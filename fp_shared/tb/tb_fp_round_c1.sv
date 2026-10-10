`timescale 1ns/1ps
`default_nettype none

// Architectural command test: ordinary FLD/FNSTENV/FLDENV seed the operands
// and C1. No hierarchical state deposit or reset-restore interface is used.
module tb_fp_round_c1;
  import ventium_decode_pkg::*;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic cmd_valid = 0, cmd_ready, cmd_accept_retire, alu_commit_retire;
  fxop_e cmd_op = FX_NONE;
  logic [2:0] cmd_aluop = 0, cmd_sti = 0, cmd_constant = 0;
  logic cmd_pop = 0, cmd_fdiv_bug = 0, cmd_fist_bug = 0;
  logic cmd_env16 = 0, cmd_real_mode = 0;
  logic [863:0] cmd_env_image = 0;
  logic cmd_update_fip = 0, cmd_update_fdp = 0;
  logic [31:0] cmd_fip = 0, cmd_fdp = 0;
  logic [15:0] cmd_fcs = 0, cmd_fds = 0;
  logic [79:0] cmd_mem = 0;
  logic [3:0] cmd_mem_bytes = 0;
  logic busy, rsp_valid, rsp_unsupported, rsp_stack_fault;
  logic [84:0] rsp_arith;
  logic rsp_store_valid, rsp_ax_valid;
  logic [863:0] rsp_store_data;
  logic [7:0] rsp_store_bytes;
  logic [15:0] rsp_ax, fstat_o, fctrl_o, fcs_o, fds_o;
  logic [2:0] ftop_o;
  logic [7:0] fptag_o;
  logic [31:0] fip_o, fdp_o;
  logic [639:0] fpr_phys_flat_o, st_flat_o;
  int checks = 0;
  ven_fp_top dut (.*);

  task automatic issue(input fxop_e op, input logic [2:0] subop,
                       input logic [2:0] sti, input logic [79:0] mem,
                       input logic [3:0] bytes, input bit stack_fault = 0,
                       input bit check_pending_c1 = 0);
    int waited;
    bit before_c1;
    waited = 0;
    while (!cmd_ready) begin
      @(negedge clk);
      if (++waited > 1000) $fatal(1, "command admission timeout");
    end
    @(negedge clk);
    before_c1 = fstat_o[9];
    cmd_valid = 1; cmd_op = op; cmd_aluop = subop; cmd_sti = sti;
    cmd_mem = mem; cmd_mem_bytes = bytes;
    @(negedge clk);
    cmd_valid = 0;
    // Completion must use captured/owned metadata, not the command bus.
    cmd_op = FX_NONE; cmd_aluop = 7; cmd_sti = 7;
    cmd_mem = '1; cmd_mem_bytes = 0;
    waited = 0;
    while (!rsp_valid) begin
      if (check_pending_c1 && fstat_o[9] !== before_c1)
        $fatal(1, "C1 changed before its response owner op=%0d", op);
      @(negedge clk);
      if (++waited > 10000) $fatal(1, "response timeout op=%0d", op);
    end
    if (rsp_unsupported || rsp_stack_fault !== stack_fault)
      $fatal(1, "unexpected response op=%0d unsupported=%b stack=%b",
             op, rsp_unsupported, rsp_stack_fault);
  endtask

  task automatic seed_c1(input bit seed);
    issue(FX_FNSTENV, 0, 0, 0, 0);
    if (!rsp_store_valid || rsp_store_bytes != 28)
      $fatal(1, "missing architectural environment");
    cmd_env_image = rsp_store_data;
    cmd_env_image[41] = seed; // 32-bit environment SW starts at byte4
    issue(FX_FLDENV, 0, 0, 0, 0);
    if (fstat_o[9] !== seed) $fatal(1, "C1 seed was not loaded");
  endtask

  task automatic vectors(input string path);
    int fd, fields, op, pc, rc, seed, expect_c1;
    logic [79:0] a, b, expected;
    logic [15:0] cw;
    fd = $fopen(path, "r");
    if (!fd) $fatal(1, "cannot open vectors %s", path);
    while (!$feof(fd)) begin
      fields = $fscanf(fd, "%h %h %h %h %h %h %h %h\n",
                       op, pc, rc, seed, a, b, expect_c1, expected);
      if ((fields == 0 || fields == -1) && $feof(fd)) break;
      if (fields != 8) $fatal(1, "bad vector row %0d", checks);
      if (!(op inside {0,1,4,5,6,8}) || !(pc inside {0,2,3}) ||
          rc > 3 || seed > 1 || expect_c1 > 1)
        $fatal(1, "invalid vector metadata");
      issue(FX_FNINIT, 0, 0, 0, 0);
      cw = 16'h007f | (16'(pc) << 8) | (16'(rc) << 10);
      issue(FX_FLDCW, 0, 0, {64'd0, cw}, 2);
      if (op != 8) issue(FX_FLD_M80, 0, 0, b, 10);
      issue(FX_FLD_M80, 0, 0, a, 10);
      seed_c1(1'(seed));
      issue(op == 8 ? FX_FSQRT : FX_AR_ST0_STI,
            3'(op), 1, 0, 0, 0, 1);
      if (st_flat_o[79:0] !== expected || fstat_o[9] !== 1'(expect_c1))
        $fatal(1, "round result case=%0d op=%0d pc=%0d rc=%0d seed=%0d a=%020h b=%020h got=%020h C1=%b expected=%020h C1=%0d",
               checks, op, pc, rc, seed, a, b, st_flat_o[79:0],
               fstat_o[9], expected, expect_c1);
      checks++;
    end
    $fclose(fd);
  endtask

`ifdef VEN_FP_ARITH_STREAM
  task automatic stream_owners;
    int returned, waited;
    issue(FX_FNINIT, 0, 0, 0, 0);
    // ST0=0; ST1=1+2^-40, ST2=2. At PC24/up, independent adds
    // write ST1 rounded upward, then ST2 exactly on consecutive clocks.
    issue(FX_FLDCW, 0, 0, 80'h087f, 2);
    issue(FX_FLD_M80, 0, 0, 80'h40008000000000000000, 10);
    issue(FX_FLD_M80, 0, 0, 80'h3fff8000000000800000, 10);
    issue(FX_FLD_M80, 0, 0, 80'd0, 10);
    seed_c1(0);
    @(negedge clk);
    cmd_valid = 1; cmd_op = FX_AR_STI_ST0; cmd_aluop = 0; cmd_sti = 1;
    #1;
    if (!cmd_ready) $fatal(1, "first stream owner rejected");
    @(negedge clk);
    cmd_sti = 2;
    #1;
    if (!cmd_ready) $fatal(1, "independent stream owner serialized");
    @(negedge clk);
    cmd_valid = 0; cmd_op = FX_NONE; cmd_sti = 7; cmd_aluop = 7;
    returned = 0; waited = 0;
    while (returned < 2) begin
      if (rsp_valid) begin
        if (rsp_unsupported || rsp_stack_fault || fstat_o[9] !== (returned == 0))
          $fatal(1, "stream C1 went to the wrong owner %0d", returned);
        returned++;
      end
      @(negedge clk);
      if (++waited > 6) $fatal(1, "arithmetic stream latency increased");
    end
    if (st_flat_o[159:80] !== 80'h3fff8000010000000000 ||
        st_flat_o[239:160] !== 80'h40008000000000000000)
      $fatal(1, "stream destinations changed");
  endtask
`endif

  initial begin
    string path;
    if (!$value$plusargs("vectors=%s", path)) $fatal(1, "missing vectors");
    repeat (3) @(negedge clk);
    rst_n = 1;
    vectors(path);
    if (checks != 2064) $fatal(1, "incomplete vector corpus count=%0d", checks);
`ifdef VEN_FP_ARITH_STREAM
    stream_owners();
`endif
    // Masked and unmasked stack faults must retain their distinct C1 rule.
    issue(FX_FNINIT, 0, 0, 0, 0);
    seed_c1(1);
    issue(FX_FSQRT, 0, 0, 0, 0, 1);
    if ((fstat_o & 16'h0241) != 16'h0041) $fatal(1, "masked stack underflow C1");
    issue(FX_FNINIT, 0, 0, 0, 0);
    for (int i=0; i<8; i++) issue(FX_FLD_M80, 0, 0, 80'h3fff8000000000000000, 10);
    issue(FX_FLD_M80, 0, 0, 80'h3fff8000000000000000, 10, 1);
    if ((fstat_o & 16'h0241) != 16'h0241) $fatal(1, "stack overflow C1");
    issue(FX_FNINIT, 0, 0, 0, 0);
    issue(FX_FLDCW, 0, 0, 80'h037e, 2);
    // FNSTENV masks exceptions, so restore the intended CW after seeding.
    seed_c1(1);
    issue(FX_FLDCW, 0, 0, 80'h037e, 2);
    issue(FX_FSQRT, 0, 0, 0, 0, 1);
    if ((fstat_o & 16'h82c1) != 16'h80c1 || fptag_o != 8'hff)
      $fatal(1, "unmasked stack underflow mutation/status");
    // Reset an actual SRT recurrence; no stale status/result may leak later.
    issue(FX_FNINIT, 0, 0, 0, 0);
    issue(FX_FLD_M80, 0, 0, 80'h40008000000000000000, 10);
    @(negedge clk);
    cmd_valid = 1; cmd_op = FX_FSQRT;
    @(negedge clk);
    cmd_valid = 0; cmd_op = FX_NONE;
    repeat (8) @(negedge clk);
    if (!busy || rsp_valid) $fatal(1, "reset did not hit active recurrence");
    rst_n = 0;
    repeat (2) @(negedge clk);
    rst_n = 1;
    repeat (80) begin
      @(negedge clk);
      if (busy || rsp_valid || fstat_o != 0 || fptag_o != 8'hff)
        $fatal(1, "reset leaked arithmetic state");
    end
    $display("FP-ROUND-C1-TOP-OK cases=%0d stack_faults=3 reset_cancel=1", checks);
    $finish;
  end
endmodule
`default_nettype wire
