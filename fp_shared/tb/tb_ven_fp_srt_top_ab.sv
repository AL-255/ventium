`timescale 1ns/1ps
`default_nettype none

// Focused old/new equivalence for ven_fp_top's shared-SRT admission cone.
// The runner supplies ven_fp_top_old by changing only the pinned old source's
// module declaration.  Both shells share every input and the production SRT
// divider, so this checks cycle timing as well as final architectural state.
module tb_ven_fp_srt_top_ab;
  import ventium_decode_pkg::*;

  localparam logic [79:0] FP_ONE  = 80'h3fff8000000000000000;
  localparam logic [79:0] FP_TWO  = 80'h40008000000000000000;
  localparam logic [79:0] FP_THREE= 80'h4000c000000000000000;
  localparam logic [79:0] FP_FIVE = 80'h4001a000000000000000;
  localparam logic [79:0] FP_1P5  = 80'h3fffc000000000000000;
  // x exponent minus y exponent is 81: ven_fp_trans must use T_ATAN_FAR_REQ.
  localparam logic [79:0] FP_ATAN_FAR_X = 80'h4050c000000000000000;
  localparam int OP_TIMEOUT = 20000;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic cmd_valid;
  fxop_e cmd_op;
  logic [2:0] cmd_aluop, cmd_sti, cmd_constant;
  logic cmd_pop, cmd_fdiv_bug, cmd_fist_bug, cmd_env16, cmd_real_mode;
  logic [79:0] cmd_mem;
  logic [3:0] cmd_mem_bytes;
  logic [863:0] cmd_env_image;
  logic cmd_update_fip, cmd_update_fdp;
  logic [31:0] cmd_fip, cmd_fdp;
  logic [15:0] cmd_fcs, cmd_fds;

  logic old_cmd_ready, old_cmd_accept_retire, old_alu_commit_retire;
  logic old_busy, old_rsp_valid, old_rsp_unsupported, old_rsp_stack_fault;
  logic [84:0] old_rsp_arith;
  logic old_rsp_store_valid, old_rsp_ax_valid;
  logic [863:0] old_rsp_store_data;
  logic [7:0] old_rsp_store_bytes;
  logic [15:0] old_rsp_ax;
  logic [2:0] old_ftop;
  logic [15:0] old_fstat, old_fctrl;
  logic [7:0] old_fptag;
  logic [31:0] old_fip, old_fdp;
  logic [15:0] old_fcs, old_fds;
  logic [639:0] old_phys_flat, old_st_flat;

  logic new_cmd_ready, new_cmd_accept_retire, new_alu_commit_retire;
  logic new_busy, new_rsp_valid, new_rsp_unsupported, new_rsp_stack_fault;
  logic [84:0] new_rsp_arith;
  logic new_rsp_store_valid, new_rsp_ax_valid;
  logic [863:0] new_rsp_store_data;
  logic [7:0] new_rsp_store_bytes;
  logic [15:0] new_rsp_ax;
  logic [2:0] new_ftop;
  logic [15:0] new_fstat, new_fctrl;
  logic [7:0] new_fptag;
  logic [31:0] new_fip, new_fdp;
  logic [15:0] new_fcs, new_fds;
  logic [639:0] new_phys_flat, new_st_flat;

  int checks;
  int matrix_cases;

  ven_fp_top_old old_dut (
      .clk(clk), .rst_n(rst_n), .cmd_valid(cmd_valid), .cmd_ready(old_cmd_ready),
      .cmd_accept_retire(old_cmd_accept_retire),
      .alu_commit_retire(old_alu_commit_retire),
      .cmd_op(cmd_op), .cmd_aluop(cmd_aluop), .cmd_sti(cmd_sti),
      .cmd_pop(cmd_pop), .cmd_constant(cmd_constant), .cmd_mem(cmd_mem),
      .cmd_mem_bytes(cmd_mem_bytes), .cmd_fdiv_bug(cmd_fdiv_bug),
      .cmd_fist_bug(cmd_fist_bug), .cmd_env16(cmd_env16),
      .cmd_real_mode(cmd_real_mode), .cmd_env_image(cmd_env_image),
      .cmd_update_fip(cmd_update_fip), .cmd_fip(cmd_fip), .cmd_fcs(cmd_fcs),
      .cmd_update_fdp(cmd_update_fdp), .cmd_fdp(cmd_fdp), .cmd_fds(cmd_fds),
      .busy(old_busy), .rsp_valid(old_rsp_valid),
      .rsp_unsupported(old_rsp_unsupported), .rsp_stack_fault(old_rsp_stack_fault),
      .rsp_arith(old_rsp_arith), .rsp_store_valid(old_rsp_store_valid),
      .rsp_store_data(old_rsp_store_data), .rsp_store_bytes(old_rsp_store_bytes),
      .rsp_ax_valid(old_rsp_ax_valid), .rsp_ax(old_rsp_ax),
      .ftop_o(old_ftop), .fstat_o(old_fstat), .fctrl_o(old_fctrl),
      .fptag_o(old_fptag), .fip_o(old_fip), .fcs_o(old_fcs),
      .fdp_o(old_fdp), .fds_o(old_fds), .fpr_phys_flat_o(old_phys_flat),
      .st_flat_o(old_st_flat)
  );

  ven_fp_top new_dut (
      .clk(clk), .rst_n(rst_n), .cmd_valid(cmd_valid), .cmd_ready(new_cmd_ready),
      .cmd_accept_retire(new_cmd_accept_retire),
      .alu_commit_retire(new_alu_commit_retire),
      .cmd_op(cmd_op), .cmd_aluop(cmd_aluop), .cmd_sti(cmd_sti),
      .cmd_pop(cmd_pop), .cmd_constant(cmd_constant), .cmd_mem(cmd_mem),
      .cmd_mem_bytes(cmd_mem_bytes), .cmd_fdiv_bug(cmd_fdiv_bug),
      .cmd_fist_bug(cmd_fist_bug), .cmd_env16(cmd_env16),
      .cmd_real_mode(cmd_real_mode), .cmd_env_image(cmd_env_image),
      .cmd_update_fip(cmd_update_fip), .cmd_fip(cmd_fip), .cmd_fcs(cmd_fcs),
      .cmd_update_fdp(cmd_update_fdp), .cmd_fdp(cmd_fdp), .cmd_fds(cmd_fds),
      .busy(new_busy), .rsp_valid(new_rsp_valid),
      .rsp_unsupported(new_rsp_unsupported), .rsp_stack_fault(new_rsp_stack_fault),
      .rsp_arith(new_rsp_arith), .rsp_store_valid(new_rsp_store_valid),
      .rsp_store_data(new_rsp_store_data), .rsp_store_bytes(new_rsp_store_bytes),
      .rsp_ax_valid(new_rsp_ax_valid), .rsp_ax(new_rsp_ax),
      .ftop_o(new_ftop), .fstat_o(new_fstat), .fctrl_o(new_fctrl),
      .fptag_o(new_fptag), .fip_o(new_fip), .fcs_o(new_fcs),
      .fdp_o(new_fdp), .fds_o(new_fds), .fpr_phys_flat_o(new_phys_flat),
      .st_flat_o(new_st_flat)
  );

  task automatic compare_settled(input string label);
    begin
      if ({new_cmd_ready, new_cmd_accept_retire, new_alu_commit_retire,
           new_busy, new_rsp_valid, new_rsp_unsupported, new_rsp_stack_fault,
           new_rsp_arith, new_rsp_store_valid, new_rsp_store_data,
           new_rsp_store_bytes, new_rsp_ax_valid, new_rsp_ax} !==
          {old_cmd_ready, old_cmd_accept_retire, old_alu_commit_retire,
           old_busy, old_rsp_valid, old_rsp_unsupported, old_rsp_stack_fault,
           old_rsp_arith, old_rsp_store_valid, old_rsp_store_data,
           old_rsp_store_bytes, old_rsp_ax_valid, old_rsp_ax})
        $fatal(1, "%s: response/handshake mismatch", label);
      if ({new_ftop, new_fstat, new_fctrl, new_fptag, new_fip, new_fcs,
           new_fdp, new_fds} !==
          {old_ftop, old_fstat, old_fctrl, old_fptag, old_fip, old_fcs,
           old_fdp, old_fds})
        $fatal(1, "%s: architectural metadata mismatch", label);
      if (new_phys_flat !== old_phys_flat || new_st_flat !== old_st_flat)
        $fatal(1, "%s: architectural register-state mismatch", label);
      if ({new_dut.top_state, new_dut.pending_op,
           new_dut.srt_start, new_dut.srt_busy, new_dut.srt_done,
           new_dut.srt_mode, new_dut.srt_a, new_dut.srt_b,
           new_dut.srt_rc, new_dut.srt_pc, new_dut.srt_result,
           new_dut.trans_divide_start} !==
          {old_dut.top_state, old_dut.pending_op,
           old_dut.srt_start, old_dut.srt_busy, old_dut.srt_done,
           old_dut.srt_mode, old_dut.srt_a, old_dut.srt_b,
           old_dut.srt_rc, old_dut.srt_pc, old_dut.srt_result,
           old_dut.trans_divide_start})
        $fatal(1, "%s: SRT ownership/control mismatch", label);
    end
  endtask

  // Drive/check phases use a one-nanosecond settle after the negative edge.
  always @(negedge clk) begin
    #1;
    if (rst_n)
      compare_settled("background");
  end

  task automatic drive_command(
      input fxop_e op, input logic [2:0] aluop, input logic [2:0] sti,
      input logic pop, input logic [79:0] mem, input logic [3:0] bytes
  );
    begin
      cmd_op = op; cmd_aluop = aluop; cmd_sti = sti; cmd_pop = pop;
      cmd_constant = '0; cmd_mem = mem; cmd_mem_bytes = bytes;
      cmd_fdiv_bug = 1'b0; cmd_fist_bug = 1'b0; cmd_env16 = 1'b0;
      cmd_real_mode = 1'b0; cmd_env_image = '0;
      cmd_update_fip = 1'b0; cmd_fip = '0; cmd_fcs = '0;
      cmd_update_fdp = 1'b0; cmd_fdp = '0; cmd_fds = '0;
    end
  endtask

  task automatic wait_ready(input string label);
    int waited;
    begin
      waited = 0;
      while (!(new_cmd_ready && old_cmd_ready)) begin
        @(negedge clk); #1;
        if (waited++ >= OP_TIMEOUT) $fatal(1, "%s: ready timeout", label);
      end
    end
  endtask

  task automatic wait_response(input string label);
    int waited;
    begin
      waited = 0;
      while (!new_rsp_valid) begin
        @(negedge clk); #1;
        if (waited++ >= OP_TIMEOUT) $fatal(1, "%s: response timeout", label);
      end
      if (old_rsp_valid !== 1'b1 || new_rsp_unsupported || old_rsp_unsupported ||
          new_rsp_stack_fault || old_rsp_stack_fault)
        $fatal(1, "%s: invalid response", label);
      checks++;
      @(negedge clk); #1;
    end
  endtask

  task automatic issue_plain(
      input fxop_e op, input logic [2:0] aluop, input logic [2:0] sti,
      input logic pop, input logic [79:0] mem, input logic [3:0] bytes,
      input string label
  );
    begin
      wait_ready(label);
      @(negedge clk);
      drive_command(op, aluop, sti, pop, mem, bytes);
      cmd_valid = 1'b1;
      #1;
      if (new_dut.srt_start || old_dut.srt_start)
        $fatal(1, "%s: non-SRT setup unexpectedly started SRT", label);
      @(negedge clk);
      cmd_valid = 1'b0;
      wait_response(label);
    end
  endtask

  task automatic expect_srt_start(
      input logic [1:0] expected_mode, input logic [1:0] expected_rc,
      input logic [1:0] expected_pc, input string label
  );
    begin
      if (new_dut.srt_start !== 1'b1 || old_dut.srt_start !== 1'b1)
        $fatal(1, "%s: SRT did not start", label);
      if ({new_dut.srt_mode, new_dut.srt_rc, new_dut.srt_pc} !==
          {expected_mode, expected_rc, expected_pc})
        $fatal(1, "%s: new controls got %0d/%0d/%0d want %0d/%0d/%0d",
               label, new_dut.srt_mode, new_dut.srt_rc, new_dut.srt_pc,
               expected_mode, expected_rc, expected_pc);
      if ({old_dut.srt_mode, old_dut.srt_rc, old_dut.srt_pc} !==
          {expected_mode, expected_rc, expected_pc})
        $fatal(1, "%s: old controls got %0d/%0d/%0d want %0d/%0d/%0d",
               label, old_dut.srt_mode, old_dut.srt_rc, old_dut.srt_pc,
               expected_mode, expected_rc, expected_pc);
    end
  endtask

  task automatic expect_srt_operands(
      input logic [79:0] expected_a, input logic [79:0] expected_b,
      input string label
  );
    begin
      if (new_dut.srt_a !== expected_a || new_dut.srt_b !== expected_b)
        $fatal(1, "%s: new SRT operands got %020h/%020h want %020h/%020h",
               label, new_dut.srt_a, new_dut.srt_b, expected_a, expected_b);
      if (old_dut.srt_a !== expected_a || old_dut.srt_b !== expected_b)
        $fatal(1, "%s: old SRT operands got %020h/%020h want %020h/%020h",
               label, old_dut.srt_a, old_dut.srt_b, expected_a, expected_b);
    end
  endtask

  task automatic issue_direct_srt(
      input fxop_e op, input logic [2:0] aluop, input logic [2:0] sti,
      input logic [1:0] expected_mode, input logic [1:0] expected_rc,
      input logic [1:0] expected_pc, input logic [79:0] expected_a,
      input logic [79:0] expected_b, input string label
  );
    begin
      wait_ready(label);
      @(negedge clk);
      drive_command(op, aluop, sti, 1'b0, '0, '0);
      cmd_valid = 1'b1;
      #1;
      expect_srt_start(expected_mode, expected_rc, expected_pc, label);
      expect_srt_operands(expected_a, expected_b, label);
      @(negedge clk);
      cmd_valid = 1'b0;
      wait_response(label);
    end
  endtask

  task automatic issue_trans_srt(
      input fxop_e op, input logic [1:0] expected_rc, input logic [1:0] expected_pc,
      input string label
  );
    int waited, starts;
    begin
      wait_ready(label);
      @(negedge clk);
      drive_command(op, '0, '0, 1'b0, '0, '0);
      cmd_valid = 1'b1;
      @(negedge clk);
      cmd_valid = 1'b0;
      waited = 0;
      starts = 0;
      while (!new_rsp_valid) begin
        @(negedge clk); #1;
        if (new_dut.srt_start || old_dut.srt_start) begin
          expect_srt_start(2'd0, expected_rc, expected_pc, label);
          if (new_dut.srt_a === '0 || new_dut.srt_b === '0 ||
              old_dut.srt_a === '0 || old_dut.srt_b === '0)
            $fatal(1, "%s: borrowed SRT did not receive nonzero operands", label);
          starts++;
        end
        if (waited++ >= OP_TIMEOUT)
          $fatal(1, "%s: transcendental/SRT timeout", label);
      end
      if (starts != 1)
        $fatal(1, "%s: expected one borrowed SRT start, got %0d", label, starts);
      if (old_rsp_valid !== 1'b1 || new_rsp_unsupported || old_rsp_unsupported ||
          new_rsp_stack_fault || old_rsp_stack_fault)
        $fatal(1, "%s: invalid response", label);
      checks++;
      @(negedge clk); #1;
    end
  endtask

  task automatic init_control(
      input logic [1:0] rc, input logic [1:0] pc, input string label
  );
    logic [15:0] control;
    begin
      issue_plain(FX_FNINIT, '0, '0, 1'b0, '0, '0, {label, ": FNINIT"});
      control = 16'h007f;
      control[11:10] = rc;
      control[9:8] = pc;
      issue_plain(FX_FLDCW, '0, '0, 1'b0, {64'd0, control}, 4'd2,
                  {label, ": FLDCW"});
      if (new_fctrl !== control || old_fctrl !== control)
        $fatal(1, "%s: control word did not commit", label);
    end
  endtask

  task automatic load80(input logic [79:0] value, input string label);
    issue_plain(FX_FLD_M80, '0, '0, 1'b0, value, 4'd10, label);
  endtask

  task automatic run_matrix_case(input logic [1:0] rc, input logic [1:0] pc);
    string label;
    begin
      label = $sformatf("rc=%0d pc=%0d", rc, pc);

      init_control(rc, pc, {label, ": fdiv"});
      load80(FP_THREE, {label, ": fdiv divisor"});
      load80(FP_FIVE, {label, ": fdiv dividend"});
      issue_direct_srt(FX_AR_ST0_STI, 3'd6, 3'd1, 2'd0, rc, pc,
                       FP_FIVE, FP_THREE,
                       {label, ": FDIV"});

      init_control(rc, pc, {label, ": reverse-fdiv"});
      load80(FP_FIVE, {label, ": reverse-fdiv ST1"});
      load80(FP_THREE, {label, ": reverse-fdiv ST0"});
      // Source operands are ST1=5/ST0=3.  ALU op 7 swaps alu_a/alu_b, so
      // the actual SRT request must be exactly 3/5, not merely A/B-equal.
      issue_direct_srt(FX_AR_STI_ST0, 3'd7, 3'd1, 2'd0, rc, pc,
                       FP_THREE, FP_FIVE,
                       {label, ": reverse FDIV"});

      init_control(rc, pc, {label, ": sqrt"});
      load80(FP_TWO, {label, ": sqrt operand"});
      issue_direct_srt(FX_FSQRT, '0, '0, 2'd1, rc, pc, FP_TWO, 80'd0,
                       {label, ": FSQRT"});

      init_control(rc, pc, {label, ": fprem"});
      load80(FP_THREE, {label, ": fprem divisor"});
      load80(FP_FIVE, {label, ": fprem dividend"});
      issue_direct_srt(FX_FPREM, '0, '0, 2'd2, rc, pc, FP_FIVE, FP_THREE,
                       {label, ": FPREM"});

      init_control(rc, pc, {label, ": fprem1"});
      load80(FP_THREE, {label, ": fprem1 divisor"});
      load80(FP_FIVE, {label, ": fprem1 dividend"});
      issue_direct_srt(FX_FPREM1, '0, '0, 2'd2, rc, pc, FP_FIVE, FP_THREE,
                       {label, ": FPREM1"});

      init_control(rc, pc, {label, ": fpatan-far"});
      load80(FP_ONE, {label, ": fpatan y"});
      load80(FP_ATAN_FAR_X, {label, ": fpatan x"});
      // Far FPATAN keeps RC but temporarily forces PC=64 for the borrow.
      issue_trans_srt(FX_FPATAN, rc, 2'b11, {label, ": FPATAN far-ratio"});

      init_control(rc, pc, {label, ": fptan"});
      load80(FP_1P5, {label, ": fptan nonzero"});
      // FPTAN's later quotient retains live control-word RC/PC.
      issue_trans_srt(FX_FPTAN, rc, pc, {label, ": FPTAN nonzero"});
      matrix_cases++;
    end
  endtask

  initial begin
    cmd_valid = 1'b0;
    drive_command(FX_NONE, '0, '0, 1'b0, '0, '0);
    checks = 0;
    matrix_cases = 0;
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);
    for (int rc = 0; rc < 4; rc++)
      for (int pc = 0; pc < 4; pc++)
        if (pc != 1)
          run_matrix_case(rc[1:0], pc[1:0]);
    if (matrix_cases != 12)
      $fatal(1, "matrix cardinality mismatch: %0d", matrix_cases);
    if (checks != 396)
      $fatal(1, "check cardinality mismatch: %0d", checks);
    $display("FP-SRT-TOP-AB-OK matrix=12 checks=396");
    $finish;
  end
endmodule

`default_nettype wire
