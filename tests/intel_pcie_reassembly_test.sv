// tests：手工构造图31与非连续 valid 波形，独立于产品发送打包器。
// reassembler 由测试独占；检查 Header-only、同拍三包、完整 11-bit VF 和非法帧。
class intel_pcie_reassembly_test extends uvm_test;
    `uvm_component_utils(intel_pcie_reassembly_test)

    // 标准 UVM 构造，状态在 run_phase 内创建并销毁。
    function new(string name = "intel_pcie_reassembly_test", uvm_component parent = null);
        super.new(name,parent);
    endfunction

    // 使用递增原始字节填满一个 segment，方便独立核对跨段/跨拍拼接顺序。
    function void fill_data(ref intel_pcie_beat_t b, input int s, input int offset);
        for (int i = 0; i < INTEL_DATA_BYTES; i++) b.data[s][i*8 +: 8] = 8'(offset+i);
        b.dvalid[s] = 1;
    endfunction

    // 断言完整 packet 字节数量和顺序，避免仅检查包数而漏掉数据重复/丢失。
    function void check_payload(intel_pcie_packet p, int count);
        if (p.payload.size() != count) `uvm_fatal("FIG31", "unexpected Payload length")
        foreach (p.payload[i])
            if (p.payload[i] !== 8'(i)) `uvm_fatal("FIG31", "Payload reordered/dropped")
    endfunction

    // 固定图31要求4x256；其他几何配置由独立 transport 测试验证。
    task run_phase(uvm_phase phase);
        intel_pcie_reassembler r = new("reassembler");
        intel_pcie_avst_codec c = new("codec");
        intel_pcie_adapter_config cfg = new("cfg");
        intel_pcie_packet started[$], done[$];
        intel_pcie_beat_t b;
        intel_expected_error errors;
        pcie_tl_tlp t;
        // 类会随整个tests package在小几何配置中注册，但本场景只在4x256运行。
        // 使用运行期索引避免对已经由下方geometry检查排除的fixture静态报越界。
        int st1=1, st2=2, st3=3;

        phase.raise_objection(this);
        if (INTEL_SEGMENTS != 4 || INTEL_DATA_WIDTH != 256)
            `uvm_fatal("TEST_GEOMETRY", "Figure31 test requires 4x256")
        r.codec = c; r.cfg = cfg;
        b = '0;
        b.sop[st1] = 1; b.hvalid[st1] = 1;
        b.hdr[st1] = 128'h40000009_123400ff_00001000_00000000;
        b.vfactive[st1] = 1; b.vfnum[st1] = 11'h5a3; b.pfnum[st1] = 3; b.bar[st1] = 2;
        fill_data(b,1,0); fill_data(b,2,32);
        b.eop[st2] = 1; b.empty[st2] = 7;
        r.consume(b,0,1,started,done);
        if (done.size()!=1) `uvm_fatal("FIG31", "T0 not completed")
        check_payload(done[0],36);
        t = c.decode(done[0]);
        if (t.cq_route.vf_index != 11'h5a3 || t.cq_route.pf_index != 3 || t.cq_route.valid)
            `uvm_fatal("METADATA", "VF truncated or incomplete BAR route marked valid")

        b = '0; b.sop[st1] = 1; b.hvalid[st1] = 1;
        b.hdr[st1] = 128'h4000001b_123400ff_00001000_00000000;
        fill_data(b,1,0); fill_data(b,2,32); fill_data(b,3,64);
        r.consume(b,0,1,started,done);
        if (done.size()!=0 || r.active==null) `uvm_fatal("FIG31", "T1 ended early")
        // 包内整拍空闲甚至无效 SOP/EOP 噪声均不能删除半包。
        b = '0; b.sop = '1; b.eop = '1;
        repeat (3) r.consume(b,0,1,started,done);
        b = '0; fill_data(b,0,96); b.eop[0] = 1; b.empty[0] = 5;
        r.consume(b,0,1,started,done);
        if (done.size()!=1) `uvm_fatal("FIG31", "T1 not completed after gap")
        check_payload(done[0],108);

        // 三个无数据 MRd 同拍开始且结束，dvalid 全零仍必须交付三个包。
        b = '0;
        for (int s = 0; s < 3; s++) begin
            b.sop[s] = 1; b.eop[s] = 1; b.hvalid[s] = 1;
            b.hdr[s] = {32'h00000001,32'h1234000f+32'(s<<8),32'h00001000,32'h0};
        end
        r.consume(b,0,1,started,done);
        if (done.size()!=3) `uvm_fatal("MULTIPACKET", "header-only TLPs lost")
        foreach (done[i]) begin
            t = c.decode(done[i]);
            if (t.tag != i || t.payload.size()!=0) `uvm_fatal("MULTIPACKET", "wrong order")
        end
        // st3 也可作为 RX SOP 起点，尾段回绕到下一拍 st0。
        b = '0;
        // st0 同时有一个完整无数据包，满足量产器件不能仅使用 st2/st3 的约束。
        b.sop[0]=1; b.eop[0]=1; b.hvalid[0]=1;
        b.hdr[0]=128'h00000001_1234000f_00001000_00000000;
        b.sop[st3]=1; b.hvalid[st3]=1;
        b.hdr[st3]=128'h40000009_123400ff_00001000_00000000; fill_data(b,3,0);
        r.consume(b,0,1,started,done);
        b='0; fill_data(b,0,32); b.eop[0]=1; b.empty[0]=7;
        r.consume(b,0,1,started,done); check_payload(done[0],36);

        errors = new; errors.expected_id="RTILE_LENGTH";
        uvm_report_cb::add(null,errors);
        b='0; b.sop[0]=1; b.hvalid[0]=1; b.eop[0]=1;
        b.hdr[0]=128'h40000009_123400ff_00001000_00000000;
        fill_data(b,0,0);
        r.consume(b,0,1,started,done);
        if (errors.count!=1 || done.size()!=0) `uvm_fatal("NEGATIVE", "early EOP accepted")
        uvm_report_cb::delete(null,errors);

        // 总线X不能被packet的2-state字段静默吞掉；3DW未用DWORD和末段padding
        // 则允许don't-care。这个独立raw-pin例子不依赖发送器默认填零的行为。
        errors=new; errors.expected_id="RTILE_CONTENT_X";
        uvm_report_cb::add(null,errors);
        b='0; b.sop[0]=1; b.hvalid[0]=1; b.eop[0]=1;
        b.hdr[0]=128'h00000001_1234000f_00001000_00000000;
        b.hdr[0][127]=1'bx;
        r.consume(b,0,1,started,done);
        if(errors.count!=1 || done.size()!=0) `uvm_fatal("NEGATIVE", "unknown Header accepted")
        b.hdr[0]=128'h40000001_1234000f_00001000_xxxxxxxx;
        b.dvalid[0]=1; b.empty[0]=7; b.data[0]='x;
        r.consume(b,0,1,started,done);
        if(errors.count!=2 || done.size()!=0) `uvm_fatal("NEGATIVE", "unknown Payload accepted")
        b.data[0][31:0]=32'h03020100;
        r.consume(b,0,1,started,done);
        if(errors.count!=2 || done.size()!=1) `uvm_fatal("NEGATIVE", "unused bytes rejected")
        check_payload(done[0],4);
        uvm_report_cb::delete(null,errors);
        `uvm_info("RTILE_TEST_PASS", "Figure31, gaps, three SOPs, st3 wrap, metadata, malformed EOP and X checks", UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass
