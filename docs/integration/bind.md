# PCIe 用户侧接口 bind 集成

`bind/intel_pcie_bind_wrapper.sv` 把目标 DUT 的 Intel R-Tile 用户侧网络接到
`intel_pcie_if`，并把 virtual interface 和 `intel_pcie_adapter_config` 发布给已经由
`pcie_tl_env` 创建的 adapter。wrapper 不创建 `intel_pcie_if_adapter`，因此不会产生
重复 driver、credit manager 或 monitor。

接入分为三步：绑定引脚；在 `#0` 后按需修改 `u_pcie_bind.cfg`；在 test 中调用
`intel_pcie_configure_env(this, cfg)` 后创建 `pcie_tl_env`。常用 bind 参数只有
`ADAPTER_PATH` 和 `SIDE`，协议角色和内存由 test 配置。完整可运行示例见
[`tb_intel_pcie_bind_env.sv`](../../tests/bind/tb_intel_pcie_bind_env.sv) 和
[`intel_pcie_env_test.sv`](../../tests/intel_pcie_env_test.sv)。

`pcie_tl_env` 默认 `num_rc=1、num_ep=1` 时，UVM 组件的实际层级是
`uvm_test_top.env.rc_adapter_0` 和 `uvm_test_top.env.ep_adapter`。类成员
`env.rc_adapter` / `env.ep_adapter` 只是指向首个 adapter 的句柄，不能直接当作
`uvm_config_db` 的层级路径。非 switch 多实例时使用
`rc_adapter_0`、`rc_adapter_1` 和 `ep_adapter_0`、`ep_adapter_1`；每个物理端口
必须绑定到各自的完整路径。

## 绑定方式

目标 DUT 的这些端口全部是 `wire`/`tri` 网络时，使用唯一的对外 bind wrapper
`intel_pcie_bind_wrapper_inout`。它保留统一的 `inout wire` 端口，只由参数
`SIDE` 在 elaboration 时选择内部 generate 的驱动方向：

```systemverilog
bind tb_top.u_dut.u_pcie intel_pcie_bind_wrapper_inout #(
  .ADAPTER_PATH("uvm_test_top.env.rc_adapter_0"),
  .SIDE("HARD_IP")
) u_pcie_bind (/* 与目标 wire 同名连接，或使用 .* */);
```

`SIDE` 不是运行时切换；它必须是 `HARD_IP` 或 `APPLICATION`，每个物理端口只
绑定一个 wrapper。`inout` 的实际连接必须是 net，不能把 DUT 的 `logic` variable
直接作为 inout actual。若 DUT 内部使用 `logic`，应在 DUT 端口边界先引出
`wire/tri` 网络，再连接该 wrapper。

### 4×256 使用一维 1024-bit 总线

DUT 可以使用 `wire [1023:0] rx_st_data_vector` / `tx_st_data_vector`。
wrapper 的 `wire [3:0][255:0] rx_data` / `tx_data` 是 packed 数组，总宽度同样为
1024 bit，端口可以直接相连，无需拆线、类型转换或新增 adapter：

```systemverilog
// bind 端口列表中的映射片段；valid、ready、credit 和其他边带仍需完整连接。
.rx_data (rx_st_data_vector),
.tx_data (tx_st_data_vector),
.rx_hdr  (rx_st_hdr_vector),
.tx_hdr  (tx_st_hdr_vector)
```

以上直接连接要求 DUT 的 `st0` 放在低位，且一维向量声明为 `[总宽度-1:0]`。
以 data 为例：

| wrapper 中的段 | DUT 一维 data 对应位段 |
| --- | --- |
| `[0]` / st0 | `[255:0]` |
| `[1]` / st1 | `[511:256]` |
| `[2]` / st2 | `[767:512]` |
| `[3]` / st3 | `[1023:768]` |

其它 packed 边带也可按同样规则直接连接：

