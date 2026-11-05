// tests：单 RC / 单 EP 环境经 bind 引脚互联的 SCB 回归，依赖公共 env/rw_seq。
// 两个 env 各自拥有 SCB 和 TagManager，互相不可见对端 monitor；测试持有独立内存。
// 该结构模拟单侧 VIP 接外部端点，覆盖发送观察回退和双向相同 Tag；不代表真实 DUT。

// 固定 Requester ID，让双向 Tag 冲突成为确定性用例；其余构包及读回使用公共 sequence。
class intel_pcie_scb_rw_seq extends pcie_tl_rw_seq;
    `uvm_object_utils(intel_pcie_scb_rw_seq)
    bit [15:0]	requester = 16'h0100;

    // sequence 只拥有本次请求；Tag 仍由各自 env 的公共 driver 分配。
    function new(string name = "intel_pcie_scb_rw_seq");
        super.new(name);
    endfunction

    // finish_item 在发送前回调；随机化已完成，此时固定身份不会被再次覆盖。
    virtual function void mid_do(uvm_sequence_item this_item);
        pcie_tl_tlp	tlp;
        super.mid_do(this_item);
        if (!$cast(tlp, this_item))
            `uvm_fatal("SPLIT_ITEM", "expected a PCIe TLP")
        tlp.requester_id = requester;
    endfunction
endclass

