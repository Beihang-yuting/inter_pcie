# VCS 验证记录

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
| `intel_pcie_env_test` | 实际factory替换pcie_tl_env，复用rw_seq双向非对齐137B写读、Completion/Tag/内存路径 |
| `intel_pcie_env_stress_test` | 4个并发worker、双方向共128个1～256B页内写后读case；逐字节golden、前后64B guard、Tag/Completion/统一内存路径 |
| `intel_pcie_env_max_boundary_test` | 双方向256B最大合法包，地址放在页尾并恰好结束于4KiB边界 |

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

协议负例只覆盖明确列出的错误条件，不宣称穷尽全部非法组合。上层scoreboard的TLM pending注册在env测试中关闭，使用rw_seq完成状态与逐字节读回比较作为判据。
