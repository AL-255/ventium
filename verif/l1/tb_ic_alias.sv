// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/l1/tb_ic_alias.sv — REVIEW1_Aug2 H-05 / REVIEW1_Aug3 R2-H09: I-cache
// coherence across CPU virtual ALIASES.
//
// One physical page can be mapped by several linear addresses. The I-cache
// lookup is linear (VIPT: the set index is page-offset bits), and each line now
// also records its PHYSICAL page tag (ic_ptag, written from fill_ptag at
// fill_done). A CPU store snoop carries the store's PHYSICAL address
// (core_addr / post-mem_xlate mem_addr), so a store through ANY alias of a
// physical line matches every aliased copy in the set and drops them all.
//
// This gate drives PORT 1 (the CPU store snoop) directly:
//
//   default build             the alias line is DROPPED (the fix: physical match)
//   +VEN_IC_SNOOP_LINEAR      the legacy linear compare returns; the snoop
//                             carries the store's LINEAR address (what the
//                             pre-fix core sent) and the alias line SURVIVES
//                             -> the hazard is reproduced, so the gate
//                             provably discriminates fix from defect
//   +VEN_IC_ALIAS_SAFE        the conservative full flush also drops it
//
// The control (a store to the SAME line must always invalidate it) runs in all
// modes, so a build that cached nothing could not pass by accident.

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
  logic [4:0]      fill_off=0; logic [31:0] fill_data=0; logic fill_done=0;
  logic [TAGW-1:0] fill_tag=0, fill_ptag=0;
  logic tch0_en=0, tch1_en=0, tch2_en=0; logic [IDXW-1:0] tch0_set=0, tch1_set=0, tch2_set=0;
  logic [TAGW-1:0] tch0_tag=0, tch1_tag=0, tch2_tag=0;
  logic        snoop_inv_valid=0; logic [31:0] snoop_inv_addr=0;
  logic        fill_nocache=0;
  logic        snp1_v=0; logic [31:0] snp1_a=0;   // the CPU STORE snoop (port 1)
  logic        snp1_hit; logic [IDXW-1:0] snp1_hset; logic [WAYW-1:0] snp1_hway;
  logic        snp2_hit; logic [IDXW-1:0] snp2_hset; logic [WAYW-1:0] snp2_hway;

  icache #(.IC_SETS(IC_SETS), .IC_LINE(IC_LINE), .IC_WAYS(IC_WAYS)) dut (
      .clk(clk), .rst_n(rst_n),
      .rd_setA(rd_setA), .rd_wayA(rd_wayA), .rd_lineA(rd_lineA),
      .rd_setB(rd_setB), .rd_wayB(rd_wayB), .rd_lineB(rd_lineB),
      .rd_collA(rd_collA), .rd_collB(rd_collB),
      .ic_tag_o(ic_tag_o), .ic_val_o(ic_val_o), .ic_victim_o(ic_victim_o),
      .fill_en(fill_en), .fill_set(fill_set), .fill_way(fill_way), .fill_off(fill_off),
      .fill_data(fill_data), .fill_nocache(fill_nocache),
      .fill_done(fill_done), .fill_tag(fill_tag), .fill_ptag(fill_ptag),
      .tch0_en(tch0_en), .tch0_set(tch0_set), .tch0_tag(tch0_tag),
      .tch1_en(tch1_en), .tch1_set(tch1_set), .tch1_tag(tch1_tag),
      .tch2_en(tch2_en), .tch2_set(tch2_set), .tch2_tag(tch2_tag),
      .snoop_inv_valid(snoop_inv_valid), .snoop_inv_addr(snoop_inv_addr),
      .snoop_inv_valid1(snp1_v), .snoop_inv_addr1(snp1_a),
      .snoop_inv_valid2(1'b0), .snoop_inv_addr2(32'd0),
      .snoop1_hit(snp1_hit), .snoop1_hset(snp1_hset), .snoop1_hway(snp1_hway),
      .snoop2_hit(snp2_hit), .snoop2_hset(snp2_hset), .snoop2_hway(snp2_hway),
      // REVIEW_Jul29 H-12 added a global-invalidate port; this TB exercises the
      // per-line snoop path only, so tie it off rather than leave it floating.
      .flush_all(1'b0));

  int errors=0;
  // the match outputs are combinational and live only during the pulse — sample
  // sticky, cleared per snoop.
  logic snp1_hit_seen=0;
  always @(posedge clk) if (snp1_hit) snp1_hit_seen <= 1'b1;
  task automatic chk(input string what, input logic got, exp);
    if (got!==exp) begin $display("  FAIL %s: got %0d exp %0d", what, got, exp); errors++; end
    else $display("  ok   %s = %0d", what, got);
  endtask
  // fill a line: linear tag from `lin`, PHYSICAL tag from `phys` (R2-H09)
  task automatic fill_line(input [31:0] lin, input [31:0] phys, input [WAYW-1:0] way);
    @(negedge clk);
    for (int w=0; w<8; w++) begin
      fill_en<=1; fill_set<=lin[5 +: IDXW]; fill_way<=way; fill_off<=5'(w*4);
      fill_data<=32'hC0DE_0000+w;
      fill_done<=(w==7); fill_tag<=lin[5+IDXW +: TAGW]; fill_ptag<=phys[5+IDXW +: TAGW];
      @(negedge clk);
    end
    fill_en<=0; fill_done<=0;
  endtask
  // a CPU STORE snoop (port 1), carrying the store's address in the build's
  // snoop domain (PHYSICAL in the default/fixed build, LINEAR under
  // VEN_IC_SNOOP_LINEAR -- what the pre-fix core sent).
  task automatic store_snoop(input [31:0] a);
    snp1_hit_seen <= 1'b0;
    @(negedge clk); snp1_v<=1; snp1_a<=a; @(negedge clk); snp1_v<=0;
    @(negedge clk);
  endtask

  // Two linear aliases of ONE physical page. They necessarily share the set
  // index (paging preserves the page-offset bits); they differ in the linear
  // tag, which is exactly the alias shape.
  localparam logic [31:0] ALIAS_A = 32'h0000_1000;
  localparam logic [31:0] ALIAS_B = 32'h0000_3000;
  localparam logic [31:0] PHYS_P  = 32'h0000_5000;   // the shared physical page
  // the address a store "through alias B to PHYS_P" presents on the snoop port
  // in each build's domain
`ifdef VEN_IC_SNOOP_LINEAR
  localparam logic [31:0] STORE_B = ALIAS_B;          // legacy core: linear
`else
  localparam logic [31:0] STORE_B = PHYS_P;           // fixed core: physical
`endif

  initial begin
    repeat(3) @(posedge clk); rst_n<=1'b1; @(posedge clk);

    $display("== REVIEW1_Aug3 R2-H09: physical snoop tags across CPU aliases ==");
`ifdef VEN_IC_SNOOP_LINEAR
    $display("   build: VEN_IC_SNOOP_LINEAR (legacy linear compare -- the hazard)");
`elsif VEN_IC_ALIAS_SAFE
    $display("   build: VEN_IC_ALIAS_SAFE (a CPU store flushes executable state)");
`else
    $display("   build: default (physical snoop tags -- the fix)");
`endif

    // ---- CONTROL: a store to a line must invalidate THAT line, in all modes --
    fill_line(ALIAS_B, PHYS_P, 1'b0);
    @(posedge clk); #1;
    chk("line resident after fill via alias B", ic_val_o[ALIAS_B[11:5]][0], 1'b1);
    store_snoop(STORE_B);
    @(posedge clk); #1;
    chk("the line invalidated by a store to it (control)", ic_val_o[ALIAS_B[11:5]][0], 1'b0);

    // ---- THE FINDING ----------------------------------------------------------
    fill_line(ALIAS_A, PHYS_P, 1'b0);
    @(posedge clk); #1;
    chk("alias A resident after fill", ic_val_o[ALIAS_A[11:5]][0], 1'b1);

    store_snoop(STORE_B);          // the CPU wrote the code THROUGH alias B
    @(posedge clk); #1;

`ifdef VEN_IC_SNOOP_LINEAR
    if (ic_val_o[ALIAS_A[11:5]][0] === 1'b1) begin
      $display("  HAZARD REPRODUCED (control): alias A survives a store through");
      $display("      alias B under the legacy linear compare -- this build proves");
      $display("      the gate discriminates the fix from the defect.");
    end else begin
      $display("  FAIL the linear-compare control build did NOT exhibit the hazard --");
      $display("       the gate cannot distinguish fix from defect.");
      errors++;
    end
`else
    chk("alias A dropped by a store through alias B (physical match)",
        ic_val_o[ALIAS_A[11:5]][0], 1'b0);
    chk("the match was reported on the snoop1 outputs (uopcache hookup)",
        snp1_hit_seen, 1'b1);
`endif

    if (errors==0) $display("ICALIAS-GATE-OK");
    else           $display("ICALIAS-GATE-FAIL (%0d)", errors);
    $finish;
  end
endmodule
