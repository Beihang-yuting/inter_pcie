// tests：Intel 引脚链路的有界深度压力测试；依赖 intel_pcie_env_test 建立的真实 adapter/env。
// 本文件只编排公共 pcie_tl_rw_seq，不复制事务层实现；测试拥有 golden/保护区并在结束释放内存。
class intel_pcie_env_stress_test extends intel_pcie_env_test;
    `uvm_component_utils(intel_pcie_env_stress_test)

    function new(string name="intel_pcie_env_stress_test", uvm_component parent=null);
        super.new(name,parent);
    endfunction

    // 检查读回长度及每一个字节；失败只影响当前 case，便于其它边界继续执行。
    function automatic bit check_bytes(bit [7:0] got[], byte exp[], int n, string tag);
        bit ok = (got.size() == n);
        if (!ok) `uvm_error("STRESS_LEN", $sformatf("%s got=%0d exp=%0d",tag,got.size(),n))
        for (int i=0; i<n && i<got.size(); i++) begin
            if (got[i] !== exp[i]) begin
                `uvm_error("STRESS_DATA", $sformatf("%s byte %0d exp=%02h got=%02h",tag,i,exp[i],got[i])); ok=0;
                break;
            end
        end
        return ok;
    endfunction

    // 在指定 requester 上执行一次写后读，并检查前后各 64B 保护区未被改写。
    // exact4k=1 时将请求放在页尾，恰好在 4KiB 边界结束；跨界请求不属于
    // CONSTRAINT_LEGAL 的正常流量，由独立负例测试负责验证。
    task automatic do_case(int side, int n, bit exact4k,
                           output bit passed);
        host_mem_api mem; pcie_tl_rw_seq wr,rd; bit [63:0] alloc_base,base; byte exp[], guard[]; bit ok;
        passed = 1'b0;
        mem = (side==0) ? env.dev_mem[0] : env.host_mem;
        alloc_base = mem.alloc(n+12288,4096);
        // manager 返回值可能只是 64B 对齐；在申请区内部选整页并预留 guard。
        base = ((alloc_base + 4095) & ~64'hfff) + 64;
        exp=new[n]; guard=new[64];
        foreach(exp[i]) exp[i]=byte'((i*37+n+side)&8'hff);
        foreach(guard[i]) guard[i]=8'he7;
        // 主压力始终使用页内合法请求；边界专项恰好结束在下一页起点。
        if (exact4k) base = (base & ~64'hfff) + (4096 - n);
        mem.write_mem(base-64,guard); mem.write_mem(base+n,guard);
        wr=pcie_tl_rw_seq::type_id::create($sformatf("wr_%0d_%0d",side,n));
        wr.op=PCIE_RW_WRITE; wr.addr=base; wr.byte_len=n; wr.wdata=new[n];
        foreach(wr.wdata[i]) wr.wdata[i]=exp[i];
        if(side==0) wr.start(env.rc_agent.sequencer); else wr.start(env.ep_agent.sequencer);
        rd=pcie_tl_rw_seq::type_id::create($sformatf("rd_%0d_%0d",side,n));
        rd.op=PCIE_RW_READ; rd.addr=base; rd.byte_len=n;
        if(side==0) rd.start(env.rc_agent.sequencer); else rd.start(env.ep_agent.sequencer);
        ok=(rd.status==PCIE_RW_OK) && check_bytes(rd.rdata,exp,n,$sformatf("s%0d/%0d",side,n));
        begin
            byte g0[],g1[]; bit gok=1;
            mem.read_mem(base-64,64,g0); mem.read_mem(base+n,64,g1);
            for (int q=0;q<64;q++) begin
                if (g0[q]!==guard[q] || g1[q]!==guard[q]) begin gok=0; break; end
            end
            if (!gok) begin ok=0; `uvm_error("STRESS_GUARD", "保护区被事务修改"); end
        end
        if (!ok) `uvm_error("STRESS_CASE", $sformatf("side=%0d len=%0d exact4k=%0d status=%s",side,n,exact4k,rd.status.name()))
        passed = ok;
        mem.free(alloc_base);
    endtask

    // 四个 worker 各执行 32 个合法页内事务；并发重叠由 sequencer/Tag 路径实测。
    // pcie_work 的默认 MPS=256B，因此单个 rw_seq case 限制在 1..256B；
    // 更大的 PCIe TLP 需要先由上层做 MPS 分片，不能直接塞给 rw_seq。
    task run_phase(uvm_phase phase);
        int success_cases=0, success_bytes=0;
        int worker_cases[4] = '{0,0,0,0};
        int worker_bytes[4] = '{0,0,0,0};
        phase.raise_objection(this);
        for (int w=0; w<4; w++) begin
            automatic int ww=w;
            fork
                begin
                    for (int j=0;j<32;j++) begin
                        int n = 1 + ((j*73 + ww*19) % 256);
                        bit passed;
                        do_case(ww%2,n,0,passed);
                        if (passed) begin
                            worker_cases[ww]++;
                            worker_bytes[ww] += n;
                        end
                    end
                end
            join_none
        end
        wait fork;
        for (int w=0; w<4; w++) begin
            success_cases += worker_cases[w];
            success_bytes += worker_bytes[w];
        end
        if (success_cases != 128)
            `uvm_error("STRESS_COUNT", $sformatf("passed=%0d expected=128",success_cases));
        `uvm_info("RTILE_TEST_PASS", $sformatf("cases=%0d bytes=%0d",success_cases,success_bytes), UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass

// 最大合法包及 4KiB 边界专项保持独立，便于单独运行和定位边界问题。
class intel_pcie_env_max_boundary_test extends intel_pcie_env_stress_test;
    `uvm_component_utils(intel_pcie_env_max_boundary_test)
    function new(string name="intel_pcie_env_max_boundary_test", uvm_component parent=null); super.new(name,parent); endfunction
    // 只执行两个 256B 页尾读写；请求恰好结束在 4KiB 边界，属于合法流量。
    task run_phase(uvm_phase phase);
        bit passed0, passed1;
        phase.raise_objection(this); fork
            do_case(0,256,1,passed0); do_case(1,256,1,passed1);
        join `uvm_info("MAX_BOUNDARY", "256-byte exact-4KiB-boundary cases completed", UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass
