// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// ===========================================================================
// rtl/fpu/fpu_fprem.sv — ITERATIVE x87 FPREM (D9 F8) engine.
//
// EXACT partial remainder ST0 - Q*ST1 (Q = trunc(ST0/ST1)), matching qemu-8.2.2
// helper_fprem -> floatx80_modrem -> frac64_modrem. A true remainder must be EXACT
// (the comment in core.sv: div+mul+sub rounds), so this does a bit-serial restoring
// integer division of the aligned 64-bit mantissas — the SAME exact remainder +
// quotient as softfloat's estimateDiv-based frac64_modrem, just produced one
// quotient bit per clock (FPREM is rare; ~expdiff+1 clocks).
//
// Condition codes (helper_fprem_common): C0<-q2, C3<-q1, C1<-q0 when the reduction
// completes (expdiff<64); C2<-1 (others cleared) on a PARTIAL reduction (expdiff>=64,
// software re-loops). Specials: ST1=0 or ST0=Inf -> IE + QNaN indefinite; either NaN
// -> propagate; ST0=0 or ST1=Inf -> remainder = ST0.
//
// Quake uses ONE FPREM (in glibc fmodl); its operands give expdiff<64 (full
// reduction in a single call). The partial case is implemented for completeness.

module fpu_fprem (
    input  wire logic        clk,
    input  wire logic        rst_n,
    input  wire logic        start,      // 1-clk: begin (ignored if busy)
    input  wire logic        prem1,      // 1 = FPREM1 (round-nearest Q); 0 = FPREM (trunc Q)
    input  wire logic [79:0] a,          // ST0 (dividend)  floatx80
    input  wire logic [79:0] b,          // ST1 (divisor)   floatx80
    output logic             busy,
    output logic             done,       // 1-clk strobe: result valid this clock
    output logic [79:0]      result,     // remainder (floatx80)
    output logic [2:0]       q012,       // {q2,q1,q0} -> {C0,C3,C1}
    output logic             c2,         // 1 = partial (incomplete) reduction
    output logic             ie          // invalid-operation (raise IE)
);
  // ---- floatx80 field helpers ----------------------------------------------
  localparam logic [79:0] QNAN_INDEF = {1'b1, 15'h7fff, 1'b1, 63'h4000000000000000};
  function automatic logic        is_inf (input logic [79:0] v);
    return (v[78:64]==15'h7fff) && (v[63:0]==64'h8000000000000000);
  endfunction
  function automatic logic        is_nan (input logic [79:0] v);
    return (v[78:64]==15'h7fff) && (v[63:0]!=64'h8000000000000000);
  endfunction
  function automatic logic        is_zero(input logic [79:0] v);
    return (v[78:64]==15'd0) && (v[63:0]==64'd0);
  endfunction
  function automatic logic [79:0] quiet  (input logic [79:0 ] v); // make a NaN quiet
    // QNaN forces BOTH the explicit integer bit (62? no: bit63) AND the quiet
    // bit (62). The old form set only bit63, leaving an SNaN still signaling
    // (RTL 80.. vs QEMU c0..) — fpu87 SNaN-operand finding.
    return {v[79], 15'h7fff, 2'b11, v[61:0]};
  endfunction
  // count leading zeros of a 64-bit value (msb position = 63-clz); 64 if all-zero.
  function automatic logic [6:0] clz64(input logic [63:0] x);
    logic [6:0] n; n = 7'd64;
    for (int i=63; i>=0; i--) if (x[i] && n==7'd64) n = 7'd63 - i[6:0];
    return n;
  endfunction

  typedef enum logic [1:0] { S_IDLE, S_REDUCE, S_NORM } st_e;
  st_e         st;
  // working regs
  logic [63:0] rem;          // current partial remainder (< mb after each step)
  logic [63:0] mb_r;         // divisor mantissa
  logic        sa_r;         // sign of ST0 (remainder takes ST0's sign)
  logic signed [16:0] eb_eff;// remainder exponent base (eb, or scaled for partial)
  logic [6:0]  steps_left;   // restoring steps remaining
  logic [63:0] quot;         // accumulated quotient (low bits)
  logic        c2_r;
  logic        prem1_r;      // FPREM1 (round-nearest Q) latched for this op
  logic [79:0] a_r;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st<=S_IDLE; busy<=1'b0; done<=1'b0; result<=80'd0; q012<=3'd0; c2<=1'b0; ie<=1'b0;
    end else begin
      done<=1'b0;
      case (st)
        // ---- decode + special cases + set up the reduction -----------------
        S_IDLE: if (start) begin
          logic [14:0] ea, eb; logic [63:0] ma, mb;
          logic signed [16:0] ea_a, eb_a, expdiff;
          ea=a[78:64]; eb=b[78:64]; ma=a[63:0]; mb=b[63:0];
          a_r<=a; sa_r<=a[79]; q012<=3'd0; c2<=1'b0; ie<=1'b0; prem1_r<=prem1;
          if (is_nan(a) || is_nan(b)) begin
            result <= is_nan(a) ? quiet(a) : quiet(b);
            busy<=1'b0; done<=1'b1; st<=S_IDLE;
          end else if (is_zero(b) || is_inf(a)) begin
            result <= QNAN_INDEF; ie<=1'b1; busy<=1'b0; done<=1'b1; st<=S_IDLE;
          end else if (is_zero(a) || is_inf(b)) begin
            result <= a; busy<=1'b0; done<=1'b1; st<=S_IDLE;   // |a|<|b| or a==0
          end else begin
            // normal operands. denormal (exp==0): effective exp = 1 - clz(mant).
            ea_a = (ea==15'd0) ? (17'sd1 - {10'd0, clz64(ma)}) : $signed({2'b0, ea});
            eb_a = (eb==15'd0) ? (17'sd1 - {10'd0, clz64(mb)}) : $signed({2'b0, eb});
            expdiff = ea_a - eb_a;
            // |a| < |b| (expdiff<0, or ==0 with ma<mb) -> remainder = a, q=0.
            if (expdiff < 0 || (expdiff==0 && ma < mb)) begin
              result<=a; busy<=1'b0; done<=1'b1; st<=S_IDLE;
            end else begin
              logic [6:0] nb; logic signed [16:0] ebe;
              if (expdiff < 64) begin nb = expdiff[6:0];               ebe = $signed({2'b0,eb}); c2_r<=1'b0; end
              else              begin nb = 7'd32 + {2'b0,expdiff[4:0]}; ebe = $signed({2'b0,eb}) + (expdiff - {10'd0,nb}); c2_r<=1'b1; end
              mb_r<=mb; eb_eff<=ebe;
              // first quotient bit (the MSB, value bit `nb`): ma >= mb ?
              if (ma >= mb) begin rem<=ma - mb; quot<=64'd1; end
              else          begin rem<=ma;      quot<=64'd0; end
              steps_left<=nb;          // then nb more shift-subtract steps
              busy<=1'b1; st<=(nb==0)? S_NORM : S_REDUCE;
            end
          end
        end
        // ---- bit-serial restoring division: one quotient bit / clock --------
        S_REDUCE: begin
          logic [64:0] sh, sub; logic qb;
          sh  = {rem,1'b0};                      // rem << 1 (bring down a 0 bit)
          qb  = (sh >= {1'b0, mb_r});
          sub = sh - {1'b0, mb_r};
          rem  <= qb ? sub[63:0] : sh[63:0];
          quot <= {quot[62:0], qb};
          steps_left <= steps_left - 7'd1;
          if (steps_left==7'd1) st<=S_NORM;
        end
        // ---- round (FPREM1) + normalize the remainder into floatx80 --------
        S_NORM: begin
          logic [6:0] lz; logic signed [16:0] e; logic [63:0] mant;
          logic [63:0] r, q_eff; logic s_eff; logic [64:0] two_r; logic rndup;
          // restoring division leaves rem in [0, mb_r) (the FPREM/trunc remainder).
          // FPREM1 picks the round-NEAREST quotient: on a COMPLETE reduction round
          // Q up when 2*rem > mb_r, or == with Q odd (nearest-even). The remainder
          // then becomes -(mb_r-rem): magnitude mb_r-rem, sign flipped. The quotient
          // condition codes use the rounded Q.
          two_r = {rem, 1'b0};
          rndup = prem1_r && !c2_r &&
                  ((two_r > {1'b0, mb_r}) || ((two_r == {1'b0, mb_r}) && quot[0]));
          if (rndup) begin r = mb_r - rem; s_eff = ~sa_r; q_eff = quot + 64'd1; end
          else       begin r = rem;        s_eff =  sa_r; q_eff = quot;          end
          if (r==64'd0) begin
            result <= {s_eff, 15'd0, 64'd0};     // signed zero
          end else begin
            lz   = clz64(r);
            mant = r << lz;                      // normalize: MSB -> bit63
            e    = eb_eff - {10'd0, lz};         // E = eb_eff - 63 + msbpos = eb_eff - lz
            if (e <= 0) begin
              // subnormal/underflow: shift right by (1-e), exp field 0 (best-effort;
              // Quake never produces this — fmod of finite normals stays normal).
              logic signed [16:0] ome; logic [6:0] rsh;
              ome = 17'sd1 - e;
              rsh = (ome > 17'sd63) ? 7'd63 : ome[6:0];
              result <= {s_eff, 15'd0, (mant >> rsh)};
            end else begin
              result <= {s_eff, e[14:0], mant};
            end
          end
          q012 <= c2_r ? 3'd0 : q_eff[2:0];      // partial clears the quotient codes
          c2   <= c2_r;
          busy<=1'b0; done<=1'b1; st<=S_IDLE;
        end
        default: st<=S_IDLE;
      endcase
    end
  end
endmodule : fpu_fprem
