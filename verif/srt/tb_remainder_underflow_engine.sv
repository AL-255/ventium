`timescale 1ns/1ps
`default_nettype none
// Accepted UM ownership, exact normalization and reset. The architectural
// shell/native tests separately cover exception priority, stack and status.
module tb_remainder_underflow_engine;
  logic clk=0, rst_n=0, start=0, prem1=0, um=1, buggy=0;
  logic [1:0] mode=0, rc=0, pc=3;
  logic [79:0] a=0, b=0;
  logic busy, done, up, c2, ie;
  logic [82:0] result;
  logic [2:0] q;
  always #5 clk=~clk;
  fpu_srt_div dut (
    .clk(clk), .rst_n(rst_n), .start(start), .mode(mode), .prem1(prem1),
    .rem_underflow_mask(um), .a(a), .b(b),
`ifdef VEN_SRT_REM_OPERAND_SPLIT
    .rem_a(a), .rem_b(b),
`endif
    .rc(rc), .pc(pc), .buggy(buggy), .busy(busy), .done(done),
    .result(result), .rounded_up(up), .rem_q012(q), .rem_c2(c2), .rem_ie(ie)
  );
  task automatic remainder(input logic [79:0] av,bv,
      input logic mask, input logic [82:0] expected, input logic [2:0] quotient);
    int clocks;
    @(negedge clk); mode=2; a=av; b=bv; prem1=0; um=mask; start=1;
    @(negedge clk);
    // All unaccepted command values change, including UM. A new start while
    // busy is ignored; it must not alter the accepted result or raise UE.
    a=80'h7fff8000000000000000; b=0; um=~mask; mode=1; prem1=1;
    rc=2; pc=0;
    clocks=0;
    while (!done && clocks<100) begin
      @(negedge clk); clocks++; start=0;
    end
    start=0;
    if (!done || result!==expected || q!==quotient || c2 || ie || up)
      $fatal(1,"REM-UM-OWNER mask=%0d result=%h expected=%h q=%d",mask,result,expected,q);
    @(negedge clk);
    if (done || busy) $fatal(1,"REM-UM-DUPLICATE");
  endtask
  task automatic exact_nonrem(input logic [1:0] next_mode,
      input logic [79:0] av,bv);
    int clocks;
    @(negedge clk); mode=next_mode; a=av; b=bv; prem1=0; um=0;
    rc=0; pc=3; start=1;
    @(negedge clk); start=0; clocks=0;
    while (!done && clocks<100) begin @(negedge clk); clocks++; end
    if (!done || result!=={3'b000,80'h40008000000000000000} || up)
      $fatal(1,"REM-UE-NONREM-LEAK mode=%0d result=%h",next_mode,result);
    @(negedge clk);
    if (done || busy) $fatal(1,"REM-NONREM-DUPLICATE");
  endtask
  initial begin
    logic [63:0] bitvalue;
    logic [14:0] expvalue;
    logic [82:0] expected;
    int count;
    repeat (3) @(negedge clk); rst_n=1; count=0;
    for (int mask=0;mask<2;mask++) begin
      for (int signbit=0;signbit<2;signbit++) begin
        for (int bitnum=0;bitnum<63;bitnum++) begin
          bitvalue=64'd1<<bitnum; expvalue=15'(24514+bitnum);
          expected=mask ? {3'b000,1'(signbit),15'd0,bitvalue}
                        : {3'b010,1'(signbit),expvalue,64'h8000000000000000};
          remainder({1'(signbit),15'd1,64'h8000000000000000|bitvalue},
                    80'h00018000000000000000,1'(mask),expected,3'd1);
          count++;
          // Both Q=0 bypasses must reuse the same normalizer, with no extra
          // iterative step and no dependency on the old divisor or prem1.
          remainder({1'(signbit),15'd0,bitvalue},
                    80'h40008000000000000000,1'(mask),expected,3'd0);
          count++;
          remainder({1'(signbit),15'd0,bitvalue},
                    80'h7fff8000000000000000,1'(mask),expected,3'd0);
          count++;
        end
      end
    end
    // Cancel an unmasked result before RNORM; then exercise the opposite UM.
    @(negedge clk); mode=2; prem1=0; um=0; start=1;
    a=80'h00018000000000000001; b=80'h00018000000000000000;
    @(negedge clk); start=0; repeat (4) @(negedge clk); rst_n=0;
    @(negedge clk); rst_n=1;
    repeat (75) begin @(negedge clk); if (done || busy) $fatal(1,"REM-UM-RESET"); end
    remainder(80'h00018000000000000001,80'h00018000000000000000,
              1'b1,{3'b000,80'h00000000000000000001},3'd1);
    remainder(80'h00018000000000000001,80'h00018000000000000000,
              1'b0,{3'b010,80'h5fc28000000000000000},3'd1);
    exact_nonrem(0,80'h4001c000000000000000,80'h4000c000000000000000); // 6/3
    exact_nonrem(1,80'h40018000000000000000,80'd0);                    // sqrt(4)
    $display("REM-UNDERFLOW-ENGINE-OK rows=%0d reset=1 div_sqrt=2",count+2); $finish;
  end
  initial begin #10000000; $fatal(1,"REM-UM-TIMEOUT"); end
endmodule
`default_nettype wire
