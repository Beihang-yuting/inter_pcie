// src/codec：复用 pcie_work TLP codec，只转换 R-Tile 的分离总线布局。
// 依赖 intel_pcie_types 和 pcie_tl_codec；每 adapter 独占一个 codec。
// Header little 模式改变 DWORD 的位置而不翻转 DWORD 内的 PCIe 位域；
// Payload 低字节先传，Prefix 始终 big endian。这里不建模 LCRC 或 TL Bypass。
class intel_pcie_avst_codec extends uvm_object;
    `uvm_object_utils(intel_pcie_avst_codec)
    pcie_tl_codec tl_codec;
    bit header_big_endian = 1;

    // 创建公共 codec；自身只拥有字段布局配置，不保存收发包状态。
    function new(string name = "intel_pcie_avst_codec");
        super.new(name);
        tl_codec = pcie_tl_codec::type_id::create("tl_codec");
    endfunction

    // 提取 PCIe 格式 DWORD N；little 模式 H0 位于 [31:0]，big 位于 [127:96]。
    function bit [31:0] header_dw(bit [127:0] hdr, int n);
        return header_big_endian ? hdr[127-n*32 -: 32] : hdr[n*32 +: 32];
    endfunction

    // 从 DW0 推导 Payload 长度；Length=0 的有数据包为 4096 B。
    function int payload_length(bit [127:0] hdr);
        bit [31:0] dw = header_dw(hdr, 0);
        return dw[30] ? ((dw[9:0] == 0) ? 4096 : int'(dw[9:0])*4) : 0;
    endfunction

    // 将 Header 分类为 P/NP/CPL，用于六类独立信用计数，包含 Vendor Message。
    function int category_of(bit [127:0] hdr);
        bit [31:0] dw = header_dw(hdr, 0);
        if (dw[28:24] inside {5'h0a, 5'h0b}) return 2;
        if (dw[28] || (dw[28:24] == 0 && dw[30])) return 0;
        return 1;
    endfunction

    // 编码为包快照；拒绝无法在用户接口表达的多 Prefix/CRC 注入，并验证
    // Payload 数量，避免 Length 与拍数不符导致硬核挂起。TD 交给硬核处理。
    function intel_pcie_packet encode(pcie_tl_tlp tlp);
        intel_pcie_packet pkt;
        bit [7:0] bytes[];
        bit [31:0] dw;
        int offset, nh;

        if (tlp == null) begin
            `uvm_error("RTILE_CODEC", "null TLP")
            return null;
        end
        if (tlp.prefixes.size() > 1 || tlp.inject_ecrc_err || tlp.inject_lcrc_err) begin
            `uvm_error("RTILE_CODEC", "one Prefix supported; ECRC/LCRC injection is not an AVST operation")
            return null;
        end
        if (!(int'(tlp.fmt) inside {[0:3]})) begin
            `uvm_error("RTILE_CODEC", "unsupported Fmt")
            return null;
        end
        pkt = new("encoded_packet");
        tl_codec.encode(tlp, bytes);
        offset = tlp.prefixes.size()*4;
        nh = tlp.is_4dw() ? 4 : 3;
        for (int n = 0; n < nh; n++) begin
            dw = {bytes[offset+4*n], bytes[offset+4*n+1],
                  bytes[offset+4*n+2], bytes[offset+4*n+3]};
            if (header_big_endian) pkt.header[127-32*n -: 32] = dw;
            else pkt.header[32*n +: 32] = dw;
        end
        pkt.expected_bytes = payload_length(pkt.header);
        if (pkt.expected_bytes != tlp.payload.size()) begin
            `uvm_error("RTILE_LENGTH", "header Length and Payload byte count disagree")
            return null;
        end
        pkt.prefix_valid = (offset != 0);
        if (pkt.prefix_valid) pkt.prefix = {bytes[0],bytes[1],bytes[2],bytes[3]};
        foreach (tlp.payload[i]) pkt.payload.push_back(tlp.payload[i]);
        pkt.category = category_of(pkt.header);
        pkt.bar = tlp.cq_route.bar_id;
        pkt.pfnum = 3'(tlp.cq_route.pf_index);
        pkt.vfactive = tlp.cq_route.is_vf;
        pkt.vfnum = 11'(tlp.cq_route.vf_index);
        return pkt;
    endfunction

    // 在重组器验证 EOP/Length 后调用；Payload 不包含硬核生成/剥离的 ECRC。
    // 不置 cq_route.valid：AVST 没有完整 BAR aperture/offset，不能伪造路由结果。
    function pcie_tl_tlp decode(intel_pcie_packet pkt);
        bit [7:0] bytes[];
        bit [31:0] dw, dw0;
        int nh, pos;
        pcie_tl_tlp tlp;

        if (pkt == null) return null;
        dw0 = header_dw(pkt.header, 0);
        nh = dw0[29] ? 4 : 3;
        bytes = new[(pkt.prefix_valid ? 4 : 0) + 4*nh + pkt.payload.size()];
        pos = 0;
        if (pkt.prefix_valid)
            for (int b = 3; b >= 0; b--) bytes[pos++] = pkt.prefix[b*8 +: 8];
        for (int n = 0; n < nh; n++) begin
            dw = header_dw(pkt.header, n);
            for (int b = 3; b >= 0; b--) bytes[pos++] = dw[b*8 +: 8];
        end
        foreach (pkt.payload[i]) bytes[pos++] = pkt.payload[i];
        tlp = tl_codec.decode(bytes);
        if (tlp != null) begin
            tlp.cq_route.bar_id = pkt.bar;
            tlp.cq_route.pf_index = pkt.pfnum;
            tlp.cq_route.is_vf = pkt.vfactive;
            tlp.cq_route.vf_index = pkt.vfactive ? int'(pkt.vfnum) : -1;
        end
        return tlp;
    endfunction
endclass
