// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/l1/tb_ic_alias.sv — REVIEW1_Aug2 H-05: linear I-cache tags are incoherent
// across CPU virtual ALIASES.
//
// The I-cache is tagged by LINEAR fetch address, but one physical page can be mapped
// by several linear addresses. A CPU store snoops with the store's LINEAR address
// (ventium_l1_axi.sv:333, icache_snoop_addr1 = core_lin), so it invalidates only the
// line tagged with THAT alias. A stale executable copy stays resident under another
// alias's tag and is fetched and executed. Self-modifying code, any loader that writes
// code through a scratch mapping, and A20 mask changes all produce this shape.
//
// This gate uses the proven tb_icache_snoop harness (fill via fill_en/fill_tag, observe
// residency via ic_val_o) and drives PORT 1 -- the CPU store snoop -- which that gate
// deliberately leaves tied off and therefore never exercised.
//
//   default build           the alias line SURVIVES the store  -> hazard demonstrated
//   +VEN_IC_ALIAS_SAFE      every CPU store flushes executable state -> alias dropped
//
// The control (a store to the SAME line must always invalidate it) runs in both modes,
// so a build that cached nothing could not pass by accident.

module tb_ic_alias;
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
  logic        fill_nocache=0;
  logic        snp1_v=0; logic [31:0] snp1_a=0;   // the CPU STORE snoop (port 1)

  icache #(.IC_SETS(IC_SETS), .IC_LINE(IC_LINE), .IC_WAYS(IC_WAYS)) dut (
      .clk(clk), .rst_n(rst_n),
      .rd_setA(rd_setA), .rd_wayA(rd_wayA), .rd_lineA(rd_lineA),
      .rd_setB(rd_setB), .rd_wayB(rd_wayB), .rd_lineB(rd_lineB),
      .rd_collA(rd_collA), .rd_collB(rd_collB),
      .ic_tag_o(ic_tag_o), .ic_val_o(ic_val_o), .ic_victim_o(ic_victim_o),
      .fill_en(fill_en), .fill_set(fill_set), .fill_way(fill_way), .fill_off(fill_off),
      .fill_data(fill_data), .fill_nocache(fill_nocache),
      .fill_done(fill_done), .fill_tag(fill_tag),
      .tch0_en(tch0_en), .tch0_set(tch0_set), .tch0_tag(tch0_tag),
      .tch1_en(tch1_en), .tch1_set(tch1_set), .tch1_tag(tch1_tag),
      .tch2_en(tch2_en), .tch2_set(tch2_set), .tch2_tag(tch2_tag),
      .snoop_inv_valid(snoop_inv_valid), .snoop_inv_addr(snoop_inv_addr),
      // REVIEW Aug-1 H-09: two further INDEPENDENT invalidation ports (a DMA snoop
      // and a self-modifying store, plus that store's second line when it crosses an
      // I-line boundary, are up to three distinct events in one clock). This gate
      // exercises port 0 only; ports 1/2 are tied off so their behaviour is untested
      // here rather than accidentally aliased onto port 0.
      .snoop_inv_valid1(snp1_v), .snoop_inv_addr1(snp1_a),
      .snoop_inv_valid2(1'b0), .snoop_inv_addr2(32'd0),
      // REVIEW_Jul29 H-12 added a global-invalidate port; this TB exercises the
      // per-line snoop path only, so tie it off rather than leave it floating.
      .flush_all(1'b0));

  int errors=0;
  task automatic chk(input string what, input logic got, exp);
    if (got!==exp) begin $display("  FAIL %s: got %0d exp %0d", what, got, exp); errors++; end
    else $display("  ok   %s = %0d", what, got);
  endtask
  task automatic fill_line(input [31:0] a, input [WAYW-1:0] way);
    @(negedge clk);
    for (int w=0; w<8; w++) begin
      fill_en<=1; fill_set<=a[5 +: IDXW]; fill_way<=way; fill_off<=5'(w*4); fill_data<=32'hC0DE_0000+w;
      fill_done<=(w==7); fill_tag<=a[5+IDXW +: TAGW];
      @(negedge clk);
    end
    fill_en<=0; fill_done<=0;
  endtask
  // a CPU STORE snoop (port 1), carrying the store's LINEAR address
  task automatic store_snoop(input [31:0] a);
    @(negedge clk); snp1_v<=1; snp1_a<=a; @(negedge clk); snp1_v<=0;
    @(negedge clk);
  endtask

  // Two linear addresses that land in DIFFERENT sets, modelling two aliases of one
  // physical page. Distinct sets is the point: a same-set alias would be evicted by
  // capacity and hide the finding.
  localparam logic [31:0] ALIAS_A = 32'h0000_1000;   // set 128'... -> set 0
  localparam logic [31:0] ALIAS_B = 32'h0000_3000;   // -> a different set

  initial begin
    repeat(3) @(posedge clk); rst_n<=1'b1; @(posedge clk);

    $display("== REVIEW1_Aug2 H-05: linear I-tags across CPU virtual aliases ==");
`ifdef VEN_IC_ALIAS_SAFE
    $display("   build: VEN_IC_ALIAS_SAFE ON (a CPU store flushes executable state)");
`else
    $display("   build: default (a store invalidates only its own linear line)");
`endif

    // ---- CONTROL: a store to a line must invalidate THAT line, in both modes ------
    fill_line(ALIAS_B, 1'b0);
    @(posedge clk); #1;
    chk("alias B resident after fill", ic_val_o[ALIAS_B[11:5]][0], 1'b1);
    store_snoop(ALIAS_B);
    @(posedge clk); #1;
    chk("alias B invalidated by a store to B (control)", ic_val_o[ALIAS_B[11:5]][0], 1'b0);

    // ---- THE FINDING -------------------------------------------------------------
    fill_line(ALIAS_A, 1'b0);
    @(posedge clk); #1;
    chk("alias A resident after fill", ic_val_o[ALIAS_A[11:5]][0], 1'b1);

    store_snoop(ALIAS_B);          // the CPU wrote the code THROUGH alias B
    @(posedge clk); #1;

`ifdef VEN_IC_ALIAS_SAFE
    chk("alias A dropped by a store through alias B", ic_val_o[ALIAS_A[11:5]][0], 1'b0);
`else
    if (ic_val_o[ALIAS_A[11:5]][0] === 1'b1) begin
      $display("  HAZARD CONFIRMED: alias A is STILL RESIDENT after a store through");
      $display("                    alias B. Stale executable bytes would be fetched.");
      $display("                    That is H-05. Build +define+VEN_IC_ALIAS_SAFE for");
      $display("                    the correct (expensive) behaviour.");
    end else begin
      $display("  FAIL the DEFAULT build did NOT exhibit the alias hazard -- then this");
      $display("       gate does not exercise the finding and proves nothing.");
      errors++;
    end
`endif

    if (errors==0) $display("ICALIAS-GATE-OK");
    else           $display("ICALIAS-GATE-FAIL (%0d)", errors);
    $finish;
  end
endmodule
