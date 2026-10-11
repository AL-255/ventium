// Compare complete SRT engines cycle-for-cycle, including reset and ignored
// starts. Numeric correctness still requires the original independent gates.
`default_nettype none
module tb_qacc_init_miter;
  logic clk=0, rst_n=0, start=0, prem1=0, buggy=0;
  logic [1:0] mode=0, rc=0, pc=3;
  logic [79:0] a=0, b=0;
  logic old_busy, old_done, new_busy, new_done;
  logic [82:0] old_result, new_result;
  logic old_up, new_up, old_c2, new_c2, old_ie, new_ie;
  logic [2:0] old_q, new_q;
  integer samples=0, checks=0, resets=0, modes[3], seed, unused_seed;
  fpu_srt_div_control control(.clk,.rst_n,.start,.mode,.prem1,.a,.b,.rc,.pc,.buggy,
      .busy(old_busy),.done(old_done),.result(old_result),.rounded_up(old_up),
      .rem_q012(old_q),.rem_c2(old_c2),.rem_ie(old_ie));
  fpu_srt_div candidate(.clk,.rst_n,.start,.mode,.prem1,.a,.b,.rc,.pc,.buggy,
      .busy(new_busy),.done(new_done),.result(new_result),.rounded_up(new_up),
      .rem_q012(new_q),.rem_c2(new_c2),.rem_ie(new_ie));
  integer live_qacc_checks=0, dead_qacc_changes=0;
  function automatic logic [79:0] edge_operand(input integer index);
    case(index)
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
  always #5 clk=~clk;

  always @(negedge clk) if(rst_n) begin
    if ({old_busy,old_done,old_up,old_q,old_c2,old_ie} !==
        {new_busy,new_done,new_up,new_q,new_c2,new_ie})
      $fatal(1,"SRT_QACC_CONTROL_MISMATCH sample=%0d",samples);
    if (control.st !== candidate.st)
      $fatal(1,"SRT_QACC_PHASE_MISMATCH sample=%0d",samples);
    if (old_done && old_result !== new_result)
      $fatal(1,"SRT_QACC_RESULT_MISMATCH sample=%0d old=%h new=%h",samples,old_result,new_result);
    // qacc can differ only outside consumers: accepted sqrt/special starts.
    // The next divide/remainder must initialize before exposing it again.
    if (control.st == control.ST_DRUN || control.st == control.ST_DFIN ||
        control.st == control.ST_RRUN || control.st == control.ST_RFIN ||
        control.st == control.ST_RNORM) begin
      if (control.qacc !== candidate.qacc)
        $fatal(1,"SRT_QACC_LIVE_MISMATCH sample=%0d",samples);
      live_qacc_checks++;
    end else if (control.qacc !== candidate.qacc) dead_qacc_changes++;
    checks++;
  end

  task automatic run(input logic [79:0] aa,bb,input logic [1:0] mm);
    integer clocks;
    @(negedge clk); a=aa; b=bb; mode=mm; start=1;
    @(negedge clk); start=0; clocks=0;
    while(!old_done) begin
      // Request operands may change after acceptance. Keep live rc/pc/buggy
      // controls stable, matching the existing engine's parent contract.
      if(old_busy) begin
        a={16'($urandom),$urandom,$urandom};
        b={16'($urandom),$urandom,$urandom};
        mode=2'($urandom); start=(clocks%7)==3;
      end
      @(negedge clk);
      clocks++;
      if(clocks>300) $fatal(1,"SRT_QACC_TIMEOUT sample=%0d mode=%0d",samples,mm);
    end
    start=0;
    samples++; modes[mm]++;
    @(negedge clk);
  endtask

  initial begin : stimulus
    logic [79:0] aa,bb;
    logic [63:0] ma,mb;
    logic [14:0] ea,eb;
    seed=32'h20011011; unused_seed=$urandom(seed);
    for(integer m=0;m<3;m++) modes[m]=0;
    repeat(4) @(negedge clk);
    rst_n=1;
    for(integer n=0;n<4096;n++) begin
      ma={$urandom,$urandom}; mb={$urandom,$urandom};
      ma[63]=1; mb[63]=1;
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
      rc=2'(n%4); pc=(n%3==0)?2'd0:(n%3==1)?2'd2:2'd3;
      buggy=1'(n/4); prem1=1'(n/8);
      run(aa,bb,2'(n%3));
    end
    for(integer i=0;i<64;i++) begin
      prem1=1'(i); rc=0; pc=3; buggy=0;
      run({16'd0,64'h8000000000000000},{16'd0,(64'd1<<i)},2'd2);
    end
    // Every special/denormal pair and both FPREM controls, interleaved across
    // operation kinds: expose stale quotient reuse after special and sqrt.
    for(integer i=0;i<12;i++) for(integer j=0;j<12;j++)
      for(integer m=0;m<3;m++) for(integer p=0;p<2;p++) begin
        prem1=1'(p); rc=2'(i+j); pc=3; buggy=1'(i);
        run(edge_operand(i),edge_operand(j),2'(m));
      end
    for(integer m=0;m<3;m++) for(integer phase=0;phase<8;phase++) begin
      @(negedge clk);
      a=80'h40018000000000000000; b=80'h3fffC000000000000000;
      mode=2'(m); start=1;
      @(negedge clk); start=0;
      repeat(phase) @(negedge clk);
      rst_n=0;
      repeat(2) @(negedge clk);
      if(old_busy || new_busy || old_done || new_done) $fatal(1,"SRT_QACC_RESET_FAILED");
      rst_n=1; resets++;
      @(negedge clk);
    end
    if(samples!=5024 || resets!=24 || checks<50000) $fatal(1,"SRT_QACC_VACUOUS");
    for(integer m=0;m<3;m++) if(modes[m]<1300) $fatal(1,"SRT_QACC_MODE_MISSING");
    if(live_qacc_checks<20000 || dead_qacc_changes==0)
      $fatal(1,"SRT_QACC_PAYLOAD_VACUOUS");
    $display("SRT-QACC-PAYLOAD live_checks=%0d dead_changes=%0d",live_qacc_checks,dead_qacc_changes);
    $display("SRT-QACC-MITER-OK samples=%0d checks=%0d resets=%0d div=%0d sqrt=%0d rem=%0d",
        samples,checks,resets,modes[0],modes[1],modes[2]);
    $finish;
  end
  initial begin
    #15000000;
    $fatal(1,"SRT_QACC_GLOBAL_TIMEOUT");
  end
endmodule
`default_nettype wire
