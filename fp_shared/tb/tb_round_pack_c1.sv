`timescale 1ns/1ps
`default_nettype none
module tb_round_pack_c1;
  import fpu_x87_pkg::*;
  initial begin
    string path;
    int fd, fields, checks;
    logic sign, sticky, expected_c1;
    logic signed [31:0] exponent;
    logic [127:0] sig;
    logic [1:0] rc, pc;
    logic [79:0] expected_value;
    logic [83:0] actual;
    logic [82:0] old, compat;
    if (!$value$plusargs("vectors=%s", path)) $fatal(1, "missing vector path");
    fd = $fopen(path, "r");
    if (!fd) $fatal(1, "cannot open vector file");
    checks = 0;
    while (!$feof(fd)) begin
      fields = $fscanf(fd, "%h %d %h %h %h %h %h %h\n",
                        sign, exponent, sig, sticky, rc, pc, expected_c1, expected_value);
      if ((fields == 0 || fields == -1) && $feof(fd)) break;
      if (fields != 8) $fatal(1, "bad vector %0d", checks);
      actual = fx_round_pack_c1(sign, exponent, sig, sticky, rc, pc);
      old = fx_round_pack_reference(sign, exponent, sig, sticky, rc, pc);
      compat = fx_round_pack_f(sign, exponent, sig, sticky, rc, pc);
      if (actual[82:0] !== old || compat !== old)
        $fatal(1, "legacy value/exception ABI changed case=%0d", checks);
      if (actual[79:0] !== expected_value || actual[83] !== expected_c1)
        $fatal(1, "round mismatch case=%0d sign=%0d exp=%0d sig=%032h sticky=%0d rc=%0d pc=%0d got=%021h expected_c1=%0d expected_value=%020h",
               checks, sign, exponent, sig, sticky, rc, pc, actual, expected_c1, expected_value);
      checks++;
    end
    $fclose(fd);
    if (checks != 15600) $fatal(1, "wrong vector count %0d", checks);
    $display("ROUND-PACK-C1-OK cases=%0d legacy_value_flags_unchanged=1", checks);
    $finish;
  end
endmodule
`default_nettype wire
