// tests：真实复用 pcie_tl_env、双向 requester/responder、统一内存与 rw_seq 的集成回归。
// 依赖 pcie_work 当前 main 的外部 transport bridge hook；不重新实现 Tag/Completion。
// test 拥有 env 和两侧独立 memory manager，env 只持有注入句柄并初始化；
// 每次分配在读回完成后释放，manager 存活到整个测试结束。
class intel_pcie_env_test extends uvm_test;
    `uvm_component_utils(intel_pcie_env_test)
    pcie_tl_env env;
    host_mem_manager host_manager, device_manager;

    // 标准 UVM 构造，全部上下文由 env 在 build/connect 时建立。
    function new(string name="intel_pcie_env_test", uvm_component parent=null);
        super.new(name,parent);
    endfunction

    // 沿用 Xilinx 的工厂替换入口；使用 upstream 已有 bridge 避免复制 responder。
    // hook 历史名称带 svt，但这里只启用 monitor->driver 转交，不引入 SVT 依赖。
    function void build_phase(uvm_phase phase);
        pcie_tl_env_config c;
        string why;
        super.build_phase(phase);
        pcie_tl_if_adapter::type_id::set_type_override(intel_pcie_if_adapter::get_type());
        c=pcie_tl_env_config::type_id::create("cfg");
        c.if_mode=SV_IF_MODE; c.infinite_credit=1;
        c.rc_agent_enable=1; c.ep_agent_enable=1; c.ep_auto_response=1;
        c.use_unified_mem=1; c.scb_enable=0;
        c.cpl_timeout_ns=100000;
        // upstream 当前 main 要求显式提供 Host；Device 也需注入独立句柄，
        // 否则仅打开 use_unified_mem 不能得到实际可分配的 backing memory。
        host_manager=new("host_manager"); device_manager=new("device_manager");
        host_manager.set_host_id(0);
        if(!c.bind_host_memory(0,0,host_manager,why))
            `uvm_fatal("TEST_MEMORY", why)
        uvm_config_db#(host_mem_api)::set(this,"env","dev_mem_0",device_manager);
        uvm_config_db#(pcie_tl_env_config)::set(this,"env","cfg",c);
        uvm_config_db#(bit)::set(this,"env","pcie_svt_bridge_required",1);
        env=pcie_tl_env::type_id::create("env",this);
    endfunction

    // RC->EP、EP->Host 都先 WRITE 再 READ，检查真实部分字节 BE 的端到端结果。
    // Completion 经过 opposite adapter 返回公共 driver，才能释放 Tag 并完成 rw_seq。
    task run_phase(uvm_phase phase);
        pcie_tl_rw_seq wr, rd;
        bit [63:0] address;
        int length_bytes=137;
        phase.raise_objection(this);
        for(int side=0;side<2;side++) begin
            if(side==0) address=env.dev_mem[0].alloc(256,64);
            else address=env.host_mem.alloc(256,64);
            wr=pcie_tl_rw_seq::type_id::create("write");
            wr.op=PCIE_RW_WRITE; wr.addr=address+1; wr.byte_len=length_bytes;
            wr.wdata=new[length_bytes];
            foreach(wr.wdata[i]) wr.wdata[i]=8'(i*19+side);
            if(side==0) wr.start(env.rc_agent.sequencer);
            else wr.start(env.ep_agent.sequencer);
            rd=pcie_tl_rw_seq::type_id::create("read");
            rd.op=PCIE_RW_READ; rd.addr=address+1; rd.byte_len=length_bytes;
            if(side==0) rd.start(env.rc_agent.sequencer);
            else rd.start(env.ep_agent.sequencer);
            if(rd.status!=PCIE_RW_OK || rd.rdata.size()!=length_bytes)
                `uvm_fatal("ENV_READBACK", "public rw_seq did not complete")
            foreach(wr.wdata[i])
                if(rd.rdata[i]!==wr.wdata[i])
                    `uvm_fatal("ENV_READBACK", $sformatf("side=%0d byte=%0d mismatch",side,i))
            if(side==0) env.dev_mem[0].free(address);
            else env.host_mem.free(address);
        end
        `uvm_info("RTILE_TEST_PASS", "pcie_work env/rw_seq: bidirectional 137-byte unaligned write/read matched",UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass
