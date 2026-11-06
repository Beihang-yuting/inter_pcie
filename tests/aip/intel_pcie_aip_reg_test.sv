// tests/aip：真实 AIP launch→公共 reg_seq→Intel 4x256 bind 的端到端回归。
// 依赖先编译 aip_core_pkg、现有 Intel 测试包与双 wrapper fixture；不含 SVT。
// test 独占命令 sequencer 句柄、期望队列和后备内存；monitor 手工拆 Header，
// 不用产品 codec 自证。+AIP_TCL 模式交给真实 Tcl bridge，SV 模式覆盖连续业务。
package intel_pcie_aip_reg_test_pkg;
    import uvm_pkg::*;
    import aip_core_pkg::*;
    import host_mem_pkg::*;
    import pcie_tl_pkg::*;
    import intel_pcie_adapter_pkg::*;
    import intel_pcie_tests_pkg::*;
    `include "uvm_macros.svh"

    // 命令只借用完整 env 的 requester sequencer，生命周期由 env 管理。
    class intel_reg_context;
        static uvm_sequencer_base	sqr;
        static bit [63:0]	base;
        // 仅测试入口公开实际分配地址，避免 Tcl 假设 allocator 的块选择策略。
        static task get_base();
            aip_cmd::set_result(0, $sformatf("0x%0h", base));
        endtask
    endclass
    `aip_cmd_reg(reg_acc, pcie_tl_reg_seq, intel_reg_context::sqr, seq.error_msg)
    `aip_cmd_task(reg_test_base, intel_reg_context::get_base)

    // 复用完整 env/SCB/双向 Completion，测试拥有已分配的 4KB 寄存器区域。
    class intel_pcie_aip_reg_test extends intel_pcie_env_test;
        `uvm_component_utils(intel_pcie_aip_reg_test)
        typedef struct packed {
            bit	           write_access;
            bit [63:0]	    address;
            int unsigned	 bytes;
            bit [127:0]	   data;
        } pin_request_t;
        pin_request_t	         expected_pins[$];
        intel_pcie_if_adapter	 hip;
        intel_pcie_vif_t	       bus;
        int	                    observed;
        int	                    requests;
        int	                    reads;
        int	                    commands;
        bit [63:0]	             base;

        // UVM 标准构造，全部业务输出按 test 实例隔离。
        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        // 在 env connect 前初始化注入内存，分别测试 3DW 与 4DW 地址格式。
        function void build_phase(uvm_phase phase);
            bit [63:0]	region_base;
            super.build_phase(phase);
            region_base = $test$plusargs("HIGH_ADDR") ? 64'h1_80000000 : 64'h80000000;
            device_manager.init_region(region_base, region_base + 65535);
        endfunction

        // 将命令的有效字节区间登记为期望；全 mask 不登记任何 TLP。
        // 每个期望保留原始数据，独立引脚监视器检查字节落点、BE 和地址格式。
        function void expect_request(bit wr, bit [63:0] address, int length_bytes,
                                     bit [127:0] data, int unsigned masked);
            int	first;
            int	i;
            pin_request_t	e;
            i = 0;
            while (i < length_bytes) begin
                if (masked[i]) begin i++; continue; end
                first = i;
                while (i < length_bytes && !masked[i]) i++;
                e.write_access = wr;
                e.address = address + first;
                e.bytes = i - first;
                e.data = data >> (first * 8);
                expected_pins.push_back(e);
                requests++;
                if (!wr) reads++;
            end
        endfunction

        // Header 通过原始 DW 位域解码；只在 hvalid 时消费期望，逐使能字节检查 payload。
        task watch_pins();
            forever begin
                @(bus.monitor_cb);
                if (bus.monitor_cb.rst_n !== 1'b1) continue;
                for (int s = 0; s < INTEL_SEGMENTS; s++) begin
                    pin_request_t	e;
                    logic [31:0]	dw[4];
                    bit [63:0]	a;
                    bit [7:0]	be;
                    int	words;
                    int	offset;
                    if (!bus.monitor_cb.rx_hvalid[s]) continue;
                    if (expected_pins.size() == 0) `uvm_fatal("REG_PIN", "unexpected request")
                    e = expected_pins.pop_front();
                    for (int j = 0; j < 4; j++)
                        dw[j] = hip.cfg.header_big_endian ? bus.monitor_cb.rx_hdr[s][127-j*32 -: 32]
                                                         : bus.monitor_cb.rx_hdr[s][j*32 +: 32];
                    a = dw[0][29] ? {dw[2], dw[3]} : {32'b0, dw[2]};
                    offset = e.address[1:0];
                    words = (offset + e.bytes + 3) / 4;
                    be = 0;
                    for (int lane = 0; lane < words*4; lane++) begin
                        if (lane < offset || lane >= offset + e.bytes) continue;
                        if (lane < 4) be[lane] = 1;
                        if (words > 1 && lane >= (words-1)*4) be[4+lane%4] = 1;
                        if (e.write_access && bus.monitor_cb.rx_data[s][lane*8 +: 8] !== e.data[(lane-offset)*8 +: 8])
                            `uvm_fatal("REG_PIN", "payload lane/value mismatch")
                    end
                    if (a !== {e.address[63:2],2'b0} || dw[0][9:0] !== 10'(words) ||
                        dw[0][31:29] !== {1'b0,e.write_access,(e.address[63:32] != 0)} ||
                        dw[0][28:24] !== 5'b0 || dw[1][7:0] !== be || dw[0][15] !== 1'b0 ||
                        bus.monitor_cb.rx_dvalid[s] !== e.write_access ||
                        bus.monitor_cb.rx_pvalid[s] !== 1'b0 ||
                        bus.monitor_cb.rx_sop[s] !== 1'b1 || bus.monitor_cb.rx_eop[s] !== 1'b1)
                        `uvm_fatal("REG_PIN", $sformatf("addr=%016h expected=%016h words=%0d BE=%02h header=%08h_%08h_%08h_%08h", a,e.address,words,be,dw[0],dw[1],dw[2],dw[3]))
                    observed++;
                end
            end
        endtask

        // 走真实 AIP 派发，不直接调用 sequence；失败必须有 ERROR 文本及非零状态。
        task command(string text, bit success, string expected = "");
            int	st;
            string	result;
            aip_cmd::exec_result(text, SRC_INTERNAL, st, result);
            if ((st == 0) != success || (expected != "" && expected != result))
                `uvm_fatal("REG_CMD", $sformatf("%s => %0d %s expected %s", text, st, result, expected))
            commands++;
        endtask

        // 命名与位置语法交替使用；读回预期来自独立标量，不从已发 TLP 反算。
        task access(bit wr, bit [63:0] address, int n, bit [127:0] value,
                    int unsigned masked = 0, bit named = 0);
            string	text;
            string	op;
            if (wr) op = "write";
            else op = "read";
            expect_request(wr, address, n, value, masked);
            if (named)
                text = $sformatf("reg_acc op=%s addr=0x%0h len=%0d data=0x%0h mask=0x%0h",
                                 op, address, n, wr ? value : 128'b0, masked);
            else begin
                text = $sformatf("reg_acc %s 0x%0h %0d", op, address, n);
                if (wr) text = {text, $sformatf(" 0x%0h", value)};
                if (masked != 0) text = {text, $sformatf(" mask=0x%0h", masked)};
            end
            command(text, 1, wr ? "" : $sformatf("rdata=0x%0h", value));
        endtask

        // 每种长度连续访问 32 次，稀疏 mask 后整块读回证明被屏蔽字节保留原值。
        // 还验证全屏蔽、边界、溢出及非法访问不会产生额外引脚流量。
        task exercise();
            bit [127:0]	value;
            bit [127:0]	merged;
            bit [127:0]	new_value;
            bit [127:0]	read_masked;
            int unsigned	masked;
            int	n;
            bit [63:0]	a;
            byte	backdoor[];
            for (int i = 0; i < 128; i++) begin
                n = 4 * (i % 4 + 1);
                a = base + i*16;
                value = 0;
                for (int b = 0; b < n; b++) value[b*8 +: 8] = 8'(i*17 + b*11 + 1);
                access(1, a, n, value, 0, i%2);
                access(0, a, n, value, 0, !(i%2));
                env.dev_mem[0].read_mem(a, n, backdoor);
                foreach (backdoor[b])
                    if (backdoor[b] !== value[b*8 +: 8]) `uvm_fatal("REG_MEM", "backdoor differs")
            end
            for (int width_index = 1; width_index <= 4; width_index++) begin
                n = width_index*4;
                a = base + 2048 + width_index*32;
                value = 128'h112233445566778899aabbccddeeff00 >> (128-n*8);
                new_value = 128'hffeeddccbbaa99887766554433221100 >> (128-n*8);
                masked = 32'haaaa & ((1 << n)-1);
                merged = new_value;
                read_masked = 0;
                for (int b = 0; b < n; b++) begin
                    if (masked[b]) merged[b*8 +: 8] = value[b*8 +: 8];
                    else read_masked[b*8 +: 8] = new_value[b*8 +: 8];
                end
                access(1, a, n, value);
                access(1, a, n, new_value, masked);
                access(0, a, n, merged);
                access(0, a, n, read_masked, masked);
                access(1, a, n, 0, (1 << n)-1);
                access(0, a, n, merged);
                access(0, a, n, 0, (1 << n)-1);
            end
            access(1, base+4080, 16, '1);
            access(0, base+4080, 16, '1);
            command($sformatf("reg_acc write 0x%0h 3 0",base), 0);
            command($sformatf("reg_acc write 0x%0h 4 0",base+1), 0);
            command($sformatf("reg_acc write 0x%0h 16 0",base+4092), 0);
            command($sformatf("reg_acc write 0x%0h 4 0x100000000",base), 0);
            command($sformatf("reg_acc write 0x%0h 4 0 mask=0x10",base), 0);
            command("reg_acc write 0xfffffffffffffffc 8 0", 0);
        endtask

        // SV 流量与引脚观察并行；Tcl 模式只运行 bridge，供 -ucli -do 测试脚本调用。
        task run_phase(uvm_phase phase);
            phase.raise_objection(this);
            intel_reg_context::sqr = env.rc_agent.sequencer;
            base = env.dev_mem[0].alloc(4096,4096);
            intel_reg_context::base = base;
            if (!$cast(hip,env.rc_adapter)) `uvm_fatal("REG_ADAPTER", "missing Intel adapter")
            bus = hip.avst_vif;
            if ($test$plusargs("AIP_TCL")) begin
                aip_tcl_bridge::run_loop();
                `uvm_info("REG_TCL_SV_PASS", "Tcl bridge returned", UVM_LOW)
            end else begin
                fork : workers
                    watch_pins();
                    begin exercise(); #40ns; end
                join_any
                disable workers;
                if (expected_pins.size() != 0 || observed != requests)
                    `uvm_fatal("REG_COUNT", "pending/observed request count mismatch")
                check_scb_counts(requests,reads,reads);
                `uvm_info("REG_BIND_PASS", $sformatf("commands=%0d raw_requests=%0d reads=%0d base=%016h endian=%0d", commands,observed,reads,base,hip.cfg.header_big_endian), UVM_LOW)
            end
            env.dev_mem[0].free(base);
            phase.drop_objection(this);
        endtask
    endclass
endpackage

// 复用产品双 wrapper 接线，顶层只设置 Header 顺序与奇偶校验，不修改 bind 文件。
module tb_intel_pcie_aip_reg;
    timeunit 1ns;
    timeprecision 1ps;
    import uvm_pkg::*;
    import intel_pcie_aip_reg_test_pkg::*;
    intel_pcie_bind_env_link link();
    initial begin
        #0;
        link.hard_bind.cfg.header_big_endian = !$test$plusargs("LITTLE_HEADER");
        link.application_bind.cfg.header_big_endian = !$test$plusargs("LITTLE_HEADER");
        link.hard_bind.cfg.check_parity = 1;
        link.application_bind.cfg.check_parity = 1;
        run_test("intel_pcie_aip_reg_test");
    end
    initial begin
        #1ms;
        $fatal(1, "AIP register integration watchdog expired");
    end
endmodule
