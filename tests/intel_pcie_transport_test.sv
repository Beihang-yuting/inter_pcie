// tests：信号级双向传输、压力、信用耗尽和复位回归；依赖 pair_test。
// 数据必须走 interface 再解码，无 assign/TLM 旁路。负例只捕获预期 reset 报告。
class intel_pcie_transport_test extends intel_pcie_pair_test;
    `uvm_component_utils(intel_pcie_transport_test)

    // 标准 UVM 构造，复用基类的 adapter 所有权。
    function new(string name="intel_pcie_transport_test", uvm_component parent=null);
        super.new(name,parent);
    endfunction

    // 覆盖多包共拍、无数据、短尾、跨拍和最大4096B，并核对不自收自发。
    task run_phase(uvm_phase phase);
        pcie_tl_tlp toward_app[$], toward_hip[$], got;
        int sizes[$]='{4,32,36,64,128,132,0,4096};
        phase.raise_objection(this);
        wait_initialized();
        foreach (sizes[i]) begin
            toward_app.push_back(intel_test_mem(sizes[i],i));
            toward_hip.push_back(intel_test_mem(sizes[i],i+31,i%2));
        end
        fork
            hip.send_batch(toward_app);
            app.send_batch(toward_hip);
            begin
                foreach (toward_app[i]) begin
                    get_packet(app,got); intel_test_equal(toward_app[i],got);
                end
            end
            begin
                pcie_tl_tlp hgot;
                foreach (toward_hip[i]) begin
                    get_packet(hip,hgot); intel_test_equal(toward_hip[i],hgot);
                end
            end
        join
        repeat(5) @(bus.monitor_cb);
        if (app.rx_queue.size()!=0 || hip.rx_queue.size()!=0 ||
            app.sent_packets!=8 || hip.sent_packets!=8 ||
            app.received_packets!=8 || hip.received_packets!=8)
            `uvm_fatal("NO_ECHO", "lost packet or TX self-echo")
        `uvm_info("RTILE_TEST_PASS", "bidirectional finite-credit transport and exact payload compare", UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass

class intel_pcie_rx_gap_test extends intel_pcie_pair_test;
    `uvm_component_utils(intel_pcie_rx_gap_test)

    // 标准 UVM 构造，不改 testbench 引脚方向。
    function new(string name="intel_pcie_rx_gap_test", uvm_component parent=null);
        super.new(name,parent);
    endfunction

    // RX 从 st1 开始，包内每个有效拍之后插入两拍空闲；ready 必须常高。
    function void configure();
        hip_cfg.rx_gap_cycles=2;
        hip_cfg.rx_start_segment=(INTEL_SEGMENTS>1) ? 1 : 0;
    endfunction

    // 监视真实空拍数量，确认不是仅配置了 gap 却没有走到该路径。
    task run_phase(uvm_phase phase);
        pcie_tl_tlp t, got;
        int gaps=0;
        bit in_packet=0, finished=0;
        phase.raise_objection(this); wait_initialized();
        t=intel_test_mem(516,77);
        fork
            hip.send(t);
            begin
                while (!finished) begin
                    @(bus.monitor_cb);
                    if (bus.monitor_cb.rx_ready !== 1) `uvm_fatal("RX_READY", "RX ready deasserted")
                    if (|bus.monitor_cb.rx_sop) in_packet=1;
                    if (in_packet && !(|bus.monitor_cb.rx_dvalid)) gaps++;
                    if (|bus.monitor_cb.rx_eop) finished=1;
                end
            end
        join
        get_packet(app,got); intel_test_equal(t,got);
        if (gaps<2) `uvm_fatal("RX_GAP", "no actual idle cycles observed")
        `uvm_info("RTILE_TEST_PASS", $sformatf("RX gaps=%0d, ready stayed high",gaps),UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass

class intel_pcie_tx_ready_test extends intel_pcie_pair_test;
    `uvm_component_utils(intel_pcie_tx_ready_test)

    // 标准 UVM 构造；stop_latency 由派生16拍测试覆盖。
    function new(string name="intel_pcie_tx_ready_test", uvm_component parent=null);
        super.new(name,parent);
    endfunction

    // 以原始字节计数验证低 ready 期间继续前进的拍没有重复，恢复只允许一拍延迟。
    task run_phase(uvm_phase phase);
        pcie_tl_tlp t, got;
        int offset=0, low_valid=0, low_cycles=0, resume_wait=0, nsop=0;
        bit started=0, finished=0, had_low=0, resumed=0;
        phase.raise_objection(this); wait_initialized();
        t=intel_test_mem(4096,91);
        fork
            app.send(t);
            begin
                do @(bus.monitor_cb); while (!(|bus.monitor_cb.tx_sop));
                hip.set_tx_ready(0);
                repeat(24) @(bus.monitor_cb);
                hip.set_tx_ready(1);
            end
            begin
                while (!finished) begin
                    @(bus.monitor_cb);
                    if (|bus.monitor_cb.tx_sop) begin started=1; nsop++; end
                    if (!started) continue;
                    if (!bus.monitor_cb.tx_ready) begin
                        had_low=1; low_cycles++;
                        if (|bus.monitor_cb.tx_dvalid) low_valid++;
                        if (low_cycles>16 && (|bus.monitor_cb.tx_dvalid))
                            `uvm_fatal("TX_LATENCY", "valid remained high past 16 cycles")
                    end
                    if (had_low && bus.monitor_cb.tx_ready && !resumed) begin
                        if (|bus.monitor_cb.tx_dvalid) resumed=1;
                        else resume_wait++;
                        if (resume_wait>1) `uvm_fatal("TX_RESUME", "late continuation after ready")
                    end
                    for (int s=0;s<INTEL_SEGMENTS;s++) begin
                        if (bus.monitor_cb.tx_dvalid[s]) begin
                            for (int b=0;b<INTEL_DATA_BYTES && offset<t.payload.size();b++) begin
                                if (bus.monitor_cb.tx_data[s][8*b +: 8] !== t.payload[offset])
                                    `uvm_fatal("TX_REPLAY", $sformatf("drop/repeat at byte %0d",offset))
                                offset++;
                            end
                        end
                        if (bus.monitor_cb.tx_eop[s]) finished=1;
                    end
                end
            end
        join
        get_packet(hip,got); intel_test_equal(t,got);
        if (nsop!=1 || offset!=4096 || !resumed || low_valid!=app_cfg.tx_stop_latency)
            `uvm_fatal("TX_READY", $sformatf("sop=%0d bytes=%0d resumed=%0b low_valid=%0d expected=%0d",
                       nsop,offset,resumed,low_valid,app_cfg.tx_stop_latency))
        `uvm_info("RTILE_TEST_PASS", $sformatf("ready low accepted %0d distinct beats; resume within one cycle",low_valid),UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass

class intel_pcie_tx_ready16_test extends intel_pcie_tx_ready_test;
    `uvm_component_utils(intel_pcie_tx_ready16_test)

    // 复用同一原始字节 scoreboard，只改变允许的停发反应延迟。
    function new(string name="intel_pcie_tx_ready16_test", uvm_component parent=null);
        super.new(name,parent);
    endfunction

    // 明确走到文档16拍上限，不能仅验证立即停发的简化实现。
    function void configure();
        app_cfg.tx_stop_latency=16;
    endfunction
