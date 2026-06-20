// verif/icache_gls/tb_ic_gls.sv — gate-level funcsim TB for the residual board-only
// icache READ corruption (the jae-operand corruption at set 0x56, beyond the fixed
// declone/collision). Drives the SYNTHESIZED RAMB36 netlist (icache_funcsim.v) so the
// real SDP-BRAM read/write/collision behavior is modeled (Verilator can't).
//
// Strategy: (1) fill every {set,way} line with 8 DISTINCT words (declone check);
// (2) read every line back on port A, all 8 words must match (catches a wrong way /
// wrong word); (3) CONCURRENT fill+read: read {set,way} while a fill writes a DIFFERENT
// {set,way} in the same set (way-conflict cross-port) and a DIFFERENT set — flag any
// read that doesn't match the last-written content. Any mismatch with rd_collA==0
// (i.e. NOT flagged for re-read) is a silent corruption = the board bug class.
`timescale 1ns/1ps
module tb_ic_gls;
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
  logic tch0_en=0,tch1_en=0,tch2_en=0;
  logic [IDXW-1:0] tch0_set=0,tch1_set=0,tch2_set=0;
  logic [TAGW-1:0] tch0_tag=0,tch1_tag=0,tch2_tag=0;
  logic snoop_inv_valid=0; logic [31:0] snoop_inv_addr=0;

  logic mirror_keep;
  ic_gls_wrap dut(.clk,.rst_n,.rd_setA,.rd_wayA,.rd_lineA,.rd_setB,.rd_wayB,.rd_lineB,
    .rd_collA,.rd_collB,.fill_en,.fill_set,.fill_way,.fill_off,.fill_data,.fill_done,.fill_tag,.mirror_keep(mirror_keep));

  always #5 clk=~clk;
  // golden 32-bit word value for {set,way,word}: distinct, non-palindromic
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
  int errs=0;
  task check_read(input [IDXW-1:0] s, input [WAYW-1:0] w);
    @(negedge clk); rd_setA=s; rd_wayA=w;
    @(posedge clk); @(posedge clk); #1;       // hold addr, let the registered RAMB read settle (2 clk)
    for (int wd=0; wd<8; wd++)
      if (rd_lineA[wd*32 +: 32] !== gv(s,w,wd[2:0]) && !rd_collA) begin
        errs++;
        if (errs<=20) $display("MISMATCH set=%0d way=%0d wd=%0d got=%08x exp=%08x collA=%b",
                               s,w,wd,rd_lineA[wd*32 +: 32],gv(s,w,wd[2:0]),rd_collA);
      end
  endtask
  initial begin
    repeat(4) @(negedge clk); rst_n=1; repeat(2) @(negedge clk);
    // (1)+(2): fill all lines, read all back
    for (int s=0;s<SETS;s++) for (int w=0;w<WAYS;w++) fill_line(s[IDXW-1:0],w[WAYW-1:0]);
    for (int s=0;s<SETS;s++) for (int w=0;w<WAYS;w++) check_read(s[IDXW-1:0],w[WAYW-1:0]);
    $display("PHASE A (fill-all/read-all): errs=%0d", errs);
    // (3): concurrent — read {s,0} while filling {s,1} (same-set way-conflict cross-port)
    for (int s=0;s<SETS;s++) begin
      @(negedge clk); rd_setA=s[IDXW-1:0]; rd_wayA=0;
      fill_en=1; fill_set=s[IDXW-1:0]; fill_way=1; fill_off=4*(s%8); fill_data=gv(s[IDXW-1:0],1,(s%8)); fill_done=0;
      @(posedge clk); #1;
      for (int wd=0; wd<8; wd++)
        if (rd_lineA[wd*32 +: 32] !== gv(s[IDXW-1:0],0,wd[2:0]) && !rd_collA) begin
          errs++; if (errs<=40) $display("XPORT-MISMATCH set=%0d wd=%0d got=%08x exp=%08x collA=%b",
                                         s,wd,rd_lineA[wd*32 +: 32],gv(s[IDXW-1:0],0,wd[2:0]),rd_collA);
        end
      @(negedge clk); fill_en=0;
    end
    $display("PHASE B (concurrent cross-port): total errs=%0d", errs);
    $display(errs==0 ? "IC_GLS_PASS" : "IC_GLS_FAIL");
    $finish;
  end
endmodule
