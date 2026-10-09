// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Exact sequential A/B against the pre-sharing leaf. The control must be a
// frozen original ven_fp_alu renamed to ven_fp_alu_control, not another copy
// of the candidate. Compare all result flags and fixed latency, not value only.
`timescale 1ns/1ps
`default_nettype none
module tb_shared_add_front;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n, start;
  logic [2:0] subop;
  logic [79:0] operand_a, operand_b;
  logic [1:0] rc, pc;
  logic busy, done, commit_next;
  logic [84:0] result;
  logic old_busy, old_done, old_commit_next;
  logic [84:0] old_result;
  logic [2:0] expected_valid = '0;
  int unsigned checks = 0;
  int unsigned accepted [0:7];
  logic [79:0] edges [0:15];

  ven_fp_alu dut (.*);
  ven_fp_alu_control control (
    .clk(clk), .rst_n(rst_n), .start(start), .subop(subop),
    .operand_a(operand_a), .operand_b(operand_b), .rc(rc), .pc(pc),
    .busy(old_busy), .done(old_done), .commit_next(old_commit_next),
    .result(old_result)
  );

  function automatic logic [79:0] random80();
    logic [31:0] a, b, c;
    a = $urandom(); b = $urandom(); c = $urandom();
    return {a, b, c[15:0]};
  endfunction

  task automatic tick(input logic reset_n, enable,
                      input logic [2:0] op,
                      input logic [79:0] a, b,
                      input logic [1:0] round_mode, precision_mode);
    @(negedge clk);
    rst_n = reset_n; start = enable; subop = op;
    operand_a = a; operand_b = b; rc = round_mode; pc = precision_mode;
    @(posedge clk);
    #1;
    expected_valid = reset_n ? {expected_valid[1:0], enable} : 3'b0;
    if ({busy, commit_next, done} !==
        {(|expected_valid), expected_valid[1], expected_valid[2]})
      $fatal(1, "latency/control mismatch check=%0d", checks);
    if ({busy, done, commit_next, result} !==
        {old_busy, old_done, old_commit_next, old_result})
      $fatal(1, "A/B mismatch check=%0d op=%0d a=%h b=%h got=%h old=%h",
             checks, op, a, b, result, old_result);
    // The entire registered unrounded front must also be identical, including
    // early exceptions and sticky bits; final rounding cannot hide a mismatch.
    if (dut.s1_pipe !== control.s1_pipe)
      $fatal(1, "unrounded front mismatch check=%0d", checks);
    if (reset_n && enable) accepted[op]++;
    checks++;
  endtask

  initial begin
    rst_n = 0; start = 0; subop = 0; operand_a = 0; operand_b = 0; rc = 0; pc = 0;
    for (int i = 0; i < 8; i++) accepted[i] = 0;
    edges[0]  = 80'h00000000000000000000; // +zero
    edges[1]  = 80'h80000000000000000000; // -zero
    edges[2]  = 80'h00000000000000000001; // smallest denormal
    edges[3]  = 80'h80007fffffffffffffff;
    edges[4]  = 80'h00018000000000000000; // smallest normal
    edges[5]  = 80'h3fff8000000000000000; // +1
    edges[6]  = 80'hbfff8000000000000000; // -1
    edges[7]  = 80'h3fff8000000000000001; // near cancellation
    edges[8]  = 80'h7ffeffffffffffffffff; // maximum finite
    edges[9]  = 80'hfffeffffffffffffffff;
    edges[10] = 80'h7fff8000000000000000; // +inf
    edges[11] = 80'hffff8000000000000000; // -inf
    edges[12] = 80'h7fffc123456789abcdef; // distinct qNaNs: priority
    edges[13] = 80'hffffc7654321fedcba98;
    edges[14] = 80'h7fff8123456789abcdef; // sNaN
    edges[15] = 80'h40000000000000000001; // unsupported explicit integer bit
    tick(0, 0, 0, 0, 0, 0, 0);
    // Back-to-back all opcodes, including invalid dispatch, all rounding and
    // precision controls (reserved PC=01 included), signs and special operands.
    for (int a = 0; a < 16; a++)
      for (int b = 0; b < 16; b++)
        for (int op = 0; op < 8; op++)
          for (int r = 0; r < 4; r++)
            for (int p = 0; p < 4; p++)
              tick(1, 1, 3'(op), edges[a], edges[b], 2'(r), 2'(p));
    // Alignment/jam limits and both operand orders, with exact cancellation,
    // carry-out and precision-boundary low bits.
    for (int delta = 0; delta < 260; delta++)
      for (int op = 0; op < 8; op++)
        for (int r = 0; r < 4; r++) begin
          tick(1, 1, 3'(op), {1'b0, 15'(16383+delta), 64'h8000000000000001},
               80'h3fff8000000000000000, 2'(r), 2'(delta));
          tick(1, 1, 3'(op), 80'hbfff8000000000000001,
               {1'b1, 15'(16383+delta), 64'hffffffffffffffff}, 2'(r), 2'(delta));
        end
    for (int n = 0; n < 262144; n++)
      tick((n % 257) != 0, ($urandom_range(0, 4) != 0),
           3'($urandom()), random80(), random80(), 2'($urandom()), 2'($urandom()));
    repeat (4) tick(1, 0, 0, random80(), random80(), 0, 0);
    for (int op = 0; op < 8; op++)
      if (accepted[op] < 4096) $fatal(1, "unexercised opcode %0d", op);
    $display("SHARED-ADD-FRONT-AB-OK clocks=%0d", checks);
    $finish;
  end
endmodule
`default_nettype wire
