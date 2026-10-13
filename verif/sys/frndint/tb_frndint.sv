`timescale 1ns/1ps
`default_nettype none
module tb_frndint;
  import ventium_decode_pkg::*;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  logic valid=0, ready, accept_retire, alu_retire, busy, rsp, unsupported, stack_fault;
  fxop_e op=FX_NONE;
  logic [863:0] env_image=0, store_data;
  logic [79:0] mem=0;
  logic [31:0] ip, dp;
  logic [15:0] cs, ds, sw, cw, ax;
  logic [2:0] top;
  logic [7:0] tag, store_bytes;
  logic [639:0] phys, st;
  logic [84:0] arith;
  logic store_valid, ax_valid;
  int latency;
  ven_fp_top dut (
    .clk(clk), .rst_n(rst_n), .cmd_valid(valid), .cmd_ready(ready),
    .cmd_accept_retire(accept_retire), .alu_commit_retire(alu_retire),
    .cmd_op(op), .cmd_aluop(3'd0), .cmd_sti(3'd0), .cmd_pop(1'b0),
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
    if (!ready) $fatal(1,"FRND-READY-TIMEOUT");
    @(negedge clk); op=next_op; valid=1;
    @(negedge clk); valid=0; op=FX_FNINIT; mem=~mem;
    // Poison the nonaccepted bus, including controls and env. No command
    // following the registered owner may steal its rounding/status response.
    env_image=~env_image;
    latency=0;
    while (!rsp && latency<100) begin @(negedge clk); latency++; end
    if (!rsp || unsupported) $fatal(1,"FRND-RESPONSE-TIMEOUT op=%0d",next_op);
  endtask
  initial begin
    string path;
    int fd, fields, kind, count;
    logic [15:0] in_cw,in_sw,in_tag,in_hi;
    logic [63:0] in_m;
    logic [79:0] result;
    logic [559:0] other_slots;
    if (!$value$plusargs("vectors=%s",path)) $fatal(1,"FRND-NO-VECTORS");
    fd=$fopen(path,"r"); if (!fd) $fatal(1,"FRND-VECTORS-OPEN");
    repeat (3) @(negedge clk); rst_n=1; count=0;
    while (!$feof(fd)) begin
      fields=$fscanf(fd,"%h %h %h %h %h %d\n",in_cw,in_sw,in_tag,in_hi,in_m,kind);
      if (fields!=6) $fatal(1,"FRND-VECTOR-PARSE");
      command(FX_FNINIT);
      env_image=0;
      env_image[0 +: 16]=in_cw;
      env_image[32 +: 16]=in_sw;
      env_image[64 +: 16]=in_tag;
      for (int i=0;i<8;i++) env_image[224+i*80 +: 80]=80'h3fff8000000000000000;
      env_image[224 +: 80]={in_hi,in_m};
      command(FX_FRSTOR);
      if (cw!==in_cw || st[79:0]!=={in_hi,in_m} || top!==0)
        $fatal(1,"FRND-SEED");
      other_slots=st[639:80];
      case (kind)
        0: command(FX_FRNDINT);
        1: command(FX_FIST_M64);
        2: command(FX_FST_M32);
        3: command(FX_FST_M64);
        default: $fatal(1,"FRND-KIND");
      endcase
      result=kind==0 ? st[79:0] : store_data[79:0];
      if (st[639:80]!==other_slots || cw!==in_cw || top!==0 ||
          {ip,dp,cs,ds}!==96'd0 || (kind!=0 && !store_valid))
        $fatal(1,"FRND-OWNER-CORRUPTION row=%0d",count);
      $display("ROW %0d %020h %04h %02h %0d %0d",count,result,sw,tag,latency,stack_fault);
      @(negedge clk);
      repeat (2) begin
        if (rsp || cw!==in_cw || (kind==0 && st[79:0]!==result))
          $fatal(1,"FRND-DUPLICATE-RESPONSE row=%0d",count);
        @(negedge clk);
      end
      count++;
    end
    $fclose(fd);
    // Cold reset at both registered execution stages must cancel the owner.
    for (int phase=0;phase<2;phase++) begin
      command(FX_FNINIT); mem=80'h3fffc000000000000000;
      command(FX_FLD_M80);
      @(negedge clk); op=FX_FRNDINT; valid=1;
      @(negedge clk); valid=0;
      repeat (phase) @(negedge clk);
      rst_n=0; @(negedge clk); rst_n=1;
      repeat (8) begin
        @(negedge clk);
        if (rsp || busy || !ready || sw!==0 || cw!==16'h037f || tag!==8'hff)
          $fatal(1,"FRND-RESET-STALE-OWNER phase=%0d",phase);
      end
    end
    $display("FRND-TRANSPORT-OK rows=%0d resets=2",count); $finish;
  end
  initial begin #100000000; $fatal(1,"FRND-TIMEOUT"); end
endmodule
`default_nettype wire
