// tb：四段单端口回归顶层，依赖 UVM、接口、测试 package；只拥有时钟和初始复位。
// 两个 adapter 连接同一真实信号总线；没有 data 的 assign 回环，收发必须经过引脚。
module tb_intel_pcie;
    timeunit 1ns;
    timeprecision 1ps;
    import uvm_pkg::*;
    import intel_pcie_adapter_pkg::*;
    import intel_pcie_tests_pkg::*;

    bit clk = 0;
    always #1ns clk = ~clk;
    intel_pcie_test_control_if control(clk);
    intel_pcie_if # (INTEL_DATA_WIDTH, INTEL_SEGMENTS) bus(clk, control.rst_n);

    initial control.reset_cycles(8);
    initial begin
        uvm_config_db#(intel_pcie_vif_t)::set(null, "uvm_test_top*", "vif", bus);
        uvm_config_db#(virtual intel_pcie_test_control_if)::set(null, "uvm_test_top", "control", control);
        run_test();
    end
    // watchdog 必须 fatal，不能用普通 $finish 掩盖 send/credit 等待死锁。
    initial begin
        #1ms;
        $fatal(1, "R-Tile regression watchdog expired");
    end
endmodule
