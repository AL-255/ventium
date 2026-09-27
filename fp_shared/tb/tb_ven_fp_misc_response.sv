// Registered response timing, operand capture, reset and sustained admission.
`timescale 1ns/1ps
module tb_ven_fp_misc_response;
  import fpu_x87_pkg::*;
  import ventium_decode_pkg::*;
  logic clk=0;
  always #5 clk=~clk;
  logic rst_n=0, start=0, bug=0;
  fxop_e op=FX_NONE;
  logic [79:0] a=0, b=0, value;
  logic [1:0] rc=0, pc=3;
  logic busy, done, ie, oe, ue, pe;
  int tests=0;
`ifdef VEN_FP_MISC_EARLY_DONE
  localparam int LATENCY=1;
`else
  localparam int LATENCY=2;
`endif
  ven_fp_misc dut(.clk, .rst_n, .start, .op, .operand_a(a), .operand_b(b),
      .rc, .pc, .fist_bug(bug), .busy, .done, .value,
      .flag_ie(ie), .flag_oe(oe), .flag_ue(ue), .flag_pe(pe));
  task automatic tick(); @(posedge clk); #1; endtask
  task automatic issue(input fxop_e operation, input logic [79:0] operand,
      input logic [79:0] operand2, input logic [1:0] rounding,
      input logic [1:0] precision, input logic [79:0] expected,
      input logic [3:0] flags);
    int waited;
    @(negedge clk);
    if(busy || done) $fatal(1,"not idle before command");
    op=operation; a=operand; b=operand2; rc=rounding; pc=precision; start=1;
    tick();
    if(done || !busy) $fatal(1,"capture edge response");
    @(negedge clk);
    // Every source/control pin changes while the captured owner executes.
    start=0; op=FX_NONE; a='1; b='1; rc=~rounding; pc=~precision;
    waited=0;
    while(!done) begin
      tick(); waited++;
      if(waited>3) $fatal(1,"response timeout");
    end
    if(waited!=LATENCY || busy) $fatal(1,"wrong response latency %0d",waited);
    if(value!==expected || {ie,oe,ue,pe}!==flags)
      $fatal(1,"op=%0d rc=%0d pc=%0d got=%h flags=%h expected=%h flags=%h",
             operation,rounding,precision,value,{ie,oe,ue,pe},expected,flags);
    tick();
    if(done) $fatal(1,"duplicate response");
    tests++;
  endtask
  initial begin
    tick(); tick(); rst_n=1;
    // Exact loads/stores plus inexact signed conversion across every RC/PC.
    for(int r=0;r<4;r++) begin
      for(int p=0;p<4;p++) if(p!=1) begin
        issue(FX_FST_M32,80'h3fffc000000000000000,0,2'(r),2'(p),80'h3fc00000,0);
        issue(FX_FST_M64,80'h3fffc000000000000000,0,2'(r),2'(p),80'h3ff8000000000000,0);
        issue(FX_FST_M80,80'h3fffc000000000000001,0,2'(r),2'(p),80'h3fffc000000000000001,0);
        issue(FX_FIST_M16,80'h3fffc000000000000000,0,2'(r),2'(p),
              (r==0 || r==2)?80'd2:80'd1,4'b0001);
        issue(FX_FIST_M32,80'hbfffc000000000000000,0,2'(r),2'(p),
              (r==0 || r==1)?80'hfffffffe:80'hffffffff,4'b0001);
        issue(FX_FIST_M64,80'h3fffc000000000000000,0,2'(r),2'(p),
              (r==0 || r==2)?80'd2:80'd1,4'b0001);
        issue(FX_FRNDINT,80'h3fffc000000000000000,0,2'(r),2'(p),
              (r==0 || r==2)?80'h40008000000000000000:80'h3fff8000000000000000,4'b0001);
        issue(FX_FSCALE,80'h3fffc000000000000000,80'h40008000000000000000,
              2'(r),2'(p),80'h4001c000000000000000,0);
        // IE and range flags reach the shell unchanged; masks live there,
        // not in this service. Architectural masked/unmasked gates are separate.
        issue(FX_FIST_M32,80'h7fff8000000000000000,0,2'(r),2'(p),80'h80000000,4'b1000);
        issue(FX_FSCALE,80'h3fff8000000000000000,80'h400e8000000000000000,
              2'(r),2'(p),80'h7fff8000000000000000,4'b0100);
        issue(FX_FSCALE,80'h3fff8000000000000000,80'hc00e8000000000000000,
              2'(r),2'(p),80'h00000000000000000000,4'b0010);
      end
    end
    // Held start is accepted only on idle edges; no drops or duplicates.
    begin
      int accepted, completed;
      accepted=0; completed=0;
      @(negedge clk); start=1; op=FX_FST_M32;
      a=80'h3fff8000000000000000; rc=0; pc=3;
      repeat(60) begin
        if(!busy) accepted++;
        tick();
        if(done) begin
          completed++;
          if(value!=80'h3f800000 || {ie,oe,ue,pe}!=0)
            $fatal(1,"held-start result");
        end
        @(negedge clk);
      end
      start=0;
      repeat(4) begin tick(); if(done) completed++; end
      if(accepted!=completed || accepted!=60/(LATENCY+1))
        $fatal(1,"held-start accounting %0d/%0d",accepted,completed);
    end
    // Reset aborts captured work and a registered response, without replay.
    for(int phase=0;phase<=LATENCY;phase++) begin
      @(negedge clk); start=1; op=FX_FST_M32;
      a=80'h3fff8000000000000000;
      tick();
      start=0; // after the sampled capture edge, before reset-phase waiting
      repeat(phase) tick();
      @(negedge clk); rst_n=0;
      tick();
      if(done || busy || value!=0 || {ie,oe,ue,pe}!=0) $fatal(1,"reset state");
      @(negedge clk); rst_n=1;
      repeat(4) begin tick(); if(done || busy) $fatal(1,"response after reset"); end
    end
    $display("FP-MISC-RESPONSE-OK tests=%0d latency=%0d",tests,LATENCY);
    $finish;
  end
endmodule
