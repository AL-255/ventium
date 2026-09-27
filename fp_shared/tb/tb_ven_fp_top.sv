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

  logic cmd_valid, cmd_ready, cmd_accept_retire, alu_commit_retire;
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

`ifdef VEN_FP_FXCH_QUEUE
  ven_fp_fxch_queue dut (
`else
  ven_fp_top dut (
`endif
      .clk(clk), .rst_n(rst_n),
      .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
      .cmd_accept_retire(cmd_accept_retire), .alu_commit_retire(alu_commit_retire),
      .cmd_op(cmd_op),
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

  // A normal shared-ALU result still commits through the ordinary TOP_ALU
  // state-file edge.  The adapter-facing pulse is deliberately one edge ahead
  // of rsp_valid, allowing the core to retire *with* that commit rather than
  // one clock after it.  Check both sides of the edge here so a later change
  // cannot accidentally turn this into an early data/result bypass.
  task automatic issue_fast_add_with_commit_token;
    int waited;
    begin
      while (!cmd_ready) @(negedge clk);
      @(negedge clk);
      cmd_valid     = 1'b1;
      cmd_op        = FX_AR_ST0_STI;
      cmd_aluop     = 3'd0;
      cmd_sti       = 3'd1;
      cmd_pop       = 1'b0;
      cmd_mem       = '0;
      cmd_mem_bytes = '0;
      @(negedge clk);
      cmd_valid = 1'b0;

      waited = 0;
      while (!alu_commit_retire && waited < 8) begin
        if (rsp_valid)
          $fatal(1, "normal ALU rsp_valid preceded commit-token");
        waited++;
        @(negedge clk);
      end
      if (!alu_commit_retire)
        $fatal(1, "normal ALU did not produce its registered commit-token");
      if (rsp_valid)
        $fatal(1, "normal ALU token overlapped rsp_valid instead of leading it");
      if (st_flat[79:0] !== FP_ONE)
        $fatal(1, "normal ALU result became visible before its commit edge");

      @(negedge clk);
      if (alu_commit_retire)
        $fatal(1, "normal ALU commit-token was not one cycle wide");
      if (!rsp_valid)
        $fatal(1, "normal ALU did not retain the registered rsp_valid contract");
      if (st_flat[79:0] !== FP_THREE)
        $fatal(1, "normal ALU result did not commit alongside the response edge");
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

  // A masked stack underflow must materialize a real-indefinite result in a
  // *valid* stack slot.  Checking data alone is insufficient: an empty slot
  // can retain the same stale bits and a subsequent x87 read would synthesize
  // another indefinite response.  Keep this leaf-level assertion beside the
  // system FXAM gate so both the state-file contract and core integration are
  // protected.
  task automatic expect_st_valid(
      input logic [2:0] idx,
      input string label
  );
    logic [2:0] phys;
    begin
      phys = ftop + idx;
      if (fptag[phys] !== 1'b0)
        $fatal(1, "%s expected ST(%0d) valid at physical slot %0d, tag=%02h",
               label, idx, phys, fptag);
    end
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

  // Keep the producer continuously ready: independent destinations ST(1..6)
  // all read the unchanged ST(0), with no pop/control-word mutation. This
  // characterizes dispatcher throughput independently of the arithmetic leaf.
  task automatic independent_arithmetic_throughput;
    int accepted, completed, cycles, first_accept, last_accept, peak_pending;
    logic [79:0] expected;
    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    repeat (8) load80(FP_TWO);
    @(negedge clk); // discard the final immediate-load response
    accepted=0; completed=0; cycles=0; first_accept=-1; last_accept=-1;
    peak_pending=0;
    while (completed < 6) begin
      cmd_valid = accepted < 6;
      cmd_op = FX_AR_STI_ST0;
      cmd_sti = 3'(accepted+1);
      cmd_pop = 0;
      case (accepted % 4)
        0: cmd_aluop=0;
        1: cmd_aluop=1;
        2: cmd_aluop=4;
        3: cmd_aluop=5;
      endcase
      @(posedge clk);
      if (cmd_valid && cmd_ready) begin
        if (first_accept < 0) first_accept=cycles;
        last_accept=cycles;
        accepted++;
        if (accepted-completed > peak_pending) peak_pending=accepted-completed;
      end
      @(negedge clk);
      if (rsp_valid) begin
        if (completed >= accepted || rsp_unsupported || rsp_stack_fault ||
            rsp_store_valid || rsp_ax_valid || rsp_arith[84:80] != 0)
          $fatal(1, "independent FP response ownership/payload");
        expected = ((completed % 4) < 2) ? FP_FOUR : FP_ZERO;
        if (rsp_arith[79:0] !== expected ||
            st_flat[(completed+1)*80 +: 80] !== expected)
          $fatal(1, "independent FP result/physical destination %0d", completed+1);
        completed++;
      end
      cycles++;
      if (cycles > 128) $fatal(1, "independent FP throughput watchdog");
    end
    cmd_valid=0;
    repeat (3) begin
      @(negedge clk);
      if (rsp_valid) $fatal(1, "duplicate independent FP response");
    end
    if (ftop !== 0 || fptag !== 0 || st_flat[79:0] !== FP_TWO ||
        st_flat[639:560] !== FP_TWO || fstat !== 0 || fctrl !== 16'h037f)
      $fatal(1, "independent FP corrupted untouched architectural state");
    $display("FP-INDEPENDENT-THROUGHPUT accepted=%0d responses=%0d clocks=%0d acceptance_span=%0d peak_pending=%0d",
             accepted, completed, cycles, last_accept-first_accept, peak_pending);
    // An explicit acceptance criterion, not a correctness pass for today's
    // serialized baseline. Future pipelined implementations must pass both.
    if ($test$plusargs("require_fp_pipeline") &&
        ((last_accept-first_accept != 5) || (peak_pending < 2)))
      $fatal(1, "FP pipeline throughput requirement unmet");
    $display("FP-INDEPENDENT-VALUES-OK");
`ifdef VEN_FP_PERF
    if (dut.fp_perf_accept[1] != 6 || dut.fp_perf_latency[1] != 24)
      $fatal(1, "overlapping FP performance attribution lost an owner");
`endif
  endtask

  // Admission may overlap, but architectural snapshots must remain ordered:
  // the arithmetic response sees its original logical destination, and only
  // the following FXCH response sees the swapped stack. A live-file swap at
  // queue acceptance would fail this even if the eventual numeric sum is right.
  task automatic queued_fxch_contract(input bit divide, input bit unmasked=0,
                                     input bit empty_partner=0);
    int accepted, completed, cycles, exchange_accept, arithmetic_response;
    logic [79:0] arithmetic_result;
    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    load80(FP_TWO); load80(FP_ONE);
    if(unmasked) issue(FX_FLDCW, 0, 0, 0, 80'h037e, 2, 0, 0);
    @(negedge clk);
    arithmetic_result = divide ? 80'h3ffe8000000000000000 : FP_THREE;
    accepted=0; completed=0; cycles=0;
    exchange_accept=-1; arithmetic_response=-1;
    while(completed<2) begin
      cmd_valid=(accepted<2);
      cmd_op=(accepted==0) ? FX_AR_ST0_STI : FX_FXCH;
      cmd_aluop=divide ? 3'd6 : 3'd0;
      cmd_sti=(accepted==0) ? 3'd1 :
              ((accepted==1) ? (empty_partner ? 3'd2 : 3'd1) : 3'd7);
      cmd_pop=0;
      cmd_update_fip=(accepted<2); cmd_update_fdp=(accepted<2);
      cmd_fip=(accepted==0) ? 32'h1110 : ((accepted==1) ? 32'h2220 : 32'hdeadbeef);
      cmd_fdp=(accepted==0) ? 32'h3330 : ((accepted==1) ? 32'h4440 : 32'hcafebabe);
      cmd_fcs=16'h1234; cmd_fds=16'h5678;
      @(posedge clk);
      if(cmd_valid && cmd_ready) begin
        if(accepted==1) exchange_accept=cycles;
        accepted++;
      end
      @(negedge clk);
      if(rsp_valid) begin
        if(completed>=accepted || rsp_unsupported ||
           rsp_stack_fault !== (empty_partner && completed==1) ||
           rsp_store_valid || rsp_ax_valid) $fatal(1,"FXCH queue response ownership");
        if(completed==0) begin
          arithmetic_response=cycles;
          if(st_flat[79:0] !== arithmetic_result || st_flat[159:80] !== FP_TWO)
            $fatal(1,"FXCH changed architectural stack before its response");
          if(fip!==32'h1110 || fdp!==32'h3330)
            $fatal(1,"queued metadata committed before its owner");
        end else begin
          if(empty_partner) begin
            if(st_flat[79:0] !== FP_INDEF || st_flat[159:80] !== FP_TWO ||
               st_flat[239:160] !== arithmetic_result)
              $fatal(1,"queued empty FXCH lost ordered result or indefinite");
            expect_st_valid(0,"queued empty FXCH ST0");
            expect_st_valid(2,"queued empty FXCH ST2");
          end else if(st_flat[79:0] !== FP_TWO || st_flat[159:80] !== arithmetic_result)
            $fatal(1,"FXCH result routed to wrong logical destination");
          if(fip!==32'h2220 || fdp!==32'h4440 || fcs!==16'h1234 || fds!==16'h5678)
            $fatal(1,"queued FXCH metadata not retained");
        end
        completed++;
      end
      if(++cycles>128) $fatal(1,"FXCH queue timeout");
    end
    cmd_valid=0; cmd_update_fip=0; cmd_update_fdp=0;
    repeat(3) begin @(negedge clk); if(rsp_valid) $fatal(1,"duplicate FXCH response"); end
    if(ftop!==6 || (fstat & 16'h82c1)!==(empty_partner ? 16'h0041 : 16'h0000) ||
       fstat[7:0]!==(empty_partner ? 8'h41 : 8'h00) ||
       fptag!==(empty_partner ? 8'h3e : 8'h3f) ||
       fctrl!==(unmasked ? 16'h037e : 16'h037f))
      $fatal(1,"FXCH queue corrupted environment");
    $display("FP-FXCH-ORDER-OK divide=%0d empty=%0d fxch_accept=%0d arithmetic_response=%0d clocks=%0d",
             divide,empty_partner,exchange_accept,arithmetic_response,cycles);
    if(unmasked && exchange_accept<arithmetic_response)
      $fatal(1,"FXCH queued across unmasked exception mode");
    if($test$plusargs("require_fxch_queue") && !unmasked && exchange_accept>=arithmetic_response)
      $fatal(1,"FXCH early-admission requirement unmet");
  endtask

`ifdef VEN_FP_FXCH_QUEUE
  task automatic cancel_queued_fxch;
    issue(FX_FNINIT,0,0,0,'0,0,0,0);
    load80(FP_TWO); load80(FP_ONE);
    @(negedge clk); cmd_valid=1; cmd_op=FX_AR_ST0_STI; cmd_sti=1; cmd_aluop=6; cmd_pop=0;
    @(posedge clk); if(!cmd_ready) $fatal(1,"reset probe divide not accepted");
    @(negedge clk); cmd_op=FX_FXCH;
    @(posedge clk); if(!cmd_ready) $fatal(1,"reset probe exchange not queued");
    @(negedge clk); cmd_valid=0; rst_n=0;
    repeat(3) @(negedge clk);
    rst_n=1;
    repeat(48) begin
      @(negedge clk);
      if(rsp_valid || busy) $fatal(1,"reset resurrected a queued FP owner");
    end
    if(ftop!==0 || fptag!==8'hff || fctrl!==16'h037f)
      $fatal(1,"queued reset environment");
    $display("FP-FXCH-QUEUE-RESET-OK");
  endtask
`endif

  task automatic arithmetic_interlock(input int kind);
    int waited;
    logic [79:0] expected;
    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    repeat (8) load80(FP_TWO);
    if (kind == 4) issue(FX_FLDCW, 0, 0, 0, 80'h037e, 2, 0, 0);
    @(negedge clk);
    cmd_valid=1; cmd_op=FX_AR_STI_ST0; cmd_aluop=0; cmd_sti=1;
    cmd_pop=(kind == 3);
    @(posedge clk);
    if (!cmd_ready) $fatal(1, "interlock first command not accepted");
    @(negedge clk);
    cmd_op = (kind == 2) ? FX_FXCH :
             ((kind == 0 || kind == 3) ? FX_AR_ST0_STI : FX_AR_STI_ST0);
    cmd_sti = (kind >= 4) ? 2 : 1;
    cmd_pop = (kind == 5);
    // Allow combinational decode of the new command before observing ready.
    #1;
    if (cmd_ready) $fatal(1, "missing arithmetic interlock kind=%0d",kind);
    waited=0;
    while (!cmd_ready) begin
      @(negedge clk);
      waited++;
      if (waited > 16) $fatal(1, "arithmetic interlock failed to drain");
    end
    if (!rsp_valid || rsp_arith[79:0] !== FP_FOUR)
      $fatal(1, "interlock released without first architectural result");
    @(posedge clk);
    @(negedge clk); cmd_valid=0;
    waited=0;
    while (!rsp_valid) begin
      @(negedge clk);
      if (++waited > 16) $fatal(1, "second interlocked response missing");
    end
    if (rsp_unsupported || rsp_stack_fault) $fatal(1, "interlock response fault");
    expected = (kind == 2 || kind >= 4) ? FP_FOUR : FP_SIX;
    if (kind == 1 || kind == 5) begin
      if (st_flat[159:80] !== expected) $fatal(1, "interlock destination ST1");
    end else if (kind == 4) begin
      if (st_flat[239:160] !== expected) $fatal(1, "unmasked drain destination");
    end else if (st_flat[79:0] !== expected)
      $fatal(1, "interlock destination ST0 kind=%0d",kind);
    if (ftop !== ((kind == 3 || kind == 5) ? 3'd1 : 3'd0))
      $fatal(1, "interlock stack order kind=%0d",kind);
    $display("FP-ARITH-INTERLOCK-OK kind=%0d",kind);
  endtask

`ifdef VEN_FP_ARITH_STREAM
  task automatic reset_arithmetic_owners;
    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    repeat (8) load80(FP_TWO);
    @(negedge clk);
    for (int i=1; i<=3; i++) begin
      cmd_valid=1; cmd_op=FX_AR_STI_ST0; cmd_aluop=0;
      cmd_sti=3'(i); cmd_pop=0;
      @(posedge clk);
      if (!cmd_ready) $fatal(1, "reset fixture failed to fill arithmetic pipeline");
      @(negedge clk);
    end
    // All three stages own work; reset wins over the oldest result's commit.
    rst_n=0; cmd_valid=0;
    repeat (2) @(negedge clk);
    rst_n=1;
    repeat (5) begin
      @(negedge clk);
      if (rsp_valid || busy || !cmd_ready || alu_commit_retire)
        $fatal(1, "arithmetic owner survived reset");
    end
    if ({ftop,fstat,fctrl,fptag} !== {3'd0,16'h0000,16'h037f,8'hff})
      $fatal(1, "arithmetic reset state mismatch");
    $display("FP-ARITH-RESET-OK");
  endtask
`endif

  function automatic logic [79:0] stream_operand(input int n);
    case (n % 12)
      0: return FP_ZERO;
      1: return 80'h80000000000000000000;
      2: return FP_ONE;
      3: return FP_NEG1;
      4: return FP_1P5;
      5: return 80'h00000000000000000001;
      6: return 80'h7ffeffffffffffffffff;
      7: return 80'h00018000000000000000;
      8: return 80'h7fff8000000000000001;
      9: return 80'h7fffc000000000000123;
      10: return FP_INF;
      default: return 80'h3ffdaaaaaaaaaaaaaaab;
    endcase
  endfunction

  // Sequential architectural oracle at each accepted command, with snapshots
  // queued until the corresponding response. The DUT may overlap independent
  // commands, but cannot change their values, order, flags or destinations.
  task automatic mixed_arithmetic_stream(input int rc, input int pc, input int seed);
    logic [639:0] spec_regs, expected_regs[64];
    logic [15:0] spec_status, expected_status[64], control_word;
    logic [84:0] expected_result[64];
    logic [79:0] a, b;
    logic [31:0] choice;
    int accepted, completed, cycles, dst;
    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    spec_regs='0;
    for (int i=7; i>=0; i--) begin
      load80(stream_operand(seed+i));
      spec_regs[i*80 +: 80]=stream_operand(seed+i);
    end
    control_word=16'h007f | (16'(pc) << 8) | (16'(rc) << 10);
    issue(FX_FLDCW, 0, 0, 0, {64'd0,control_word}, 2, 0, 0);
    @(negedge clk);
    spec_status=0; accepted=0; completed=0; cycles=0;
    while (completed < 64) begin
      choice=32'(accepted+1) * 32'h9e3779b9 ^ (32'(seed+1) * 32'h85ebca6b);
      choice=choice ^ (choice >> 13);
      cmd_valid=(accepted < 64) && ((cycles % 7) != 3);
      cmd_sti=choice[2:0]; cmd_pop=0;
      case (choice[4:3])
        0: cmd_aluop=0;
        1: cmd_aluop=1;
        2: cmd_aluop=4;
        3: cmd_aluop=5;
      endcase
      cmd_op=choice[5] ? FX_AR_STI_ST0 : FX_AR_ST0_STI;
      // Alternate register operations with real64 and signed integer32 sources.
      cmd_mem=0; cmd_mem_bytes=0;
      if (choice[7:6] == 2) begin
        cmd_op=FX_AR_M64; cmd_mem_bytes=8;
        cmd_mem={16'd0,choice[8],11'h3ff,20'habcde,choice};
      end else if (choice[7:6] == 3) begin
        cmd_op=FX_AR_I32; cmd_mem_bytes=4; cmd_mem={48'd0,choice};
      end
      @(posedge clk);
      if (cmd_valid && cmd_ready) begin
        dst=(cmd_op == FX_AR_STI_ST0) ? int'(cmd_sti) : 0;
        a=spec_regs[0 +: 80]; b=spec_regs[int'(cmd_sti)*80 +: 80];
        if (cmd_op == FX_AR_STI_ST0) begin
          a=spec_regs[int'(cmd_sti)*80 +: 80]; b=spec_regs[0 +: 80];
        end else if (cmd_op == FX_AR_M64)
          b=ventium_x87_pkg::f_mem_as_float(cmd_mem,cmd_mem_bytes);
        else if (cmd_op == FX_AR_I32)
          b=ventium_x87_pkg::f_mem_as_int(cmd_mem,cmd_mem_bytes);
        expected_result[accepted]=ventium_x87_pkg::f_eval(cmd_aluop,a,b,2'(rc),2'(pc),0);
        spec_regs[dst*80 +: 80]=expected_result[accepted][79:0];
        spec_status=ventium_x87_pkg::f_arith_fstat(spec_status,expected_result[accepted]);
        expected_regs[accepted]=spec_regs;
        expected_status[accepted]=spec_status;
        accepted++;
      end
      @(negedge clk);
      if (rsp_valid) begin
        if (completed >= accepted || rsp_unsupported || rsp_stack_fault ||
            rsp_store_valid || rsp_ax_valid || rsp_arith !== expected_result[completed] ||
            st_flat !== expected_regs[completed] || fstat !== expected_status[completed] ||
            fctrl !== control_word || ftop !== 0 || fptag !== 0)
          $fatal(1, "mixed FP stream mismatch seed=%0d rc=%0d pc=%0d response=%0d arith=%022x expected=%022x",
                 seed,rc,pc,completed,rsp_arith,expected_result[completed]);
        completed++;
      end
      if (++cycles > 1024) $fatal(1, "mixed FP stream watchdog");
    end
    cmd_valid=0;
    repeat (3) begin
      @(negedge clk);
      if (rsp_valid) $fatal(1, "mixed FP stream duplicate response");
    end
    checks+=completed;
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

    if ($test$plusargs("fp_stream_mixed_only")) begin
      for (int rc=0; rc<4; rc++)
        for (int pc=0; pc<4; pc++)
          if (pc != 1)
            for (int seed=0; seed<12; seed++) mixed_arithmetic_stream(rc,pc,seed);
      $display("FP-MIXED-STREAM-OK checks=%0d (includes initialization commands)",checks);
      $finish;
    end

    if ($test$plusargs("fp_stack_queue_only")) begin
      queued_fxch_contract(0);
      queued_fxch_contract(1);
      queued_fxch_contract(1,1);
      queued_fxch_contract(0,0,1);
      queued_fxch_contract(1,0,1);
`ifdef VEN_FP_FXCH_QUEUE
      cancel_queued_fxch();
      queued_fxch_contract(0); // reuse after cancellation
`endif
      $display("FP-STACK-QUEUE-CONTRACT-OK");
      $finish;
    end

    if ($test$plusargs("fp_throughput_only")) begin
      independent_arithmetic_throughput();
      for (int kind=0; kind<6; kind++) arithmetic_interlock(kind);
      repeat (2) @(negedge clk); // performance observer consumes final response
`ifdef VEN_FP_ARITH_STREAM
      reset_arithmetic_owners();
      independent_arithmetic_throughput(); // clean reuse after cancel/reset
`endif
      $finish;
    end

    load80(FP_TWO);
    load80(FP_ONE);
    issue_fast_add_with_commit_token();
    expect_st0(FP_THREE, "1+2");

    load80(FP_TWO);
    issue(FX_AR_ST0_STI, 3'd1, 3'd1, 1'b0, '0, 0, 1'b0, 1);
    expect_st0(FP_SIX, "2*3");

    issue(FX_AR_ST0_STI, 3'd6, 3'd1, 1'b0, '0, 0, 1'b0, 30);
    expect_st0(FP_TWO, "6/3");

    // The core supplies m64real operands in f_mem80.  Keep a directed shell
    // check here: the arithmetic-unit test alone cannot catch a byte-width or
    // command-operand selection regression on the shared-FPU boundary.
    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    load80(FP_ONE);
    issue(FX_AR_M64, 3'd0, 3'd0, 1'b0,
          {16'd0,64'h3ff0000000000000}, 4'd8, 1'b0, 1);
    expect_st0(FP_TWO, "FADD m64real 1+1");

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
    expect_st_valid(3'd0, "masked empty arithmetic result");

    // DE-style destination/write followed by pop: ST(0) is live, ST(1) is
    // empty, so the real-indefinite written into ST(1) becomes the new ST(0).
    // This catches a data-only write that leaves the post-pop destination tag
    // EMPTY, the exact failure mode of REP-independent shared FPU state.
    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    load80(FP_ONE);
    issue(FX_AR_STI_ST0, 3'd0, 3'd1, 1'b1, '0, 0, 1'b0, 0);
    if (!rsp_stack_fault || st_flat[79:0] !== FP_INDEF || ftop !== 3'd0 ||
        (fstat & 16'h82c1) !== 16'h0041)
      $fatal(1, "masked DE-style arithmetic-pop response mismatch");
    expect_st_valid(3'd0, "masked DE-style post-pop destination");

    // FABS has an already-formed direct c_write before the stack-fault
    // override; it must receive the same valid-tag treatment as deferred
    // arithmetic.
    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    issue(FX_FABS, 0, 0, 0, '0, 0, 0, 0);
    if (!rsp_stack_fault || st_flat[79:0] !== FP_INDEF ||
        (fstat & 16'h82c1) !== 16'h0041)
      $fatal(1, "masked empty FABS response mismatch");
    expect_st_valid(3'd0, "masked empty FABS result");

    // FXCH has no normal result-write port: it is a map rename in the shared
    // state file.  A masked empty source is nevertheless architectural data,
    // not a tag-only event: load each empty operand with real-indefinite and
    // then exchange.  Exercise one empty partner, both empty partners, and
    // the aliased FXCH ST(0) form so a data-only or tag-only repair cannot
    // pass by accident.
    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    load80(FP_FOUR);
    issue(FX_FXCH, 0, 3'd1, 0, '0, 0, 0, 0);
    if (!rsp_stack_fault || st_flat[79:0] !== FP_INDEF ||
        st_flat[159:80] !== FP_FOUR || ftop !== 3'd7 ||
        (fstat & 16'h82c1) !== 16'h0041)
      $fatal(1, "masked FXCH one-empty response mismatch");
    expect_st_valid(3'd0, "masked FXCH one-empty ST0");
    expect_st_valid(3'd1, "masked FXCH one-empty ST1");

    // Reverse the empty/live direction.  This is not redundant with the
    // preceding case: a compact-map implementation can accidentally leave
    // the source's tag attached to its old physical bank, which only becomes
    // visible when the EMPTY operand started at ST(0).
    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    load80(FP_ONE);                      // ST(1), physical slot 7
    load80(FP_FOUR);                     // ST(0), physical slot 6
    issue(FX_FFREE, 0, 0, 0, '0, 0, 0, 0); // ST(0) EMPTY; ST(1) live
    issue(FX_FXCH, 0, 3'd1, 0, '0, 0, 0, 0);
    if (!rsp_stack_fault || st_flat[79:0] !== FP_ONE ||
        st_flat[159:80] !== FP_INDEF || ftop !== 3'd6 ||
        (fstat & 16'h82c1) !== 16'h0041)
      $fatal(1, "masked FXCH reverse-empty response mismatch");
    expect_st_valid(3'd0, "masked FXCH reverse-empty ST0");
    expect_st_valid(3'd1, "masked FXCH reverse-empty ST1");

    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    issue(FX_FXCH, 0, 3'd1, 0, '0, 0, 0, 0);
    if (!rsp_stack_fault || st_flat[79:0] !== FP_INDEF ||
        st_flat[159:80] !== FP_INDEF || ftop !== 3'd0 ||
        (fstat & 16'h82c1) !== 16'h0041)
      $fatal(1, "masked FXCH both-empty response mismatch");
    expect_st_valid(3'd0, "masked FXCH both-empty ST0");
    expect_st_valid(3'd1, "masked FXCH both-empty ST1");

    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    issue(FX_FXCH, 0, 3'd0, 0, '0, 0, 0, 0);
    if (!rsp_stack_fault || st_flat[79:0] !== FP_INDEF || ftop !== 3'd0 ||
        (fstat & 16'h82c1) !== 16'h0041)
      $fatal(1, "masked FXCH ST0 response mismatch");
    expect_st_valid(3'd0, "masked FXCH ST0 result");

    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    load80(FP_FOUR);
    issue(FX_FLDCW, 0, 0, 0, {64'd0,16'h037e}, 2, 0, 0);
    saved_st  = st_flat;
    saved_tag = fptag;
    saved_top = ftop;
    issue(FX_FXCH, 0, 3'd1, 0, '0, 0, 0, 0);
    // FXCH with an EMPTY operand is a stack *underflow*: SF/IE and the
    // unmasked ES/B summary set, but C1 remains clear (C1=1 is reserved for
    // stack overflow).  The data, tags and TOP must otherwise be untouched.
    if (!rsp_stack_fault || st_flat !== saved_st || fptag !== saved_tag ||
        ftop !== saved_top || (fstat & 16'h80c1) !== 16'h80c1)
      $fatal(1, "unmasked FXCH one-empty was not fully suppressed");

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
    load80(FP_ONE);                       // becomes ST(1)
    load80(FP_TWO);                       // ST(0), then deliberately empty it
    issue(FX_FFREE, 0, 0, 0, '0, 0, 0, 0);
    issue(FX_FSCALE, 0, 0, 0, '0, 0, 0, 0);
    if (!rsp_stack_fault || st_flat[79:0] !== FP_INDEF ||
        (fstat & 16'h0241) !== 16'h0041)
      $fatal(1, "fixed-ST1 masked underflow mismatch");
    expect_st_valid(3'd0, "fixed-ST1 masked result");

    // The fixed-ST1 transcendental shape writes ST(1) and then pops ST(0).
    // Its underflow shortcut is distinct from the normal ALU and direct top
    // write paths, so prove the new architectural ST(0) is valid as well.
    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    load80(FP_ONE);
    load80(FP_TWO);
    issue(FX_FFREE, 0, 0, 0, '0, 0, 0, 0);
    issue(FX_FPATAN, 0, 0, 0, '0, 0, 0, 0);
    if (!rsp_stack_fault || st_flat[79:0] !== FP_INDEF ||
        (fstat & 16'h0241) !== 16'h0041 || ftop !== 3'd7)
      $fatal(1, "fixed-ST1 masked arithmetic-pop mismatch");
    expect_st_valid(3'd0, "fixed-ST1 masked post-pop result");

    // The prior FPATAN case leaves the encoded destination (old ST(1))
    // live.  Reverse that condition so the write-before-pop path must clear
    // the formerly EMPTY destination tag; after the pop it becomes ST(0).
    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    load80(FP_ONE);                      // ST(1)
    load80(FP_TWO);                      // ST(0)
    issue(FX_FFREE, 0, 3'd1, 0, '0, 0, 0, 0); // destination ST(1) EMPTY
    issue(FX_FPATAN, 0, 0, 0, '0, 0, 0, 0);
    if (!rsp_stack_fault || st_flat[79:0] !== FP_INDEF ||
        (fstat & 16'h0241) !== 16'h0041 || ftop !== 3'd7)
      $fatal(1, "fixed-ST1 masked destination-empty arithmetic-pop mismatch");
    expect_st_valid(3'd0, "fixed-ST1 masked destination-empty post-pop result");

    // FSINCOS and FPTAN each have a two-result stack shape: their masked
    // empty-ST(0) response must materialize both logical results as VALID
    // real-indefinites.  These return directly from the stack-fault path, so
    // the check also proves neither iterative/transcendental engine was
    // accidentally allowed to consume stale empty-slot payloads.
    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    issue(FX_FSINCOS, 0, 0, 0, '0, 0, 0, 0);
    if (!rsp_stack_fault || st_flat[79:0] !== FP_INDEF ||
        st_flat[159:80] !== FP_INDEF || ftop !== 3'd7 ||
        (fstat & 16'h82c1) !== 16'h0041)
      $fatal(1, "masked empty FSINCOS response mismatch");
    expect_st_valid(3'd0, "masked FSINCOS ST0 result");
    expect_st_valid(3'd1, "masked FSINCOS ST1 result");

    issue(FX_FNINIT, 0, 0, 0, '0, 0, 0, 0);
    issue(FX_FPTAN, 0, 0, 0, '0, 0, 0, 0);
    if (!rsp_stack_fault || st_flat[79:0] !== FP_INDEF ||
        st_flat[159:80] !== FP_INDEF || ftop !== 3'd7 ||
        (fstat & 16'h82c1) !== 16'h0041)
      $fatal(1, "masked empty FPTAN response mismatch");
    expect_st_valid(3'd0, "masked FPTAN ST0 result");
    expect_st_valid(3'd1, "masked FPTAN ST1 result");

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
