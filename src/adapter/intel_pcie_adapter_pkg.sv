// src/adapter：唯一 UVM 编译入口；interface 必须在本 package 之前编译。
// 依赖外部 pcie_work/pcie_tl_pkg 和 UVM，不复制其 agent、sequence 或 TLP 类。
// 常量共享，所有运行状态由 adapter 实例拥有；支持同一几何配置下多独立端口。
`include "intel_pcie_params.svh"
package intel_pcie_adapter_pkg;
    import uvm_pkg::*;
    import pcie_tl_pkg::*;
    `include "uvm_macros.svh"

    localparam int INTEL_DATA_WIDTH = `INTEL_PCIE_DATA_WIDTH;
    localparam int INTEL_SEGMENTS = `INTEL_PCIE_SEGMENTS;
    localparam int INTEL_DATA_BYTES = INTEL_DATA_WIDTH / 8;
    typedef virtual intel_pcie_if #(INTEL_DATA_WIDTH, INTEL_SEGMENTS) intel_pcie_vif_t;

    `include "intel_pcie_types.sv"
    `include "codec/intel_pcie_avst_codec.sv"
    `include "codec/intel_pcie_reassembler.sv"
    `include "adapter/intel_pcie_credit_manager.sv"
    `include "adapter/intel_pcie_if_adapter.sv"
endpackage
