// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/core_fetch_decode.svh — RAW case-arm text `included inside core.sv's
// always_ff `unique case (state)` (R2 modularization). NOT a standalone unit
// (no module/always wrapper); pasted verbatim at the original FSM site, netlist
// identical. Covers the fetch + in-FSM decode-commit/dispatch arms:
//   S_FETCH (16-byte fetch window), S_DECODE (prefix/length/operand decode +
//   the SYS_* -> S_LGDT/S_SEGLD/S_LJMP/S_LTR routing and load/exec dispatch).
        S_FETCH: begin
          // task #54: the whole 16-byte window is already in the I-cache -> take it
          // in ONE clock instead of four bus reads. sfetch_fast (core.sv) is the
          // residency predicate; the bus driver suppresses mem_req on the same
          // condition so this issues no transaction at all.
          if (sfetch_fast) begin
            for (int i = 0; i < IWORDS*4; i++) ibuf[i] <= ic_byte(flin + 32'(i));
            fetch_word <= 3'd0;
            state      <= S_DECODE;
          end else if (mem_ack) begin
            ibuf[{fetch_word,2'b00}+0]<=mem_rdata[7:0];
            ibuf[{fetch_word,2'b00}+1]<=mem_rdata[15:8];
            ibuf[{fetch_word,2'b00}+2]<=mem_rdata[23:16];
            ibuf[{fetch_word,2'b00}+3]<=mem_rdata[31:24];
            if (fetch_word==3'(IWORDS-1)) begin fetch_word<=3'd0; state<=S_DECODE; end
            else fetch_word<=fetch_word+3'd1;
          end
        end

        S_DECODE: begin
`ifdef VEN_DBG_WD
          // [VEN-DECPROBE] ground-truth of the decode at the far-jmp task switch (cs=002b:0x3e93) and the
          // resume (cs=0018:0x3f49) during the cascade: ibuf bytes + effective op/addr size + decoded uop.
          if ((eip[15:0]==16'h3f49 || eip[15:0]==16'h3e93 || eip[15:0]==16'h3e98)
              && (gpr_o[R_ESI]==32'h0011b354 || gpr_o[R_ESI]==32'h00000758)) begin
            $display("[VEN-DECPROBE] cs:eip=%04x:%04x ib=%02x %02x %02x %02x %02x %02x | eff_op=%b eff_addr=%b def16=%b cs_d=%b | d_memrd=%b d_memwr=%b d_ea=%08h d_len=%0d esi=%08h",
                     seg_sel[SG_CS], eip[15:0], ibuf[0],ibuf[1],ibuf[2],ibuf[3],ibuf[4],ibuf[5],
                     eff_opsize, eff_addr, def16, cs_d, d_mem_read, d_mem_write, d_ea, d_len, gpr_o[R_ESI]);
          end
          // [VEN-TBLWRITER] the writer at cs=0087:0x3d8 populates the fn-ptr table but at 0x5c004+ (never
          // 0x5c000). Log its decode + EA + base/index regs to see if the loop base is off-by-4 (should start
          // at 0x5c000) or if 0x5c000 is a separate write that Ventium skips.
          if (seg_sel[SG_CS]==16'h0087 && eip>=32'h000003c0 && eip<=32'h000003ec) begin
            $display("[VEN-TBLWRITER] cs:eip=0087:%04h ib=%02x %02x %02x %02x %02x %02x | eff_addr=%b d_memwr=%b d_ea=%08h(ds_lin=%08h) d_len=%0d | eax=%08h ecx=%08h edx=%08h esi=%08h edi=%08h ebp=%08h",
                     eip[15:0], ibuf[0],ibuf[1],ibuf[2],ibuf[3],ibuf[4],ibuf[5], eff_addr, d_mem_write,
                     d_ea, seg_base[SG_DS]+d_ea, d_len,
                     gpr_o[R_EAX], gpr_o[R_ECX], gpr_o[R_EDX], gpr_o[R_ESI], gpr_o[R_EDI], gpr_o[R_EBP]);
          end
          // [VEN-NULLCALL] the 2nd bug: Quake client sets eax->0 near cs=00a7:0x515b2 then `call eax` (=null).
          // Log the decode + eax + the memory operand (if a load) for the whole 0x515a0..0x515b6 window so we
          // see WHICH instruction zeroes eax and whether it is a load (mov eax,[ptr] with [ptr]=0) or a compute.
          if (seg_sel[SG_CS]==16'h00a7 && eip>=32'h000515a0 && eip<=32'h000515b6) begin
            $display("[VEN-NULLCALL] cs:eip=00a7:%08h ib=%02x %02x %02x %02x %02x %02x | eff_op=%b eff_addr=%b | d_memrd=%b d_memwr=%b d_ea=%08h(ds_lin=%08h) d_len=%0d | eax=%08h ebx=%08h esi=%08h edi=%08h",
                     eip, ibuf[0],ibuf[1],ibuf[2],ibuf[3],ibuf[4],ibuf[5], eff_opsize, eff_addr,
                     d_mem_read, d_mem_write, d_ea, seg_base[SG_DS]+d_ea, d_len,
                     gpr_o[R_EAX], gpr_o[R_EBX], gpr_o[R_ESI], gpr_o[R_EDI]);
          end
`endif
`ifdef VEN_DBG_CORE
          // DOS-Quake #DE CONFIRM (hook cfg[2]): the JMP FAR `ea 00 00 70 00` (JMP FAR
          // 0x0070:0x0000) at cs=0x2b:0x3E93 is the divergence — the board lands at
          // cs=0x2b:0x24e = JMP FAR operands 4e 02 2b (corrupted from 00 00 70). The
          // far jump is non-simple -> slow path -> S_DECODE -> dbg_ibuf = the fetched
          // bytes. Golden: bytes0_3=0x700000EA (ea 00 00 70), byte4=0x00.
          if (dbg_hook_cfg[0] && dbg_hook_cfg[2] && eip[15:0]==16'h3e93
              && seg_sel[SG_CS]==16'h002b) begin
            dbg_hook_seq  <= dbg_hook_seq + 8'd1;
            dbg_hook_eip  <= eip;
            dbg_hook_opa  <= dbg_ibuf;
            dbg_hook_meta <= {8'hEA, seg_sel[SG_CS], 8'd0};
          end
`endif
`ifdef VEN_DBG_SSBASE
          // F3 gap-walk probe: in real mode every sreg base must equal sel<<4.
          // (SeaBIOS unreal-mode transition stretches fire this legitimately —
          // PM selectors with base 0 surviving into real mode; read with care.)
          if (seg_real && (seg_base[SG_SS] != {12'd0, seg_sel[SG_SS], 4'd0}
                        || seg_base[SG_DS] != {12'd0, seg_sel[SG_DS], 4'd0}
                        || seg_base[SG_ES] != {12'd0, seg_sel[SG_ES], 4'd0}))
            $display("SSBASE-DESYNC eip=%08x ss=%04x ss.base=%08x ds=%04x ds.base=%08x es=%04x es.base=%08x",
                     eip, seg_sel[SG_SS], seg_base[SG_SS],
                     seg_sel[SG_DS], seg_base[SG_DS], seg_sel[SG_ES], seg_base[SG_ES]);
          // F3 probe 2: 16-bit code never legitimately carries ESP[31:16]!=0.
          // High bits here mean a 32-bit-ESP stack op leaked past 64K (the
          // missing real-mode SP wrap) — the audit's remaining finding.
          if (seg_real && gpr_o[R_ESP][31:16] != 16'd0)
            $display("ESP-HIGH eip=%08x esp=%08x ss=%04x", eip, gpr_o[R_ESP], seg_sel[SG_SS]);
`endif
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
          q_cli<=d_cli; q_sti<=d_sti; q_br16<=d_br16; q_clts<=d_clts;   // H-23
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
          q_io_port<= d_io_imm ? {8'd0, d_io_port_imm} : gpr_o[R_EDX][15:0];
          // latch x87 decode
          q_fxop<=d_fxop; q_is_x87<=d_is_x87; q_f_mem_read<=d_f_mem_read;
          q_f_mem_write<=d_f_mem_write; q_f_mbytes<=d_f_mbytes; q_f_pop<=d_f_pop;
          q_f_pop2<=d_f_pop2; q_f_sti<=d_f_sti; q_f_aluop<=d_f_aluop; q_f_const<=d_f_const;
          f_step<=4'd0;
          // M2S.1 system decode latch.
          q_sysop<=d_sysop; q_sys_sreg<=d_sys_sreg; q_sys_creg<=d_sys_creg;
          q_seg<=d_seg; q_pfx_seg_en<=d_pfx_seg_en; q_ljmp_off<=d_ljmp_off; q_ljmp_sel<=d_ljmp_sel;
          q_seg_load<=d_seg_load; q_lseg<=d_lseg;   // M9.5 LES/LDS/LSS/LFS/LGS
          q_push_sreg<=d_push_sreg; q_pop_sreg<=d_pop_sreg;   // F3 PUSH/POP sreg
          q_seg_load_lo<=d_seg_load_lo;                       // F3 MOV Sreg,[mem]
          q_store_sreg<=d_store_sreg;                         // F3 MOV [mem],Sreg
          q_xlat<=d_xlat;                                     // XLATB (D7)
          q_callf_mem<=d_callf_mem; q_jmpf_mem<=d_jmpf_mem;   // F3 FF /3 CALLF / FF /5 JMPF
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
            smi_enter(eip);   // REVIEW2 C-08: shared with the fast boundary
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
          // ---- VEN_DBG_CORE single-step / breakpoint PARK -------------------
          // dbg_block_issue is tied 0 in non-debug builds, so this arm is dead and
          // the dispatch is byte/cycle-identical. It sits BELOW SMI/NMI/INTR (no
          // interrupt is ever lost) and ABOVE the normal instruction dispatch + its
          // per-insn fault checks: a held instruction does not execute at all. state
          // stays S_DECODE and eip is unchanged, so the held instruction re-decodes
          // and issues only when the hold releases (dbg_step grants one; dbg_halt_req
          // low + the breakpoint cleared frees the run).
          else if (dbg_block_issue) begin
            state <= S_DECODE;
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
          // REVIEW2 C-05: architectural CPL/IOPL check, ahead of the V86 special case
          // (which stays because it also covers PUSHF/POPF/INT n/IRET, which are V86-
          // specific rather than CPL0-only). priv_fault is the single predicate
          // computed in core.sv; #GP(0) is a FAULT, so the faulting EIP is pushed and
          // the instruction is restartable.
          else if (priv_fault) begin
            start_fault(8'd13, 1'b1, 32'd0, eip);
          end
          // REVIEW2 C-06 DELIVERY: REMOVED, not merely disabled. Measured, and the
          // bolt-on cannot be made correct here.
          //
          // With VEN_SEG_ENFORCE on, all five of pseg/pmode/ppage/pcpl/pfcpl3 failed.
          // Instrumenting the fault showed why:
          //
          //     [SEGFAULT-DBG] dseg=2 sel=0000 ea=60000011 w=2 limit=0000ffff over=1
          //
          // ea=0x60000011 is CR0's VALUE, not an address. Two structural errors, and
          // both are the mirror problem this session keeps finding:
          //   1. The check was not gated on the instruction actually MAKING a data
          //      memory access. For a register-only instruction q_ea holds whatever
          //      the decoder left there, and the limit check faulted on it.
          //   2. It read q_* (the PREVIOUS instruction's latched decode -- q_ea<=d_ea
          //      is nonblocking) while being delivered at the S_DECODE dispatch for the
          //      CURRENT one. Wrong signal domain entirely.
          //
          // Gating and re-timing this in place would mean reconstructing dseg, the
          // effective address and the width in the decode domain -- i.e. building a
          // SECOND copy of the address-generation logic beside the one in cur_lin and
          // the one in the bus driver. That is precisely what C-03 documents as
          // already broken with two copies; adding a third to enforce segment limits
          // would be the same mistake with a fresh name.
          //
          // Segment limits are a PER-ACCESS check, like page permissions. C-01 could
          // be delivered because paging already has per-access plumbing (cur_lin,
          // cur_is_d, cur_is_w, translatable) to hook into. Segmentation has no
          // equivalent, and creating one IS the access descriptor of #65. So the
          // computation stays (lint-sunk, and now width-accurate with expand-down),
          // and the delivery waits for #65 rather than shipping behind a flag that
          // is known not to work.
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
              ssp_hit = dr_match(seg_base[SG_SS] + gpr_o[R_ESP], 1'b0);
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
          else if (d_io && !(d_kind==K_STR && d_st==ST_OUTS)) begin
            // INS (string port-input) routes to its dedicated per-element handshake
            // S_INS (it is BOTH d_io and a K_STR); plain IN/OUT routes to S_IO.
            // OUTS (ST_OUTS) is EXCLUDED here: its element must be LOADED from [SI]
            // first, so it takes the normal K_STR d_mem_read -> S_LOAD -> S_EXEC path
            // (the K_STR arm then routes to S_IO for the per-element OUT handshake).
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
                            : (gpr_o[R_EDX][15:0]==16'h00F4)))
                begin state<=S_HALT; `ifdef VEN_DBG_CORE int_vec<=8'hE4; `endif end  // isa-debug-exit terminator (no retire)
              else if (d_kind==K_STR && d_st==ST_INS) state <= S_INS;
              else                                    state <= S_IO;
            end
            // Outside co-sim/SoC: `out 0xf4` is the clean isa-debug-exit terminator
            // (HALT, no retire); every other IN/OUT is a loud out-of-scope HALT.
            // Either way -> S_HALT with NO retire (matches the pre-M7.3b path
            // exactly, so the sys gates are byte-for-byte unchanged).
            else begin state<=S_HALT; `ifdef VEN_DBG_CORE int_vec<=8'hE5; `endif end
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
            // R3: EAX<=syscall_eax (kernel ret) moved to the gpr writeback driver
            // (core_gpr_wb.svh, S_DECODE proxy-int80 arm).
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
            // F3 INTERRUPTIBLE HLT (system mode only): in sys_mode `d_halt` is ONLY the
            // HLT opcode (INT n decodes to d_int there, never d_halt). A real CPU's HLT
            // halts until an interrupt, then the IRET resumes AFTER the HLT — SeaBIOS's
            // yield() (sti;hlt;cli) busy-waits on the timer IRQ exactly this way during
            // its INT 13h disk wait. So retire the HLT, step EIP past it, and park in
            // S_HLTWAIT (which delivers the next INTR/NMI). USER mode keeps the terminal
            // no-wake S_HALT below (no retire), so make verify is byte-identical.
            if (sys_mode && d_halt && !d_unknown) begin
              q_pc<=eip; retire_valid<=1'b1;
              eip<=eip+{28'd0,d_len};
              state<=S_HLTWAIT;
            end else begin
              // M5 finding [low]: in CYCLE mode the oracle emits a retire record for
              // the terminating `int 0x80` (a retired instruction to the TCG plugin),
              // so the RTL must too. Emit ONE retire for a genuine HALT syscall
              // (d_halt) then stop. d_unknown stays a LOUD no-retire HALT.
              if (cycle_mode && d_halt && !d_unknown) begin
                q_pc<=eip; retire_valid<=1'b1;
                retire_pipe_valid<=1'b1; retire_pipe<=2'd0; retire_paired<=1'b0;
              end
`ifdef VEN_DBG_WD
              // Capture the exact opcode bytes that halt the core (Quake d_unknown wedge).
              if (d_unknown)
                $display("[VEN-UNK] d_unknown HALT cs:eip=%04x:%08x lin=%08x ibuf= %02x %02x %02x %02x %02x %02x %02x %02x",
                         seg_sel[SG_CS], eip, seg_base[SG_CS]+eip,
                         ibuf[0],ibuf[1],ibuf[2],ibuf[3],ibuf[4],ibuf[5],ibuf[6],ibuf[7]);
`endif
              // M6 Erratum 81 (F00F): the locked CMPXCHG8B reg-dst HANG.
              if (d_f00f && errata_en[ERR_F00F] && pfx_lock)
                state<=S_F00F_HANG;
              // REVIEW2 H-11: an invalid/unsupported encoding used to drop straight into
              // terminal S_HALT. An OS then cannot catch or emulate it, and malformed
              // USER code halts the whole machine instead of taking a fault -- which is
              // both a denial of service and the reason several legitimate encodings
              // (now #UD'd by H-02) looked like hangs. In SYSTEM mode deliver the
              // architectural #UD (vector 6) so the guest's handler runs.
              //
              // USER mode keeps the loud HALT deliberately: there is no IDT there, the
              // bare-metal corpus has no #UD handler, and a silent fault would turn a
              // decoder gap into a mysterious wrong answer instead of an obvious stop.
              else if (sys_mode)
                start_fault(8'd6, 1'b0, 32'd0, eip);
              else
                state<=S_HALT; `ifdef VEN_DBG_CORE int_vec<=8'hE6; `endif
            end
          end
          // REVIEW2 H-23: CR0.EM / CR0.TS must trap x87 execution with #NM (vector 7).
          // Neither was inspected at all, so lazy FPU context switching was impossible:
          // a task switch sets CR0.TS (core_tsw.svh:165) and the very next x87
          // instruction just executed against the OUTGOING task's register file.
          //   EM=1 -> no x87 hardware; every x87 op traps so software can emulate.
          //   TS=1 -> the x87 context belongs to another task; trap so the handler can
          //           save/restore it and clear TS.
          // #NM takes no error code.
          //
          // FWAIT is NOT covered here: it decodes as d_is_nop (decode_stages.sv:1028),
          // and its rule is different anyway (it traps only when TS=1 AND MP=1). That,
          // and making FWAIT actually wait on pending unmasked exceptions, is H-22.
          else if (d_is_x87 && (creg0[2] || creg0[3])) begin
            start_fault(8'd7, 1'b0, 32'd0, eip);
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
`ifdef VEN_DBG_CORE
              // F4A: capture a SOFTWARE int 0 (the "Division by Zero" abort is a PM
              // int-0, NOT a divide — divide tap showed cnt=0). ibuf confirms cd 00
              // vs garbage (a control-flow derail landing on it).
              if (d_int && !d_ud2 && d_int_vec == 8'd0)
                $display("tb: INT0 software-int-0 @cs=%04x eip=%08x ibuf=%016x",
                         seg_sel[SG_CS], eip, dbg_ibuf);
`endif
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
            // 16-bit IRET (IRETW): in PM the frame width follows the IRET's EFFECTIVE
            // operand size (eff_opsize = pfx_opsize ^ def16). In 16-bit PM (cs_d=0, no
            // 0x66) eff_opsize=1 -> pop a 6-byte IP:CS:FLAGS frame (2-byte slots, ESP
            // += 6); 32-bit (cs_d=1 or 16-bit+0x66) keeps the 12-byte legacy pop. Only
            // the SAME-PRIV S_IRET arm honours int_gate_op16 (inter-priv/V86 unchanged).
            int_gate_op16 <= eff_opsize;
            // REVIEW2 H-09: IRET re-arms NMI -- but only the IRET that unwinds the
            // NMI's OWN frame. This used to clear nmi_in_progress unconditionally, so
            // a maskable interrupt taken INSIDE an NMI handler could run its own IRET
            // and re-arm NMI while the outer NMI handler was still executing; a second
            // NMI would then corrupt the first one's frame. nmi_nest counts frames
            // stacked inside the NMI (incremented in start_fault, which every delivery
            // path funnels through), so a nested IRET unwinds one level instead.
            //
            // KNOWN REMAINING GAP, stated rather than papered over: this still acts at
            // IRET DECODE, so an IRET that FAULTS during its own stack reads has
            // already decremented. Closing that needs validate-the-whole-frame-then-
            // commit, which is REVIEW2 C-10 and a much larger change; the nesting
            // escalation fixed here is the more serious of the two.
            if (nmi_nest != 4'd0) nmi_nest <= nmi_nest - 4'd1;
            else                  nmi_in_progress <= 1'b0;
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
              SYS_LTR, SYS_LLDT: begin
                // LTR — read the GDT TSS descriptor (S_LTR fetches it, loads the
                // TR hidden base/limit + sets the descriptor busy bit). LLDT reuses
                // the same read FSM but loads ldt_base/ldt_limit (branched in S_LTR).
                seg_step<=1'b0; state<=S_LTR;
              end
              // M9.5 — real-mode far CALL / RETF. The S_LCALL/S_RETF micro-sequences
              // push/pop CS:IP on SS:SP and do the real-mode CS load (base=sel<<4).
              // Scoped to real mode / V86 (seg_real); a PROTECTED-mode far CALL/RETF
              // (call gates / privilege change) is out of scope -> HALT loudly (never
              // mis-executes) exactly like the other unimplemented system forms.
              SYS_LCALL: begin
                // real/V86: push CS:IP + real-mode CS load (base=sel<<4). PM: push
                // CS:EIP then S_LCALL hands off to S_LJMP's GDT descriptor CS load
                // (DOS Quake's CWSDPMI far-calls in PM). seg_real && paging_on stays HALT.
                if ((seg_real && !paging_on) || !seg_real) begin seg_step<=1'b0; state<=S_LCALL; end
                else begin state<=S_HALT; `ifdef VEN_DBG_CORE int_vec<=8'hE7; `endif end
              end
              SYS_RETF: begin
                // real/V86: pop CS:IP + real-mode CS load (base=sel<<4). PM: pop
                // CS:EIP then S_RETF hands off to S_LJMP's GDT/LDT descriptor CS load
                // (DOS Quake's CWSDPMI far-returns in PM — same-privilege, the popped
                // CS RPL == CPL). seg_real && paging_on stays HALT. Mirrors SYS_LCALL.
                if ((seg_real && !paging_on) || !seg_real) begin seg_step<=1'b0; state<=S_RETF; end
                else begin state<=S_HALT; `ifdef VEN_DBG_CORE int_vec<=8'hE8; `endif end
              end
              // M9.5 — SGDT/SIDT: 2-beat store of the GDTR/IDTR pseudo-descriptor.
              // Decode already gated on !paging_on; mode-agnostic otherwise.
              SYS_SGDT, SYS_SIDT: begin seg_step<=1'b0; state<=S_SGDT; end
              default: state<=S_EXEC;  // MOV CRn to/from, MOV/STR sreg: no fetch
            endcase
          end
          else if (d_kind==K_STR) begin
            // REP with ECX==0: degenerate single no-op record (advance EIP).
            if ((pfx_rep!=2'd0) && (gpr_o[R_ECX]==32'd0)) state<=S_EXEC; // handled as no-op
            else if (d_mem_read) state<=S_LOAD;   // movs/lods/scas/cmps load first
            else state<=S_EXEC;                    // stos stores directly
          end
          else if (d_mem_read || d_is_pop ||
                   (d_kind==K_STKMISC && (d_sm==SM_LEAVE || d_sm==SM_POPF)))
            state<=S_LOAD;
          else state<=S_EXEC;
        end
