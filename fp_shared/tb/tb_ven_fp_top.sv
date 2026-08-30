`timescale 1ns/1ps
`default_nettype none

module tb_ven_fp_top;
  import ventium_decode_pkg::*;

  localparam logic [79:0] FP_ZERO = 80'h00000000000000000000;
  localparam logic [79:0] FP_ONE  = 80'h3fff8000000000000000;
  localparam logic [79:0] FP_TWO  = 80'h40008000000000000000;
  localparam logic [79:0] FP_THREE= 80'h4000c000000000000000;
  localparam logic [79:0] FP_FOUR = 80'h40018000000000000000;
  localparam logic [79:0] FP_FIVE = 80'h4001a000000000000000;
  localparam logic [79:0] FP_SIX  = 80'h4001c000000000000000;
  localparam logic [79:0] FP_1P5 = 80'h3fffc000000000000000;
  localparam logic [79:0] FP_NEG1 = 80'hbfff8000000000000000;
  localparam logic [79:0] FP_INF  = 80'h7fff8000000000000000;
  localparam logic [79:0] FP_INDEF= 80'hffffc000000000000000;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic cmd_valid, cmd_ready;
  fxop_e cmd_op;
  logic [2:0] cmd_aluop, cmd_sti, cmd_constant;
  logic cmd_pop, cmd_fdiv_bug;
  logic cmd_fist_bug, cmd_env16, cmd_real_mode;
  logic [863:0] cmd_env_image;
  logic cmd_update_fip, cmd_update_fdp;
  logic [31:0] cmd_fip, cmd_fdp;
  logic [15:0] cmd_fcs, cmd_fds;
  logic [79:0] cmd_mem;
  logic [3:0] cmd_mem_bytes;
  logic busy, rsp_valid, rsp_unsupported;
  logic rsp_stack_fault, rsp_store_valid, rsp_ax_valid;
  logic [84:0] rsp_arith;
  logic [863:0] rsp_store_data;
  logic [7:0] rsp_store_bytes;
  logic [15:0] rsp_ax;
  logic [2:0] ftop;
  logic [15:0] fstat, fctrl;
  logic [7:0] fptag;
  logic [639:0] phys_flat, st_flat;
  logic [31:0] fip, fdp;
  logic [15:0] fcs, fds;
  logic [639:0] saved_st;
  logic [7:0] saved_tag;
  logic [2:0] saved_top;
  int checks;

  ven_fp_top dut (
      .clk(clk), .rst_n(rst_n),
      .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_op(cmd_op),
      .cmd_aluop(cmd_aluop), .cmd_sti(cmd_sti), .cmd_pop(cmd_pop),
      .cmd_constant(cmd_constant), .cmd_mem(cmd_mem),
      .cmd_mem_bytes(cmd_mem_bytes), .cmd_fdiv_bug(cmd_fdiv_bug),
      .cmd_fist_bug(cmd_fist_bug), .cmd_env16(cmd_env16),
      .cmd_real_mode(cmd_real_mode), .cmd_env_image(cmd_env_image),
      .cmd_update_fip(cmd_update_fip), .cmd_fip(cmd_fip), .cmd_fcs(cmd_fcs),
      .cmd_update_fdp(cmd_update_fdp), .cmd_fdp(cmd_fdp), .cmd_fds(cmd_fds),
      .busy(busy), .rsp_valid(rsp_valid), .rsp_unsupported(rsp_unsupported),
      .rsp_stack_fault(rsp_stack_fault),
      .rsp_arith(rsp_arith), .ftop_o(ftop), .fstat_o(fstat),
      .rsp_store_valid(rsp_store_valid), .rsp_store_data(rsp_store_data),
      .rsp_store_bytes(rsp_store_bytes), .rsp_ax_valid(rsp_ax_valid),
      .rsp_ax(rsp_ax),
      .fctrl_o(fctrl), .fptag_o(fptag), .fpr_phys_flat_o(phys_flat),
      .fip_o(fip), .fcs_o(fcs), .fdp_o(fdp), .fds_o(fds),
      .st_flat_o(st_flat)
  );

  task automatic issue(
      input fxop_e op,
      input logic [2:0] aluop,
      input logic [2:0] sti,
      input logic pop,
      input logic [79:0] mem,
      input logic [3:0] bytes,
      input logic expect_unsupported,
      input int min_busy_cycles
  );
    int waited;
    begin
      while (!cmd_ready) @(negedge clk);
      @(negedge clk);
      cmd_valid     = 1'b1;
      cmd_op        = op;
      cmd_aluop     = aluop;
      cmd_sti       = sti;
      cmd_pop       = pop;
      cmd_mem       = mem;
      cmd_mem_bytes = bytes;
      @(negedge clk);
      cmd_valid = 1'b0;
      waited = 0;
      while (!rsp_valid) begin
        if (!cmd_ready) waited++;
        @(negedge clk);
      end
      if (rsp_unsupported !== expect_unsupported)
        $fatal(1, "unsupported mismatch op=%0d", op);
      if (waited < min_busy_cycles)
        $fatal(1, "operation completed too early op=%0d waited=%0d", op, waited);
      checks++;
    end
  endtask

  // A producer may change every command field after the valid/ready edge.
  // Exercise a long FDIV while deliberately corrupting the live command bus;
  // the accepted operation must depend only on state captured at issue.
  task automatic issue_div_with_mutating_command_bus;
    int waited;
    begin
      while (!cmd_ready) @(negedge clk);
      @(negedge clk);
      cmd_valid     = 1'b1;
      cmd_op        = FX_AR_ST0_STI;
      cmd_aluop     = 3'd6;
      cmd_sti       = 3'd1;
      cmd_pop       = 1'b0;
      cmd_mem       = 80'd0;
      cmd_mem_bytes = 4'd0;
      cmd_fdiv_bug  = 1'b0;
      @(negedge clk);
      cmd_valid = 1'b0;

      waited = 0;
      while (!rsp_valid) begin
        if (cmd_ready || !busy)
          $fatal(1, "FDIV exposed ready or dropped busy before completion");
        cmd_op        = waited[0] ? FX_FNINIT : FX_NONE;
        cmd_aluop     = waited[2:0];
        cmd_sti       = ~waited[2:0];
        cmd_pop       = waited[0];
        cmd_mem       = {waited[15:0], $urandom, $urandom};
        cmd_mem_bytes = waited[3:0];
        cmd_fdiv_bug  = waited[0];
        cmd_fist_bug  = waited[1];
        cmd_env16     = waited[2];
        waited++;
        @(negedge clk);
      end

      if (rsp_unsupported || rsp_stack_fault || !cmd_ready || busy)
        $fatal(1, "FDIV completion handshake/status mismatch");
      if (waited < 30)
        $fatal(1, "mutating-bus FDIV completed too early: %0d cycles", waited);
      checks++;

      // Responses are pulses; there is deliberately no response backpressure.
      @(negedge clk);
      if (rsp_valid)
        $fatal(1, "rsp_valid was not a one-cycle pulse");
      cmd_op        = FX_NONE;
      cmd_aluop     = 3'd0;
      cmd_sti       = 3'd0;
      cmd_pop       = 1'b0;
      cmd_mem       = 80'd0;
      cmd_mem_bytes = 4'd0;
      cmd_fdiv_bug  = 1'b0;
      cmd_fist_bug  = 1'b0;
      cmd_env16     = 1'b0;
    end
  endtask

  task automatic load80(input logic [79:0] value);
    issue(FX_FLD_M80, 3'd0, 3'd0, 1'b0, value, 4'd10, 1'b0, 0);
  endtask

  task automatic expect_st0(input logic [79:0] expected, input string label);
    if (st_flat[79:0] !== expected)
      $fatal(1, "%s ST0 expected=%020h actual=%020h", label,
             expected, st_flat[79:0]);
  endtask

  task automatic expect_store(
      input logic [79:0] expected,
      input logic [7:0] bytes,
      input string label
  );
    begin
      if (!rsp_store_valid || rsp_store_bytes != bytes ||
          rsp_store_data[79:0] !== expected)
        $fatal(1, "%s store expected bytes=%0d data=%020h actual valid=%0b bytes=%0d data=%020h",
               label, bytes, expected, rsp_store_valid, rsp_store_bytes,
               rsp_store_data[79:0]);
    end
  endtask

  initial begin
    cmd_valid=0; cmd_op=FX_NONE; cmd_aluop=0; cmd_sti=0; cmd_pop=0;
    cmd_constant=0; cmd_mem=0; cmd_mem_bytes=0; cmd_fdiv_bug=0;
    cmd_fist_bug=0; cmd_env16=0; cmd_real_mode=0; cmd_env_image=0;
    cmd_update_fip=0; cmd_fip=0; cmd_fcs=0;
    cmd_update_fdp=0; cmd_fdp=0; cmd_fds=0;
    checks=0;
    repeat (3) @(negedge clk);
    rst_n=1;

    if ({ftop,fstat,fctrl,fptag} !== {3'd0,16'h0000,16'h037f,8'hff})
      $fatal(1, "reset state mismatch");

    load80(FP_TWO);
    load80(FP_ONE);
    issue(FX_AR_ST0_STI, 3'd0, 3'd1, 1'b0, '0, 0, 1'b0, 1);
    expect_st0(FP_THREE, "1+2");

    load80(FP_TWO);
    issue(FX_AR_ST0_STI, 3'd1, 3'd1, 1'b0, '0, 0, 1'b0, 1);
    expect_st0(FP_SIX, "2*3");

    issue(FX_AR_ST0_STI, 3'd6, 3'd1, 1'b0, '0, 0, 1'b0, 30);
    expect_st0(FP_TWO, "6/3");

    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    load80(FP_TWO);
    load80(FP_FOUR);
    issue_div_with_mutating_command_bus();
    expect_st0(FP_TWO, "latched-command 4/2");

    load80(FP_FOUR);
    issue(FX_FSQRT, 3'd0, 3'd0, 1'b0, '0, 0, 1'b0, 30);
    expect_st0(FP_TWO, "sqrt(4)");

    // Division exceptional cases are completed without entering the SRT loop.
    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    load80(FP_ZERO);
    load80(FP_ONE);
    issue(FX_AR_ST0_STI, 3'd6, 3'd1, 1'b0, '0, 0, 1'b0, 0);
    expect_st0(FP_INF, "1/0");
    if (!fstat[2]) $fatal(1, "1/0 did not set ZE");

    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    load80(FP_ZERO);
    load80(FP_ZERO);
    issue(FX_AR_ST0_STI, 3'd6, 3'd1, 1'b0, '0, 0, 1'b0, 0);
    expect_st0(FP_INDEF, "0/0");
    if (!fstat[0]) $fatal(1, "0/0 did not set IE");

    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    load80(FP_NEG1);
    issue(FX_FSQRT, 0, 0, 0, '0, 0, 0, 0);
    expect_st0(FP_INDEF, "sqrt(-1)");
    if ({fstat[10],fstat[0]} !== 2'b11)
      $fatal(1, "sqrt(-1) did not set C2+IE");

    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    load80(FP_TWO);
    load80(FP_ONE);
    issue(FX_FCOM_STI, 0, 3'd1, 0, '0, 0, 0, 0);
    if ({fstat[14],fstat[10],fstat[8]} !== 3'b001)
      $fatal(1, "FCOM 1,2 condition-code mismatch");
    issue(FX_FXAM, 0, 0, 0, '0, 0, 0, 0);
    if ({fstat[14],fstat[10],fstat[9],fstat[8]} !== 4'b0100)
      $fatal(1, "FXAM normal classification mismatch");
    issue(FX_FCOMPP, 0, 0, 0, '0, 0, 0, 0);
    if (ftop !== 3'd0 || fptag !== 8'hff)
      $fatal(1, "FCOMPP did not pop two operands");

    // Registered conversion/store service.
    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    load80(FP_ONE);
    issue(FX_FST_M32, 0, 0, 0, '0, 4, 0, 1);
    expect_store({48'd0,32'h3f800000}, 8'd4, "FST m32 1.0");
    issue(FX_FST_M64, 0, 0, 0, '0, 8, 0, 1);
    expect_store({16'd0,64'h3ff0000000000000}, 8'd8, "FST m64 1.0");
    issue(FX_FST_M80, 0, 0, 0, '0, 10, 0, 1);
    expect_store(FP_ONE, 8'd10, "FST m80 1.0");

    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    load80(FP_1P5);
    issue(FX_FIST_M16, 0, 0, 0, '0, 2, 0, 1);
    expect_store({64'd0,16'd2}, 8'd2, "FIST m16 1.5");
    if (!fstat[5]) $fatal(1, "FIST m16 1.5 did not set PE");

    issue(FX_FNCLEX, 0, 0, 0, '0, 0, 0, 0);
    issue(FX_FRNDINT, 0, 0, 0, '0, 0, 0, 1);
    expect_st0(FP_TWO, "FRNDINT 1.5");
    if (!fstat[5]) $fatal(1, "FRNDINT 1.5 did not set PE");

    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    load80(FP_TWO);
    load80(FP_1P5);
    issue(FX_FSCALE, 0, 0, 0, '0, 0, 0, 1);
    expect_st0(FP_SIX, "FSCALE 1.5 by 2");

    // Unified SRT remainder service.
    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    load80(FP_TWO);
    load80(FP_FIVE);
    issue(FX_FPREM, 0, 0, 0, '0, 0, 0, 20);
    expect_st0(FP_ONE, "FPREM 5,2");
    if ({fstat[14],fstat[10],fstat[9],fstat[8]} !== 4'b1000)
      $fatal(1, "FPREM quotient condition-code mismatch");

    // Iterative BCD load/store round-trip.
    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    issue(FX_FBLD, 0, 0, 0, 80'h00000000000000000123, 10, 0, 5);
    issue(FX_FBSTP, 0, 0, 1, '0, 10, 0, 40);
    expect_store(80'h00000000000000000123, 8'd10, "BCD 123 round-trip");
    if (ftop !== 3'd0 || fptag !== 8'hff)
      $fatal(1, "FBSTP did not pop the BCD operand");

    // Exact status/control stores and the full environment/state image.
    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    load80(FP_TWO);
    load80(FP_ONE);
    issue(FX_FNSAVE, 0, 0, 0, '0, 0, 0, 0);
    if (!rsp_store_valid || rsp_store_bytes != 8'd108)
      $fatal(1, "FNSAVE did not return a 108-byte image");
    cmd_env_image = rsp_store_data;
    if ({ftop,fstat,fctrl,fptag} !== {3'd0,16'h0000,16'h037f,8'hff})
      $fatal(1, "FNSAVE did not reinitialize metadata");
    issue(FX_FRSTOR, 0, 0, 0, '0, 0, 0, 0);
    expect_st0(FP_ONE, "FRSTOR ST0");
    if (st_flat[159:80] !== FP_TWO)
      $fatal(1, "FRSTOR ST1 mismatch");

    issue(FX_FNSTCW, 0, 0, 0, '0, 0, 0, 0);
    expect_store({64'd0,16'h037f}, 8'd2, "FNSTCW");
    issue(FX_FNSTSW_AX, 0, 0, 0, '0, 0, 0, 0);
    if (!rsp_ax_valid || rsp_ax[13:11] !== ftop)
      $fatal(1, "FNSTSW AX response mismatch");

    // 16-bit environment/state form: seven 16-bit environment fields followed
    // by the same eight 80-bit logical registers (14/94 bytes total).
    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    cmd_update_fip = 1'b1;
    cmd_update_fdp = 1'b1;
    cmd_fip = 32'h12345678; cmd_fcs = 16'h2468;
    cmd_fdp = 32'h89abcdef; cmd_fds = 16'h1357;
    load80(FP_THREE);
    cmd_update_fip = 1'b0;
    cmd_update_fdp = 1'b0;
    load80(FP_TWO);
    cmd_env16 = 1'b1;
    issue(FX_FNSAVE, 0, 0, 0, '0, 0, 0, 0);
    if (!rsp_store_valid || rsp_store_bytes != 8'd94 ||
        rsp_store_data[63:48] !== 16'h5678 ||
        rsp_store_data[79:64] !== 16'h2468 ||
        rsp_store_data[95:80] !== 16'hcdef ||
        rsp_store_data[111:96] !== 16'h1357)
      $fatal(1, "16-bit protected-mode FNSAVE image mismatch");
    cmd_env_image = rsp_store_data;
    issue(FX_FRSTOR, 0, 0, 0, '0, 0, 0, 0);
    expect_st0(FP_TWO, "16-bit FRSTOR ST0");
    if (st_flat[159:80] !== FP_THREE)
      $fatal(1, "16-bit FRSTOR ST1 mismatch");

    // In real mode the selector words carry the high four address bits; FOP is
    // zero in the project oracle, matching the existing core image builder.
    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    cmd_update_fip = 1'b1;
    cmd_update_fdp = 1'b1;
    cmd_fip = 32'h000a5678; cmd_fcs = 16'hffff;
    cmd_fdp = 32'h000bcdef; cmd_fds = 16'heeee;
    load80(FP_ONE);
    cmd_update_fip = 1'b0;
    cmd_update_fdp = 1'b0;
    cmd_real_mode = 1'b1;
    issue(FX_FNSTENV, 0, 0, 0, '0, 0, 0, 0);
    if (!rsp_store_valid || rsp_store_bytes != 8'd14 ||
        rsp_store_data[63:48] !== 16'h5678 ||
        rsp_store_data[79:64] !== 16'ha000 ||
        rsp_store_data[95:80] !== 16'hcdef ||
        rsp_store_data[111:96] !== 16'hb000)
      $fatal(1, "16-bit real-mode FNSTENV image mismatch");
    cmd_env16 = 1'b0;
    cmd_real_mode = 1'b0;

    // Architectural stack-fault matrix.  These cases are compared directly
    // with the proven fpu_writeback contract and its px87stk regressions.
    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    repeat (8) load80(FP_ONE);
    issue(FX_FLD_M80, 0, 0, 0, FP_TWO, 10, 0, 0);
    if (!rsp_stack_fault || st_flat[79:0] !== FP_INDEF ||
        (fstat & 16'h82c1) !== 16'h0241 || ftop !== 3'd7)
      $fatal(1, "masked push-overflow response mismatch");

    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    issue(FX_AR_ST0_STI, 0, 1, 0, '0, 0, 0, 0);
    if (!rsp_stack_fault || st_flat[79:0] !== FP_INDEF ||
        (fstat & 16'h82c1) !== 16'h0041)
      $fatal(1, "masked empty arithmetic response mismatch");

    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    issue(FX_FCOM_STI, 0, 1, 0, '0, 0, 0, 0);
    if (!rsp_stack_fault ||
        {fstat[14],fstat[10],fstat[9],fstat[8]} !== 4'b1101 ||
        (fstat & 16'h0041) !== 16'h0041)
      $fatal(1, "masked empty compare was not unordered");

    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    repeat (8) load80(FP_ONE);
    issue(FX_FLDCW, 0, 0, 0, {64'd0,16'h037e}, 2, 0, 0);
    saved_st  = st_flat;
    saved_tag = fptag;
    saved_top = ftop;
    issue(FX_FLD_M80, 0, 0, 0, FP_TWO, 10, 0, 0);
    if (!rsp_stack_fault || rsp_store_valid || st_flat !== saved_st ||
        fptag !== saved_tag || ftop !== saved_top ||
        (fstat & 16'h82c1) !== 16'h82c1)
      $fatal(1, "unmasked push-overflow was not fully suppressed");

    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    issue(FX_FXAM, 0, 0, 0, '0, 0, 0, 0);
    if (rsp_stack_fault || (fstat & 16'h0041) != 0 ||
        {fstat[14],fstat[10],fstat[8]} !== 3'b101)
      $fatal(1, "FXAM empty incorrectly raised a stack fault");

    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    load80(FP_ONE);
    issue(FX_FSCALE, 0, 0, 0, '0, 0, 0, 0);
    if (!rsp_stack_fault || st_flat[79:0] !== FP_INDEF ||
        (fstat & 16'h0241) !== 16'h0041)
      $fatal(1, "fixed-ST1 masked underflow mismatch");

    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    issue(FX_FST_M32, 0, 0, 1, '0, 4, 0, 0);
    if (!rsp_stack_fault || !rsp_store_valid || rsp_store_bytes != 8'd4 ||
        rsp_store_data[31:0] !== 32'hffc00000 || ftop !== 3'd1)
      $fatal(1, "masked empty FSTP m32 response mismatch");

    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    issue(FX_FLDCW, 0, 0, 0, {64'd0,16'h037e}, 2, 0, 0);
    saved_st  = st_flat;
    saved_tag = fptag;
    saved_top = ftop;
    issue(FX_FIST_M32, 0, 0, 1, '0, 4, 0, 0);
    if (!rsp_stack_fault || rsp_store_valid || st_flat !== saved_st ||
        fptag !== saved_tag || ftop !== saved_top ||
        (fstat & 16'h80c1) !== 16'h80c1)
      $fatal(1, "unmasked empty FISTP m32 was not suppressed");

    // Shared transcendental sequencer through the architectural shell.
    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    load80(FP_ZERO);
    issue(FX_FSIN, 0, 0, 0, '0, 0, 0, 100);
    expect_st0(FP_ZERO, "FSIN(0)");
    if (!fstat[5] || fstat[10])
      $fatal(1, "FSIN status mismatch");

    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    load80(FP_ZERO);
    issue(FX_FCOS, 0, 0, 0, '0, 0, 0, 100);
    expect_st0(FP_ONE, "FCOS(0)");

    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    load80(FP_ZERO);
    issue(FX_FSINCOS, 0, 0, 0, '0, 0, 0, 100);
    expect_st0(FP_ONE, "FSINCOS cos(0)");
    if (st_flat[159:80] !== FP_ZERO || ftop !== 3'd6)
      $fatal(1, "FSINCOS sin result or push mismatch");

    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    load80(FP_ZERO);
    issue(FX_FPTAN, 0, 0, 0, '0, 0, 0, 100);
    expect_st0(FP_ONE, "FPTAN pushed one");
    if (st_flat[159:80] !== FP_ZERO || ftop !== 3'd6)
      $fatal(1, "FPTAN tangent result or push mismatch");

    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    load80(80'h403e8000000000000000);
    issue(FX_FSINCOS, 0, 0, 0, '0, 0, 0, 0);
    expect_st0(80'h403e8000000000000000, "FSINCOS out-of-range");
    if (!fstat[10] || ftop !== 3'd7)
      $fatal(1, "out-of-range FSINCOS did not set C2 without push");

    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    load80(FP_ONE);
    issue(FX_F2XM1, 0, 0, 0, '0, 0, 0, 2);
    expect_st0(FP_ONE, "F2XM1(1)");
    if (fstat[5:0] != 6'd0)
      $fatal(1, "exact F2XM1(1) incorrectly raised an exception");

    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    load80(FP_ONE);                         // ST1 multiplier
    load80(80'h40008000000000000000);       // ST0 = 2.0
    issue(FX_FYL2X, 0, 0, 0, '0, 0, 0, 2);
    expect_st0(FP_ONE, "FYL2X(1,2)");
    if (ftop !== 3'd7)
      $fatal(1, "FYL2X did not write ST1 and pop ST0");

    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    load80(FP_ONE);                         // ST1 multiplier
    load80(FP_ZERO);                        // log2(1 + 0) = 0
    issue(FX_FYL2XP1, 0, 0, 0, '0, 0, 0, 2);
    expect_st0(FP_ZERO, "FYL2XP1(1,0)");
    if (ftop !== 3'd7)
      $fatal(1, "FYL2XP1 did not write ST1 and pop ST0");

    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    load80(FP_ONE);                         // ST1 = y
    load80(FP_ONE);                         // ST0 = x
    issue(FX_FPATAN, 0, 0, 0, '0, 0, 0, 2);
    expect_st0(80'h3ffec90fdaa22168c235, "FPATAN(1,1)");
    if (ftop !== 3'd7)
      $fatal(1, "FPATAN did not write ST1 and pop ST0");

    // An explicit no-operation encoding remains a loud unsupported witness.
    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    issue(FX_NONE, 0, 0, 0, '0, 0, 1, 0);

    $display("VEN-FP-TOP-SMOKE-OK checks=%0d", checks);
    $finish;
  end
endmodule

`default_nettype wire
