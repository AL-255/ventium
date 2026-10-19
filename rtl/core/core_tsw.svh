// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/core_tsw.svh — RAW case-arm text `included inside core.sv's always_ff
// `unique case (state)` (R2 modularization). NOT a standalone unit (no module/
// always wrapper); pasted verbatim at the original FSM site, netlist identical.
// Covers the M2S.4b hardware task-switch micro-sequence arms:
//   S_TSW_SAVE / S_TSW_READ / S_TSW_SEG / S_TSW_BUSY.
        // M2S.4b — HARDWARE TASK SWITCH (gated sys_mode; IA-32 SDM Vol.3 §7.3).
        // Reached from S_LJMP when a far JMP targets a 32-bit available/busy TSS.
        // The micro-sequence: SAVE outgoing state -> READ incoming state -> reload
        // incoming segment descriptors -> toggle the GDT busy bits -> COMMIT.
        // The TSS / GDT are linear structures addressed PHYSICALLY under the
        // M2S.1/.2 identity-map convention (paging is off in the ptask corpus), so
        // these accesses are NOT re-translated (excluded in the post-translate).
        // ===================================================================
        // S_TSW_SAVE: write the OUTGOING task state into the CURRENT TSS (tr_base),
        // one dword per beat at the documented 32-bit-TSS offsets. The store data +
        // address are driven by the bus arm; this block only advances the beat and,
        // after the last save, moves to read the incoming state.
        // FIX (Quake task #25): terminate at beat 15 (GS@0x5C), NOT beat 16 (LDTR@0x60).
        // IA-32 SDM Vol.3 7.3: a task switch SAVES only EIP/EFLAGS/GPR/ES..GS to the old
        // TSS — the LDTR field is STATIC (set once when the task is created) and is NOT
        // written by the CPU. The old code wrote LDTR:=0, corrupting the outgoing task's
        // LDT selector; on its next restore a bogus/stale LDT base makes its LDT-selector
        // segments (the extender's page-fault handler runs on ds/es=0xAF LDT selectors)
        // resolve to the wrong linear base -> wrong-memory writes -> state corruption.
        S_TSW_SAVE: begin
          if (mem_ack) begin
            if (tsw_step == 5'd15) begin tsw_step <= 5'd0; state <= S_TSW_READ; end
            else tsw_step <= tsw_step + 5'd1;
          end
        end

        // S_TSW_READ: read the INCOMING task state from the NEW TSS (tsw_new_base)
        // into the tsw_* holding regs. Beats: 0 CR3@0x1C, 1 EIP@0x20, 2 EFLAGS@0x24,
        // 3..10 GPR[0..7]@0x28..0x44, 11..16 ES/CS/SS/DS/FS/GS@0x48..0x5C, 17 LDTR
        // @0x60 (no LDT tracked in this RTL; the read result is discarded).
        S_TSW_READ: begin
          if (mem_ack) begin
            unique case (tsw_step)
              5'd0:  tsw_cr3    <= mem_rdata;
              5'd1:  tsw_eip    <= mem_rdata;
              5'd2:  tsw_eflags <= mem_rdata;
              5'd3,5'd4,5'd5,5'd6,5'd7,5'd8,5'd9,5'd10:
                     tsw_gpr[3'(tsw_step - 5'd3)] <= mem_rdata;
              5'd11: tsw_sel[SG_ES] <= mem_rdata[15:0];
              5'd12: tsw_sel[SG_CS] <= mem_rdata[15:0];
              5'd13: tsw_sel[SG_SS] <= mem_rdata[15:0];
              5'd14: tsw_sel[SG_DS] <= mem_rdata[15:0];
              5'd15: tsw_sel[SG_FS] <= mem_rdata[15:0];
              5'd16: tsw_sel[SG_GS] <= mem_rdata[15:0];
              5'd17: tsw_new_ldt <= mem_rdata[15:0];  // capture the new task's LDTR selector
              default: ;
            endcase
