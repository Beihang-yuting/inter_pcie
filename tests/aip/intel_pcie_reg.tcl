# tests/aip：真实 Tcl bridge 的宽寄存器访问；需 +AIP_TCL 和默认低地址 fixture。
# 脚本持有独立十六进制期望值，不使用 SV sequence 输出构造期望。
source $::env(AIP_CORE_ROOT)/src/tcl/aip_cmd.tcl
set checks 0
proc check_reg {condition text} {
    if {!$condition} { error "REG_TCL_FAIL: $text" }
    incr ::checks
}
set start_base [reg_test_base]
set base $start_base
foreach n {4 8 12 16} {
    # 使用固定字面量，避免不同 UCLI Tcl 版本的 format %x 窄化宽数据。
    set hex [dict get {4 0xddeeff00 8 0x99aabbccddeeff00 12 0x5566778899aabbccddeeff00 16 0x112233445566778899aabbccddeeff00} $n]
    reg_acc write $base $n $hex
    check_reg [expr {[aip_check_status] == 0}] "write $n"
    reg_acc read $base $n
    check_reg [expr {[aip_read_result] eq "rdata=$hex"}] "wide read $n"
    reg_acc op=write addr=$base len=$n data=0 mask=0x2
    check_reg [expr {[aip_check_status] == 0}] "masked write $n"
    reg_acc read $base $n
    check_reg [expr {[aip_read_result] eq "rdata=0xff00"}] "masked byte retained $n"
    set base [expr {$base+32}]
}
reg_acc read $start_base
check_reg [expr {[aip_read_result] eq "rdata=0xff00"}] "default read length"
reg_acc write $start_base 4 0x100000000
check_reg [expr {[aip_check_status] != 0}] "reject len overflow"
reg_acc write $start_base 16 0x100000000000000000000000000000000
check_reg [expr {[aip_check_status] != 0}] "reject 128-bit overflow"
puts "REG_TCL_PASS checks=$checks"
end_test drain=100ns
# ACK 暂停后继续推进，让 bridge 返回、UVM check/report_phase 真正执行。
run
