# Intel R-Tile Avalon-ST PCIe Adapter 设计规格

## 目标

在当前仓库增加 Intel Agilex R-Tile PCIe Avalon-ST UVM/BFM 适配层，使 R-Tile 用户侧接口能够复用 `pcie_work/pcie_tl_vip` 中已有的 `pcie_tl_tlp`、Transaction Layer sequence、Tag/Completion和环境。适配层的使用方式、工厂覆盖方式和文件组织参考 `xillinx_pcie` 的 `adapter-mode`。

本规格于2026-10-30按手册时序复核及实际实现修订；初始设计已获用户“开始吧”授权。这里描述最终结构，具体仿真结果单独记录在[验证记录](../../validation.md)。

默认覆盖 R-Tile 1×16、double-width、四个 256-bit segment 的端口；编译参数接受256×1/2/4、128×1/2，2×256可显式选择x16 single-width。单次编译各端口使用同一几何配置。

## 依赖与边界

`pcie_work` 通过 `PCIE_WORK_ROOT` 作为外部只读依赖，filelist 编译其 `pcie_tl_vip/src`；独立 `host_mem` 通过 `HOST_MEM_ROOT` 引用。本适配层不复制 TLP 类型、TLP codec、sequence 或环境代码。公共FC以DWORD计数，本项目为AVST的16-byte单位单独实现credit manager，要求公共FC置infinite或关闭有限门控。

适配层负责：

1. 把 `pcie_tl_tlp` 映射为 R-Tile Avalon-ST 的 Header、Prefix、Payload 和 segment 控制信号。
2. 根据显式wire-side收取RX或TX stream，按segment顺序重组为 `pcie_tl_tlp`。
3. 封装 R-Tile 的 RX/TX ready 和信用接口约束。
4. 提供与 `pcie_tl_if_adapter` 相同的 `send()`/`receive()` 抽象和 UVM 工厂替换点。

适配层不负责 PCIe LTSSM、链路训练、配置空间、BAR 地址译码或 TLP 协议判定；这些由硬核或 `pcie_work` 的协议层负责。

## 组件

### `intel_pcie_if`

定义一个 R-Tile 端口的 `coreclkout_hip` 时钟、复位、RX/TX Avalon-ST 信号以及信用信号。每个 segment 包含：

- `data[DATA_W-1:0]`、`hdr[127:0]`、`prefix[31:0]`；
- `sop`、`eop`、`dvalid`、`hvalid`、`pvalid`；
- RX 的 `empty`、BAR、PF/VF 元数据；
- 可选 parity 信号。

RX的ready归APPLICATION所有并固定为1；TX的ready归HARD_IP所有。接口采样使用posedge input #1step，BFM所有输出集中在negedge驱动。

### `intel_pcie_if_adapter`

继承 `pcie_tl_if_adapter`，通过工厂覆盖安装到 `pcie_tl_env`。wire-side与RC/EP协议角色分开：APPLICATION发TX收RX，HARD_IP发RX收TX。默认名字 `rc_adapter*` 对应HARD_IP，`ep_adapter*` 对应APPLICATION；自定义名字或真实RP用户DUT连接应显式配置方向。

Header和Prefix只在SOP段有效。单一时钟worker一次组织整个beat，按segment顺序填充Payload，不为每个segment单独等待时钟。1×16 double-width只从st0/st2起包；st2起包必须由前面有数据包在st0/st1结束后接续。仅Header包保守地从新拍开始，不使用手册表58/59未列明的后继组合。

TX状态保存当前TLP和字节偏移。ready拉低后可配置1～16拍停发延迟，窗口内每个valid beat继续推进，不能保持同一beat反复发送。停发后保存未发送偏移；ready恢复后最多1拍续传，不重复SOP。公共send阻塞到EOP采样，send_batch额外支持同拍多包调度。

RX 监视每个 segment。每个有效 segment 按 segment 编号进入当前 TLP 重组器；SOP 创建 TLP 上下文，Header/Prefix 在 SOP 段采集，DVALID 段采集 Payload，EOP 段依据 `empty` 删除尾部无效 DWORD 并完成 TLP。RX 允许 SOP/EOP 之间存在无效数据段，重组器不能把 `dvalid=0` 的段当作 Payload。

