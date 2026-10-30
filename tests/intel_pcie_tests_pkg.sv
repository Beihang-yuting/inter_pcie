// tests：统一测试注册入口；依赖已编译的 UVM、pcie_tl_pkg、Intel adapter 和控制接口。
// 仅 include 测试类，不进入产品库 filelist；测试创建的对象不影响其它仿真进程。
package intel_pcie_tests_pkg;
    import uvm_pkg::*;
    import host_mem_pkg::*;
    import pcie_tl_pkg::*;
    import intel_pcie_adapter_pkg::*;
    `include "uvm_macros.svh"
    `include "intel_pcie_test_helpers.sv"
    `include "intel_pcie_codec_test.sv"
    `include "intel_pcie_reassembly_test.sv"
    `include "intel_pcie_transport_test.sv"
    `include "intel_pcie_ready_toggle_test.sv"
    `include "intel_pcie_credit_edges_test.sv"
    `include "intel_pcie_env_test.sv"
    `include "intel_pcie_env_stress_test.sv"
endpackage