| wrapper 字段 | 4×256 时的一维宽度 |
| --- | --- |
| `rx_data`、`tx_data` | 1024 bit |
| `rx_hdr`、`tx_hdr` | 512 bit（每段 128） |
| `rx_prefix`、`tx_prefix` | 128 bit（每段 32） |
| 每组 `sop/eop/dvalid/hvalid/pvalid` | 各 4 bit |
| `rx_empty`、`rx_bar`、`rx_pfnum` | 各 12 bit |
| `rx_vfactive`、`rx_vfnum` | 4 bit、44 bit |
| `rx_data_par`、`tx_data_par` | 各 32 bit |
| `rx_hdr_par`、`tx_hdr_par` | 各 16 bit |
| `rx_prefix_par`、`tx_prefix_par` | 各 4 bit |
| `rx_ready`、`tx_ready` | 各 1 bit |

credit 是每端口共享的 P/NP/CPL 六类信用，不能再乘以 segment 数。其控制和 ACK
各为 3 bit，Header update count 为 6 bit，Data update count 为 12 bit。

如果 DUT 将 valid 合并成 `rx_st_vld_vector` / `tx_st_vld_vector`，必须先确认
`ST_VLD` 及每段 dvalid/hvalid/pvalid 的位定义，再将相应位作为 net 拼接连接到
wrapper 的三组 4-bit valid。1024-bit data 宽度本身不能推导 valid 位序。

编译参数仍为 `INTEL_PCIE_DATA_WIDTH=256`、`INTEL_PCIE_SEGMENTS=4`；DATA_WIDTH
表示每段宽度，不能填 1024。若 DUT 的 st0 位于高位，应按实际段序重排 data 和
所有对应边带，不能只调整 data。

`output logic` 变量不能直接连接本 wrapper 的 inout 端口。可以选择父模块中连接
DUT 端口的现有 `wire/tri` 网络作为绑定点；父层 net 应是实际连到 DUT 端口的网络，
单独用单向 assign 复制一份信号并不能普遍实现双向连接。

### DUT 使用独立 st0～st3 信号

下面示例对应默认
`INTEL_PCIE_DATA_WIDTH=256`、`INTEL_PCIE_SEGMENTS=4`，`st0` 是 packed 数组低索引：

```systemverilog
bind tb_top.u_dut.u_pcie intel_pcie_bind_wrapper_inout #(
  .ADAPTER_PATH("uvm_test_top.env.rc_adapter_0"),
  .SIDE("HARD_IP")
) u_pcie_bind (
  .clk                 (coreclkout_hip),
  .rst_n               (reset_status_n),
  .rx_data             ({p0_rx_st3_data_o, p0_rx_st2_data_o,
                         p0_rx_st1_data_o, p0_rx_st0_data_o}),
  .rx_hdr              ({p0_rx_st3_hdr_o, p0_rx_st2_hdr_o,
                         p0_rx_st1_hdr_o, p0_rx_st0_hdr_o}),
  .rx_prefix           ({p0_rx_st3_prefix_o, p0_rx_st2_prefix_o,
                         p0_rx_st1_prefix_o, p0_rx_st0_prefix_o}),
  .rx_sop              ({p0_rx_st3_sop_o, p0_rx_st2_sop_o,
                         p0_rx_st1_sop_o, p0_rx_st0_sop_o}),
  .rx_eop              ({p0_rx_st3_eop_o, p0_rx_st2_eop_o,
                         p0_rx_st1_eop_o, p0_rx_st0_eop_o}),
  .rx_dvalid           ({p0_rx_st3_dvalid_o, p0_rx_st2_dvalid_o,
                         p0_rx_st1_dvalid_o, p0_rx_st0_dvalid_o}),
  .rx_hvalid           ({p0_rx_st3_hvalid_o, p0_rx_st2_hvalid_o,
                         p0_rx_st1_hvalid_o, p0_rx_st0_hvalid_o}),
  .rx_pvalid           ({p0_rx_st3_pvalid_o, p0_rx_st2_pvalid_o,
                         p0_rx_st1_pvalid_o, p0_rx_st0_pvalid_o}),
  .rx_empty            ({p0_rx_st3_empty_o, p0_rx_st2_empty_o,
                         p0_rx_st1_empty_o, p0_rx_st0_empty_o}),
  .rx_bar              ({p0_rx_st3_bar_o, p0_rx_st2_bar_o,
                         p0_rx_st1_bar_o, p0_rx_st0_bar_o}),
  .rx_pfnum            ({p0_rx_st3_pfnum_o, p0_rx_st2_pfnum_o,
                         p0_rx_st1_pfnum_o, p0_rx_st0_pfnum_o}),
  .rx_vfactive         ({p0_rx_st3_vf_active_o, p0_rx_st2_vf_active_o,
                         p0_rx_st1_vf_active_o, p0_rx_st0_vf_active_o}),
  .rx_vfnum            ({p0_rx_st3_vf_num_o, p0_rx_st2_vf_num_o,
                         p0_rx_st1_vf_num_o, p0_rx_st0_vf_num_o}),
  .rx_data_par         ({p0_rx_st3_data_par_o, p0_rx_st2_data_par_o,
                         p0_rx_st1_data_par_o, p0_rx_st0_data_par_o}),
  .rx_hdr_par          ({p0_rx_st3_hdr_par_o, p0_rx_st2_hdr_par_o,
                         p0_rx_st1_hdr_par_o, p0_rx_st0_hdr_par_o}),
  .rx_prefix_par       ({p0_rx_st3_prefix_par_o, p0_rx_st2_prefix_par_o,
                         p0_rx_st1_prefix_par_o, p0_rx_st0_prefix_par_o}),
  .tx_data             ({p0_tx_st3_data_i, p0_tx_st2_data_i,
                         p0_tx_st1_data_i, p0_tx_st0_data_i}),
  .tx_hdr              ({p0_tx_st3_hdr_i, p0_tx_st2_hdr_i,
                         p0_tx_st1_hdr_i, p0_tx_st0_hdr_i}),
  .tx_prefix           ({p0_tx_st3_prefix_i, p0_tx_st2_prefix_i,
                         p0_tx_st1_prefix_i, p0_tx_st0_prefix_i}),
  .tx_sop              ({p0_tx_st3_sop_i, p0_tx_st2_sop_i,
                         p0_tx_st1_sop_i, p0_tx_st0_sop_i}),
  .tx_eop              ({p0_tx_st3_eop_i, p0_tx_st2_eop_i,
                         p0_tx_st1_eop_i, p0_tx_st0_eop_i}),
  .tx_dvalid           ({p0_tx_st3_dvalid_i, p0_tx_st2_dvalid_i,
                         p0_tx_st1_dvalid_i, p0_tx_st0_dvalid_i}),
  .tx_hvalid           ({p0_tx_st3_hvalid_i, p0_tx_st2_hvalid_i,
                         p0_tx_st1_hvalid_i, p0_tx_st0_hvalid_i}),
  .tx_pvalid           ({p0_tx_st3_pvalid_i, p0_tx_st2_pvalid_i,
                         p0_tx_st1_pvalid_i, p0_tx_st0_pvalid_i}),
  .tx_data_par         ({p0_tx_st3_data_par_i, p0_tx_st2_data_par_i,
                         p0_tx_st1_data_par_i, p0_tx_st0_data_par_i}),
  .tx_hdr_par          ({p0_tx_st3_hdr_par_i, p0_tx_st2_hdr_par_i,
                         p0_tx_st1_hdr_par_i, p0_tx_st0_hdr_par_i}),
  .tx_prefix_par       ({p0_tx_st3_prefix_par_i, p0_tx_st2_prefix_par_i,
                         p0_tx_st1_prefix_par_i, p0_tx_st0_prefix_par_i}),
  .rx_ready            (p0_rx_ready_i),
  .tx_ready            (p0_tx_ready_o),
  .rx_hcrdt_init       (p0_rx_hcrdt_init_o),
  .rx_hcrdt_init_ack   (p0_rx_hcrdt_init_i),
  .rx_hcrdt_update     (p0_rx_hcrdt_update_o),
  .rx_hcrdt_update_cnt (p0_rx_hcrdt_update_cnt_o),
  .rx_dcrdt_init       (p0_rx_dcrdt_init_o),
  .rx_dcrdt_init_ack   (p0_rx_dcrdt_init_i),
  .rx_dcrdt_update     (p0_rx_dcrdt_update_o),
  .rx_dcrdt_update_cnt (p0_rx_dcrdt_update_cnt_o),
  .tx_hcrdt_init       (p0_tx_hcrdt_init_o),
  .tx_hcrdt_init_ack   (p0_tx_hcrdt_init_i),
  .tx_hcrdt_update     (p0_tx_hcrdt_update_o),
  .tx_hcrdt_update_cnt (p0_tx_hcrdt_update_cnt_o),
  .tx_dcrdt_init       (p0_tx_dcrdt_init_o),
  .tx_dcrdt_init_ack   (p0_tx_dcrdt_init_i),
  .tx_dcrdt_update     (p0_tx_dcrdt_update_o),
  .tx_dcrdt_update_cnt (p0_tx_dcrdt_update_cnt_o)
);
```