endclass

class intel_pcie_credit_test extends intel_pcie_pair_test;
    `uvm_component_utils(intel_pcie_credit_test)

    // 标准 UVM 构造，有限信用由 config 独立设置。
    function new(string name="intel_pcie_credit_test", uvm_component parent=null);
        super.new(name,parent);
    endfunction

    // 应用 RX 仅两个 P Header 槽位，数据空间仍满足初始化 >32 的限制。
    function void configure();
        app_cfg.header_capacity[0]=2;
        app_cfg.data_capacity[0]=64;
    endfunction

    // 不出队就不得返回信用；第三包需等 receive() 归还一个 Header 后才能开始。
    task run_phase(uvm_phase phase);
        pcie_tl_tlp batch[$], got;
        bit send_finished=0;
        phase.raise_objection(this); wait_initialized();
        for(int i=0;i<3;i++) batch.push_back(intel_test_mem(48,i));
        fork
            begin hip.send_batch(batch); send_finished=1; end
            begin
                wait(app.rx_queue.size()==2);
                repeat(8) @(bus.monitor_cb);
                if(send_finished || hip.sent_packets!=2 || hip.credits.havailable[0]!=0 ||
                   app.credits.hused[0]!=2 || app.credits.dused[0]!=6)
                    `uvm_fatal("CREDIT_STALL", "buffer-full condition was not respected")
                get_packet(app,got); intel_test_equal(batch[0],got);
                wait(app.rx_queue.size()==2);
                get_packet(app,got); intel_test_equal(batch[1],got);
                get_packet(app,got); intel_test_equal(batch[2],got);
            end
        join
        repeat(8) @(bus.monitor_cb);
        if(hip.credits.havailable[0]!=2 || hip.credits.davailable[0]!=64 ||
           app.credits.hused[0]!=0 || app.credits.dused[0]!=0)
            `uvm_fatal("CREDIT_RETURN", "credit leak/duplicate after dequeue")
        `uvm_info("RTILE_TEST_PASS", "RX full stalls on credit; dequeue restores exact 16-byte credits",UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass

class intel_pcie_reset_test extends intel_pcie_pair_test;
    `uvm_component_utils(intel_pcie_reset_test)

    // 标准 UVM 构造，由 control interface 独占复位驱动。
    function new(string name="intel_pcie_reset_test", uvm_component parent=null);
        super.new(name,parent);
    endfunction

    // 半包被反压时复位，旧 send 必须退出且不能在新 epoch 重放旧数据/信用。
    task run_phase(uvm_phase phase);
        pcie_tl_tlp t, got;
        intel_expected_error errors;
        phase.raise_objection(this); wait_initialized();
        errors=new; errors.expected_id="RTILE_RESET_ABORT";
        uvm_report_cb::add(null,errors);
        t=intel_test_mem(4096,123);
        fork
            app.send(t);
            begin
                do @(bus.monitor_cb); while (!(|bus.monitor_cb.tx_sop));
                hip.set_tx_ready(0);
                repeat(4) @(bus.monitor_cb);
                control.reset_cycles(5);
                hip.set_tx_ready(1);
            end
        join
        if(errors.count!=1) `uvm_fatal("RESET", "send did not report exactly one reset abort")
        uvm_report_cb::delete(null,errors);
        wait_initialized();
        if(hip.rx_queue.size()!=0 || app.rx_queue.size()!=0 || hip.reassembler.active!=null)
            `uvm_fatal("RESET", "stale RX state survived reset")
        t=intel_test_mem(36,55); app.send(t);
        get_packet(hip,got); intel_test_equal(t,got);
        repeat(5) @(bus.monitor_cb);
        if(hip.received_packets!=1) `uvm_fatal("RESET", "aborted TLP replayed after reset")
        `uvm_info("RTILE_TEST_PASS", "half-packet reset abort, credit reinit and clean subsequent transfer",UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass
