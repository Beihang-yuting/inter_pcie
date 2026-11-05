# VCS 验证记录

## 2026-11-02：bind 简化与统一环境入口

本轮在 `10.11.10.53` 使用 VCS W-2024.09-SP1 / UVM 1.2 验证单层
`intel_pcie_bind_wrapper_inout` 和 `intel_pcie_configure_env`。5.6 模型执行仿真和
日志判定，Astra 完成源码、日志及配置作用域的最终审查。

| 验证组 | 几何或场景 | 次数 | 结果 |
| --- | --- | --- | --- |
| bind smoke | 4×256、2×256、1×256、2×128、1×128；每组均检查两个 SIDE | 5 | PASS |
| 完整 bind env | 上述五种几何，各运行双向 137B 非对齐写读 | 5 | PASS |
| 完整 bind env 压力/边界 | 4×256，128 个写后读 case / 双方向 256B 页尾边界 | 2 | PASS |
| 原有接法兼容 | `tb_intel_pcie` 的默认 12 项功能、ready、credit、reset、env 回归 | 12 | PASS |

共 24 个运行场景、11 次独立编译通过。编译的 `Warning-[...]`、Error、Fatal 均为 0；
19 次 UVM 场景的 WARNING/ERROR/FATAL 均为 0。5 次 smoke 不启动 UVM test，以两个
SIDE 的完成标记和仿真正常结束判定成功。VCS 仍有常规的 `Ports coerced to inout`
Notice。并发测试通过 128 个 case、16768 字节，逐字节读回及前后保护区检查无误。

新增完整 bind 顶层使用两个独立 interface，经两个 wrapper 和解析型 wire 网络连接，
保持 AVST credit 开启，并在 `#0` 后通过直接 `cfg` 句柄打开 parity 检查。它验证的是
双 BFM 接线，不含真实 DUT 或 Quartus 硬核。env 测试还在目标 env 之外实例化公共
adapter，确认新的 factory instance override 没有影响该对象。

静态审查确认合并前后 47 个端口声明及 90 条 assign 完全一致；wrapper 从 332 行减至
236 行。原 `u_bind.u_core.cfg` 层次改为 `u_bind.cfg`，旧 `ADAPTER_NAME` 参数兼容性和
time-0 配置发布由 smoke 覆盖。

原始日志见 [`bind_simplify_20261102/results/`](../sim/build/logs/bind_simplify_20261102/results/)，
逐项汇总见 [validation_summary.txt](../sim/build/logs/bind_simplify_20261102/validation_summary.txt)。
受测源码清单见 [source.sha256](../sim/build/logs/bind_simplify_20261102/source.sha256)，
29 个文件已与当前工作区及测试后重算的[远端实际源码清单](../sim/build/logs/bind_simplify_20261102/tested_remote_source.sha256)
逐文件核对一致。该清单文件的 SHA-256 为
`471ebe0c333fc8c5a8a6de735feaa88d691ca5a2e6d885260650a2749577d5bb`。

本轮依赖使用本地 `pcie_work/pcie_tl_vip/src` 和 `host_mem/src` 的独立远端副本。
初始检查发现远端已有 `host_mem` 与本地不同，因此没有使用该候选版本判定结果。
本次本地依赖清单分别为 [pcie_work](../sim/build/logs/bind_simplify_20261102/local_pcie_tl_src.sha256)
和 [host_mem](../sim/build/logs/bind_simplify_20261102/local_host_mem_src.sha256)；不能仅以历史
Git 提交号代替这些实际源码快照。测试后重算的远端实际依赖清单分别为
[pcie_work（75 文件）](../sim/build/logs/bind_simplify_20261102/tested_remote_pcie_tl_src.sha256) 和
[host_mem（4 文件）](../sim/build/logs/bind_simplify_20261102/tested_remote_host_mem_src.sha256)，
均与本地逐文件一致。完整 bind env 的复现命令见[接入说明](integration/bind.md)。

## 2026-10-30：初始适配器与深度流量回归

验证日期：2026-10-30。所有编译与仿真在用户指定的 `10.11.10.53`、用户 `ubuntu` 下执行，通过 `bash -lic` 加载 `.bashrc` 中的工具与license配置。Astra负责实现/修复/审查，GPT-5.6-sol负责VCS执行、日志分析和结果判定。

工具为 VCS **W-2024.09-SP1**（build 2024-12-03），UVM 1.2，测试seed=1。外部依赖版本见[README](../README.md)。测试使用两BFM经真实interface引脚连接，没有TLM数据回环或自发自收旁路；env测试的业务响应仍由公共协议模型完成。

## 判定方法

`sim/run.sh` 要求每项同时满足：进程成功退出、UVM_ERROR/FATAL计数存在且为0、出现 `RTILE_TEST_PASS`。预期协议错误使用精确report ID的catcher，并断言命中次数；不能用屏蔽全部错误获得通过。顶层设置1 ms仿真时间watchdog，死锁不得以普通finish结束。

## 场景清单

| 测试 | 验证内容 |
| --- | --- |
| `intel_pcie_codec_test` | 独立手算big/little Header、Prefix、3/4DW、0～4096B、Completion/Config；拒绝长度不符/多Prefix |
| `intel_pcie_reassembly_test` | 图31的36B/108B手工波形、包内空拍、同拍3包、st3回绕、11-bit VF、早EOP及有效内容X负例 |
| `intel_pcie_transport_test` | 两方向各8包，4/32/36/64/128/132/0/4096B，逐字节比较且无自回环 |
| `intel_pcie_rx_gap_test` | RX包内插入2拍空闲、非零起点（多段配置）、ready始终高 |
| `intel_pcie_tx_ready_test` | 1拍停发、24拍ready低、1拍内恢复；raw-pin字节检查防重放/丢失 |
| `intel_pcie_tx_ready16_test` | 16拍停发边界；低ready窗口16个不同有效beat |
| `intel_pcie_ready_toggle_test` | 同一4096B包内5次ready低4拍/高3拍，精确Payload及每次及时恢复 |
| `intel_pcie_credit_test` | RX Posted Header仅2个槽，第三包等待；出队后精确归还 |
| `intel_pcie_data_credit_test` | 两方向Header充足而Data不足；另测RX剩31credit、下包需1credit仍被32门槛阻塞 |
| `intel_pcie_credit_init_test` | 等ACK后公告容量、分拍增量、两个空拍、六类有限/无限独立、运行期零增量不变成无限 |
| `intel_pcie_reset_test` | TX半包暂停时复位，恰好一次send中止报告，信用重初始化且无旧包重放 |
| `intel_pcie_env_test` | 实际factory替换pcie_tl_env，复用rw_seq双向非对齐137B写读；开启SCB，精确检查4请求/6分片/2匹配及空pending |
| `intel_pcie_env_stress_test` | 4个并发worker、双方向共128个1～256B页内写后读case；逐字节golden、前后64B guard、Tag/Completion/统一内存路径 |
| `intel_pcie_env_max_boundary_test` | 双方向256B最大合法包，地址放在页尾并恰好结束于4KiB边界 |
| `intel_pcie_env_split_test` | 两个独立env各持RC或EP；经bind运行相同Tag/不同Requester的双向137B读写，两SCB均检查4请求/6分片/2匹配及空pending |

## 执行记录

功能矩阵共执行5种几何配置、36次场景。默认4×256的12项全部通过，包括env双向非对齐读写；较小配置每组运行transport、rx_gap、ready_toggle、credit、data_credit、env这6项。随后消除静态越界告警，再执行6次针对性复验，总计42次场景通过。

| 每段Data宽度 | 每端口segment数 | 场景数 | 结果 |
| --- | --- | --- | --- |
| 256 bit | 4 | 12 | PASS |
| 256 bit | 2 | 6 | PASS |
| 256 bit | 1 | 6 | PASS |
| 128 bit | 2 | 6 | PASS |
| 128 bit | 1 | 6 | PASS |

36次运行的UVM_WARNING/ERROR/FATAL均为0。默认env场景在142 ns完成双向137-byte非对齐写读。深度流量测试另运行128个并发case和两个页尾边界case；`pcie_tl_rw_seq` 的单包长度按上游默认MPS=256B约束，超过MPS的包需先由上层分片。

日志保存在 [`sim/build/logs/final/`](../sim/build/logs/final/)，按 `4x256`、`2x256`、`1x256`、`2x128`、`1x128` 分组。本轮22个受测文件的本地/远端聚合SHA-256一致：`f3d737fc36ab6a457e263639afc8dc9c25265e5a204f7bd83b693c66a3ab718d`，逐文件记录见 [source.sha256](../sim/build/logs/final/source.sha256)。

参数化 `inout wire` bind smoke 另在五种几何（4×256、2×256、1×256、2×128、1×128）全部通过，日志见 [`sim/build/logs/bind_direction_inout/`](../sim/build/logs/bind_direction_inout/)。深度流量日志见 [`sim/build/logs/env_stress_fixed/`](../sim/build/logs/env_stress_fixed/)：`intel_pcie_env_stress_test` 通过128个case、累计16768字节，`intel_pcie_env_max_boundary_test` 通过双方向256B页尾边界case，两个测试的UVM_WARNING/ERROR/FATAL均为0。

参数化 `intel_pcie_bind_wrapper_inout` 在4×256下用完整端口通配连接分别运行 `SIDE=HARD_IP` 和 `SIDE=APPLICATION`，两组均通过；VCS 仅报告通用的 `Ports coerced to inout` Notice，没有错误或UVM告警。

编译审查发现小几何配置存在SIOB静态越界告警：四段专用手工fixture，以及产品检查器中单段配置不可达的 `dvalid[1]` 引用。已将产品改为与当前段相关的 `dvalid[s-1]`，fixture改用运行期索引并保留严格geometry检查。

修复后5组全部重新编译，所有VCS `Warning-[...]` 均为0；4×256重跑reassembly和transport，其余4组各重跑transport，6/6通过，UVM_WARNING/ERROR/FATAL均为0。日志保存在 [`final/warning_cleanup/`](../sim/build/logs/final/warning_cleanup/)，早先36次证据保持原样。

最终22个受测文件的本地/远端聚合SHA-256一致：`0a706097697c035dcc4f4bbdd54fc292883d755b8716695fe7208a3f73412f1e`。逐文件记录见 [warning_cleanup/source.sha256](../sim/build/logs/final/warning_cleanup/source.sha256)，已逐项核对成功。源码校验范围含src、tb、tests和sim入口，不包含本记录等文档及日志产物。

此前诊断轮次保留在 `sim/build/logs/run2/`、`run3/`：先修复测试helper的SV ref参数方向继承问题；随后默认数据通路8项通过，新增Data/初始化两项也通过。env最初在time 0因未绑定Host manager失败，已改为显式绑定Host/Device manager。这些诊断日志不代替最终快照回归结果。

## 2026-11-05：bridge SCB 请求登记修复

先在 4×256 bind 链路复现：SCB 关闭时 137B 双向读回通过；开启后，driver 能匹配
Completion，但 SCB pending 为空，出现 3 次 `Unexpected Completion`。临时补登记后
异常消失；独立 Header golden 的两种 DWORD 顺序及 Tag 高两位四种组合共 8 项通过。
诊断证据保留在 [scb-probe-20261105.md](validation/scb-probe-20261105.md)。

正式修复位于 `pcie_work` 公共 driver/env/scoreboard：发送前同步预登记，使用
`{Requester ID, Tag}` 键并保存请求快照，单侧环境补足缺失的发送观察，双 BFM 不重复
计数。原 TLM 通路保留迟到 RX 不重新登记已完成事务的行为。

在 `10.11.10.53` 用冻结源码、VCS W-2024.09-SP1、seed=1 执行首轮 10 项，均通过，
每项 UVM_WARNING/ERROR/FATAL 都为 0：

| 场景 | SCB 请求 / Completion 分片 / 完整匹配 | 额外判据 |
| --- | --- | --- |
| Intel bind env | 4 / 6 / 2 | 双向 137B 非对齐逐字节读回 |
| Intel bind stress | 256 / 324 / 128 | 128 组写读，16768B，保护区未变 |
| Intel bind boundary | 4 / 8 / 2 | 双向 256B 页尾请求 |
| Intel 独立单 RC/单 EP env | 每个 SCB 4 / 6 / 2 | 相同 Tag、不同 Requester；各自无对端 monitor |
| Intel codec | — | Header/Payload golden 检查 |
| 公共 bridge SCB unit | 4 / 6 / 4 | 相同 Tag 交错分片、对象快照、期望状态保留、Tag 重用 |
| 公共 TLM smoke_mem | 2 / 1 / 1 | 原 TLM 回环 |
| 公共 TLM cpl_split | 13 / 57 / 13 | 多片响应与 Tag 回收 |
| 公共 virtio_fix_unit | — | 原状态/无数据响应/BE 回归 |
| 公共 virtio_fix_order | — | 原 FIFO 顺序回归 |

