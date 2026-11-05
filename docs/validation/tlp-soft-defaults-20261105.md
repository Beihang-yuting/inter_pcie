# `pcie_tl_tlp` error-injection soft-default VCS validation

本报告随源码提交；文中命令、日志、哈希清单的相对路径均指向本地 `sim/build/logs/tlp_soft_defaults_20261105/`。原始仿真产物保留在该目录，不随仓库发布。

## Environment and frozen input

- Host: `ubuntu@10.11.10.53`
- VCS: `W-2024.09-SP1_Full64`
- Isolated tree: `/tmp/pcie_tlp_soft_defaults_20261105.a9NPqm`
- Input manifest: 144 files from `pcie_tl_vip`, `host_mem`, and `pcie_intel`
- The frozen directed test is the final version with `int checks = 0`; its SHA-256 is `20fa980fbb61b6b9a4af08ce58eadddc49e441478d5509c16a148632a0bba26f`.
- Remote `sha256sum -c source.sha256` passed for every file.
- Post-sync `rsync -aniO --checksum` produced no output (`rsync_verify.txt` is empty).

## Process status and UVM totals

| Item | Process rc | UVM INFO | UVM WARNING | UVM ERROR | UVM FATAL | Result |
|---|---:|---:|---:|---:|---:|---|
| Public TL compile | 0 | — | — | — | — | PASS |
| Intel bind compile | 0 | — | — | — | — | PASS |
| Injection defaults, seed 1 | 0 | 4 | 0 | 0 | 0 | PASS |
| Injection defaults, seed 2 | 0 | 4 | 0 | 0 | 0 | PASS |
| Injection defaults, seed 3 | 0 | 4 | 0 | 0 | 0 | PASS |
| `pcie_tl_virtio_fix_unit_test`, seed 1 | 0 | 8 | 0 | 0 | 0 | PASS |
| `intel_pcie_env_test`, seed 1 | 0 | 11 | 0 | 0 | 0 | PASS |
| `intel_pcie_env_stress_test`, seed 1 | 0 | 174 | 0 | 0 | 0 | PASS |

All entries in `run_status.tsv` are zero. The simulator logs, rather than the `simv` return codes alone, establish the run results above.

## Directed default and override contract

Each of seeds 1, 2, and 3 emitted exactly one:

```text
[INJECT_DEFAULTS_DONE] completed 338 exact field/mode checks
```

The 338 checks cover base, Memory, and Completion TLP objects under default, explicit LEGAL, ILLEGAL, and CORNER_CASE modes. They verify six zero defaults, each single-field inline override with all other error metadata still zero, recovery to zero on the next randomization, and the LEGAL default mode. The same test also starts and captures the production poisoned and malformed sequences. All three runs have zero UVM warning/error/fatal reports.

## Existing behavior

`pcie_tl_virtio_fix_unit_test` passed its explicit poisoned, malformed, prefixed-malformed, and ECRC-only materialization checks. Its report catcher caught the two deliberately generated negative scoreboard errors required by the test; the test checks that the caught count is exactly two. The final report has zero warning/error/fatal reports. Its scoreboard reports have zero mismatch, unexpected, and timeout counts.

The Intel bind regressions retained normal behavior:

- `intel_pcie_env_test`: `RTILE_TEST_PASS`; SCB requests=4, completions=6, matched=2, mismatched=0, unexpected=0, timed-out=0.
- `intel_pcie_env_stress_test`: `RTILE_TEST_PASS cases=128 bytes=16768`; SCB requests=256, completions=324, matched=128, mismatched=0, unexpected=0, timed-out=0.
- Both tests inherit the final check for empty SCB pending requests and completion trackers. Their zero UVM error/fatal totals show that check passed.

## Compile diagnostics

The public TL compile completed with six warnings from existing unrelated tests: four `TMBIN` width warnings in `pcie_tl_multi_root_stress_test.sv` and `pcie_tl_multipair_heavy_test.sv`, plus two `KUAI` identifier warnings in `pcie_tl_multi_root_stress_test.sv`. The Intel bind compile had no `Warning-` or `Error-` diagnostics. No warning originates in `pcie_tl_tlp.sv` or `pcie_tl_injection_defaults_unit_test.sv`.

The finalized six-run matrix omits `pcie_tl_multi_root_stress_test`: the new directed test directly runs the production poisoned/malformed sequences, and the virtio unit test verifies receiver-side error materialization. The omitted test primarily adds unrelated multi-root fabric pressure.

Exact compile/run commands are in `commands.txt`; complete inputs, hashes, return codes, simulator logs, console logs, and compile logs are stored beside this summary.
