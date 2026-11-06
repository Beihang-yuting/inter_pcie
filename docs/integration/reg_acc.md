# 通过 AIP reg_acc 访问 Intel 接口上的 DUT 寄存器

使用 `pcie_work/pcie_tl_pkg` 的 `pcie_tl_reg_seq`，注册到完整环境的
`pcie_env.rc_agent.sequencer`。已有 Intel env 配置和 bind 接线不需要改动。
需要同时更新支持位置参数/128 位数据的 `aip_core/update` 与新增该类的 `pcie_work`。

```systemverilog
// 测试包导入 uvm_pkg、aip_core_pkg、pcie_tl_pkg 后定义。
class my_reg_context;
    static uvm_sequencer_base pcie_sqr;
endclass
`aip_cmd_reg(reg_acc, pcie_tl_reg_seq, my_reg_context::pcie_sqr, seq.error_msg)

// 大 env.connect_phase：借用实际 requester，不传 Intel interface/bind 句柄。
my_reg_context::pcie_sqr = pcie_env.rc_agent.sequencer;
```

运行 `aip_tcl_bridge::run_loop()` 后，Tcl 可以使用：

```tcl
reg_acc write 0x80000000 4 0x11223344
reg_acc write 0x80000008 8 0x1122334455667788
reg_acc write 0x80000010 12 0x112233445566778899aabbcc
reg_acc write 0x80000020 16 0x112233445566778899aabbccddeeff00
reg_acc read 0x80000020 16
puts [aip_read_result]

# mask 默认 0，bit i=1 仅屏蔽 addr+i 字节，保留 DUT 原值。
reg_acc write 0x80000000 4 0xaabbccdd mask=0x2
# 原有写法仍可使用。
reg_acc op=read addr=0x80000000 len=4
```

`addr` 是完整 PCIe 字节地址，`len` 是 4/8/12/16 字节。
DWORD 对齐、单次不跨 4KB；小端数据低字节对应低地址，1024-bit 总线不改变此约定。
完整访问单 TLP，部分 mask 按连续未屏蔽字节拆分，不执行读改写、不保证跨 TLP 原子性。
读的屏蔽字节返回零；全屏蔽不产生 TLP。第四注册参数 `seq.error_msg` 将失败返回 Tcl。

完整字段和边界说明见 pcie_work 的 `docs/pcie_tl_reg_seq.md`。
AIP 的默认 mask 已由全 1 改为 0；其他总线原有使能语义需显式传值保持兼容。

## 验证入口

在 VCS 主机设置 `INTEL_PCIE_ROOT`、`PCIE_WORK_ROOT`、`HOST_MEM_ROOT`、
`AIP_CORE_ROOT`，后者必须指向包含本次解析扩展的 AIP 工作树：

```bash
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
    -debug_access+all -top tb_intel_pcie_aip_reg \
    -f "$INTEL_PCIE_ROOT/sim/filelist_aip_reg.f" -o simv_reg
./simv_reg
./simv_reg +HIGH_ADDR +LITTLE_HEADER
./simv_reg +AIP_TCL -ucli -do "$INTEL_PCIE_ROOT/tests/aip/intel_pcie_reg.tcl"
```

默认 4x256。SV 模式检查连续四种长度、稀疏/全 mask、原始 RX Header/data、读回和 SCB；
`HIGH_ADDR` 覆盖 4DW Header，`LITTLE_HEADER` 覆盖另一种 Header DWORD 排列。
Tcl 模式验证真正的命令行 bridge；成功必须同时检查 PASS 标记与 UVM_ERROR/FATAL 计数。

本次执行结果和源码快照见 [reg_acc 验证记录](../validation-reg-acc.md)。
