// Full sequential A/B engines, not an independent numerical oracle.
// Stimulus changes only at falling edges; observations follow rising-edge NBAs.
`timescale 1ns/1ps
`default_nettype none
module tb_div_exp_miter;
  logic clk=0, rst_n=0, start=0, prem1=0, buggy=0;
  logic [1:0] mode=0, rc=0, pc=3;
  logic [79:0] a=0, b=0, rem_a=0, rem_b=0;
  logic old_busy, old_done, new_busy, new_done;
  logic [82:0] old_result, new_result;
  logic old_up, new_up, old_c2, new_c2, old_ie, new_ie;
  logic [2:0] old_q, new_q;
  integer samples=0, checks=0, resets=0, ignored_starts=0;
  integer modes[3], phases[9], rc_hits[4], pc_hits[4], buggy_hits[2];
  integer exp_min=0, exp_max=0, seed, unused_seed;
  fpu_srt_div_control control(.clk,.rst_n,.start,.mode,.prem1,.a,.b,.rc,.pc,.buggy,
`ifdef VEN_SRT_REM_OPERAND_SPLIT
      .rem_a,.rem_b,
`endif
      .busy(old_busy),.done(old_done),.result(old_result),.rounded_up(old_up),
      .rem_q012(old_q),.rem_c2(old_c2),.rem_ie(old_ie));
  fpu_srt_div candidate(.clk,.rst_n,.start,.mode,.prem1,.a,.b,.rc,.pc,.buggy,
`ifdef VEN_SRT_REM_OPERAND_SPLIT
      .rem_a,.rem_b,
`endif
      .busy(new_busy),.done(new_done),.result(new_result),.rounded_up(new_up),
      .rem_q012(new_q),.rem_c2(new_c2),.rem_ie(new_ie));
  always #5 clk=~clk;

  always @(posedge clk) begin
    #1;
    if(rst_n) begin
      if ({old_busy,old_done,old_up,old_q,old_c2,old_ie} !==
          {new_busy,new_done,new_up,new_q,new_c2,new_ie})
        $fatal(1,"DIV_EXP_CONTROL_MISMATCH sample=%0d",samples);
      if (control.st !== candidate.st)
        $fatal(1,"DIV_EXP_PHASE_MISMATCH sample=%0d",samples);
      if (old_done && old_result !== new_result)
        $fatal(1,"DIV_EXP_RESULT_MISMATCH sample=%0d old=%h new=%h",samples,old_result,new_result);
      // No inactive-state differences are permitted by this transformation.
      // Verilator supplies two-state initial values; X/Z arithmetic is tested
      // separately by the source-derived Icarus helper gate.
      if ({control.mode_q,control.sign,control.ua,control.ub,control.d4,control.dfx,
           control.S,control.C,control.qacc,control.k,control.twoR,control.corrpos,
           control.round_uq_q,control.round_sh_q,control.dvd,control.rmb,control.rsa,
           control.reb,control.rnsteps,control.rc2,control.rprem1} !==
          {candidate.mode_q,candidate.sign,candidate.ua,candidate.ub,candidate.d4,candidate.dfx,
           candidate.S,candidate.C,candidate.qacc,candidate.k,candidate.twoR,candidate.corrpos,
           candidate.round_uq_q,candidate.round_sh_q,candidate.dvd,candidate.rmb,candidate.rsa,
           candidate.reb,candidate.rnsteps,candidate.rc2,candidate.rprem1})
        $fatal(1,"DIV_EXP_STATE_MISMATCH sample=%0d old_exp=%0d/%0d new_exp=%0d/%0d",
            samples,control.ua,control.ub,candidate.ua,candidate.ub);
      if (control.st == control.ST_DRUN && control.k == 0) begin
        if(control.ua < exp_min) exp_min=control.ua;
        if(control.ub < exp_min) exp_min=control.ub;
        if(control.ua > exp_max) exp_max=control.ua;
        if(control.ub > exp_max) exp_max=control.ub;
      end
      phases[int'(control.st)]++;
      checks++;
    end else if(old_busy || new_busy || old_done || new_done)
      $fatal(1,"DIV_EXP_RESET_MISMATCH");
  end

  task automatic drive(input logic [79:0] aa,bb,input logic [1:0] mm);
    a=aa; b=bb; rem_a=aa; rem_b=bb; mode=mm;
`ifdef VEN_SRT_REM_OPERAND_SPLIT
    // Prove remainder uses its own accepted port, not a/b's incidental value.
    if(mm==2) begin a=~aa; b=~bb; end
`endif
  endtask

  task automatic run(input logic [79:0] aa,bb,input logic [1:0] mm);
    integer clocks;
    @(negedge clk); drive(aa,bb,mm); start=1;
    @(negedge clk); start=0; clocks=0;
    while(!old_done) begin
      if(old_busy) begin
        // Live rounding/erratum controls remain stable as required by parent.
        a={16'($urandom),$urandom,$urandom}; b=~a;
        rem_a={16'($urandom),$urandom,$urandom}; rem_b=~rem_a;
        mode=2'($urandom); start=(clocks%7)==3;
        if(start) ignored_starts++;
      end
      @(negedge clk);
      clocks++;
      if(clocks>300) $fatal(1,"DIV_EXP_TIMEOUT sample=%0d mode=%0d",samples,mm);
    end
    start=0; samples++; modes[mm]++; rc_hits[rc]++; pc_hits[pc]++; buggy_hits[buggy]++;
  endtask

  function automatic logic [14:0] edge_exp(input integer i);
    case(i)
      0: return 15'd0;
      1: return 15'd1;
      2: return 15'd16382;
      3: return 15'd16383;
      4: return 15'd16384;
      default: return 15'd32767;
    endcase
  endfunction
  function automatic logic [79:0] edge_operand(input integer i);
    case(i)
      0: return 80'h00000000000000000000;
      1: return 80'h80000000000000000000;
      2: return 80'h3fff8000000000000000;
      3: return 80'hc0019000000000000000;
      4: return 80'h7fff8000000000000000;
      5: return 80'hffff8000000000000000;
      6: return 80'h7fffc000000000001234;
      7: return 80'h7fff8000000000001234;
      8: return 80'h00000000000000000001;
      9: return 80'h00008000000000000000;
      10:return 80'h00007fffffffffffffff;
      default:return 80'h12340000000000000000;
    endcase
  endfunction

  initial begin : stimulus
    logic [79:0] aa,bb;
    logic [63:0] ma,mb;
    logic [14:0] ea,eb;
    seed=32'h12102026; unused_seed=$urandom(seed);
    foreach(modes[i]) modes[i]=0;
    foreach(phases[i]) phases[i]=0;
    foreach(rc_hits[i]) rc_hits[i]=0;
    foreach(pc_hits[i]) pc_hits[i]=0;
    foreach(buggy_hits[i]) buggy_hits[i]=0;
    repeat(4) @(negedge clk);
    rst_n=1;
    // Direct witness for all three bad exponent implementations, before fuzz.
    run(80'h00000000000000000001,80'h3fff8000000000000000,0);
    for(integer n=0;n<4096;n++) begin
      ma={$urandom,$urandom}; mb={$urandom,$urandom}; ma[63]=1; mb[63]=1;
      ea=15'(1+(n*127)%32766); eb=15'(1+(n*131)%32766);
      case((n/3)%8)
        0: begin ea=0; ma=ma >> (n%64); end
        1: begin eb=0; mb=mb >> ((n/8)%64); end
        2: begin ea=0; eb=0; ma=ma>>(n%64); mb=mb>>((n/8)%64); end
        3: begin ea=15'h3fff; eb=15'h3fff; end
        4: begin ea=1; eb=15'h7ffe; end
        5: begin ea=15'h7ffe; eb=1; end
        default: begin end
      endcase
      aa={(n%3==1 ? 1'b0 : 1'(n)),ea,ma}; bb={1'(n/2),eb,mb};
      rc=2'(n%4); pc=2'(n/4); buggy=1'(n/16); prem1=1'(n/8);
      run(aa,bb,2'(n%3));
    end
    // All 64 leading-one positions, both input roles, all rounding/precision
    // controls and both erratum modes at six exponent boundaries.
    for(integer ecase=0;ecase<6;ecase++) for(integer bitpos=0;bitpos<64;bitpos++)
      for(integer role=0;role<2;role++) for(integer r=0;r<4;r++)
        for(integer p=0;p<4;p++) for(integer bug=0;bug<2;bug++) begin
          rc=2'(r); pc=2'(p); buggy=1'(bug);
          aa={1'(r),edge_exp(ecase),(64'd1<<bitpos)};
          bb={1'(p),15'h3fff,64'hc000000000000000};
          if(role) run(bb,aa,0); else run(aa,bb,0);
        end
    // Include specials and transitions between all three shared operations.
    for(integer i=0;i<12;i++) for(integer j=0;j<12;j++)
      for(integer m=0;m<3;m++) for(integer p=0;p<2;p++) begin
        prem1=1'(p); rc=2'(i+j); pc=3; buggy=1'(i);
        run(edge_operand(i),edge_operand(j),2'(m));
      end
    // Reset during setup/iteration/finalization and after a completed result.
    for(integer m=0;m<3;m++) for(integer delay_cycles=0;delay_cycles<42;delay_cycles++) begin
      @(negedge clk);
      drive(80'h40018000000000000000,80'h3fffc000000000000000,2'(m)); start=1;
      @(negedge clk); start=0;
      repeat(delay_cycles) @(negedge clk);
      rst_n=0;
      repeat(2) @(negedge clk);
      rst_n=1; resets++;
    end
    @(negedge clk);
    if(samples!=29537 || resets!=126 || checks<100000 || ignored_starts<1000)
      $fatal(1,"DIV_EXP_VACUOUS samples=%0d checks=%0d",samples,checks);
    if(exp_min!=-16445 || exp_max!=16384)
      $fatal(1,"DIV_EXP_RANGE_MISSING min=%0d max=%0d",exp_min,exp_max);
    foreach(phases[i]) if(phases[i]==0) $fatal(1,"DIV_EXP_PHASE_MISSING phase=%0d",i);
    foreach(modes[i]) if(modes[i]<1000) $fatal(1,"DIV_EXP_MODE_MISSING mode=%0d",i);
    foreach(rc_hits[i]) if(rc_hits[i]<1000) $fatal(1,"DIV_EXP_RC_MISSING rc=%0d",i);
    foreach(pc_hits[i]) if(pc_hits[i]<1000) $fatal(1,"DIV_EXP_PC_MISSING pc=%0d",i);
    foreach(buggy_hits[i]) if(buggy_hits[i]<1000) $fatal(1,"DIV_EXP_ERRATUM_MISSING buggy=%0d",i);
    $display("DIV-EXP-MITER-OK samples=%0d checks=%0d resets=%0d ignored_starts=%0d min=%0d max=%0d",
        samples,checks,resets,ignored_starts,exp_min,exp_max);
    $finish;
  end
  initial begin
    #100000000;
    $fatal(1,"DIV_EXP_GLOBAL_TIMEOUT");
  end
endmodule
`default_nettype wire
