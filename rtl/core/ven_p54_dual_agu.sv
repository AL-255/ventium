`default_nettype none
// Two independent 32-bit ModR/M/SIB effective-address generators. The U
// address feeds the existing checked memory owner; the V address feeds LEA and
// the optional checked V-memory lane (including a separate prime query).
// Segment selection, limits, translation and stack-pointer special cases stay
// with their architectural owners in core.sv. Neither EA is a memory request.
module ven_p54_dual_agu
  import ventium_decode_pkg::*;
(
    input  fpd_t u,
    input  fpd_t v,
    input  wire logic [31:0] gpr [8],
    output      logic [31:0] u_ea,
    output      logic [31:0] v_ea
);
  logic [31:0] u_base, u_index, v_base, v_index;
  assign u_base = u.mem_base_en ? gpr[u.base] : 32'd0;
  assign u_index = u.mem_index_en ? (gpr[u.mem_index] << u.mem_scale) : 32'd0;
  assign v_base = v.mem_base_en ? gpr[v.base] : 32'd0;
  assign v_index = v.mem_index_en ? (gpr[v.mem_index] << v.mem_scale) : 32'd0;
  assign u_ea = (u_base + u_index) + u.mem_disp;
  assign v_ea = (v_base + v_index) + v.mem_disp;
endmodule
`default_nettype wire
