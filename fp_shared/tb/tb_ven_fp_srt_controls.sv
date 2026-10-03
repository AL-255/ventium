`timescale 1ns/1ps
`default_nettype none

// Source-extracted selector equivalence only.  The runner writes this include
// from the pinned frozen/current ven_fp_top.sv files before compiling this TB.
// It does not instantiate the FPU, SRT arithmetic, queues, or architectural
// state.  A #1 settle point deliberately compares stable combinational values,
// not the different always_comb scheduling of the two factored forms.
`include "srt_controls_actual_extract.sv"
`default_nettype none

module tb_ven_fp_srt_controls;
  import ventium_decode_pkg::*;

  localparam logic [2:0] TOP_IDLE  = 3'd0;
  localparam logic [2:0] TOP_ALU   = 3'd1;
  localparam logic [2:0] TOP_TRANS = 3'd6;

  logic [2:0]  top_state;
  logic        cmd_valid;
  logic [6:0]  cmd_op;
  logic [2:0]  cmd_aluop;
  logic [2:0]  cmd_sti;
  logic        cmd_pop;
  logic        issue_stack_fault;
  logic        div_special_hit;
  logic        sqrt_special_hit;
  logic [15:0] fctrl_o;
  logic [15:0] fstat_o;
  logic        arith_mul_accepted_last_cycle;
  logic        arith_stream_hazard;
  logic [79:0] alu_a;
  logic [79:0] alu_b;
  logic [79:0] st0_data;
  logic [79:0] sti_data;
  logic        trans_divide_start;
  logic [79:0] trans_divide_a;
  logic [79:0] trans_divide_b;
  logic [1:0]  trans_divide_rc;
  logic        trans_done;
  logic [79:0] trans_primary;
  logic [79:0] trans_secondary;
  logic [6:0]  pending_op;
  logic        trans_c2;

  wire logic        old_cmd_ready, old_accept;
  wire logic        old_srt_start;
  wire logic [1:0]  old_srt_mode, old_srt_rc, old_srt_pc;
  wire logic [79:0] old_srt_a, old_srt_b;
  wire logic        new_cmd_ready, new_accept;
  wire logic        new_srt_start;
  wire logic [1:0]  new_srt_mode, new_srt_rc, new_srt_pc;
  wire logic [79:0] new_srt_a, new_srt_b;

  srt_controls_old_actual old_selector (
    .top_state, .cmd_valid, .cmd_op, .cmd_aluop, .cmd_sti, .cmd_pop,
    .issue_stack_fault, .div_special_hit, .sqrt_special_hit, .fctrl_o,
    .fstat_o, .arith_mul_accepted_last_cycle, .arith_stream_hazard, .alu_a,
    .alu_b, .st0_data, .sti_data, .trans_divide_start, .trans_divide_a,
    .trans_divide_b, .trans_divide_rc, .trans_done, .trans_primary,
    .trans_secondary, .pending_op, .trans_c2, .cmd_ready(old_cmd_ready),
    .accept_o(old_accept), .srt_start(old_srt_start), .srt_mode(old_srt_mode),
    .srt_rc(old_srt_rc), .srt_pc(old_srt_pc), .srt_a(old_srt_a), .srt_b(old_srt_b)
  );

  srt_controls_new_actual new_selector (
    .top_state, .cmd_valid, .cmd_op, .cmd_aluop, .cmd_sti, .cmd_pop,
    .issue_stack_fault, .div_special_hit, .sqrt_special_hit, .fctrl_o,
    .fstat_o, .arith_mul_accepted_last_cycle, .arith_stream_hazard, .alu_a,
    .alu_b, .st0_data, .sti_data, .trans_divide_start, .trans_divide_a,
    .trans_divide_b, .trans_divide_rc, .trans_done, .trans_primary,
    .trans_secondary, .pending_op, .trans_c2, .cmd_ready(new_cmd_ready),
    .accept_o(new_accept), .srt_start(new_srt_start), .srt_mode(new_srt_mode),
    .srt_rc(new_srt_rc), .srt_pc(new_srt_pc), .srt_a(new_srt_a), .srt_b(new_srt_b)
  );

  integer comparisons;
  integer top_i, op_i, alu_i, valid_i, rc_i, pc_i, trans_rc_i;
  integer state_code_i, req_code_i, xz_i;

  task automatic defaults;
    begin
      top_state                     = TOP_IDLE;
      cmd_valid                     = 1'b0;
      cmd_op                        = FX_NONE;
      cmd_aluop                     = 3'd0;
      cmd_sti                       = 3'd3;
      cmd_pop                       = 1'b0;
      issue_stack_fault             = 1'b0;
      div_special_hit               = 1'b0;
      sqrt_special_hit              = 1'b0;
      fctrl_o                       = 16'h003f;
      fstat_o                       = 16'h0000;
      arith_mul_accepted_last_cycle = 1'b0;
      arith_stream_hazard           = 1'b0;
      alu_a                         = 80'h0123_4567_89ab_cdef_0011;
      alu_b                         = 80'hfedc_ba98_7654_3210_1100;
      st0_data                      = 80'h1000_0000_0000_0000_0001;
      sti_data                      = 80'h2000_0000_0000_0000_0002;
      trans_divide_start            = 1'b0;
      trans_divide_a                = 80'h3000_0000_0000_0000_0003;
      trans_divide_b                = 80'h4000_0000_0000_0000_0004;
      trans_divide_rc               = 2'd0;
      trans_done                    = 1'b0;
      trans_primary                 = 80'h5000_0000_0000_0000_0005;
      trans_secondary               = 80'h6000_0000_0000_0000_0006;
      pending_op                    = FX_NONE;
      trans_c2                      = 1'b0;
    end
  endtask

  task automatic settle_compare;
    begin
      #1;
      comparisons = comparisons + 1;
      if ((old_cmd_ready !== new_cmd_ready) || (old_accept !== new_accept) ||
          (old_srt_start !== new_srt_start) || (old_srt_mode !== new_srt_mode) ||
          (old_srt_rc !== new_srt_rc) || (old_srt_pc !== new_srt_pc) ||
          (old_srt_a !== new_srt_a) || (old_srt_b !== new_srt_b)) begin
        $display("SRT control mismatch n=%0d state=%b valid=%b op=%b alu=%b req=%b done=%b pending=%b c2=%b",
                 comparisons, top_state, cmd_valid, cmd_op, cmd_aluop,
                 trans_divide_start, trans_done, pending_op, trans_c2);
        $display("  old ready=%b accept=%b start=%b mode=%b rc=%b pc=%b a=%h b=%h",
                 old_cmd_ready, old_accept, old_srt_start, old_srt_mode,
                 old_srt_rc, old_srt_pc, old_srt_a, old_srt_b);
        $display("  new ready=%b accept=%b start=%b mode=%b rc=%b pc=%b a=%h b=%h",
                 new_cmd_ready, new_accept, new_srt_start, new_srt_mode,
                 new_srt_rc, new_srt_pc, new_srt_a, new_srt_b);
        $fatal(1, "source-extracted old/new selector mismatch");
      end
    end
  endtask

  task automatic require_known(input logic condition, input [8*72-1:0] text);
    begin
      if (condition !== 1'b1)
        $fatal(1, "SRT control contract failure: %0s", text);
    end
  endtask

  function automatic logic [2:0] four_state_top(input integer code);
    integer bit_i;
    begin
      for (bit_i = 0; bit_i < 3; bit_i = bit_i + 1) begin
        case ((code >> (bit_i * 2)) & 3)
          0: four_state_top[bit_i] = 1'b0;
          1: four_state_top[bit_i] = 1'b1;
          2: four_state_top[bit_i] = 1'bx;
          default: four_state_top[bit_i] = 1'bz;
        endcase
      end
    end
  endfunction

  function automatic logic [1:0] four_state_pair(input integer code);
    integer bit_i;
    begin
      for (bit_i = 0; bit_i < 2; bit_i = bit_i + 1) begin
        case ((code >> (bit_i * 2)) & 3)
          0: four_state_pair[bit_i] = 1'b0;
          1: four_state_pair[bit_i] = 1'b1;
          2: four_state_pair[bit_i] = 1'bx;
          default: four_state_pair[bit_i] = 1'bz;
        endcase
      end
    end
  endfunction

  task automatic set_four_state_request(input integer code);
    begin
      case (code)
        0: trans_divide_start = 1'b0;
        1: trans_divide_start = 1'b1;
        2: trans_divide_start = 1'bx;
        default: trans_divide_start = 1'bz;
      endcase
    end
  endtask

  task automatic expect_live_rcpc;
    begin
      require_known(new_srt_rc === fctrl_o[11:10], "live RC must be retained");
      require_known(new_srt_pc === fctrl_o[9:8], "live PC must be retained");
    end
  endtask

  task automatic expect_trans_override;
    begin
      require_known(new_srt_start === 1'b1, "transcendental request must start SRT");
      require_known(new_srt_mode === 2'd0, "transcendental request mode must be divide");
      require_known(new_srt_rc === trans_divide_rc, "transcendental RC must override live CW");
      require_known(new_srt_pc === 2'b11, "transcendental PC must be 64-bit");
      require_known(new_srt_a === trans_divide_a, "transcendental A must be selected");
      require_known(new_srt_b === trans_divide_b, "transcendental B must be selected");
      require_known(new_cmd_ready === 1'b0, "TOP_TRANS cmd_ready must be low");
      require_known(new_accept === 1'b0, "TOP_TRANS accept must be low");
    end
  endtask

  initial begin
    comparisons = 0;

    // All 7 legal TOP states plus invalid 3'd7, every fxop encoding, every
    // ALU encoding, both known admission levels, and all RC/PC encodings
    // (RC=nearest/down/up/chop; PC=24/53/64/reserved encoding).
    for (top_i = 0; top_i < 8; top_i = top_i + 1) begin
      for (op_i = 0; op_i < 128; op_i = op_i + 1) begin
        for (alu_i = 0; alu_i < 8; alu_i = alu_i + 1) begin
          for (valid_i = 0; valid_i < 2; valid_i = valid_i + 1) begin
            for (rc_i = 0; rc_i < 4; rc_i = rc_i + 1) begin
              for (pc_i = 0; pc_i < 4; pc_i = pc_i + 1) begin
                defaults();
                top_state       = top_i[2:0];
                cmd_op          = op_i[6:0];
                cmd_aluop       = alu_i[2:0];
                cmd_valid       = valid_i[0];
                fctrl_o[11:10]  = rc_i[1:0];
                fctrl_o[9:8]    = pc_i[1:0];
                settle_compare();
                require_known(new_accept === (cmd_valid & new_cmd_ready),
                              "accept must be cmd_valid & cmd_ready");
`ifndef VEN_FP_ARITH_STREAM
                require_known(new_cmd_ready === (top_state == TOP_IDLE),
                              "non-stream cmd_ready must be TOP_IDLE only");
`endif
              end
            end
          end
        end
      end
    end

    // Actual admission constraints, including the stream-only TOP_ALU window.
    defaults();
    top_state = TOP_IDLE;
    cmd_valid = 1'b1;
    cmd_op = FX_AR_ST0_STI;
    cmd_aluop = 3'd1;
    settle_compare();
`ifdef VEN_FP_ARITH_STREAM
    require_known(new_cmd_ready === 1'b1, "idle non-busy command must be ready");
`else
    require_known(new_cmd_ready === 1'b1, "idle command must be ready");
`endif
    require_known(new_accept === 1'b1, "ready valid command must accept");

    arith_mul_accepted_last_cycle = 1'b1;
    settle_compare();
`ifdef VEN_FP_ARITH_STREAM
    require_known(new_cmd_ready === 1'b0, "back-to-back multiply must interlock");
    require_known(new_accept === 1'b0, "interlocked multiply must not accept");
`else
    require_known(new_cmd_ready === 1'b1, "base profile has no arithmetic stream interlock");
`endif

    defaults();
    top_state = TOP_ALU;
    cmd_valid = 1'b1;
    cmd_op = FX_AR_ST0_STI;
    cmd_aluop = 3'd0;
    settle_compare();
`ifdef VEN_FP_ARITH_STREAM
    require_known(new_cmd_ready === 1'b1, "eligible fast arithmetic can stream from TOP_ALU");
    require_known(new_accept === 1'b1, "eligible streamed arithmetic accepts");
    cmd_pop = 1'b1;
    settle_compare();
    require_known(new_cmd_ready === 1'b0, "popping arithmetic cannot stream");
    defaults(); top_state = TOP_ALU; cmd_valid = 1'b1; cmd_op = FX_AR_ST0_STI; cmd_aluop = 3'd0;
    issue_stack_fault = 1'b1;
    settle_compare();
    require_known(new_cmd_ready === 1'b0, "stack-fault command cannot stream");
    defaults(); top_state = TOP_ALU; cmd_valid = 1'b1; cmd_op = FX_AR_ST0_STI; cmd_aluop = 3'd0;
    fctrl_o[5:0] = 6'h00;
    settle_compare();
    require_known(new_cmd_ready === 1'b0, "non-default exception mask cannot stream");
    defaults(); top_state = TOP_ALU; cmd_valid = 1'b1; cmd_op = FX_AR_ST0_STI; cmd_aluop = 3'd0;
    fstat_o[7] = 1'b1;
    settle_compare();
    require_known(new_cmd_ready === 1'b0, "busy exception state cannot stream");
    defaults(); top_state = TOP_ALU; cmd_valid = 1'b1; cmd_op = FX_AR_ST0_STI; cmd_aluop = 3'd0;
    arith_stream_hazard = 1'b1;
    settle_compare();
    require_known(new_cmd_ready === 1'b0, "arithmetic hazard cannot stream");
`else
    require_known(new_cmd_ready === 1'b0, "base profile TOP_ALU cannot accept");
`endif

    // A TOP_TRANS request preempts every normal command branch.  This also
    // exercises all fxop/ALU combinations while request ownership is active.
    for (op_i = 0; op_i < 128; op_i = op_i + 1) begin
      for (alu_i = 0; alu_i < 8; alu_i = alu_i + 1) begin
        for (rc_i = 0; rc_i < 4; rc_i = rc_i + 1) begin
          for (pc_i = 0; pc_i < 4; pc_i = pc_i + 1) begin
            for (trans_rc_i = 0; trans_rc_i < 4; trans_rc_i = trans_rc_i + 1) begin
              defaults();
              top_state           = TOP_TRANS;
              cmd_valid           = 1'b1;
              cmd_op              = op_i[6:0];
              cmd_aluop           = alu_i[2:0];
              fctrl_o[11:10]      = rc_i[1:0];
              fctrl_o[9:8]        = pc_i[1:0];
              trans_divide_start  = 1'b1;
              trans_divide_rc     = trans_rc_i[1:0];
              settle_compare();
              expect_trans_override();
            end
          end
        end
      end
    end

    // FPTAN's done-cycle SRT tail uses the live CW, while C2/done/operation
    // unknowns remain procedural-if false rather than producing a ?: merge.
    for (rc_i = 0; rc_i < 4; rc_i = rc_i + 1) begin
      for (pc_i = 0; pc_i < 4; pc_i = pc_i + 1) begin
        defaults();
        top_state = TOP_TRANS;
        fctrl_o[11:10] = rc_i[1:0];
        fctrl_o[9:8] = pc_i[1:0];
        trans_done = 1'b1;
        pending_op = FX_FPTAN;
        trans_c2 = 1'b0;
        settle_compare();
        require_known(new_srt_start === 1'b1, "FPTAN tail must start SRT");
        require_known(new_srt_mode === 2'd0, "FPTAN tail must use divide mode");
        require_known(new_srt_rc === fctrl_o[11:10], "FPTAN tail retains live RC");
        require_known(new_srt_pc === fctrl_o[9:8], "FPTAN tail retains live PC");
        require_known(new_srt_a === trans_primary, "FPTAN tail selects primary operand");
        require_known(new_srt_b === trans_secondary, "FPTAN tail selects secondary operand");
      end
    end
    for (xz_i = 0; xz_i < 2; xz_i = xz_i + 1) begin
      defaults(); top_state = TOP_TRANS; trans_done = 1'b1; pending_op = FX_FPTAN;
      trans_c2 = xz_i == 0 ? 1'bx : 1'bz;
      settle_compare();
      require_known(new_srt_start === 1'b0, "unknown FPTAN C2 cannot start SRT");
      defaults(); top_state = TOP_TRANS; pending_op = FX_FPTAN;
      trans_done = xz_i == 0 ? 1'bx : 1'bz;
      settle_compare();
      require_known(new_srt_start === 1'b0, "unknown FPTAN done cannot start SRT");
      defaults(); top_state = TOP_TRANS; trans_done = 1'b1;
      pending_op = xz_i == 0 ? 7'bxxxxxxx : 7'bzzzzzzz;
      settle_compare();
      require_known(new_srt_start === 1'b0, "unknown pending operation cannot start SRT");
    end

    // Raw 0/1/X/Z TOP bits (4^3 patterns), request 0/1/X/Z, and all live
    // RC/PC settings.  Exact TOP_TRANS+1 is the sole override condition.
    for (state_code_i = 0; state_code_i < 64; state_code_i = state_code_i + 1) begin
      for (req_code_i = 0; req_code_i < 4; req_code_i = req_code_i + 1) begin
        for (rc_i = 0; rc_i < 4; rc_i = rc_i + 1) begin
          for (pc_i = 0; pc_i < 4; pc_i = pc_i + 1) begin
            defaults();
            top_state = four_state_top(state_code_i);
            set_four_state_request(req_code_i);
            fctrl_o[11:10] = rc_i[1:0];
            fctrl_o[9:8] = pc_i[1:0];
            trans_divide_rc = 2'd2;
            settle_compare();
            if ((top_state === TOP_TRANS) && (trans_divide_start === 1'b1))
              expect_trans_override();
            else
              expect_live_rcpc();
          end
        end
      end
    end

    // All sixteen four-state encodings of each live CW field are retained in
    // the default path and after a borrowed request falls to X, then to 0.
    // This is intentionally separate from the known override, where fctrl_o
    // is irrelevant.
    for (rc_i = 0; rc_i < 16; rc_i = rc_i + 1) begin
      for (pc_i = 0; pc_i < 16; pc_i = pc_i + 1) begin
        defaults();
        fctrl_o[11:10] = four_state_pair(rc_i);
        fctrl_o[9:8] = four_state_pair(pc_i);
        settle_compare();
        expect_live_rcpc();
        top_state = TOP_TRANS;
        trans_divide_start = 1'bx;
        settle_compare();
        expect_live_rcpc();
        trans_divide_start = 1'b0;
        settle_compare();
        expect_live_rcpc();
      end
    end

    // All sixteen four-state transcendental RC encodings remain observable
    // when a known request owns TOP_TRANS; the PC override stays known 64-bit.
    for (trans_rc_i = 0; trans_rc_i < 16; trans_rc_i = trans_rc_i + 1) begin
      defaults();
      top_state = TOP_TRANS;
      trans_divide_start = 1'b1;
      trans_divide_rc = four_state_pair(trans_rc_i);
      settle_compare();
      expect_trans_override();
    end

    // Unknown admission/data cases use the actual procedural-if semantics:
    // no normal arm starts from X/Z, while a known TOP_TRANS request still
    // owns the request independently of unknown command/admission inputs.
    for (xz_i = 0; xz_i < 2; xz_i = xz_i + 1) begin
      defaults(); top_state = TOP_IDLE; cmd_op = FX_AR_ST0_STI; cmd_aluop = 3'd6;
      cmd_valid = xz_i == 0 ? 1'bx : 1'bz;
      settle_compare();
      require_known(new_srt_start === 1'b0, "X/Z cmd_valid cannot start normal SRT");
      defaults(); top_state = TOP_IDLE; cmd_valid = 1'b1; cmd_op = FX_AR_ST0_STI; cmd_aluop = 3'd6;
      issue_stack_fault = xz_i == 0 ? 1'bx : 1'bz;
      settle_compare();
      require_known(new_srt_start === 1'b0, "X/Z stack fault cannot start normal SRT");
      defaults(); top_state = TOP_IDLE; cmd_valid = 1'b1; cmd_op = FX_AR_ST0_STI;
      cmd_aluop = xz_i == 0 ? 3'bxxx : 3'bzzz;
      div_special_hit = xz_i == 0 ? 1'bx : 1'bz;
      settle_compare();
      require_known(new_srt_start === 1'b0, "X/Z operation admission cannot start normal SRT");
      defaults(); top_state = TOP_TRANS; trans_divide_start = 1'b1;
      cmd_valid = xz_i == 0 ? 1'bx : 1'bz;
      issue_stack_fault = xz_i == 0 ? 1'bx : 1'bz;
      div_special_hit = xz_i == 0 ? 1'bx : 1'bz;
      sqrt_special_hit = xz_i == 0 ? 1'bx : 1'bz;
      fctrl_o = xz_i == 0 ? 16'hxxxx : 16'hzzzz;
      alu_a = xz_i == 0 ? 80'hx123_4567_89ab_cdef_0011 : 80'hz123_4567_89ab_cdef_0011;
      alu_b = xz_i == 0 ? 80'hx234_5678_9abc_def0_0012 : 80'hz234_5678_9abc_def0_0012;
      trans_divide_a = xz_i == 0 ? 80'hx345_6789_abcd_ef01_0013 : 80'hz345_6789_abcd_ef01_0013;
      trans_divide_b = xz_i == 0 ? 80'hx456_789a_bcde_f012_0014 : 80'hz456_789a_bcde_f012_0014;
      trans_divide_rc = 2'd1;
      settle_compare();
      expect_trans_override();
    end

    // The exact requested 1 -> X -> 0 -> 1 sequence demonstrates that the
    // RC/PC override is not captured: it returns to the current live CW as
    // soon as the borrowed request is not known-true.
    defaults(); top_state = TOP_TRANS; trans_divide_rc = 2'd2;
    fctrl_o[11:10] = 2'd0; fctrl_o[9:8] = 2'd0; trans_divide_start = 1'b1;
    settle_compare(); expect_trans_override();
    fctrl_o[11:10] = 2'd3; fctrl_o[9:8] = 2'd2;
    settle_compare(); expect_trans_override();
    trans_divide_start = 1'bx;
    settle_compare(); expect_live_rcpc();
    fctrl_o[11:10] = 2'd0; fctrl_o[9:8] = 2'd1;
    settle_compare(); expect_live_rcpc();
    trans_divide_start = 1'b0;
    settle_compare(); expect_live_rcpc();
    fctrl_o[11:10] = 2'd1; fctrl_o[9:8] = 2'd3; trans_divide_start = 1'b1;
    settle_compare(); expect_trans_override();

`ifdef VEN_FP_ARITH_STREAM
    $display("VEN-FP-SRT-CONTROLS-OK config=stream comparisons=%0d", comparisons);
`else
    $display("VEN-FP-SRT-CONTROLS-OK config=base comparisons=%0d", comparisons);
`endif
    $finish;
  end
endmodule

`default_nettype wire
