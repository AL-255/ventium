// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/core_fetch_decode.svh — RAW case-arm text `included inside core.sv's
// always_ff `unique case (state)` (R2 modularization). NOT a standalone unit
// (no module/always wrapper); pasted verbatim at the original FSM site, netlist
// identical. Covers the fetch + in-FSM decode-commit/dispatch arms:
//   S_FETCH (16-byte fetch window), S_DECODE (prefix/length/operand decode +
//   the SYS_* -> S_LGDT/S_SEGLD/S_LJMP/S_LTR routing and load/exec dispatch).
        S_FETCH: begin
          // One-shot short descriptor state is consumed on every S_FETCH entry,
          // whether the tagged-cache recheck succeeds or falls through to the
          // original bus fetch below.
          sfetch_short_len_q <= 4'd0;
`ifdef VEN_UOPCACHE
          // Consume the overflow-only shortcut request even if its tagged-buffer
          // recheck fails below. In that case this S_FETCH immediately resumes the
          // original bus sequence; it must not become a persistent alternate fetch
          // policy for subsequent slow-path instructions.
          sfetch_uop_q <= 1'b0;
`endif
`ifdef VEN_SFETCH_RESIDENT
          sfetch_resident_q <= 1'b0;
`endif
          // task #54: the whole 16-byte window is already in the I-cache -> take it
          // in ONE clock instead of four bus reads.  The narrow short descriptor
          // is different: only its two verified instruction bytes are copied and
          // the suffix is explicitly zeroed before the ordinary slow decoder runs.
          // The bus driver uses the same predicate, so this issues no transaction.
