// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// ven_fp_alu.sv -- one shared, registered floatx80 add/multiply pipeline.
//
// Only the fast arithmetic classes are accepted here:
//   0 add, 1 multiply, 4 subtract, 5 reverse-subtract.
// Divide/square-root/remainder use the shared iterative SRT engine.  Keeping
// those opcodes out of this module is important: it prevents synthesis from
// retaining the large behavioral divider reachable through f_eval().

`default_nettype none

(* use_dsp = "yes" *)
module ven_fp_alu
  import fpu_x87_pkg::*;
  import ventium_x87_pkg::*;
(
    input  wire logic         clk,
    input  wire logic         rst_n,
    input  wire logic         start,
    input  wire logic [2:0]   subop,
    input  wire logic [79:0]  operand_a,
    input  wire logic [79:0]  operand_b,
    input  wire logic [1:0]   rc,
    input  wire logic [1:0]   pc,
    output      logic         busy,
    output      logic         done,
    output      logic [84:0]  result
);

  logic       s0_valid;
  logic       s1_valid;
  logic       s2_valid;
  logic [2:0] s0_subop;
  logic [79:0] s0_a, s0_b;
  logic [1:0] s0_rc, s0_pc;
  fx_pipe_t   s1_pipe;
  logic [1:0] s1_rc;
  logic [1:0] s1_pc;
  logic [84:0] result_q;

  // Specialized copy of the proven f_eval_s1 fast arm.  It deliberately has
  // no division cases and therefore no path to f_arith()/fx_div_exact().
  function automatic fx_pipe_t fast_front(
      input logic [2:0]  op,
      input logic [79:0] a,
      input logic [79:0] b,
      input logic [1:0]  round_control
  );
    logic [81:0] special;
    fx_pipe_t p;
    begin
      p = '0;
      special = f_special(op, a, b);
      if (special[81]) begin
        p.early  = 1'b1;
        p.result = {special[80], 4'b0000, special[79:0]};
      end else begin
        unique case (op)
          3'd0: p = fx_add_s1(a, b, round_control);
          3'd1: p = fx_mul_s1(a, b);
          3'd4: p = fx_add_s1(a, {~b[79], b[78:0]}, round_control);
          3'd5: p = fx_add_s1(b, {~a[79], a[78:0]}, round_control);
          default: begin
            // Invalid dispatch is made visible as masked-invalid indefinite.
            p.early  = 1'b1;
            p.result = {1'b1, 4'b0000, 80'hffffc000000000000000};
          end
        endcase
      end
      return p;
    end
  endfunction

  function automatic logic [84:0] finish(
      input fx_pipe_t  pipe,
      input logic [1:0] round_control,
      input logic [1:0] precision_control
  );
    logic [82:0] rounded;
    begin
      if (pipe.early)
        return pipe.result;
      rounded = fx_round_pack_f(pipe.sign, pipe.unbiased, pipe.sig,
                                pipe.pre_inexact, round_control,
                                precision_control);
      return {2'b00, rounded[82], rounded[81], rounded[80], rounded[79:0]};
    end
  endfunction

  assign busy   = s0_valid | s1_valid | s2_valid;
  assign done   = s2_valid;
  assign result = result_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s0_valid <= 1'b0;
      s1_valid <= 1'b0;
      s2_valid <= 1'b0;
      s0_subop <= 3'd0;
      s0_a     <= 80'd0;
      s0_b     <= 80'd0;
      s0_rc    <= 2'b00;
      s0_pc    <= 2'b11;
      s1_pipe  <= '0;
      s1_rc    <= 2'b00;
      s1_pc    <= 2'b11;
      result_q <= '0;
    end else begin
      // FIRC/operand-capture stage: no arithmetic cone is allowed between the
      // architectural state read and these registers.
      s0_valid <= start;
      if (start) begin
        s0_subop <= subop;
        s0_a     <= operand_a;
        s0_b     <= operand_b;
        s0_rc    <= rc;
        s0_pc    <= pc;
      end

      // Execute front: unpack/align/add or significand multiply.
      s1_valid <= s0_valid;
      if (s0_valid) begin
        s1_pipe <= fast_front(s0_subop, s0_a, s0_b, s0_rc);
        s1_rc   <= s0_rc;
        s1_pc   <= s0_pc;
      end

      // Normalize/round/pack back stage.
      s2_valid <= s1_valid;
      if (s1_valid)
        result_q <= finish(s1_pipe, s1_rc, s1_pc);
    end
  end

endmodule

`default_nettype wire
