// tests：独立验证 Data credit 不足、RX 32-credit 门槛和有限/无限初始化。
// 依赖 pair_test 与 credit_manager；运行态流控通过真实引脚往返，初始化测试则
// 手工核对逐拍输出，避免只通过两份相同实现互相收发而漏掉协议单位错误。

// Header 空间充足时单独耗尽 Data，证明两类门控独立且归还必须经过 receive。
class intel_pcie_data_credit_test extends intel_pcie_pair_test;
    `uvm_component_utils(intel_pcie_data_credit_test)

    // 两个 adapter 由基类拥有；本类只创建测试流量和观察信用恢复。
    function new(string name="intel_pcie_data_credit_test", uvm_component parent=null);
        super.new(name,parent);
    endfunction

    // 两侧各提供64个 Posted Data credit，可接收两包384B，第三包必须等待。
    function void configure();
        app_cfg.data_capacity[0]=64;
        hip_cfg.data_capacity[0]=64;
    endfunction

    // 保持前两包不出队；核对 Header 仍充足、Data 只剩16，然后逐包取出恢复。
    // sent_packets 跨场景累计，所以比较本次增量而不是假设初始统计为零。
    task check_data_limit(intel_pcie_if_adapter source, intel_pcie_if_adapter sink);
        pcie_tl_tlp batch[$], got;
        bit finished=0;
        longint unsigned sent_before=source.sent_packets;
        for(int i=0;i<3;i++) batch.push_back(intel_test_mem(384,i+41));
        fork
            begin source.send_batch(batch); finished=1; end
            begin
                wait(sink.rx_queue.size()==2);
                repeat(8) @(bus.monitor_cb);
                if(finished || source.sent_packets-sent_before!=2 ||
                   source.credits.havailable[0]!=14 || source.credits.davailable[0]!=16 ||
                   sink.credits.hused[0]!=2 || sink.credits.dused[0]!=48)
                    `uvm_fatal("DATA_CREDIT", "Data exhaustion was not independent of Header credits")
                get_packet(sink,got); intel_test_equal(batch[0],got);
                wait(sink.rx_queue.size()==2);
                get_packet(sink,got); intel_test_equal(batch[1],got);
                get_packet(sink,got); intel_test_equal(batch[2],got);
            end
        join
        repeat(12) @(bus.monitor_cb);
        if(source.credits.havailable[0]!=16 || source.credits.davailable[0]!=64 ||
           sink.credits.hused[0]!=0 || sink.credits.dused[0]!=0)
            `uvm_fatal("DATA_CREDIT", "Data credits failed to return exactly once")
    endtask

    // 再构造剩余31个信用但下一包仅需1个的场景，单独命中 RX 的32-credit 门槛。
    task run_phase(uvm_phase phase);
        pcie_tl_tlp batch[$], got;
        bit finished=0;
        phase.raise_objection(this);
        wait_initialized();
        check_data_limit(hip,app);
        check_data_limit(app,hip);
        batch.push_back(intel_test_mem(528,61));
        batch.push_back(intel_test_mem(4,62));
        fork
            begin hip.send_batch(batch); finished=1; end
            begin
                wait(app.rx_queue.size()==1);
                repeat(8) @(bus.monitor_cb);
                if(finished || hip.credits.davailable[0]!=31 ||
                   hip.credits.havailable[0]!=15)
                    `uvm_fatal("RX_THRESHOLD", "RX started a TLP below the 32-credit threshold")
                get_packet(app,got); intel_test_equal(batch[0],got);
                get_packet(app,got); intel_test_equal(batch[1],got);
            end
        join
        repeat(12) @(bus.monitor_cb);
        if(hip.credits.davailable[0]!=64 || hip.credits.havailable[0]!=16)
            `uvm_fatal("RX_THRESHOLD", "credit counts did not recover after the threshold stall")
        `uvm_info("RTILE_TEST_PASS", "bidirectional Data exhaustion, RX 32-credit gate and exact credit return",UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass

// 不依赖 adapter 生成源流量，直接观察初始化输出以校验 ACK、增量和两个空拍。
class intel_pcie_credit_init_test extends uvm_test;
    `uvm_component_utils(intel_pcie_credit_init_test)

    // 所有 manager/config 仅在当前 run_phase 存活，不访问 testbench 引脚。
    function new(string name="intel_pcie_credit_init_test", uvm_component parent=null);
        super.new(name,parent);
    endfunction

    // P=有限Header/无限Data，NP=无限Header/有限Data，CPL=全有限。
    // 运行期 update=1/count=0 不得误置 infinite；无效计数允许 X。
    task run_phase(uvm_phase phase);
        intel_pcie_adapter_config cfg=new("cfg");
        intel_pcie_credit_manager sink=new("sink"), source=new("source");
        intel_pcie_credit_pins_t p;
        intel_pcie_packet pkt=new("packet");
        int hsum[3]='{0,0,0}, dsum[3]='{0,0,0};
        int hzero[3]='{0,0,0}, dzero[3]='{0,0,0};
        int last_update=-1, ended=-1;

        phase.raise_objection(this);
        cfg.header_capacity='{2,7,5}; cfg.data_capacity='{64,48,35};
        cfg.infinite_data[0]=1; cfg.infinite_header[1]=1;
        cfg.validate(); sink.cfg=cfg; source.cfg=cfg; sink.reset(); source.reset();
        // 尚未得到 ACK 时仅发 init，不能抢先公告容量。
        repeat(3) begin
            p=sink.drive_local(0,0);
            if(p.hinit!==3'b111 || p.dinit!==3'b111 || p.hupdate!=0 || p.dupdate!=0)
                `uvm_fatal("CREDIT_INIT", "credit advertisement preceded ACK")
            source.sample_remote(p);
        end
        for(int cycle=0;cycle<20;cycle++) begin
            p=sink.drive_local(3'b111,3'b111);
            if(|p.hupdate || |p.dupdate) last_update=cycle;
            for(int c=0;c<3;c++) begin
                if(p.hupdate[c]) begin
                    hsum[c]+=int'(p.hcnt[2*c +: 2]);
                    if(p.hcnt[2*c +: 2]==0) hzero[c]++;
                end
                if(p.dupdate[c]) begin
                    dsum[c]+=int'(p.dcnt[4*c +: 4]);
                    if(p.dcnt[4*c +: 4]==0) dzero[c]++;
                end
            end
            source.sample_remote(p);
            if(p.hinit==0 && p.dinit==0) begin ended=cycle; break; end
        end
        if(ended<0 || ended-last_update<3 ||
           hsum[0]!=2 || hsum[1]!=0 || hsum[2]!=5 ||
           dsum[0]!=0 || dsum[1]!=48 || dsum[2]!=35 ||
           hzero[0]!=0 || hzero[1]!=1 || hzero[2]!=0 ||
           dzero[0]!=1 || dzero[1]!=0 || dzero[2]!=0)
            `uvm_fatal("CREDIT_INIT", "incorrect capacities, infinite encoding or final idle separation")
        if(!source.dinfinite[0] || !source.hinfinite[1] ||
           source.hinfinite[0] || source.dinfinite[1] || source.hinfinite[2] || source.dinfinite[2])
            `uvm_fatal("CREDIT_INIT", "six credit categories were not independent")
        pkt.category=0; pkt.expected_bytes=4096;
        repeat(2) begin
            if(!source.can_send(pkt)) `uvm_fatal("CREDIT_INIT", "infinite data was treated as zero space")
            source.reserve_remote(pkt);
        end
        if(source.can_send(pkt)) `uvm_fatal("CREDIT_INIT", "infinite data bypassed finite Header limit")
        p='0; p.hcnt='x; p.dcnt='x;
        source.sample_remote(p);
        p='0; p.hupdate[2]=1; p.dupdate[2]=1;
        source.sample_remote(p);
        if(source.hinfinite[2] || source.dinfinite[2] ||
           source.havailable[2]!=5 || source.davailable[2]!=35)
            `uvm_fatal("CREDIT_INIT", "runtime zero update incorrectly advertised infinity")
        `uvm_info("RTILE_TEST_PASS", "ACK gating, split counts, two idle cycles and independent infinite credits",UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass
