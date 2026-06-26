// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/l1/tb_icache_snoop.sv — Phase D.6 (mechanism): the icache per-line snoop-invalidate.
// The icache snoop port was added in Phase A but is tied 0 at the core.sv instantiation and
// the top-level threading (ven_northbridge.snoop_inv_* → core.u_icache) requires editing
// ventium_top.sv. This gate proves the icache snoop MECHANISM directly: fill a line, confirm
// it is resident (ic_val_o), pulse snoop_inv for it, confirm it is invalidated — and that a
// non-matching snoop leaves it alone. Prints ICSNOOP-GATE-OK / -FAIL.

module tb_icache_snoop;
  localparam int IC_SETS=128, IC_LINE=32, IC_WAYS=2;
  localparam int IDXW=$clog2(IC_SETS), WAYW=1, TAGW=32-5-IDXW;

  logic clk=0, rst_n=0; always #5 clk=~clk;

  logic [IDXW-1:0] rd_setA=0, rd_setB=0; logic [WAYW-1:0] rd_wayA=0, rd_wayB=0;
  logic [IC_LINE*8-1:0] rd_lineA, rd_lineB; logic rd_collA, rd_collB;
  logic [TAGW-1:0] ic_tag_o [IC_SETS][IC_WAYS];
  logic            ic_val_o [IC_SETS][IC_WAYS];
  logic [WAYW-1:0] ic_victim_o [IC_SETS];
  logic            fill_en=0; logic [IDXW-1:0] fill_set=0; logic [WAYW-1:0] fill_way=0;
  logic [4:0]      fill_off=0; logic [31:0] fill_data=0; logic fill_done=0; logic [TAGW-1:0] fill_tag=0;
  logic tch0_en=0, tch1_en=0, tch2_en=0; logic [IDXW-1:0] tch0_set=0, tch1_set=0, tch2_set=0;
  logic [TAGW-1:0] tch0_tag=0, tch1_tag=0, tch2_tag=0;
  logic        snoop_inv_valid=0; logic [31:0] snoop_inv_addr=0;

  icache #(.IC_SETS(IC_SETS), .IC_LINE(IC_LINE), .IC_WAYS(IC_WAYS)) dut (
      .clk(clk), .rst_n(rst_n),
      .rd_setA(rd_setA), .rd_wayA(rd_wayA), .rd_lineA(rd_lineA),
      .rd_setB(rd_setB), .rd_wayB(rd_wayB), .rd_lineB(rd_lineB),
      .rd_collA(rd_collA), .rd_collB(rd_collB),
      .ic_tag_o(ic_tag_o), .ic_val_o(ic_val_o), .ic_victim_o(ic_victim_o),
      .fill_en(fill_en), .fill_set(fill_set), .fill_way(fill_way), .fill_off(fill_off),
      .fill_data(fill_data), .fill_done(fill_done), .fill_tag(fill_tag),
      .tch0_en(tch0_en), .tch0_set(tch0_set), .tch0_tag(tch0_tag),
      .tch1_en(tch1_en), .tch1_set(tch1_set), .tch1_tag(tch1_tag),
      .tch2_en(tch2_en), .tch2_set(tch2_set), .tch2_tag(tch2_tag),
      .snoop_inv_valid(snoop_inv_valid), .snoop_inv_addr(snoop_inv_addr));

  int errors=0;
  task automatic chk(input string what, input logic got, exp);
    if (got!==exp) begin $display("  FAIL %s: got %0d exp %0d", what, got, exp); errors++; end
    else $display("  ok   %s = %0d", what, got);
  endtask
  // fill the line covering `a` into {set,way} with tag from `a`.
  task automatic fill_line(input [31:0] a, input [WAYW-1:0] way);
    @(negedge clk);
    for (int w=0; w<8; w++) begin
      fill_en<=1; fill_set<=a[5 +: IDXW]; fill_way<=way; fill_off<=5'(w*4); fill_data<=32'hC0DE_0000+w;
      fill_done<=(w==7); fill_tag<=a[5+IDXW +: TAGW];
      @(negedge clk);
    end
    fill_en<=0; fill_done<=0;
  endtask
  task automatic snoop(input [31:0] a);
    @(negedge clk); snoop_inv_valid<=1; snoop_inv_addr<=a; @(negedge clk); snoop_inv_valid<=0;
  endtask

  initial begin
    repeat(3) @(posedge clk); rst_n<=1'b1; @(posedge clk);

    $display("[1] fill line @0x1000 (set 0, way 0) → resident");
    fill_line(32'h0000_1000, 1'b0);
    @(posedge clk); #1;
    chk("set0/way0 valid after fill", ic_val_o[0][0], 1'b1);

    $display("[2] fill an unrelated line @0x4000 (set 0, way 1) → both resident");
    fill_line(32'h0000_4000, 1'b1);
    @(posedge clk); #1;
    chk("set0/way1 valid after fill", ic_val_o[0][1], 1'b1);

    $display("[3] snoop a NON-matching address (0x9000, set 0, different tag) → no effect");
    snoop(32'h0000_9000);
    @(posedge clk); #1;
    chk("0x1000 still valid (no false invalidate)", ic_val_o[0][0], 1'b1);
    chk("0x4000 still valid",                       ic_val_o[0][1], 1'b1);

    $display("[4] snoop 0x1000 (a DMA write to that line) → invalidates ONLY that way");
    snoop(32'h0000_1000);
    @(posedge clk); #1;
    chk("0x1000 (set0/way0) invalidated", ic_val_o[0][0], 1'b0);
    chk("0x4000 (set0/way1) untouched",   ic_val_o[0][1], 1'b1);

    $display("[5] snoop 0x4000 → invalidates the other way too");
    snoop(32'h0000_4000);
    @(posedge clk); #1;
    chk("0x4000 (set0/way1) invalidated", ic_val_o[0][1], 1'b0);

    if (errors==0) $display("ICSNOOP-GATE-OK (all checks pass)");
    else           $display("ICSNOOP-GATE-FAIL (%0d errors)", errors);
    $finish;
  end
  initial begin #100000; $display("ICSNOOP-GATE-FAIL (timeout)"); $finish; end
endmodule