Intel env/stress/boundary/split 均显式检查 pending 与分片跟踪表清空，并要求
unexpected/mismatched/timed_out 为 0。首轮 split 仅验证结果 Tag 相等。完整日志在
[SCB 首轮结果](validation/scb-fix-20261105.md#round1-结果)。

首轮四个顶层编译成功。公共 TL 编译包含 6 条 TMBIN/KUAI warning，运行阶段的 UVM
告警计数仍均为 0；告警来自未修改的 multi_root_stress/multipair_heavy 测试文件。
编译 warning 与 UVM warning 分开统计，不宣称整轮编译无告警。

第二轮仅补强 split 测试：两端完成 write 后经 barrier 同步发起 read，并采样断言
两个 SCB 都曾同时保留两条 pending。独立重编 `tb_intel_pcie_bind_split_env` 后通过：
`tag=000 requester_ids=0100/0200 overlap_seen=1`，两个 SCB 各 4 请求 / 6 分片 /
2 匹配，所有异常计数为 0，pending/tracker 清空，UVM_WARNING/ERROR/FATAL 为 0。
两轮合计 10 项场景、11 次运行通过；第二轮源码只改变 split 测试及 fixture 两文件，
公共产品代码与首轮一致，其余首轮结果仍适用。

完整结果、命令、各轮 143 个输入文件的 SHA-256 清单见
[scb-fix-20261105.md](validation/scb-fix-20261105.md)。
验证结束后再次核对本地源码与最终远端快照一致；用户实际 DUT 未参与本轮仿真。

## 2026-11-05：TLP 错误注入默认 soft 0

公共 `pcie_tl_tlp` 的 `inject_ecrc_err`、`inject_lcrc_err`、`inject_poisoned`、
`violate_ordering`、`field_bitmask` 和 `ep_bit` 改为各自独立、无条件的 soft 0。
LEGAL/ILLEGAL/CORNER 三种模式都适用；显式 inline 约束可覆盖单项，其余项仍为 0。
默认模式原有的 `soft constraint_mode_sel == CONSTRAINT_LEGAL` 保留。

在 `10.11.10.53` 冻结 144 个输入文件并编译公共 TL / Intel bind 两套镜像，执行
6 次运行全部通过，UVM_WARNING/ERROR/FATAL 均为 0：

- `pcie_tl_injection_defaults_unit_test`：seed 1/2/3 各 338 次精确检查，共 1014 次；
  覆盖普通随机化、Memory/Completion 派生类、默认及显式模式、单项覆盖后恢复，
  并实际启动生产 Poisoned/Malformed sequence 检查注入意图。
- `pcie_tl_virtio_fix_unit_test`：原有错误物化和 SCB 负例契约通过，两个预期错误
  由精确 report catcher 捕获并断言计数。
- `intel_pcie_env_test`：双向 137B 读写通过，SCB 4 请求 / 6 分片 / 2 匹配。
- `intel_pcie_env_stress_test`：128 组写读、16768B 通过，SCB 256 请求 / 324 分片 /
  128 匹配，异常计数为 0，pending/tracker 清空。

公共编译的 6 条 warning 来自本次未修改的 multi_root/multipair 测试文件；bind
编译无 warning/error。远端 SHA-256 与最终本地源码一致，完整证据见
[tlp-soft-defaults-20261105.md](validation/tlp-soft-defaults-20261105.md)。

## 复现

在指定主机、依赖路径正确且VCS环境已加载的shell中：

```bash
# 默认4×256完整回归。
bash sim/run.sh

# 例：2×128的适用场景，另建目录避免误用其它宽度的二进制。
DATA_WIDTH=128 SEGMENTS=2 BUILD_DIR="$PWD/sim/build_128x2" \
  bash sim/run.sh intel_pcie_transport_test intel_pcie_rx_gap_test \
  intel_pcie_ready_toggle_test intel_pcie_credit_test \
  intel_pcie_data_credit_test intel_pcie_env_test
```

## 范围与未覆盖部分

这些是定向功能与时序回归，不是随机覆盖率收敛或板级验证。没有接入实际Quartus硬核，也未验证LTSSM、PHY/DLLP、真实硬核Tag allocation、ID重写、动态信用重协商、多端口混合几何或SR-IOV完整枚举。深度测试覆盖的是公共 `pcie_tl_rw_seq` 在默认MPS下的并发合法包；4096B跨4KiB的非法请求没有作为正常通过项。x16 single-width配置开关目前没有独立回归；Header little模式有codec golden验证，默认端到端流量使用big模式。

协议负例只覆盖明确列出的错误条件，不宣称穷尽全部非法组合。早期记录中的 env 测试关闭公共 SCB，仅检查 rw_seq 状态与逐字节读回；2026-11-05 bridge SCB 修复后的测试打开 SCB 并额外检查精确计数和跟踪表清空，不能把早期结果当作 SCB 开启的验证证据。同一 switch root 混合真实 DUT/BFM EP 的观察选择、Host/Device 同地址的数据参考隔离不在本次修复范围。
