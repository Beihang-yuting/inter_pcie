# R-Tile 用户侧接口信号与时序

依据用户上传的《R-Tile Avalon Streaming IP for PCI Express User Guide》，UG-20316，2026.01.29。RX 为 §4.3.1.3（pp.81–87），TX 为 §4.3.1.4（pp.87–95）；流控需同时阅读 §4.3.1.2（pp.75–81）。以下方向都以**硬核 HIP**为参照。

## 端口与 segment

`pX` 是 PCIe 端口，`stN` 是该端口内的 segment。默认 1×16 double-width：一个时钟有 st0～st3，各含 256-bit Data、128-bit Header、32-bit Prefix；Payload 总宽度是 1024 bit。四个 segment 不是四个互相独立的 TLP 通道。

包内数据、同拍多包均按 `st0 → st1 → st2 → st3 → 下一拍 st0` 排序。一个 TLP 可以跨多个 segment 和时钟，一拍也可以结束前一个包并开始后一个包。

## 信号对应

本项目使用数组 `rx_*[N]` / `tx_*[N]` 对应手册的 `pX_rx_stN_*_o` / `pX_tx_stN_*_i`。

| 信号 | 每段宽度 | RX 方向 / TX 方向 | 采样意义 |
| --- | --- | --- | --- |
| `data` | 默认256 bit | HIP→应用 / 应用→HIP | Payload；由 `dvalid` 限定 |
| `hdr` | 128 bit | HIP→应用 / 应用→HIP | 3DW/4DW TLP Header；由 `hvalid` 限定，随 SOP |
| `prefix` | 32 bit | HIP→应用 / 应用→HIP | 第一个 TLP Prefix；由 `pvalid` 限定，随 SOP |
| `sop` / `eop` | 各1 bit | HIP→应用 / 应用→HIP | 有效段内的包首 / 包尾，可以同段同时为1 |
| `hvalid` / `dvalid` / `pvalid` | 各1 bit | HIP→应用 / 应用→HIP | Header / Data / Prefix 分别有效，不能用一个 valid 代替三者 |
| `empty` | 3 bit，仅RX | HIP→应用 | EOP 数据段尾部无效 DWORD 数；256-bit段有效字节=`32−4×empty` |
| `bar` / `pfnum` | 各3 bit，仅RX | HIP→应用 | SOP 携带的 BAR / 物理功能号 |
| `vfactive` / `vfnum` | 1 / 11 bit，仅RX | HIP→应用 | SOP 指示是否VF；VF号仅在 `vfactive=1` 有效 |
| `data_par` / `hdr_par` / `prefix_par` | 8 / 4 / 1 bit（256-bit段） | HIP→应用 / 应用→HIP | 每32 bit取一次XOR；需按对应valid校验 |
| `rx_ready` | 每端口1 bit | 应用→HIP | 必须常高，不能用它反压RX |
| `tx_ready` | 每端口1 bit | HIP→应用 | 控制应用TX启停，响应有规定的时钟延迟 |

无 Payload 的 MRd 等包仍有 Header、SOP、EOP，`dvalid=0` 也必须接收。无效段上的 SOP/EOP 不代表实际包边界。

Header big 模式中 H0 在 `[127:96]`；little 模式中 H0 在 `[31:0]`。切换的是 DWORD 的位置，DWORD 内 PCIe 位域不翻转。Prefix 始终 big endian；Payload 第一个字节放在该段 `data[7:0]`。

## RX：有效数据有空隙，空间由 credit 保证

1. `rx_ready=1`；每个有效段按序消费。
2. SOP 接收 Header 和可选 Prefix，建立本包上下文。
3. `dvalid=1` 才加入 Payload。SOP/EOP 之间可以出现空段或整拍空闲，半包状态必须保留。
4. EOP 根据 `empty` 去掉末段无效 DWORD，实际 Payload 长度必须等于 Header 声明长度。
5. 同拍最多3个 SOP。SOP 可在任意段，但量产器件在 st0、st1 均未使用时，不会只使用 st2、st3（p.87列明适用器件）。

图31的两个独立例子可以理解为：

| 包 | 起点 | 数据分布 | 终点 |
| --- | --- | --- | --- |
| T0，36 B | 当前拍st1 | st1=32 B，st2=4 B | st2 EOP，`empty=7` |
| T1，108 B | 当前拍st1 | st1/st2/st3各32 B，下一拍st0=12 B | 下一拍st0 EOP，`empty=5` |

用户提出的“对端没准备好”测试，在RX应表现为：应用不释放缓冲 → 不归还信用 → HIP停止起新包 → 应用取走旧包并归还信用 → HIP恢复。拉低RX ready属于协议违规负例，不是合法的接收反压场景。

## TX：连续供数与延迟停发

- HIP先置 `tx_ready=1`，应用才能开始发送。
- 1×16 double-width 的 SOP 只能出现在st0或st2。st2起新包还必须满足表58：前面的有数据包在st0或st1结束；不能在前两段空闲时单独从st2起包。
- 表59给出较小double-width配置中st1起包的条件；x16 single-width每拍只能有一个SOP。
- ready维持高时，SOP至EOP不得主动插空；Header、Payload拍数和EOP必须与Length一致。TX没有 `empty`，末段有效字节数从Header推导。
- ready拉低后，应用最多用16个时钟停发。允许窗口内已经推出的有效数据继续前进，不能冻结一个beat反复发送。
- 如果停在半包，ready重新拉高后最多1个时钟恢复剩余Payload，不能重复SOP或旧数据。

本BFM在下降沿驱动、上升沿前采样。以停发延迟1拍为例：

| 采样沿 | TX ready | TX数据 | 解释 |
| --- | --- | --- | --- |
| k | 1 | D0（含SOP） | 开始包 |
| k+1 | 0 | D1 | 已推出的延迟拍，仍消费 |
| k+2…m | 0 | 无valid | 保存下一段偏移，暂停 |
| m+1 | 1 | 无valid | 观察到ready恢复 |
| m+2 | 1 | D2 | 从未发送位置续传 |

因此接收端不能只在 `ready && valid` 时计数，否则会丢掉D1。独立波形检查应核对全部有效Payload字节，检测漏拍、重放、超16拍停发或超过1拍续传。

## 六类信用及引脚所有权

Posted、Non-Posted、Completion各有Header和Data两类信用。1 Header credit包含该包Header、可选Prefix/Digest；1 Data credit为**16字节**，一个包消耗 `ceil(Payload字节数/16)`，无数据包消耗0个Data credit。

| 接口 | sink负责 init / update / count | source负责 init_ack |
| --- | --- | --- |
| RX credit | 应用 | HIP |
| TX credit | HIP | 应用 |

Header每类计数增量宽2 bit，每次最多3；Data每类宽4 bit，每次最多15。P/NP/CPL依次放在低、中、高字段。sink先拉高init，收到ACK后分拍公布容量；最后update与init撤销之间至少两个完整空拍。初始化时 `update=1, count=0` 表示无限信用，不能当成零容量；运行期零增量不能改变有限/无限属性。

有限Data初始信用必须超过32。手册还指出RX可用信用低于32时HIP暂停TLP传递；本BFM在所属类别Data信用低于32时停止新SOP，已经预留完整空间的半包继续。完整包空间在SOP之前预留，接收后到 `receive()` 出队才归还，避免缓冲尚占用就虚报可用空间。

`pcie_work` 的公共FC数据计数使用DWORD，不能直接接入这些16-byte增量。本实现要求公共FC用 `infinite_credit=1` 或关闭其有限门控；实际AVST有限信用由适配器自己的manager处理。
