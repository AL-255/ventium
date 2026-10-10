// Independent legal-BCD oracle; the old conversion shared the negative-zero bug.
`default_nettype none
module tb_bcd_sign;
  import fpu_x87_pkg::*;
  logic clk=0, rst_n=0, start=0;
  logic [79:0] bcd=0;
  logic busy,done,old_busy,old_done;
  logic [79:0] result,old_result;
  ven_bcd_to_fp dut(.clk,.rst_n,.start,.bcd,.busy,.done,.result);
  ven_bcd_to_fp_control control(.clk,.rst_n,.start,.bcd,
    .busy(old_busy),.done(old_done),.result(old_result));
  always #5 clk=~clk;
  always @(negedge clk) if(rst_n) begin
    if(busy!==old_busy || done!==old_done) $fatal(1,"BCD handshake changed");
  end

  function automatic logic [79:0] expected(input logic [79:0] packed_value);
    logic [63:0] magnitude,place;
    int leading;
    logic [14:0] exponent;
    magnitude=0;place=1;leading=0;
    // Positional decimal sum, independent of DUT's paired Horner recurrence.
    for(int i=0;i<18;i++) begin
      magnitude += 64'(packed_value[4*i+:4])*place;
      place *= 10;
    end
    if(magnitude==0) return {packed_value[79],79'd0};
    for(int i=0;i<64;i++) if(magnitude[i]) leading=i;
    exponent=15'(16383+leading);
    return {packed_value[79],exponent,(magnitude<<(63-leading))};
  endfunction

  int checks=0,known_control_failures=0,resets=0;
  task automatic run_one(input logic [79:0] number);
    logic [79:0] want;
    int age;
    want=expected(number);
    @(negedge clk);start=1;bcd=number;
    @(negedge clk);start=0;age=0;
    while(!done) begin
      // A start/operand change while busy must not change the retained owner.
      start=(age==2);bcd=~number;
      @(negedge clk);age++;
      if(age>12) $fatal(1,"BCD completion timeout");
    end
    start=0;
    if(result!==want || fx_bcd_to_fx(number)!==want)
      $fatal(1,"BCD b=%h actual=%h want=%h",number,result,want);
    if(old_result!==want) begin
      if(number!==80'h80000000000000000000) $fatal(1,"unexpected old result difference");
      if(old_result!==80'd0) $fatal(1,"old negative-zero discriminator drift");
      known_control_failures++;
    end
    checks++;
  endtask

  initial begin
    logic [79:0] number;
    repeat(3) @(negedge clk);rst_n=1;
    run_one(80'd0);run_one(80'h80000000000000000000);
    run_one(80'h00999999999999999999);run_one(80'h80999999999999999999);
    for(int k=0;k<40000;k++) begin
      number=0;
      for(int d=0;d<18;d++) number[4*d+:4]=4'($urandom_range(0,9));
      number[79]=1'($urandom());
      run_one(number);
    end
    for(int position=0;position<11;position++) begin
      @(negedge clk);start=1;bcd=80'h80999999999999999999;
      @(negedge clk);start=0;
      repeat(position) @(negedge clk);
      rst_n=0;@(negedge clk);rst_n=1;@(negedge clk);
      if(done||busy||old_done||old_busy) $fatal(1,"BCD reset left an owner");
      resets++;
      run_one(80'h80000000000000000000);
    end
    if(checks!=40015 || known_control_failures!=12 || resets!=11)
      $fatal(1,"BCD coverage counters changed");
    $display("BCD-SIGN-OK checks=%0d negative-zero-control-failures=%0d reset-positions=%0d",
      checks,known_control_failures,resets);
    $finish;
  end
  initial begin #10000000; $fatal(1,"BCD watchdog"); end
endmodule
`default_nettype wire
