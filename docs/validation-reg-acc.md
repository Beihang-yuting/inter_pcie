# 2026-11-06：AIP reg_acc / pcie_tl_reg_seq 验证

验证主机：`ubuntu@10.11.10.53`。通过 bash 登录环境加载 VCS/license。
远端快照：`/home/ubuntu/codex_validation/pcie_reg128_20261106`。
所有 PASS 均要求实际完成标记；Intel 与公共 sequence 回归另要求最终 UVM_ERROR/FATAL 为 0。

## 源码基线

| 项目 | 基线 commit | 本次内容 |
| --- | --- | --- |
| inter_pcie | `95dedf000384876e51ab3f4889bb25d879a5c54f` | AIP/Intel bind 回归、文档 |
| pcie_work | `ea87b1aa1873872ce00ccc17eb12e5bae5348b52` | reg_seq、package 导出、公共契约回归 |
| aip_core/update | `841c879da29a55f7fa22281b2c12cbef53009883` | 位置参数、128 位数据、mask 默认 0、错误回传 |
| host_mem | `35ec087014744ec85cf6c0fe17e1f7118ee7a7b7` | 原有依赖 |

本轮验证基于以上基线叠加本次变更，下面的文件 SHA-256 标识实际参与验证的源码。

最终编译快照与本地核对的 SHA-256：

```text
pcie_tl_reg_seq.sv
de801a5c419966a285cddeb68f10a7d94faaef7c4fd94e33204e04555281101b
aip_cmd.sv
595eca989c85692c0d4b392d6bc1abc4ea97ceebe67c566bf06dce765be69371
aip_reg_args.sv
025b5224592e5796d7ef5eb4427b5e56e482cd21814e9ddd0819d1900123416f
intel_pcie_aip_reg_test.sv
464d9ad0a43eae8dafb05d11fc890949974adf5dd4aba4459b54df97501312cd
```

## 结果

| 回归 | 检查结果 |
| --- | --- |
| AIP `test_reg_wide` | 27 项检查通过：宽整数、位置/命名参数、旧 64 位类、严格宏、参数拒绝、业务错误回传 |
| AIP 原有 `test_reg_seq` | Tcl 12/12 通过，旧三参数注册继续使用 |
| 公共 `pcie_tl_reg_seq_test` | 130 项检查、156 个请求；UVM_ERROR/FATAL=0 |
| Intel 默认，seed 1 | 292 条命令、310 个原始请求、157 个读完成；UVM_ERROR/FATAL=0 |
| Intel `HIGH_ADDR`，seed 2 | 同上，4DW 地址格式；UVM_ERROR/FATAL=0 |
| Intel `LITTLE_HEADER`，seed 1 | 同上，另一种 Header DWORD 排列；UVM_ERROR/FATAL=0 |
| Intel `HIGH_ADDR LITTLE_HEADER`，seed 2 | 同上；UVM_ERROR/FATAL=0 |
| Intel 真实 Tcl bridge | 19 项检查通过，同时出现 `REG_TCL_PASS`、`REG_TCL_SV_PASS`；UVM_ERROR/FATAL=0 |

四组 Intel SV 回归各自 SCB 为 310 requests、157 completions、157 matched；
unexpected/mismatched/timed_out/pending/分片跟踪项均由基类检查为零。
每组检查四种访问长度、连续地址、数据字节序、部分和全 mask、页末合法访问及错误参数。
原始 RX 引脚检查独立提取 DW0..DW3、地址、Length、BE、TD、SOP/EOP 与 payload，
并与标量期望及后备内存对照，不仅依赖 codec 自发自收。

公共 sequence 回归覆盖 40 种单字节屏蔽位置、同一对象复用时的高/低地址切换、
全屏蔽不发请求、错误参数、UR、超时、短 Completion 和失败后恢复。
UR 产生 1 个预期 warning；超时产生的 1 个预期 `RW_SEQ` error 只在该负测中被
report catcher 接收并核对次数，其他 error/fatal 不屏蔽。

## 日志和复现

远端集成日志目录：`integration/build/logs/`，相对上述快照根目录。
最终 Tcl 日志为 `final_intel_tcl_seed1_r2.log`；四种 SV 配置使用 `final_` 前缀日志。
AIP 日志位于快照中 AIP 工作树的 `tests/sv/`；公共 sequence 日志在集成日志目录。
编译和运行示例见 [reg_acc 集成说明](integration/reg_acc.md)。

11 个最终日志已复制到本地 `/tmp/pcie_reg128_validation_logs_RKfbHB`，并逐文件
与远端 SHA-256 manifest 核对一致；目录总计 627621 字节。主要日志：

```text
run_reg_wide_final.log
test_reg_seq_final.log
run_reg_seq_unit_seed1_r2.log
final_default_seed1.log
final_high_addr_seed2.log
final_little_header_seed1.log
final_high_little_seed2.log
final_intel_tcl_seed1_r2.log
```

Tcl 模式 SCB 为 21 requests、9 completions、9 matched，其他错误计数为零。
AIP 宽数据和原有 12 项回归均在最终 guard/source 快照更新后重新执行。

本回归使用两个产品 bind wrapper、公共 requester/responder 和独立内存模型，
没有用户实际 DUT。它验证命令到 Intel 引脚及 Completion 的映射，不能替代 DUT 寄存器
副作用、BAR 地址映射或设备特定访问顺序的验证。
