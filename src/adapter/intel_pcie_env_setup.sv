// src/adapter：pcie_tl_env 的 Intel 用户接口接入入口，由 intel_pcie_adapter_pkg include。
// 依赖 UVM、pcie_tl_env_config 和 intel_pcie_if_adapter；不创建 env/agent 或内存。
// 调用者拥有 cfg，config_db 和后续 env 借用同一对象；必须在创建 env 前调用。
// 把引脚传输所需的固定配置放在一处，避免漏开 bridge 后误走公共 TLM 回环。

// 配置 parent 下的 env_name；parent=null 时 env_name 为完整 UVM 路径。
// cfg 不能为空，env_name 不能为空且应指向一个确定的 env，不能使用通配路径。
// 仅替换该 env 子树内的 adapter，并发布 cfg/bridge；不选择 RC/EP、内存或 scoreboard。
// 公共 FC 使用无限信用，本地 AVST credit_enable 仍由各端口 intel_cfg 独立控制。
function automatic void intel_pcie_configure_env(
    input uvm_component parent,
    input pcie_tl_env_config cfg,
    input string env_name = "env"
);
    string env_path;

    if (cfg == null) begin
        `uvm_fatal("RTILE_ENV_CONFIG", "intel_pcie_configure_env requires a non-null cfg")
        return;
    end
    if (env_name == "") begin
        `uvm_fatal("RTILE_ENV_CONFIG", "env_name must identify one env without wildcards")
        return;
    end
    for (int i = 0; i < env_name.len(); i++) begin
        if (env_name.getc(i) inside {"*", "?"}) begin
            `uvm_fatal("RTILE_ENV_CONFIG", "env_name must identify one env without wildcards")
            return;
        end
    end

    env_path = env_name;
    if (parent != null)
        if (parent.get_full_name() != "")
            env_path = {parent.get_full_name(), ".", env_name};

    pcie_tl_if_adapter::type_id::set_inst_override(
        intel_pcie_if_adapter::get_type(), {env_path, ".*"});
    cfg.if_mode = SV_IF_MODE;
    cfg.infinite_credit = 1;
    uvm_config_db#(pcie_tl_env_config)::set(parent, env_name, "cfg", cfg);
    uvm_config_db#(bit)::set(parent, env_name, "pcie_svt_bridge_required", 1'b1);
endfunction