不同 segment 数量只需按当前编译宏删减/增加 `stN` 项；`rx_data_par` 的每段宽度是
`DATA_WIDTH/32`，`rx_hdr_par` 固定 4 bit，Header update count 为 6 bit，Data
update count 为 12 bit。信号方向和每个字段含义见 [`r-tile-interface.md`](../r-tile-interface.md)。

真实 HIP、VIP 模拟 APPLICATION 时仍使用同一个 wrapper，参数改为：

```systemverilog
bind tb_top.u_dut.u_pcie intel_pcie_bind_wrapper_inout #(
  .ADAPTER_PATH("uvm_test_top.env.ep_adapter"),
  .SIDE("APPLICATION")
) u_pcie_bind (/* 按反向端口方向连接同一组用户侧信号 */);
```

## SIDE 所有权

| `SIDE` | wrapper 驱动 | wrapper 采样 DUT |
| --- | --- | --- |
| `HARD_IP` | RX 全部 stream/路由/parity、`tx_ready`、TX credit init/update/count、RX credit ACK | TX 全部 stream/parity、`rx_ready`、RX credit init/update/count、TX credit ACK |
| `APPLICATION` | TX 全部 stream/parity、`rx_ready`、RX credit init/update/count、TX credit ACK | RX 全部 stream/路由/parity、`tx_ready`、TX credit init/update/count、RX credit ACK |

wrapper 对自己拥有的网络使用 `assign (supply1, supply0)`，未拥有的方向保持高阻，
因此一个绑定点只能再有真实 DUT 的一个驱动者。TX invalid 拍也保持驱动，不能按
valid 条件释放网络；复位期间 adapter 会清空 valid/credit，APPLICATION 仍驱动
`rx_ready=1`，HARD_IP 的 `tx_ready` 暂为 0。

## 配置和启动顺序

`ADAPTER_PATH` 必须与 `pcie_tl_env` 实际创建的组件路径完全一致，多端口使用不同路径。
`ADAPTER_NAME` 仅作为旧调用的兼容参数保留，只影响配置对象名字，通常无需填写。

在 test 的 `build_phase` 中，配置好协议角色和内存后，用统一入口完成接入：

```systemverilog
// 需 import intel_pcie_adapter_pkg::*；cfg 为已创建的 pcie_tl_env_config。
intel_pcie_configure_env(this, cfg);  // 默认目标是当前 test 下的 "env"
env = pcie_tl_env::type_id::create("env", this);
```

入口设置 `SV_IF_MODE`、公共 FC 的 `infinite_credit=1`、外部引脚 bridge 和 env cfg，
并且只对指定 env 子树设置 Intel adapter 的 factory instance override。它不创建
env/agent，不选择 RC/EP，不创建内存，也不改变 scoreboard 或本地 AVST credit 配置。
因此仍应按业务设置 agent 开关、端口数量、内存和检查方式。
改用此入口时，删除原来的全局 `set_type_override` 和重复的模式/bridge 设置。

env 使用其他名字时，传入第三个参数，例如 `intel_pcie_configure_env(this, cfg, "pcie_env")`，
并以同名创建 env。`parent=null` 时第三个参数必须是完整 UVM 路径；空路径、通配路径和
空 cfg 会立即报 `RTILE_ENV_CONFIG`。必须在创建目标 env 之前调用。

所有 wrapper 的 time-0 初始化完成后，顶层再进入 Inactive 区调用一次 `run_test()`：

```systemverilog
initial begin
  #0;
  // 可选：直接调整 wrapper 发布的同一个配置对象。
  u_dut.u_pcie.u_pcie_bind.cfg.check_parity = 1;
  run_test("my_pcie_test");
end
```

不要在 wrapper 内调用 `run_test()`，也不要在 env 中为同一 `ADAPTER_PATH` 再创建一套
adapter。`#0` 只保证 config_db 已发布；adapter 本身仍在 UVM build_phase 创建。
`cfg` 的容量、parity 等行为字段应在 build 前配置，`cfg.side` 必须保持与参数 `SIDE`
一致，不能用修改 cfg 的方式切换 elaboration 时已经确定的引脚方向。

旧层次 `u_pcie_bind.u_core.cfg` 改为 `u_pcie_bind.cfg`；interface 同样直接位于
`u_pcie_bind.u_intel_pcie_if`。模块名、引脚和参数保持兼容。

## 与完整 `pcie_tl_env` 的连接

`SIDE` 描述用户侧引脚的驱动方向，`rc_agent/ep_agent` 描述 PCIe 协议角色；两者
是独立选择。真实 DUT 链路只保留一个外部端点。`pcie_tl_env` 默认同时创建 RC 和 EP 两个
adapter，适合双 BFM 自测；绑定一个真实 DUT 时必须关闭 DUT 对应的另一侧 agent，
否则未绑定的第二个 adapter 也会进入 `SV_IF_MODE`，并在 build 阶段因缺少 `vif`
失败。常见组合如下：

| 外部对象 | VIP 的 `SIDE` | VIP 打开的 agent |
| --- | --- | --- |
| DUT 用户逻辑，VIP 模拟 HIP | `HARD_IP` | 按 DUT 的 PCIe 角色选 RC 或 EP |
| DUT 真实 HIP，VIP 模拟用户逻辑 | `APPLICATION` | 按 HIP 的 PCIe 角色选 RC 或 EP |

下面是 DUT 为 RC 用户应用、VIP 模拟 HARD_IP 的最小配置：

```systemverilog
`include "uvm_macros.svh"
import uvm_pkg::*;
import pcie_tl_pkg::*;
import host_mem_pkg::*;
import intel_pcie_adapter_pkg::*;

class my_app_dut_test extends uvm_test;
  `uvm_component_utils(my_app_dut_test)
  pcie_tl_env env;
  pcie_tl_env_config cfg;
  host_mem_manager host_mem;

  function new(string name = "my_app_dut_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    string why;
    super.build_phase(phase);
    cfg = pcie_tl_env_config::type_id::create("cfg");
    cfg.rc_agent_enable = 1;
    cfg.ep_agent_enable = 0;       // DUT 是用户侧逻辑，HIP 由 VIP 模拟
    cfg.num_rc = 1;
    cfg.num_ep = 0;
    cfg.ep_auto_response = 0;
    cfg.use_unified_mem = 1;
    cfg.scb_enable = 0;            // 引脚桥接场景用 monitor/sequence 自检
    host_mem = new("host_mem");
    host_mem.set_host_id(0);
    if (!cfg.bind_host_memory(0, 0, host_mem, why))
      `uvm_fatal("HOST_MEM", why)

    intel_pcie_configure_env(this, cfg);
    env = pcie_tl_env::type_id::create("env", this);
  endfunction
endclass
```

此时 bind 参数使用 `.ADAPTER_PATH("uvm_test_top.env.rc_adapter_0")` 和
`.SIDE("HARD_IP")`。RC sequence 通过 `env.rc_agent.sequencer` 发起事务；DUT
发出的 DMA 请求由 RC monitor 观察并交给 `rc_driver`/`host_mem` 响应。
若 DUT 用户逻辑是 EP，则把同样的 `HARD_IP` 绑定到 `ep_adapter`，关闭 RC agent
并打开 EP agent；协议角色变化不会改变 `SIDE` 的引脚所有权。

例如 DUT 是 PCIe EP HIP、VIP 模拟用户应用时，只打开 EP agent：

```systemverilog
cfg.rc_agent_enable = 0;
cfg.ep_agent_enable = 1;
cfg.num_rc = 0;
cfg.num_ep = 1;
cfg.ep_auto_response = 1;
uvm_config_db#(host_mem_api)::set(this, "env", "dev_mem_0", device_mem);
```

bind 参数改为 `.ADAPTER_PATH("uvm_test_top.env.ep_adapter")` 和
`.SIDE("APPLICATION")`。此时 EP sequence 通过 `env.ep_agent.sequencer` 发包，
HIP 发来的请求由 EP monitor 交给 EP driver，并由 `dev_mem_0` 完成读写响应。
如果 HIP 配置为 RC，则改为打开 RC agent、使用 `rc_adapter_0` 路径，SIDE 仍为
`APPLICATION`。
如果只有单向事务且不需要内存 responder，可以关闭 `use_unified_mem`，同时不注入
对应的 memory manager。

`pcie_svt_bridge_required=1` 在这里表示“外部引脚是唯一传输通路”：环境不会启动
RC↔EP 的 TLM loopback，adapter 的 monitor/driver 直接在 Intel 用户侧接口上完成
发送和接收。不要在同一条总线上同时创建另一套 RC/EP adapter，也不要把 bind wrapper
再接到 `tests/intel_pcie_env_test.sv` 的双 BFM 总线上；后者是独立的双端自测示例。

## 编译

bind 文件不加入默认 `sim/filelist_tests.f`，避免没有绑定目标时破坏普通回归。集成仿真
应在自己的 filelist 中追加：

```text
-f $INTEL_PCIE_ROOT/sim/filelist_lib.f
$INTEL_PCIE_ROOT/bind/intel_pcie_bind_wrapper.sv
$INTEL_PCIE_ROOT/tb/my_pcie_bind.sv
```

`INTEL_PCIE_DATA_WIDTH` / `INTEL_PCIE_SEGMENTS` 必须与目标端口一致。wrapper 只适配
用户侧时序，不建模 LTSSM、链路训练或配置空间；RX `ready` 的断续压力应通过 `tx_ready`
（对端 TX source 的 ready）和 credit 更新测试，R-Tile RX ready 按手册保持常高。

在指定 VCS 主机上运行仓库自带 smoke：

```bash
export INTEL_PCIE_ROOT=/path/to/pcie_intel
export PCIE_WORK_ROOT=/path/to/pcie_work
export HOST_MEM_ROOT=/path/to/host_mem
vcs -full64 -sverilog -ntb_opts uvm-1.2 -top tb_intel_pcie_bind_smoke \
  -f $INTEL_PCIE_ROOT/sim/filelist_bind.f \
  +define+INTEL_PCIE_DATA_WIDTH=256 +define+INTEL_PCIE_SEGMENTS=4 \
  -o simv_bind
./simv_bind
```

smoke 会检查两个 SIDE 的配置发布、输入采样和 supply 输出；将 bind 语句替换为真实
DUT 后仍需保留 `-f sim/filelist_lib.f` 的库编译顺序。

完整环境回归用两个独立 interface 经 wrapper 和 wire 网络对接，保持 credit 开启并
检查 parity；它复用公共 `pcie_tl_rw_seq`，没有直接共享 interface 的旁路。在独立构建目录
执行以下命令，避免覆盖普通回归二进制：

```bash
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
  -top tb_intel_pcie_bind_env -f $INTEL_PCIE_ROOT/sim/filelist_bind_env.f \
  -o simv_bind_env
./simv_bind_env +UVM_TESTNAME=intel_pcie_env_test
./simv_bind_env +UVM_TESTNAME=intel_pcie_env_stress_test
./simv_bind_env +UVM_TESTNAME=intel_pcie_env_max_boundary_test
```

上述 env 测试也会实际创建一个 env 之外的公共 adapter，确认初始化入口没有替换其他
环境的 adapter。绑定自测不包含真实 DUT；真实 DUT 接入时只保留与它相连的一端 VIP。
