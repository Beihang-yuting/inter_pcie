// =============================================================================
// 文件: tests/bind/tb_intel_pcie_bind_smoke.sv
// 职责: 提供两个使用 wire 用户侧引脚的 bind 目标，验证 HARD_IP/APPLICATION 的
//       所有权映射、time-0 config_db 发布以及 packed segment 连接。
// 依赖: intel_pcie_bind_wrapper_inout、intel_pcie_adapter_pkg、UVM。
// 生命周期: 测试模块独立产生时钟/复位并在 smoke 断言后结束；不创建 pcie_tl_env。
// =============================================================================
`timescale 1ns/1ps
`include "intel_pcie_params.svh"

// 验证模块只检查 bind wrapper 的 config_db 发布和网络方向，不创建 adapter。
import intel_pcie_adapter_pkg::*;
import uvm_pkg::*;

// HARD_IP 目标：DUT 驱动 TX/RX-credit，wrapper 应接管 RX、TX-ready 和 TX-credit。
// 目标引脚全部声明为 wire；DUT 输出侧使用连续赋值，inout wrapper 的
// SIDE 参数决定哪一组网络由 VIP 驱动。
module intel_pcie_bind_target_hard;
  localparam int DATA_WIDTH = `INTEL_PCIE_DATA_WIDTH;
  localparam int SEGMENTS = `INTEL_PCIE_SEGMENTS;
  localparam int DATA_PARITY_WORDS = DATA_WIDTH/32;
  logic clk = 0;
  logic rst_n = 0;
  always #1 clk = ~clk;
  initial #2 rst_n = 1;
  wire [SEGMENTS-1:0][DATA_WIDTH-1:0] rx_data;
  wire [SEGMENTS-1:0][127:0] rx_hdr;
  wire [SEGMENTS-1:0][31:0] rx_prefix;
  wire [SEGMENTS-1:0] rx_sop;
  wire [SEGMENTS-1:0] rx_eop;
  wire [SEGMENTS-1:0] rx_dvalid;
  wire [SEGMENTS-1:0] rx_hvalid;
  wire [SEGMENTS-1:0] rx_pvalid;
  wire [SEGMENTS-1:0][2:0] rx_empty;
  wire [SEGMENTS-1:0][2:0] rx_bar;
  wire [SEGMENTS-1:0][2:0] rx_pfnum;
  wire [SEGMENTS-1:0] rx_vfactive;
  wire [SEGMENTS-1:0][10:0] rx_vfnum;
  wire [SEGMENTS-1:0][DATA_PARITY_WORDS-1:0] rx_data_par;
  wire [SEGMENTS-1:0][3:0] rx_hdr_par;
  wire [SEGMENTS-1:0] rx_prefix_par;
  wire [SEGMENTS-1:0][DATA_WIDTH-1:0] tx_data;
  wire [SEGMENTS-1:0][127:0] tx_hdr;
  wire [SEGMENTS-1:0][31:0] tx_prefix;
  wire [SEGMENTS-1:0] tx_sop;
  wire [SEGMENTS-1:0] tx_eop;
  wire [SEGMENTS-1:0] tx_dvalid;
  wire [SEGMENTS-1:0] tx_hvalid;
  wire [SEGMENTS-1:0] tx_pvalid;
  wire [SEGMENTS-1:0][DATA_PARITY_WORDS-1:0] tx_data_par;
  wire [SEGMENTS-1:0][3:0] tx_hdr_par;
  wire [SEGMENTS-1:0] tx_prefix_par;
  wire rx_ready;
  wire tx_ready;
  wire [2:0] rx_hcrdt_init;
  wire [2:0] rx_hcrdt_init_ack;
  wire [2:0] rx_hcrdt_update;
  wire [5:0] rx_hcrdt_update_cnt;
  wire [2:0] rx_dcrdt_init;
  wire [2:0] rx_dcrdt_init_ack;
  wire [2:0] rx_dcrdt_update;
  wire [11:0] rx_dcrdt_update_cnt;
  wire [2:0] tx_hcrdt_init;
  wire [2:0] tx_hcrdt_init_ack;
  wire [2:0] tx_hcrdt_update;
  wire [5:0] tx_hcrdt_update_cnt;
  wire [2:0] tx_dcrdt_init;
  wire [2:0] tx_dcrdt_init_ack;
  wire [2:0] tx_dcrdt_update;
  wire [11:0] tx_dcrdt_update_cnt;

  // 这些是 DUT 的输出网络，wire 允许与参数化 inout wrapper 解析连接。
  assign tx_data = 'h1; assign tx_hdr = 'h1; assign tx_prefix = 'h1;
  assign tx_sop = 'h1; assign tx_eop = 'h1; assign tx_dvalid = 'h1;
  assign tx_hvalid = 'h1; assign tx_pvalid = 'h1; assign tx_data_par = 'h1;
  assign tx_hdr_par = 'h1; assign tx_prefix_par = 'h1; assign rx_ready = 'h1;
  assign rx_hcrdt_init = 'h1; assign rx_hcrdt_update = 'h1;
  assign rx_hcrdt_update_cnt = 'h1; assign rx_dcrdt_init = 'h1;
  assign rx_dcrdt_update = 'h1; assign rx_dcrdt_update_cnt = 'h1;
  assign tx_hcrdt_init_ack = 'h1; assign tx_dcrdt_init_ack = 'h1;
  // #0 等待 wrapper 完成同步发布；检查扁平 cfg 句柄与旧名称参数兼容，
  // 再等待一拍使连续赋值稳定后检查网络方向。
  initial begin
    intel_pcie_vif_t got_vif;
    intel_pcie_adapter_config got_cfg;
    #0;
    if (!uvm_config_db#(intel_pcie_vif_t)::get(null,
        "uvm_test_top.env.hard_adapter", "vif", got_vif) ||
        !uvm_config_db#(intel_pcie_adapter_config)::get(null,
        "uvm_test_top.env.hard_adapter", "intel_cfg", got_cfg))
        $fatal(1, "hard config_db publication failed");
    if (u_bind.cfg.side != INTEL_PCIE_HARD_IP ||
        got_cfg != u_bind.cfg)
        $fatal(1, "hard side not published");
    u_bind.cfg.check_parity = 1;
    if (!got_cfg.check_parity)
        $fatal(1, "direct cfg must be the published object");
    #1;
    if (u_bind.u_intel_pcie_if.tx_data !== tx_data ||
        u_bind.u_intel_pcie_if.rx_ready !== rx_ready)
        $fatal(1, "hard input mapping failed");
    u_bind.u_intel_pcie_if.tx_ready = 1'b1;
    #1;
    if (tx_ready !== 1'b1) $fatal(1, "hard output mapping failed");
    $display("[PCIE_BIND_SMOKE_PASS] hard ");
  end
endmodule

bind intel_pcie_bind_target_hard intel_pcie_bind_wrapper_inout #(
  .ADAPTER_PATH("uvm_test_top.env.hard_adapter"),
  .SIDE("HARD_IP")
) u_bind (.*);

