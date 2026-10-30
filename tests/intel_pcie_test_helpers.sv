// tests：公共构包、比对和预期错误计数，依赖产品包与公共 pcie_tl_pkg。
// 只提供测试工具；golden 位域/时序测试仍手工构造，不能全靠 codec 往返自证。

// 创建有模式数据的 Memory TLP，nbytes=0 表示 MRd；不 randomize，结果可复现。
function automatic pcie_tl_mem_tlp intel_test_mem(int nbytes, int marker = 0,
                                                bit four_dw = 1);
    pcie_tl_mem_tlp t = pcie_tl_mem_tlp::type_id::create("memory");
    t.kind = nbytes ? TLP_MEM_WR : TLP_MEM_RD;
    t.type_f = TLP_TYPE_MEM_RD;
    t.fmt = four_dw ? (nbytes ? FMT_4DW_WITH_DATA : FMT_4DW_NO_DATA) :
                     (nbytes ? FMT_3DW_WITH_DATA : FMT_3DW_NO_DATA);
    t.is_64bit = four_dw;
    t.addr = four_dw ? 64'h0123456789abcdf0 : 64'h00001000;
    t.requester_id = 16'h1234;
    t.tag = 10'h2ab;
    t.length = nbytes ? 10'(nbytes/4) : 10'd1;
    t.first_be = 4'hf;
    t.last_be = (t.length == 1) ? 0 : 4'hf;
    t.payload = new[nbytes];
    foreach (t.payload[i]) t.payload[i] = 8'((i*37 + marker) ^ (i>>8));
    return t;
endfunction

// 比较全部编码 Header/Prefix/Payload（包含地址、tag、BE）；空返回直接 fatal。
function automatic void intel_test_equal(pcie_tl_tlp expected, pcie_tl_tlp actual);
    pcie_tl_codec c = new("compare_codec");
    bit [7:0] e[], a[];
    if (expected == null || actual == null) begin
        `uvm_fatal("TEST_COMPARE", "null TLP")
        return;
    end
    c.encode(expected, e); c.encode(actual, a);
    if (e.size() != a.size())
        `uvm_fatal("TEST_COMPARE", $sformatf("length expected=%0d actual=%0d", e.size(), a.size()))
    foreach (e[i])
        if (e[i] !== a[i])
            `uvm_fatal("TEST_COMPARE", $sformatf("byte %0d expected=%02x actual=%02x", i,e[i],a[i]))
endfunction

// 负例只捕获精确 ID，记录次数；未预期的其它 UVM_ERROR 仍会令回归失败。
class intel_expected_error extends uvm_report_catcher;
    string expected_id;
    int count;

    // 一个 catcher 只服务当前测试阶段；测试完成后必须移除并核对 count。
    function new(string name = "intel_expected_error");
        super.new(name);
    endfunction

    // 不更改报告的其它属性，仅吞掉测试明确要求触发的 ERROR。
    virtual function action_e catch();
        if (get_severity() == UVM_ERROR && get_id() == expected_id) begin
            count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass

// 实例级 adapter 回归基类：通过 factory 基类创建，证明没有绕过工厂替换路径。
class intel_pcie_pair_test extends uvm_test;
    `uvm_component_utils(intel_pcie_pair_test)
    intel_pcie_if_adapter hip, app;
    intel_pcie_adapter_config hip_cfg, app_cfg;
    intel_pcie_vif_t bus;
    virtual intel_pcie_test_control_if control;

    // UVM test 拥有两 adapter、各自 config；interface 由 top 拥有。
    function new(string name = "intel_pcie_pair_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // 派生测试在创建组件之前改容量/时序选项，不在发包中改变接口几何参数。
    virtual function void configure();
    endfunction

    // 构建同一端口的两侧，不克隆/修改外部 pcie_work 源码。
    function void build_phase(uvm_phase phase);
        pcie_tl_if_adapter h, a;
        super.build_phase(phase);
        hip_cfg = new("hip_cfg"); app_cfg = new("app_cfg");
        hip_cfg.side = INTEL_PCIE_HARD_IP; app_cfg.side = INTEL_PCIE_APPLICATION;
        hip_cfg.check_parity = 1; app_cfg.check_parity = 1;
        configure();
        pcie_tl_if_adapter::type_id::set_type_override(intel_pcie_if_adapter::get_type());
        uvm_config_db#(intel_pcie_adapter_config)::set(this, "rc_adapter", "intel_cfg", hip_cfg);
        uvm_config_db#(intel_pcie_adapter_config)::set(this, "ep_adapter", "intel_cfg", app_cfg);
        h = pcie_tl_if_adapter::type_id::create("rc_adapter", this);
        a = pcie_tl_if_adapter::type_id::create("ep_adapter", this);
        if (!$cast(hip,h) || !$cast(app,a)) `uvm_fatal("TEST_FACTORY", "factory override failed")
        if (!uvm_config_db#(intel_pcie_vif_t)::get(this,"","vif",bus))
            `uvm_fatal("TEST_VIF", "missing bus")
        if (!uvm_config_db#(virtual intel_pcie_test_control_if)::get(this,"","control",control))
            `uvm_fatal("TEST_VIF", "missing reset control")
    endfunction

    // 等待双方公布完整信用；watchdog 防止 init/ACK 接反造成无限等待。
    task wait_initialized();
        wait (app.running && hip.running && !app.in_reset && !hip.in_reset);
        wait (app.credits.hready[0] && hip.credits.hready[0] &&
              app.credits.dready[0] && hip.credits.dready[0]);
        repeat (2) @(bus.monitor_cb);
    endtask

    // 同步等到包入队，再使用非阻塞 receive；归还的信用仍需经过总线更新。
    task get_packet(intel_pcie_if_adapter adapter, output pcie_tl_tlp t);
        wait (adapter.rx_queue.size() != 0);
        adapter.receive(t);
        if (t == null) `uvm_fatal("TEST_RECEIVE", "receive unexpectedly returned null")
    endtask
endclass
