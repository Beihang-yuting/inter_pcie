// tests：用手算 PCIe Header 常量验证字节序，再覆盖公共 TLP 类型的往返。
// 依赖测试 helper/产品 codec；不创建 adapter、不依赖 ready 或仿真硬核。
class intel_pcie_codec_test extends uvm_test;
    `uvm_component_utils(intel_pcie_codec_test)

    // 标准 UVM 注册构造，不保存跨测试状态。
    function new(string name = "intel_pcie_codec_test", uvm_component parent = null);
        super.new(name,parent);
    endfunction

    // 分别断言手算 DWORD 位置；typed Completion/Config/Prefix 使用公共 codec 交叉核对。
    task run_phase(uvm_phase phase);
        intel_pcie_avst_codec c = new("codec");
        intel_pcie_packet p;
        pcie_tl_mem_tlp m;
        pcie_tl_cpl_tlp cp;
        pcie_tl_cfg_tlp cf;
        pcie_tl_prefix prefix;
        intel_expected_error errors;
        int sizes[$] = '{0,4,28,32,36,64,128,132,4096};

        phase.raise_objection(this);
        m = intel_test_mem(36);
        p = c.encode(m);
        if (p.header !== 128'h60800009_1234abff_01234567_89abcdf0)
            `uvm_fatal("GOLDEN_HEADER", $sformatf("big Header mismatch: %032h",p.header))
        c.header_big_endian = 0;
        p = c.encode(m);
        if (p.header !== 128'h89abcdf0_01234567_1234abff_60800009)
            `uvm_fatal("GOLDEN_HEADER", $sformatf("little Header mismatch: %032h",p.header))
        for (int big = 0; big < 2; big++) begin
            c.header_big_endian = big;
            for (int four = 0; four < 2; four++) begin
                foreach (sizes[i]) begin
                    m = intel_test_mem(sizes[i], i, four);
                    p = c.encode(m);
                    intel_test_equal(m, c.decode(p));
                end
            end
            m = intel_test_mem(36);
            prefix = new("pasid"); prefix.raw_dw = 32'h91012345;
            m.prefixes.push_back(prefix); m.has_prefix = 1;
            p = c.encode(m);
            if (!p.prefix_valid || p.prefix !== 32'h91012345)
                `uvm_fatal("GOLDEN_PREFIX", "prefix endian mismatch")
            intel_test_equal(m,c.decode(p));

            cp = pcie_tl_cpl_tlp::type_id::create("completion");
            cp.kind = TLP_CPLD; cp.fmt = FMT_3DW_WITH_DATA; cp.type_f = TLP_TYPE_CPL;
            cp.length = 1; cp.byte_count = 4; cp.cpl_status = CPL_STATUS_SC;
            cp.requester_id = 16'h1234; cp.completer_id = 16'h0100; cp.tag = 10'h355;
            cp.payload = new[4]; cp.payload = '{8'h12,8'h34,8'h56,8'h78};
            intel_test_equal(cp,c.decode(c.encode(cp)));
            cf = pcie_tl_cfg_tlp::type_id::create("config_read");
            cf.kind = TLP_CFG_RD0; cf.type_f = TLP_TYPE_CFG_RD0; cf.fmt = FMT_3DW_NO_DATA;
            cf.length = 1; cf.first_be = 4'hf; cf.completer_id = 16'h0200;
            cf.reg_num = 10'h123; cf.requester_id = 16'h0030; cf.tag = 10'h101;
            intel_test_equal(cf,c.decode(c.encode(cf)));
        end
        // 负例验证不会静默截断第二个 Prefix 或发出 Length 不匹配的硬核输入。
        errors = new; errors.expected_id = "RTILE_LENGTH";
        uvm_report_cb::add(null,errors);
        m = intel_test_mem(36); m.length = 8; p = c.encode(m);
        if (p != null || errors.count != 1) `uvm_fatal("NEGATIVE", "missing Length rejection")
        uvm_report_cb::delete(null,errors);
        errors = new; errors.expected_id = "RTILE_CODEC";
        uvm_report_cb::add(null,errors);
        m = intel_test_mem(4); m.prefixes.push_back(prefix); m.prefixes.push_back(prefix);
        p = c.encode(m);
        if (p != null || errors.count != 1) `uvm_fatal("NEGATIVE", "missing multi-prefix rejection")
        uvm_report_cb::delete(null,errors);
        `uvm_info("RTILE_TEST_PASS", "golden Header/Prefix, 3DW/4DW, 4096B, typed TLP and negative codec cases", UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass
