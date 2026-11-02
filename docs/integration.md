# 接入现有 pcie_work 验证环境

直接绑定真实 DUT 用户侧网络时，使用 [bind wrapper 接入说明](integration/bind.md)；它只发布已有 adapter 所需的 virtual interface/config，不改变默认回归。

## 编译与对象分层

设置 `INTEL_PCIE_ROOT`、`PCIE_WORK_ROOT`、`HOST_MEM_ROOT` 为绝对路径，使用 `sim/filelist_lib.f` 编译产品库。接口先于 `intel_pcie_adapter_pkg` 编译，外部 `host_mem_pkg` 自己包含manager，不能再单独编译一次manager。

几何参数为全局编译宏：`INTEL_PCIE_DATA_WIDTH`、`INTEL_PCIE_SEGMENTS`，默认256/4。同一仿真可以有多个独立端口实例，但本版单次编译只使用一种几何配置。支持的参数组合为256×1/2/4、128×1/2；具体回归证据见[验证记录](validation.md)。

## 按引脚方向选择适配器

PCIe协议的RC/EP角色和用户侧接口的source/sink角色不同，必须分别配置。

| `intel_cfg.side` | 驱动 | 接收 | 适用连接 |
| --- | --- | --- | --- |
| `INTEL_PCIE_HARD_IP` | RX stream、TX ready、TX credit、RX credit ACK | TX stream、RX credit | BFM扮演硬核，与用户逻辑DUT相连 |
| `INTEL_PCIE_APPLICATION` | TX stream、RX ready、RX credit、TX credit ACK | RX stream、TX credit | BFM扮演用户逻辑，与硬核接口相连 |

自动方向仅为与参考环境兼容：`rc_adapter*`→HARD_IP、`ep_adapter*`→APPLICATION。自定义名字必须显式指定side；即便名称匹配，真实RP用户逻辑的对端BFM也应显式设HARD_IP，不能仅靠RC/EP命名猜测方向。

每条总线只能有一个每种方向的驱动者。自测用两BFM对接；接真实DUT时，由DUT替代相应一侧，不能把两BFM再一起接到DUT上。

## Factory与配置

在创建env之前设置factory和配置，基本写法如下。`tests/intel_pcie_env_test.sv` 是可执行的完整示例。

入口来自 `intel_pcie_adapter_pkg`，须在 `pcie_tl_env::type_id::create("env", this)`
之前调用。第三个参数可指定其他 env 名字；factory 替换仅作用于目标 env 子树，
不改变其他环境。它不选择 RC/EP、创建内存或关闭 scoreboard。

每个adapter使用独立的 `intel_pcie_adapter_config` 对象，构建后不再修改方向/容量。不要把同一个AUTO配置句柄通过通配路径同时分给两侧：build会把AUTO解析为该实例的实际方向。

```systemverilog
// env_cfg 为已创建、已选择协议角色和内存的 pcie_tl_env_config。
// 统一配置当前 env 的 factory、SV_IF_MODE、公共无限 FC 和外部引脚 bridge。
intel_pcie_configure_env(this, env_cfg);

intel_cfg.side = INTEL_PCIE_HARD_IP;
uvm_config_db#(intel_pcie_adapter_config)::set(
    this, "env.rc_adapter_0", "intel_cfg", intel_cfg);
```

在top中将virtual interface发布到**准确组件路径**；默认单 RC 的实际组件名是
`rc_adapter_0`，默认单 EP 的实际组件名是 `ep_adapter`。多端口使用 env 实际创建的
`rc_adapter_<n>` / `ep_adapter_<n>` 路径。使用 bind wrapper 时不需要再调用下面的
连接宏，因为 wrapper 已经把 `vif` 和 `intel_cfg` 发布到同一个路径。

```systemverilog
`INTEL_PCIE_ADAPTER_CONNECT("uvm_test_top.env.rc_adapter_0", pcie_bus)
```

宏定义位于 `tb/intel_pcie_adapter_connect.svh`，只设置 `vif`，不额外驱动引脚。interface的 `clk` 连接该端口 `coreclkout_hip`，`rst_n` 连接已同步、低有效的用户接口复位。

硬核引脚与数组一一映射，例如 `bus.rx_data[N] ↔ pX_rx_stN_data_o`、`bus.tx_data[N] ↔ pX_tx_stN_data_i`；credit为每端口共享。`vfactive` 对应手册 `vf_active` 命名。所有valid、包边界、Header/Prefix、credit/ACK也必须连接，不能只接data/ready。详细所有权见 `intel_pcie_if.sv` 的application modport及[信号表](r-tile-interface.md)。

## 复用requester/responder

当前 `pcie_work` 的SV接口模式需要已有的transport bridge，让monitor接收到的请求/Completion转交公共driver。
`intel_pcie_configure_env` 已为指定 env 设置 `pcie_svt_bridge_required=1`，无需重复填写。
此hook虽因历史原因带 `svt` 名称，此处不依赖SVT VIP。它复用公共responder、Tag回收、Completion通知和统一内存，不在Intel仓库复制一套响应器。

打开 `use_unified_mem` 后还必须注入实际manager。当前上游版本不会自动创建Host/Device内存；例如在test中持有两个独立 `host_mem_manager`，并在env创建前执行：

```systemverilog
// 需 import host_mem_pkg::*；why为string，两个manager由test持有到仿真结束。
host_manager = new("host_manager");
device_manager = new("device_manager");
host_manager.set_host_id(0);
if (!env_cfg.bind_host_memory(0, 0, host_manager, why))
    `uvm_fatal("TEST_MEMORY", why)
uvm_config_db#(host_mem_api)::set(this, "env", "dev_mem_0", device_manager);
```

集成回归设置 `ep_auto_response=1`、`use_unified_mem=1`，用 `pcie_tl_rw_seq` 完成RC→EP和EP→Host的137-byte非对齐写读。该测试关闭公共scoreboard：其pending注册路径属于TLM通路，当前引脚桥不补写该内部状态；测试逐字节检查读回结果。接项目自有scoreboard时，应通过公共monitor/adapter analysis port接入真实观测结果。

## 配置与调用约定

| 配置 | 默认 | 含义 |
| --- | --- | --- |
| `header_big_endian` | 1 | 必须与IP参数一致，控制Header DWORD摆放 |
| `check_parity` | 0 | 接收侧32:1 XOR校验；发送侧始终生成parity |
| `credit_enable` | 1 | AVST有限信用控制；禁用仅适合双方明确一致的隔离测试 |
| `header_capacity[3]` | 各16 | 本端接收的P/NP/CPL Header缓冲数 |
| `data_capacity[3]` | 各512 | 本端接收的P/NP/CPL Data缓冲数，单位16 B |
| `infinite_header/data[3]` | 各0 | 分别选择初始化时公告无限信用 |
| `tx_stop_latency` | 1 | APPLICATION响应TX ready低的停发延迟，范围1～16 |
| `rx_gap_cycles` | 0 | HARD_IP在RX包内插入的整拍空闲数 |
| `rx_start_segment` | 0 | HARD_IP独立起包的位置；四段端口限0/1，避免量产器件禁止的后半拍独占 |
| `x16_single_width` | 0 | 2×256时显式选择x16 single-width，限制每拍一个TX SOP |

`send(tlp)` 阻塞到本地EOP采样，不等同于PCIe请求已完成。适配器先编码为私有快照；多个并发调用按入队顺序发送。扩展入口 `send_batch(tlps)` 先验证整个batch再入队，支持合法同拍多包，公共sequence仍可直接调用原 `send`。

`receive(tlp)` 非阻塞，空队列返回null。出队时释放缓冲并通过后续credit更新通知对端。`rx_packet_ap` 在完整packet入队时发布观测对象；订阅者只读该对象，如需修改先复制。

`set_tx_ready(value)` 仅允许HARD_IP调用，下一下降沿更新TX ready。RX ready由APPLICATION持续驱动1；监视到其为0或X会报 `RTILE_RX_READY`。

一次信用不足只阻塞发送，不丢弃队列，也不超时伪造成功。超过公告容量的包、长度/empty错误、TX非法起点、无反压空洞、parity错误均报告UVM_ERROR。非法流量发生后应判定测试失败；产品不承诺自动从畸形包恢复信用状态。

复位会清空半包、待发送/待接收队列及信用，重新初始化。已入队的 `send` 被唤醒并报告 `RTILE_RESET_ABORT`。调用者还须协调公共driver的未完成Tag、sequence与内存事务；适配层不替上层决定如何重试。

## 对真实硬核的边界

- 仅适配事务用户接口，不实现LTSSM、链路训练、DLLP、配置空间、地址枚举或Quartus硬核行为。
- 本版按普通非TL-Bypass模式处理Header/Prefix/Payload。最多一个32-bit Prefix；多Prefix、ECRC/LCRC错误注入显式拒绝。TD可保留，用户Payload中不附加由硬核生成/剥离的ECRC。
- 真实硬核的Tag allocation接口及Requester/Completer ID改写未建模。Tag由公共协议模型管理；真实RP应用TX的ID应按p.89要求设置为0，EP的ID处理应遵循IP和SR-IOV配置。不能把双BFM自测通过当成完整硬核接入认证。
- RX保留3-bit BAR、PF、完整11-bit VF。AVST不提供完整BAR aperture/offset/BDF，因此不设置 `cq_route.valid`，不把11-bit VF截成8-bit `target_func`；上层需要完整路由时必须提供地址/功能配置。
- 同一方向按队列顺序发送，前包缺信用会阻塞后包；没有实现按P/NP/CPL跳过队首的性能调度。
- 有限缓冲应至少容纳预期最大包，否则完整包预留策略会持续等待。无限信用依赖接收端实际能持续容纳流量。
- 空闲时按手册可重新协商信用，但本版主动重新公告容量通过复位完成；不提供运行中动态修改容量的API。
