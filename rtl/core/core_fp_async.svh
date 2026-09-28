// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Experimental single-owner shared-FP overlap. Included at module scope.
logic fp_async_pending, fp_async_start, fp_async_hold, fp_async_retire_q;
logic fp_async_fault_hold;
`ifdef VEN_FP_REG_ADMIT
`ifndef VEN_FP_ASYNC_STREAM
  initial $fatal(1, "VEN_FP_REG_ADMIT requires VEN_FP_ASYNC_STREAM");
`endif
  // This command already crossed the checked issue boundary and owns q_*.
  // Do not classify it using the live frontend descriptor while it waits.
  // Only masked non-pop register fast arithmetic may overlap older owners;
  // the unchanged leaf still interlocks every register dependency.
  logic fp_async_reg_cmd;
  assign fp_async_reg_cmd = cycle_mode && (state == S_FEXEC) && q_is_x87 &&
      !q_f_mem_read && !q_f_mem_write && !q_f_pop && !q_f_pop2 &&
      ((q_fxop == FX_AR_ST0_STI) || (q_fxop == FX_AR_STI_ST0)) &&
      ((q_f_aluop == 3'd0) || (q_f_aluop == 3'd1) ||
       (q_f_aluop == 3'd4) || (q_f_aluop == 3'd5)) &&
      (fctrl[5:0] == 6'h3f) && !fstat[7] && fp_shared_early_retire_ok &&
      (!sys_mode || (!real_mode && cs_d)) &&
      !fp_dbg_active && !dbg_block_issue;
`endif
`ifdef VEN_FP_MEM_QUEUE
`ifndef VEN_FP_FXCH_QUEUE
  initial $fatal(1, "VEN_FP_MEM_QUEUE requires VEN_FP_FXCH_QUEUE");
`endif
`ifndef VEN_FP_OPERAND_OVERLAP
  initial $fatal(1, "VEN_FP_MEM_QUEUE requires VEN_FP_OPERAND_OVERLAP");
`endif
  // Already-admitted source only. S_FLOAD still needs a complete fragment
  // ACK; S_FEXEC owns the assembled f_mem80. The wrapper owns slot capacity.
  // This shape must not consume ACK/ready/fsm_case_enabled, which depend on
  // async hold and would create a request-gating feedback loop.
  logic fp_async_mem_cmd;
  assign fp_async_mem_cmd = ((state == S_FLOAD) || (state == S_FEXEC)) &&
      q_f_mem_read && !q_f_mem_write && (q_f_mbytes == 4'd4) && !q_f_pop &&
      ((q_fxop == FX_FLD_M32) || (q_fxop == FX_FILD_M32) ||
       ((q_fxop == FX_AR_M32) &&
        ((q_f_aluop == 3'd0) || (q_f_aluop == 3'd1) || (q_f_aluop >= 3'd4)))) &&
      (fctrl[5:0] == 6'h3f) && !fstat[7] && fp_shared_early_retire_ok &&
      !fp_dbg_active && !dbg_block_issue;
`endif
`ifdef VEN_FP_OPERAND_OVERLAP
`ifndef VEN_FP_ASYNC_STREAM
  initial $fatal(1, "VEN_FP_OPERAND_OVERLAP requires VEN_FP_ASYNC_STREAM");
`endif
`ifndef VEN_FP_MEM_ADMIT
  initial $fatal(1, "VEN_FP_OPERAND_OVERLAP requires VEN_FP_MEM_ADMIT");
`endif
  // Reuse the one captured q_*/f_mem80 operand owner. Only acquisition may
  // overlap: S_FEXEC and command acceptance still wait for older owners.
  // No result, TOP/tag, store, or architectural pointer update occurs here.
  logic fp_async_operand_read;
  assign fp_async_operand_read = (state == S_FLOAD) &&
      q_f_mem_read && !q_f_mem_write &&
      ((q_fxop == FX_AR_M32) || (q_fxop == FX_AR_M64) ||
       (q_fxop == FX_FLD_M32) || (q_fxop == FX_FLD_M64) ||
      (q_fxop == FX_FILD_M32) || (q_fxop == FX_FILD_M64)) &&
      (fctrl[5:0] == 6'h3f) && !fstat[7] &&
      !fp_dbg_active;
  // S_FLOAD is already past the checked issue boundary. A later host-debug
  // park must not withdraw its request/ACK while the older FP owner drains:
  // a non-cacheable response is consumable only once and cannot be replayed.
  // dbg_block_issue still prevents admission in S_PIPE and async command
  // retirement; the captured source finishes before the next boundary parks.
`endif
`ifdef VEN_FP_FXCH_QUEUE
`ifndef VEN_FP_ASYNC_STREAM
  initial $fatal(1, "VEN_FP_FXCH_QUEUE core integration requires VEN_FP_ASYNC_STREAM");
`endif
`endif
`ifdef VEN_FP_ASYNC
`ifdef VEN_FP_SHARED
`ifdef VEN_FP_ASYNC_STACK
`ifndef VEN_FP_ASYNC_MEM
  initial $fatal(1, "VEN_FP_ASYNC_STACK requires checked async integer memory");
`endif
`endif
`ifdef VEN_FP_ASYNC_STREAM
`ifndef VEN_FP_ARITH_STREAM
  initial $fatal(1, "VEN_FP_ASYNC_STREAM requires VEN_FP_ARITH_STREAM");
`endif
`ifndef VEN_FP_ASYNC_EARLY
  initial $fatal(1, "VEN_FP_ASYNC_STREAM requires VEN_FP_ASYNC_EARLY");
`endif
`ifndef VEN_FP_SHARED_EARLY_CMD
  initial $fatal(1, "VEN_FP_ASYNC_STREAM requires VEN_FP_SHARED_EARLY_CMD");
`endif
`ifndef VEN_FP_SHARED_DIRECT
  initial $fatal(1, "VEN_FP_ASYNC_STREAM requires VEN_FP_SHARED_DIRECT");
`endif
  logic [2:0] fp_async_count;
  logic fp_async_stream_shape;
  // Raw descriptor eligibility must not consume pipe_fp_live_arm/issue_block:
  // those depend on this hold. The ordinary checked direct arm still owns
  // admission, and the shared FPU independently interlocks register hazards.
  assign fp_async_stream_shape = (state == S_PIPE) && u_d.is_fp && !u_d.is_mem &&
      ((((u_d.fp_kind == FK_ARITH) || (u_d.fp_kind == FK_ARITH_STI)) &&
      ((u_d.fp_aluop == 0) || (u_d.fp_aluop == 1) ||
       (u_d.fp_aluop == 4) || (u_d.fp_aluop == 5)))
`ifdef VEN_FP_FXCH_QUEUE
       || (u_d.fp_kind == FK_FXCH)
