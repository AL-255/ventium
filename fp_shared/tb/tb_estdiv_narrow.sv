`timescale 1ns/1ps
`default_nettype none

// Cycle-by-cycle old/new miter: narrowing an invariant-zero quotient word
// must not change request ownership, latency, saturation, correction or reset.
module tb_estdiv_narrow;
  logic clk = 0, rst_n = 0, req = 0;
  logic [63:0] a0 = 0, a1 = 0, b = 0;
  logic old_vld, new_vld;
  logic [63:0] old_z, new_z;
  int clocks = 0, completed = 0, resets = 0, correction_cycles = 0;
  bit seen_state [0:5];
  always #5 clk = ~clk;
  ven_fp_estdiv_reference old_dut (
    .clk, .rst_n, .req, .a0, .a1, .b, .vld(old_vld), .z(old_z));
  ven_fp_estdiv new_dut (
    .clk, .rst_n, .req, .a0, .a1, .b, .vld(new_vld), .z(new_z));

  task automatic tick;
    @(negedge clk);
    clocks++;
    if (old_vld !== new_vld || old_z !== new_z)
      $fatal(1, "cycle mismatch clk=%0d old=%b:%h new=%b:%h",
             clocks, old_vld, old_z, new_vld, new_z);
    if (old_dut.est_q !== new_dut.est_q || old_dut.z_q[31:0] !== 0 ||
        old_dut.z_q[63:32] !== new_dut.z_hi_q ||
        old_dut.rem0_q !== new_dut.rem0_q || old_dut.rem1_q !== new_dut.rem1_q)
      $fatal(1, "internal invariant/recurrence mismatch clk=%0d", clocks);
    if (rst_n) begin
      seen_state[int'(old_dut.est_q)] = 1;
      if (old_dut.est_q == 4 && old_dut.rem0_q[63] && old_dut.correction_q != 6)
        correction_cycles++;
    end
    if (new_vld) completed++;
  endtask

  function automatic logic [63:0] rnd64;
    return {$urandom, $urandom};
  endfunction

  task automatic one(input logic [63:0] ia0, ia1, ib, input bit poison_busy);
    int waited;
    if (old_dut.est_q != 0 || new_dut.est_q != 0) $fatal(1, "not idle");
    req = 1; a0 = ia0; a1 = ia1; b = ib;
    tick();
    req = 0;
    waited = 0;
    while (!new_vld) begin
      // Busy requests/operand mutations must not replace the accepted owner.
      req = poison_busy && (old_dut.est_q != 0);
      a0 = rnd64(); a1 = rnd64(); b = rnd64();
      tick();
      if (++waited > 100) $fatal(1, "transaction timeout");
    end
    req = 0;
    tick();
  endtask

  initial begin
    logic [63:0] den, num;
    tick(); tick(); rst_n = 1;
    for (int i = 0; i < 6; i++) seen_state[i] = 0;
    one(0, 0, 64'h8000000000000000, 0);
    one(64'h8000000000000000, '1, 64'h80000000ffffffff, 1);
    one('1, 64'h0123456789abcdef, 64'h8000000000000000, 0);
    one(64'h7fffffffffffffff, '1, '1, 1);
    one(0, '1, 0, 0);
    one(0, '1, 1, 1);
    for (int i=0; i<10000; i++) begin
      den = rnd64(); num = rnd64();
      case (i % 5)
        0: begin den[63] = 1; num[63] = 0; end
        1: num = den;
        2: begin den[63] = 1; num = den - 1; end
        3: begin den[63:32] = 0; num = {32'd0, num[31:0]}; end
        default: begin end
      endcase
      one(num, rnd64(), den, 1'(i));
    end
    // Cancellation at every possible recurrence age, followed by fresh work.
    for (int age=0; age<80; age++) begin
      req = 1; a0 = 64'h1234567812345678; a1 = '1; b = 64'h87654321abcdef01;
      tick(); req = 0;
      repeat (age) tick();
      rst_n = 0; tick(); rst_n = 1; resets++;
      repeat (3) tick();
      one(64'h7fffffffffffffff, '1, 64'h8000000000000001, 1);
    end
    // Continuous req also exercises saturation and back-to-back idle accepts.
    req = 1;
    repeat (2000) begin a0 = rnd64(); a1 = rnd64(); b = rnd64(); tick(); end
    req = 0;
    repeat (100) tick();
    foreach (seen_state[i]) if (!seen_state[i]) $fatal(1, "uncovered FSM state %0d", i);
    if (!correction_cycles || resets != 80 || completed < 10086)
      $fatal(1, "incomplete witness completed=%0d correction=%0d", completed, correction_cycles);
    $display("ESTDIV-NARROW-MITER-OK clocks=%0d completed=%0d resets=%0d correction_cycles=%0d",
             clocks, completed, resets, correction_cycles);
    $finish;
  end
endmodule
`default_nettype wire
