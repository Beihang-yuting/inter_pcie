// tb：只发布 virtual interface 的连接宏，依赖 UVM 和 intel_pcie_adapter_pkg。
// 每条总线最多连接一个 APPLICATION 和一个 HARD_IP，连接宏不决定信号方向。
// PATH 为明确层次路径，支持 rc_adapter_<n>/ep_adapter_<n>，不使用跨端口通配。
`ifndef INTEL_PCIE_ADAPTER_CONNECT_SVH
`define INTEL_PCIE_ADAPTER_CONNECT_SVH
`define INTEL_PCIE_ADAPTER_CONNECT(PATH, BUS) \
    uvm_config_db#(intel_pcie_adapter_pkg::intel_pcie_vif_t)::set(null, PATH, "vif", BUS);
`endif