接收完整packet放入adapter私有队列；receive为空时返回null，有包时解码并归还信用。adapter只监视相反方向，不形成TX自回环。有效Header/Prefix/Payload的X在转为公共2-state类型前报错；无效padding不检查。

复位丢弃半包和全部队列、重新初始化信用，并以RTILE_RESET_ABORT报告已入队send的中止。公共driver/Tag/sequence的取消与重启由调用者协调。

### `intel_pcie_credit_manager`

每adapter独占六类本地缓冲计数与对端可用信用镜像。sink发init/update/count，source发ACK，不能接反。初始化依次经过WAIT_ACK、ADVERTISE、GAP_ONE、GAP_TWO、RUN；容量按Header≤3、Data≤15的增量拆分，末次update之后至少两个空拍才撤销init。每一类可单独公告无限信用。

SOP前预留整个包的一个Header及ceil(Payload/16)个Data信用，receive出队时归还。有限Data初始容量>32；HIP模拟RX时，某类别Data信用<32不再起新包。上游公共FC无限不等于AVST流控关闭。

### `intel_pcie_adapter_pkg`

只集中包含产品类型、codec、reassembler、credit和adapter；接口提前编译。测试单独进入tests package，连接宏独立放在tb，库filelist不混入测试。

## 数据与时序约束

1. RX `ready` 始终为 1。应用侧缓冲通过 RX credit 接口表达，不能用 Avalon-ST ready 反压。
2. RX解析顺序为 `st0 → st1 → st2 → st3 → st0`；同拍最多3个SOP。SOP可在任意segment，但量产器件不允许st0/st1同时闲置而仅使用st2/st3。
3. RX `empty` 仅在 EOP 段有效，单位为 DWORD，尾部有效字节数按 DWORD 对齐计算。
4. TX 必须在 `ready=1` 时开始；从 SOP 到 EOP 之间不能主动插入空拍。
5. TX `ready` 拉低后，最多 16 个时钟周期内撤销 `valid`；有暂停 TLP 时 ready 恢复后最多 1 个时钟周期续传。
6. TX 发送的数据拍数必须与 TLP Header 的长度一致，否则硬核可能停止接受后续 TLP。
7. Header big/little改变DWORD摆放、不改变DWORD内位域；Prefix始终big；Payload低字节先传。无数据包不能因dvalid=0被丢弃。
8. 保留BAR/PF/完整11-bit VF，但AVST没有完整BAR aperture/offset，不能伪造cq_route.valid。

## 验证

验证在用户指定的10.11.10.53 VCS主机执行，5.6模型执行并分析日志，Astra负责代码和最终审查。场景包括：

- codec round-trip：无数据、单段 Payload、跨四段 Payload、Prefix、不同 Header 长度；
- RX 重组：任意 SOP segment、跨拍回绕、EOP/empty、包内 dvalid 空段、多 TLP 同拍；
- TX 时序：st0/st2 起包限制、连续发送、ready 撤销 16 拍窗口、恢复后 1 拍续传；
- 信用：Header与Data分别耗尽、RX32门槛、出队后精确归还、有限/无限初始化；
- adapter：工厂覆盖、双向send/receive、半包复位、反复ready低高；
- 公共env：复用transport bridge、requester/responder、Tag和统一内存，用rw_seq双向非对齐读写137 B。

## 已知范围

实现了用户侧AVST信用初始化与有限流控，不实现PCIe链路层训练/DLLP或Quartus硬核。不是可综合RTL。真实硬核的Tag allocation与ID改写需另外接入，公共模型现有Tag管理不能自动代替硬核侧边带协议。

普通非TL-Bypass模式最多一个Prefix；ECRC由硬核生成/剥离，拒绝CRC注入。有效包可保持TD，但Payload不附Digest。公开错误不做无声修复；畸形流量的信用恢复依赖测试判失败后复位。完整接入方法和其余限制见[接入说明](../../integration.md)。
