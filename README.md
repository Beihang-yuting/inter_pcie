# Intel R-Tile PCIe 用户接口适配器

本项目把 R-Tile Avalon-ST 的分离 Header / Prefix / Payload 接口接入 `pcie_work/pcie_tl_vip`，复用其 TLP、agent、sequence、Tag、Completion 和内存模型。安装方式沿用 Xilinx adapter-mode：继承 `pcie_tl_if_adapter`，通过 UVM factory 替换传输层。

这是 **SystemVerilog/UVM BFM 适配层**，不是可综合 RTL，也不是 Quartus PCIe 硬核仿真模型。默认端口为 1×16 double-width，即 4 个 256-bit segment。

## 阅读入口

- [手册 §4.3.1.3 / §4.3.1.4 的信号与时序总结](docs/r-tile-interface.md)
- [接入方法、配置与边界](docs/integration.md)
- [DUT bind 接入与信号映射](docs/integration/bind.md)
- [设计规格](docs/superpowers/specs/2026-10-29-intel-r-tile-adapter-design.md)
- [验证记录](docs/validation.md)

## 实现

| 文件 | 职责 |
| --- | --- |
| `src/interface/intel_pcie_if.sv` | 一个端口的 RX/TX、六类 credit、parity、PF/VF/BAR 信号 |
| `src/codec/intel_pcie_avst_codec.sv` | 公共 TLP 与分离总线格式转换；Header 两种字序 |
| `src/codec/intel_pcie_reassembler.sv` | 按 segment 顺序重组、包内空拍、多包、Length/empty 检查 |
| `src/adapter/intel_pcie_credit_manager.sv` | 初始化、有限/无限信用、完整包预留、出队后归还 |
| `src/adapter/intel_pcie_if_adapter.sv` | `send/receive`、整拍调度、TX ready 停发/恢复、复位 |
| `bind/intel_pcie_bind_wrapper.sv` | 参数化 wire/inout wrapper 与内部 core；发布 vif/config |
| `tests/bind/tb_intel_pcie_bind_smoke.sv` | HARD_IP/APPLICATION 两种方向和多种几何的 bind smoke |
| `tests/intel_pcie_env_test.sv` | 复用 `pcie_tl_env` / `pcie_tl_rw_seq` 的双向非对齐读写示例 |
| `tests/intel_pcie_env_stress_test.sv` | 4 worker、128 个并发合法包、逐字节读回和4KiB页尾边界测试 |

RX `ready` 必须常高，缓冲不足通过 credit 表示。TX `ready` 拉低后的允许延迟窗口内，每个有效拍仍然向前传输；不能套用 `ready && valid` 的保持/重发规则。

## 外部依赖

依赖保持在外部，通过 filelist 环境变量引用；不复制公共协议实现。

| 来源 | 本次参考/验证版本 |
| --- | --- |
| [pcie_work/main](https://github.com/Beihang-yuting/pcie_work/tree/main) | `2ae1129093b4014fd0528f6092ab303fc8ca4feb` |
| 独立 `host_mem` 仓库 | `35ec087014744ec85cf6c0fe17e1f7118ee7a7b7` |
| [xillinx_pcie/feat/adapter-mode](https://github.com/Beihang-yuting/xillinx_pcie/tree/feat/adapter-mode)（设计参考，不参与编译） | `f3646316b2125486f7074bd2d97cf8dc62bc997e` |
| 用户上传 `R-Tile.pdf` | UG-20316，2026.01.29，尤其 pp.75–95 |

## 执行回归

所有仿真必须在 `10.11.10.53` 执行。通过 `bash -lic` 加载该主机的 VCS 和 license 环境，在远端源码目录运行：

```bash
export PCIE_WORK_ROOT=/absolute/path/to/pcie_work
export HOST_MEM_ROOT=/absolute/path/to/host_mem
bash sim/run.sh
```

`sim/run.sh` 在非指定主机上拒绝运行。默认编译后执行全部回归；可指定测试名，例如 `bash sim/run.sh intel_pcie_tx_ready16_test`。已有相同配置的二进制时，可用 `SKIP_COMPILE=1`。日志默认写入 `sim/build/logs`；判断成功同时要求 UVM ERROR/FATAL 为零和场景完成标记，不能只看进程退出码。

较小的合法几何配置用 `DATA_WIDTH` / `SEGMENTS` 编译，必须使用独立 `BUILD_DIR`。手工图31测试固定使用 4×256，其他宽度应显式选择适用测试，详见验证记录。

2026-10-30已在指定VCS主机完成5种配置的36次功能回归，以及清理编译告警后的6次针对性复验，全部通过；参数化 inout bind smoke 的5种几何和深度流量测试也通过，运行UVM_WARNING/ERROR/FATAL均为0。[验证记录](docs/validation.md)保留测试范围、原始日志与源码hash。
