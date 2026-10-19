// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Reuse the reference decoder's complete scalar memory packet, never a new
// decoder or FPU command producer. The existing load/store probe and execution
// states still own all operand faults and irreversible shared-FPU commands.
logic pipe_fp_scalar_dispatch_ok;
`ifdef VEN_FP_SCALAR_DISPATCH
`ifndef VEN_FP_SHARED
  initial $fatal(1, "scalar FP dispatch requires the shared FPU probe path");
`endif
`ifndef VEN_FP_SHORT_WINDOW
  initial $fatal(1, "scalar FP dispatch requires checked exact x87 bytes");
`endif
  assign pipe_fp_scalar_dispatch_ok = (state == S_PIPE) && cycle_mode &&
      pipe_fp_short_window_ok && !def16 && !d_unknown && d_is_x87 &&
      !d_lock && !d_is_fwait && (d_f_mem_read ^ d_f_mem_write) &&
      (d_fxop inside {FX_FLD_M32, FX_FLD_M64, FX_FLD_M80,
          FX_FILD_M16, FX_FILD_M32, FX_FILD_M64,
          FX_FST_M32, FX_FST_M64, FX_FST_M80,
          FX_FIST_M16, FX_FIST_M32, FX_FIST_M64,
          FX_FCOM_M32, FX_FCOM_M64, FX_AR_I16, FX_AR_I32}) &&
      (!sys_mode || (sys_fp_ok && !real_mode && !v86 && cs_d)) &&
      !creg0[2] && !creg0[3] && !fstat[7] &&
      !fp_async_pending && !fp_shared_busy && !fp_dbg_active &&
      !dbg_block_issue && !dbg_step_active && !irq_shadow &&
      !smi_take && !nmi_take && !intr_take && !pipe_agi &&
      (mispred_bubbles == 0) && (stall_cnt == 0) && (pending_mem_pen == 0);
`else
  assign pipe_fp_scalar_dispatch_ok = 1'b0;
`endif
