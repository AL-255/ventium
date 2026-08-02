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
            // esi is beat 9 (TSS+0x40). Log the value the READ pulls from memory for the garbage pointer
            // 0x11b354 -> tells us if the TSS.esi MEMORY is corrupt (mem_rdata==0x11b354) vs a READ mis-load.
            if (tsw_step == 5'd9)
              $display("[VEN-TSWR] esi<-%08h from TSS_base=%08h untranslated_addr=%08h TRANSLATED_phys=%08h paging=%b @cs:eip=%04x:%08h",
                       mem_rdata, tsw_new_base, tsw_new_base + 32'h40,
                       mem_xlate(tsw_new_base + 32'h40, 1'b1), paging_on, seg_sel[SG_CS], eip);
`endif
            // After the last TSS field, load the LDTR's hidden base/limit (S_TSW_LDT)
            // BEFORE reloading the segments, so LDT-selector CS/SS/etc. resolve right.
            if (tsw_step == 5'd17) begin tsw_step <= 5'd0; state <= S_TSW_LDT; end
            else tsw_step <= tsw_step + 5'd1;
          end
        end

        // S_TSW_LDT: load the new task's LDTR hidden base/limit from the GDT LDT
        // descriptor named by tsw_new_ldt (2 word reads), so the subsequent S_TSW_SEG
        // can resolve LDT-selector segments (e.g. CWSDPMI's PM client CS). A null
        // LDTR (index 0) leaves ldt_base unchanged. Then proceed to the seg reload.
        S_TSW_LDT: begin
          if (mem_ack) begin
            if (!tsw_step[0]) begin tsw_seg_lo <= mem_rdata; tsw_step <= 5'd1; end
            else begin
              logic [63:0] desc;
              desc = {mem_rdata, tsw_seg_lo};
              // REVIEW2 M-02: track the LDTR selector across a task switch too, so the
              // SMM save map and any future SLDT see the LDTR the new task actually has.
              // A null LDT selector leaves the hidden cache alone (as before) but must
              // still record the selector, which is what the new task's TSS specifies.
              ldt_sel <= tsw_new_ldt;
              if (|tsw_new_ldt[15:3]) begin
                // ---- REVIEW1_Aug2 C-09: VALIDATE the incoming LDTR ------------------
                // The descriptor was installed unconditionally: no table-limit check on
                // the selector, and no type or Present check on what came back. A
                // malformed TSS therefore handed the new task an arbitrary LDT base and
                // limit, and every subsequent TI=1 selector resolved through it.
                // IA-32: the selector must be a GDT selector (TI=0) inside the table,
                // the descriptor must be an LDT (S=0, type 2), and it must be present.
                // #TS(selector) otherwise -- the task-switch error code.
                if (tsw_new_ldt[2] || !sel_in_table(tsw_new_ldt)
                    || desc_s(desc_attr(desc))
                    || (desc_attr(desc)[3:0] != 4'h2)
                    || !desc_present(desc_attr(desc))) begin
                  start_fault(8'd10, 1'b1,
                              {16'd0, tsw_new_ldt} & 32'h0000_FFFC, int_src_pc);
                end else begin
                ldt_base  <= desc_base(desc);
                ldt_limit <= desc_limit16(desc);
                tsw_step <= 5'd0; state <= S_TSW_SEG;
                end
              end else begin
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
          if (mem_ack) begin
            if (!tsw_step[0]) begin
              tsw_seg_lo <= mem_rdata; tsw_step <= tsw_step + 5'd1;
            end else begin
              logic [63:0] desc;
              logic [2:0]  sidx;
              logic [7:0]  sattr;
              desc  = {mem_rdata, tsw_seg_lo};
              sidx  = 3'(tsw_step[4:1]);     // 0..5 = CS,SS,DS,ES,FS,GS
              sattr = desc_attr(desc);
              seg_sel  [sidx] <= tsw_sel[sidx];
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
              tsw_seg_bad = 1'b0;
              if (!tsw_eflags[17]) begin
                if (!sel_in_table(tsw_sel[sidx]) && |tsw_sel[sidx][15:3])
                  tsw_seg_bad = 1'b1;
                else if (sidx == 3'(SG_CS))
                  tsw_seg_bad = (tsw_sel[SG_CS][15:2] == 14'd0)
                             || !desc_present(sattr) || !desc_s(sattr)
                             || !seg_is_code(sattr);
                else if (sidx == 3'(SG_SS))
                  tsw_seg_bad = (tsw_sel[SG_SS][15:2] == 14'd0)
                             || !desc_present(sattr) || !desc_s(sattr)
                             ||  seg_is_code(sattr) || !sattr[1]
                             || (tsw_sel[SG_SS][1:0]  != tsw_sel[SG_CS][1:0])
                             || (desc_dpl(sattr)      != tsw_sel[SG_CS][1:0]);
                else if (|tsw_sel[sidx][15:3])   // DS/ES/FS/GS, non-null only
                  tsw_seg_bad = !desc_present(sattr) || !desc_s(sattr)
                             || (seg_is_code(sattr) && !sattr[1]);  // execute-only code
              end
              if (tsw_eflags[17]) begin
                seg_base [sidx] <= {12'd0, tsw_sel[sidx], 4'd0};   // base = sel<<4
                seg_limit[sidx] <= 32'h0000_FFFF;
                seg_attr [sidx] <= (sidx == 3'(SG_CS)) ? 8'h9B : 8'h93;
                if (sidx == 3'(SG_CS)) begin
                  cpl_r <= 2'd3;                 // V86 runs at CPL3
                  cs_d  <= 1'b0;                 // V86 is 16-bit default
                  // REVIEW1_Aug2 M-02: and so is its stack.
                  if (sidx == 3'(SG_SS)) ss_b <= 1'b0;
                end
              end else if (tsw_seg_bad) begin
                // ---- REVIEW1_Aug2 C-09: VALIDATE each incoming segment descriptor ----
                // All six were installed with no selector, type, privilege or Present
                // check at all, so a malformed TSS gave the new task arbitrary segment
                // bases and limits at an arbitrary CPL. IA-32 raises #TS(selector) for
                // each of these on a task switch (see tsw_seg_bad, which states the
                // per-segment rules once rather than repeating them per arm).
                start_fault(8'd10, 1'b1,
                            {16'd0, tsw_sel[sidx]} & 32'h0000_FFFC, int_src_pc);
              end else begin
                seg_base [sidx] <= desc_base(desc);
                seg_limit[sidx] <= desc_limit(desc);
                seg_attr [sidx] <= sattr;
                if (sidx == 3'(SG_CS)) begin
                  cpl_r <= tsw_sel[SG_CS][1:0];  // CPL = new CS.RPL
                  cs_d  <= desc[54];              // D/B: 32-bit default op/addr size
                end
                // REVIEW_aug2 H-01: the incoming task's SS width. Exactly the cs_d
                // capture above, for the stack -- it was simply missing, so a task
                // switch into a 16-bit-stack task inherited the outgoing task's width.
                if (sidx == 3'(SG_SS)) ss_b <= desc[54];
              end
              if (tsw_step == 5'd11) begin tsw_step <= 5'd0; state <= S_TSW_BUSY; end
              else tsw_step <= tsw_step + 5'd1;
            end
          end
        end

        // S_TSW_BUSY: toggle the descriptor busy bits in the GDT, then COMMIT the
        // incoming task state + retire ONCE. For a JMP the OUTGOING TSS busy bit is
        // CLEARED (type B->9, beat 0) and the INCOMING one is SET (9->B, beat 1).
        // The busy bytes are written as a single byte (the access byte at descriptor
        // +5) via mem_wstrb in the bus arm. On the final beat: load the incoming
        // EIP/EFLAGS/GPRs/CR3, point TR at the new TSS, set CR0.TS=1 (every task
        // switch sets TS), and retire with q_pc = the JMP's PC (held from S_LJMP).
        // NT / the back-link are NOT touched (a JMP, not a CALL — see deferral).
        S_TSW_BUSY: begin
          if (mem_ack) begin
            if (tsw_step == 5'd0) begin
              tsw_step <= 5'd1;
            end else begin
              // ---- COMMIT the incoming task ----
              eip     <= tsw_eip;
              eflags  <= tsw_eflags;
              // R3: the incoming-task GPR-file load moved to the gpr writeback driver
              // (core_gpr_wb.svh, S_TSW_BUSY arm).
              creg3   <= tsw_cr3;                 // new task CR3 (0 here; paging off)
`ifdef VEN_DBG_WD
              $display("[VEN-CR3] TASKSW CR3 <- %08h (was %08h) @ cs:eip=%04x:%08h new_sel=%04x new_base=%08h (read cr3 @ %08h)",
                       tsw_cr3, creg3, seg_sel[SG_CS], eip, tsw_new_sel, tsw_new_base, tsw_new_base + 32'h1c);
              // [VEN-TSWIN] the INCOMING task's loaded EIP/EFLAGS/GPRs — compare vs golden (task should
              // start at 0x3f49, esi 0x758, and PROGRESS; a wrong entry EIP/flags => the 3-task deadlock).
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
