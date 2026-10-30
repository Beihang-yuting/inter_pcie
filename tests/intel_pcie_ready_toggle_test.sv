// tests：反复拉低/恢复TX ready，验证多次“对端未准备好”不会重复Header或Payload。
// 依赖pair_test，HIP侧独占ready；独立raw-pin计数器逐字节验证，不通过codec自证时序。
class intel_pcie_ready_toggle_test extends intel_pcie_pair_test;
    `uvm_component_utils(intel_pcie_ready_toggle_test)

    // 两侧BFM由基类创建；本类仅提供有界的压力序列和观测状态。
    function new(string name="intel_pcie_ready_toggle_test", uvm_component parent=null);
        super.new(name,parent);
    endfunction

    // 五次4拍低/3拍高均发生在4096B同一包中；每次停发1拍、恢复至多1拍。
    task run_phase(uvm_phase phase);
        pcie_tl_tlp t, got;
        int offset=0, pulses=0, low_cycles=0, resume_wait=0, nsop=0;
        bit finished=0, started=0, prior_ready=1, awaiting_resume=0;

        phase.raise_objection(this);
        wait_initialized();
        t=intel_test_mem(4096,173);
        fork
            app.send(t);
            begin
                do @(bus.monitor_cb); while (!(|bus.monitor_cb.tx_sop));
                repeat(5) begin
                    hip.set_tx_ready(0);
                    repeat(4) @(bus.monitor_cb);
                    hip.set_tx_ready(1);
                    repeat(3) @(bus.monitor_cb);
                end
            end
            begin
                while(!finished) begin
                    @(bus.monitor_cb);
                    if(|bus.monitor_cb.tx_sop) begin started=1; nsop++; end
                    if(!started) continue;
                    if(!bus.monitor_cb.tx_ready) begin
                        if(prior_ready) pulses++;
                        low_cycles++;
                        awaiting_resume=1; resume_wait=0;
                        if(low_cycles>1 && (|bus.monitor_cb.tx_dvalid))
                            `uvm_fatal("TX_TOGGLE", "configured one-cycle stop latency exceeded")
                    end else begin
                        low_cycles=0;
                        if(awaiting_resume) begin
                            if(|bus.monitor_cb.tx_dvalid) awaiting_resume=0;
                            else resume_wait++;
                            if(resume_wait>1) `uvm_fatal("TX_TOGGLE", "late resume during repeated backpressure")
                        end
                    end
                    prior_ready=bus.monitor_cb.tx_ready;
                    for(int s=0;s<INTEL_SEGMENTS;s++) begin
                        if(bus.monitor_cb.tx_dvalid[s]) begin
                            for(int b=0;b<INTEL_DATA_BYTES && offset<t.payload.size();b++) begin
                                if(bus.monitor_cb.tx_data[s][8*b +: 8]!==t.payload[offset])
                                    `uvm_fatal("TX_TOGGLE", $sformatf("drop/replay at byte %0d",offset))
                                offset++;
                            end
                        end
                        if(bus.monitor_cb.tx_eop[s]) finished=1;
                    end
                end
            end
        join
        get_packet(hip,got); intel_test_equal(t,got);
        if(offset!=4096 || pulses!=5 || nsop!=1 || awaiting_resume)
            `uvm_fatal("TX_TOGGLE", "did not cover five complete pauses within one TLP")
        `uvm_info("RTILE_TEST_PASS", "five TX ready low/high intervals, exact bytes and timely continuation",UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass
