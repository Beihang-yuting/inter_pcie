// src/adapter：pcie_tl_if_adapter 的 R-Tile 传输实现，依赖本包 codec/credit/reassembler。
// 一个实例对应一个端口；HARD_IP 驱 RX/收 TX，APPLICATION 驱 TX/收 RX。
// 上层复用 pcie_work 的 TLP/agent/sequence，接口方向独立于 PCIe RC/EP 协议角色。
// 队列、半包和信用均由实例独占；send 保存编码快照，直到 EOP 采样或复位才返回。
// Driver 以整拍组织段并在下降沿驱动；monitor_cb 上升沿前采样，不套用 ready&&valid。
class intel_pcie_if_adapter extends pcie_tl_if_adapter;
    `uvm_component_utils(intel_pcie_if_adapter)

    intel_pcie_vif_t avst_vif;
    intel_pcie_adapter_config cfg;
    intel_pcie_avst_codec avst_codec;
    intel_pcie_credit_manager credits;
    intel_pcie_reassembler reassembler;
    uvm_analysis_port #(intel_pcie_packet) rx_packet_ap;
    intel_pcie_packet tx_queue[$], rx_queue[$], beat_done[$];
    intel_pcie_packet tx_active;
    int tx_offset, rx_gap_left;
    bit running, in_reset = 1;
    bit sampled_ready, previous_ready, ever_ready;
    int ready_low_cycles;
    logic [2:0] local_hack, local_dack, remote_hinit, remote_dinit;
    longint unsigned sent_packets, received_packets, reset_epochs;
    bit hard_ip_ready = 1;

    // 构造只建立 UVM 归属；配置和 virtual interface 在 build_phase 绑定。
    function new(string name = "intel_pcie_if_adapter", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // Intel adapter 使用专用 Avalon-ST virtual interface；不能让公共 env
    // 通过基类 pcie_tl_if_adapter.vif 判断，否则即使 bind 成功也会误报。
    virtual function bit native_vif_required();
        return 1'b1;
    endfunction

    virtual function bit native_vif_bound();
        return (avst_vif != null);
    endfunction

    // 工厂覆盖与 Xilinx adapter 一致。默认 rc_adapter* 模拟硬核，ep_adapter*
    // 模拟应用；接真实 RP 用户 DUT 时必须通过 intel_cfg.side 显式指定方向。
    function void build_phase(uvm_phase phase);
        string nm;
        super.build_phase(phase);
        if (!uvm_config_db#(intel_pcie_adapter_config)::get(this, "", "intel_cfg", cfg))
            cfg = intel_pcie_adapter_config::type_id::create("intel_cfg");
        nm = get_name();
        if (cfg.side == INTEL_PCIE_AUTO) begin
            if (nm.len() >= 10 && nm.substr(0,9) == "rc_adapter") cfg.side = INTEL_PCIE_HARD_IP;
            else if (nm.len() >= 10 && nm.substr(0,9) == "ep_adapter") cfg.side = INTEL_PCIE_APPLICATION;
            else `uvm_fatal("RTILE_CONFIG", "set intel_cfg.side for a custom adapter name")
        end
        cfg.validate();
        if (!uvm_config_db#(intel_pcie_vif_t)::get(this, "", "vif", avst_vif))
            `uvm_fatal("RTILE_VIF", $sformatf(
                "missing intel_pcie_if virtual interface for adapter '%s'",
                get_full_name()))
        mode = SV_IF_MODE;
        avst_codec = intel_pcie_avst_codec::type_id::create("avst_codec");
        avst_codec.header_big_endian = cfg.header_big_endian;
        credits = intel_pcie_credit_manager::type_id::create("credits");
        credits.cfg = cfg;
        reassembler = intel_pcie_reassembler::type_id::create("reassembler");
        reassembler.cfg = cfg;
        reassembler.codec = avst_codec;
        rx_packet_ap = new("rx_packet_ap", this);
    endfunction

    // 公共 FC 以 DWORD 计数且可能在 RC/EP 之间共享，必须显式关闭其有限门控。
    // 本地 AVST credit_enable 仍默认开启，二者互不替代；不静默改写上游 manager。
    function void start_of_simulation_phase(uvm_phase phase);
        super.start_of_simulation_phase(phase);
        if (fc_mgr != null && fc_mgr.fc_enable && !fc_mgr.infinite_credit)
            `uvm_fatal("RTILE_FC_CONFIG", "set pcie_tl_env_config.infinite_credit=1; adapter owns finite AVST credits")
    endfunction

    // 串行时钟线程拥有全部 pins，防止 send/monitor/reset 各自修改引脚产生竞争。
    // 每拍已推出的 valid 都被消费；TX ready 低的允许延迟窗口内不保持旧拍重发。
    task run_phase(uvm_phase phase);
        reset_state();
        drive_reset();
        running = 1;
        forever begin
            @(avst_vif.monitor_cb);
            if (avst_vif.monitor_cb.rst_n !== 1'b1) begin
                if (!in_reset) reset_state();
                in_reset = 1;
            end else begin
                in_reset = 0;
                sample_cycle();
            end
            @(negedge avst_vif.clk);
            if (avst_vif.rst_n !== 1'b1 || in_reset) drive_reset();
            else drive_cycle();
        end
    endtask

    // 保留公共 send 签名；完成表示本地 EOP 已经采样，尚不代表 PCIe 对端完成响应。
    virtual task send(pcie_tl_tlp tlp);
        pcie_tl_tlp batch[$];
        batch.push_back(tlp);
        send_batch(batch);
    endtask

    // 可选批量入口把多个包先入队，允许在 st0/st2 同拍起包；正常 sequence 仍用 send。
    // 所有编码先完成再入队，任一不支持的包都不会留下半个已提交 batch。
    task send_batch(pcie_tl_tlp tlps[$]);
        intel_pcie_packet packets[$];
        intel_pcie_packet p;
        wait (running && !in_reset);
        foreach (tlps[i]) begin
            p = avst_codec.encode(tlps[i]);
            if (p == null) return;
            packets.push_back(p);
        end
        foreach (packets[i]) tx_queue.push_back(packets[i]);
        foreach (packets[i]) begin
            wait (packets[i].completed || packets[i].aborted);
            if (packets[i].aborted)
                `uvm_error("RTILE_RESET_ABORT", "reset aborted an outstanding send; caller must restart its transaction")
        end
    endtask

    // 非阻塞队列出队复用公共 monitor 契约；空间在此刻释放，不在 EOP 提前归还。
    virtual task receive(output pcie_tl_tlp tlp);
        intel_pcie_packet p;
        tlp = null;
        if (in_reset || rx_queue.size() == 0) return;
        p = rx_queue.pop_front();
        tlp = avst_codec.decode(p);
        credits.release_local(p);
    endtask

    // 硬核侧压力测试入口，仅改变下个下降沿驱动的 TX ready，应用侧禁止调用。
    function void set_tx_ready(bit value);
        if (cfg.side != INTEL_PCIE_HARD_IP)
            `uvm_error("RTILE_DIRECTION", "only HARD_IP owns tx_ready")
        else hard_ip_ready = value;
    endfunction

    // 重置当前 epoch：解除 send 等待，丢弃接收半包/完整队列，重新初始化信用。
    // sent/received 统计跨复位累计，便于检查没有旧包重放；TX ready 策略由测试保留。
    protected function void reset_state();
        foreach (tx_queue[i]) tx_queue[i].aborted = 1;
        foreach (beat_done[i]) beat_done[i].aborted = 1;
        if (tx_active != null) tx_active.aborted = 1;
        tx_queue.delete(); rx_queue.delete(); beat_done.delete();
        tx_active = null; tx_offset = 0; rx_gap_left = 0;
        sampled_ready = 0; previous_ready = 0; ever_ready = 0; ready_low_cycles = 0;
        local_hack = '0; local_dack = '0; remote_hinit = '0; remote_dinit = '0;
        credits.reset(); reassembler.reset(); reset_epochs++;
    endfunction

    // 采样控制、接收包与已发 EOP。双方对每拍 valid 的解释完全相同，避免重发/丢拍。
    protected function void sample_cycle();
        intel_pcie_credit_pins_t remote;
        intel_pcie_beat_t incoming;
        intel_pcie_packet started[$], done[$];
        bit incoming_tx, strict_ready;

        previous_ready = sampled_ready;
        sampled_ready = (avst_vif.monitor_cb.tx_ready === 1'b1);
        if (sampled_ready) begin ever_ready = 1; ready_low_cycles = 0; end
        else ready_low_cycles++;
        incoming_tx = (cfg.side == INTEL_PCIE_HARD_IP);
        remote = sample_credit_pins(!incoming_tx);
        credits.sample_remote(remote);
        remote_hinit = remote.hinit; remote_dinit = remote.dinit;
        if (incoming_tx) begin
            local_hack = avst_vif.monitor_cb.tx_hcrdt_init_ack;
            local_dack = avst_vif.monitor_cb.tx_dcrdt_init_ack;
        end else begin
            local_hack = avst_vif.monitor_cb.rx_hcrdt_init_ack;
            local_dack = avst_vif.monitor_cb.rx_dcrdt_init_ack;
        end
        if (avst_vif.monitor_cb.rx_ready !== 1'b1)
            `uvm_error("RTILE_RX_READY", "R-Tile rx_ready must stay high; use credits for RX backpressure")
        incoming = sample_beat(incoming_tx);
        if (incoming_tx && (|incoming.hvalid || |incoming.dvalid)) begin
            if (!ever_ready || (!sampled_ready && ready_low_cycles > 16))
                `uvm_error("RTILE_TX_READY", "TX valid outside the permitted ready response window")
        end
        // ready 首次恢复时允许一拍反应；随后仍有半包就必须连续供数。
        strict_ready = sampled_ready && previous_ready;
        reassembler.consume(incoming, incoming_tx, strict_ready, started, done);
        foreach (started[i]) credits.occupy_local(started[i]);
        foreach (done[i]) begin
            rx_queue.push_back(done[i]); received_packets++;
            rx_packet_ap.write(done[i]);
        end
        foreach (beat_done[i]) begin beat_done[i].completed = 1; sent_packets++; end
        beat_done.delete();
    endfunction

    // 从一个采样快照读取 credit pins；tx=1 为硬核公布给 TX source 的计数。
    protected function intel_pcie_credit_pins_t sample_credit_pins(bit tx);
        intel_pcie_credit_pins_t p;
        if (tx) begin
            p.hinit = avst_vif.monitor_cb.tx_hcrdt_init;
            p.dinit = avst_vif.monitor_cb.tx_dcrdt_init;
            p.hupdate = avst_vif.monitor_cb.tx_hcrdt_update;
            p.dupdate = avst_vif.monitor_cb.tx_dcrdt_update;
            p.hcnt = avst_vif.monitor_cb.tx_hcrdt_update_cnt;
            p.dcnt = avst_vif.monitor_cb.tx_dcrdt_update_cnt;
        end else begin
            p.hinit = avst_vif.monitor_cb.rx_hcrdt_init;
            p.dinit = avst_vif.monitor_cb.rx_dcrdt_init;
            p.hupdate = avst_vif.monitor_cb.rx_hcrdt_update;
            p.dupdate = avst_vif.monitor_cb.rx_dcrdt_update;
            p.hcnt = avst_vif.monitor_cb.rx_hcrdt_update_cnt;
            p.dcnt = avst_vif.monitor_cb.rx_dcrdt_update_cnt;
        end
        return p;
    endfunction

    // TX 没有 empty/路由边带；这些字段只在 RX packet 有意义，TX 快照保持零。
    protected function intel_pcie_beat_t sample_beat(bit tx);
        intel_pcie_beat_t b = '0;
        if (tx) begin
            b.data = avst_vif.monitor_cb.tx_data; b.hdr = avst_vif.monitor_cb.tx_hdr;
            b.prefix = avst_vif.monitor_cb.tx_prefix;
            b.sop = avst_vif.monitor_cb.tx_sop; b.eop = avst_vif.monitor_cb.tx_eop;
            b.hvalid = avst_vif.monitor_cb.tx_hvalid; b.dvalid = avst_vif.monitor_cb.tx_dvalid;
            b.pvalid = avst_vif.monitor_cb.tx_pvalid;
            b.data_par = avst_vif.monitor_cb.tx_data_par;
            b.hdr_par = avst_vif.monitor_cb.tx_hdr_par;
            b.prefix_par = avst_vif.monitor_cb.tx_prefix_par;
        end else begin
            b.data = avst_vif.monitor_cb.rx_data; b.hdr = avst_vif.monitor_cb.rx_hdr;
            b.prefix = avst_vif.monitor_cb.rx_prefix;
            b.sop = avst_vif.monitor_cb.rx_sop; b.eop = avst_vif.monitor_cb.rx_eop;
            b.hvalid = avst_vif.monitor_cb.rx_hvalid; b.dvalid = avst_vif.monitor_cb.rx_dvalid;
            b.pvalid = avst_vif.monitor_cb.rx_pvalid; b.empty = avst_vif.monitor_cb.rx_empty;
            b.bar = avst_vif.monitor_cb.rx_bar; b.pfnum = avst_vif.monitor_cb.rx_pfnum;
            b.vfactive = avst_vif.monitor_cb.rx_vfactive; b.vfnum = avst_vif.monitor_cb.rx_vfnum;
            b.data_par = avst_vif.monitor_cb.rx_data_par;
            b.hdr_par = avst_vif.monitor_cb.rx_hdr_par;
            b.prefix_par = avst_vif.monitor_cb.rx_prefix_par;
        end
        return b;
    endfunction

    // 下降沿统一驱动当前 side 的数据、ready 与信用。ACK 只响应远端发起的 init。
    protected function void drive_cycle();
        intel_pcie_credit_pins_t p;
        intel_pcie_beat_t b;
        p = credits.drive_local(local_hack, local_dack);
        b = build_beat();
        drive_beat(b);
        drive_credit_pins(p, remote_hinit, remote_dinit);
        if (cfg.side == INTEL_PCIE_APPLICATION) avst_vif.rx_ready = 1;
        else avst_vif.tx_ready = hard_ip_ready;
    endfunction

    // 复位也保持 RX ready=1，但清 valid/credit/ACK；实际硬核 TX ready 保持低。
    protected function void drive_reset();
        drive_beat('0);
        drive_credit_pins('0, '0, '0);
        if (cfg.side == INTEL_PCIE_APPLICATION) avst_vif.rx_ready = 1;
        else avst_vif.tx_ready = 0;
    endfunction

    // source 先预留完整包信用，再在本拍填满所有可用 segment；绝不逐段等待时钟。
    // 四段 TX 的后继包仅在前包有数据且于 st0/st1 结束时从 st2 开始。
    protected function intel_pcie_beat_t build_beat();
        intel_pcie_beat_t b = '0;
        intel_pcie_packet next_pkt;
        bit tx, first_segment, previous_data;
        int s, starts, n, remain, next_s;

        tx = (cfg.side == INTEL_PCIE_APPLICATION);
        if (tx && !sampled_ready &&
            !(tx_active != null && ever_ready && ready_low_cycles < cfg.tx_stop_latency)) return b;
        if (!tx && rx_gap_left > 0) begin rx_gap_left--; return b; end
        s = 0; starts = 0; previous_data = 0;
        if (!tx && tx_active == null) s = cfg.rx_start_segment;
        while (s < INTEL_SEGMENTS) begin
            first_segment = 0;
            if (tx_active == null) begin
                if (tx && !sampled_ready) break;
                if (tx_queue.size() == 0) break;
                if ((!tx && starts >= 3) || (tx && cfg.x16_single_width && starts >= 1)) break;
                next_pkt = tx_queue[0];
                if (!credits.can_send(next_pkt)) break;
                // UG §4.3.1.2.4：硬核到用户的 RX data credits 低于32时停止起包。
                // 已经预留的半包仍继续；此门槛不能套用到应用发送 TX 的对端信用。
                if (!tx && cfg.credit_enable && !credits.dinfinite[next_pkt.category] &&
                    credits.davailable[next_pkt.category] < 32) break;
                // 表58/59列出的后继起包均为有数据包；纯 Header 包只从新拍开始。
                if (tx && s != 0 && (!previous_data || next_pkt.expected_bytes == 0)) break;
                tx_active = tx_queue.pop_front(); tx_offset = 0;
                credits.reserve_remote(tx_active);
                first_segment = 1; starts++;
            end
            if (first_segment) begin
                b.sop[s] = 1; b.hvalid[s] = 1; b.hdr[s] = tx_active.header;
                b.pvalid[s] = tx_active.prefix_valid; b.prefix[s] = tx_active.prefix;
                b.bar[s] = tx_active.bar; b.pfnum[s] = tx_active.pfnum;
                b.vfactive[s] = tx_active.vfactive; b.vfnum[s] = tx_active.vfnum;
            end
            remain = tx_active.expected_bytes - tx_offset;
            n = (remain > INTEL_DATA_BYTES) ? INTEL_DATA_BYTES : remain;
            if (n > 0) begin
                b.dvalid[s] = 1;
                for (int i = 0; i < n; i++) b.data[s][8*i +: 8] = tx_active.payload[tx_offset+i];
                tx_offset += n;
            end
            if (tx_offset == tx_active.expected_bytes) begin
                b.eop[s] = 1;
                if (n > 0) b.empty[s] = 3'((INTEL_DATA_BYTES-n)/4);
                previous_data = (tx_active.expected_bytes > 0);
                beat_done.push_back(tx_active); tx_active = null;
                next_s = s+1;
                if (tx && INTEL_SEGMENTS == 4 && next_s == 1) next_s = 2;
                if (tx && INTEL_SEGMENTS == 4 && next_s == 3) break;
                s = next_s;
            end else s++;
        end
        // RX 才允许主动制造包内空拍；TX 永远只因 ready 暂停。
        if (!tx && tx_active != null) rx_gap_left = cfg.rx_gap_cycles;
        for (int seg = 0; seg < INTEL_SEGMENTS; seg++) begin
            for (int d = 0; d < INTEL_DATA_WIDTH/32; d++)
                b.data_par[seg][d] = ^b.data[seg][32*d +: 32];
            for (int d = 0; d < 4; d++) b.hdr_par[seg][d] = ^b.hdr[seg][32*d +: 32];
            b.prefix_par[seg] = ^b.prefix[seg];
        end
        return b;
    endfunction

    // 唯一的数据引脚写入口；按 side 选择，不能同时驱动接收方向以制造自回环。
    protected function void drive_beat(intel_pcie_beat_t b);
        if (cfg.side == INTEL_PCIE_APPLICATION) begin
            avst_vif.tx_data = b.data; avst_vif.tx_hdr = b.hdr; avst_vif.tx_prefix = b.prefix;
            avst_vif.tx_sop = b.sop; avst_vif.tx_eop = b.eop;
            avst_vif.tx_hvalid = b.hvalid; avst_vif.tx_dvalid = b.dvalid; avst_vif.tx_pvalid = b.pvalid;
            avst_vif.tx_data_par = b.data_par; avst_vif.tx_hdr_par = b.hdr_par;
            avst_vif.tx_prefix_par = b.prefix_par;
        end else begin
            avst_vif.rx_data = b.data; avst_vif.rx_hdr = b.hdr; avst_vif.rx_prefix = b.prefix;
            avst_vif.rx_sop = b.sop; avst_vif.rx_eop = b.eop;
            avst_vif.rx_hvalid = b.hvalid; avst_vif.rx_dvalid = b.dvalid; avst_vif.rx_pvalid = b.pvalid;
            avst_vif.rx_empty = b.empty; avst_vif.rx_bar = b.bar; avst_vif.rx_pfnum = b.pfnum;
            avst_vif.rx_vfactive = b.vfactive; avst_vif.rx_vfnum = b.vfnum;
            avst_vif.rx_data_par = b.data_par; avst_vif.rx_hdr_par = b.hdr_par;
            avst_vif.rx_prefix_par = b.prefix_par;
        end
    endfunction

    // Sink 拥有 init/update，source 拥有对应 ACK：RX sink=应用，TX sink=硬核。
    protected function void drive_credit_pins(intel_pcie_credit_pins_t p,
                                               logic [2:0] hack, dack);
        if (cfg.side == INTEL_PCIE_APPLICATION) begin
            avst_vif.rx_hcrdt_init = p.hinit; avst_vif.rx_dcrdt_init = p.dinit;
            avst_vif.rx_hcrdt_update = p.hupdate; avst_vif.rx_dcrdt_update = p.dupdate;
            avst_vif.rx_hcrdt_update_cnt = p.hcnt; avst_vif.rx_dcrdt_update_cnt = p.dcnt;
            avst_vif.tx_hcrdt_init_ack = hack; avst_vif.tx_dcrdt_init_ack = dack;
        end else begin
            avst_vif.tx_hcrdt_init = p.hinit; avst_vif.tx_dcrdt_init = p.dinit;
            avst_vif.tx_hcrdt_update = p.hupdate; avst_vif.tx_dcrdt_update = p.dupdate;
            avst_vif.tx_hcrdt_update_cnt = p.hcnt; avst_vif.tx_dcrdt_update_cnt = p.dcnt;
            avst_vif.rx_hcrdt_init_ack = hack; avst_vif.rx_dcrdt_init_ack = dack;
        end
    endfunction
endclass
