// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// frndint_dut.sv — OOC wrapper reproducing the x87 FRNDINT datapath EXACTLY as
// fpu_writeback.sv:803-810 (same fpu_x87_pkg functions): pass Inf/NaN/zero and
// already-integral (uexp>=63) through; else round ST0 to integer via the shared
// fx_to_int_ex (the function whose tiny-value bug was just fixed) and rebuild the
// floatx80 via fx_from_int, preserving the sign of a round-to-zero. Validates
// that the fist fix propagates correctly into FRNDINT (e.g. FRNDINT(0.3) -> 0.0).
`default_nettype none
module frndint_dut
  import fpu_x87_pkg::*;
(
    input  wire logic [79:0] v,
    input  wire logic [1:0]  rc,
    output logic [79:0]      r,
    output logic             pe
);
    logic [65:0] ri;
    always_comb begin
        if (fx_is_inf_nan(v) || fx_is_zero(v) || (fx_uexp(v) >= 32'sd63)) begin
            r  = v;
            pe = 1'b0;
        end else begin
            ri = fx_to_int_ex(v, 64, rc);
            r  = (ri[63:0]==64'd0) ? fx_make(fx_sign(v), 15'd0, 64'd0)
                                   : fx_from_int($signed(ri[63:0]), 2'b11);
            pe = ri[64];
        end
    end
endmodule
`default_nettype wire
