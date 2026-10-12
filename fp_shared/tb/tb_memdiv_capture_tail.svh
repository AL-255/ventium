  // The runner prepends the original gate's complete port declarations and
  // old/new instances. Only the new instance gets an unaccepted busy command.
  logic busy_noise = 0;
  logic register_phase = 1;
  int mem_cases = 0, delayed_cases = 0, special_cases = 0, fault_cases = 0;
  int reset_cases = 0, commands = 0, starts_checked = 0;
  logic test_bug = 0;
  logic [31:0] noise = 32'hc001d00d;

  function automatic logic [1418:0] old_arch();
    return {old_ftop, old_fstat, old_fctrl, old_fptag, old_fip, old_fcs,
            old_fdp, old_fds, old_phys_flat, old_st_flat};
  endfunction
  function automatic logic [1418:0] new_arch();
    return {new_ftop, new_fstat, new_fctrl, new_fptag, new_fip, new_fcs,
            new_fdp, new_fds, new_phys_flat, new_st_flat};
  endfunction
  function automatic logic [976:0] old_response();
    return {old_rsp_unsupported, old_rsp_stack_fault, old_rsp_arith,
            old_rsp_store_valid, old_rsp_store_data, old_rsp_store_bytes,
            old_rsp_ax_valid, old_rsp_ax};
  endfunction
  function automatic logic [976:0] new_response();
    return {new_rsp_unsupported, new_rsp_stack_fault, new_rsp_arith,
            new_rsp_store_valid, new_rsp_store_data, new_rsp_store_bytes,
            new_rsp_ax_valid, new_rsp_ax};
  endfunction

  task automatic drive(input fxop_e op, input logic [2:0] subop,
      input logic pop, input logic [79:0] mem, input logic [3:0] bytes);
    cmd_op = op; cmd_aluop = subop; cmd_sti = 1; cmd_pop = pop;
    cmd_constant = 0; cmd_mem = mem; cmd_mem_bytes = bytes;
    cmd_fdiv_bug = test_bug; cmd_fist_bug = 0; cmd_env16 = 0;
    cmd_real_mode = 0; cmd_env_image = 0;
    cmd_update_fip = 1; cmd_fip = 32'h10203040 + 32'(commands);
    cmd_fcs = 16'h2468; cmd_update_fdp = 1;
    cmd_fdp = 32'habcd1234 - 32'(commands); cmd_fds = 16'h4321;
  endtask

  task automatic poison();
    noise = {noise[30:0], noise[31]^noise[21]^noise[1]^noise[0]};
    cmd_op = noise[0] ? FX_FSQRT : FX_FPREM1;
    cmd_mem = {noise[15:0], noise ^ 32'h13579bdf, ~noise};
    cmd_mem_bytes = noise[1] ? 2 : 8;
    cmd_aluop = ~cmd_aluop; cmd_sti = ~cmd_sti; cmd_pop = ~cmd_pop;
    cmd_fdiv_bug = ~cmd_fdiv_bug;
    cmd_update_fip = ~cmd_update_fip; cmd_fip = noise; cmd_fcs = noise[15:0];
    cmd_update_fdp = ~cmd_update_fdp; cmd_fdp = ~noise; cmd_fds = ~noise[15:0];
  endtask

  task automatic run_command(input fxop_e op, input logic [2:0] subop,
      input logic pop, input logic [79:0] mem, input logic [3:0] bytes,
      input logic memory_divide);
    logic delayed, fault, special, was_start;
    logic [79:0] operand_a, operand_b;
    logic [1:0] control_rc, control_pc;
    logic [1418:0] completed_arch;
    logic [976:0] completed_response;
    logic [1322:0] initial_state;
    int old_age, new_age, age;
    @(negedge clk); #1;
    if (!old_cmd_ready || !new_cmd_ready || old_rsp_valid || new_rsp_valid)
      $fatal(1, "MEMDIV_READY command=%0d", commands);
    drive(op, subop, pop, mem, bytes); cmd_valid = 1;
    #1;
    fault = old_dut.issue_stack_fault;
    delayed = memory_divide && !fault;
    special = memory_divide && old_dut.div_special_hit;
    was_start = old_dut.srt_start;
    operand_a = old_dut.srt_a; operand_b = old_dut.srt_b;
    control_rc = old_dut.srt_rc; control_pc = old_dut.srt_pc;
    initial_state = {new_ftop, new_fstat, new_fctrl, new_fptag,
                     new_phys_flat, new_st_flat};
    if (old_cmd_accept_retire !== new_cmd_accept_retire ||
        new_dut.issue_stack_fault !== fault)
      $fatal(1, "MEMDIV_ADMISSION command=%0d", commands);
    if (delayed && (new_cmd_accept_retire || new_dut.srt_start))
      $fatal(1, "MEMDIV_EARLY_START command=%0d", commands);
    old_age = -1; new_age = -1;
    for (age = 0; age < 20000; age++) begin
      @(posedge clk); #1;
      cmd_valid = 0;
      if (old_rsp_valid) begin
        if (old_age != -1) $fatal(1, "MEMDIV_DUPLICATE_OLD");
        old_age = age; completed_arch = old_arch();
        completed_response = old_response();
      end
      if (new_rsp_valid) begin
        if (new_age != -1) $fatal(1, "MEMDIV_DUPLICATE_NEW");
        new_age = age;
        if (old_age == -1 || new_arch() !== completed_arch ||
            new_response() !== completed_response)
          $fatal(1, "MEMDIV_ARCH command=%0d op=%0d sub=%0d old_age=%0d new_age=%0d", commands, op, subop, old_age, age);
      end
      if (delayed && !new_rsp_valid) begin
        if (!new_busy || new_cmd_ready || new_cmd_accept_retire ||
            {new_ftop, new_fstat, new_fctrl, new_fptag,
             new_phys_flat, new_st_flat} !== initial_state)
          $fatal(1, "MEMDIV_PREMATURE_COMMIT command=%0d age=%0d", commands, age);
      end
      if (!delayed && (old_arch() !== new_arch() ||
          {old_rsp_valid, old_cmd_ready, old_busy, old_alu_commit_retire} !==
          {new_rsp_valid, new_cmd_ready, new_busy, new_alu_commit_retire}))
        $fatal(1, "MEMDIV_UNCHANGED_LATENCY command=%0d age=%0d", commands, age);
      if (new_age != -1) break;
      @(negedge clk);
      poison(); busy_noise = 1;
      #1;
      if (delayed && age == 0) begin
        if (new_dut.srt_start !== was_start ||
            (was_start && ({new_dut.srt_a, new_dut.srt_b, new_dut.srt_mode,
                           new_dut.srt_rc, new_dut.srt_pc} !==
                          {operand_a, operand_b, 2'd0, control_rc, control_pc})))
          $fatal(1, "MEMDIV_CAPTURE command=%0d", commands);
        if (was_start) starts_checked++;
      end
    end
    busy_noise = 0;
    if (old_age == -1 || new_age != old_age + int'(delayed))
      $fatal(1, "MEMDIV_LATENCY command=%0d old=%0d new=%0d expected_delta=%0d", commands, old_age, new_age, delayed);
    if (memory_divide) begin
      mem_cases++; delayed_cases += int'(delayed);
      special_cases += int'(special && !fault); fault_cases += int'(fault);
    end
    commands++;
    @(negedge clk); #1;
    @(posedge clk); #1;
    if (old_rsp_valid || new_rsp_valid || old_arch() !== new_arch())
      $fatal(1, "MEMDIV_RESPONSE_PULSE command=%0d", commands);
  endtask

  task automatic initialize(input logic [1:0] rc, input logic [1:0] pc,
      input logic masked);
    logic [15:0] control;
    run_command(FX_FNINIT, 0, 0, 0, 0, 0);
    control = 16'h007f; control[11:10] = rc; control[9:8] = pc;
    control[0] = masked;
    run_command(FX_FLDCW, 0, 0, {64'd0,control}, 2, 0);
  endtask

  function automatic logic [79:0] top_value(input int pattern);
    case (pattern)
       0: return FP_FIVE;
       1: return 80'd0;
       2: return 80'h80000000000000000000;
       3: return 80'h7fff8000000000000000;
       4: return 80'hffff8000000000000000;
       5: return 80'h7fffc123456789abcdef;
       6: return 80'h7fff8123456789abcdef;
       7: return 80'h00000000000000000001;
       8: return 80'h00017fffffffffffffff;
       9: return 80'h7ffeffffffffffffffff;
      10: return 80'hbfff8000000000000000;
      11: return 80'h3ffeaaaaaaaaaaaaaaaa;
      12: return 80'h00018000000000000000;
      13: return 80'h00008000000000000000;
      14: return 80'h401540be1a0000000000;
      default: return FP_THREE;
    endcase
  endfunction

  function automatic logic [79:0] memory_value(input int format, input int pattern);
    logic [63:0] bits64;
    logic [31:0] bits32;
    case (pattern)
       0: begin bits64=64'h4008000000000000; bits32=32'h40400000; end
       1: begin bits64=0; bits32=0; end
       2: begin bits64=64'h8000000000000000; bits32=32'h80000000; end
       3: begin bits64=64'h7ff0000000000000; bits32=32'h7f800000; end
       4: begin bits64=64'hfff0000000000000; bits32=32'hff800000; end
       5: begin bits64=64'h7ff8123456789abc; bits32=32'h7fc12345; end
       6: begin bits64=64'h7ff0123456789abc; bits32=32'h7f812345; end
       7: begin bits64=1; bits32=1; end
       8: begin bits64=64'h000fffffffffffff; bits32=32'h007fffff; end
       9: begin bits64=64'h7fefffffffffffff; bits32=32'h7f7fffff; end
      10: begin bits64=64'hbff0000000000000; bits32=32'hbf800000; end
      11: begin bits64=64'h3fd5555555555555; bits32=32'h3eaaaaab; end
      12: begin bits64=64'h0010000000000000; bits32=32'h00800000; end
      13: begin bits64=64'h8000000000000001; bits32=32'h80000001; end
      14: begin bits64=64'h415300c900000000; bits32=32'h4a180648; end
      default: begin bits64=64'h3ff8000000000000; bits32=32'h3fc00000; end
    endcase
    if (format == 0) return {48'hacceded12345,bits32};
    if (format == 1) return {16'habcd,bits64};
    // Exercise signed min/max, negative, zero and upper non-operand garbage.
    if (pattern == 0) bits32 = 3;
    if (pattern == 1) bits32 = 0;
    if (pattern == 2) bits32 = 32'h80008000;
    if (pattern == 3) bits32 = 32'h7fff7fff;
    if (pattern == 4) bits32 = 32'hffffffff;
    if (pattern == 5) bits32 = 32'h80000000;
    if (pattern == 6) bits32 = 32'h7fffffff;
    return {48'h123456abcdef,bits32};
  endfunction

  task automatic reset_test(input int phase);
    initialize(0,3,1);
    run_command(FX_FLD_M80,0,0,FP_FIVE,10,0);
    @(negedge clk); drive(FX_AR_M32,6,0,80'h40400000,4); cmd_valid=1;
    @(posedge clk); #1; cmd_valid=0;
    repeat (phase) @(posedge clk);
    @(negedge clk); rst_n=0; busy_noise=0; poison();
    repeat (2) @(posedge clk);
    @(negedge clk); rst_n=1;
    repeat (70) begin
      @(posedge clk); #1;
      if (old_rsp_valid || new_rsp_valid || old_busy || new_busy ||
          !old_cmd_ready || !new_cmd_ready || old_arch() !== new_arch())
        $fatal(1,"MEMDIV_RESET phase=%0d", phase);
    end
    reset_cases++;
  endtask

  initial begin
    run_register_matrix();
    register_phase=0;
    for (int format=0; format<4; format++) begin
      automatic fxop_e op = (format==0) ? FX_AR_M32 :
          (format==1) ? FX_AR_M64 : (format==2) ? FX_AR_I16 : FX_AR_I32;
      automatic logic [3:0] bytes = (format==1) ? 8 : (format==2) ? 2 : 4;
      for (int rc=0; rc<4; rc++) for (int pc=0; pc<4; pc++)
      for (int reverse_div=0; reverse_div<2; reverse_div++)
      for (int buggy=0; buggy<2; buggy++) for (int pop=0; pop<2; pop++)
      for (int pattern=0; pattern<16; pattern++) begin
        test_bug = 1'(buggy);
        initialize(2'(rc),2'(pc),1);
        run_command(FX_FLD_M80,0,0,top_value(pattern),10,0);
        run_command(op, reverse_div ? 7 : 6, 1'(pop),
                    memory_value(format,(pattern+7)%16),bytes,1);
      end
      for (int masked=0; masked<2; masked++)
      for (int reverse_div=0; reverse_div<2; reverse_div++) begin
        initialize(0,3,1'(masked));
        run_command(op,reverse_div ? 7 : 6,1,memory_value(format,0),bytes,1);
      end
    end
    for (int phase=0; phase<4; phase++) reset_test(phase*8);
    if (mem_cases != 8208 || delayed_cases != 8192 || fault_cases != 16 ||
        special_cases == 0 || starts_checked == 0 || reset_cases != 4)
      $fatal(1,"MEMDIV_COVERAGE mem=%0d delayed=%0d fault=%0d special=%0d starts=%0d resets=%0d",
          mem_cases,delayed_cases,fault_cases,special_cases,starts_checked,reset_cases);
    $display("MEMDIV-CAPTURE-OK mem=%0d delayed=%0d fault=%0d special=%0d starts=%0d resets=%0d commands=%0d",
        mem_cases,delayed_cases,fault_cases,special_cases,starts_checked,reset_cases,commands);
    $finish;
  end
endmodule
`default_nettype wire
