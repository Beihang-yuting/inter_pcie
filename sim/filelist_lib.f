// 库编译入口；路径环境变量由调用者设置，不依赖 /tmp 或机器名。
// HOST_MEM_ROOT 为独立 host_mem 仓库，package 自行 include manager，不能重复编译。
+incdir+$HOST_MEM_ROOT/src
$HOST_MEM_ROOT/src/host_mem_pkg.sv
+incdir+$PCIE_WORK_ROOT/pcie_tl_vip/src
+incdir+$PCIE_WORK_ROOT/pcie_tl_vip/src/topology
$PCIE_WORK_ROOT/pcie_tl_vip/src/pcie_tl_if.sv
$PCIE_WORK_ROOT/pcie_tl_vip/src/shared/pcie_tl_bdf_utils_pkg.sv
$PCIE_WORK_ROOT/pcie_tl_vip/src/shared/pcie_tl_device_profile_pkg.sv
$PCIE_WORK_ROOT/pcie_tl_vip/src/topology/pcie_topology_pkg.sv
$PCIE_WORK_ROOT/pcie_tl_vip/src/pcie_tl_pkg.sv
+incdir+$INTEL_PCIE_ROOT/src
$INTEL_PCIE_ROOT/src/interface/intel_pcie_if.sv
$INTEL_PCIE_ROOT/src/adapter/intel_pcie_adapter_pkg.sv
