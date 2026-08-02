// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/core_fenv.svh — RAW case-arms `included inside core.sv's always_ff FSM
// `unique case (state)` (M11b). NOT a standalone unit. Covers the x87 environment/
// state SAVE (S_FENV_ST: FNSTENV 28B / FNSAVE 108B) and the LOAD (S_FENV_LD:
// FLDENV / FRSTOR) variable-length transfers, mirroring the SMM beat loop
// (core_smm.svh): one dword per wide beat (f_seq_step), driven by the bus arm
// (core_bus_driver.svh) at dbase+q_ea+4*f_seq_step; the store data comes from the
// flat fenv_image; the load latches each beat into env_tmp[] then commits.
//
// f_seq_last = 6 for the 28-byte env (FNSTENV/FLDENV), 26 for the 108-byte full
// state (FNSAVE/FRSTOR). FNSTENV has NO post-store side effect (this qemu does not
// mask exceptions); FNSAVE reinitializes (fp_we_fninit, driven on the last beat by
// the fp_we_* combinational block). The graded trace pointer/tag fields stay 0.
        // ===================================================================
        // M11b — x87 env/state SAVE (S_FENV_ST). One dword per beat from the flat
        // fenv_image; retire on the last beat. (FLDENV/FRSTOR loads = S_FENV_LD,
        // added with the load increment.)
        // ===================================================================
        S_FENV_ST: begin
          if (mem_ack) begin
            if (f_seq_step == fenv_last) begin   // M-04: one definition (core.sv)
              // last beat: advance EIP + retire (FNSAVE's FNINIT reinit rides
              // fp_we_fninit from the fp_we_* block on this same beat).
              eip<=next_eip; retire_valid<=1'b1; x87_touched_r<=1'b1;
              state<=S_PIPE; f_seq_step<=6'd0;
            end else f_seq_step <= f_seq_step + 6'd1;
          end
        end

        // ===================================================================
        // M11b — x87 env/state LOAD (S_FENV_LD: FLDENV / FRSTOR). Latch each read
        // dword into env_tmp[]; on the last beat the fp_we_* block commits CW/SW/
        // TOP/tags (+ regs for FRSTOR) and we retire. CW/SW are loaded verbatim
        // (no masking); the tag word is re-derived from the loaded FTW.
        // ===================================================================
        S_FENV_LD: begin
          if (mem_ack) begin
            // REVIEW1_Aug2 M-04: the 14-byte form delivers one WORD per beat, right-
            // justified by the memory subsystem. Zero-extending keeps the commit block
            // below unchanged -- it already reads CW/SW/FTW as env_tmp[n][15:0], which
            // is the whole of each 16-bit field.
            env_tmp[f_seq_step] <= (q_f_mbytes == 4'd2) ? {16'd0, mem_rdata[15:0]}
                                                        : mem_rdata;
            if (f_seq_step == fenv_last) begin   // M-04: one definition (core.sv)
              eip<=next_eip; retire_valid<=1'b1; x87_touched_r<=1'b1;
              state<=S_PIPE; f_seq_step<=6'd0;
            end else f_seq_step <= f_seq_step + 6'd1;
          end
        end
