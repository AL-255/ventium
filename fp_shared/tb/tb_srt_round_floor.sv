`timescale 1ns/1ps
`default_nettype none

// Original and private repaired SRT engine, identical clocks/inputs. Vector
// values come from actual native x87, independently matched to pinned QEMU.
// C1 has its own known-open test; this gate covers value/exception/latency only.
module tb_srt_round_floor;
  logic clk = 0, rst_n = 0, start = 0;
  always #5 clk = ~clk;
  logic [1:0] mode = 0, pc = 0, rc = 0;
  logic [79:0] a = 0, b = 0;
  logic old_busy, old_done, new_busy, new_done;
  logic [82:0] old_result, new_result;
  logic [2:0] old_q, new_q;
  logic old_c2, new_c2, old_ie, new_ie;
  int count = 0, parent_mismatches = 0;

  fpu_srt_div old_dut (
    .clk(clk), .rst_n(rst_n), .start(start), .mode(mode), .prem1(1'b0),
    .a(a), .b(b), .pc(pc), .rc(rc), .buggy(1'b0),
    .busy(old_busy), .done(old_done), .result(old_result),
    .rem_q012(old_q), .rem_c2(old_c2), .rem_ie(old_ie)
  );
  fpu_srt_div_floor_candidate new_dut (
    .clk(clk), .rst_n(rst_n), .start(start), .mode(mode), .prem1(1'b0),
    .a(a), .b(b), .pc(pc), .rc(rc), .buggy(1'b0),
    .busy(new_busy), .done(new_done), .result(new_result),
    .rem_q012(new_q), .rem_c2(new_c2), .rem_ie(new_ie)
  );

  // A result repair may not serialize or add an extra recurrence/round clock.
  always @(negedge clk) begin
    if (rst_n && {old_busy, old_done} !== {new_busy, new_done})
      $fatal(1, "handshake changed at case %0d", count);
  end

  initial begin
    string path;
    int fd, fields, clocks;
    logic [79:0] expected;
    if (!$value$plusargs("vectors=%s", path)) $fatal(1, "missing vectors");
    fd = $fopen(path, "r");
    if (!fd) $fatal(1, "cannot open vector file");
    repeat (3) @(negedge clk);
    rst_n = 1;
    while (!$feof(fd)) begin
      fields = $fscanf(fd, "%h %h %h %h %h %h\n", mode, pc, rc, a, b, expected);
      if ((fields == 0 || fields == -1) && $feof(fd)) break;
      if (fields != 6) $fatal(1, "bad vector %0d fields=%0d", count, fields);
      start = 1;
      @(negedge clk);
      start = 0;
      clocks = 0;
      while (!new_done) begin
        @(negedge clk);
        clocks++;
        if (clocks > 100) $fatal(1, "engine timeout case=%0d", count);
      end
      if (new_result[79:0] !== expected)
        $fatal(1, "new mismatch case=%0d mode=%0d pc=%0d rc=%0d a=%020h b=%020h got=%020h exp=%020h",
               count, mode, pc, rc, a, b, new_result[79:0], expected);
      if (old_result[82:80] !== new_result[82:80])
        $fatal(1, "exception flags changed case=%0d", count);
      if (old_result[79:0] !== expected) parent_mismatches++;
      count++;
      @(negedge clk);
    end
    $fclose(fd);
    if (count != 912 || parent_mismatches != 4)
      $fatal(1, "wrong corpus or ineffective negative control count=%0d parent_bad=%0d",
             count, parent_mismatches);
    // Cancel a real long operation through synchronous reset. Neither engine
    // may emit its pre-reset result later.
    mode = 1; pc = 2; rc = 2; a = 80'h7ffe_ffffffffffffffff;
    start = 1;
    @(negedge clk);
    start = 0;
    repeat (9) @(negedge clk);
    if (!old_busy || !new_busy) $fatal(1, "cancel did not reach active recurrence");
    rst_n = 0;
    repeat (2) @(negedge clk);
    rst_n = 1;
    repeat (50) begin
      @(negedge clk);
      if (old_busy || new_busy || old_done || new_done) $fatal(1, "reset leaked completion");
    end
    $display("SRT-ROUND-FLOOR-OK cases=%0d parent_mismatches=%0d latency_unchanged=1 reset_cancel=1",
             count, parent_mismatches);
    $finish;
  end
endmodule
`default_nettype wire
