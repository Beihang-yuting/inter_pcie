// 完整 env 的 bind 回归入口：复用公共测试和 sequence，通过两个 wrapper 连接真实 net。
// -top 必须使用 tb_intel_pcie_bind_env；默认测试顶层不会参与 elaboration。
-f $INTEL_PCIE_ROOT/sim/filelist_tests.f
$INTEL_PCIE_ROOT/bind/intel_pcie_bind_wrapper.sv
$INTEL_PCIE_ROOT/tests/bind/tb_intel_pcie_bind_env.sv
