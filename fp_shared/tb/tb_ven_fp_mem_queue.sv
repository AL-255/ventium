`timescale 1ns/1ps
`default_nettype none
module tb_ven_fp_mem_queue;
  import ventium_decode_pkg::*;
  localparam logic [79:0] ONE = 80'h3fff8000000000000000;
  localparam logic [79:0] TWO = 80'h40008000000000000000;
  localparam logic [79:0] THREE = 80'h4000c000000000000000;
  localparam logic [79:0] FOUR = 80'h40018000000000000000;
  localparam logic [79:0] SIX = 80'h4001c000000000000000;
  localparam logic [79:0] EIGHT = 80'h40028000000000000000;
  localparam logic [79:0] NEG_TWO = 80'hc0008000000000000000;
  localparam logic [79:0] NEG_SEVEN = 80'hc001e000000000000000;
  localparam logic [79:0] HALF = 80'h3ffe8000000000000000;
  localparam logic [79:0] INDEF = 80'hffffc000000000000000;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n, cmd_valid, cmd_ready, cmd_accept_retire, alu_commit_retire;
  fxop_e cmd_op;
  logic [2:0] cmd_aluop, cmd_sti, cmd_constant;
  logic cmd_pop, cmd_fdiv_bug, cmd_fist_bug, cmd_env16, cmd_real_mode;
  logic [79:0] cmd_mem;
  logic [3:0] cmd_mem_bytes;
  logic [863:0] cmd_env_image;
  logic cmd_update_fip, cmd_update_fdp;
  logic [31:0] cmd_fip, cmd_fdp;
  logic [15:0] cmd_fcs, cmd_fds;
  logic busy, rsp_valid, rsp_unsupported, rsp_stack_fault, rsp_store_valid, rsp_ax_valid;
  logic [84:0] rsp_arith;
  logic [863:0] rsp_store_data;
  logic [7:0] rsp_store_bytes;
  logic [15:0] rsp_ax;
  logic [2:0] ftop_o;
  logic [15:0] fstat_o, fctrl_o;
  logic [7:0] fptag_o;
  logic [31:0] fip_o, fdp_o;
  logic [15:0] fcs_o, fds_o;
  logic [639:0] fpr_phys_flat_o, st_flat_o;
  int checks = 0;
  ven_fp_fxch_queue dut (.*);

  task automatic idle_inputs;
    cmd_valid = 0; cmd_op = FX_NONE; cmd_aluop = 0; cmd_sti = 0;
    cmd_constant = 0; cmd_pop = 0; cmd_fdiv_bug = 0; cmd_fist_bug = 0;
    cmd_env16 = 0; cmd_real_mode = 0; cmd_mem = 0; cmd_mem_bytes = 0;
    cmd_env_image = 0; cmd_update_fip = 0; cmd_update_fdp = 0;
    cmd_fip = 0; cmd_fdp = 0; cmd_fcs = 0; cmd_fds = 0;
  endtask

  task automatic reset_core;
    @(negedge clk); rst_n = 0; idle_inputs();
    repeat (3) @(negedge clk);
    rst_n = 1;
    @(negedge clk);
    if (busy || rsp_valid) $fatal(1, "reset left pending response");
  endtask

  task automatic serial(input fxop_e op, input logic [31:0] data);
    int timeout;
    @(negedge clk);
    idle_inputs(); cmd_op = op; cmd_mem = {48'd0, data}; cmd_mem_bytes = 4;
    cmd_valid = 1;
    #1;
    timeout = 0;
    while (!cmd_ready && timeout < 200) begin @(negedge clk); timeout++; end
    if (!cmd_ready) $fatal(1, "serial accept timeout");
    @(negedge clk); cmd_valid = 0;
    timeout = 0;
    while (!rsp_valid && timeout < 200) begin @(negedge clk); timeout++; end
    if (!rsp_valid || rsp_unsupported) $fatal(1, "serial response failure");
    @(negedge clk);
  endtask

  task automatic setup(input bit full_stack, input bit unmasked);
    reset_core();
    serial(FX_FNINIT, 0);
    if (full_stack) repeat (6) serial(FX_FLD_M32, 32'h3f800000);
    serial(FX_FLD_M32, 32'h40400000);
    serial(FX_FLD_M32, 32'h40c00000);
    if (unmasked) serial(FX_FLDCW, 32'h0000037e);
  endtask

  task automatic start_divide;
    @(negedge clk); idle_inputs();
    cmd_valid = 1; cmd_op = FX_AR_ST0_STI; cmd_aluop = 6; cmd_sti = 1;
    cmd_update_fip = 1; cmd_fip = 32'h10203040; cmd_fcs = 16'h0018;
    #1;
    if (!cmd_ready || cmd_accept_retire) $fatal(1, "divide admission failure");
    @(negedge clk); cmd_valid = 0;
    if (!busy || rsp_valid) $fatal(1, "divide did not retain owner");
  endtask

  task automatic queue_pair(input fxop_e op, input logic [2:0] alu,
                            input logic [31:0] data, input logic [79:0] expected,
                            input bit pushes, input bit full_stack);
    int responses, waited;
    logic [2:0] old_top;
    logic [7:0] old_tag;
    logic [639:0] old_regs;
    logic [639:0] old_done_regs, young_done_regs;
    setup(full_stack, 0);
    old_top = ftop_o; old_tag = fptag_o; old_regs = fpr_phys_flat_o;
    old_done_regs = old_regs;
    old_done_regs[old_top*80 +: 80] = TWO;
    young_done_regs = old_done_regs;
    young_done_regs[(pushes ? (3'(old_top - 3'd1)) : old_top)*80 +: 80] = expected;
    start_divide();
    // Already acquired memory bytes are presented on the command seam.
    cmd_op = op; cmd_aluop = alu; cmd_sti = 0; cmd_mem = {48'd0, data};
    cmd_mem_bytes = 4; cmd_pop = 0; cmd_valid = 1;
    cmd_update_fip = 1; cmd_update_fdp = 1;
    cmd_fip = 32'h55667788; cmd_fcs = 16'h0028;
    cmd_fdp = 32'h1234567c; cmd_fds = 16'h0030;
    #1;
    if (!cmd_ready || cmd_accept_retire)
      $fatal(1, "memory command did not queue before old divide response");
    @(negedge clk);
    if (!busy || rsp_valid || ftop_o != old_top || fptag_o != old_tag ||
        fpr_phys_flat_o != old_regs || fip_o != 32'h10203040)
      $fatal(1, "queue mutated architectural state before older completion");
    // Capacity and descriptor identity: poison every live command field.
    idle_inputs(); cmd_valid = 1; cmd_op = FX_FNSTSW_AX;
    cmd_mem = '1; cmd_mem_bytes = 10; cmd_aluop = 7; cmd_pop = 1;
    cmd_update_fip = 1; cmd_update_fdp = 1;
    cmd_fip = '1; cmd_fdp = '1; cmd_fcs = '1; cmd_fds = '1;
    cmd_fdiv_bug = 1;
    #1;
    if (cmd_ready) $fatal(1, "occupied queue accepted a second owner");
    @(negedge clk); cmd_valid = 0;
    responses = 0; waited = 0;
    while (responses < 2 && waited < 250) begin
      if (rsp_valid) begin
        if (rsp_unsupported || rsp_store_valid || rsp_ax_valid)
          $fatal(1, "queued memory owner produced unexpected payload");
        if (responses == 0) begin
          if (st_flat_o[79:0] != TWO || st_flat_o[159:80] != THREE ||
              fpr_phys_flat_o != old_done_regs ||
              ftop_o != old_top || fptag_o != old_tag ||
              fip_o != 32'h10203040 || fcs_o != 16'h0018 ||
              fdp_o != 0 || fds_o != 0 || rsp_stack_fault)
            $fatal(1, "older response lost arithmetic/metadata identity");
        end else begin
          if (st_flat_o[79:0] != expected ||
              fpr_phys_flat_o != young_done_regs ||
              st_flat_o[159:80] != (pushes ? TWO : THREE) ||
              ftop_o != (pushes ? old_top - 3'd1 : old_top) ||
              fptag_o != (pushes ? (old_tag & ~(8'd1 << (old_top - 3'd1))) : old_tag) ||
              fip_o != 32'h55667788 || fcs_o != 16'h0028 ||
              fdp_o != 32'h1234567c || fds_o != 16'h0030 ||
              fctrl_o != 16'h037f || rsp_stack_fault != full_stack ||
              (fstat_o & 16'h47ff) != (full_stack ? 16'h0241 : 16'h0000))
            $fatal(1, "younger response identity mismatch op=%0d alu=%0d value=%020x top=%0d tag=%02x status=%04x",
                   op, alu, st_flat_o[79:0], ftop_o, fptag_o, fstat_o);
        end
        responses++;
      end
      @(negedge clk); waited++;
    end
    if (responses != 2) $fatal(1, "missing ordered responses");
    repeat (4) begin
      if (rsp_valid || busy) $fatal(1, "duplicate response or leaked owner");
      @(negedge clk);
    end
    checks++;
  endtask

  task automatic reject_shapes;
    setup(0, 0); start_divide();
    cmd_valid = 1; cmd_mem_bytes = 4; cmd_pop = 0;
    cmd_op = FX_AR_M32; cmd_aluop = 2; #1;
    if (cmd_ready) $fatal(1, "compare incorrectly queued");
    cmd_aluop = 3; #1;
    if (cmd_ready) $fatal(1, "compare-pop incorrectly queued");
    cmd_aluop = 0; cmd_pop = 1; #1;
    if (cmd_ready) $fatal(1, "pop arithmetic incorrectly queued");
    cmd_pop = 0; cmd_op = FX_FST_M32; #1;
    if (cmd_ready) $fatal(1, "store incorrectly queued");
    cmd_op = FX_FLD_M64; cmd_mem_bytes = 8; #1;
    if (cmd_ready) $fatal(1, "wide source incorrectly queued");
    cmd_op = FX_FLD_M32; cmd_mem_bytes = 2; #1;
    if (cmd_ready) $fatal(1, "partial source incorrectly queued");
    cmd_valid = 0;
    setup(0, 1); start_divide();
    cmd_op = FX_FLD_M32; cmd_mem_bytes = 4; cmd_pop = 0; cmd_valid = 1; #1;
    if (cmd_ready) $fatal(1, "unmasked source incorrectly queued");
    cmd_valid = 0;
    checks++;
  endtask

  task automatic reset_queued;
    setup(0, 0); start_divide();
    cmd_op = FX_FLD_M32; cmd_mem_bytes = 4; cmd_mem = {48'd0,32'h40800000};
    cmd_valid = 1; #1;
    if (!cmd_ready) $fatal(1, "reset fixture failed to queue");
    @(negedge clk); cmd_valid = 0;
    reset_core();
    repeat (80) begin
      if (rsp_valid || busy) $fatal(1, "reset leaked cancelled response");
      @(negedge clk);
    end
    serial(FX_FLD_M32, 32'h3f800000);
    if (st_flat_o[79:0] != ONE) $fatal(1, "reset queue reuse failed");
    checks++;
  endtask

  initial begin
    rst_n = 0; idle_inputs();
    queue_pair(FX_AR_M32, 0, 32'h40800000, SIX, 0, 0);
    queue_pair(FX_AR_M32, 1, 32'h40800000, EIGHT, 0, 0);
    queue_pair(FX_AR_M32, 4, 32'h40800000, NEG_TWO, 0, 0);
    queue_pair(FX_AR_M32, 5, 32'h40800000, TWO, 0, 0);
    queue_pair(FX_AR_M32, 6, 32'h40800000, HALF, 0, 0);
    queue_pair(FX_AR_M32, 7, 32'h40800000, TWO, 0, 0);
    queue_pair(FX_FLD_M32, 0, 32'h40800000, FOUR, 1, 0);
    queue_pair(FX_FILD_M32, 0, 32'hfffffff9, NEG_SEVEN, 1, 0);
    queue_pair(FX_FLD_M32, 0, 32'h40800000, INDEF, 1, 1);
    queue_pair(FX_FILD_M32, 0, 32'hfffffff9, INDEF, 1, 1);
    reject_shapes(); reset_queued();
    $display("FP-MEM-QUEUE-LEAF-OK checks=%0d", checks);
    $finish;
  end
  initial begin #1000000; $fatal(1, "leaf test timeout"); end
endmodule
`default_nettype wire
