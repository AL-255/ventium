// Same-cycle area-rewrite miter. The literal parent remains the oracle here;
// this does not establish ISA correctness of its existing conversion behavior.
`timescale 1ns/1ps
module tb_misc_shared_int;
  import ventium_decode_pkg::*;
  logic clk=0;
  always #5 clk=~clk;
  logic rst_n=0, start=0, bug=0;
  fxop_e op=FX_NONE;
  logic [79:0] a=0, b=0, old_value, new_value;
  logic [1:0] rc=0, pc=3;
  logic old_busy, old_done, old_ie, old_oe, old_ue, old_pe, old_up;
  logic new_busy, new_done, new_ie, new_oe, new_ue, new_pe, new_up;
  int cases=0, cycles=0, completions=0, aborts=0;
  logic [63:0] rng=64'h85ab439c702e921d;
`ifdef VEN_FP_MISC_EARLY_DONE
  localparam int LATENCY=1;
`else
  localparam int LATENCY=2;
`endif
  ven_fp_misc_reference old_dut(.clk, .rst_n, .start, .op,
      .operand_a(a), .operand_b(b), .rc, .pc, .fist_bug(bug),
      .busy(old_busy), .done(old_done), .value(old_value),
      .flag_ie(old_ie), .flag_oe(old_oe), .flag_ue(old_ue), .flag_pe(old_pe),
      .rounded_up(old_up));
  ven_fp_misc new_dut(.clk, .rst_n, .start, .op,
      .operand_a(a), .operand_b(b), .rc, .pc, .fist_bug(bug),
      .busy(new_busy), .done(new_done), .value(new_value),
      .flag_ie(new_ie), .flag_oe(new_oe), .flag_ue(new_ue), .flag_pe(new_pe),
      .rounded_up(new_up));

  task automatic tick();
    @(posedge clk); #1; cycles++;
    if ({old_busy,old_done,old_value,old_ie,old_oe,old_ue,old_pe,old_up} !==
        {new_busy,new_done,new_value,new_ie,new_oe,new_ue,new_pe,new_up})
      $fatal(1,"MISC-SHARE mismatch clock=%0d case=%0d op=%0d a=%h b=%h old=%h new=%h",
          cycles,cases,op,a,b,old_value,new_value);
    if(old_done) completions++;
  endtask
  function automatic logic [63:0] random64();
    rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
    return rng;
  endfunction
  function automatic logic [79:0] operand(input int n);
    logic [15:0] sign_exp;
    logic [63:0] man;
    case (n % 16)
      0: sign_exp=16'h0000;
      1: sign_exp=16'h0001;
      2: sign_exp=16'h3ffd;
      3: sign_exp=16'h3ffe;
      4: sign_exp=16'h3fff;
      5: sign_exp=16'h4000;
      6: sign_exp=16'h400e;
      7: sign_exp=16'h400f;
      8: sign_exp=16'h401e;
      9: sign_exp=16'h401f;
      10: sign_exp=16'h403d;
      11: sign_exp=16'h403e;
      12: sign_exp=16'h403f;
      13: sign_exp=16'h7ffe;
      14: sign_exp=16'h7fff;
      default: sign_exp=16'(random64());
    endcase
    case ((n/16)%8)
      0: man=64'd0;
      1: man=64'h8000000000000000;
      2: man=64'hffffffffffffffff;
      3: man=64'h8000000000000001;
      4: man=64'hc000000000000000;
      5: man=64'h7fffffffffffffff;
      6: man=64'h0000000000000001;
      default: man=random64();
    endcase
    sign_exp[15]=1'(n/128);
    return {sign_exp,man};
  endfunction
  function automatic fxop_e operation(input int i);
    case(i)
      0: return FX_FIST_M16;
      1: return FX_FIST_M32;
      2: return FX_FIST_M64;
      3: return FX_FRNDINT;
      4: return FX_FSCALE;
      5: return FX_FST_M32;
      6: return FX_FST_M64;
      7: return FX_FST_M80;
      default: return FX_NONE;
    endcase
  endfunction
  task automatic issue(input fxop_e cmd, input logic[79:0] aa,bb,
      input logic[1:0] rounding,precision, input logic erratum);
    @(negedge clk);
    if(old_busy || old_done) $fatal(1,"not idle before command");
    start=1; op=cmd; a=aa; b=bb; rc=rounding; pc=precision; bug=erratum;
    tick();
    if(!old_busy || old_done) $fatal(1,"early capture response");
    @(negedge clk);
    // Captured owner must be immune to all input changes and busy requests.
    start=1; op=FX_NONE; a=~aa; b=~bb; rc=~rounding; pc=~precision; bug=~erratum;
    repeat(LATENCY) tick();
    if(!old_done || old_busy) $fatal(1,"wrong completion latency");
    @(negedge clk); start=0;
    tick();
    if(old_done || old_busy) $fatal(1,"busy input admitted or duplicate completion");
    cases++;
  endtask
  initial begin
    tick(); tick(); @(negedge clk); rst_n=1;
    for(int n=0;n<256;n++)
      for(int r=0;r<4;r++)
        for(int p=0;p<4;p++)
          for(int err=0;err<2;err++)
            for(int i=0;i<9;i++)
              issue(operation(i),operand(n),operand((n*73+41)%256),2'(r),2'(p),1'(err));
    // Held requests, changing controls, admit on every actual idle edge.
    begin
      int admitted, finished_before;
      admitted=0; finished_before=completions;
      for(int n=0;n<300;n++) begin
        @(negedge clk); start=1; op=operation(n%9);
        a=operand(n%256); b=operand((n+57)%256); rc=2'(n); pc=2'(n/4); bug=1'(n);
        if(!old_busy) admitted++;
        tick();
      end
      @(negedge clk); start=0;
      repeat(4) tick();
      if(completions-finished_before!=admitted) $fatal(1,"held start accounting");
    end
    for(int i=0;i<9;i++) for(int phase=0;phase<=LATENCY;phase++) begin
      @(negedge clk); start=1; op=operation(i); a=operand(68); b=operand(197);
      tick(); @(negedge clk); start=0;
      repeat(phase) tick();
      @(negedge clk); rst_n=0;
      tick();
      if(old_busy || old_done || old_value!=0 || {old_ie,old_oe,old_ue,old_pe,old_up}!=0)
        $fatal(1,"bad reset");
      @(negedge clk); rst_n=1;
      repeat(4) tick();
      if(old_busy || old_done) $fatal(1,"reset replay");
      aborts++;
    end
    if(cases!=73728) $fatal(1,"case coverage changed");
    $display("MISC-SHARED-INT-MITER-OK cases=%0d cycles=%0d completions=%0d aborts=%0d latency=%0d",
        cases,cycles,completions,aborts,LATENCY);
    $finish;
  end
endmodule
