// =============================================================================
// 文件: src/intel_pcie_params.svh
// 职责: Intel R-Tile Avalon-ST 适配层的编译期参数。
// 依赖: 无；由 filelist 在 pcie_work 的 package 之前包含。
// 生命周期: 仅在编译期展开，不产生仿真对象。
// =============================================================================

`ifndef INTEL_PCIE_PARAMS_SVH
`define INTEL_PCIE_PARAMS_SVH

// 默认配置对应 R-Tile 1x16 double-width：四个 256-bit segment。
`ifndef INTEL_PCIE_DATA_WIDTH
`define INTEL_PCIE_DATA_WIDTH 256
`endif

`ifndef INTEL_PCIE_SEGMENTS
`define INTEL_PCIE_SEGMENTS 4
`endif

`ifndef INTEL_PCIE_HEADER_BIG_ENDIAN
`define INTEL_PCIE_HEADER_BIG_ENDIAN 1
`endif

`endif
