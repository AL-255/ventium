// ven_fpu_dpi.sv — DPI bridge exposing the ventium project's QEMU-verified,
// bit-exact x87 FPU datapath (rtl/fpu/fpu_x87_pkg.sv + rtl/core/ventium_x87_pkg.sv)
// to the ao486-sim C++ x87 co-sim (ao486-sim/ps/x87_cosim.cpp).
//
// The co-sim previously computed each x87 op with host `long double`/libm, which
// is NOT bit-exact to a real x87/QEMU (denormals, NaN propagation, inexact
// rounding). Those divergences wedge DOS-Quake's FCOMP/FUCOMP-driven inner loops.
// Here we route the basic ops (add/sub/mul/div/sqrt, float<->x80 conversion,
// FIST, FRNDINT, FCOM) through the SAME combinational functions the ventium core
// uses and that verif/fpu87 gates bit-exact vs Berkeley SoftFloat (47/47).
//
// floatx80 (80 bits) is passed split as {se[15:0]=v[79:64], sig[63:0]=v[63:0]}
// so every DPI arg/result is a plain <=64-bit C scalar (no wide-vector DPI).
//
// Transcendentals (FSIN/FCOS/F2XM1/FYL2X/FPATAN/FPTAN/FSINCOS) are MULTI-CYCLE
// modules in rtl/fpu, not functions — they remain libm-approximate in the co-sim.
//
// Uses the default (no +define) FPU config: combinational fx_div / fx_sqrt, exact
// (no VEN_SRT_ITER / VEN_DIV_EXACT / VEN_SRT_FDIV_BUG), matching the verif gates.
`default_nettype none
module ven_fpu_dpi
  import fpu_x87_pkg::*;
  import ventium_x87_pkg::*;
();

  // ---- arithmetic: add(0)/mul(1)/sub(4)/subr(5)/div(6)/divr(7) --------------
  // f_eval handles the QEMU special-operand cases (NaN pickNaN, Inf combos, 0/0,
  // x/0->ZE) and returns {ie,ze,oe,ue,pe, result[79:0]}. flags = r[84:80].
  export "DPI-C" function ven_feval;
  function void ven_feval(input byte unsigned sub,
                          input longint unsigned a_sig, input shortint unsigned a_se,
                          input longint unsigned b_sig, input shortint unsigned b_se,
                          input byte unsigned rc, input byte unsigned pc,
                          output longint unsigned r_sig, output shortint unsigned r_se,
                          output byte unsigned flags);
    logic [79:0] a, b;
    logic [84:0] r;
    begin
      a = {a_se, a_sig};
      b = {b_se, b_sig};
      r = f_eval(sub[2:0], a, b, rc[1:0], pc[1:0], 1'b0);
      r_sig = r[63:0];
      r_se  = r[79:64];
      flags = {3'b0, r[84], r[83], r[82], r[81], r[80]};   // {ie,ze,oe,ue,pe}
    end
  endfunction

  // ---- FCOM / FUCOM condition codes {C3,C2,C0} (unordered on NaN) -----------
  export "DPI-C" function ven_fcom;
  function void ven_fcom(input longint unsigned a_sig, input shortint unsigned a_se,
                         input longint unsigned b_sig, input shortint unsigned b_se,
                         output byte unsigned codes);
    begin codes = {5'b0, fcom_codes({a_se, a_sig}, {b_se, b_sig})}; end
  endfunction

  // ---- FSQRT (mirrors fpu_writeback FX_FSQRT, non-engine combinational path) -
  // flags: bit0=IE, bit1=PE, bit2=C2. C2 marks the negative/-0 radicand cases.
  export "DPI-C" function ven_fsqrt;
  function void ven_fsqrt(input longint unsigned a_sig, input shortint unsigned a_se,
                          input byte unsigned rc, input byte unsigned pc,
                          output longint unsigned r_sig, output shortint unsigned r_se,
                          output byte unsigned flags);
    logic [79:0] a, res;
    logic [80:0] sq;
    logic        ie, pe, c2;
    begin
      a = {a_se, a_sig}; ie=1'b0; pe=1'b0; c2=1'b0;
      if (fx_is_snan(a))      begin res = fx_quietize(a); ie=1'b1; end
      else if (fx_is_nan(a))  begin res = a; end
      else if (a[79]) begin
        if (fx_is_neg(a))     begin res = 80'hFFFFC000000000000000; ie=1'b1; c2=1'b1; end
        else begin sq = fx_sqrt(a, rc[1:0], pc[1:0]); res = sq[79:0]; c2=1'b1; end  // -0
      end else begin
        sq = fx_sqrt(a, rc[1:0], pc[1:0]); res = sq[79:0]; pe = sq[80];
      end
      r_sig = res[63:0]; r_se = res[79:64];
      flags = {5'b0, c2, pe, ie};
    end
  endfunction

  // ---- FLD m32 / m64 (exact widening to floatx80) ---------------------------
  export "DPI-C" function ven_from_f32;
  function void ven_from_f32(input int unsigned u32,
                             output longint unsigned r_sig, output shortint unsigned r_se);
    logic [79:0] r; begin r = fx_from_f32(u32); r_sig=r[63:0]; r_se=r[79:64]; end
  endfunction
  export "DPI-C" function ven_from_f64;
  function void ven_from_f64(input longint unsigned u64,
                             output longint unsigned r_sig, output shortint unsigned r_se);
    logic [79:0] r; begin r = fx_from_f64(u64); r_sig=r[63:0]; r_se=r[79:64]; end
  endfunction

  // ---- FST m32 / m64 (narrowing, RC-honored). flags = {oe,ue,pe} ------------
  export "DPI-C" function ven_to_f32;
  function void ven_to_f32(input longint unsigned v_sig, input shortint unsigned v_se,
                           input byte unsigned rc,
                           output int unsigned f32, output byte unsigned flags);
    logic [34:0] r;
    begin r = fx_to_f32_ex({v_se, v_sig}, rc[1:0]); f32 = r[31:0];
          flags = {5'b0, r[34], r[33], r[32]}; end
  endfunction
  export "DPI-C" function ven_to_f64;
  function void ven_to_f64(input longint unsigned v_sig, input shortint unsigned v_se,
                           input byte unsigned rc,
                           output longint unsigned f64, output byte unsigned flags);
    logic [66:0] r;
    begin r = fx_to_f64_ex({v_se, v_sig}, rc[1:0]); f64 = r[63:0];
          flags = {5'b0, r[66], r[65], r[64]}; end
  endfunction

  // ---- FIST / FISTP (floatx80 -> signed int, width 16/32/64). flags = {inex,inv}
  export "DPI-C" function ven_to_int;
  function void ven_to_int(input longint unsigned v_sig, input shortint unsigned v_se,
                           input byte unsigned width, input byte unsigned rc,
                           output longint unsigned val, output byte unsigned flags);
    logic [65:0] r;
    begin r = fx_to_int_ex({v_se, v_sig}, int'(width), rc[1:0]); val = r[63:0];
          flags = {6'b0, r[64], r[65]}; end   // bit1=inexact(r[64]), bit0=invalid(r[65])
  endfunction

  // ---- FRNDINT (mirrors fpu_writeback FX_FRNDINT). pe = inexact --------------
  export "DPI-C" function ven_frndint;
  function void ven_frndint(input longint unsigned v_sig, input shortint unsigned v_se,
                            input byte unsigned rc, input byte unsigned pc,
                            output longint unsigned r_sig, output shortint unsigned r_se,
                            output byte unsigned pe);
    logic [79:0] v, res;
    logic [65:0] ri;
    begin
      v = {v_se, v_sig}; pe = 8'd0;
      if (fx_is_inf_nan(v) || fx_is_zero(v) || (fx_uexp(v) >= 32'sd63)) begin
        res = v;
      end else begin
        ri  = fx_to_int_ex(v, 64, rc[1:0]);
        res = (ri[63:0]==64'd0) ? fx_make(fx_sign(v), 15'd0, 64'd0)
                                : fx_from_int($signed(ri[63:0]), pc[1:0]);
        pe  = {7'b0, ri[64]};
      end
      r_sig = res[63:0]; r_se = res[79:64];
    end
  endfunction

endmodule
`default_nettype wire

// Instantiate once inside the top so Verilator elaborates the module and emits
// its export "DPI-C" prototypes into Vsystem__Dpi.h (no ports needed).
bind system ven_fpu_dpi u_ven_fpu_dpi();
