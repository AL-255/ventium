`timescale 1ns/1ps
module tb_rem_clz_tree;
`include "functions.svh"
  integer checks = 0;
  logic [63:0] value;
  logic [63:0] rng = 64'h87654321abcdef01;

  task automatic check(input logic [63:0] x);
    logic [6:0] got, expected;
    got = rem_clz64_tree(x);
    expected = rem_clz64_original(x);
    if (got !== expected)
      $fatal(1,"REM-CLZ-MISMATCH x=%h got=%d expected=%d",x,got,expected);
    checks++;
  endtask

  initial begin
    check(64'd0); check('1); check('x); check('z);
    for (int i=0; i<64; i++) begin
      check(64'd1<<i); check(~(64'd1<<i));
      // Every location relative to the highest known one, and both unknowns.
      for (int j=0; j<64; j++) begin
        for (int z=0; z<2; z++) begin
          value=64'd1<<i; value[j]=z ? 1'bz : 1'bx; check(value);
          value=z ? 'z : 'x; value[i]=1'b1; value[j]=1'b0; check(value);
        end
      end
    end
    // Exhaust every 16-bit pattern in each quadrant, including all boundaries.
    for (int quadrant=0; quadrant<4; quadrant++)
      for (int bits=0; bits<65536; bits++) check(64'(bits)<<(16*quadrant));
    // Deterministic mixtures, retaining the actual four-state RTL semantics.
    for (int k=0; k<16384; k++) begin
      rng=rng^(rng<<13); rng=rng^(rng>>7); rng=rng^(rng<<17);
      check(rng); value=rng;
      for (int bitno=0; bitno<64; bitno++)
        if ((bitno+k)%3==0) value[bitno]=k[0] ? 1'bx : 1'bz;
      check(value);
    end
    if (checks != 311428) $fatal(1,"REM-CLZ-WRONG-COVERAGE %0d",checks);
    $display("REM-CLZ-TREE-OK checks=%0d",checks);
    $finish;
  end
endmodule
