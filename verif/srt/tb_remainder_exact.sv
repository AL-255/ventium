`default_nettype none
module tb_remainder_exact;
  logic clk=0, rst_n=0, start=0, prem1=0;
  logic [79:0] a=0, b=0;
  logic [1:0] rc=0, pc=3;
  wire busy, done, rounded_up, rem_c2, rem_ie;
  wire [82:0] result;
  wire [2:0] rem_q012;
  fpu_srt_div dut(.clk,.rst_n,.start,.mode(2'd2),.prem1,.a,.b,
`ifdef VEN_SRT_REM_OPERAND_SPLIT
      .rem_a(a),.rem_b(b),
`endif
      .rc,.pc,.buggy(1'b0),.busy,.done,.result,.rounded_up,.rem_q012,.rem_c2,.rem_ie);
  task automatic tick;
    #1; clk=1; #1; clk=0;
  endtask
  string input_path, output_path;
  integer inputs, outputs, ident, kind, precision, rounding, scanned, count=0, records=0;
  logic [79:0] operand_a, operand_b;
  initial begin
    if (!$value$plusargs("input=%s",input_path) || !$value$plusargs("output=%s",output_path))
      $fatal(1,"missing vector paths");
    inputs=$fopen(input_path,"r"); outputs=$fopen(output_path,"w");
    if (!inputs || !outputs) $fatal(1,"cannot open vectors");
    tick(); tick(); rst_n=1; tick();
    while (!$feof(inputs)) begin
      scanned=$fscanf(inputs,"%d %d %d %d %h %h\n",ident,kind,precision,rounding,operand_a,operand_b);
      if (scanned!=6) $fatal(1,"malformed input %0d",scanned);
      if (ident!=count) $fatal(1,"case order");
      count=count+1;
      a=operand_a; b=operand_b; prem1=1'(kind); pc=2'(precision); rc=2'(rounding);
      for (integer step=0;step<1026;step++) begin
        integer cycles;
        if (busy || done) $fatal(1,"unclean start");
        start=1; tick(); start=0; cycles=0;
        while (!done && cycles<256) begin tick(); cycles=cycles+1; end
        if (!done || busy || cycles>=256) $fatal(1,"bounded completion case %0d",ident);
        $fdisplay(outputs,"%0d %0d %020h %01h %01h %01h %01h %01h %0d",
            ident,step,result[79:0],rem_q012,rem_c2,rem_ie,result[82:80],rounded_up,cycles);
        records=records+1;
        operand_a=result[79:0];
        if (!rem_c2) begin tick(); break; end
        if (step==1025) $fatal(1,"partial loop did not terminate");
        tick(); a=operand_a;
      end
    end
    $fclose(inputs); $fclose(outputs);
    $display("REMAINDER-EXACT-DONE cases=%0d records=%0d",count,records);
    $finish;
  end
endmodule
`default_nettype wire
