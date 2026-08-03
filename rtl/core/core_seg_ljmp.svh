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
          if (mem_ack) begin
            logic [15:0] msel;
            logic        mnull;
            msel  = q_seg_from_mem ? seg_mem_sel : gpr_o[q_src_reg][15:0];
            mnull = (msel[15:3] == 13'd0);
            // M2S.3 — selector index past the GDT limit -> #GP(13) carrying the
            // selector as the error code (the descriptor read was out of bounds;
            // we discard it). A NULL selector (idx 0) skips the limit check (a
            // null load into DS/ES/FS/GS is legal). Checked on beat 0 so we
            // deliver before consuming the (garbage) descriptor.
            if (!seg_step && !mnull &&   // TI bit (msel[2]) picks the GDT vs LDT limit
                ({16'd0, msel[15:3], 3'd0} + 32'd7 > {16'd0, (msel[2]?ldt_limit:gdt_limit)})) begin
`ifdef VEN_DBG_CORE
              // task #102 #GP triage (plusarg-gated, inert by default): a PM seg-load
              // whose selector index overruns the GDT/LDT limit. Dumps the mode context
              // so a spurious PM-walk of a REAL-mode segment value is identifiable.
              if (segfaultdbg) $display(
                "[SEGFLT] LIMIT #GP sel=%04x from_mem=%b tgt=%0d sysop=%0d ispop=%b popsreg=%b srcreg=%0d src=%08x seg_step=%b | seg_real=%b real=%b v86=%b cr0=%08x ef=%08x | gdt_lim=%08x ldt_lim=%08x cpl=%0d cs=%04x q_pc=%08x",
                msel, q_seg_from_mem, (q_seg_from_mem?q_lseg:q_sys_sreg), q_sysop, q_is_pop, q_pop_sreg,
                q_src_reg, gpr_o[q_src_reg], seg_step, seg_real, real_mode, v86,
                creg0, eflags, gdt_limit, ldt_limit, cpl_r, seg_sel[SG_CS], q_pc);
`endif
              start_fault(8'd13, 1'b1, {16'd0, msel}, q_pc);
              seg_step<=1'b0; q_seg_from_mem<=1'b0;
            end else if (!seg_step) begin gdt_lo<=mem_rdata; seg_step<=1'b1; end
            else begin
              logic [63:0] desc;
              logic [7:0]  attr;
              logic        is_ss;
              logic [2:0]  tgt;
              desc  = {mem_rdata, gdt_lo};
              attr  = desc_attr(desc);
              tgt   = q_seg_from_mem ? q_lseg : q_sys_sreg;  // PM mov-sreg-from-mem -> q_lseg
              is_ss = (tgt == 3'(SG_SS));
              // PROTECTION DECISION (M2S.1) -> now DELIVERED through the IDT (M2S.3).
              if (seg_load_fault(1'b0, is_ss, msel, attr, cpl_r)) begin
`ifdef VEN_DBG_CORE
                if (segfaultdbg) $display(
                  "[SEGFLT] DESC fault sel=%04x attr=%02x from_mem=%b tgt=%0d | seg_real=%b v86=%b cr0=%08x ef=%08x cpl=%0d cs=%04x q_pc=%08x",
                  msel, attr, q_seg_from_mem, tgt, seg_real, v86, creg0, eflags, cpl_r, seg_sel[SG_CS], q_pc);
`endif
                // #NP/#SS/#GP — error code = selector (idx<<3 | TI | EXT=0).
                start_fault(seg_fault_vec(1'b0, is_ss, msel, attr), 1'b1,
                            {16'd0, msel[15:3], 3'd0}, q_pc);
                seg_step<=1'b0; q_seg_from_mem<=1'b0;
              end else begin
                seg_sel  [tgt] <= msel;
                seg_base [tgt] <= desc_base(desc);
                seg_limit[tgt] <= desc_limit(desc);
                seg_attr [tgt] <= attr;
                // REVIEW2 C-07: capture SS's D/B bit exactly as the CS path captures
                // desc[54] into cs_d. Without it there was no hidden SS.B state at all,
                // so stk16() could not know a protected-mode stack was 16-bit and never
                // wrapped SP at 64 KiB.
                if (tgt == SG_SS) ss_b <= desc[54];
                // REVIEW2_aug2 H-05: capture B for EVERY segment, so a non-SS
                // expand-down data segment has a real upper bound instead of 4 GiB.
                seg_b[tgt] <= desc[54];
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
              // and resume the incoming task. A JMP does NOT set NT / the back-link
              // (only a CALL/interrupt-task-gate does — see the deferral note below).
              // Capture the new TSS descriptor (base/limit/sel/access) here, then
              // run the S_TSW_* micro-sequence. Other system descriptors (task gate
              // 0x5, call gate, LDT, ...) are not in the corpus -> HALT cleanly.
              if (!desc_s(attr)) begin
                // REVIEW2 H-04: a JMP to a BUSY TSS (type 0xB) must #GP -- it means the
                // target task is already active, and switching to it would corrupt its
                // saved state. Only an AVAILABLE TSS (0x9) is a legal JMP target; the
                // busy type is legal only for an IRET back to a nested task. Accepting
                // both let a JMP re-enter a running task and overwrite its context.
                if (desc_present(attr) && (desc_type(attr) == 4'hB)) begin
                  start_fault(8'd13, 1'b1, {16'd0, q_ljmp_sel[15:2], 2'b00}, q_pc);
                  seg_step <= 1'b0;
                end else if (desc_present(attr) && (desc_type(attr) == 4'h9)
                             && (desc_limit(desc) < 32'h67)) begin
                  // REVIEW1_Aug2 C-09 (last bullet): the TSS LIMIT was never checked.
                  // A 32-bit TSS must be at least 0x67 bytes -- the microsequence reads
                  // EIP@0x20, EFLAGS@0x24, eight GPRs, six selectors and LDTR@0x60, so
                  // a smaller one is read PAST ITS END and the new task starts from
                  // whatever follows it in memory. IA-32 raises #TS(selector).
                  // Present and available-vs-busy were already checked above; this is
                  // the size, which is the part that decides whether the fields the
                  // switch is about to read even exist.
                  start_fault(8'd10, 1'b1, {16'd0, q_ljmp_sel} & 32'h0000_FFFC, q_pc);
                  seg_step <= 1'b0;
                end else if (desc_present(attr) && (desc_type(attr) == 4'h9)) begin
                  // HARDWARE TASK SWITCH to a 32-bit TSS.
                  tsw_new_base  <= desc_base(desc);
                  tsw_new_limit <= desc_limit(desc);
                  tsw_new_sel   <= q_ljmp_sel;
                  tsw_new_attr  <= attr | 8'h02;     // incoming busy bit set (9->B)
                  tsw_save_eip  <= next_eip;          // outgoing resume EIP (after jmp)
                  tsw_step      <= 5'd0;
                  seg_step      <= 1'b0;
                  state         <= S_TSW_SAVE;
`ifdef VEN_DBG_WD
                  $display("[VEN-TSW] far-switch -> TSS sel=%04x type=%01x base=%08h @ outgoing cs:eip=%04x:%08h next_eip=%08h cur_tr=%04x off=%08h cr3=%08h",
                           q_ljmp_sel, desc_type(attr), desc_base(desc), seg_sel[SG_CS], eip, next_eip, tr_sel, q_ljmp_off, creg3);
`endif
                end else if (desc_present(attr) &&
                            (desc_type(attr) == 4'hC || desc_type(attr) == 4'h4)) begin
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
                  gdpl = desc[45:44];
                  if ((gdpl < cpl_r) || (gdpl < q_ljmp_sel[1:0])) begin
                    // gate not reachable from this privilege level -> #GP(selector)
                    start_fault(8'd13, 1'b1, {16'd0, q_ljmp_sel[15:3], 3'd0}, q_pc);
                    seg_step <= 1'b0; gate_via <= 1'b0;
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
                  end else if (gsel[15:3] == 13'd0) begin
                    start_fault(8'd13, 1'b1, 32'd0, q_pc);          // null gate target
                    seg_step <= 1'b0; gate_via <= 1'b0;
                  end else if (gsel[2]
                               ? ({16'd0, gsel[15:3], 3'd0} + 32'd7 > {16'd0, ldt_limit})
                               : ({16'd0, gsel[15:3], 3'd0} + 32'd7 > {16'd0, gdt_limit})) begin
                    start_fault(8'd13, 1'b1, {16'd0, gsel[15:3], 3'd0}, q_pc);
                    seg_step <= 1'b0; gate_via <= 1'b0;
                  end else begin
                    q_ljmp_sel <= gsel;
                    q_ljmp_off <= goff;
                    gate_via   <= 1'b1;
                    seg_step   <= 1'b0;      // re-read: now the TARGET CS descriptor
                  end
                end else begin
                  // REVIEW2_aug2 H-19: UNIMPLEMENTED system descriptor on a far
                  // transfer. Documented as unsupported CPU behaviour in
                  // docs/unsupported-isa.md §1, which the review asks for explicitly as
                  // the alternative to implementing these forms.
                  //
                  // The tag's low nibble carries the DESCRIPTOR TYPE, so a freeze names
                  // the form exactly instead of just "not a TSS":
                  //   0xD5 = TASK GATE   0xD2 = LDT   0xD1/0xD3 = 16-bit TSS
                  // (0xDC/0xD4 — the call gates — are HANDLED above, same-privilege.)
                  //
                  // HALT rather than #GP, deliberately: these are LEGAL descriptor
                  // types. Faulting would tell the guest its descriptor is malformed
                  // when the truth is that this CPU does not implement the transfer.
                  // A halt is an honest "unimplemented" and the tag says which.
                  state<=S_HALT; `ifdef VEN_DBG_CORE int_vec<={4'hD, desc_type(attr)}; `endif seg_step<=1'b0;
                end
              end else if (seg_load_fault(1'b1, 1'b0, q_ljmp_sel, attr, cpl_r)) begin
                // #GP/#NP on a far-jump CS load -> DELIVER (error code = selector).
                start_fault(seg_fault_vec(1'b1, 1'b0, q_ljmp_sel, attr), 1'b1,
                            {16'd0, q_ljmp_sel[15:3], 3'd0}, q_pc);
                seg_step<=1'b0;
              end else if (gate_via && (desc_dpl(attr) < cpl_r)) begin
                // CROSS-PRIVILEGE call gate (target CS.DPL < CPL). IA-32 requires a
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
                state<=S_HALT; `ifdef VEN_DBG_CORE int_vec<=8'hDB; `endif
                seg_step<=1'b0; gate_via<=1'b0;
              end else begin
                seg_sel  [SG_CS] <= q_ljmp_sel;
                seg_base [SG_CS] <= desc_base(desc);
                seg_limit[SG_CS] <= desc_limit(desc);
                seg_attr [SG_CS] <= attr;
                // CPL: a plain far jump takes CS.RPL. Through a CALL GATE the selector
                // RPL is NOT the new privilege (gates commonly carry RPL 0 while the
                // transfer is same-privilege) — using it would silently escalate to
                // ring 0. Same-privilege gate transfers KEEP the current CPL; the
                // cross-privilege case is rejected above.
                cpl_r    <= gate_via ? cpl_r : q_ljmp_sel[1:0];
                cs_d <= desc[54];   // D/B bit: 1 => 32-bit default operand/addr size
                eip<=q_ljmp_off; retire_valid<=1'b1; state<=S_PIPE; seg_step<=1'b0;
                gate_via <= 1'b0;
                // REVIEW1_Aug2 H-02: the target OFFSET was installed without ever being
                // checked against the destination CS limit, so a far jump/call could
                // transfer to an architecturally invalid EIP outside the code segment.
                // Overrides the commit above -- last assignment wins -- so nothing is
                // installed when the target is out of range. #GP(0), which is the code
                // for a control transfer past the segment limit (the selector is fine;
                // the offset is not).
                if ({1'b0, q_ljmp_off} > {1'b0, desc_limit(desc)}) begin
                  retire_valid <= 1'b0;
                  start_fault(8'd13, 1'b1, 32'd0, q_pc);
                end
              end
            end
          end
        end

        // -------------------------------------------------------------------
        // M9.5 — S_LCALL: REAL-MODE far CALL (0x9A). Two descending stack writes
        // (the bus driver supplies the address/data per beat): beat 0 pushes CS,
        // beat 1 pushes the return IP. On beat 1's ack, drop ESP by 2*w, load CS
        // (real-mode base=sel<<4), set EIP=off, and retire. (PM far CALL is gated
        // out in core_fetch_decode.svh -> HALT; this arm is real-mode only.)
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
              // DESCRIPTOR half: NOT DONE, and there is no smaller true step inside it.
              // The checks (present, code segment, DPL, conforming) need the read that
              // S_LJMP performs, which is after the push. Moving the read earlier is
              // the "validate, then push, then commit" reorder the finding asks for,
              // and it CANNOT be done for the ordinary case alone: S_LJMP's commit at
              // ~313 also serves CALL GATES, which re-enter this state with the gate's
              // embedded target selector (gate_via). A gate is precisely what decides
              // whether the transfer changes privilege, and therefore what the stack
              // does -- so validation and stack behaviour are coupled through the gate
              // pass. A reorder covering the non-gate case would still push before
              // validating on the gate path, which is the case DOS Quake's CWSDPMI
              // actually uses (task #47).
              //
              // This is the same test applied to H-11's decline: not "is it big" but
              // "is there a smaller step that is fully true". For C-06's selector half
              // there was one, and it landed. For this half there is not.
              if (far_sel_bad(q_ljmp_sel))
                start_fault(8'd13, 1'b1,
                            {16'd0, q_ljmp_sel} & 32'h0000_FFFC, q_pc);
              else begin seg_step <= 1'b0; state <= S_LJMP; end
            end
            else begin
              // R3: SP -= 2w bump moved to the gpr writeback driver (S_LCALL arm).
              seg_sel [SG_CS] <= q_ljmp_sel;
              seg_base[SG_CS] <= {12'd0, q_ljmp_sel, 4'd0};        // base = sel<<4
              seg_attr[SG_CS] <= 8'h9B;
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
              // REVIEW2_aug2 H-07: the POPPED CS is the least trustworthy selector in
              // the core -- it comes straight off the stack -- and it reached S_LJMP
              // with no bounds test at all.
              if (far_sel_bad(mem_rdata[15:0]))
                start_fault(8'd13, 1'b1,
                            {16'd0, mem_rdata[15:0]} & 32'h0000_FFFC, q_pc);
              else begin seg_step <= 1'b0; state <= S_LJMP; end
            end else begin
              logic [15:0] new_cs;
              new_cs = mem_rdata[15:0];               // popped CS (beat 1)
              seg_sel [SG_CS] <= new_cs;
              seg_base[SG_CS] <= {12'd0, new_cs, 4'd0};
              seg_attr[SG_CS] <= 8'h9B;
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
          if (mem_ack) begin
            if (!seg_step) seg_step <= 1'b1;
            else begin
              eip<=next_eip; retire_valid<=1'b1; state<=S_PIPE; seg_step<=1'b0;
            end
          end
        end

