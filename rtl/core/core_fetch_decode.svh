// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/core_fetch_decode.svh — RAW case-arm text `included inside core.sv's
// always_ff `unique case (state)` (R2 modularization). NOT a standalone unit
// (no module/always wrapper); pasted verbatim at the original FSM site, netlist
// identical. Covers the fetch + in-FSM decode-commit/dispatch arms:
//   S_FETCH (16-byte fetch window), S_DECODE (prefix/length/operand decode +
//   the SYS_* -> S_LGDT/S_SEGLD/S_LJMP/S_LTR routing and load/exec dispatch).
        S_FETCH: begin
          if (mem_ack) begin
            ibuf[{fetch_word,2'b00}+0]<=mem_rdata[7:0];
            ibuf[{fetch_word,2'b00}+1]<=mem_rdata[15:8];
            ibuf[{fetch_word,2'b00}+2]<=mem_rdata[23:16];
            ibuf[{fetch_word,2'b00}+3]<=mem_rdata[31:24];
            if (fetch_word==3'(IWORDS-1)) begin fetch_word<=3'd0; state<=S_DECODE; end
            else fetch_word<=fetch_word+3'd1;
          end
        end

        S_DECODE: begin
          // M2S.6 (gated sys_mode): snapshot the TF/RF the about-to-execute
          // instruction RUNS UNDER (so the #DB checks at its RETIRE boundary use
          // the issue-time flags, not the post-modified ones — a POPF that SETS TF
          // must not itself step-trap; the trap fires after the NEXT instruction).
          // EFLAGS.RF (resume flag) suppresses an instruction breakpoint for
          // exactly THIS one instruction and the CPU clears it once the instruction
          // retires; clearing it here makes the post-retire EFLAGS show RF=0 (qemu
          // does the same). A SMI/#DB diversion does not reach the normal dispatch,
          // so these are still issue-time-correct.
          if (sys_mode) begin
            tf_at_issue <= eflags[8];
            rf_at_issue <= eflags[16];
            if (eflags[16]) eflags <= eflags & ~32'h0001_0000;  // RF clears after 1 insn
          end
          q_len<=d_len; q_is_branch<=d_is_branch; q_branch_taken<=d_branch_taken;
          q_rel<=d_rel; q_alu_op<=d_alu_op; q_writes_reg<=d_writes_reg;
          q_writes_flags<=d_writes_flags; q_mem_read<=d_mem_read; q_mem_write<=d_mem_write;
          q_mem_dst<=d_mem_dst; q_dst_reg<=d_dst_reg; q_src_reg<=d_src_reg; q_imm<=d_imm;
          q_use_imm<=d_use_imm; q_is_push<=d_is_push; q_is_pop<=d_is_pop; q_is_lea<=d_is_lea;
          q_is_mov<=d_is_mov; q_ea<=d_ea; q_pc<=eip; q_w<=d_w; q_dst_high8<=d_dst_high8;
          q_src_high8<=d_src_high8; q_kind<=d_kind; q_shrot<=d_shrot; q_shift_cl<=d_shift_cl;
          q_shift_one<=d_shift_one; q_shift_imm<=d_shift_imm; q_shrd<=d_shrd; q_md<=d_md;
          q_imul_3op<=d_imul_3op; q_imul_imm<=d_imul_imm; q_ext_signed<=d_ext_signed;
          q_ext_srcw<=d_ext_srcw; q_cc<=d_cc; q_bit_imm<=d_bit_imm; q_bit_op<=d_bit_op;
          q_conv_cdq<=d_conv_cdq; q_sm<=d_sm; q_st<=d_st; q_rep<=(pfx_rep==2'd3);
          q_repne<=(pfx_rep==2'd2); q_str_loadsi<=d_str_loadsi; q_str_storedi<=d_str_storedi;
          q_str_scandi<=d_str_scandi; q_ct<=d_ct; q_ret_imm<=d_ret_imm;
          q_cld<=d_cld; q_std<=d_std; step<=4'd0;
          q_clc<=d_clc; q_stc<=d_stc; q_cmc<=d_cmc; q_cnt16<=d_cnt16;
          q_cli<=d_cli; q_sti<=d_sti; q_br16<=d_br16;
          // M8.1: the STI/MOV-SS interrupt shadow lasts exactly ONE instruction.
          // It was set in S_EXEC by the STI; this S_DECODE (the boundary BEFORE the
          // shadowed instruction) still sees it set in the combinational intr_take
          // (registered value), correctly masking INTR for this one boundary, and we
          // clear it here so the NEXT boundary is open. Unconditional + harmless:
          // INERT when soc_en==0 (irq_shadow is never read). The divert branches
          // below only change `state`, never irq_shadow, so this is not clobbered.
          irq_shadow <= 1'b0;
          // M7.3b IN/OUT latch: resolve the port (imm8 zero-extended, or DX[15:0]).
          q_io<=d_io; q_io_write<=d_io_write; q_io_w<=d_io_w;
          q_io_port<= d_io_imm ? {8'd0, d_io_port_imm} : gpr[R_EDX][15:0];
          // latch x87 decode
          q_fxop<=d_fxop; q_is_x87<=d_is_x87; q_f_mem_read<=d_f_mem_read;
          q_f_mem_write<=d_f_mem_write; q_f_mbytes<=d_f_mbytes; q_f_pop<=d_f_pop;
          q_f_pop2<=d_f_pop2; q_f_sti<=d_f_sti; q_f_aluop<=d_f_aluop; q_f_const<=d_f_const;
          f_step<=4'd0;
          // M2S.1 system decode latch.
          q_sysop<=d_sysop; q_sys_sreg<=d_sys_sreg; q_sys_creg<=d_sys_creg;
          q_seg<=d_seg; q_ljmp_off<=d_ljmp_off; q_ljmp_sel<=d_ljmp_sel;
          q_seg_load<=d_seg_load; q_lseg<=d_lseg;   // M9.5 LES/LDS/LSS/LFS/LGS
          q_push_sreg<=d_push_sreg; q_pop_sreg<=d_pop_sreg;   // F3 PUSH/POP sreg
          q_seg_load_lo<=d_seg_load_lo;                       // F3 MOV Sreg,[mem]
          q_store_sreg<=d_store_sreg;                         // F3 MOV [mem],Sreg
          seg_step<=1'b0;
          // M2S.3 INT/IRET/UD2 are dispatched directly from the d_* decode below
          // (they begin their micro-sequence in S_DECODE), so no q_* latch is
          // needed: the delivery state is captured in int_* / iret_* instead.

          // ---- M2S.5 SMI# recognition (gated sys_mode) ----------------------
          // A recognised SMI# is taken at the instruction boundary, BEFORE this
          // instruction executes (so it does not retire). Save the resume EIP =
          // the current EIP (this instruction restarts after RSM) and divert to
          // S_SMI_SAVE. smm_active blocks re-entrant SMI (SMI is masked in SMM).
          // This takes priority over the decoded instruction below.
          if (smi_pending && sys_mode && !smm_active) begin
            smi_pending    <= 1'b0;
            smm_resume_eip <= eip;          // restart this instruction after RSM
            smm_step       <= 6'd0;
            state          <= S_SMI_SAVE;
          end
          // ---- M8.1 EXTERNAL INTERRUPT divert (gated soc_en) -----------------
          // ADDED to the existing instruction-boundary priority chain RIGHT AFTER
          // the SMI# block (SMI > NMI > INTR). An external interrupt is taken
          // BEFORE the about-to-run instruction executes (it does NOT retire) —
          // exactly like the SMI# above and a hardware fault — and is delivered
          // through the SAME verified S_INT_GATE -> S_INT_CS -> S_INT_PUSH IDT FSM
          // via the int_sw=0 (hardware) entry, reusing start_fault VERBATIM:
          //   * the pushed EIP = the CURRENT eip (the next instruction to run, so
          //     IRET resumes it). This is the int_ret_eip a HW fault uses (restart).
          //   * has_err=0, err=0 (external interrupts carry no error code).
          //   * int_sw=0 -> the S_INT_GATE gate.DPL>=CPL check is bypassed (it
          //     applies only to SOFTWARE INT n) AND the IF/TF clear on an
          //     interrupt-gate entry happens in S_INT_PUSH from the gate type read
          //     out of the IDT, just like every HW fault. V86/IOPL is handled by
          //     the SAME downstream FSM (S_INT_CS from_v86 path), so no extra logic
          //     is needed here.
          // ENTIRELY INERT when soc_en==0 (nmi_take/intr_take are 0), so this whole
          // branch is dead and every existing gate is byte-identical.
          //
          // NMI (vector 2) is non-maskable and sets nmi_in_progress (blocks a
          // further NMI until the IRET that ends the handler — see S_DECODE d_iret);
          // it does NOT pulse inta. A maskable INTR pulses inta this clock and the
          // PIC supplies inta_vector COMBINATIONALLY, latched here as the vector.
          else if (nmi_take) begin
            nmi_pending     <= 1'b0;            // consume the latched edge
            nmi_in_progress <= 1'b1;            // mask further NMI until IRET
            start_fault(8'd2, 1'b0, 32'd0, eip);
          end
          else if (intr_take) begin
            // inta pulsed combinationally THIS clock; the PIC has driven the vector
            // back on inta_vector. Deliver through IDT[inta_vector], int_sw=0.
            start_fault(inta_vector, 1'b0, 32'd0, eip);
          end
          // ---- M2S.6 GD general-detect (#DB before a MOV-DR access; gated
          // sys_mode + DBG_GD_ENABLE). This is the ONE #DB that fires BEFORE its
          // instruction (no preceding instruction to fuse with): a MOV to/from a DR
          // while DR7.GD=1 faults (DR6.BD) before the access, restarting the MOV.
          // qemu 8.2.2 does NOT model GD, so this is DEFERRED (DBG_GD_ENABLE=0) to
          // keep the differential diff matching the golden's exactly-3 #DB; the
          // decision is wired so a future structural self-check can flip the gate.
          else if (DBG_GD_ENABLE && sys_mode &&
                   (d_sysop==SYS_MOVDR_TO || d_sysop==SYS_MOVDR_FROM) && dr7[DR7_GD]) begin
            arm_db(32'd1 << DR6_BD, eip, eip);   // FAULT before the MOV-DR access
          end
          // ---- M2S.6 DR4/DR5 alias vs #UD on CR4.DE (debug extensions). When
          // CR4.DE (creg4[3]) == 0, DR4/DR5 ALIAS DR6/DR7 (legacy); when CR4.DE == 1
          // (P5 debug-extensions enabled) a MOV to/from DR4 or DR5 is #UD (vector 6,
          // no error code, a FAULT — push the faulting EIP). This matches qemu's
          // helper_get_dr/helper_set_dr (raise EXCP06_ILLOP when DE && reg>=4). The
          // alias path itself is handled in S_EXEC (CR4.DE==0). The corpus keeps
          // CR4.DE==0 throughout so this #UD path is never taken there (the gate
          // stays bit-identical) — it makes the RTL spec-faithful for DE=1.
          else if (sys_mode && creg4[3] &&
                   (d_sysop==SYS_MOVDR_TO || d_sysop==SYS_MOVDR_FROM) &&
                   (d_sys_creg==3'd4 || d_sys_creg==3'd5)) begin
            int_vec     <= 8'd6;       // #UD
            int_ret_eip <= eip;        // FAULT: push the faulting EIP (restart)
            int_src_pc  <= eip;
            int_has_err <= 1'b0;       // #UD carries no error code
            int_err     <= 32'd0;
            int_step    <= 4'd0;
            int_sw      <= 1'b0;       // HW fault: bypass the gate DPL>=CPL check
            state       <= S_INT_GATE;
          end
          // ---- M7.2 V86 IOPL GUARD (method-1 / VME-OFF) ---------------------
          // Under V86 (v86 = sys_mode && EFLAGS.VM) with IOPL < 3, the IOPL-
          // SENSITIVE instructions CLI / STI / PUSHF / POPF / INT n / IRET (and
          // IN/OUT — not in this core's decode, out-of-scope, see the manifest's
          // documented follow-on) do NOT execute: they raise #GP(0) and trap to
          // the CPL0 monitor (IA-32 SDM Vol.3 method-1). At IOPL==3 they would run
          // normally (the `iopl < 3` guard makes this fall through). The #GP is a
          // FAULT delivered through IDT[13]: it pushes the 9-word V86 frame on the
          // monitor stack (S_INT_PUSH from_v86 path), an error code 0 (has_err=1,
          // err=0 — the monitor discards it), and the FAULTING V86 EIP (eip) so the
          // monitor can decode the opcode + advance EIP itself. This whole branch
          // is INERT when EFLAGS.VM==0 (v86==0), so every prior gate is unchanged.
          // INT3 (0xCC) and INTO (0xCE) are NOT trapped here: only the INT n
          // IMMEDIATE form (0xCD ib, d_int_imm) is IOPL-sensitive in V86. INT3/INTO
          // have distinct V86 semantics (#BP/#OF vectoring) that the golden never
          // exercises — left as a documented follow-on rather than guessing an
          // un-oracled behaviour. The pv86 corpus uses CLI/STI/PUSHF/POPF/INT n.
          else if (v86 && iopl < 2'd3 &&
                   (d_cli || d_sti ||
                    (d_kind==K_STKMISC && (d_sm==SM_PUSHF || d_sm==SM_POPF)) ||
                    d_int_imm || d_iret)) begin
            // #GP(0) to the CPL0 monitor: vector 13, error code 0, FAULT (push the
            // faulting V86 EIP so the monitor restarts/advances it). int_sw=0 so the
            // hardware-fault path bypasses the gate DPL>=CPL check.
            start_fault(8'd13, 1'b1, 32'd0, eip);
            // ---- M6B Erratum 79 (errata_en[ERR_DBGP], default OFF) ------------
            // The IOPL-sensitive POPF/IRET trapped to #GP WITHOUT accessing the
            // stack, so a data breakpoint armed on SS:ESP must NOT fire. On the
            // affected steppings it ERRONEOUSLY does: compute the SS:ESP linear
            // address (V86 SS base = SS<<4, held in seg_base[SG_SS]) and ask
            // dr_match for a DATA-write/read breakpoint hit (want_x=0). If the
            // erratum is enabled and ONLY for POPF/IRET (the documented operands —
            // NOT CLI/STI/PUSHF/INT n, which are the negative control), latch the
            // matched DR6.Bn bits so the #GP delivery's last beat chains an
            // erroneous #DB whose saved CS:EIP = the #GP handler's first
            // instruction. With the flag OFF this whole compare is dead (no chain),
            // so only the #GP is delivered — the documented clean Expected.
            if (errata_en[ERR_DBGP] &&
                ((d_kind==K_STKMISC && d_sm==SM_POPF) || d_iret)) begin
              logic [3:0] ssp_hit;
              ssp_hit = dr_match(seg_base[SG_SS] + gpr[R_ESP], 1'b0);
              if (ssp_hit != 4'd0) begin
                err79_pending  <= 1'b1;
                err79_dr6_bits <= ssp_hit;
              end
            end
          end
          // ---- M7.3b PORT I/O dispatch (IN/OUT) ------------------------------
          // Three cases, in priority order:
          //  (1) cosim_en: EXECUTE the I/O through the io_* bus (S_IO). An IN takes
          //      its value from the replayed golden dev_in; an OUT drives the CPU's
          //      own AL/AX/eAX out. This is the ONLY place env input is injected.
          //  (2) !cosim_en + `out <port>,al` to 0xf4: the isa-debug-exit terminator
          //      (M2S sys tests). EXACTLY the prior behaviour — HALT with NO extra
          //      retire (the golden ends BEFORE the out 0xf4, so retiring it would
          //      desync the sys gate). The port is q_io_port-equivalent: an imm8
          //      (E6) or DX (EE); the sys test uses `outb %al,%dx` with dx=0xF4.
          //  (3) !cosim_en + any other IN/OUT: a genuine out-of-scope op outside
          //      co-sim -> HALT LOUDLY (no retire), exactly as the pre-M7.3b
          //      d_unknown path did (the corpus never uses port I/O elsewhere).
          else if (d_io) begin
            // INS (string port-input) routes to its dedicated per-element handshake
            // S_INS (it is BOTH d_io and a K_STR); plain IN/OUT routes to S_IO.
            // M8.1: the ventium_soc (soc_en=1) drives REAL device I/O — the PMIO
            // decoder routes IN/OUT to ven_pic/ven_pit over the SAME io_* seam the
            // co-sim uses (so soc_en, like cosim_en, EXECUTES IN/OUT through S_IO),
            // with the SOLE exception of the isa-debug-exit terminator `out 0xf4`
            // which still HALTs with no retire (the trace ends BEFORE the out, so
            // the checkpoint is read at the post-readback point — matches qemu).
            // The port at this boundary is the imm8 (E6) or DX[15:0] (EE); the
            // exit uses `outb %al,%dx` with dx=0xF4. ENTIRELY INERT when both
            // cosim_en==0 and soc_en==0: the existing !cosim path is unchanged
            // (HALT on any IN/OUT), so every existing gate is byte-for-byte the
            // same.
            if (cosim_en && d_kind==K_STR && d_st==ST_INS) state <= S_INS;
            else if (cosim_en)                             state <= S_IO;
            // SoC: execute device I/O via S_IO, except the `out 0xf4` exit -> HALT.
            else if (soc_en) begin
              if (d_io_write &&
                  (d_io_imm ? ({8'd0, d_io_port_imm}==16'h00F4)
                            : (gpr[R_EDX][15:0]==16'h00F4)))
                state <= S_HALT;          // isa-debug-exit terminator (no retire)
              else if (d_kind==K_STR && d_st==ST_INS) state <= S_INS;
              else                                    state <= S_IO;
            end
            // Outside co-sim/SoC: `out 0xf4` is the clean isa-debug-exit terminator
            // (HALT, no retire); every other IN/OUT is a loud out-of-scope HALT.
            // Either way -> S_HALT with NO retire (matches the pre-M7.3b path
            // exactly, so the sys gates are byte-for-byte unchanged).
            else          state <= S_HALT;
          end
          // ---- M7.1 int-0x80 PROXY (user-mode Quake lock-step) ---------------
          // When proxy_en is set, an `int 0x80` does NOT halt. We apply the GOLDEN
          // kernel effects the TB drives back this clock (sampled off our
          // syscall_active pulse) and resume WITHOUT executing the kernel:
          //   * eax <- syscall_eax   (the kernel return value)
          //   * if syscall_apply_gs: latch the %gs TLS base (installed into
          //            seg_base[GS] when the program later does `mov gs,0x33`)
          // The TB has already applied the kernel memory writes to its bus memory.
          //
          // FOLDED-INSTRUCTION semantics (the load-bearing subtlety): QEMU's
          // -one-insn-per-tb single-step over `cd80` runs the kernel AND the guest
          // instruction immediately after cd80 in ONE step, so the GOLDEN record at
          // the int-0x80 carries pc=<int> but post-state = (kernel ret) + (that
          // following instruction's effect). The following insn is either a plain
          // op (e.g. `test eax,eax` / `xchg edx,ebx`) for a direct `int 0x80`, or a
          // `ret` for the musl vDSO __kernel_vsyscall stub (`cd80; c3`). To
          // reproduce this EXACTLY without a kernel, we do NOT retire the int here:
          // we advance EIP past cd80 (eip+len) and let the core EXECUTE that
          // following instruction through the normal FSM — its natural effect
          // (register/flag write, or the `ret` pop+branch) lands on the SINGLE
          // retire we then emit, whose pc we OVERRIDE back to the int's pc
          // (fold_pc_r) so it aligns with the golden record. So one golden
          // int-0x80 record == one RTL retire = (kernel eax) + (folded insn). The
          // golden's next-record pc (syscall_resume_eip) is carried only as a TB
          // cross-check; the RTL derives the resume EIP by actually running the
          // folded insn. Gated entirely on proxy_en && d_int80.
          else if (proxy_en && d_int80) begin
`ifdef VEN_PS_PROXY
            // PS-bridge (F4): the PS answers microseconds later, so commit NOTHING
            // now — park eip at cd80, leave fold disarmed and gpr/gs unlatched, and
            // wait in S_SYSCALL_WAIT for syscall_resp_valid (mirrors the S_IO stall
            // discipline). syscall_active still pulses this one S_DECODE clock; the
            // args/n stay stable across the wait (no retire ticks cn). Latch only the
            // int80 length so the wait arm can advance eip on the late commit.
            q_proxy_len <= d_len;
            state       <= S_SYSCALL_WAIT;
`else
            gpr[0] <= syscall_eax;               // eax = kernel ret (pre-folded-insn)
            if (syscall_apply_gs)
              gs_base_r <= syscall_gs_base;      // latch the TLS base for `mov gs`
            eip <= eip + {28'd0, d_len};         // step past cd80 to the folded insn
            fold_pending_r <= 1'b1;              // the next retire IS this syscall's
            fold_pc_r      <= eip;               // ...and carries the int's pc
            fetch_word     <= 3'd0;
            state          <= S_FETCH;           // run the folded insn via the FSM
`ifdef M7_PROXY_DEBUG
            $display("[M7DBG] proxy int80 @0x%08x cn=%0d eax<=0x%08x apply_gs=%0d gs_base<=0x%08x",
                     eip, cn, syscall_eax, syscall_apply_gs, syscall_gs_base);
`endif
`endif
          end
          else if (d_halt || d_unknown) begin
            // M5 finding [low]: in CYCLE mode the oracle emits a retire record for
            // the terminating `int 0x80` (it is a retired instruction to the TCG
            // plugin), so the RTL must too — otherwise the cycle trace is one
            // record short of the golden and compare.py reports a LENGTH MISMATCH
            // (harmless under the current gate, which ignores compare's exit code,
            // but it would fail a tightened gate that honored it). Emit ONE retire
            // for a genuine HALT syscall (d_halt) and THEN stop. d_unknown (an
            // out-of-scope opcode) stays a LOUD no-retire HALT — never a record, so
            // an unsupported opcode can never masquerade as a clean run. Func mode
            // keeps the M0/QEMU-gdbstub convention (no post-state row for the exit
            // syscall), so this extra retire is cycle-mode only and cannot perturb
            // the functional gates.
            if (cycle_mode && d_halt && !d_unknown) begin
              q_pc<=eip; retire_valid<=1'b1;
              retire_pipe_valid<=1'b1; retire_pipe<=2'd0; retire_paired<=1'b0;
            end
            // M6 Erratum 81 (F00F): the invalid LOCK CMPXCHG8B reg-dst form. With
            // errata enabled AND the LOCK prefix present, reproduce the documented
            // HANG (the bus stays locked so the #UD handler never starts) instead
            // of the clean loud HALT. The non-locked invalid form, and the valid
            // memory form (mod!=11, never d_f00f), still take the clean HALT path.
            if (d_f00f && errata_en[ERR_F00F] && pfx_lock)
              state<=S_F00F_HANG;
            else
              state<=S_HALT;
          end
          else if (d_is_x87) begin
            // M11b: env/state ops own a dedicated wide-beat sequencer.
            if (d_fxop==FX_FNSTENV || d_fxop==FX_FNSAVE)  begin f_seq_step<=5'd0; state<=S_FENV_ST; end
            else if (d_fxop==FX_FLDENV || d_fxop==FX_FRSTOR) begin f_seq_step<=5'd0; state<=S_FENV_LD; end
            else if (d_f_mem_read) state<=S_FLOAD;  // read mem operand first
            else state<=S_FEXEC;                    // reg/const/control op
          end
          // ---- M2S.3 IDT delivery: software INT n / INT3 / INTO / UD2 --------
          // These are TRAPS except UD2 (#UD, a FAULT). A TRAP pushes the EIP of
          // the NEXT instruction (so IRET resumes after the INT); UD2 (#UD) is a
          // FAULT and pushes the FAULTING EIP (this instruction). INTO only
          // delivers when OF is set — otherwise it is a no-op that just advances.
          // None of these carry an error code (#UD has none either).
          else if (d_int || d_ud2) begin
            if (d_int && d_int_cond_of && !eflags[11]) begin
              state<=S_EXEC;            // INTO with OF=0: no-op, advance EIP
            end else begin
              int_vec     <= d_ud2 ? 8'd6 : d_int_vec;
              // FAULT (#UD) pushes the faulting EIP; a TRAP (INT/INT3/INTO)
              // pushes the NEXT EIP. In S_DECODE q_pc/q_len are not yet latched,
              // so derive next-EIP from the live eip + decoded length.
              int_ret_eip <= d_ud2 ? eip : (eip + {28'd0, d_len});
              int_src_pc  <= eip;
              int_has_err <= 1'b0;      // INT/INT3/INTO/#UD: no error code
              int_err     <= 32'd0;
              int_step    <= 4'd0;
              // SOFTWARE INT n/INT3/INTO are subject to the gate DPL>=CPL check
              // (IA-32 6.12.1.2); #UD (d_ud2) is a HARDWARE fault that bypasses it.
              int_sw      <= d_int && !d_ud2;
              // F3: PURE real mode (PE=0) delivers through the 4-byte IVT (S_RMINT_RD);
              // V86 + protected mode keep the 8-byte IDT-gate path (S_INT_GATE).
              state       <= real_mode ? S_RMINT_RD : S_INT_GATE;
            end
          end
          else if (d_iret) begin
            // F3: real-mode IRET pops a 16-bit FLAGS:CS:IP frame (S_RMIRET); V86/PM
            // keep the 32-bit S_IRET pop (incl. the descriptor reload / priv return).
            int_step <= 4'd0; int_src_pc <= eip; state <= real_mode ? S_RMIRET : S_IRET;
            // M8.1: IRET ends an interrupt/NMI handler -> re-arm NMI (clear the NMI
            // block, IA-32). nmi_in_progress is only ever SET in the soc_en NMI
            // divert, so this clear is a no-op (stays 0) when soc_en==0 — INERT.
            nmi_in_progress <= 1'b0;
          end
          // ---- M2S.5 RSM (0F AA): leave SMM, restore the saved state ---------
          else if (d_rsm) begin
            int_src_pc <= eip;   // stamp the RSM insn's PC on the resume retire
            smm_step   <= 6'd0;
            state      <= S_RSM;
          end
          // ---- M2S.1 system instructions ------------------------------------
          else if (d_sysop != SYS_NONE) begin
            unique case (d_sysop)
              SYS_LGDT, SYS_LIDT: state<=S_LGDT;    // read 6-byte pseudo-desc
              SYS_MOVSREG_TO: begin
                // load a segment register. In REAL mode (or a null/PM-but-here
                // we keep it simple) compute the hidden base directly; in
                // PROTECTED mode read the 8-byte descriptor from the GDT first.
                // M7.1 USER+proxy: a linux-user `mov sreg,r16` has NO GDT to walk
                // (this user core never sets up a GDT) — handle it FLAT in S_EXEC:
                // selector := value; base := (GS & sel==0x33) ? latched gs_base : 0.
                // (Without proxy_en this stays the M2S.1 sys-only path, untouched.)
                // M7.2 V86: a MOV Sreg, r16 under V86 (seg_real) loads the hidden
                // base = sel<<4 with NO GDT descriptor read (IA-32 V86 segmentation),
                // exactly like real mode — handled in S_EXEC by the SYS_MOVSREG_TO
                // real-mode arm (sys_mode is 1 under V86, so the proxy arm is skipped).
                if (seg_real || (!sys_mode && proxy_en)) state<=S_EXEC;
                else state<=S_SEGLD;                // PM: fetch descriptor
              end
              SYS_LJMP: begin
                // far jump. REAL mode / V86: base=sel<<4, jump now. PM: load CS
                // from the GDT descriptor (S_LJMP fetches it) then switch. Under V86
                // (seg_real) the S_EXEC SYS_LJMP arm loads CS.base = sel<<4 with no
                // descriptor read, matching real-mode V86 segmentation.
                if (seg_real) state<=S_EXEC;
                else state<=S_LJMP;
              end
              SYS_LTR: begin
                // LTR — read the GDT TSS descriptor (S_LTR fetches it, loads the
                // TR hidden base/limit + sets the descriptor busy bit).
                seg_step<=1'b0; state<=S_LTR;
              end
              // M9.5 — real-mode far CALL / RETF. The S_LCALL/S_RETF micro-sequences
              // push/pop CS:IP on SS:SP and do the real-mode CS load (base=sel<<4).
              // Scoped to real mode / V86 (seg_real); a PROTECTED-mode far CALL/RETF
              // (call gates / privilege change) is out of scope -> HALT loudly (never
              // mis-executes) exactly like the other unimplemented system forms.
              SYS_LCALL: begin
                if (seg_real && !paging_on) begin seg_step<=1'b0; state<=S_LCALL; end
                else state<=S_HALT;
              end
              SYS_RETF: begin
                if (seg_real && !paging_on) begin seg_step<=1'b0; state<=S_RETF; end
                else state<=S_HALT;
              end
              // M9.5 — SGDT/SIDT: 2-beat store of the GDTR/IDTR pseudo-descriptor.
              // Decode already gated on !paging_on; mode-agnostic otherwise.
              SYS_SGDT, SYS_SIDT: begin seg_step<=1'b0; state<=S_SGDT; end
              default: state<=S_EXEC;  // MOV CRn to/from, MOV/STR sreg: no fetch
            endcase
          end
          else if (d_kind==K_STR) begin
            // REP with ECX==0: degenerate single no-op record (advance EIP).
            if ((pfx_rep!=2'd0) && (gpr[R_ECX]==32'd0)) state<=S_EXEC; // handled as no-op
            else if (d_mem_read) state<=S_LOAD;   // movs/lods/scas/cmps load first
            else state<=S_EXEC;                    // stos stores directly
          end
          else if (d_mem_read || d_is_pop ||
                   (d_kind==K_STKMISC && (d_sm==SM_LEAVE || d_sm==SM_POPF)))
            state<=S_LOAD;
          else state<=S_EXEC;
        end
