// AIP 为可选依赖；仅此回归入口启用，产品库仍可单独编译。
// AIP_CORE_ROOT 应指向支持 128 位/位置参数的 aip_core update 工作树。
+incdir+$AIP_CORE_ROOT
+incdir+$AIP_CORE_ROOT/src/sv
$AIP_CORE_ROOT/src/sv/aip_core_pkg.sv
-f $INTEL_PCIE_ROOT/sim/filelist_bind_env.f
$INTEL_PCIE_ROOT/tests/aip/intel_pcie_aip_reg_test.sv