`ifdef VEN_UOP_SLOW_LEN_HINT
          // CPU-store snoops depend on the bus driver's write output. Using
          // them in sfetch_short_fast (which blanks that same bus block) would
          // form a combinational loop. Veto only the sequential capture: hold
          // S_FETCH with no ibuf write, consume the one-shot above, and retry
          // through the established fetch path after invalidation takes effect.
          if (sfetch_short_fast && (icsnp_v1 || icsnp_v2)) begin
          end else
`endif
          if (sfetch_boundary) begin
            if (sfetch_early_nm || sfetch_early_gp ||
                (!sfetch_demand_req && d_fetch_meta_ready)) begin
              fetch_word <= 3'd0;
              state <= S_DECODE;
            end else if (mem_req && mem_ack) begin
              // Clear stale suffix scratch once; only validated bytes become
              // visible to the length parser as sfetch_valid_q advances.
              if (sfetch_valid_q == 5'd0)
                for (int i=0; i<IWORDS*4; i++) ibuf[i] <= 8'd0;
              for (int i=0; i<4; i++)
                if (i < int'(sfetch_demand_size))
                  ibuf[sfetch_valid_q[3:0] + 4'(i)] <= mem_rdata[i*8 +: 8];
            end
          end else if (sfetch_short_fast || sfetch_fast || sfetch_uop_fast || sfetch_resident_fast) begin
            for (int i = 0; i < IWORDS*4; i++) begin
              if (sfetch_short_fast && (
`ifdef VEN_UOP_SLOW_LEN_HINT
                  (i >= int'(sfetch_short_len_q))
`else
                  (i >= 2)
`ifdef VEN_UOP_FWAIT_FETCH
                  || ((i == 1) && sfetch_short_len_q == 4'd1)
`endif
`endif
                  )) ibuf[i] <= 8'd0;
              else
`ifdef VEN_IC_BRAM
                ibuf[i] <= ic_front_bytes[i];
`else
                ibuf[i] <= ic_byte(flin + 32'(i));
`endif
            end
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
          // exactly THIS one instruction. Keep architectural RF until successful
          // completion: decode/operand faults and pre-execution SMI/IRQ/#DB must
          // save the incoming value, not a prematurely cleared decode attempt.
          if (sys_mode && !dbg_block_issue) begin
            tf_at_issue <= eflags[8];
            rf_at_issue <= eflags[16];
          end
          capture_reference_decode(eip);
          // M2S.3 INT/IRET/UD2 are dispatched directly from the d_* decode below
          // (they begin their micro-sequence in S_DECODE), so no q_* latch is
          // needed: the delivery state is captured in int_* / iret_* instead.

          // ---- M2S.5 SMI# recognition (gated sys_mode) ----------------------
          // A recognised SMI# is taken at the instruction boundary, BEFORE this
          // instruction executes (so it does not retire). Save the resume EIP =
          // the current EIP (this instruction restarts after RSM) and divert to
          // S_SMI_SAVE. smm_active blocks re-entrant SMI (SMI is masked in SMM).
          // This takes priority over the decoded instruction below.
          if (dbg_block_issue) begin
            // The external debugger owns this boundary.  Do not consume RF or
            // an interrupt shadow above, and do not acknowledge an interrupt;
            // the pending level/edge is delivered after a debugger resume.
            state <= S_DECODE;
          end
          else if (smi_pending && sys_mode && !smm_active && !dbg_step_active) begin
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
          else if (nmi_take && !dbg_step_active) begin
            nmi_pending     <= 1'b0;            // consume the latched edge
            nmi_in_progress <= 1'b1;            // mask further NMI until IRET
            start_fault(8'd2, 1'b0, 32'd0, eip);
            dlv_ext         <= 1'b1;            // NMI is an external event (EXT=1)
          end
          else if (intr_take && !dbg_step_active) begin
            // inta pulsed combinationally THIS clock; the PIC has driven the vector
            // back on inta_vector. Deliver through IDT[inta_vector], int_sw=0.
            start_fault(inta_vector, 1'b0, 32'd0, eip);
            dlv_ext         <= 1'b1;            // INTR is an external event (EXT=1)
          end
          else if ((sfetch_header_fault_q != 2'd0) ||
                   sfetch_early_nm || sfetch_early_gp) begin
            // The authorized opcode selected a fault before its EA exists.
            // A complete interior window uses the same header priority as a
            // demanded boundary header; only the latter needs the latch.
            // Never execute a provisional zero-padded semantic decode, and
            // preserve the normal debugger/SMI/NMI/INTR boundary priority.
            if ((sfetch_header_fault_q == 2'd1) || sfetch_early_nm)
              start_fault(8'd7, 1'b0, 32'd0, eip);
            else
              start_fault(8'd13, 1'b1, 32'd0, eip);
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
            dlv_ext     <= 1'b0;       // synchronous #UD: not an external event
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
          else if (d_fetch_overlong) begin
            // Byte16 has already passed the demanded translation checks. Its
            // absent-page PF therefore precedes this architectural #GP(0).
            if (sys_mode)
              start_fault(8'd13, 1'b1, 32'd0, eip);
            else begin
              // The bare functional harness has no architectural IDT. Match
              // its unsupported-encoding policy: loud no-retirement halt,
              // never a legal-looking operation with wrapped q_len==0.
              state <= S_HALT;
`ifndef SYNTHESIS
              $display("[VEN-UNK] overlength HALT eip=%08x", eip);
`endif
            end
          end
          else if (priv_fault) begin
            start_fault(8'd13, 1'b1, 32'd0, eip);
          end
          // ---- REVIEW2_Aug1 C-06 DELIVERY, restored behind VEN_SEG_ENFORCE --------
          // The history below is kept because it is the evidence, not decoration: the
          // delivery was removed twice for shipping false positives. All three causes
          // are now found and fixed, and the acceptance criterion is measured rather
          // than argued -- +ven_seglog counts every access the check WOULD reject:
          //
          //   as-was            : all 19 system tests fire, floor of 12 -> systematic
          //   + cur_is_d        : 16 of 19 go to zero (fetches were checked vs DS)
          //   + cur_seg_rel     : 19 of 19 go to ZERO  (descriptor-table reads are
          //                       linear; subtracting a segment base underflowed)
          //
          // It is NOT enabled by default, and that is a deliberate call rather than
          // timidity. Zero false positives across 19 system tests is not zero across
          // real firmware: the m7 Win95 / Quake gates are artifact-dependent and
          // excluded from verify-all, so nothing here can prove a spurious #GP will
          // not appear in a guest. Injecting one into Win95 would be a far worse
          // regression than the missing check. Enabling it is a two-line change once
          // m7 can be run: build with +define+VEN_SEG_ENFORCE.
          //
          // What IS proven: with the define ON, all 19 system tests still pass -- the
          // enforcement path builds, delivers, and is quiet on everything covered.
          // The delivery itself is NOT here -- see core.sv, next to perm_fault. It
          // was tried here first and measured wrong: seg_access_fault asserts in
          // S_LOAD/S_STORE (pseglim: st=3, off=00010000 vs lim=0000ffff), one state
          // AFTER this arm runs, so a decode-time delivery never fires. That is
          // exactly what the original "cannot be made correct here" note meant.
          // ---- the original removal note, kept as the record ---------------------
          // REVIEW2 C-06 DELIVERY: was REMOVED, not merely disabled. Measured, and the
          // bolt-on could not be made correct WHERE IT WAS -- see above for what
          // changed.
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
            // ---- REVIEW1_Aug2 M-03: the TSS I/O-permission bitmap -----------------
            // Port I/O at CPL > IOPL, or in V86 at any IOPL, is not automatically
            // illegal -- the bitmap can grant individual ports. Rejecting all of it
            // (which the old blanket
            // iopl_sensitive term did) breaks protected-mode I/O virtualisation. When
            // the consult is required, divert to S_IOPERM, which reads TSS+0x66 for the
            // map base and then the byte covering this port, and either continues to
            // the original target or raises #GP(0).
            //
            // ioperm_ret records where to resume, so the bitmap consult is transparent
            // to the three dispatch shapes below rather than duplicated into each.
            if (ioperm_needed) begin
              ioperm_ret  <= (d_kind==K_STR && d_st==ST_INS) ? S_INS : S_IO;
              ioperm_port <= d_io_imm ? {8'd0, d_io_port_imm} : gpr_o[R_EDX][15:0];
              int_step    <= 4'd0;
              state       <= S_IOPERM;
            end
            else if (cosim_en && d_kind==K_STR && d_st==ST_INS) state <= S_INS;
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
              complete_reference_rf();
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
              else begin
                state <= S_HALT;
`ifdef VEN_DBG_CORE
                int_vec <= 8'hE6;
`endif
              end
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
          else if (d_is_x87 && (creg0[2] || creg0[3])) begin
            start_fault(8'd7, 1'b0, 32'd0, eip);
          end
          // REVIEW2_aug2 H-17: FWAIT's #NM rule differs from every other x87 op and was
          // never implemented -- the comment that used to sit here NAMED the rule and
          // then deferred it. FWAIT/WAIT traps only when CR0.MP=1 AND CR0.TS=1 (SDM
          // Vol.2: "WAIT/FWAIT ... #NM if CR0.MP and CR0.TS are both set"), NOT on EM
          // and not on TS alone. That asymmetry is deliberate: MP ("monitor
          // coprocessor") is what tells the CPU a WAIT should synchronise with an FPU
          // whose context is stale, so with MP=0 a lazy-FPU OS expects WAIT to pass.
          //
          // Checked BEFORE the pending-#MF arm below: #NM asks "is the FPU usable at
          // all", which precedes "does it have an unreported error".
          else if (d_is_fwait && creg0[1] && creg0[3]) begin
            start_fault(8'd7, 1'b0, 32'd0, eip);       // #NM, no error code
          end
          // REVIEW1_Aug2 H-12 (remainder): a PENDING UNMASKED x87 exception must be
          // delivered as #MF (vector 16) BEFORE the next waiting FP instruction runs.
          // FSW.ES is now derived (H-12's first half) but nothing ever consumed it, so
          // an unmasked exception was raised and then silently ignored forever.
          //
          // CR0.NE (bit 5) selects the delivery route: NE=1 is the internal #MF, NE=0
          // is the external FERR#/IGNNE# PC-AT path (DOS IRQ13), which this core does
          // not model -- so with NE=0 the behaviour is unchanged, as before.
          //
          // WHERE the check goes is the whole design question. Real hardware checks it
          // on EVERY waiting FP instruction. The oracle does NOT: QEMU emits
          // gen_helper_fwait at exactly two sites -- translate.c:5538 (FWAIT, 9B) and
          // :4608 (FNOP, D9 D0, commented "FreeBSD FPU probe") -- and nowhere else. So
          // those two are checked unconditionally (matching the oracle, differential-
          // safe), and the architecturally-complete "every waiting op" form sits behind
          // VEN_X87_MF_STRICT. Both routes are gated; see run-fenv-gate.sh.
          //
          // The no-wait forms (the N in FNINIT/FNCLEX/FNSTSW/FNSTCW/FNSTENV/FNSAVE) are
          // NEVER checked, in either mode. They are the instructions software uses to
          // READ and CLEAR the status word; trapping them would make an unmasked
          // exception permanently unrecoverable.
          else if ((d_is_fwait || (d_is_x87 && d_fxop == FX_FNOP)
`ifdef VEN_X87_MF_STRICT
                    || (d_is_x87 && !fx_nowait)
`endif
                   ) && fstat[7] && creg0[5]) begin
            start_fault(8'd16, 1'b0, 32'd0, eip);   // #MF takes no error code
          end
          else if (d_is_x87) begin
            // M11b: env/state ops own a dedicated wide-beat sequencer.
            // The shared FPU command cannot be cancelled once accepted.  Its
            // memory stores therefore use the existing read path as a complete
            // translation/limit/page probe before S_FEXEC accepts the command.
            // Staying out of S_DECODE through the probe also prevents an
            // interrupt/task-switch between proof and final store.
            if (d_fxop==FX_FNSTENV || d_fxop==FX_FNSAVE)  begin
              f_seq_step<=5'd0;
`ifdef VEN_FP_SHARED
              state<=S_FENV_LD;  // probe the whole 14/28/94/108-byte destination
`else
              state<=S_FENV_ST;
`endif
            end
            else if (d_fxop==FX_FLDENV || d_fxop==FX_FRSTOR) begin f_seq_step<=5'd0; state<=S_FENV_LD; end
            else if (d_f_mem_read
`ifdef VEN_FP_SHARED
                     || d_f_mem_write
`endif
                    ) state<=S_FLOAD;  // load operand / shared-store pre-probe
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
              dlv_ext     <= 1'b0;     // software INT / #UD: not an external event
              // F3: PURE real mode (PE=0) delivers through the 4-byte IVT (S_RMINT_RD);
              // V86 + protected mode keep the 8-byte IDT-gate path (S_INT_GATE).
              state       <= real_mode ? S_RMINT_RD : S_INT_GATE;
              if (real_mode) rm_read_armed <= 1'b0;
            end
          end
          else if (d_iret) begin
            // F3: real-mode IRET pops a 16-bit FLAGS:CS:IP frame (S_RMIRET); V86/PM
            // keep the 32-bit S_IRET pop (incl. the descriptor reload / priv return).
            // ---- REVIEW2_aug2 H-08 (NT task-return): INSTRUMENTED, not implemented.
            // IRET with EFLAGS.NT=1 must task-switch through the current TSS backlink.
            // Nothing here has ever looked at NT, so such an IRET is silently treated
            // as an ordinary return -- the machine keeps running in the wrong task.
            //
            // I did NOT make this a fault. The honest-#GP precedent used for task gates
            // in the IDT does not transfer: an NT return is a LEGAL operation the core
            // simply does not implement, the core itself never SETS NT (no S_TSW_* arm
            // writes it, and a CALL-type switch would), so the only way to reach this
            // is guest software -- and the workloads that would tell me whether they do
            // (m7 Quake, m7 Win95) are EXCLUDED from verify-all and artifact-gated. A
            // hard #GP would be a behavioural change validated by nothing.
            //
            // So: measure first, exactly as the C-03/C-04 crossing work did. This
            // counts NT-set IRETs and says so loudly, without changing behaviour. If a
            // real workload ever trips it, that is the evidence needed to justify
            // routing it into the existing S_TSW_* machinery (which is what an NT
            // return is: a task switch to the backlink at tr_base+0, with the incoming
            // task's busy bit left SET rather than re-set, and NT cleared in the
            // outgoing image).
            //
            // HOW MUCH IS ACTUALLY MISSING -- checked, because "a new architectural
            // feature" was my phrase and this review has corrected seven such calls.
            // The task-switch machinery FULLY exists (S_TSW_SAVE/READ/SEG/BUSY) and a
            // JMP-form switch enters it from core_seg_ljmp.svh:206 after S_LJMP has
            // read the target TSS descriptor. An NT return reuses all of that. What is
            // genuinely absent is small and specific:
            //   1. a state that reads the BACKLINK selector from tr_base+0 -- no
            //      existing state reads TSS offset 0;
            //   2. a flag through S_LJMP so that selector is treated as a TSS target;
            //   3. a busy-bit variant in S_TSW_BUSY: the incoming (suspended outer)
            //      task is ALREADY busy, so it must be left set rather than re-set,
            //      while the outgoing one is cleared -- the JMP form does `attr|8'h02`;
            //   4. clearing NT in the outgoing EFLAGS image.
            //
            // IMPLEMENTED (REVIEW2_aug2 H-08). All four parts land as follows:
            //   1. the dispatch below, on NT and not-V86;
            //   2. S_NTRET_RD reads the back-link at tr_base+0 and hands the selector
            //      to S_LJMP, which already knows how to run a task switch;
            //   3. tsw_type_ok() widens S_LJMP's two type tests to accept a BUSY TSS
            //      (0xB) under ntret_pend, and the busy-TSS #GP arm above it is
            //      qualified with !ntret_pend -- a back-link names the suspended OUTER
            //      task, which never stopped being busy, so H-04's "you may not JMP
            //      into a running task" guard must not fire here;
            //   4. eflags[14] is cleared AT THE ARM, before S_TSW_SAVE beat 1 writes
            //      the outgoing EFLAGS image.
            // The S_TSW_BUSY beats needed NO change: beat 0 clears the outgoing busy
            // bit, and beat 1's `attr | 8'h02` rewrites B over B for an already-busy
            // incoming TSS. Reusing them is why this is ~15 lines and not a new
            // micro-sequence.
            //
            // TWO EARLIER ATTEMPTS WERE REVERTED, and the reason is worth keeping:
            // both were diagnosed as "S_LJMP is never entered". That was WRONG. A
            // probe on S_LJMP's entry showed it IS entered with ntret_pend set and
            // BOTH descriptor beats acking. The real blocker was in the TEST -- pntret
            // wrote GDT index 6 twice, clobbering the TSS_B descriptor with a
            // conforming CODE segment, so the core correctly took the far-jump path
            // and the run ended cs=0x0030. That reads exactly like "NT was ignored".
            // Probing the RTL's actual state, instead of re-editing on a theory, is
            // what separated the two.
            //
            // pntret discriminates: ebp 0x07000001 implemented / 0x07000000 not, and
            // CR0.TS (0x...19 vs 0x...11) says the same thing independently. MEASURED
            // against a build with this dispatch forced false, not asserted.
            int_step <= 4'd0; int_src_pc <= eip;
            // REVIEW2_aug2 H-08: IRET with NT=1 in protected mode is a TASK RETURN,
            // not a stack return -- it switches back to the task named by the current
            // TSS back-link. V86 (EFLAGS.VM) is excluded: NT has no such meaning there.
            if (!real_mode && eflags[14] && !eflags[17]) begin
              // REVIEW_Aug3 H-01: an NT task RETURN used to read the back-link at
              // tr_base+0 with NO preconditions on TR itself -- an invalid or
              // truncated TR made an arbitrary descriptor read (or a #PF) ahead of
              // the architecturally prior task-state fault. Require a valid, BUSY
              // 32-bit TSS whose limit covers the back-link word (bytes 0..1):
              // anything else is #TS(TR selector) before any memory is touched.
              if (!tr_valid || (tr_attr[3:0] != 4'hB) || (tr_limit < 32'd1))
                start_fault(8'd10, 1'b1, {16'd0, tr_sel} & 32'h0000_FFFC, eip);
              else begin
                ntret_pend <= 1'b1; seg_step <= 1'b0; state <= S_NTRET_RD;
              end
            end else
            state <= real_mode ? S_RMIRET : S_IRET;
            if (real_mode) rm_read_armed <= 1'b0;
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
            // REVIEW_aug2 H-05: the re-arm itself is NO LONGER DONE HERE. Acting at
            // decode meant an IRET that faulted during its own stack reads or frame
            // validation had already re-armed NMI. It now happens at the four IRET
            // COMMIT sites via iret_retire_nmi() (core.sv), which the C-07 whole-frame
            // commit made possible. Nothing NMI-related is decided at decode.
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
              SYS_LAR, SYS_LSL, SYS_VERR, SYS_VERW: begin
                seg_step<=1'b0;
                state<=d_mem_read ? S_LOAD : S_DQUERY;
              end
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
                // REVIEW1_Aug2 H-02: S_SEGLD checks GDT/LDT bounds before reading a
                // descriptor; S_LJMP did not, so a far jump/call to a selector past the
                // end of the table read arbitrary memory AS a descriptor. Checked here,
                // BEFORE the read, for the same reason as the IRET case in H-01 -- the
                // read itself is the defect. Same sel_in_table() helper. A NULL
                // selector is also rejected here (#GP(0), matching QEMU and the far
                // CALL arm): without it the S_LJMP arm read GDT[0] and raised #NP.
                else if (far_sel_bad(d_ljmp_sel))
                  start_fault(8'd13, 1'b1, {16'd0, d_ljmp_sel} & 32'h0000_FFFC, eip);
                else state<=S_LJMP;
              end
              SYS_LTR, SYS_LLDT: begin
                // LTR — read the GDT TSS descriptor (S_LTR fetches it, loads the
                // TR hidden base/limit + sets the descriptor busy bit). LLDT reuses
                // the same read FSM but loads ldt_base/ldt_limit (branched in S_LTR).
                //
                // REVIEW2_aug2 H-01 (one of four paths): the selector was validated only
                // AFTER both descriptor words had been READ. An out-of-table selector
                // therefore issued an arbitrary GDT-relative read first, which under
                // paging can take a #PF -- delivering the WRONG exception, ahead of the
                // architecturally prior #GP. The table-limit and TI checks depend on
                // nothing the read returns, so they belong here, before mem_req.
                //
                // A null selector is NOT rejected here: it is legal for LLDT (H-10) and
                // illegal for LTR, and the illegal case is caught by the type check in
                // S_LTR, which does need the descriptor.
                //
                // REVIEW_Aug3 H-11b: a NULL LLDT names no descriptor, so S_LTR's bus
                // arm suppresses the read and the FSM commits the invalid LDTR
                // directly. The old flow read GDT[0] first and discarded it -- under
                // paging an access the architecture never makes, which can #PF.
                lldt_null_q <= (d_sysop == SYS_LLDT)
                            && (gpr_o[d_src_reg][15:3] == 13'd0) && !gpr_o[d_src_reg][2];
                ltr_busy_q  <= 1'b0;
                if (gpr_o[d_src_reg][2]                                   // TI=1: not GDT
                    || ({16'd0, gpr_o[d_src_reg][15:3], 3'd0} + 32'd7
                        > {16'd0, gdt_limit}))                            // past the GDT
                  start_fault(8'd13, 1'b1,
                              {16'd0, gpr_o[d_src_reg][15:0]} & 32'h0000_FFFC, eip);
                else begin
                  seg_step<=1'b0; state<=S_LTR;
                end
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
                // ---- REVIEW2_aug2 C-06 (first bullet, selector half): validate the
                // target selector BEFORE the return frame is pushed. H-07 added this
                // check at S_LCALL -> S_LJMP, which stops the out-of-table descriptor
                // READ but runs AFTER both pushes, so a rejected selector still faults
                // with CS:next_eip on the stack and ESP decremented -- exactly what
                // C-06 describes. For the IMMEDIATE ptr16:32 form the selector is known
                // here, at dispatch, before anything touches the stack.
                //
                // This does NOT close C-06: the DESCRIPTOR checks (present, code, DPL,
                // conforming) still need the read that S_LJMP performs after the push,
                // and unwinding THAT needs the far-transfer staging the finding asks
                // for. It removes the selector class, which is the one that can be
                // decided without a memory access.
                if (!seg_real && far_sel_bad(d_ljmp_sel))
                  start_fault(8'd13, 1'b1,
                              {16'd0, d_ljmp_sel} & 32'h0000_FFFC, eip);
                // REVIEW2_aug2 C-06: in PM, run the descriptor VALIDATION first
                // (S_LJMP with lcall_pend), then push in S_LCALL, then commit there.
                // Real mode keeps the old order -- it has no descriptor to validate.
                else if (seg_real && !paging_on) begin seg_step<=1'b0; state<=S_LCALL; end
                else if (!seg_real) begin
                  seg_step<=1'b0; lcall_pend<=1'b1; state<=S_LJMP;
                end
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
              // Validate the complete destination before the first store.
              SYS_SGDT, SYS_SIDT: begin
                seg_step<=1'b0; sgdt_probe_q<=1'b1; sgdt_probe_second<=1'b0;
                state<=S_SGDT;
              end
              default: state<=S_EXEC;  // MOV CRn to/from, MOV/STR sreg: no fetch
            endcase
          end
          else if (d_kind==K_STR) begin
            // REP with its address-size-selected count equal to zero is a
            // degenerate no-op record (advance EIP).  Test d_cnt16 here,
            // rather than full ECX: S_LOAD must not perform a source access
            // for 67 F3 A4/A5 with CX==0 and ECX[31:16]!=0.
            if ((pfx_rep!=2'd0) &&
                (d_cnt16 ? (gpr_o[R_ECX][15:0]==16'd0)
                         : (gpr_o[R_ECX]==32'd0))) state<=S_EXEC;
            else if (d_mem_read) state<=S_LOAD;   // movs/lods/scas/cmps load first
            else state<=S_EXEC;                    // stos stores directly
          end
          else if (d_mem_read || d_is_pop ||
                   (d_kind==K_STKMISC && (d_sm==SM_LEAVE || d_sm==SM_POPF)))
            state<=S_LOAD;
`ifdef VEN_STORE_DISPATCH
          // These fully decoded stores have NO S_EXEC side effect: MOV's
          // memory-destination GPR arm is empty, and near CALLREL writes ESP
          // only at the final S_STORE ACK. Neither writes flags. The q_* NBA
          // capture above supplies the same width/high-byte/EA/immediate and
          // q_pc+q_len return PC before the existing store datapath is used.
          // Keep every boundary/fault/system check above this shortcut. S_EXEC
          // is not a debug/event boundary; a halt arriving after dispatch still
          // drains this instruction through S_STORE before the next S_PIPE.
          // Reject push/pop, segment-register stores/loads, LOCK and all RMW;
          // plain 8/16/32-bit register/immediate/moffs MOVs retain their normal
          // segment, page-crossing probe, watchpoint and store-ACK machinery.
          else if (d_mem_write && !d_mem_read && !d_writes_reg && !d_writes_flags &&
                   !d_lock && !d_is_push && !d_is_pop && !d_is_lea && !d_xlat &&
                   !d_seg_load && !d_store_sreg && !d_push_sreg && !d_pop_sreg &&
                   (d_sysop==SYS_NONE) &&
                   (((d_kind==K_ALU) && d_is_mov && (d_alu_op==ALU_MOV) &&
                     (d_w inside {3'd1,3'd2,3'd4})) ||
                    ((d_kind==K_CTRL) && (d_ct==CT_CALLREL) &&
                     (d_w inside {3'd2,3'd4}))))
            state<=S_STORE;
`endif
          else state<=S_EXEC;
        end
