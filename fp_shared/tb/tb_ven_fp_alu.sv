`timescale 1ns/1ps
`default_nettype none

module tb_ven_fp_alu;
  import fpu_x87_pkg::*;
  import ventium_x87_pkg::*;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic start;
  logic [2:0] subop;
  logic [79:0] operand_a, operand_b;
  logic [1:0] rc, pc;
  logic busy, done, commit_next;
  logic [84:0] result;
  logic ref_vld, ref_pe;
  logic [79:0] ref_y;
  int checks;

  always #5 clk = ~clk;

  ven_fp_alu dut (.*);

  fpu_fx_ppl oracle (
      .clk(clk), .rst_n(rst_n), .req(start),
      .op(subop == 3'd0 ? 2'd0 : subop == 3'd1 ? 2'd1 :
          subop == 3'd4 ? 2'd2 : 2'd3),
      .a(operand_a), .b(operand_b), .rc(rc), .pc(pc),
      .vld(ref_vld), .y(ref_y), .pe(ref_pe)
  );

  function automatic logic [84:0] fast_reference(
      input logic [2:0] op,
      input logic [79:0] a,
      input logic [79:0] b,
      input logic [1:0] round_control,
      input logic [1:0] precision_control
  );
    logic [81:0] special;
    logic [82:0] rounded;
    fx_pipe_t p;
    begin
      special = f_special(op, a, b);
      if (special[81])
        return {special[80], 4'b0000, special[79:0]};
      unique case (op)
        3'd0: p = fx_add_s1(a, b, round_control);
        3'd1: p = fx_mul_s1(a, b);
        3'd4: p = fx_add_s1(a, {~b[79], b[78:0]}, round_control);
        default: p = fx_add_s1(b, {~a[79], a[78:0]}, round_control);
      endcase
      if (p.early)
        return p.result;
      rounded = fx_round_pack_f(p.sign, p.unbiased, p.sig, p.pre_inexact,
                                round_control, precision_control);
      return {2'b00, rounded[82], rounded[81], rounded[80], rounded[79:0]};
    end
  endfunction

  task automatic check_one(
      input logic [2:0] op,
      input logic [79:0] a,
      input logic [79:0] b,
      input logic [1:0] round_control,
      input logic [1:0] precision_control
  );
    logic [84:0] expected;
    logic [81:0] special;
    logic [79:0] saved_ref_y;
    logic saved_ref_pe;
    logic ref_seen;
    begin
      special = f_special(op, a, b);
      expected = fast_reference(op, a, b, round_control, precision_control);
      @(negedge clk);
      start     = 1'b1;
      subop     = op;
      operand_a = a;
      operand_b = b;
      rc        = round_control;
      pc        = precision_control;
      @(negedge clk);
      start = 1'b0;
      ref_seen = 1'b0;
      while (!done) begin
        if (ref_vld) begin
          saved_ref_y  = ref_y;
          saved_ref_pe = ref_pe;
          ref_seen     = 1'b1;
        end
        @(negedge clk);
      end
      if (ref_vld) begin
        saved_ref_y  = ref_y;
        saved_ref_pe = ref_pe;
        ref_seen     = 1'b1;
      end
      if (!ref_seen)
        $fatal(1, "proven fpu_fx_ppl did not complete");
      if (result !== expected) begin
        $display("FAIL op=%0d rc=%0d pc=%0d a=%020h b=%020h", op,
                 round_control, precision_control, a, b);
        $display("  expected=%022h actual=%022h", expected, result);
        $fatal(1);
      end
      // fpu_fx_ppl predates instruction-level NaN/Inf wrapping, so compare it
      // directly on the finite/non-special cases it implements.
      if (!special[81] &&
          ({saved_ref_pe,saved_ref_y} !== {result[80],result[79:0]}))
        $fatal(1, "old-pipeline mismatch op=%0d", op);
      checks++;
    end
  endtask

  function automatic logic [79:0] random_fx80();
    return {$urandom(), $urandom(), $urandom()[15:0]};
  endfunction

  initial begin
    start = 1'b0;
    subop = 3'd0;
    operand_a = '0;
    operand_b = '0;
    rc = 2'b00;
    pc = 2'b11;
    checks = 0;

    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    // Directed normal, zero, infinity, NaN, and cancellation cases.
    for (int r = 0; r < 4; r++) begin
      check_one(3'd0, 80'h3fff8000000000000000,
                80'h40008000000000000000, r[1:0], 2'b11);
      check_one(3'd4, 80'h3fff8000000000000000,
                80'h3fff8000000000000000, r[1:0], 2'b11);
      check_one(3'd1, 80'h00000000000000000000,
                80'h7fff8000000000000000, r[1:0], 2'b11);
      check_one(3'd0, 80'h7fffc123456789abcdef,
                80'h3fff8000000000000000, r[1:0], 2'b11);
    end

    // Random A/B comparison against the proven instruction-level evaluator.
    for (int n = 0; n < 1200; n++) begin
      logic [2:0] op;
      logic [1:0] precision;
      int op_pick;
      int pc_pick;
      op_pick = $urandom_range(0, 3);
      pc_pick = $urandom_range(0, 2);
      case (op_pick)
        0: op = 3'd0;
        1: op = 3'd1;
        2: op = 3'd4;
        default: op = 3'd5;
      endcase
      case (pc_pick)
        0: precision = 2'b00;
        1: precision = 2'b10;
        default: precision = 2'b11;
      endcase
      check_one(op, random_fx80(), random_fx80(),
                $urandom_range(0, 3), precision);
    end

    $display("VEN-FP-ALU-A-B-OK checks=%0d", checks);
    $finish;
  end
endmodule

`default_nettype wire
