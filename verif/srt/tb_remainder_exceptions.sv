`timescale 1ns/1ps
`default_nettype none
module tb_remainder_exceptions;
  import ventium_decode_pkg::*;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  logic valid=0, ready, accept_retire, alu_retire, busy, rsp, unsupported, stack_fault;
  fxop_e op=FX_NONE;
  logic [863:0] env_image=0, store_data;
  logic [79:0] mem=0;
  logic [31:0] ip, dp;
  logic [15:0] cs, ds, sw, cw, ax;
  logic [2:0] top, sti=0;
  logic [7:0] tag, store_bytes;
  logic [639:0] phys, st;
  logic [84:0] arith;
  logic store_valid, ax_valid;
  int latency;
  ven_fp_top dut (
    .clk(clk), .rst_n(rst_n), .cmd_valid(valid), .cmd_ready(ready),
    .cmd_accept_retire(accept_retire), .alu_commit_retire(alu_retire),
    .cmd_op(op), .cmd_aluop(3'd0), .cmd_sti(sti), .cmd_pop(1'b0),
    .cmd_constant(3'd0), .cmd_mem(mem), .cmd_mem_bytes(4'd10),
    .cmd_fdiv_bug(1'b0), .cmd_fist_bug(1'b0), .cmd_env16(1'b0),
    .cmd_real_mode(1'b0), .cmd_env_image(env_image),
    .cmd_update_fip(1'b0), .cmd_fip(32'd0), .cmd_fcs(16'd0),
    .cmd_update_fdp(1'b0), .cmd_fdp(32'd0), .cmd_fds(16'd0),
    .busy(busy), .rsp_valid(rsp), .rsp_unsupported(unsupported),
    .rsp_stack_fault(stack_fault), .rsp_arith(arith),
    .rsp_store_valid(store_valid), .rsp_store_data(store_data),
    .rsp_store_bytes(store_bytes), .rsp_ax_valid(ax_valid), .rsp_ax(ax),
    .ftop_o(top), .fstat_o(sw), .fctrl_o(cw), .fptag_o(tag),
    .fpr_phys_flat_o(phys), .st_flat_o(st),
    .fip_o(ip), .fcs_o(cs), .fdp_o(dp), .fds_o(ds)
  );
  task automatic command(input fxop_e next_op);
    int waited;
    waited=0;
    while (!ready && waited<100) begin @(negedge clk); waited++; end
    if (!ready) $fatal(1,"REM-READY-TIMEOUT");
    @(negedge clk); op=next_op; valid=1; sti=1;
    @(negedge clk); valid=0; op=FX_FNINIT; mem=~mem; sti=7;
    // A following, unaccepted bus value may not select the pending ST(1).
    env_image=~env_image;
    latency=0;
    while (!rsp && latency<200) begin
      @(negedge clk); latency++; sti=sti+3'd1;
    end
    if (!rsp || unsupported) $fatal(1,"REM-RESPONSE-TIMEOUT op=%0d",next_op);
  endtask
  task automatic seed(input logic [15:0] icw,isw,itag,
                      input logic [79:0] a,b);
    command(FX_FNINIT);
    env_image=0;
    env_image[0 +: 16]=icw; env_image[32 +: 16]=isw;
    env_image[64 +: 16]=itag;
    for (int i=0;i<8;i++) begin
      env_image[224+i*80 +: 80]={(i==0 ? 16'h3fff : (16'h4000+16'((255+i)&255))),
                                64'h8000000000000000};
    end
    env_image[224 +: 80]=a; env_image[304 +: 80]=b;
    command(FX_FRSTOR);
    if (cw!==icw || st[159:0]!=={b,a} || top!==isw[13:11]) $fatal(1,"REM-SEED");
  endtask
  initial begin
    string path;
    int fd, fields, kind, count, rem_latency, fault;
    logic [15:0] in_cw,in_sw,in_tag;
    logic [79:0] a,b;
    logic [639:0] completed;
    if (!$value$plusargs("vectors=%s",path)) $fatal(1,"REM-NO-VECTORS");
    fd=$fopen(path,"r"); if (!fd) $fatal(1,"REM-VECTORS-OPEN");
    repeat (3) @(negedge clk); rst_n=1; count=0;
    while (!$feof(fd)) begin
      fields=$fscanf(fd,"%h %h %h %h %h %d\n",in_cw,in_sw,in_tag,a,b,kind);
      if (fields!=6) $fatal(1,"REM-VECTOR-PARSE");
      seed(in_cw,in_sw,in_tag,a,b);
      command(kind==0 ? FX_FPREM : FX_FPREM1);
      rem_latency=latency; fault=int'(stack_fault); completed=st;
      if (st[159:80]!==b || cw!==in_cw || top!==in_sw[13:11] || {ip,dp,cs,ds}!==96'd0)
        $fatal(1,"REM-OWNER-CORRUPTION row=%0d",count);
      @(negedge clk);
      repeat (2) begin
        if (rsp || st!==completed || cw!==in_cw) $fatal(1,"REM-DUPLICATE-RESPONSE row=%0d",count);
        @(negedge clk);
      end
      command(FX_FNSAVE);
      if (!store_valid || store_bytes!==108 || store_data[224 +: 640]!==completed)
        $fatal(1,"REM-SAVE row=%0d",count);
      $display("ROW %0d %0216h %0d %0d",count,store_data,rem_latency,fault);
      count++;
    end
    $fclose(fd);
    // Reset while a special, normal recurrence, and tiny-divisor recurrence
    // are pending. No response from the cancelled owner may escape reset.
    for (int phase=0;phase<3;phase++) begin
      if (phase==0)
        seed(16'h037e,0,0,80'h7fffa123456789abcdef,80'h3fff923456789abcdef1);
      else if (phase==1)
        seed(16'h037d,0,0,80'h405fc123456789abcdef,80'h3fff923456789abcdef1);
      else
        seed(16'h037d,0,0,80'h3fff8000000000000000,80'h00000000000000000003);
      @(negedge clk); op=FX_FPREM1; valid=1;
      @(negedge clk); valid=0;
      repeat (phase*4) @(negedge clk);
      rst_n=0; @(negedge clk); rst_n=1;
      repeat (80) begin
        @(negedge clk);
        if (rsp || busy || !ready || sw!==0 || cw!==16'h037f || tag!==8'hff)
          $fatal(1,"REM-RESET-STALE-OWNER phase=%0d",phase);
      end
    end
    $display("REM-EXCEPTION-TRANSPORT-OK rows=%0d resets=3",count); $finish;
  end
  initial begin #100000000; $fatal(1,"REM-TIMEOUT"); end
endmodule
`default_nettype wire