`ifdef VEN_DBG_WD
            // ESI is beat 9 (TSS+0x40); retain this generic task-switch trace.
            if (tsw_step == 5'd9)
              $display("[VEN-TSWR] esi<-%08h from TSS_base=%08h untranslated_addr=%08h TRANSLATED_phys=%08h paging=%b @cs:eip=%04x:%08h",
                       mem_rdata, tsw_new_base, tsw_new_base + 32'h40,
                       mem_xlate(tsw_new_base + 32'h40, 1'b1), paging_on, seg_sel[SG_CS], eip);
`endif
            // After the last TSS field, load the LDTR's hidden base/limit (S_TSW_LDT)
            // BEFORE reloading the segments, so LDT-selector CS/SS/etc. resolve right.
            // REVIEW_Aug3 C-06: PREVALIDATE the incoming LDTR selector here, before
            // S_TSW_LDT issues any descriptor read. A null LDTR skips the read
            // entirely (the invalid LDT is staged directly -- the old flow read
            // GDT[0] and discarded it, which under paging can #PF on an access the
            // architecture never makes); TI=1 or out-of-GDT-bounds is #TS ahead of
            // any memory access, not after it. The fault stamps q_pc (the far
            // JMP/CALL that started the switch), not int_src_pc -- this switch's
            // source is not interrupt delivery, so that register could carry stale
            // attribution.
            // F1 (found by the ptaskpg differential): evaluate against
            // mem_rdata[15:0] -- beat 17 IS the LDTR read. tsw_new_ldt is captured
            // nonblocking above and still holds the OLD value on this clock, so
            // testing it sent every non-null incoming LDTR down the null path.
            if (tsw_step == 5'd17) begin
              // R2-C02: null is TI=0/index-0 ONLY. A TI=1 "null" (0x0004) names
              // LDT entry 0 -- for the LDTR that is a TI violation -> #TS, not a
              // silent invalidation.
              if (is_null_selector(mem_rdata[15:0])) begin
                tsw_st_ldt_sel   <= mem_rdata[15:0];
                tsw_st_ldt_base  <= 32'd0;
                tsw_st_ldt_limit <= 16'd0;
                tsw_step <= 5'd0; state <= S_TSW_SEG;
              end else if (mem_rdata[2] || !sel_in_table(mem_rdata[15:0])) begin
                start_fault(8'd10, 1'b1,
                            {16'd0, mem_rdata[15:0]} & 32'h0000_FFFC, q_pc);
              end else begin
                tsw_step <= 5'd0; state <= S_TSW_LDT;
              end
            end
            else tsw_step <= tsw_step + 5'd1;
          end
        end

        // S_TSW_LDT: load the new task's LDTR hidden base/limit from the GDT LDT
        // descriptor named by tsw_new_ldt (2 word reads), so the subsequent S_TSW_SEG
        // can resolve LDT-selector segments (e.g. CWSDPMI's PM client CS).
        // REVIEW_Aug3 C-06: the SELECTOR half (null / TI / GDT bounds) is now
        // checked in S_TSW_READ before this state issues its first read -- so only
        // the DESCRIPTOR half remains here: the descriptor must be an LDT (S=0,
        // type 2) and Present, else #TS(selector). A #TS stamps q_pc, not
        // int_src_pc (the switch's source is a far JMP/CALL, not an interrupt).
        S_TSW_LDT: begin
          if (mem_ack) begin
            if (!tsw_step[0]) begin tsw_seg_lo <= mem_rdata; tsw_step <= 5'd1; end
            else begin
              logic [63:0] desc;
              desc = {mem_rdata, tsw_seg_lo};
              // REVIEW2 M-02: track the LDTR selector across a task switch too, so the
              // SMM save map and any future SLDT see the LDTR the new task actually has.
              tsw_st_ldt_sel <= tsw_new_ldt;   // C-05: staged, committed in S_TSW_BUSY
              if (desc_s(desc_attr(desc))
                  || (desc_type(desc_attr(desc)) != 4'h2)
                  || !desc_present(desc_attr(desc))) begin
                start_fault(8'd10, 1'b1,
                            {16'd0, tsw_new_ldt} & 32'h0000_FFFC, q_pc);
              end else begin
                tsw_st_ldt_base  <= desc_base(desc);
                tsw_st_ldt_limit <= desc_limit16(desc);
                tsw_step <= 5'd0; state <= S_TSW_SEG;
              end
            end
          end
        end

        // S_TSW_SEG: reload the hidden descriptor (base/limit/attr) of each of the
        // 6 incoming segment selectors from the GDT, exactly like a normal segment
        // load (two 4-byte reads per descriptor). beat = seg_idx*2 + half, segment
        // order CS,SS,DS,ES,FS,GS (the seg_* array order). A null selector (index 0)
        // reads GDT[0] = all-zeros -> a null (base/limit/attr 0) segment. The new
        // selectors are committed here; CPL = the new CS.RPL, cs_d = its D/B bit.
        S_TSW_SEG: begin
          // ---- REVIEW2_aug2 C-05 (fourth bullet): a V86 incoming task issues NO
          // descriptor reads at all. Its six "selectors" are real-mode PARAGRAPHS, so
          // the bus driver used them to index the GDT and the results were discarded.
          // The in-source note called that "harmless: DOS low memory is mapped, so the
          // overrun read can't fault" -- an assumption about the GUEST, not about the
          // architecture. gdt_base + (paragraph << 3) is an arbitrary linear address:
          // under paging it can #PF, and it is an address the architecture must never
          // touch, so the fault is both spurious and attributable to nothing.
          //
          // mem_req is suppressed for this case in core_bus_driver.svh; suppressing a
          // request while still WAITING for its acknowledgement is the C-01 deadlock,
          // so the beat cadence must advance on its own here. The two-beat-per-segment
          // structure is kept as-is so the staging logic below is untouched -- the V86
          // path simply runs it with no bus traffic and ignores tsw_seg_lo.
          // REVIEW_Aug3 C-06: an out-of-table selector faults BEFORE its read is
          // issued. tsw_seg_oob (module level) suppresses the bus request for
          // exactly this beat, so the fault fires here with no memory touched --
          // under paging the old flow could take a #PF ahead of the required #TS.
          // The fault stamps q_pc, not int_src_pc (this switch's source is a far
          // JMP/CALL, not interrupt delivery).
          if (tsw_seg_oob) begin
            start_fault(8'd10, 1'b1,
                        {16'd0, tsw_sel[3'(tsw_step[4:1])]} & 32'h0000_FFFC, q_pc);
          end else if (tsw_seg_null) begin
            // REVIEW1_Aug3 R2-C02: a NULL incoming selector performs NO descriptor
            // read (the bus arm suppresses it on this same predicate). CS/SS null
            // is #TS(selector); a null DS/ES/FS/GS stages an explicit NULL hidden
            // cache -- the old flow read GDT[0] and installed whatever hidden
            // state those bytes held.
            if ((tsw_step[4:1] == 4'd0) || (tsw_step[4:1] == 4'd1))   // CS / SS
              start_fault(8'd10, 1'b1,
                          selector_error(tsw_sel[3'(tsw_step[4:1])]), q_pc);
            else begin
              tsw_st_sel  [3'(tsw_step[4:1])] <= tsw_sel[3'(tsw_step[4:1])];
              tsw_st_base [3'(tsw_step[4:1])] <= 32'd0;
              tsw_st_limit[3'(tsw_step[4:1])] <= 32'd0;
              tsw_st_attr [3'(tsw_step[4:1])] <= 8'd0;
              tsw_st_b    [3'(tsw_step[4:1])] <= 1'b0;
              tsw_st_pml  [3'(tsw_step[4:1])] <= 1'b1;   // R2-H07: null = loaded-null
              if (tsw_step == 5'd10) begin tsw_step <= 5'd0; state <= S_TSW_BUSY; end
              else                   tsw_step <= tsw_step + 5'd2;
            end
          end else if (tsw_eflags[17] || mem_ack) begin
            if (!tsw_step[0]) begin
              tsw_seg_lo <= mem_rdata; tsw_step <= tsw_step + 5'd1;
            end else begin
              logic [63:0] desc;
              logic [2:0]  sidx;
              logic [7:0]  sattr;
              desc  = {mem_rdata, tsw_seg_lo};
              sidx  = 3'(tsw_step[4:1]);     // 0..5 = CS,SS,DS,ES,FS,GS
              sattr = desc_attr(desc);
              // REVIEW2_aug2 C-05: STAGED, not committed. This used to write
              // seg_sel[sidx] here -- before tsw_seg_bad is even computed below -- while
              // base/limit/attr went to the staging registers. A later #TS or #PF (on a
              // subsequent segment's descriptor read, say) therefore left the incoming
              // task's NEW SELECTOR paired with the OUTGOING task's hidden descriptor:
              // a segment register that names one thing and addresses another.
              tsw_st_sel[sidx] <= tsw_sel[sidx];
              // V86 incoming task (tsw_eflags[17]=VM): load FLAT real-mode segments
              // (base = sel<<4, limit 0xFFFF, CPL3, 16-bit) instead of decoding the V86
              // segment VALUES as GDT descriptors — they are real-mode paragraphs, not
              // selector indices. Mirrors the V86-return IRET tail (core_iret.svh:86-121)
              // and qemu switch_tss_ra's `if (new_eflags & VM_MASK) load_seg_vm(...)`.
              // (The bus driver still issues the GDT reads; mem_rdata is just ignored here
              //  — harmless: DOS low memory is mapped, so the overrun read can't fault.)
              // REVIEW1_Aug2 C-09: one statement of the per-segment task-switch rules.
              //   CS  must be a present CODE segment, inside its table, non-null.
              //   SS  must be a present WRITABLE DATA segment whose DPL and RPL equal
              //       the new CPL (CS.RPL).
              //   DS/ES/FS/GS may be NULL; if not null they must be inside the table,
              //       present, and readable (data, or a readable code segment).
              // V86 tasks (EFLAGS.VM) bypass all of it -- their selectors are real-mode
              // paragraphs, not descriptors, which is why this sits in the else branch.
              // The failure reasons are ranked like the pinned oracle's
              // tss_load_seg: S/type/privilege first (#TS), the Present bit
              // LAST (#NP). A combined-invalid descriptor therefore reports
              // #TS, and a presence-only failure reports #NP -- never one
              // collapsed vector for both classes.
              tsw_seg_ts = 1'b0;
              tsw_seg_np = 1'b0;
              if (!tsw_eflags[17]) begin
                // (REVIEW_Aug3 C-06: the table-bounds half is now prechecked at
                // beat 0 via tsw_seg_oob -- before the read is issued.)
                if (sidx == 3'(SG_CS)) begin
                  tsw_seg_ts = (tsw_sel[SG_CS][15:2] == 14'd0)
                            || !desc_s(sattr)
                            || !seg_is_code(sattr)
                            // REVIEW_Aug3 C-06: the privilege + offset rules were
                            // missing. The new CPL is CS.RPL: a NONCONFORMING code
                            // segment needs DPL == that RPL, a conforming one
                            // DPL <= RPL.
                            || (sattr[2] ? (desc_dpl(sattr) >  tsw_sel[SG_CS][1:0])
                                         : (desc_dpl(sattr) != tsw_sel[SG_CS][1:0]));
                  tsw_seg_np = !tsw_seg_ts && !desc_present(sattr);
                  // The target EIP (already read from the incoming TSS) must lie
                  // within the new CS limit. Ranks AFTER presence: the pinned
                  // oracle runs this check post-load, so a not-present CS
                  // reports #NP regardless of its limit field.
                  tsw_seg_ts = tsw_seg_ts
                            || (!tsw_seg_np && (tsw_eip > desc_limit(desc)));
                end
                else if (sidx == 3'(SG_SS)) begin
                  tsw_seg_ts = (tsw_sel[SG_SS][15:2] == 14'd0)
                            || !desc_s(sattr)
                            ||  seg_is_code(sattr) || !sattr[1]
                            || (tsw_sel[SG_SS][1:0]  != tsw_sel[SG_CS][1:0])
                            || (desc_dpl(sattr)      != tsw_sel[SG_CS][1:0]);
                  tsw_seg_np = !tsw_seg_ts && !desc_present(sattr);
                end
                else if (!is_null_selector(tsw_sel[sidx])) begin  // DS/ES/FS/GS, non-null only (R2-C02: TI=1 idx-0 validates like any entry)
                  tsw_seg_ts = !desc_s(sattr)
                            || (seg_is_code(sattr) && !sattr[1])  // execute-only code
                            // REVIEW_Aug3 C-06: the DPL rule was missing. A data
                            // segment or a NONCONFORMING (readable) code segment
                            // must be accessible at the new privilege:
                            // DPL >= max(new CPL, the selector's RPL). A conforming
                            // code segment is exempt by definition.
                            || (!(seg_is_code(sattr) && sattr[2])
                                && ((desc_dpl(sattr) < tsw_sel[SG_CS][1:0])
                                 || (desc_dpl(sattr) < tsw_sel[sidx][1:0])));
                  tsw_seg_np = !tsw_seg_ts && !desc_present(sattr);
                end
              end
              if (tsw_eflags[17]) begin
                // REVIEW1_Aug2 C-09: STAGED, not installed (see the commit in
                // S_TSW_BUSY). V86 selectors are paragraphs, so base = sel<<4.
                tsw_st_base [sidx] <= {12'd0, tsw_sel[sidx], 4'd0};
                tsw_st_limit[sidx] <= 32'h0000_FFFF;
                tsw_st_attr [sidx] <= (sidx == 3'(SG_CS)) ? 8'h9B : 8'h93;
                tsw_st_b    [sidx] <= 1'b0;            // C-06: V86 is 16-bit
                tsw_st_pml  [sidx] <= 1'b0;            // R2-H07: V86-style, not a PM load
                if (sidx == 3'(SG_CS)) begin
                  tsw_st_cpl <= 2'd3;            // V86 runs at CPL3
                  tsw_st_cs_d<= 1'b0;            // V86 is 16-bit default
                end
                // REVIEW1_Aug2 M-02: a V86 stack is 16-bit.
                if (sidx == 3'(SG_SS)) tsw_st_ss_b <= 1'b0;
              end else if (tsw_seg_ts || tsw_seg_np) begin
                // ---- REVIEW1_Aug2 C-09: VALIDATE each incoming segment descriptor ----
                // All six were installed with no selector, type, privilege or Present
                // check at all, so a malformed TSS gave the new task arbitrary segment
                // bases and limits at an arbitrary CPL. A type/privilege failure is
                // #TS(selector); a presence-only failure is #NP(selector) -- the
                // per-segment rules above rank the reasons the way the pinned
                // oracle's tss_load_seg does (S/type/privilege before P).
                // REVIEW_Aug3 C-06: stamp q_pc (the far JMP/CALL), not int_src_pc.
                start_fault(tsw_seg_np ? 8'd11 : 8'd10, 1'b1,
                            {16'd0, tsw_sel[sidx]} & 32'h0000_FFFC, q_pc);
              end else begin
                // REVIEW1_Aug2 C-09: STAGED. Nothing architectural moves until every
                // descriptor has been read and validated.
                tsw_st_base [sidx] <= desc_base(desc);
                tsw_st_limit[sidx] <= desc_limit(desc);
                tsw_st_attr [sidx] <= sattr;
                tsw_st_pml  [sidx] <= 1'b1;   // R2-H07: validated PM descriptor load
                // REVIEW_Aug3 C-06: stage the D/B bit for EVERY segment -- only CS.D
                // and SS.B were carried, so a 16-bit non-SS expand-down segment kept
                // the previous task's upper bound (seg_b[]) across the switch.
                tsw_st_b    [sidx] <= desc[54];
                if (sidx == 3'(SG_CS)) begin
                  tsw_st_cpl  <= tsw_sel[SG_CS][1:0];  // CPL = new CS.RPL
                  tsw_st_cs_d <= desc[54];             // D/B: 32-bit default op/addr
                end
                // REVIEW_aug2 H-01: the incoming task's SS width.
                if (sidx == 3'(SG_SS)) tsw_st_ss_b <= desc[54];
              end
              if (tsw_step == 5'd11) begin tsw_step <= 5'd0; state <= S_TSW_BUSY; end
              else tsw_step <= tsw_step + 5'd1;
            end
          end
        end

        // S_TSW_BUSY: toggle the descriptor busy bits in the GDT, then COMMIT the
        // incoming task state + retire ONCE. For a JMP the OUTGOING TSS busy bit is
        // CLEARED (B->9) and the INCOMING one is SET (9->B) -- beat order per the
        // REVIEW2_aug2 C-05 note in the bus arm. For an NT return the incoming TSS
        // is already busy and stays so. REVIEW_Aug3 C-04: for a CALL (tsw_call) the
        // second beat instead writes the outgoing TR selector into the incoming
        // TSS back-link, the outgoing descriptor STAYS busy, and the commit sets
        // NT in the incoming EFLAGS image -- the nested-task semantics that let an
        // NT-IRET return to the caller.
        // The busy bytes are written as a single byte (the access byte at descriptor
        // +5) via mem_wstrb in the bus arm. On the final beat: load the incoming
        // EIP/EFLAGS/GPRs/CR3, point TR at the new TSS, set CR0.TS=1 (every task
        // switch sets TS), and retire with q_pc = the JMP's PC (held from S_LJMP).
        S_TSW_BUSY: begin
          if (mem_ack) begin
            if (tsw_step == 5'd0) begin
              tsw_step <= 5'd1;
            end else begin
              // ---- COMMIT the incoming task ----
              // REVIEW1_Aug2 C-09: the SIX SEGMENTS land here too, from the staging
              // written during S_TSW_SEG. Before this they were installed one at a
              // time as each descriptor was read, so a rejected descriptor -- or a
              // page fault on its read -- left the task half switched. Now the whole
              // context moves on one clock.
              for (int t = 0; t < NUM_SEG; t++) begin
                seg_sel  [t] <= tsw_st_sel  [t];   // C-05: selector moves with the rest
                seg_base [t] <= tsw_st_base [t];
                seg_limit[t] <= tsw_st_limit[t];
                seg_attr [t] <= tsw_st_attr [t];
                seg_b    [t] <= tsw_st_b    [t];   // C-06: D/B for every segment
                seg_pm_loaded[t] <= tsw_st_pml[t]; // R2-H07: staged loaded-bit
              end
              // REVIEW2_aug2 C-05: LDTR lands HERE now, with the segments it governs,
              // instead of back in S_TSW_LDT before any of them had been read.
              ldt_sel   <= tsw_st_ldt_sel;
              ldt_base  <= tsw_st_ldt_base;
              ldt_limit <= tsw_st_ldt_limit;
              cpl_r   <= tsw_st_cpl;
              cs_d    <= tsw_st_cs_d;
              ss_b    <= tsw_st_ss_b;
              eip     <= tsw_eip;
              // REVIEW_Aug3 C-04: a CALL task switch sets NT in the INCOMING task's
              // EFLAGS image (the back-link beat above is what makes that NT
              // meaningful -- an NT-IRET from the nested task returns here). JMP
              // and NT-IRET forms leave the image alone.
              eflags  <= tsw_eflags | (tsw_call ? 32'h0000_4000 : 32'd0);
              tsw_call<= 1'b0;
              // R3: the incoming-task GPR-file load moved to the gpr writeback driver
              // (core_gpr_wb.svh, S_TSW_BUSY arm).
              creg3   <= tsw_cr3;                 // new task CR3 (0 here; paging off)
`ifdef VEN_DBG_WD
              $display("[VEN-CR3] TASKSW CR3 <- %08h (was %08h) @ cs:eip=%04x:%08h new_sel=%04x new_base=%08h (read cr3 @ %08h)",
                       tsw_cr3, creg3, seg_sel[SG_CS], eip, tsw_new_sel, tsw_new_base, tsw_new_base + 32'h1c);
              // Incoming task state trace; no guest-specific expected values are encoded.
              $display("[VEN-TSWIN] -> sel=%04x IN eip=%08h efl=%08h esi=%08h edi=%08h esp=%08h eax=%08h",
                       tsw_new_sel, tsw_eip, tsw_eflags, tsw_gpr[R_ESI], tsw_gpr[R_EDI], tsw_gpr[R_ESP], tsw_gpr[R_EAX]);
`endif
              creg0   <= creg0 | 32'h0000_0008;   // CR0.TS = 1 on every task switch
              // new TR <- the incoming TSS descriptor (now busy).
              tr_sel  <= tsw_new_sel;
              tr_base <= tsw_new_base;
              tr_limit<= tsw_new_limit;
              tr_attr <= tsw_new_attr;
              tr_valid<= 1'b1;
              tsw_step<= 5'd0;
              // retire the task switch: q_pc still holds the JMP's PC (the golden
              // stamps the switch record at the ljmp). The post-state row is the
              // INCOMING task context (reloaded GPRs/segs/EIP + CR0.TS + new EFLAGS).
              retire_valid <= 1'b1;
              state        <= S_PIPE;
            end
          end
        end
