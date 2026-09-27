`timescale 1ns/1ps
`default_nettype none

// Command/architectural-state A/B harness.
//
// The reference side is the checkout's proven fpu_writeback + fpu_top pair.
// The candidate side is ven_fp_top.  The candidate intentionally changes
// latency, so comparisons occur after one logical instruction has retired on
// both sides.  For deferred reference commits, the already A/B-proven leaf
// result is replayed onto fpu_writeback's engine-result bus; this test therefore
// checks instruction routing, destination selection, stack motion, status
// merging, environment pointers and save/restore sequencing independently of
// the leaf arithmetic tests.

module tb_ven_fp_arch_ab;
  import ventium_pkg::*;
  import ventium_alu_pkg::*;
  import ventium_decode_pkg::*;
  import fpu_x87_pkg::*;
  import ventium_x87_pkg::*;
  import ventium_sys_pkg::*;

  localparam logic [79:0] FP_ZERO = 80'h00000000000000000000;
  localparam logic [79:0] FP_HALF = 80'h3ffE8000000000000000;
  localparam logic [79:0] FP_ONE  = 80'h3fff8000000000000000;
  localparam logic [79:0] FP_1P5  = 80'h3fffc000000000000000;
  localparam logic [79:0] FP_TWO  = 80'h40008000000000000000;
  localparam logic [79:0] FP_THREE= 80'h4000c000000000000000;
  localparam logic [79:0] FP_FOUR = 80'h40018000000000000000;
  localparam logic [79:0] FP_FIVE = 80'h4001a000000000000000;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  // Candidate command and response.
  logic cmd_valid, cmd_ready, cmd_accept_retire, new_alu_commit_retire;
  fxop_e cmd_op;
  logic [2:0] cmd_aluop, cmd_sti, cmd_constant;
  logic cmd_pop, cmd_fdiv_bug, cmd_fist_bug;
  logic [79:0] cmd_mem;
  logic [3:0] cmd_mem_bytes;
  logic cmd_env16, cmd_real_mode;
  logic [863:0] cmd_env_image;
  logic cmd_update_fip, cmd_update_fdp;
  logic [31:0] cmd_fip, cmd_fdp;
  logic [15:0] cmd_fcs, cmd_fds;
  logic new_busy, rsp_valid, rsp_unsupported, rsp_stack_fault;
  logic [84:0] rsp_arith;
  logic rsp_store_valid, rsp_ax_valid;
  logic [863:0] rsp_store_data;
  logic [7:0] rsp_store_bytes;
  logic [15:0] rsp_ax;
  logic [2:0] new_ftop;
  logic [15:0] new_fstat, new_fctrl;
  logic [7:0] new_fptag;
  logic [31:0] new_fip, new_fdp;
  logic [15:0] new_fcs, new_fds;
  logic [639:0] new_phys, new_st;

  ven_fp_top u_new (
      .clk(clk), .rst_n(rst_n),
      .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
      .cmd_accept_retire(cmd_accept_retire),
      .alu_commit_retire(new_alu_commit_retire), .cmd_op(cmd_op),
      .cmd_aluop(cmd_aluop), .cmd_sti(cmd_sti), .cmd_pop(cmd_pop),
      .cmd_constant(cmd_constant), .cmd_mem(cmd_mem),
      .cmd_mem_bytes(cmd_mem_bytes), .cmd_fdiv_bug(cmd_fdiv_bug),
      .cmd_fist_bug(cmd_fist_bug), .cmd_env16(cmd_env16),
      .cmd_real_mode(cmd_real_mode), .cmd_env_image(cmd_env_image),
      .cmd_update_fip(cmd_update_fip), .cmd_fip(cmd_fip), .cmd_fcs(cmd_fcs),
      .cmd_update_fdp(cmd_update_fdp), .cmd_fdp(cmd_fdp), .cmd_fds(cmd_fds),
      .busy(new_busy), .rsp_valid(rsp_valid),
      .rsp_unsupported(rsp_unsupported), .rsp_stack_fault(rsp_stack_fault),
      .rsp_arith(rsp_arith), .rsp_store_valid(rsp_store_valid),
      .rsp_store_data(rsp_store_data), .rsp_store_bytes(rsp_store_bytes),
      .rsp_ax_valid(rsp_ax_valid), .rsp_ax(rsp_ax),
      .ftop_o(new_ftop), .fstat_o(new_fstat), .fctrl_o(new_fctrl),
      .fptag_o(new_fptag), .fip_o(new_fip), .fcs_o(new_fcs),
      .fdp_o(new_fdp), .fds_o(new_fds),
      .fpr_phys_flat_o(new_phys), .st_flat_o(new_st)
  );

  // Reference writeback inputs.
  state_e state;
  logic [4:0] errata_en;
  fpd_t u_d, v_d;
  fxop_e q_fxop;
  logic q_f_mem_read, q_f_mem_write;
  logic [3:0] q_f_mbytes;
  logic q_f_pop;
  logic [2:0] q_f_sti, q_f_aluop, q_f_const;
  logic [31:0] q_pc, q_ea, dbase;
  logic mem_ack;
  logic [31:0] mem_rdata;
  logic [79:0] f_mem80;
  logic [3:0] f_step;
  logic [5:0] f_seq_step, fenv_last;
  logic [31:0] env_tmp [47];
  logic xlate_miss, issue_block;
  logic [6:0] stall_cnt, pending_mem_pen;
  logic pipe_bytes_ok, v_bytes_ok, pair_block, fp_v_fold_ok;
  logic [31:0] core_cyc, fp_ready_cyc;
  logic fp_occ_pending;
  logic pipe_fp_live_arm;
  logic fstore_ie, fstore_pe, fstore_oe, fstore_ue;
  logic eng_div_done, eng_sqrt_done;
  logic [82:0] eng_div_result, eng_sqrt_result;
  logic eng_bcd_done, eng_fbld_done;
  logic [81:0] eng_bcd_result;
  logic [79:0] eng_fbld_result;
  logic eng_trsc_done, eng_trsc_pe, eng_trsc_ie, eng_trsc_c2;
  logic [79:0] eng_trsc_result, eng_fs_sin, eng_fs_cos;
  logic eng_fprem_done, eng_fprem_c2, eng_fprem_ie;
  logic [79:0] eng_fprem_result;
  logic [2:0] eng_fprem_q012;
  logic fp_flt_i, fp_flt_ovf_i;

  // Reference state readback.
  logic [79:0] fp_st [8];
  logic [79:0] old_st0, old_st1, old_st2, old_st3;
  logic [79:0] old_st4, old_st5, old_st6, old_st7;
  logic [2:0] ftop;
  logic [15:0] fstat, fctrl;
  logic [7:0] fptag;
  logic [31:0] old_fip, old_fdp;
  logic [15:0] old_fcs, old_fds;
  logic [79:0] old_phys_top;
  logic [639:0] old_phys, old_st_flat;

  assign fp_st[0]=old_st0; assign fp_st[1]=old_st1;
  assign fp_st[2]=old_st2; assign fp_st[3]=old_st3;
  assign fp_st[4]=old_st4; assign fp_st[5]=old_st5;
  assign fp_st[6]=old_st6; assign fp_st[7]=old_st7;
  always_comb begin
    old_st_flat = '0;
    for (int i=0; i<8; i++) old_st_flat[i*80 +: 80] = fp_st[i];
  end

  // Reference write-port and iterative-dispatch outputs.
  logic fp_stk_ovf, fp_stk_unf;
  logic fp_we_push; logic [79:0] fp_push_data;
  logic fp_we_top; logic [79:0] fp_top_data;
  logic fp_we_fstat; logic [15:0] fp_fstat_wval;
  logic fp_we_sti; logic [2:0] fp_wsti_idx;
  logic [79:0] fp_wsti_data; logic fp_wsti_clr_tag;
  logic fp_we_fxch; logic [2:0] fp_fxch_idx;
  logic [79:0] fp_fxch_a, fp_fxch_b;
  logic fp_fxch_materialize_empty;
  logic fp_we_pop, fp_we_pop2, fp_we_ffree;
  logic [2:0] fp_ffree_idx;
  logic fp_we_incstp, fp_we_decstp;
  logic fp_we_fctrl; logic [15:0] fp_fctrl_wval;
  logic fp_we_fninit;
  logic fp_div_elig, fp_sqrt_elig, fp_iter_go, fp_iter_done;
  logic [79:0] eng_div_a, eng_div_b, eng_sqrt_in;
  logic [1:0] eng_rc;
  logic eng_div_start, eng_sqrt_start;
  logic fp_we_eptr; logic [31:0] fp_eptr_fip;
  logic [15:0] fp_eptr_fcs;
  logic fp_we_dptr; logic [31:0] fp_eptr_fdp;
  logic [15:0] fp_eptr_fds;
  logic fp_we_envld; logic [15:0] fp_env_fctrl;
  logic [2:0] fp_env_ftop; logic [15:0] fp_env_fstat;
  logic [7:0] fp_env_fptag;
  logic fp_we_envregs; logic [639:0] fp_env_fpr_flat;
  logic fp_we_wabs, fp_we_wabs_fstat;
  logic [2:0] fp_wabs_idx;
  logic [79:0] fp_wabs_data;
  logic [15:0] fp_wabs_fstat;

  fpu_writeback u_old_wb (.*);

  fpu_top u_old_state (
      .clk(clk), .rst_n(rst_n),
      .st0(old_st0), .st1(old_st1), .st2(old_st2), .st3(old_st3),
      .st4(old_st4), .st5(old_st5), .st6(old_st6), .st7(old_st7),
      .ftop_o(ftop), .fstat_o(fstat), .fctrl_o(fctrl), .fptag_o(fptag),
      .rd_phys_top(old_phys_top),
      .we_push(fp_we_push), .push_data(fp_push_data),
      .we_top(fp_we_top), .top_data(fp_top_data),
      .we_fstat(fp_we_fstat), .fstat_wval(fp_fstat_wval),
      .we_sti(fp_we_sti), .wsti_idx(fp_wsti_idx), .wsti_data(fp_wsti_data),
      .wsti_clr_tag(fp_wsti_clr_tag),
      .we_fxch(fp_we_fxch), .fxch_idx(fp_fxch_idx),
      .fxch_a(fp_fxch_a), .fxch_b(fp_fxch_b),
      .fxch_materialize_empty(fp_fxch_materialize_empty),
      .we_pop(fp_we_pop), .we_pop2(fp_we_pop2),
      .we_ffree(fp_we_ffree), .ffree_idx(fp_ffree_idx),
      .we_incstp(fp_we_incstp), .we_decstp(fp_we_decstp),
      .we_fctrl(fp_we_fctrl), .fctrl_wval(fp_fctrl_wval),
      .we_fninit(fp_we_fninit),
      .we_eptr(fp_we_eptr), .eptr_fip(fp_eptr_fip), .eptr_fcs(fp_eptr_fcs),
      .we_dptr(fp_we_dptr), .dptr_fdp(fp_eptr_fdp), .dptr_fds(fp_eptr_fds),
      .fip_o(old_fip), .fcs_o(old_fcs), .fdp_o(old_fdp), .fds_o(old_fds),
      .fpr_flat_o(old_phys),
      .we_envld(fp_we_envld), .env_fctrl(fp_env_fctrl),
      .env_ftop(fp_env_ftop), .env_fstat(fp_env_fstat),
      .env_fptag(fp_env_fptag), .we_envregs(fp_we_envregs),
      .env_fpr_flat(fp_env_fpr_flat),
      .we_wabs(fp_we_wabs), .wabs_idx(fp_wabs_idx),
      .wabs_data(fp_wabs_data), .we_wabs_fstat(fp_we_wabs_fstat),
      .wabs_fstat(fp_wabs_fstat)
  );

  int checks;
  logic [863:0] expected_env_image;

  function automatic logic op_mem_read(input fxop_e op);
    unique case (op)
      FX_FLD_M32, FX_FLD_M64, FX_FLD_M80,
      FX_FILD_M16, FX_FILD_M32, FX_FILD_M64, FX_FBLD,
      FX_FLDCW, FX_FLDENV, FX_FRSTOR,
      FX_FCOM_M32, FX_FCOM_M64, FX_FICOM_M16, FX_FICOM_M32,
      FX_AR_M32, FX_AR_M64, FX_AR_I16, FX_AR_I32: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  function automatic logic op_mem_write(input fxop_e op);
    unique case (op)
      FX_FST_M32, FX_FST_M64, FX_FST_M80,
      FX_FIST_M16, FX_FIST_M32, FX_FIST_M64, FX_FBSTP,
      FX_FNSTCW, FX_FNSTSW_M, FX_FNSTENV, FX_FNSAVE: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  function automatic logic op_admin(input fxop_e op);
    unique case (op)
      FX_FNINIT, FX_FNCLEX, FX_FNSTCW, FX_FNSTSW_M, FX_FLDCW,
      FX_FWAIT, FX_FNSTENV, FX_FLDENV, FX_FNSAVE, FX_FRSTOR:
        return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  function automatic logic op_store(input fxop_e op);
    unique case (op)
      FX_FST_M32, FX_FST_M64, FX_FST_M80,
      FX_FIST_M16, FX_FIST_M32, FX_FIST_M64: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  function automatic logic op_trans(input fxop_e op);
    return (op>=FX_F2XM1) && (op<=FX_FPTAN);
  endfunction

  function automatic logic [863:0] old_env32;
    logic [15:0] ftw;
    begin
      ftw = '0;
      for (int p=0; p<8; p++)
        ftw[p*2 +: 2] = ftw_field(fptag[p], old_phys[p*80 +: 80]);
      old_env32 = {
        old_st_flat, {16'd0,old_fds}, old_fdp,
        {5'd0,11'd0,old_fcs}, old_fip, {16'd0,ftw},
        {16'd0,(fstat & ~16'h3800) | ({13'd0,ftop} << 11)},
        {16'd0,fctrl}
      };
    end
  endfunction

  task automatic clear_engine_inputs;
    begin
      eng_div_done=0; eng_sqrt_done=0; eng_bcd_done=0; eng_fbld_done=0;
      eng_trsc_done=0; eng_fprem_done=0;
      fstore_ie=0; fstore_pe=0; fstore_oe=0; fstore_ue=0;
      mem_ack=0; f_step=0; f_seq_step=0;
      fp_flt_i=0; fp_flt_ovf_i=0;
    end
  endtask

  task automatic compare_state(input string label);
    begin
      if ({new_ftop,new_fstat,new_fctrl,new_fptag} !==
          {ftop,fstat,fctrl,fptag})
        $fatal(1, "%s metadata new=%h/%h/%h/%h old=%h/%h/%h/%h",
               label,new_ftop,new_fstat,new_fctrl,new_fptag,
               ftop,fstat,fctrl,fptag);
      if ({new_fip,new_fcs,new_fdp,new_fds} !==
          {old_fip,old_fcs,old_fdp,old_fds})
        $fatal(1, "%s pointer mismatch new=%h/%h/%h/%h old=%h/%h/%h/%h",
               label,new_fip,new_fcs,new_fdp,new_fds,
               old_fip,old_fcs,old_fdp,old_fds);
      if (new_phys !== old_phys) begin
        for (int p=0; p<8; p++)
          if (new_phys[p*80 +: 80] !== old_phys[p*80 +: 80])
            $display("%s phys%0d new=%020h old=%020h", label, p,
                     new_phys[p*80 +: 80], old_phys[p*80 +: 80]);
        $fatal(1, "%s physical-register mismatch", label);
      end
      if (new_st !== old_st_flat) begin
        for (int i=0; i<8; i++)
          if (new_st[i*80 +: 80] !== old_st_flat[i*80 +: 80])
            $display("%s ST%0d new=%020h old=%020h", label, i,
                     new_st[i*80 +: 80], old_st_flat[i*80 +: 80]);
        $fatal(1, "%s logical-register mismatch", label);
      end
      checks++;
    end
  endtask

  task automatic reference_deferred(input fxop_e op);
    begin
      clear_engine_inputs();
      if (((op==FX_AR_ST0_STI)||(op==FX_AR_STI_ST0)||
           (op==FX_AR_M32)||(op==FX_AR_M64)||
           (op==FX_AR_I16)||(op==FX_AR_I32)) &&
          ((q_f_aluop==3'd6)||(q_f_aluop==3'd7))) begin
        state = S_FP_BUSY;
        eng_div_result = {rsp_arith[82:80],rsp_arith[79:0]};
        eng_div_done = 1'b1;
      end else if (op==FX_FSQRT) begin
        state = S_FP_BUSY;
        eng_sqrt_result = {rsp_arith[82:80],rsp_arith[79:0]};
        eng_sqrt_done = 1'b1;
      end else if ((op==FX_FPREM)||(op==FX_FPREM1)) begin
        state = S_FPREM_BUSY;
        eng_fprem_done = 1'b1;
        eng_fprem_result = rsp_arith[79:0];
        eng_fprem_ie = new_fstat[0];
        eng_fprem_c2 = new_fstat[10];
        eng_fprem_q012 = {new_fstat[8],new_fstat[14],new_fstat[9]};
      end else if (op_trans(op)) begin
        state = S_TRSC_BUSY;
        eng_trsc_done = 1'b1;
        eng_trsc_ie = new_fstat[0];
        eng_trsc_pe = new_fstat[5];
        eng_trsc_c2 = new_fstat[10];
        if ((op==FX_FPATAN)||(op==FX_FYL2X)||(op==FX_FYL2XP1))
          eng_trsc_result = new_st[79:0];
        else if (op==FX_FSINCOS) begin
          eng_trsc_result = new_st[159:80];
          eng_fs_sin = new_st[159:80];
          eng_fs_cos = new_st[79:0];
        end else if (op==FX_FPTAN) begin
          // The old commit computes sin/cos combinationally.  tan/1 supplies
          // exactly the candidate quotient while preserving the commit shape.
          eng_trsc_result = new_st[159:80];
          eng_fs_sin = new_st[159:80];
          eng_fs_cos = FP_ONE;
        end else
          eng_trsc_result = new_st[79:0];
      end else if (op==FX_FBLD) begin
        state = S_FBLD_BUSY;
        eng_fbld_done = 1'b1;
        eng_fbld_result = rsp_arith[79:0];
      end else if (op==FX_FBSTP) begin
        state = S_BCD_BUSY;
        eng_bcd_done = 1'b1;
        eng_bcd_result = {rsp_arith[84],rsp_arith[80],rsp_store_data[79:0]};
      end else begin
        return;
      end
      @(negedge clk);
      clear_engine_inputs();
      state = S_PIPE;
    end
  endtask

  task automatic reference_store_finish(input fxop_e op);
    begin
      if (op_store(op)) begin
        // Replay the legacy dispatch-time store flags now that the registered
        // candidate conversion has completed.
        state = S_FEXEC;
        fstore_ie = rsp_arith[84];
        fstore_oe = rsp_arith[82];
        fstore_ue = rsp_arith[81];
        fstore_pe = rsp_arith[80];
        @(negedge clk);
        clear_engine_inputs();
      end
      if (op_store(op) || (op==FX_FBSTP)) begin
        state = S_FSTORE;
        mem_ack = 1'b1;
        if (q_f_mbytes==4'd8) f_step=4'd1;
        if (q_f_mbytes==4'd10) f_step=4'd2;
        @(negedge clk);
        clear_engine_inputs();
        state = S_PIPE;
      end
    end
  endtask

  task automatic reference_env_finish(input fxop_e op);
    begin
      if ((op==FX_FNSTENV)||(op==FX_FNSAVE)) begin
        state = S_FENV_ST;
        mem_ack = 1'b1;
        f_seq_step = (op==FX_FNSAVE) ? 6'd26 : 6'd6;
        @(negedge clk);
        clear_engine_inputs();
        state = S_PIPE;
      end else if ((op==FX_FLDENV)||(op==FX_FRSTOR)) begin
        for (int j=0; j<27; j++) env_tmp[j] = cmd_env_image[j*32 +: 32];
        state = S_FENV_LD;
        mem_ack = 1'b1;
        fenv_last = (op==FX_FRSTOR) ? 6'd26 : 6'd6;
        f_seq_step = fenv_last;
        mem_rdata = cmd_env_image[26*32 +: 32];
        @(negedge clk);
        clear_engine_inputs();
        state = S_PIPE;
      end
    end
  endtask

  task automatic issue_ab(
      input fxop_e op,
      input logic [2:0] aluop,
      input logic [2:0] sti,
      input logic pop,
      input logic [79:0] mem,
      input logic [3:0] bytes,
      input string label
  );
    begin
      while (!cmd_ready) @(negedge clk);
      @(negedge clk);
      q_fxop=op; q_f_aluop=aluop; q_f_sti=sti; q_f_pop=pop;
      q_f_mbytes=bytes; q_f_const=cmd_constant;
      q_f_mem_read=op_mem_read(op); q_f_mem_write=op_mem_write(op);
      f_mem80=mem;
      q_pc=q_pc+32'd4; q_ea=q_ea+32'd16;

      cmd_op=op; cmd_aluop=aluop; cmd_sti=sti; cmd_pop=pop;
      cmd_mem=mem; cmd_mem_bytes=bytes;
      cmd_update_fip=!op_admin(op); cmd_fip=q_pc; cmd_fcs=16'h0023;
      cmd_update_fdp=!op_admin(op) && (q_f_mem_read||q_f_mem_write);
      cmd_fdp=dbase+q_ea; cmd_fds=16'h002b;
      expected_env_image=old_env32();

      state=S_FEXEC;
      cmd_valid=1'b1;
      @(negedge clk);
      cmd_valid=1'b0;
      state=S_PIPE;

      while (!rsp_valid) @(negedge clk);
      if (rsp_unsupported) $fatal(1, "%s unexpectedly unsupported",label);

      if ((op==FX_FNSTENV)||(op==FX_FNSAVE)) begin
        if (!rsp_store_valid || rsp_store_data!==expected_env_image)
          $fatal(1, "%s environment image mismatch",label);
      end

      reference_deferred(op);
      reference_store_finish(op);
      reference_env_finish(op);
      compare_state(label);
    end
  endtask

  task automatic load80(input logic [79:0] value, input string label);
    issue_ab(FX_FLD_M80,3'd0,3'd0,1'b0,value,4'd10,label);
  endtask

  initial begin
    cmd_valid=0; cmd_op=FX_NONE; cmd_aluop=0; cmd_sti=0; cmd_pop=0;
    cmd_constant=0; cmd_mem=0; cmd_mem_bytes=0;
    cmd_fdiv_bug=0; cmd_fist_bug=0; cmd_env16=0; cmd_real_mode=0;
    cmd_env_image=0; cmd_update_fip=0; cmd_update_fdp=0;
    cmd_fip=0; cmd_fcs=16'h23; cmd_fdp=0; cmd_fds=16'h2b;

    state=S_PIPE; errata_en=0; u_d='0; v_d='0;
    q_fxop=FX_NONE; q_f_mem_read=0; q_f_mem_write=0; q_f_mbytes=0;
    q_f_pop=0; q_f_sti=0; q_f_aluop=0; q_f_const=0;
    q_pc=32'h1000; q_ea=32'h2000; dbase=32'h3000;
    mem_rdata=0; f_mem80=0; fenv_last=6'd26;
    xlate_miss=0; issue_block=0; stall_cnt=0; pipe_bytes_ok=1;
    pending_mem_pen=0; v_bytes_ok=1; pair_block=0; fp_v_fold_ok=1;
    core_cyc=0; fp_ready_cyc=0; fp_occ_pending=0; pipe_fp_live_arm=1;
    eng_div_result=0; eng_sqrt_result=0; eng_bcd_result=0;
    eng_fbld_result=0; eng_trsc_result=0; eng_fs_sin=0; eng_fs_cos=0;
    eng_fprem_result=0; eng_fprem_q012=0;
    for (int j=0; j<47; j++) env_tmp[j]=0;
    clear_engine_inputs();
    checks=0;

    repeat (3) @(negedge clk);
    rst_n=1'b1;
    @(negedge clk);
    compare_state("reset");

    // Direct pushes, moves, shared arithmetic and iterative divide/sqrt.
    load80(FP_TWO,"FLD two");
    load80(FP_ONE,"FLD one");
    issue_ab(FX_AR_ST0_STI,3'd0,3'd1,0,0,0,"FADD ST0,ST1");
    issue_ab(FX_AR_ST0_STI,3'd1,3'd1,0,0,0,"FMUL ST0,ST1");
    issue_ab(FX_AR_ST0_STI,3'd6,3'd1,0,0,0,"FDIV ST0,ST1");
    load80(FP_FOUR,"FLD four");
    issue_ab(FX_FSQRT,0,0,0,0,0,"FSQRT");

    issue_ab(FX_FXCH,0,3'd1,0,0,0,"FXCH");
    issue_ab(FX_FST_STI,0,3'd2,0,0,0,"FST ST2");
    issue_ab(FX_FCOM_STI,0,3'd1,0,0,0,"FCOM ST1");
    issue_ab(FX_FXAM,0,0,0,0,0,"FXAM");
    issue_ab(FX_FABS,0,0,0,0,0,"FABS");
    issue_ab(FX_FCHS,0,0,0,0,0,"FCHS");
    issue_ab(FX_FFREE,0,3'd2,0,0,0,"FFREE ST2");

    // Registered misc service and store/pop path.
    issue_ab(FX_FNINIT,0,0,0,0,0,"FNINIT misc");
    load80(FP_1P5,"FLD 1.5");
    issue_ab(FX_FRNDINT,0,0,0,0,0,"FRNDINT");
    load80(FP_TWO,"FLD scale");
    issue_ab(FX_FSCALE,0,0,0,0,0,"FSCALE");
    issue_ab(FX_FST_M64,0,0,1,0,8,"FSTP m64");

    // One shared SRT remainder engine.
    issue_ab(FX_FNINIT,0,0,0,0,0,"FNINIT rem");
    load80(FP_TWO,"FLD divisor");
    load80(FP_FIVE,"FLD dividend");
    issue_ab(FX_FPREM,0,0,0,0,0,"FPREM");

    // All transcendental commit shapes.  Direct engine A/B tests supply the
    // value proof; this sequence proves top/status/pop/push destinations.
    issue_ab(FX_FNINIT,0,0,0,0,0,"FNINIT trans");
    load80(FP_HALF,"FLD half");
    issue_ab(FX_F2XM1,0,0,0,0,0,"F2XM1");
    issue_ab(FX_FSIN,0,0,0,0,0,"FSIN");
    issue_ab(FX_FCOS,0,0,0,0,0,"FCOS");
    issue_ab(FX_FSINCOS,0,0,0,0,0,"FSINCOS");
    issue_ab(FX_FPTAN,0,0,0,0,0,"FPTAN");
    issue_ab(FX_FNINIT,0,0,0,0,0,"FNINIT binary trans");
    load80(FP_TWO,"FLD y");
    load80(FP_ONE,"FLD x");
    issue_ab(FX_FYL2X,0,0,0,0,0,"FYL2X");
    load80(FP_ONE,"FLD atan x");
    issue_ab(FX_FPATAN,0,0,0,0,0,"FPATAN");

    // Iterative BCD and complete state image round trip.
    issue_ab(FX_FNINIT,0,0,0,0,0,"FNINIT BCD");
    issue_ab(FX_FBLD,0,0,0,80'h00000000000000000123,10,"FBLD");
    issue_ab(FX_FBSTP,0,0,1,0,10,"FBSTP");
    load80(FP_THREE,"FLD env ST0");
    load80(FP_TWO,"FLD env ST1");
    issue_ab(FX_FNSAVE,0,0,0,0,4,"FNSAVE");
    cmd_env_image=expected_env_image;
    issue_ab(FX_FRSTOR,0,0,0,0,4,"FRSTOR");
    issue_ab(FX_FNSTENV,0,0,0,0,4,"FNSTENV");
    issue_ab(FX_FLDENV,0,0,0,0,4,"FLDENV");

    // Route-completeness sweep.  The leaf suites carry the dense numerical
    // vectors; this section makes every remaining supported fxop_e traverse
    // both architectural shells at least once.
    issue_ab(FX_FNINIT,0,0,0,0,0,"FNINIT load sweep");
    issue_ab(FX_FLD_M32,0,0,0,{48'd0,32'h3f800000},4,"FLD m32");
    issue_ab(FX_FLD_M64,0,0,0,{16'd0,64'h4000000000000000},8,"FLD m64");
    issue_ab(FX_FLD_STI,0,1,0,0,0,"FLD ST1");
    issue_ab(FX_FILD_M16,0,0,0,{64'd0,16'hfffe},2,"FILD m16");
    issue_ab(FX_FILD_M32,0,0,0,{48'd0,32'd3},4,"FILD m32");
    issue_ab(FX_FILD_M64,0,0,0,{16'd0,64'd4},8,"FILD m64");
    cmd_constant=3'd3;
    issue_ab(FX_FLDCONST,0,0,0,0,0,"FLDPI");
    cmd_constant=3'd0;

    issue_ab(FX_FNINIT,0,0,0,0,0,"FNINIT store sweep");
    load80(FP_1P5,"FLD store value");
    issue_ab(FX_FST_M32,0,0,0,0,4,"FST m32");
    issue_ab(FX_FST_M80,0,0,0,0,10,"FST m80");
    issue_ab(FX_FIST_M16,0,0,0,0,2,"FIST m16");
    issue_ab(FX_FIST_M32,0,0,0,0,4,"FIST m32");
    issue_ab(FX_FIST_M64,0,0,0,0,8,"FIST m64");
    issue_ab(FX_FNSTCW,0,0,0,0,2,"FNSTCW");
    issue_ab(FX_FNSTSW_M,0,0,0,0,2,"FNSTSW m16");
    issue_ab(FX_FNSTSW_AX,0,0,0,0,0,"FNSTSW AX");
    issue_ab(FX_FLDCW,0,0,0,{64'd0,16'h037f},2,"FLDCW");
    issue_ab(FX_FNCLEX,0,0,0,0,0,"FNCLEX");
    issue_ab(FX_FNOP,0,0,0,0,0,"FNOP");
    issue_ab(FX_FWAIT,0,0,0,0,0,"FWAIT");
    issue_ab(FX_FINCSTP,0,0,0,0,0,"FINCSTP");
    issue_ab(FX_FDECSTP,0,0,0,0,0,"FDECSTP");

    issue_ab(FX_FNINIT,0,0,0,0,0,"FNINIT compare sweep");
    load80(FP_TWO,"FLD compare ST1");
    load80(FP_ONE,"FLD compare ST0");
    issue_ab(FX_FCOM_M32,0,0,0,{48'd0,32'h3f800000},4,"FCOM m32");
    issue_ab(FX_FCOM_M64,0,0,0,{16'd0,64'h4000000000000000},8,"FCOM m64");
    issue_ab(FX_FUCOM_STI,0,1,0,0,0,"FUCOM ST1");
    issue_ab(FX_FCOMPP,0,0,0,0,0,"FCOMPP");
    load80(FP_TWO,"FLD FUCOMPP ST1");
    load80(FP_ONE,"FLD FUCOMPP ST0");
    issue_ab(FX_FUCOMPP,0,0,0,0,0,"FUCOMPP");
    load80(FP_ONE,"FLD compare integer");
    issue_ab(FX_FTST,0,0,0,0,0,"FTST");
    issue_ab(FX_FICOM_M16,0,0,0,{64'd0,16'd1},2,"FICOM m16");
    issue_ab(FX_FICOM_M32,0,0,0,{48'd0,32'd2},4,"FICOM m32");

    issue_ab(FX_FNINIT,0,0,0,0,0,"FNINIT arithmetic sweep");
    load80(FP_TWO,"FLD arithmetic ST1");
    load80(FP_ONE,"FLD arithmetic ST0");
    issue_ab(FX_AR_STI_ST0,3'd0,3'd1,0,0,0,"FADD ST1,ST0");
    issue_ab(FX_AR_M32,3'd0,0,0,{48'd0,32'h3f800000},4,"FADD m32");
    issue_ab(FX_AR_M64,3'd1,0,0,{16'd0,64'h4000000000000000},8,"FMUL m64");
    issue_ab(FX_AR_I16,3'd4,0,0,{64'd0,16'd1},2,"FISUB m16");
    issue_ab(FX_AR_I32,3'd6,0,0,{48'd0,32'd2},4,"FIDIV m32");

    issue_ab(FX_FNINIT,0,0,0,0,0,"FNINIT FPREM1");
    load80(FP_TWO,"FLD FPREM1 divisor");
    load80(FP_FIVE,"FLD FPREM1 dividend");
    issue_ab(FX_FPREM1,0,0,0,0,0,"FPREM1");

    issue_ab(FX_FNINIT,0,0,0,0,0,"FNINIT FYL2XP1");
    load80(FP_ONE,"FLD FYL2XP1 y");
    load80(FP_ZERO,"FLD FYL2XP1 x");
    issue_ab(FX_FYL2XP1,0,0,0,0,0,"FYL2XP1");

    $display("VEN-FP-ARCH-A-B-OK checks=%0d",checks);
    $finish;
  end
endmodule

`default_nettype wire
