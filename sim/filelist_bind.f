// 独立 bind smoke 编译入口；不并入默认 sim/filelist_tests.f，避免没有 DUT bind 点时影响普通回归。
-f $INTEL_PCIE_ROOT/sim/filelist_lib.f
$INTEL_PCIE_ROOT/bind/intel_pcie_bind_wrapper.sv
$INTEL_PCIE_ROOT/tests/bind/tb_intel_pcie_bind_smoke.sv