// APPLICATION 目标：DUT 驱动 RX/TX-credit，wrapper 应接管 TX、RX-ready 和 RX-credit。
// 通过与 HARD_IP 相同的 wire 端口集合确认 SIDE 只改变所有权，不改变几何。
module intel_pcie_bind_target_application;
  localparam int DATA_WIDTH = `INTEL_PCIE_DATA_WIDTH;
  localparam int SEGMENTS = `INTEL_PCIE_SEGMENTS;
  localparam int DATA_PARITY_WORDS = DATA_WIDTH/32;
  logic clk = 0;
  logic rst_n = 0;
  always #1 clk = ~clk;
  initial #2 rst_n = 1;
  wire [SEGMENTS-1:0][DATA_WIDTH-1:0] rx_data;
  wire [SEGMENTS-1:0][127:0] rx_hdr;
  wire [SEGMENTS-1:0][31:0] rx_prefix;
  wire [SEGMENTS-1:0] rx_sop;
  wire [SEGMENTS-1:0] rx_eop;
  wire [SEGMENTS-1:0] rx_dvalid;
  wire [SEGMENTS-1:0] rx_hvalid;
  wire [SEGMENTS-1:0] rx_pvalid;
  wire [SEGMENTS-1:0][2:0] rx_empty;
  wire [SEGMENTS-1:0][2:0] rx_bar;
  wire [SEGMENTS-1:0][2:0] rx_pfnum;
  wire [SEGMENTS-1:0] rx_vfactive;
  wire [SEGMENTS-1:0][10:0] rx_vfnum;
  wire [SEGMENTS-1:0][DATA_PARITY_WORDS-1:0] rx_data_par;
  wire [SEGMENTS-1:0][3:0] rx_hdr_par;
  wire [SEGMENTS-1:0] rx_prefix_par;
  wire [SEGMENTS-1:0][DATA_WIDTH-1:0] tx_data;
  wire [SEGMENTS-1:0][127:0] tx_hdr;
  wire [SEGMENTS-1:0][31:0] tx_prefix;
  wire [SEGMENTS-1:0] tx_sop;
  wire [SEGMENTS-1:0] tx_eop;
  wire [SEGMENTS-1:0] tx_dvalid;
  wire [SEGMENTS-1:0] tx_hvalid;
  wire [SEGMENTS-1:0] tx_pvalid;
  wire [SEGMENTS-1:0][DATA_PARITY_WORDS-1:0] tx_data_par;
  wire [SEGMENTS-1:0][3:0] tx_hdr_par;
  wire [SEGMENTS-1:0] tx_prefix_par;
  wire rx_ready;
  wire tx_ready;
  wire [2:0] rx_hcrdt_init;
  wire [2:0] rx_hcrdt_init_ack;
  wire [2:0] rx_hcrdt_update;
  wire [5:0] rx_hcrdt_update_cnt;
  wire [2:0] rx_dcrdt_init;
  wire [2:0] rx_dcrdt_init_ack;
  wire [2:0] rx_dcrdt_update;
  wire [11:0] rx_dcrdt_update_cnt;
  wire [2:0] tx_hcrdt_init;
  wire [2:0] tx_hcrdt_init_ack;
  wire [2:0] tx_hcrdt_update;
  wire [5:0] tx_hcrdt_update_cnt;
  wire [2:0] tx_dcrdt_init;
  wire [2:0] tx_dcrdt_init_ack;
  wire [2:0] tx_dcrdt_update;
  wire [11:0] tx_dcrdt_update_cnt;

  // APPLICATION DUT 输出 RX/tx_ready/TX-credit，均为 wire 网络驱动。
  assign rx_data = 'h0; assign rx_hdr = 'h0; assign rx_prefix = 'h0;
  assign rx_sop = 'h0; assign rx_eop = 'h0; assign rx_dvalid = 'h0;
  assign rx_hvalid = 'h0; assign rx_pvalid = 'h0; assign rx_empty = 'h0;
  assign rx_bar = 'h0; assign rx_pfnum = 'h0; assign rx_vfactive = 'h0;
  assign rx_vfnum = 'h0; assign rx_data_par = 'h0; assign rx_hdr_par = 'h0;
  assign rx_prefix_par = 'h0; assign tx_ready = 'h0;
  assign rx_hcrdt_init_ack = 'h0; assign rx_dcrdt_init_ack = 'h0;
  assign tx_hcrdt_init = 'h0; assign tx_hcrdt_update = 'h0;
  assign tx_hcrdt_update_cnt = 'h0; assign tx_dcrdt_init = 'h0;
  assign tx_dcrdt_update = 'h0; assign tx_dcrdt_update_cnt = 'h0;
  // APPLICATION 的检查同时确认 wrapper 驱动 TX 数据和 RX ready，未拥有信号保持 DUT 值。
  initial begin
    intel_pcie_vif_t got_vif;
    intel_pcie_adapter_config got_cfg;
    #0;
    if (!uvm_config_db#(intel_pcie_vif_t)::get(null,
        "uvm_test_top.env.application_adapter", "vif", got_vif) ||
        !uvm_config_db#(intel_pcie_adapter_config)::get(null,
        "uvm_test_top.env.application_adapter", "intel_cfg", got_cfg))
        $fatal(1, "application config_db publication failed");
    if (u_bind.cfg.side != INTEL_PCIE_APPLICATION ||
        got_cfg != u_bind.cfg)
        $fatal(1, "application side not published");
    if (got_cfg.get_name() != "application_adapter_cfg")
        $fatal(1, "legacy ADAPTER_NAME must still name cfg");
    #1;
    u_bind.u_intel_pcie_if.tx_data = 'h5678;
    u_bind.u_intel_pcie_if.rx_ready = 1'b1;
    #1;
    if (tx_data !== 'h5678 ||
        u_bind.u_intel_pcie_if.tx_ready !== tx_ready)
        $fatal(1, "application direction mapping failed");
    $display("[PCIE_BIND_SMOKE_PASS] application ");
  end
endmodule

bind intel_pcie_bind_target_application intel_pcie_bind_wrapper_inout #(
  .ADAPTER_NAME("application_adapter"),
  .ADAPTER_PATH("uvm_test_top.env.application_adapter"),
  .SIDE("APPLICATION")
) u_bind (.*);

// 顶层只负责拉起两个独立目标并结束仿真；不会调用 run_test，避免与 bind wrapper 生命周期耦合。
module tb_intel_pcie_bind_smoke;
  import uvm_pkg::*;
  logic clk = 0;
  logic rst_n = 0;
  always #1 clk = ~clk;
  initial begin #2 rst_n = 1; #5 $finish; end
  intel_pcie_bind_target_hard hard ();
  intel_pcie_bind_target_application application ();
endmodule
