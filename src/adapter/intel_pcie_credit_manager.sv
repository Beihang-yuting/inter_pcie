// src/adapter：R-Tile AVST 六类信用的初始化、预留和归还；由 adapter_pkg include。
// 依赖 config/packet 类型。每端口独占实例，同时拥有本端缓冲计数和对端信用镜像。
// 不复用 pcie_work 的 DWORD 数据计数器：硬核接口每个 Data credit 为 16 B，
// 两者不能直接相加。上游 FC 设为 infinite，有限信用完全由本类处理。
class intel_pcie_credit_manager extends uvm_object;
    `uvm_object_utils(intel_pcie_credit_manager)

    intel_pcie_adapter_config cfg;
    int havailable[3], davailable[3];
    bit hinfinite[3], dinfinite[3], hready[3], dready[3];
    bit hseen[3], dseen[3];
    logic [2:0] previous_hinit, previous_dinit;
    int hused[3], dused[3], hreturn[3], dreturn[3];
    int hremaining[3], dremaining[3];
    bit hsent[3], dsent[3];
    typedef enum {WAIT_ACK, ADVERTISE, GAP_ONE, GAP_TWO, RUN} init_state_e;
    init_state_e state;
    bit local_initialized;

    // 构造后必须由 adapter 赋 cfg 并调用 reset，避免共享配置的隐式初始状态。
    function new(string name = "intel_pcie_credit_manager");
        super.new(name);
    endfunction

    // 复位销毁全部在途信用；与 adapter 丢弃半包/队列同步，不能复用上个 epoch。
    function void reset();
        state = WAIT_ACK;
        local_initialized = 0;
        previous_hinit = '0;
        previous_dinit = '0;
        for (int c = 0; c < 3; c++) begin
            havailable[c] = 0; davailable[c] = 0;
            hinfinite[c] = 0; dinfinite[c] = 0;
            hready[c] = 0; dready[c] = 0;
            hseen[c] = 0; dseen[c] = 0;
            hused[c] = 0; dused[c] = 0;
            hreturn[c] = 0; dreturn[c] = 0;
            hsent[c] = 0; dsent[c] = 0;
            hremaining[c] = cfg.header_capacity[c];
            dremaining[c] = cfg.data_capacity[c];
        end
    endfunction

    // 采样对端 sink 的 credit 接口。只在 init 阶段的 update=1/cnt=0 表示无限；
    // 正常运行的零增量不是无限。六类可独立初始化，不把一次更新当累计总量。
    function void sample_remote(intel_pcie_credit_pins_t p);
        if (!cfg.credit_enable) return;
        if ($isunknown({p.hinit,p.dinit,p.hupdate,p.dupdate})) begin
            `uvm_error("RTILE_CREDIT_X", "unknown credit control or count")
            return;
        end
        for (int c = 0; c < 3; c++) begin
            if (p.hinit[c] && !previous_hinit[c]) begin
                havailable[c] = 0; hinfinite[c] = 0; hready[c] = 0; hseen[c] = 1;
            end
            if (p.dinit[c] && !previous_dinit[c]) begin
                davailable[c] = 0; dinfinite[c] = 0; dready[c] = 0; dseen[c] = 1;
            end
            if (p.hupdate[c]) begin
                if ($isunknown(p.hcnt[2*c +: 2]))
                    `uvm_error("RTILE_CREDIT_X", "unknown valid header update count")
                if (p.hinit[c] && p.hcnt[2*c +: 2] == 0) hinfinite[c] = 1;
                else havailable[c] += int'(p.hcnt[2*c +: 2]);
            end
            if (p.dupdate[c]) begin
                if ($isunknown(p.dcnt[4*c +: 4]))
                    `uvm_error("RTILE_CREDIT_X", "unknown valid data update count")
                if (p.dinit[c] && p.dcnt[4*c +: 4] == 0) dinfinite[c] = 1;
                else davailable[c] += int'(p.dcnt[4*c +: 4]);
            end
            if (hseen[c] && !p.hinit[c]) hready[c] = 1;
            if (dseen[c] && !p.dinit[c]) dready[c] = 1;
        end
        previous_hinit = p.hinit;
        previous_dinit = p.dinit;
    endfunction

    // 输出本端 sink 的初始化或回收增量。所有计数按接口宽度拆成 <=3/<=15，
    // 最后一拍 update 与 init 撤销之间保持两个完整空拍（UG §4.3.1.2.2）。
    function intel_pcie_credit_pins_t drive_local(logic [2:0] hack, dack);
        intel_pcie_credit_pins_t p = '0;
        bit all_sent;
        int n;

        if (!cfg.credit_enable) begin
            local_initialized = 1;
            return p;
        end
        if (state != RUN) begin p.hinit = '1; p.dinit = '1; end
        case (state)
            WAIT_ACK: if ((hack === 3'b111) && (dack === 3'b111)) state = ADVERTISE;
            ADVERTISE: begin
                all_sent = 1;
                for (int c = 0; c < 3; c++) begin
                    if (!hsent[c]) begin
                        n = cfg.infinite_header[c] ? 0 : ((hremaining[c] > 3) ? 3 : hremaining[c]);
                        p.hupdate[c] = 1; p.hcnt[2*c +: 2] = 2'(n);
                        hremaining[c] -= n;
                        hsent[c] = cfg.infinite_header[c] || hremaining[c] == 0;
                    end
                    if (!dsent[c]) begin
                        n = cfg.infinite_data[c] ? 0 : ((dremaining[c] > 15) ? 15 : dremaining[c]);
                        p.dupdate[c] = 1; p.dcnt[4*c +: 4] = 4'(n);
                        dremaining[c] -= n;
                        dsent[c] = cfg.infinite_data[c] || dremaining[c] == 0;
                    end
                    all_sent &= hsent[c] && dsent[c];
                end
                if (all_sent) state = GAP_ONE;
            end
            GAP_ONE: state = GAP_TWO;
            GAP_TWO: state = RUN;
            RUN: begin
                local_initialized = 1;
                for (int c = 0; c < 3; c++) begin
                    if (hreturn[c] > 0 && !cfg.infinite_header[c]) begin
                        n = (hreturn[c] > 3) ? 3 : hreturn[c];
                        p.hupdate[c] = 1; p.hcnt[2*c +: 2] = 2'(n); hreturn[c] -= n;
                    end
                    if (dreturn[c] > 0 && !cfg.infinite_data[c]) begin
                        n = (dreturn[c] > 15) ? 15 : dreturn[c];
                        p.dupdate[c] = 1; p.dcnt[4*c +: 4] = 4'(n); dreturn[c] -= n;
                    end
                end
            end
        endcase
        return p;
    endfunction

    // SOP 前预留完整包的空间，避免包中等待 credit 而违反 TX 连续发送规则。
    function bit can_send(intel_pcie_packet pkt);
        int c = pkt.category;
        if (!cfg.credit_enable) return 1;
        return hready[c] && dready[c] &&
               (hinfinite[c] || havailable[c] >= 1) &&
               (dinfinite[c] || davailable[c] >= pkt.data_credits());
    endfunction

    // 只在首次推出 SOP 时调用一次；反压恢复不能重复扣除。
    function void reserve_remote(intel_pcie_packet pkt);
        int c = pkt.category;
        if (!cfg.credit_enable) return;
        if (!can_send(pkt)) begin
            `uvm_error("RTILE_CREDIT", "attempted SOP without sufficient credits")
            return;
        end
        if (!hinfinite[c]) havailable[c]--;
        if (!dinfinite[c]) davailable[c] -= pkt.data_credits();
    endfunction

    // 接收 SOP 时核对已公布的容量。空间持有到 receive() 出队，不在 EOP 提前归还。
    function void occupy_local(intel_pcie_packet pkt);
        int c = pkt.category;
        if (!cfg.credit_enable) return;
        hused[c]++; dused[c] += pkt.data_credits();
        if (!local_initialized ||
            (!cfg.infinite_header[c] && hused[c] > cfg.header_capacity[c]) ||
            (!cfg.infinite_data[c] && dused[c] > cfg.data_capacity[c]))
            `uvm_error("RTILE_OVERFLOW", "received TLP beyond advertised buffer credits")
    endfunction

    // 用户真正取走包时释放空间，增量由下一次 drive_local 分批发给对端。
    function void release_local(intel_pcie_packet pkt);
        int c = pkt.category;
        if (!cfg.credit_enable) return;
        hused[c]--; dused[c] -= pkt.data_credits();
        if (hused[c] < 0 || dused[c] < 0)
            `uvm_error("RTILE_CREDIT", "duplicate credit release")
        hreturn[c]++; dreturn[c] += pkt.data_credits();
    endfunction
endclass
