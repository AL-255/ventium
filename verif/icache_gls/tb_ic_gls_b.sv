// verif/icache_gls/tb_ic_gls_b.sv — gate-level funcsim TB that exercises the icache
// PORT-B read (rd_lineB) — the Method-B WORD-REVERSED read path that the original
// tb_ic_gls NEVER checked (it only validated rd_lineA). The spine selects ic_rd_lineB
// for straddle / next-line / branch-target fetches; if the synthesized Method-B
// un-reversal corrupts a word, rd_lineB returns wrong bytes -> wrong fetched opcode
// (A[2]-drop-class symptom) while 2-state Verilator reads clean. Drives the real
// RAMB36 netlist (icache_funcsim.v).
`timescale 1ns/1ps
module tb_ic_gls_b;
  localparam SETS=128, WAYS=2, IDXW=7, WAYW=1, TAGW=20;
  logic clk=0, rst_n=0;
  logic [IDXW-1:0] rd_setA=0, rd_setB=0, fill_set=0;
  logic [WAYW-1:0] rd_wayA=0, rd_wayB=0, fill_way=0;
  logic [255:0] rd_lineA, rd_lineB;
  logic rd_collA, rd_collB;
  logic fill_en=0, fill_done=0;
  logic [4:0] fill_off=0;
  logic [31:0] fill_data=0;
  logic [TAGW-1:0] fill_tag=0;
  logic mirror_keep;
  ic_gls_wrap dut(.clk,.rst_n,.rd_setA,.rd_wayA,.rd_lineA,.rd_setB,.rd_wayB,.rd_lineB,
    .rd_collA,.rd_collB,.fill_en,.fill_set,.fill_way,.fill_off,.fill_data,.fill_done,.fill_tag,.mirror_keep(mirror_keep));
  always #5 clk=~clk;
  function [31:0] gv(input [IDXW-1:0] s, input [WAYW-1:0] w, input [2:0] wd);
    gv = {s, w, wd, 5'h1F, 12'(s*7 + w*3 + wd*131 + 32'h2D1)};
  endfunction
  task fill_line(input [IDXW-1:0] s, input [WAYW-1:0] w);
    for (int wd=0; wd<8; wd++) begin
      @(negedge clk); fill_en=1; fill_set=s; fill_way=w; fill_off=wd*4;
      fill_data=gv(s,w,wd[2:0]); fill_done=(wd==7); fill_tag=20'(s+w);
    end
    @(negedge clk); fill_en=0; fill_done=0;
  endtask
  int errsA=0, errsB=0;
  // read via PORT B and check rd_lineB (the Method-B reversed-read path)
  task check_read_B(input [IDXW-1:0] s, input [WAYW-1:0] w);
    @(negedge clk); rd_setB=s; rd_wayB=w;
    @(posedge clk); @(posedge clk); #1;
    for (int wd=0; wd<8; wd++)
      if (rd_lineB[wd*32 +: 32] !== gv(s,w,wd[2:0]) && !rd_collB) begin
        errsB++;
        if (errsB<=24) $display("B-MISMATCH set=%0d way=%0d wd=%0d got=%08x exp=%08x collB=%b",
                                s,w,wd,rd_lineB[wd*32 +: 32],gv(s,w,wd[2:0]),rd_collB);
      end
  endtask
  // read via PORT A (control: should already be clean per tb_ic_gls)
  task check_read_A(input [IDXW-1:0] s, input [WAYW-1:0] w);
    @(negedge clk); rd_setA=s; rd_wayA=w;
    @(posedge clk); @(posedge clk); #1;
    for (int wd=0; wd<8; wd++)
      if (rd_lineA[wd*32 +: 32] !== gv(s,w,wd[2:0]) && !rd_collA) errsA++;
  endtask
  initial begin
    repeat(4) @(negedge clk); rst_n=1; repeat(2) @(negedge clk);
    for (int s=0;s<SETS;s++) for (int w=0;w<WAYS;w++) fill_line(s[IDXW-1:0],w[WAYW-1:0]);
    // PORT B read-back of EVERY line/word (the untested Method-B path)
    for (int s=0;s<SETS;s++) for (int w=0;w<WAYS;w++) check_read_B(s[IDXW-1:0],w[WAYW-1:0]);
    // control: PORT A
    for (int s=0;s<SETS;s++) for (int w=0;w<WAYS;w++) check_read_A(s[IDXW-1:0],w[WAYW-1:0]);
    $display("PORT-A errs=%0d  PORT-B errs=%0d", errsA, errsB);
    $display((errsA==0 && errsB==0) ? "IC_GLS_B_PASS" : "IC_GLS_B_FAIL");
    $finish;
  end
endmodule
