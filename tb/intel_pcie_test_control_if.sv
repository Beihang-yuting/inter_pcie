// tb：测试独占的复位控制接口，不属于用户 DUT 端口。依赖 testbench 时钟。
// 初始复位由 top 调用 reset_cycles；后续复位只由 reset 测试调用，不并发驱动。
interface intel_pcie_test_control_if(input logic clk);
    logic rst_n = 0;

    // 在下降沿更新复位，跨指定数目的完整时钟；避免采样沿竞争。
    task reset_cycles(int cycles = 5);
        @(negedge clk);
        rst_n = 0;
        repeat (cycles) @(negedge clk);
        rst_n = 1;
    endtask
endinterface
