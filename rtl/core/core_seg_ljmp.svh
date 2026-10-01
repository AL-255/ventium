// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/core_seg_ljmp.svh — RAW case-arm text `included inside core.sv's

//
// ===========================================================================
// REVIEW2_aug2 C-06 -- PROTECTED FAR CALL/RETF MUTATE STATE BEFORE VALIDATING.
// NOT FIXED. Recorded here rather than in a status note.
//
// Protected far CALL pushes the return CS:EIP and the GPR writeback decrements ESP
// BEFORE the unvalidated selector reaches S_LJMP. A later selector, presence,
// privilege, table-limit or target-limit fault therefore leaves the return frame
// written and ESP moved -- the handler sees a stack that the faulting instruction
// architecturally should not have touched.
//
// Protected RETF pops EIP/CS and advances ESP before validating the destination, then
// reuses far-JMP semantics; it has NO outer-privilege SS:ESP pop/validation path.
// Cross-privilege call gates loud-HALT instead of switching stack and copying
// parameters (see docs/unsupported-isa.md).
//
// WHAT THE FIX REQUIRES: stage the stack operands AND the target descriptor state,
// validate everything, then commit stack and control state atomically -- the same
// shape the IRET whole-frame commit uses (REVIEW1_Aug2 C-06/C-07). Plus the two
// architecturally distinct sequences that do not exist at all: RETF to an OUTER
// privilege level (pop SS:ESP, validate the new SS, discard the inner frame), and the
// call-gate privilege transition (switch to TSS.SS<n>:ESP<n>, copy the parameter
// words, then push the outer return frame).
//
// WHY IT IS NOT ATTEMPTED IN THIS PASS, stated plainly rather than dressed up:
//   * A partial pre-check is form-dependent and would be misleading. The selector is
//     available at dispatch only for the IMMEDIATE ptr16:32 form; for CALL/JMP FAR
//     m16:32 it is not known until the memory operand load completes, so "validate the
//     selector early" cannot cover both and would leave the harder form unprotected
//     while looking addressed.
//   * This path is LOAD-BEARING for the project's own target: the dispatch comments
//     record that DOS Quake's CWSDPMI far-calls and far-returns run through it in
//     protected mode. A partial restructure that regresses it costs more than the
//     unfixed ordering.
//   * This is the finding class that produced the worst regression of this review --
//     REVIEW2_aug2 C-01, a deadlock in the SHIPPING build, came from a same-shaped
//     "obviously safe" reordering of fault handling.
//
// The ordering defect is real and unmitigated. It is not silent: a fault after the
// push leaves observable stack damage, which is at least diagnosable.
// ===========================================================================
// always_ff `unique case (state)` (R2 modularization). NOT a standalone unit
// (no module/always wrapper); pasted verbatim at the original FSM site, netlist
// identical. Covers the M2S.1 descriptor-table reads + protected-mode far jmp:
//   S_LGDT (LGDT/LIDT pseudo-descriptor read), S_SEGLD (MOV-to-Sreg desc load),
//   S_LJMP (far JMP CS desc load / task-switch entry).
        // -------------------------------------------------------------------
        // M2S.1 — S_LGDT: read the 6-byte LGDT/LIDT pseudo-descriptor (limit[2] +
        // base[4]) from memory at q_ea via two word reads, then load GDTR/IDTR.
        // beat 0: word @q_ea   = { base[15:0], limit[15:0] }
        // beat 1: word @q_ea+4 = { ........., base[31:16] }
        // -------------------------------------------------------------------
        S_LGDT: begin
          if (mem_ack) begin
            if (!seg_step) begin
              gdt_lo <= mem_rdata;     // limit[15:0] | base[15:0]
              seg_step <= 1'b1;
            end else begin
              // base[31:16] is the low half of the second word.
              logic [31:0] nb; logic [15:0] nl;
              nl = gdt_lo[15:0];
              // IA-32: a 16-bit-operand LGDT/LIDT loads a 24-bit base with bits 31:24
              // CLEARED; only a 32-bit operand loads the full 32-bit base. q_w==2 is the
              // 16-bit form (set 0x66-aware in the 0F 01 decode). Without the mask the 4th
              // base byte (the descriptor's access byte) leaks into base[31:24] and the
              // subsequent descriptor read lands tens of MB off -> Win95 AH=87 PM-entry hang.
              nb = (q_w==3'd2) ? {8'd0, mem_rdata[7:0], gdt_lo[31:16]}
                               : {mem_rdata[15:0], gdt_lo[31:16]};
              if (q_sysop==SYS_LGDT) begin gdt_base<=nb; gdt_limit<=nl; end
              else begin idt_base<=nb; idt_limit<=nl; end
              eip<=next_eip; retire_valid<=1'b1; state<=S_PIPE; seg_step<=1'b0;
            end
          end
        end

        // -------------------------------------------------------------------
        // M2S.1 — S_SEGLD: PROTECTED-mode MOV Sreg, r16. Read the 8-byte GDT
        // descriptor at gdt_base + (sel & ~7) via two word reads, decode the
        // hidden base/limit/attr, and load the segment. The protection DECISION
        // (present/type/DPL + null-SS/CS rules, CPL=cpl_r, RPL=sel[1:0]) is
        // genuinely COMPUTED here via seg_load_fault(); fault *delivery* through
        // the IDT is M2S.3, so a raised decision can only HALT loudly (it never
        // silently mis-loads). The pseg corpus loads only clean descriptors, so
        // the decision is always "no fault" and this never halts — but a wrong/
        // absent/mis-typed descriptor WOULD now be caught here (spec §3).
        // -------------------------------------------------------------------
        S_SEGLD: begin
          // REVIEW1_Aug3 R2-C02: a NULL selector performs NO descriptor read.
          // CS/SS null faults without one (seg_load_fault's null case needs no
          // descriptor); a null DS/ES/FS/GS installs an explicit NULL hidden
          // cache -- the old flow read GDT[0] twice and installed whatever hidden
          // state those bytes happened to hold, and under paging made an access
          // the architecture never makes. A later use of this null segment is
          // caught by the enforcement metadata (attr=0 -> not-present).
          if (seg_null_load) begin
            if (segld_tgt == 3'(SG_CS) || segld_tgt == 3'(SG_SS)) begin
              start_fault(8'd13, 1'b1, 32'd0, q_pc);   // #GP(0)
              seg_step<=1'b0; q_seg_from_mem<=1'b0;
            end else begin
              seg_sel  [segld_tgt] <= segld_sel;
              seg_base [segld_tgt] <= 32'd0;
              seg_limit[segld_tgt] <= 32'd0;
              seg_attr [segld_tgt] <= 8'd0;
              seg_b    [segld_tgt] <= 1'b0;
              // R2-H07: a NULL load IS a protected-mode load event (using it
              // must fault #GP(0)); the explicit zeroed hidden state (R2-C02)
              // is now marked loaded directly.
              seg_pm_loaded[segld_tgt] <= 1'b1;
              q_seg_from_mem <= 1'b0;
              eip<=next_eip; retire_valid<=1'b1; state<=S_PIPE; seg_step<=1'b0;
            end
          end else if (mem_ack) begin
            // M2S.3 — selector index past the GDT limit -> #GP(13) carrying the
            // selector as the error code (the descriptor read was out of bounds;
            // we discard it). A NULL selector (idx 0) skips the limit check (a
            // null load into DS/ES/FS/GS is legal). Checked on beat 0 so we
            // deliver before consuming the (garbage) descriptor.
            if (!seg_step && segld_table_oob) begin
`ifdef VEN_DBG_CORE
              // task #102 #GP triage (plusarg-gated, inert by default): a PM seg-load
              // whose selector index overruns the GDT/LDT limit. Dumps the mode context
              // so a spurious PM-walk of a REAL-mode segment value is identifiable.
              if (segfaultdbg) $display(
                "[SEGFLT] LIMIT #GP sel=%04x from_mem=%b tgt=%0d sysop=%0d ispop=%b popsreg=%b srcreg=%0d src=%08x seg_step=%b | seg_real=%b real=%b v86=%b cr0=%08x ef=%08x | gdt_lim=%08x ldt_lim=%08x cpl=%0d cs=%04x q_pc=%08x",
                segld_sel, q_seg_from_mem, segld_tgt, q_sysop, q_is_pop, q_pop_sreg,
                q_src_reg, gpr_o[q_src_reg], seg_step, seg_real, real_mode, v86,
                creg0, eflags, gdt_limit, ldt_limit, cpl_r, seg_sel[SG_CS], q_pc);
`endif
              // R2-C02: the error code preserves TI and clears only RPL.
              start_fault(8'd13, 1'b1, selector_error(segld_sel), q_pc);
              seg_step<=1'b0; q_seg_from_mem<=1'b0;
            end else if (!seg_step) begin gdt_lo<=mem_rdata; seg_step<=1'b1; end
            else begin
              // PROTECTION DECISION (M2S.1) -> now DELIVERED through the IDT (M2S.3).
              if (segld_desc_fault) begin
`ifdef VEN_DBG_CORE
                if (segfaultdbg) $display(
                  "[SEGFLT] DESC fault sel=%04x attr=%02x from_mem=%b tgt=%0d | seg_real=%b v86=%b cr0=%08x ef=%08x cpl=%0d cs=%04x q_pc=%08x",
                  segld_sel, segld_attr, q_seg_from_mem, segld_tgt,
                  seg_real, v86, creg0, eflags, cpl_r, seg_sel[SG_CS], q_pc);
`endif
                // #NP/#SS/#GP — error code = selector (index | TI preserved,
                // RPL cleared, EXT=0). R2-C02: was {sel[15:3],3'b0}, which cleared TI.
                start_fault(seg_fault_vec(1'b0, segld_is_ss, segld_sel,
                            segld_attr, cpl_r), 1'b1,
                            selector_error(segld_sel), q_pc);
                seg_step<=1'b0; q_seg_from_mem<=1'b0;
              end else begin
                seg_sel  [segld_tgt] <= segld_sel;
                seg_base [segld_tgt] <= desc_base(segld_desc);
                seg_limit[segld_tgt] <= desc_limit(segld_desc);
                seg_attr [segld_tgt] <= segld_attr;
                seg_pm_loaded[segld_tgt] <= 1'b1;   // R2-H07: validated PM descriptor load
                // REVIEW2 C-07: capture SS's D/B bit exactly as the CS path captures
                // desc[54] into cs_d. Without it there was no hidden SS.B state at all,
                // so stk16() could not know a protected-mode stack was 16-bit and never
                // wrapped SP at 64 KiB.
                if (segld_tgt == 3'(SG_SS)) ss_b <= segld_desc[54];
                // REVIEW2_aug2 H-05: capture B for EVERY segment, so a non-SS
                // expand-down data segment has a real upper bound instead of 4 GiB.
                seg_b[segld_tgt] <= segld_desc[54];
                q_seg_from_mem <= 1'b0;
                eip<=next_eip; retire_valid<=1'b1; state<=S_PIPE; seg_step<=1'b0;
              end
            end
          end
        end

        // -------------------------------------------------------------------
        // M2S.1 — S_LJMP: PROTECTED-mode far JMP. Read the CS descriptor from the
        // GDT, load CS.sel/base/limit/attr, derive CPL=CS.RPL, and set EIP to the
        // jump offset. This is the second half of the real->protected transition
        // (the CR0.PE write retired separately): its own retire record, switching
        // to 32-bit PM. The CS protection DECISION (present/code-type/null) is
        // COMPUTED via seg_load_fault(); delivery is M2S.3 (a raised decision
        // HALTs). The pseg far jump targets a present 32-bit code seg => no fault.
        // -------------------------------------------------------------------
        S_DQUERY: begin
          if (dq_pre_invalid) begin
            // An executed ZF0 query still has normal post-instruction #DB
            // semantics; an operand/descriptor fault never reaches this edge.
            retire_reference_integer(next_eip, 1'b1, dq_flags);
            seg_step<=1'b0;
          end else if (mem_ack) begin
            if (!seg_step) begin
              gdt_lo<=mem_rdata;
              seg_step<=1'b1;
            end else begin
              retire_reference_integer(next_eip, 1'b1, dq_flags);
              seg_step<=1'b0;
            end
          end
        end

        S_LJMP: begin
          if (mem_ack) begin
            if (!seg_step) begin gdt_lo<=mem_rdata; seg_step<=1'b1; end
            else begin
              logic [63:0] desc;
              logic [7:0]  attr;
              desc = {mem_rdata, gdt_lo};
              attr = desc_attr(desc);
              // M2S.4b — a far JMP whose target descriptor is a SYSTEM descriptor
              // (S=0) is a HARDWARE TASK SWITCH when it names an available (type
              // 0x9) or busy (0xB) 32-bit TSS: SAVE the outgoing state into the
              // current TSS, LOAD the incoming state from the new TSS, reload the
              // segments, toggle the descriptor busy bits, set the new TR + CR0.TS,
              // and resume the incoming task. REVIEW_Aug3 C-04: a far CALL here is
              // the NESTING form (tsw_call): back-link write + NT + outgoing stays
              // busy. A JMP does NOT set NT / the back-link; the interrupt
              // task-gate form remains unsupported (loud halt below).
              // Capture the new TSS descriptor (base/limit/sel/access) here, then
              // run the S_TSW_* micro-sequence. Other system descriptors (task gate
              // 0x5, call gate, LDT, ...) are not in the corpus -> HALT cleanly.
              if (!desc_s(attr)) begin
                // System-descriptor dispatch for a direct far transfer, in the
                // pinned oracle's precedence (helper_ljmp/helper_lcall's
                // switch(type), then switch_tss_ra): transfer-kind rejection
                // (RETF) first, then TYPE/DPL classification, then PRESENCE,
                // then the per-form rules. (The earlier form evaluated
                // presence first, so a combined-invalid descriptor reported
                // #NP where the oracle selects a type/privilege #GP.) Classes
                // the oracle rejects outright are #GP(selector) here; only
                // forms the oracle ACCEPTS but this core does not implement
                // (task gate, 286 TSS) loud-HALT, and only after every
                // architecturally required fault has been selected.
                if (retf_same) begin
                  // REVIEW1_Aug3 R2-C01: a RETF may not resolve a SYSTEM
                  // descriptor at all (no task switch, no gate): #GP(selector).
                  // retf_same used to fall into the TSS/gate resolver.
                  start_fault(8'd13, 1'b1, selector_error(q_ljmp_sel), q_pc);
                  seg_step  <= 1'b0;
                  retf_same <= 1'b0;
                end else if (desc_type(attr) == 4'h9 || desc_type(attr) == 4'hB
                             || desc_type(attr) == 4'h1 || desc_type(attr) == 4'h5) begin
                  // ---- TSS family (available/busy 386 TSS, 286 TSS, task gate)
                  if (ntret_pend) begin
                    // NT RETURN: a busy back-link is the CORRECT and only legal
                    // case -- the task being returned TO is by definition still
                    // active (it CALLed us). Presence still precedes the
                    // unsupported-form halt.
                    if (!desc_present(attr)) begin
                      start_fault(8'd11, 1'b1, selector_error(q_ljmp_sel), q_pc);
                      seg_step  <= 1'b0;
                      ntret_pend<= 1'b0;
                    end else if (desc_type(attr) != 4'hB) begin
                      state<=S_HALT; `ifdef VEN_DBG_CORE int_vec<={4'hD, desc_type(attr)}; `endif seg_step<=1'b0;
                    end else if (desc_limit(desc) < 32'h67) begin
                      start_fault(8'd10, 1'b1, {16'd0, q_ljmp_sel} & 32'h0000_FFFC, q_pc);
                      seg_step  <= 1'b0;
                      ntret_pend<= 1'b0;
                    end else if (!tr_valid || (tr_attr[3:0] != 4'hB)
                                 || (tr_limit < 32'h67)) begin
                      start_fault(8'd10, 1'b1, selector_error(tr_sel), q_pc);
                      seg_step  <= 1'b0;
                      ntret_pend<= 1'b0;
                      lcall_pend<= 1'b0;
                    end else begin
                      // NT-IRET task switch. attr|2 keeps the incoming TSS
                      // busy (0xB|2 == 0xB), and the outgoing EFLAGS IMAGE is
                      // staged with NT clear (the live flags move only at the
                      // S_TSW_BUSY commit).
                      tsw_new_base  <= desc_base(desc);
                      tsw_new_limit <= desc_limit(desc);
                      tsw_new_sel   <= q_ljmp_sel;
                      tsw_call      <= lcall_pend;
                      lcall_pend    <= 1'b0;
                      tsw_new_attr  <= attr | 8'h02;
                      tsw_save_eflags <= eflags & ~32'h0000_4000;
                      ntret_pend    <= 1'b0;
                      tsw_save_eip  <= next_eip;
                      tsw_step      <= 5'd0;
                      seg_step      <= 1'b0;
                      state         <= S_TSW_SAVE;
                    end
                  end else if ((desc_dpl(attr) < cpl_r)
                               || (desc_dpl(attr) < q_ljmp_sel[1:0])) begin
                    // REVIEW1_Aug3 R2-C01: a direct JMP/CALL to a TSS must be
                    // accessible at the caller's privilege: DPL >= max(CPL,
                    // RPL). The oracle selects this BEFORE the presence bit.
                    start_fault(8'd13, 1'b1, selector_error(q_ljmp_sel), q_pc);
                    seg_step  <= 1'b0;
                    ntret_pend<= 1'b0;
                    lcall_pend<= 1'b0;
                  end else if (desc_type(attr) == 4'hB) begin
                    // REVIEW2 H-04: a JMP/CALL to a BUSY TSS must #GP -- the
                    // target task is already active, and switching to it would
                    // corrupt its saved state. (The oracle's default case; it
                    // never reaches a presence check for this type.)
                    start_fault(8'd13, 1'b1, selector_error(q_ljmp_sel), q_pc);
                    seg_step  <= 1'b0;
                    ntret_pend<= 1'b0;
                    lcall_pend<= 1'b0;
                  end else if (!desc_present(attr)) begin
                    // an ABSENT descriptor whose type/privilege are otherwise
                    // acceptable is #NP(selector) -- and presence still
                    // precedes "unimplemented".
                    start_fault(8'd11, 1'b1, selector_error(q_ljmp_sel), q_pc);
                    seg_step  <= 1'b0;
                    ntret_pend<= 1'b0;
                    lcall_pend<= 1'b0;
                  end else if (desc_type(attr) != 4'h9) begin
                    // task gate / 286 TSS: legal forms this core does not
                    // implement -- HALT (the tag names the type), now AFTER
                    // every architecturally required fault above.
                    state<=S_HALT; `ifdef VEN_DBG_CORE int_vec<={4'hD, desc_type(attr)}; `endif seg_step<=1'b0;
                  end else if (q_ljmp_sel[2]) begin
                    // a TSS selector must name the GDT (SDM #GP; QEMU raises
                    // #TS -- the documented pxfer oracle gap).
                    start_fault(8'd13, 1'b1, selector_error(q_ljmp_sel), q_pc);
                    seg_step  <= 1'b0;
                    ntret_pend<= 1'b0;
                    lcall_pend<= 1'b0;
                  end else if (desc_limit(desc) < 32'h67) begin
                    // REVIEW1_Aug2 C-09 (last bullet): the TSS LIMIT. A 32-bit
                    // TSS must be at least 0x67 bytes -- the microsequence reads
                    // EIP@0x20, EFLAGS@0x24, eight GPRs, six selectors and
                    // LDTR@0x60, so a smaller one is read PAST ITS END.
                    start_fault(8'd10, 1'b1, {16'd0, q_ljmp_sel} & 32'h0000_FFFC, q_pc);
                    seg_step  <= 1'b0;
                    ntret_pend<= 1'b0;
                    lcall_pend<= 1'b0;
                  end else if (!tr_valid || (tr_attr[3:0] != 4'hB)
                              || (tr_limit < 32'h67)) begin
                    // REVIEW1_Aug3 R2-H04: precheck the CURRENT TR before the
                    // outgoing save's first write. #TS(current TR selector).
                    start_fault(8'd10, 1'b1, selector_error(tr_sel), q_pc);
                    seg_step  <= 1'b0;
                    ntret_pend<= 1'b0;
                    lcall_pend<= 1'b0;
                  end else begin
                    // HARDWARE TASK SWITCH to an available 32-bit TSS.
                    // REVIEW_Aug3 C-04: tsw_call latches the transfer KIND (a
                    // far CALL nests: back-link + NT + outgoing stays busy).
                    tsw_new_base  <= desc_base(desc);
                    tsw_new_limit <= desc_limit(desc);
                    tsw_new_sel   <= q_ljmp_sel;
                    tsw_call      <= lcall_pend;
                    lcall_pend    <= 1'b0;
                    tsw_new_attr  <= attr | 8'h02;
                    tsw_save_eflags <= eflags;
                    ntret_pend    <= 1'b0;
                    tsw_save_eip  <= next_eip;
                    tsw_step      <= 5'd0;
                    seg_step      <= 1'b0;
                    state         <= S_TSW_SAVE;
`ifdef VEN_DBG_WD
                    $display("[VEN-TSW] far-switch -> TSS sel=%04x type=%01x base=%08h @ outgoing cs:eip=%04x:%08h next_eip=%08h cur_tr=%04x off=%08h cr3=%08h",
                             q_ljmp_sel, desc_type(attr), desc_base(desc), seg_sel[SG_CS], eip, next_eip, tr_sel, q_ljmp_off, creg3);
`endif
                  end
                end else if (desc_type(attr) == 4'hC || desc_type(attr) == 4'h4) begin
                  // ===== CALL GATE (32-bit type 0xC / 16-bit type 0x4) =============
                  // BUG #6 (HW-confirmed): DOS-Quake's CWSDPMI far-transfers through a
                  // gate right after the RETF into the DPMI-side segment, and this arm
                  // used to loud-HALT (tag 0xE3 / 0xDC at FRZEIP=0x10dc).
                  //
                  // A call gate is NOT a code segment: it carries the real target in
                  //   offset = {desc[63:48], desc[15:0]}   (16-bit gate: low half only)
                  //   selector = desc[31:16]               (the target CODE selector)
                  //   DPL      = desc[45:44],  P = desc[47]
                  // IA-32 6.11: the gate is usable when gate.DPL >= CPL AND
                  // gate.DPL >= RPL(gate selector) — else #GP(selector).
                  //
                  // We RE-VECTOR: install the gate's target selector/offset into
                  // q_ljmp_sel/q_ljmp_off and restart this same 2-beat descriptor read
                  // (seg_step<=0, state stays S_LJMP). The bus driver addresses the
                  // descriptor from q_ljmp_sel, so the next pass reads the TARGET CS
                  // descriptor and falls into the ordinary code-segment path below.
                  // gate_via records that we arrived through a gate, because the CPL
                  // rule then differs from a plain far jump (see below).
                  logic [15:0] gsel; logic [31:0] goff; logic [1:0] gdpl;
                  gsel = desc[31:16];
                  goff = (desc_type(attr) == 4'hC) ? {desc[63:48], desc[15:0]}
                                                   : {16'd0,      desc[15:0]};
                  // REVIEW2_aug2 C-06: THE GATE'S DPL WAS READ FROM THE WRONG BITS.
                  // The access byte is desc[47:40] and DPL is its [6:5], i.e.
                  // desc[46:45] -- this read desc[45:44], which is {DPL[0], S}. For a
                  // SYSTEM descriptor S=0, so a DPL-3 gate decoded as DPL 2 and a
                  // DPL-1 gate as DPL 0; only DPL 0 was right, by accident.
                  //
                  // The consequence is not subtle: `gdpl < cpl_r` then rejected every
                  // DPL-3 gate called from ring 3 with #GP(selector) -- and a DPL-3
                  // gate is the ONLY kind ring-3 code can use, so NO cross-privilege
                  // call gate could ever be taken. That is also why the 0xDB
                  // "cross-priv gate not implemented" halt below was never observed by
                  // any corpus run: the transfer was killed one check earlier.
                  //
                  // Use the shared accessor rather than a literal slice, so this
                  // cannot drift from desc_dpl() again.
                  gdpl = desc_dpl(desc_attr(desc));
                  if ((gdpl < cpl_r) || (gdpl < q_ljmp_sel[1:0])) begin
                    // gate not reachable from this privilege level -> #GP(selector).
                    // The oracle selects this BEFORE the presence bit.
                    start_fault(8'd13, 1'b1, selector_error(q_ljmp_sel), q_pc); /* R2-C02: TI preserved */
                    seg_step <= 1'b0; gate_via <= 1'b0;
                  end else if (!desc_present(attr)) begin
                    // an absent gate whose DPL admits the caller -> #NP(selector)
                    start_fault(8'd11, 1'b1, selector_error(q_ljmp_sel), q_pc);
                    seg_step <= 1'b0; gate_via <= 1'b0;
                    ntret_pend<= 1'b0;
                    lcall_pend<= 1'b0;
                  // REVIEW2_aug2 H-07: the gate's EMBEDDED TARGET selector was accepted
                  // unchecked and then used to index the descriptor table on the next
                  // pass. A gate whose target selector is null, or points past the GDT/
                  // LDT limit, therefore issued an out-of-table descriptor read -- which
                  // under paging can take a #PF, delivering the wrong exception ahead of
                  // the architecturally prior #GP. The initial selector is prechecked at
                  // dispatch (SYS_LJMP) and LTR/LLDT got the same treatment under H-01;
                  // the gate's target is the third selector dereference and was the one
                  // still unguarded.
                  //
                  // A NULL target is #GP(0) per the SDM (a gate may not point at the
                  // null descriptor); an out-of-table one is #GP(sel & 0xFFFC).
                  // R2-C02: null is TI=0/index-0 -- a TI=1 index-0 target names LDT
                  // entry 0 and is bounded below like any other entry.
                  end else if (is_null_selector(gsel)) begin
                    start_fault(8'd13, 1'b1, 32'd0, q_pc);          // null gate target
                    seg_step <= 1'b0; gate_via <= 1'b0;
                  end else if (gsel[2]
                               ? ({16'd0, gsel[15:3], 3'd0} + 32'd7 > {16'd0, ldt_limit})
                               : ({16'd0, gsel[15:3], 3'd0} + 32'd7 > {16'd0, gdt_limit})) begin
                    start_fault(8'd13, 1'b1, selector_error(gsel), q_pc); /* R2-C02: TI preserved */
                    seg_step <= 1'b0; gate_via <= 1'b0;
                  end else begin
                    q_ljmp_sel <= gsel;
                    q_ljmp_off <= goff;
                    gate_via   <= 1'b1;
                    // REVIEW2_aug2 C-06: the gate's parameter count, kept for the
                    // cross-privilege arm -- on the next pass `desc` is the TARGET
                    // CS descriptor and the gate's own fields are gone.
                    cg_pcount  <= desc[36:32];
                    // REVIEW1_Aug3 R2-H05: the gate's WIDTH must be kept for the
                    // same reason. 1 = 32-bit gate (type 4'hC), 0 = 16-bit (4'h4):
                    // it fixes the frame's unit size, the ESP commit mask, and the
                    // parameter-copy stride -- none of which may come from the
                    // caller's operand size or the target's D bit.
                    cg_wide    <= (desc_type(attr) == 4'hC);
                    seg_step   <= 1'b0;      // re-read: now the TARGET CS descriptor
                  end
                end else begin
                  // Every other system-descriptor class on a direct far
                  // transfer (LDT, data-in-system, interrupt/trap gates,
                  // reserved types): the pinned oracle's default case is
                  // #GP(selector), present or not. (Only the forms it ACCEPTS
                  // but this core does not implement -- task gate, 286 TSS --
                  // still loud-HALT, in the TSS-family arm above.)
                  start_fault(8'd13, 1'b1, selector_error(q_ljmp_sel), q_pc);
                  seg_step  <= 1'b0;
                  ntret_pend<= 1'b0;
                  lcall_pend<= 1'b0;
                end
              end else if (seg_load_fault(1'b1, 1'b0, q_ljmp_sel, attr, cpl_r)) begin
                // #GP/#NP on a far-jump CS load -> DELIVER (error code = selector,
                // TI preserved per R2-C02).
                start_fault(seg_fault_vec(1'b1, 1'b0, q_ljmp_sel, attr, cpl_r), 1'b1,
                            selector_error(q_ljmp_sel), q_pc);
                seg_step<=1'b0;
              end else if (gate_via && (desc_dpl(attr) > cpl_r)) begin
                // REVIEW1_Aug3 R2-C01: a call-gate target LESS privileged than the
                // caller is #GP(selector) -- conforming or not, CALL or JMP. This
                // used to be accepted as a same-privilege transfer.
                start_fault(8'd13, 1'b1, selector_error(q_ljmp_sel), q_pc);
                seg_step<=1'b0; gate_via<=1'b0;
              end else if (!gate_via && (attr[2]
                           ? (desc_dpl(attr) > cpl_r)
                           : (retf_same ? (desc_dpl(attr) != q_ljmp_sel[1:0])
                                        : ((desc_dpl(attr) != cpl_r)
                                           || (q_ljmp_sel[1:0] > cpl_r))))) begin
                // REVIEW1_Aug3 R2-C01: the DIRECT-transfer DPL/RPL matrix the shared
                // state never had (gate targets take the gate matrix instead):
                //   conforming:     DPL <= CPL (any transfer)
                //   nonconforming:  direct JMP/CALL: DPL == CPL and RPL <= CPL
                //                   RETF (retf_same): DPL == popped RPL
                //                     (popped RPL < CPL is rejected at the pop)
                // A crafted selector could previously lower cpl_r without an
                // authorized gate.
                start_fault(8'd13, 1'b1, selector_error(q_ljmp_sel), q_pc);
                seg_step<=1'b0; lcall_pend<=1'b0; retf_same<=1'b0;
              end else if (gate_via && !attr[2] && (desc_dpl(attr) < cpl_r)
                           && !lcall_pend) begin
                // REVIEW_Aug3 C-04: a JMP may NOT raise privilege through a call
                // gate. The cross-privilege branch below checks only
                // `gate_via && target_DPL<CPL`, and gate_via is set for far JMP and
                // far CALL alike -- so a far JMP through a gate to a more
                // privileged nonconforming target entered the CALL stack-switch
                // path and pushed a return frame. IA-32 raises #GP(selector) here.
                // (attr[2] is the code-segment CONFORMING bit: a conforming target
                // is not a privilege change for JMP or CALL and falls through to
                // the ordinary paths, which keep CPL.)
                start_fault(8'd13, 1'b1, selector_error(q_ljmp_sel), q_pc); /* R2-C02: TI preserved */
                seg_step <= 1'b0; gate_via <= 1'b0;
              end else if (gate_via && !attr[2] && (desc_dpl(attr) < cpl_r)) begin
                // CROSS-PRIVILEGE call gate (target CS.DPL < CPL). REVIEW_Aug3 C-04:
                // this branch is now reached only by a far CALL (lcall_pend) to a
                // NONCONFORMING target -- the JMP form faults above and a conforming
                // target is not a privilege change.
                //
                // IA-32 requires a
                // STACK SWITCH here: load SS:ESP from TSS.ssN/espN for the new CPL,
                // copy `param count` dwords from the old stack, then push the old
                // SS:ESP and the return CS:EIP. NOT implemented yet — and it must not
                // be faked, because taking the same-privilege path would push the
                // return frame on the CALLER's stack while running at a HIGHER
                // privilege: a silent privilege escalation with a corrupt frame.
                // Halt loudly with its own tag (0xDB) so a freeze read distinguishes
                // "cross-priv gate" from every other gate case. The machinery to reuse
                // already exists in the interrupt path (S_INT_TSS reads TSS.ssN:espN,
                // S_INT_SS loads the new SS, S_INT_PUSH builds the frame) — see task #47.
                // IMPLEMENTED (REVIEW2_aug2 C-06, call-gate half) by reusing the
                // interrupt path's cross-privilege machinery exactly as the note
                // above predicted: S_INT_TSS reads TSS.ssN:espN, S_INT_SS validates
                // and loads the new SS (and commits cpl_r <= int_new_cpl), and
                // S_INT_PUSH builds the frame and is the single commit point for
                // CS/EIP. This arm only stages the target and enters that sequence.
                //
                // REVIEW1_Aug3 R2-H05: PARAMETER COPY + GATE WIDTH are now
                // implemented too (the 0xDA halt is gone). cg_pcount/cg_wide,
                // staged at the gate beat, drive S_CG_PRD (params off the old
                // stack before the SS/CPL commit) and the width-correct frame
                // in S_INT_PUSH. A 16-bit cross-privilege gate no longer builds
                // a 32-bit frame (the old §B.1 silent defect).
                begin
                  // Stage the TARGET CS: the commit in S_INT_PUSH reads int_cs_*, so
                  // nothing is installed until the whole frame is on the new stack.
                  int_cs_base  <= desc_base(desc);
                  int_cs_limit <= desc_limit(desc);
                  int_cs_attr  <= attr;
                  int_cs_d     <= desc[54];
                  int_gate_sel <= {q_ljmp_sel[15:2], desc_dpl(attr)};  // RPL = new CPL
                  int_gate_off <= q_ljmp_off;
                  int_new_cpl  <= desc_dpl(attr);
                  int_old_ss   <= seg_sel[SG_SS];
                  int_old_esp  <= gpr_o[R_ESP];
                  int_old_cs   <= seg_sel[SG_CS];
                  int_ret_eip  <= next_eip;      // a CALL returns AFTER itself
                  int_src_pc   <= q_pc;
                  int_has_err  <= 1'b0;
                  from_v86     <= 1'b0;
                  xpl_active   <= 1'b1;
                  cg_xpl       <= 1'b1;
                  int_step     <= 4'd0;
                  seg_step     <= 1'b0;
                  gate_via     <= 1'b0;
                  lcall_pend   <= 1'b0;   // S_INT_PUSH builds the frame now
                  state        <= S_INT_TSS;
                end
              end else if (lcall_pend) begin
                // ---- REVIEW2_aug2 C-06 (descriptor half): PROBE PASS of a far CALL.
                // Everything above has already run -- gate resolution, seg_load_fault,
                // the cross-priv-gate halt -- so by here the target is fully validated
                // and NOTHING has touched the stack. Park the result and go push.
                // The offset-vs-limit check is repeated here rather than deferred,
                // because it is the last thing that can reject the target.
                if ({1'b0, q_ljmp_off} > {1'b0, desc_limit(desc)}) begin
                  lcall_pend <= 1'b0; seg_step <= 1'b0; gate_via <= 1'b0;
                  start_fault(8'd13, 1'b1, 32'd0, q_pc);
                end else begin
                  lc_cs_base  <= desc_base(desc);
                  lc_cs_limit <= desc_limit(desc);
                  lc_cs_attr  <= attr;
                  lc_cs_d     <= desc[54];
                  // REVIEW_Aug3 F2: the conforming-target CPL rule must match the
                  // S_LJMP commit exactly -- DPL < CPL keeps the CPL (and forces
                  // CS.RPL to it at the commit), otherwise the selector's RPL.
                  lc_cs_cpl   <= (gate_via || (attr[2] && (desc_dpl(attr) < cpl_r)))
                               ? cpl_r : q_ljmp_sel[1:0];
                  // REVIEW1_Aug3 R2-H05: a same-privilege transfer THROUGH A GATE
                  // pushes its return frame in the GATE's width, not the caller's
                  // operand size. gate_via is cleared below; park both bits.
                  lc_gate     <= gate_via;
                  lc_gw       <= cg_wide;
                  gate_via    <= 1'b0;
                  seg_step    <= 1'b0;
                  state       <= S_LCALL;   // now push, then commit there
                end
              end else begin
                // REVIEW_Aug4 A4-C02: the offset-vs-limit decision comes FIRST.
                // This arm used to schedule the CS/CPL/hidden-cache/EIP commit and
                // only then check the offset, on the theory that start_fault
                // "overrides the commit" -- but nonblocking priority only helps
                // signals assigned AGAIN, and start_fault does not restore CS
                // hidden state, CPL, or seg_pm_loaded: a direct far JMP (or the
                // same-level RETF sharing this arm) delivered #GP from the
                // partially installed TARGET state, and the fault frame pushed
                // the target's CS. The check is now structural: nothing
                // architectural assigns on the reject path. (retf_commit_w
                // carries the same offset term, so the staged RETF ESP advance
                // cannot fire on the reject either.)
                if ({1'b0, q_ljmp_off} > {1'b0, desc_limit(desc)}) begin
                  // #GP(0): a control transfer past the segment limit (the
                  // selector is fine; the offset is not). ESP/CS/CPL untouched.
                  retire_valid <= 1'b0;
                  seg_step     <= 1'b0;
                  start_fault(8'd13, 1'b1, 32'd0, q_pc);
                end else begin
                // REVIEW_Aug3 F2 (found by the pjmpgate differential): for a
                // CONFORMING target with DPL < CPL, the loaded CS selector's RPL is
                // forced to the CPL (QEMU seg_helper.c: (sel & 0xFFFC) | cpl) and
                // the CPL does NOT change -- installing the selector verbatim left
                // CS.RPL != CPL after the transfer, and a direct far transfer with
                // selector RPL < CPL would silently escalate privilege.
                logic [1:0] erpl;
                erpl = (attr[2] && (desc_dpl(attr) < cpl_r)) ? cpl_r
                                                             : q_ljmp_sel[1:0];
                seg_sel  [SG_CS] <= {q_ljmp_sel[15:2], erpl};
                seg_base [SG_CS] <= desc_base(desc);
                seg_limit[SG_CS] <= desc_limit(desc);
                seg_attr [SG_CS] <= attr;
                seg_pm_loaded[SG_CS] <= 1'b1;   // R2-H07: validated PM descriptor load
                // CPL: a plain far jump takes CS.RPL. Through a CALL GATE the selector
                // RPL is NOT the new privilege (gates commonly carry RPL 0 while the
                // transfer is same-privilege) — using it would silently escalate to
                // ring 0. Same-privilege gate transfers KEEP the current CPL; the
                // cross-privilege case is rejected above. erpl is the forced RPL (F2).
                cpl_r    <= gate_via ? cpl_r : erpl;
                cs_d <= desc[54];   // D/B bit: 1 => 32-bit default operand/addr size
                eip<=q_ljmp_off; retire_valid<=1'b1; state<=S_PIPE; seg_step<=1'b0;
                gate_via <= 1'b0;
                // REVIEW_Aug3 H-02: this commit is also the same-privilege RETF's --
                // retf_commit_w fires the staged ESP advance on this same clock.
                retf_same <= 1'b0;
                end
              end
            end
          end
        end

        // -------------------------------------------------------------------
        // M9.5 — S_LCALL: far CALL (0x9A) return-frame pushes. Two descending
        // stack writes (the bus driver supplies the address/data per beat):
        // beat 0 pushes CS, beat 1 pushes the return IP. Real mode loads CS
        // (base=sel<<4), sets EIP=off, and retires at beat 1. PM arrives here
        // via the S_LJMP descriptor-validation probe (lcall_pend) and commits
        // the validated descriptor below.
        // -------------------------------------------------------------------
        S_LCALL: begin
          if (mem_ack) begin
            if (!seg_step) seg_step <= 1'b1;          // CS pushed (beat 0)
            else if (!seg_real) begin
              // PM far CALL: both return-frame pushes are done (the ESP-=2w fires in
              // the gpr-wb S_LCALL arm at this same beat-1 ack). Hand off to S_LJMP,
              // which reads the target CS descriptor from the GDT, loads CS:base/
              // limit/attr/CPL/D, sets EIP=q_ljmp_off and retires — identical CS-load
              // path the PM far JMP already uses (incl. seg_load_fault delivery).
              // REVIEW2_aug2 H-07: bound the target selector before S_LJMP issues the
              // descriptor read. This one arm covers EVERY far CALL form -- immediate
              // ptr16:32 and both memory-indirect forms all funnel through S_LCALL --
              // whereas the dispatch precheck only ever covered SYS_LJMP.
              //
              // ---- C-06 STATUS at this site, traced rather than asserted -----------
              // SELECTOR half: DONE, but NOT here. A bad selector is now rejected at
              // dispatch and at both memory-indirect load completions -- i.e. BEFORE
              // S_LCALL pushes anything (see core_fetch_decode.svh SYS_LCALL and
              // core_load.svh). This site is the backstop that stops the out-of-table
              // descriptor READ; by the time it runs the frame is already pushed.
              //
              // DESCRIPTOR half: NOT DONE. The reason recorded here previously was
              // WRONG and is corrected rather than left standing.
              //
              // I wrote that a "validate, then push, then commit" reorder could not be
              // done for the ordinary case alone, because S_LJMP's commit also serves
              // CALL GATES and a gate decides whether privilege changes and therefore
              // what the stack does -- so validation and stack behaviour were coupled.
              // That coupling DOES NOT EXIST in the implemented design: the cross-
              // privilege gate case a few lines above HALTS with tag 0xDB, explicitly
              // unimplemented. Every transfer that reaches this commit is therefore
              // SAME-PRIVILEGE, gate or not, and pushes CS:EIP on the current stack.
              // A probe-then-push reorder would be uniform, and the cross-priv gate
              // would halt during the probe -- BEFORE any push, which is strictly
              // better than today, where it halts after two.
              //
              // WHAT ACTUALLY REMAINS is ordinary work, not an impossibility: route
              // SYS_LCALL through S_LJMP in a no-commit mode, stage the validated CS
              // (the int_cs_*/iret_cs_* pattern already in the tree), return to
              // S_LCALL for the pushes, and commit there.
              //
              // Regression cover status (kept current): the indirect forms are now
              // gated -- psoccallfmem (source-controlled, in verify-sys) covers
              // real/V86 m16:16+m16:32 memory-indirect far CALL including the
              // stack-built BP/SS pointer shape, top-of-stack wraps, and protected
              // positive/rejected controls; pfarok covers the protected direct
              // forms; pcallsel covers the reject path. psocfarcall/psocpmretf
              // remain binary-only orphans (no .S/Makefile, referenced by zero
              // gates -- the missing-source class task #64 tracks). The reorder
              // above is still optional hardening, not a known defect.
              // Sixth time this review a "blocked" call of mine was wrong. The pattern
              // every time: I described what the code would do instead of reading what
              // it does.
              // REVIEW2_aug2 C-06: the descriptor was validated BEFORE these pushes,
              // in the S_LJMP probe pass, and its result is parked in lc_cs_*. Commit
              // it here, with the frame already on the stack and nothing left that can
              // reject the transfer. (The far_sel_bad backstop is gone from this arm
              // because the selector is checked at dispatch and the descriptor at the
              // probe -- both before any push.)
              // REVIEW_Aug3 F2: install the selector with the conforming-target RPL
              // forcing, exactly as the S_LJMP commit does.
              // REVIEW1_Aug3 R2-H05 follow-up (B2, found by pcg16): a same-privilege
              // transfer THROUGH A GATE installs RPL = CPL too (QEMU
              // helper_lcall_protected: selector = (sel & ~3) | dpl, and dpl == CPL
              // for any same-privilege target) -- the gate's embedded target selector
              // commonly carries RPL 0, which left CS.RPL != CPL in the trace.
              seg_sel  [SG_CS] <= {q_ljmp_sel[15:2],
                                   (lc_gate || (lc_cs_attr[2] && (desc_dpl(lc_cs_attr) < cpl_r)))
                                   ? cpl_r : q_ljmp_sel[1:0]};
              seg_base [SG_CS] <= lc_cs_base;
              seg_limit[SG_CS] <= lc_cs_limit;
              seg_attr [SG_CS] <= lc_cs_attr;
              seg_pm_loaded[SG_CS] <= 1'b1;   // R2-H07: validated (probe-pass) load
              cs_d             <= lc_cs_d;
              cpl_r            <= lc_cs_cpl;
              eip              <= q_ljmp_off;
              lcall_pend       <= 1'b0;
              lc_gate          <= 1'b0;   // R2-H05: gate width consumed
              seg_step         <= 1'b0;
              retire_valid     <= 1'b1;
              state            <= S_PIPE;
            end
            else begin
              // R3: SP -= 2w bump moved to the gpr writeback driver (S_LCALL arm).
              seg_sel [SG_CS] <= q_ljmp_sel;
              seg_base[SG_CS] <= {12'd0, q_ljmp_sel, 4'd0};        // base = sel<<4
              seg_attr[SG_CS] <= 8'h9B;
              seg_pm_loaded[SG_CS] <= 1'b0;   // R2-H07: real-mode load
              eip <= q_ljmp_off; retire_valid<=1'b1; state<=S_PIPE; seg_step<=1'b0;
            end
          end
        end

        // -------------------------------------------------------------------
        // M9.5 — S_RETF: REAL-MODE far return (0xCB / 0xCA imm16). Two ascending
        // stack reads: beat 0 pops the IP (held in retf_off), beat 1 pops CS. On
        // beat 1's ack, load CS (base=sel<<4), set EIP from the popped IP (16- or
        // 32-bit per operand size), bump ESP by 2*w + imm16, and retire.
        // -------------------------------------------------------------------
        S_RETF: begin
          if (mem_ack) begin
            if (!seg_step) begin
              retf_off <= mem_rdata;                  // popped IP (beat 0)
              seg_step <= 1'b1;
            end else if (!seg_real) begin
              // PM far RETF: both pops are done (ESP+=2w+imm fires in the gpr-wb
              // S_RETF arm at this same beat-1 ack). Latch the popped {CS, EIP} into
              // the far-target regs and hand off to S_LJMP, which reads the target CS
              // descriptor from the GDT/LDT, loads CS base/limit/attr/CPL/D, sets
              // EIP=q_ljmp_off and retires — the identical CS-load path the PM far
              // JMP/CALL already use (incl. seg_load_fault delivery). DOS Quake's
              // CWSDPMI far-returns same-privilege (popped CS RPL == CPL).
              q_ljmp_sel <= mem_rdata[15:0];
              q_ljmp_off <= (q_w==3'd2) ? {16'd0, retf_off[15:0]} : retf_off;
              // ---- REVIEW2_aug2 C-06 (RETF outer-level): IMPLEMENTED ------------
              // A protected RETF whose popped CS.RPL > CPL returns to an OUTER
              // privilege level: the frame carries ESP and SS as well, and both must
              // be popped and VALIDATED before anything commits. This core reused
              // far-JMP semantics, so CPL took the popped RPL while SS:ESP stayed the
              // INNER ones -- outer code holding an inner stack pointer, silently.
              //
              // Rather than write a second cross-privilege path, this reuses the one
              // C-07 already built for the inter-privilege IRET: stage the frame into
              // the iret_* registers, then hand off to S_INT_CS_RET, which validates
              // the CS, and S_IRET_SS, which validates the SS and commits CS/SS/EIP/
              // EFLAGS/CPL/ESP on ONE clock. The rules are identical for both
              // instructions, so sharing them is what keeps them from drifting.
              //
              // The ONE architectural difference is EFLAGS: an IRET restores it from
              // the frame, a RETF does not touch it. Staging iret_eflags <= eflags
              // makes the shared commit a no-op for flags, so no commit variant is
              // needed. (The other difference, NMI unblocking, is gated on retf_out
              // at the commit itself -- see core_iret.svh.)
              if (retf_out) begin
                if (!retf_ob) begin
                  // beat 2: the OUTER ESP. `RET imm16` adds imm to the OUTER stack
                  // pointer, not the inner one, so fold it in here.
                  // REVIEW_Aug3 H-02: a 16-bit outer RETF (q_w==2) pops a WORD SP --
                  // the frame is SP[2] then SS[2], so this dword read carries SS in
                  // its upper half. Zero-extend the SP word (matching the 16-bit
                  // iret_eip treatment) instead of installing the garbage high half.
                  iret_esp <= (q_w==3'd2) ? ({16'd0, mem_rdata[15:0]} + {16'd0, q_ret_imm})
                                          : (mem_rdata + {16'd0, q_ret_imm});
                  retf_ob  <= 1'b1;
                end else begin
                  // beat 3: the OUTER SS. Hand off to the validated CS reload.
                  iret_ss      <= mem_rdata[15:0];
                  int_gate_sel <= iret_cs;
                  int_step     <= 4'd0;
                  seg_step     <= 1'b0;
                  retf_ob      <= 1'b0;
                  if (!sel_in_table(iret_cs))
                    start_fault(8'd13, 1'b1, {16'd0, iret_cs} & 32'h0000_FFFC, q_pc);
                  else state <= S_INT_CS_RET;
                end
              end else if (mem_rdata[1:0] < cpl_r) begin
                // REVIEW1_Aug3 R2-C01: RETF may not RAISE privilege. A popped CS
                // with RPL < CPL took the same-privilege path above and lowered
                // cpl_r to the crafted RPL; it is #GP(selector) instead.
                start_fault(8'd13, 1'b1, selector_error(mem_rdata[15:0]), q_pc);
                seg_step <= 1'b0;
              end else if (mem_rdata[1:0] > cpl_r) begin
                // beat 1 detected the outer return. Stage what is already known and
                // keep popping; NOTHING architectural moves until S_IRET_SS.
                retf_out       <= 1'b1;
                retf_ob        <= 1'b0;
                iret_interpriv <= 1'b1;
                iret_cs        <= mem_rdata[15:0];
                iret_eip       <= (q_w==3'd2) ? {16'd0, retf_off[15:0]} : retf_off;
                iret_eflags    <= eflags;      // a RETF does not restore EFLAGS
                int_src_pc     <= q_pc;        // the retire record stamps at the RETF
              end else begin
                            // REVIEW2_aug2 H-07: the POPPED CS is the least trustworthy selector in
              // the core -- it comes straight off the stack -- and it reached S_LJMP
              // with no bounds test at all.
              if (far_sel_bad(mem_rdata[15:0]))
                start_fault(8'd13, 1'b1,
                            {16'd0, mem_rdata[15:0]} & 32'h0000_FFFC, q_pc);
              else begin
                // REVIEW_Aug3 H-02: stage the ESP advance (2w + imm16) instead of
                // letting the gpr writeback apply it NOW. The popped target CS is
                // validated only in S_LJMP; a rejected target must fault with ESP
                // and the stack frame untouched. retf_commit_w fires the writeback
                // on the clock S_LJMP accepts the target.
                retf_same    <= 1'b1;
                retf_esp_adj <= {27'd0, q_w, 1'b0} + {16'd0, q_ret_imm};
                seg_step <= 1'b0; state <= S_LJMP;
              end
              end   // C-06: closes the same-privilege else
            end else begin
              logic [15:0] new_cs;
              new_cs = mem_rdata[15:0];               // popped CS (beat 1)
              seg_sel [SG_CS] <= new_cs;
              seg_base[SG_CS] <= {12'd0, new_cs, 4'd0};
              seg_attr[SG_CS] <= 8'h9B;
              seg_pm_loaded[SG_CS] <= 1'b0;   // R2-H07: real-mode load
              // R3: ESP += 2w + imm bump moved to the gpr writeback driver (S_RETF arm).
              eip <= (q_w==3'd2) ? {16'd0, retf_off[15:0]} : retf_off;
              retire_valid<=1'b1; state<=S_PIPE; seg_step<=1'b0;
            end
          end
        end

        // -------------------------------------------------------------------
        // M9.5 — S_SGDT: 2-beat store of the GDTR/IDTR pseudo-descriptor (the bus
        // driver supplies the address/data/strobe per beat). beat 0 writes the
        // {base[15:0],limit} word, beat 1 the base[31:16] half; then retire.
        // -------------------------------------------------------------------
        S_SGDT: begin
          // Walk detours leave these phase latches intact. The main FSM's
          // fault/walk priority prevents advance until this page is validated.
          if (sgdt_probe_q) begin
            if (!seg_access_fault && !perm_fault && !xlate_miss && !fe_xlate_pend) begin
              if (paging_on && sgdt_probe_cross && !sgdt_probe_second)
                sgdt_probe_second <= 1'b1;
              else begin sgdt_probe_q<=1'b0; sgdt_probe_second<=1'b0; end
            end
          end else if (mem_ack) begin
            if (!seg_step) seg_step <= 1'b1;
            else begin
              eip<=next_eip; retire_valid<=1'b1; state<=S_PIPE; seg_step<=1'b0;
            end
          end
        end
