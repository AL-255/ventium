// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ===========================================================================
// verif/idiv/tb_idiv.sv — standalone clocked gate for the iterative integer
// divider (rtl/core/ven_idiv.sv). Asserts the engine's quotient/remainder/#DE
// are bit-exact vs the native combinational '/'/'%' + per-width overflow
// predicates that core_exec.svh uses (the golden is computed here the SAME way),
// for all six forms (DIV/IDIV x r8/r16/r32) over directed edges + random.
// Built with the --timing flag.
// ===========================================================================
`default_nettype none

module tb_idiv;
`ifndef IDIV_N
  `define IDIV_N 60000
`endif
  localparam int N = `IDIV_N;

  logic        clk=1'b0, rst_n=1'b0, start=1'b0, is_signed=1'b0;
  logic [2:0]  w=3'd4;
  logic [63:0] dividend='0;
  logic [31:0] divisor='0;
  logic        busy, done;
  logic [31:0] quotient, remainder;
  logic        derr;

  ven_idiv dut (.clk,.rst_n,.start,.is_signed,.w,.dividend,.divisor,.busy,.done,.quotient,.remainder,.derr);

  initial forever #5 clk = ~clk;

  // ---- native golden (mirrors core_exec.svh 256-355) -----------------------
  // returns derr; on !derr returns gq/gr (low wbits relevant) for comparison.
  task automatic golden(input logic sg, input logic [2:0] ww,
                        input logic [63:0] dvd, input logic [31:0] dvr,
                        output logic gderr, output logic [31:0] gq, output logic [31:0] gr);
    gderr=1'b0; gq=32'd0; gr=32'd0;
    if (!sg) begin // DIV (unsigned)
      if (ww==3'd1) begin logic [15:0] num,qq,rr; num=dvd[15:0];
        if (dvr[7:0]==0) gderr=1; else begin qq=num/{8'd0,dvr[7:0]}; rr=num%{8'd0,dvr[7:0]};
          if (qq[15:8]!=0) gderr=1; else begin gq={24'd0,qq[7:0]}; gr={24'd0,rr[7:0]}; end end
      end else if (ww==3'd2) begin logic [31:0] num,qq,rr; num={dvd[31:16],dvd[15:0]};
        if (dvr[15:0]==0) gderr=1; else begin qq=num/{16'd0,dvr[15:0]}; rr=num%{16'd0,dvr[15:0]};
          if (qq[31:16]!=0) gderr=1; else begin gq={16'd0,qq[15:0]}; gr={16'd0,rr[15:0]}; end end
      end else begin logic [63:0] num,qq,rr; num=dvd;
        if (dvr==0) gderr=1; else begin qq=num/{32'd0,dvr}; rr=num%{32'd0,dvr};
          if (qq[63:32]!=0) gderr=1; else begin gq=qq[31:0]; gr=rr[31:0]; end end
      end
    end else begin // IDIV (signed)
      if (ww==3'd1) begin logic signed [15:0] num,den,qq,rr; num=$signed(dvd[15:0]); den=$signed({{8{dvr[7]}},dvr[7:0]});
        if (dvr[7:0]==0) gderr=1; else begin qq=num/den; rr=num%den;
          if (qq != $signed({{8{qq[7]}},qq[7:0]})) gderr=1; else begin gq={{24{qq[7]}},qq[7:0]}; gr={{24{rr[7]}},rr[7:0]}; end end
      end else if (ww==3'd2) begin logic signed [31:0] num,den,qq,rr; num=$signed({dvd[31:16],dvd[15:0]}); den=$signed({{16{dvr[15]}},dvr[15:0]});
        if (dvr[15:0]==0) gderr=1; else begin qq=num/den; rr=num%den;
          if (qq != $signed({{16{qq[15]}},qq[15:0]})) gderr=1; else begin gq={{16{qq[15]}},qq[15:0]}; gr={{16{rr[15]}},rr[15:0]}; end end
      end else begin logic signed [63:0] num,den,qq,rr; num=$signed(dvd); den=$signed({{32{dvr[31]}},dvr});
        if (dvr==0) gderr=1; else begin qq=num/den; rr=num%den;
          if (qq != $signed({{32{qq[31]}},qq[31:0]})) gderr=1; else begin gq=qq[31:0]; gr=rr[31:0]; end end
      end
    end
  endtask

  function automatic int unsigned wbits_of(input logic [2:0] ww);
    wbits_of = (ww==3'd1) ? 8 : (ww==3'd2) ? 16 : 32;
  endfunction

  int fail;
  task automatic run_one(input logic sg, input logic [2:0] ww, input logic [63:0] dvd, input logic [31:0] dvr);
    logic gderr; logic [31:0] gq, gr; int wb;
    golden(sg, ww, dvd, dvr, gderr, gq, gr);
    @(negedge clk); is_signed=sg; w=ww; dividend=dvd; divisor=dvr; start=1'b1;
    @(negedge clk); start=1'b0;
    while (!done) @(negedge clk);
    wb = wbits_of(ww);
    if (derr !== gderr) begin
      fail++; if (fail<=10) $display("FAIL derr: sg=%0d w=%0d dvd=%016h dvr=%08h got_derr=%b exp=%b", sg,ww,dvd,dvr,derr,gderr);
    end else if (!gderr) begin
      // compare low wbits of quotient + remainder
      if ((quotient & ((32'd1<<wb)-1)) !== (gq & ((32'd1<<wb)-1)) ||
          (remainder & ((32'd1<<wb)-1)) !== (gr & ((32'd1<<wb)-1))) begin
        fail++; if (fail<=10) $display("FAIL qr: sg=%0d w=%0d dvd=%016h dvr=%08h q=%08h/%08h r=%08h/%08h", sg,ww,dvd,dvr,quotient,gq,remainder,gr);
      end
    end
  endtask

  logic [63:0] rdvd; logic [31:0] rdvr; logic [2:0] rw; logic rsg;
  initial begin
    rst_n=1'b0; repeat(4) @(negedge clk); rst_n=1'b1; @(negedge clk);
    fail=0;
    // directed edges for each form
    for (int sgi=0;sgi<2;sgi++) for (int wi=0;wi<3;wi++) begin
      automatic logic sg = sgi[0]; automatic logic [2:0] ww = (wi==0)?3'd1:(wi==1)?3'd2:3'd4;
      run_one(sg, ww, 64'd0,          32'd0);      // 0/0 -> #DE
      run_one(sg, ww, 64'h1234,       32'd0);      // x/0 -> #DE
      run_one(sg, ww, 64'd0,          32'd1);      // 0/1
      run_one(sg, ww, 64'hFFFFFFFFFFFFFFFF, 32'd1);// max/1 -> overflow
      run_one(sg, ww, 64'hFFFFFFFFFFFFFFFF, 32'hFFFFFFFF); // -1/-1 etc
      run_one(sg, ww, 64'h0000000000007FFF, 32'd1);        // overflow /1 (well-defined; not the INT_MIN/-1 C++ UB corner)
      run_one(sg, ww, 64'h00000000_0000007F, 32'd2);
      run_one(sg, ww, 64'hDEADBEEF_CAFEBABE, 32'd3);
    end
    // random corpus
    for (int i=0;i<N;i++) begin
      rdvd = {$urandom(),$urandom()};
      rdvr = $urandom();
      rw   = (($urandom()%3)==0)?3'd1:(($urandom()%2)==0)?3'd2:3'd4;
      rsg  = $urandom() & 1;
      // bias divisor small sometimes to hit valid (non-overflow) results
      if (($urandom()%2)==0) rdvr = rdvr & 32'h0000FFFF;
      run_one(rsg, rw, rdvd, rdvr);
    end
    if (fail==0) $display("IDIV-GATE-OK  (%0d random + directed, all 6 forms bit-exact vs native)", N);
    else         $display("IDIV-GATE-FAIL  (%0d mismatches)", fail);
    $finish;
  end

  initial begin #200000000 $display("IDIV-GATE-FAIL (timeout)"); $finish; end
endmodule

`default_nettype wire