// 同一物理链路由两个 env 各持一端，避免双 BFM 的共享观察流掩盖单侧集成缺陷。
class intel_pcie_env_split_test extends uvm_test;
    `uvm_component_utils(intel_pcie_env_split_test)
    pcie_tl_env	       env;
    pcie_tl_env	       peer_env;
    host_mem_manager	 host_manager;
    host_mem_manager	 device_manager;
    intel_pcie_scb_rw_seq	reads[2];
    uvm_barrier	writes_done;

    // 标准构造；组件和内存存活到测试结束，请求完成后释放分配区。
    function new(string name = "intel_pcie_env_split_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // 两端独立配置：RC 服务 Host DMA，EP 服务 Device 访问，均打开严格 SCB。
    function void build_phase(uvm_phase phase);
        pcie_tl_env_config	rc_cfg;
        pcie_tl_env_config	ep_cfg;
        string	            why;
        super.build_phase(phase);
        writes_done = new("writes_done", 2);
        rc_cfg = pcie_tl_env_config::type_id::create("rc_cfg");
        ep_cfg = pcie_tl_env_config::type_id::create("ep_cfg");
        rc_cfg.rc_agent_enable = 1;
        rc_cfg.ep_agent_enable = 0;
        rc_cfg.num_rc = 1;
        rc_cfg.num_ep = 0;
        rc_cfg.ep_auto_response = 0;
        rc_cfg.use_unified_mem = 1;
        rc_cfg.scb_enable = 1;
        rc_cfg.cpl_timeout_ns = 100000;
        ep_cfg.rc_agent_enable = 0;
        ep_cfg.ep_agent_enable = 1;
        ep_cfg.num_rc = 0;
        ep_cfg.num_ep = 1;
        ep_cfg.ep_auto_response = 1;
        ep_cfg.use_unified_mem = 1;
        ep_cfg.scb_enable = 1;
        ep_cfg.cpl_timeout_ns = 100000;

        host_manager = new("host_manager");
        device_manager = new("device_manager");
        host_manager.set_host_id(0);
        if (!rc_cfg.bind_host_memory(0, 0, host_manager, why))
            `uvm_fatal("SPLIT_MEMORY", why)
        uvm_config_db#(host_mem_api)::set(this, "peer_env", "dev_mem_0", device_manager);
        intel_pcie_configure_env(this, rc_cfg, "env");
        intel_pcie_configure_env(this, ep_cfg, "peer_env");
        env = pcie_tl_env::type_id::create("env", this);
        peer_env = pcie_tl_env::type_id::create("peer_env", this);
    endfunction

    // 每侧先写 137 个非对齐字节，再同时读回；双方独立分配 Tag，Completion 均分片。
    // 地址域刻意分离，当前公共 SCB 的数据参考表仍按地址索引，另由读回逐字节检查。
    task exercise_side(int side);
        host_mem_api	          mem;
        uvm_sequencer #(pcie_tl_tlp)	seqr;
        intel_pcie_scb_rw_seq	wr;
        bit [63:0]	            base;
        bit [63:0]	            address;
        mem = (side == 0) ? host_mem_api'(device_manager) : host_mem_api'(host_manager);
        seqr = (side == 0) ? env.rc_agent.sequencer : peer_env.ep_agent.sequencer;
        base = mem.alloc(8192, 64);
        address = base + side * 4096 + 1;
        wr = intel_pcie_scb_rw_seq::type_id::create($sformatf("wr_%0d", side));
        wr.requester = (side == 0) ? 16'h0100 : 16'h0200;
        wr.op = PCIE_RW_WRITE;
        wr.addr = address;
        wr.byte_len = 137;
        wr.wdata = new[137];
        foreach (wr.wdata[i]) wr.wdata[i] = 8'(i * 23 + side);
        wr.start(seqr);
        // 两个 posted write 都发送完再放行读，避免调度差异把同 Tag 用例串行化。
        writes_done.wait_for();
        reads[side] = intel_pcie_scb_rw_seq::type_id::create($sformatf("rd_%0d", side));
        reads[side].requester = wr.requester;
        reads[side].op = PCIE_RW_READ;
        reads[side].addr = address;
        reads[side].byte_len = 137;
        reads[side].start(seqr);
        if (reads[side].status != PCIE_RW_OK || reads[side].rdata.size() != 137)
            `uvm_fatal("SPLIT_READ", $sformatf("side=%0d read did not complete", side))
        foreach (wr.wdata[i])
            if (reads[side].rdata[i] !== wr.wdata[i])
                `uvm_fatal("SPLIT_READ", $sformatf("side=%0d byte=%0d mismatch", side, i))
        mem.free(base);
    endtask

    // 每个 SCB 都应看到四个请求、六个 Completion，并匹配两次完整读请求。
    // 计数精确比对可发现单侧 TX 遗漏、重复发布以及响应发出后未清账。
    function void check_scoreboard(pcie_tl_scoreboard s);
        if (s == null)
            `uvm_fatal("SPLIT_SCB", "scoreboard missing")
        if (s.total_requests != 4 || s.total_completions != 6 || s.matched != 2 ||
            s.unexpected != 0 || s.mismatched != 0 || s.timed_out != 0 ||
            s.pending_requests.num() != 0 || s.cpl_trackers.num() != 0)
            `uvm_error("SPLIT_SCB", $sformatf(
                "%s requests=%0d cpl=%0d matched=%0d unexpected=%0d mismatch=%0d timeout=%0d pending=%0d trackers=%0d",
                s.get_full_name(), s.total_requests, s.total_completions, s.matched,
                s.unexpected, s.mismatched, s.timed_out,
                s.pending_requests.num(), s.cpl_trackers.num()))
    endfunction

    // 同时发起 Host 访问与 EP DMA；两端各自缺少对端 monitor，必须走 TX 观察回退。
    task run_phase(uvm_phase phase);
        bit	traffic_done;
        bit	overlap_seen;
        phase.raise_objection(this);
        fork
            begin
                fork
                    exercise_side(0);
                    exercise_side(1);
                join
                traffic_done = 1;
            end
            begin
                // 两笔读是唯一 NP；两边 SCB 同时存在两项才证明复合键在实链路共存。
                // 链路时钟为 2ns，分片响应跨度大于 1ns，采样不会漏掉稳定 pending 区间。
                while (!traffic_done) begin
                    #1ns;
                    if (env.scb.pending_requests.num() == 2 &&
                        peer_env.scb.pending_requests.num() == 2)
                        overlap_seen = 1;
                end
            end
        join
        #20ns;
        if (!overlap_seen)
            `uvm_fatal("SPLIT_OVERLAP", "same-Tag requests never coexisted in both scoreboards")
        if (reads[0].issued_tlp.tag != reads[1].issued_tlp.tag ||
            reads[0].issued_tlp.requester_id == reads[1].issued_tlp.requester_id)
            `uvm_fatal("SPLIT_TAG", "test must use equal Tags with distinct Requester IDs")
        check_scoreboard(env.scb);
        check_scoreboard(peer_env.scb);
        `uvm_info("RTILE_TEST_PASS", $sformatf(
            "single-RC/single-EP SCBs drained: tag=%03h requester_ids=%04h/%04h overlap_seen=%0d",
            reads[0].issued_tlp.tag, reads[0].issued_tlp.requester_id,
            reads[1].issued_tlp.requester_id, overlap_seen), UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass
