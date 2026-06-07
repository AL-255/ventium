// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ===========================================================================
// rtl/fpu/fpu_sqrt_iter.sv — ITERATIVE floatx80 square-root engine.
//
// Multi-cycle, 2-restoring-steps-per-clock hardware form of the combinational
// fpu_x87_pkg::fx_sqrt (which calls the 128-iteration restoring fx_isqrt). The
// per-iteration restoring-sqrt body and the fx_sqrt exponent/round-pack wrapper
// are lifted VERBATIM, so the committed floatx80 is bit-identical to fx_sqrt
// (which is QEMU-validated by verif/tests/tx_sqrt / `make m3`). The combinational
// fx_isqrt unrolls 128 256-bit restoring steps into one giant cone (a chunk of
// the 126 256-bit adders in synth — see fpga/TIMING_PROBLEMS.md P0-1); this runs
// 2 steps/clock (~64 RUN clocks, within the P5 FSQRT occ=70 budget), collapsing
// that area and the critical path.
//
// NOTE ON FIDELITY: this is the *iterative restoring* sqrt (bit-exact to the
// existing model). The authentic Pentium method is radix-4 SRT square root on
// the shared divide datapath (D -> 2*Sj); that is a documented fidelity upgrade
// (TARGETS.md D6 / it needs its own golden). This engine fixes the synthesis
// area/timing while staying bit-exact today.
// ===========================================================================
`default_nettype none

module fpu_sqrt_iter
  import fpu_x87_pkg::*;
(
    input  wire logic        clk,
    input  wire logic        rst_n,
    input  wire logic        start,      // 1-clk: begin (ignored if busy). a >= 0.
    input  wire logic [79:0] a,          // operand (floatx80, >= 0; caller handles <0/NaN)
    input  wire logic [1:0]  rc,         // x87 rounding control
    output logic             busy,
    output logic             done,       // 1-clk strobe: result valid
    output logic [80:0]      result      // {inexact, floatx80}
);
  localparam int Fb = 80;                // == fx_sqrt Fb (64 + 2*Fb = 224 <= 256)

  typedef enum logic [1:0] { ST_IDLE, ST_RUN, ST_FIN, ST_SPECIAL } state_t;
  state_t st;

  logic [255:0]        X;                // radicand << 2*Fb (the isqrt input n)
  logic [255:0]        root, rem;        // restoring-sqrt running state
  logic signed [31:0]  e;                // halved-exponent accumulator (even)
  logic [7:0]          ihi;              // current high index (127,125,...,1)
  logic [80:0]         result_q;
  logic                done_q;

  assign busy   = (st != ST_IDLE);
  assign done   = done_q;
  assign result = result_q;

  // ---- two chained restoring steps (indices ihi, ihi-1) --------------------
  // each step mirrors fx_isqrt's loop body (fpu_x87_pkg.sv:709-717).
  logic [255:0] tw0, rs0, tr0, rem_a, root_a;
  logic [255:0] tw1, rs1, tr1, rem_b, root_b;
  logic         ge0, ge1;
  always_comb begin
    tw0    = (X >> (2*int'(ihi)))       & 256'd3;
    rs0    = (rem  << 2) | tw0;
    tr0    = (root << 2) | 256'd1;
    ge0    = (rs0 >= tr0);
    rem_a  = ge0 ? (rs0 - tr0)        : rs0;
    root_a = ge0 ? ((root << 1) | 256'd1) : (root << 1);

    tw1    = (X >> (2*(int'(ihi)-1)))   & 256'd3;
    rs1    = (rem_a  << 2) | tw1;
    tr1    = (root_a << 2) | 256'd1;
    ge1    = (rs1 >= tr1);
    rem_b  = ge1 ? (rs1 - tr1)         : rs1;
    root_b = ge1 ? ((root_a << 1) | 256'd1) : (root_a << 1);
  end

  // ---- final round/pack — mirrors fx_sqrt lines 687-693 --------------------
  logic [255:0]        r_final;
  int                  msb;
  logic signed [31:0]  msbpos;
  logic [80:0]         fin_result;
  always_comb begin
    // The final restoring remainder `rem` == X - root², so rem!=0 ⟺ X is not a
    // perfect square ⟺ root*root != X. Use it for the inexact sticky instead of a
    // 256x256 multiply (bit-exact, but removes the DSP mult + the FIN crit path).
    r_final = (rem != 256'd0) ? (root | 256'd1) : root;  // sticky -> force inexact
    msb     = 0;
    for (int i=255; i>=0; i--) if (r_final[i]) begin msb=i; break; end
    msbpos  = msb;
    fin_result = fx_round_pack(1'b0, (msbpos - Fb) + (e >>> 1), r_final[127:0], 1'b0, rc);
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= ST_IDLE; done_q <= 1'b0; ihi <= 8'd127;
    end else begin
      done_q <= 1'b0;
      unique case (st)
        ST_IDLE: begin
          if (start) begin
            if (fx_is_zero(a) || fx_exp(a)==15'h7fff) begin
              result_q <= {1'b0, a};                // sqrt(+0)=+0, sqrt(-0)=-0, sqrt(+Inf)=+Inf
              st <= ST_SPECIAL;
            end else begin
              // value = ma * 2^(ua-63); make exponent even, X = ma2 << 2*Fb
              automatic logic [63:0]        ma = fx_man(a);
              automatic logic signed [31:0] ee = fx_uexp(a) - 32'sd63;
              automatic logic [255:0]       ma2;
              if (ee[0]) begin ma2 = {191'd0, ma, 1'b0}; ee = ee - 32'sd1; end
              else       begin ma2 = {192'd0, ma};       end
              X    <= ma2 << (2*Fb);
              e    <= ee;
              root <= 256'd0;
              rem  <= 256'd0;
              ihi  <= 8'd127;
              st   <= ST_RUN;
            end
          end
        end
        ST_RUN: begin
          root <= root_b;
          rem  <= rem_b;
          if (ihi == 8'd1) st <= ST_FIN;            // just processed pair (1,0)
          ihi  <= ihi - 8'd2;
        end
        ST_FIN: begin
          result_q <= fin_result;
          done_q   <= 1'b1;
          st       <= ST_IDLE;
        end
        ST_SPECIAL: begin
          done_q <= 1'b1;
          st     <= ST_IDLE;
        end
        default: st <= ST_IDLE;
      endcase
    end
  end
endmodule

`default_nettype wire