`endif
`ifdef VEN_FP_OPERAND_OVERLAP
       // FK_MEM intentionally does not set the integer is_mem flag.
       || ((u_d.fp_kind == FK_MEM) && (u_d.fp_role <= 3'd2))
`endif
      ) &&
      (fctrl[5:0] == 6'h3f) && !fstat[7] && !fp_fast_trap_bail &&
      (!sys_mode || (!real_mode && cs_d));
  assign fp_async_pending = (fp_async_count != 0);
`endif
`ifdef VEN_FP_ASYNC_EARLY
  // Admit the same arithmetic owner at any already-checked command handoff.
  // In S_PIPE q_fxop still names the PREVIOUS instruction; the shared FPU
  // receives the live direct packet, so ownership must classify that packet
  // too. S_FLOAD already has stable q_* and a complete fragment-engine ACK.
  fxop_e fp_async_cmd_op;
`ifdef VEN_FP_SHARED_DIRECT
  assign fp_async_cmd_op = fp_shared_pipe_cmd ? fp_shared_direct_fxop : q_fxop;
`else
  assign fp_async_cmd_op = q_fxop;
`endif
  assign fp_async_start = fp_shared_cmd_valid && fsm_case_enabled &&
      cycle_mode && fp_shared_cmd_ready && !fp_shared_accept_retire &&
`ifdef VEN_FP_ASYNC_STREAM
      ((fp_async_count < 4) || fp_shared_rsp_valid) &&
`else
      !fp_async_pending &&
`endif
      fp_shared_early_retire_ok && !fp_dbg_active &&
      !dbg_block_issue &&
      ((fp_async_cmd_op == FX_AR_ST0_STI) || (fp_async_cmd_op == FX_AR_STI_ST0) ||
       (fp_async_cmd_op == FX_AR_M32) || (fp_async_cmd_op == FX_AR_M64) ||
       (fp_async_cmd_op == FX_AR_I16) || (fp_async_cmd_op == FX_AR_I32) ||
       (fp_async_cmd_op == FX_FSQRT)
`ifdef VEN_FP_FXCH_QUEUE
       || (fp_async_cmd_op == FX_FXCH)
`endif
`ifdef VEN_FP_MEM_QUEUE
       // Idle FLD/FILD is immediate. Only a queued form has accept_retire=0
       // and therefore needs this real, ordered deferred response owner.
       || (fp_async_mem_cmd && ((fp_async_cmd_op == FX_FLD_M32) ||
                               (fp_async_cmd_op == FX_FILD_M32)))
`endif
      );
`else
  // Conservative control: early command handoffs retain their serialized path.
  assign fp_async_start = (state == S_FEXEC) && fsm_case_enabled &&
      cycle_mode && fp_shared_cmd_ready && !fp_shared_accept_retire &&
      !fp_async_pending && fp_shared_early_retire_ok && !fp_dbg_active &&
      !dbg_block_issue &&
      ((q_fxop == FX_AR_ST0_STI) || (q_fxop == FX_AR_STI_ST0) ||
       (q_fxop == FX_AR_M32) || (q_fxop == FX_AR_M64) ||
       (q_fxop == FX_AR_I16) || (q_fxop == FX_AR_I32) ||
       (q_fxop == FX_FSQRT));
`endif

  // Only resident, ordinary integer register packets may pass an unfinished
  // result by default. Opt-in checked memory/stack and direct-branch profiles
  // widen that set; slow decode, x87, invalidated code, debug and external
  // events still drain at the issue boundary. The opt-in
  // branch profile admits only the decoder's simple, non-memory, non-stack
  // Jcc/JMP forms: they read integer flags, not x87 state, and have no data
  // side effect. A later target fault/event still waits for the older FP
  // owner through the existing fault and event gates.
  // Use raw descriptor properties, not pipe_int_commit/fsm_case_enabled:
  // those consume this hold and would create a combinational feedback loop.
  assign fp_async_hold = fp_async_pending &&
`ifdef VEN_FP_REG_ADMIT
      !fp_async_reg_cmd &&
`endif
`ifdef VEN_FP_MEM_QUEUE
      !fp_async_mem_cmd &&
`endif
`ifdef VEN_FP_OPERAND_OVERLAP
      // This instruction already owns its captured descriptor. As with a
      // held integer access, later frontend invalidation/events must not
      // discard it. Translation/fault detours remain deferred separately.
      !fp_async_operand_read &&
`endif
`ifdef VEN_FP_ASYNC_MEM
      // Once admitted, the normal memory owner must consume its ACK even if
      // code is invalidated or an event arrives. Existing PIPE event logic
      // already excludes pipe_mem_active_q. Never withdraw that request just
      // because the independent FP operation has not completed yet.
      !pipe_mem_active_q &&
`endif
      ((state != S_PIPE) || !pipe_frontend_ready || !exec_issue_ok ||
`ifdef VEN_FP_ASYNC_STREAM
       ((!u_d.simple || u_d.is_fp) && !fp_async_stream_shape) ||
`else
       !u_d.simple || u_d.is_fp ||
`endif
`ifndef VEN_FP_ASYNC_MEM
       u_d.is_mem ||
`endif
`ifndef VEN_FP_ASYNC_STACK
       u_d.is_stack ||
`else
       // A simple PUSH/POP uses the same checked, held memory owner as MOV.
       // Async FP admission requires every FP exception masked; the younger
       // integer stack access may therefore overlap until a fault/event gate
       // demands an ordered drain. No slow or 16-bit stack form is admitted.
`endif
`ifndef VEN_FP_ASYNC_BRANCH
       u_d.is_branch ||
`endif
       fp_dbg_active || dbg_block_issue || smi_take || nmi_take || intr_take);

  // Keep this separate from the request/translation hold above: permission
  // and miss signals consume the request classification. Feeding them back
  // into it would make a combinational loop. Existing fault gates already
  // suppress bus/GPR effects; only the FSM's detour must additionally wait.
  assign fp_async_fault_hold = fp_async_pending &&
                               (sync_access_fault || perm_fault || xlate_miss);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
`ifdef VEN_FP_ASYNC_STREAM
      fp_async_count <= 0;
`else
      fp_async_pending <= 1'b0;
`endif
      fp_async_retire_q <= 1'b0;
    end else begin
      fp_async_retire_q <= fp_async_start;
`ifdef VEN_FP_ASYNC_STREAM
      case ({fp_async_start, fp_async_pending && fp_shared_rsp_valid})
        2'b10: fp_async_count <= fp_async_count + 1'b1;
        2'b01: fp_async_count <= fp_async_count - 1'b1;
        default: begin end
      endcase
`else
      if (fp_async_start) fp_async_pending <= 1'b1;
      else if (fp_async_pending && fp_shared_rsp_valid)
        fp_async_pending <= 1'b0;
`endif
`ifndef SYNTHESIS
`ifdef VEN_FP_OPERAND_OVERLAP
      if (fp_async_pending && fp_async_operand_read && mem_ack && fsm_case_enabled &&
          $test$plusargs("ven_fp_operand_log"))
        $display("[FP-OPERAND-OVERLAP] pc=%08x step=%0d owners=%0d", q_pc, f_step, fp_async_count);
      if (fp_async_pending && (state == S_FLOAD) && fp_shared_cmd_valid
`ifdef VEN_FP_MEM_QUEUE
          && !fp_async_mem_cmd
`endif
         )
        $fatal(1, "FP_OPERAND: younger command escaped acquisition-only ownership");
`endif
      if (fp_async_fault_hold && $test$plusargs("ven_fp_async_log"))
        $display("[FP-ASYNC-DRAIN] pc=%08x pending=1 seg=%0b perm=%0b walk=%0b",
                 eip, sync_access_fault, perm_fault, xlate_miss);
      if (fp_async_fault_hold && (pipe_int_commit || bd_req || gpr_we != '0))
        $fatal(1, "FP_ASYNC: side effect escaped deferred fault/walk");
      if (fp_async_pending && fp_shared_rsp_valid &&
          (fp_shared_rsp_store_valid || fp_shared_rsp_ax_valid || fp_shared_rsp_unsupported))
        $fatal(1, "FP_ASYNC: unexpected payload/unsupported response");
`ifdef VEN_FP_ASYNC_STREAM
      if (fp_async_count > 4) $fatal(1, "FP_ASYNC: owner capacity exceeded");
`ifdef VEN_FP_REG_ADMIT
      // A ready leaf must never accept outside the core's permitted edge.
      if (fp_async_pending && fp_async_reg_cmd && !fsm_case_enabled &&
          fp_shared_cmd_valid)
        $fatal(1, "FP_REG_ADMIT: command valid during blocked FSM");
      if (fp_async_reg_cmd && fp_async_count == 4 && !fp_shared_rsp_valid &&
          fp_shared_cmd_valid)
        $fatal(1, "FP_REG_ADMIT: command valid without owner capacity");
`endif
      // A direct FXCH can arrive on the final older response's consumer edge.
      // The leaf is idle and commits that exchange immediately; S_PIPE retires
      // it on this edge, so it must NOT allocate a deferred owner. Only allow
      // this exact drain-to-immediate boundary, not an arbitrary unowned accept.
      if (fp_async_pending && fp_shared_cmd_valid && fp_shared_cmd_ready && !fp_async_start &&
          !(fp_shared_accept_retire && fp_shared_rsp_valid && fp_async_count == 1 &&
            fsm_case_enabled && fp_shared_early_retire_ok &&
            !fp_dbg_active && !dbg_block_issue &&
            ((fp_shared_pipe_cmd && fp_async_cmd_op == FX_FXCH)
`ifdef VEN_FP_MEM_QUEUE
             || (fp_async_mem_cmd && ((fp_async_cmd_op == FX_FLD_M32) ||
                                     (fp_async_cmd_op == FX_FILD_M32)))
`endif
            )))
        $fatal(1, "FP_ASYNC: command accepted without ordered owner count=%0d op=%0d immediate=%0b rsp=%0b pipe=%0b enabled=%0b",
               fp_async_count, fp_async_cmd_op, fp_shared_accept_retire,
               fp_shared_rsp_valid, fp_shared_pipe_cmd, fsm_case_enabled);
`else
      if (fp_async_pending && fp_shared_cmd_valid && fp_shared_cmd_ready)
        $fatal(1, "FP_ASYNC: second command while owner pending");
`endif
`ifdef VEN_FP_MEM_QUEUE
      if ($test$plusargs("ven_fp_mem_queue_log")) begin
        if (fp_async_start && fp_async_mem_cmd)
          $display("[FP-MEM-QUEUE] ACCEPT pc=%08x owners=%0d op=%0d data=%08x",
                   q_pc, fp_async_count, q_fxop, fp_shared_cmd_mem[31:0]);
        if (pipe_int_commit && fp_async_count >= 2)
          $display("[FP-MEM-QUEUE] INTEGER pc=%08x owners=%0d", pipe_commit_eip, fp_async_count);
      end
`endif
`endif
    end
  end
`else
  initial $fatal(1, "VEN_FP_ASYNC requires VEN_FP_SHARED");
  assign fp_async_start=1'b0, fp_async_pending=1'b0;
  assign fp_async_hold=1'b0, fp_async_retire_q=1'b0;
  assign fp_async_fault_hold=1'b0;
`endif
`else
  assign fp_async_start=1'b0, fp_async_pending=1'b0;
  assign fp_async_hold=1'b0, fp_async_retire_q=1'b0;
  assign fp_async_fault_hold=1'b0;
`endif
