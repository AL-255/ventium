// Compare complete SRT engines cycle-for-cycle, including reset and ignored
// starts. Numeric correctness still requires the original independent gates.
`default_nettype none
module tb_input_norm_miter;
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
  always #5 clk=~clk;

  always @(negedge clk) if(rst_n) begin
    if ({old_busy,old_done,old_up,old_q,old_c2,old_ie} !==
        {new_busy,new_done,new_up,new_q,new_c2,new_ie})
      $fatal(1,"SRT_INPUT_CONTROL_MISMATCH sample=%0d",samples);
    if (control.st !== candidate.st)
      $fatal(1,"SRT_INPUT_PHASE_MISMATCH sample=%0d",samples);
    if (old_done && old_result !== new_result)
      $fatal(1,"SRT_INPUT_RESULT_MISMATCH sample=%0d old=%h new=%h",samples,old_result,new_result);
    if (control.ua !== candidate.ua || control.ub !== candidate.ub ||
        control.dfx !== candidate.dfx || control.S !== candidate.S ||
        control.C !== candidate.C || control.twoR !== candidate.twoR)
      $fatal(1,"SRT_INPUT_STATE_MISMATCH sample=%0d",samples);
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
      if(clocks>300) $fatal(1,"SRT_INPUT_TIMEOUT sample=%0d mode=%0d",samples,mm);
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
    // Every leading-one position, exponent-zero and ordinary unnormal input,
    // in both divide operand positions and the square-root normalization arm.
    for(integer bitpos=0;bitpos<64;bitpos++)
      for(integer expcase=0;expcase<2;expcase++)
        for(integer m=0;m<3;m++) begin
          rc=2'(bitpos); pc=(bitpos%3==0)?0:(bitpos%3==1)?2:3;
          aa={1'b0,(expcase ? 15'h1234 : 15'd0),(64'd1<<bitpos)};
          bb={1'b0,(expcase ? 15'h4321 : 15'd0),(64'd1<<(63-bitpos))};
          run(aa,bb,2'(m));
        end
    for(integer m=0;m<3;m++) for(integer phase=0;phase<8;phase++) begin
      @(negedge clk);
      a=80'h40018000000000000000; b=80'h3fffC000000000000000;
      mode=2'(m); start=1;
      @(negedge clk); start=0;
      repeat(phase) @(negedge clk);
      rst_n=0;
      repeat(2) @(negedge clk);
      if(old_busy || new_busy || old_done || new_done) $fatal(1,"SRT_INPUT_RESET_FAILED");
      rst_n=1; resets++;
      @(negedge clk);
    end
    if(samples!=4544 || resets!=24 || checks<50000) $fatal(1,"SRT_INPUT_VACUOUS");
    for(integer m=0;m<3;m++) if(modes[m]<1300) $fatal(1,"SRT_INPUT_MODE_MISSING");
    $display("SRT-INPUT-NORM-MITER-OK samples=%0d checks=%0d resets=%0d div=%0d sqrt=%0d rem=%0d",
        samples,checks,resets,modes[0],modes[1],modes[2]);
    $finish;
  end
  initial begin
    #15000000;
    $fatal(1,"SRT_INPUT_GLOBAL_TIMEOUT");
  end
endmodule
`default_nettype wire

