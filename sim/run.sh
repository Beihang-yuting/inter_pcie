#!/usr/bin/env bash
# sim：VCS 编译/回归入口，依赖外部 pcie_work、host_mem 和已加载的 VCS/license。
# 产物仅写入 BUILD_DIR；失败日志保留。脚本不登录远端、不保存口令，必须在 .53 执行。
set -euo pipefail

task_ips=" $(hostname -I) "
if [[ "$task_ips" != *" 10.11.10.53 "* ]]; then
    echo "Simulation must run on 10.11.10.53; load ~/.bashrc first." >&2
    exit 2
fi
export INTEL_PCIE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PCIE_WORK_ROOT="${PCIE_WORK_ROOT:-$INTEL_PCIE_ROOT/../pcie_work}"
export HOST_MEM_ROOT="${HOST_MEM_ROOT:-$INTEL_PCIE_ROOT/../host_mem}"
task_build="${BUILD_DIR:-$INTEL_PCIE_ROOT/sim/build}"
mkdir -p "$task_build/logs"
task_build="$(cd "$task_build" && pwd)"

for task_file in "$PCIE_WORK_ROOT/pcie_tl_vip/src/pcie_tl_pkg.sv" "$HOST_MEM_ROOT/src/host_mem_pkg.sv"; do
    [[ -f "$task_file" ]] || { echo "Missing dependency: $task_file" >&2; exit 2; }
done
cd "$task_build"
if [[ "${SKIP_COMPILE:-0}" != 1 ]]; then
    vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
        -top tb_intel_pcie -f "$INTEL_PCIE_ROOT/sim/filelist_tests.f" \
        -Mdir="$task_build/csrc" -o "$task_build/simv" \
        -l "$task_build/logs/compile.log" \
        "+define+INTEL_PCIE_DATA_WIDTH=${DATA_WIDTH:-256}" \
        "+define+INTEL_PCIE_SEGMENTS=${SEGMENTS:-4}"
fi

if [[ $# -eq 0 ]]; then
    set -- intel_pcie_codec_test intel_pcie_reassembly_test intel_pcie_transport_test \
        intel_pcie_rx_gap_test intel_pcie_tx_ready_test intel_pcie_tx_ready16_test \
        intel_pcie_ready_toggle_test \
        intel_pcie_credit_test intel_pcie_data_credit_test intel_pcie_credit_init_test \
        intel_pcie_reset_test intel_pcie_env_test
fi
for task_test in "$@"; do
    task_log="$task_build/logs/${task_test}.log"
    ./simv "+UVM_TESTNAME=$task_test" "+ntb_random_seed=${SEED:-1}" \
        +UVM_VERBOSITY=UVM_LOW -l "$task_log"
    # UVM 默认可在有 ERROR 时仍返回0；同时检查报告计数和场景完成标记。
    python3 - "$task_log" <<'PY'
import re
import sys
from pathlib import Path

log = Path(sys.argv[1]).read_text(errors="replace")
for level in ("ERROR", "FATAL"):
    counts = re.findall(r"UVM_" + level + r"\s*:\s*(\d+)", log)
    if not counts or any(int(value) for value in counts):
        raise SystemExit(f"FAIL {sys.argv[1]}: UVM_{level} report")
if "[RTILE_TEST_PASS]" not in log:
    raise SystemExit(f"FAIL {sys.argv[1]}: scenario did not finish")
print(f"PASS {sys.argv[1]}")
PY
done
