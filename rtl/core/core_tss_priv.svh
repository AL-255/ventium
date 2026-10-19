// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/core_tss_priv.svh — RAW case-arm text `included inside core.sv's
// always_ff `unique case (state)` (R2 modularization). NOT a standalone unit
// (no module/always wrapper); pasted verbatim at the original FSM site, netlist
// identical. Covers the LTR + cross-privilege stack/SS-load arms:
//   S_LTR (M2S.4 load TR), S_INT_TSS (TSS.ssN:espN), S_INT_SS (new SS desc).
        // S_LTR (M2S.4): LTR r16 — read the GDT TSS descriptor named by the
        // selector in gpr_o[q_src_reg], load the TR hidden cache (base/limit/sel),
        // and retire. REVIEW_Aug3 H-11b: the architectural busy-bit write (type
        // 9 -> B at descriptor+5) is now performed before TR commits, so software
        // reading the descriptor sees the task in use and a second LTR on the same
        // selector faults (#GP: type 0xB is no longer an available TSS). LLDT
        // reuses the two descriptor-read beats only; a null LLDT performs no read.
        S_LTR: begin
          // REVIEW_Aug3 H-11b (null LLDT half): a null LLDT names no descriptor,
          // so the bus arm suppresses the request (lldt_null_q) and the invalid
          // LDTR commits directly -- GDT[0] on an unmapped page can no longer
          // raise a #PF for an access the architecture never makes.
          if (lldt_null_q) begin
            ldt_sel     <= 16'd0;
            ldt_base    <= 32'd0;
            ldt_limit   <= 16'd0;
            lldt_null_q <= 1'b0;
            seg_step    <= 1'b0;
            complete_reference_rf();
            eip<=next_eip; retire_valid<=1'b1; state<=S_PIPE;
          end else if (mem_ack && ltr_busy_q) begin
            // REVIEW_Aug3 H-11b (busy half, beat 3): the busy byte has been
            // written to the GDT; only NOW does TR commit. A fault on that write
            // left TR at its old value -- the correct partial state for a
            // rejected LTR.
            tr_sel     <= ltr_sel_q;
            tr_base    <= ltr_base_q;
            tr_limit   <= ltr_limit_q;
            // tr_attr mirrors the descriptor AS IT NOW STANDS in the GDT -- the
            // busy write just made it 0xB, and the NT-return precondition
            // (REVIEW_Aug3 H-01) and the task-switch busy-clear both read that.
            tr_attr    <= ltr_attr_q | 8'h02;
            tr_valid   <= 1'b1;
            ltr_busy_q <= 1'b0;
            seg_step   <= 1'b0;
            complete_reference_rf();
            eip<=next_eip; retire_valid<=1'b1; state<=S_PIPE;
          end else if (mem_ack) begin
            if (!seg_step) begin gdt_lo<=mem_rdata; seg_step<=1'b1; end
            else begin
              logic [63:0] desc; logic [7:0] dattr; logic [15:0] dsel;
              logic bad_sel, bad_type, not_present;
              desc  = {mem_rdata, gdt_lo};
              dattr = desc_attr(desc);
              dsel  = gpr_o[q_src_reg][15:0];
              // REVIEW2 H-04: LTR/LLDT committed the descriptor with NO validation at
              // all -- malformed task state was installed and then USED FOR MEMORY
              // ADDRESSING (tr_base feeds S_INT_TSS). The required faults:
              //   * selector must be non-null and in the GDT (TI=0), and its index must
              //     lie within the GDT limit          -> #GP(sel & 0xFFFC)
              //   * type must be the right SYSTEM type: LTR needs an AVAILABLE 32-bit
              //     TSS (0x9); a BUSY one (0xB) is #GP, which is also what makes a
              //     re-LTR of a running task fault. LLDT needs an LDT (0x2).
              //   * descriptor must be Present                    -> #NP(sel & 0xFFFC)
              // The error code for a descriptor-sourced fault is the selector with the
              // low two bits cleared (EXT=0, IDT=0 -- this is a GDT reference).
              // (REVIEW_Aug3 H-11b: the null-LLDT terms that used to guard these are
              // gone -- the null case is committed above before any read.)
              bad_sel     = (dsel[15:3] == 13'd0) || dsel[2]
                         || ({16'd0, dsel[15:3], 3'd0} + 32'd7 > {16'd0, gdt_limit});
              bad_type    = dattr[4]   // S must be 0 (system descriptor)
                         || (q_sysop==SYS_LLDT ? (dattr[3:0] != 4'h2)
                                               : (dattr[3:0] != 4'h9));
              not_present = !dattr[7];
              if (bad_sel || bad_type) begin
                seg_step <= 1'b0;
                start_fault(8'd13, 1'b1, {16'd0, dsel[15:2], 2'b00}, q_pc);
              end else if (not_present) begin
                seg_step <= 1'b0;
                start_fault(8'd11, 1'b1, {16'd0, dsel[15:2], 2'b00}, q_pc);
              end else begin
              if (q_sysop==SYS_LLDT) begin
                // LLDT: load the LDTR hidden base/limit from the GDT LDT descriptor.
                // REVIEW2 M-02: also keep the SELECTOR. It was being discarded here,
                // so the LDTR's architectural half did not exist anywhere in the core.
                ldt_sel   <= dsel;
                ldt_base  <= desc_base(desc);
                ldt_limit <= desc_limit16(desc);
                seg_step <= 1'b0;
                complete_reference_rf();
                eip<=next_eip; retire_valid<=1'b1; state<=S_PIPE;
              end else begin
                // REVIEW_Aug3 H-11b: do NOT commit TR yet. Stage the validated
                // descriptor and run the busy-bit write first (the bus arm's
                // ltr_busy_q variant); the commit happens when that write lands.
                ltr_sel_q   <= dsel;
                ltr_base_q  <= desc_base(desc);
                ltr_limit_q <= desc_limit(desc);
                ltr_attr_q  <= dattr;
                ltr_busy_q  <= 1'b1;
                seg_step    <= 1'b0;
              end
              end
            end
          end
        end

        // S_INT_TSS (M2S.4 cross-priv): read TSS.ssN:espN (N = int_new_cpl). The
        // 32-bit TSS stores ESPn then SSn contiguously at 0x04 + 8*N; beat 0 reads
        // ESPn, beat 1 reads SSn. Then read the new SS descriptor (S_INT_SS).
        // ---- REVIEW1_Aug2 M-03: TSS I/O-permission bitmap -----------------------
        // Beat 0 reads the I/O map base (TSS+0x66, a 16-bit field). Beat 1 reads the
        // dword containing the bitmap byte for this port and tests its bit. A SET bit
        // denies the port; a clear bit allows it.
        //
        // Denials, all #GP(0), and all architectural:
        //   * the TSS cannot hold a map base at all (tr_limit < 0x67);
        //   * the map base points at or past the TSS limit (no bitmap present);
        //   * the byte covering this port lies outside the TSS limit -- IA-32 treats
        //     bits beyond the bitmap as SET, i.e. denied;
        //   * the bit is set.
        S_NTRET_RD: begin
          if (mem_ack) begin
            // REVIEW_Aug3 H-01: validate the back-link BEFORE it indexes the GDT.
            // IA-32 requires a non-null, TI=0, in-GDT-bounds back-link selector --
            // #TS(back-link) otherwise. This used to hand any popped word to the
            // generic S_LJMP path, whose dispatch-time far_sel_bad check this entry
            // bypasses, so an LDT or out-of-range back-link became a descriptor
            // address (and a possible #PF) ahead of the required #TS.
            if ((mem_rdata[15:3] == 13'd0) || mem_rdata[2]
                || !sel_in_table(mem_rdata[15:0]))
              start_fault(8'd10, 1'b1,
                          {16'd0, mem_rdata[15:0]} & 32'h0000_FFFC, int_src_pc);
            else begin
              q_ljmp_sel <= mem_rdata[15:0];
              q_ljmp_off <= 32'd0;
              seg_step   <= 1'b0;
              state      <= S_LJMP;
            end
          end
        end

        S_IOPERM: begin
          if (mem_ack) begin
            if (int_step == 4'd0) begin
              // REVIEW2_aug2 C-07(a): the I/O-map base lives at TSS offset 0x66, and
              // the bus arm addresses tr_base+0x64 -- so it is the HIGH half of the
              // returned dword. Taking [15:0] read offset 0x64-0x65, the preceding
              // trap/reserved field, which is normally ZERO: the map base then looked
              // like 0, and every permission read was directed into unrelated TSS
              // fields near the top of the descriptor.
              ioperm_base <= mem_rdata[31:16];
              // REVIEW2_aug2 M-02: a TSS limit is INCLUSIVE, so base == limit still
              // names a byte that exists and legitimately covers ports 0-7. Rejecting
              // `>=` denied a legal one-byte bitmap. The per-access width check below
              // decides whether the bytes actually needed exist.
              if ((tr_limit < 32'h67) || ({16'd0, mem_rdata[31:16]} > tr_limit))
                start_fault(8'd13, 1'b1, 32'd0, q_pc);
              else int_step <= 4'd1;
            end else begin
              // REVIEW2_aug2 C-07(b)+(c). Two separate bugs lived here.
              //
              // (b) the bit index was
              //         port[2:0] + (port[1:0] << 3)
              //     which yields 0, 9, 18, 27, 4, 13, 22, 31 for ports 0..7 -- for most
              //     ports a bit from a DIFFERENT byte of the returned dword. The read is
              //     a byte-addressed dword at tr_base+base+(port>>3), so bit j of it
              //     covers port (port & ~7) + j; the wanted bit is simply port[2:0].
              //
              // (c) only the FIRST port was checked, while word and dword IN/OUT cover
              //     2 and 4 consecutive ports. A permitted first port let the rest
              //     through unchecked -- a direct privilege bypass.
              //
              // All q_io_w ports fit in the SAME read: the dword covers 32 consecutive
              // ports starting at (port & ~7), and port[2:0]+3 <= 10 < 32. So no extra
              // beat is needed; only the LIMIT check has to account for the last byte.
              // REVIEW_Aug3 M-01: an access whose extent wraps past port 0xFFFF is
              // denied outright (ioperm_wrap) -- the 16-bit ioperm_last used to wrap,
              // passing the limit check vacuously and reading ADJACENT bitmap memory.
              if (ioperm_wrap
                  || ({16'd0, ioperm_base} + {19'd0, ioperm_last[15:3]}) > tr_limit)
                start_fault(8'd13, 1'b1, 32'd0, q_pc);   // past the bitmap => denied
              else if (|(io_perm_mask & mem_rdata))
                start_fault(8'd13, 1'b1, 32'd0, q_pc);   // any covered bit SET => denied
              else begin
                int_step <= 4'd0;
                state    <= ioperm_ret;                  // permitted: carry on
              end
            end
          end
        end

        S_INT_TSS: begin
          if (mem_ack) begin
            if (int_step == 4'd0) begin
              int_new_esp <= mem_rdata; int_step <= 4'd1;
`ifdef VEN_DBG_WD
              // Generic TSS stack-pointer read trace for cross-privilege delivery.
              $display("[VEN-ESP0] TSS.ESPn<=%08h from addr=%08h tr_base=%08h new_cpl=%0d vec=%0d @cs:eip=%04x:%08h",
                       mem_rdata, mem_addr, tr_base, int_new_cpl, int_vec, seg_sel[SG_CS], eip);
`endif
            end else begin
              int_new_ss  <= mem_rdata[15:0];
              int_step    <= 4'd0;
              // ---- REVIEW2_aug2 C-03 (second bullet): bound the TSS-supplied SS
              // selector against its table BEFORE issuing the descriptor read, the
              // same precheck the outer-IRET SS gets (core_iret.svh:215) and for the
              // same reason: sel_in_table() is what stops an out-of-table selector
              // from being turned into an ADDRESS. Without it, S_INT_SS reads eight
              // bytes from gdt_base + sel*8 past the end of the GDT, then validates
              // whatever those bytes happen to be -- so the descriptor test cannot
              // reject it, because the test is applied to memory that is not a
              // descriptor. #TS(sel): the selector came from the TSS.
`ifdef VEN_C03_PROBE
              $display("[C03-TSSSS] TSS.ssN=%04h in_table=%0b", mem_rdata[15:0],
                       sel_in_table(mem_rdata[15:0]));
`endif
              if (!sel_in_table(mem_rdata[15:0]))
                start_fault(8'd10, 1'b1,
                            {16'd0, mem_rdata[15:0]} & 32'h0000_FFFC, int_src_pc);
              else
                state     <= S_INT_SS;
            end
          end
        end

        // S_INT_SS (M2S.4 cross-priv): read + load the new SS descriptor named by
        // TSS.ssN, then push the larger frame (S_INT_PUSH). The new SS base feeds
        // the descending push (flat 0 in the pcpl corpus).
        // DONE-PARTIAL (documented follow-on): the new SS is loaded UNCONDITIONALLY.
        // IA-32 6.12.1.2 validates the loaded SS — SS.DPL == target CPL, SS.RPL ==
        // target CPL, a WRITABLE data segment, and Present — raising #TS(ssN)/#GP
        // otherwise (and S_INT_TSS would first bound the ssN:espN read against the
        // TSS limit + require tr_valid, raising #TS). The pcpl corpus uses a
        // well-formed SS0 (0x10, DPL0, present, writable, within the 104-byte TSS),
        // so none of these negative paths is exercised and there is NO oracle to
        // differentially validate the #TS/#GP delivery. Wiring an unvalidated fault
        // here would be unverified dead logic; deferred until a bad-SS / truncated-
        // TSS corpus test exists (see the tr_valid/tr_limit lint-sink note).
        S_INT_SS: begin
          if (mem_ack) begin
            if (int_step == 4'd0) begin
              int_lo <= mem_rdata; int_step <= 4'd1;
            end else begin
              logic [63:0] desc;
              logic [7:0]  ss_int_a;
              logic        ss_int_bad;
              desc = {mem_rdata, int_lo};
              ss_int_a   = desc_attr(desc);
              // REVIEW2_aug2 C-03 (staging, CPL half): compare against int_new_cpl,
              // NOT cpl_r. S_INT_CS used to commit the new CPL before chaining here,
              // so cpl_r happened to hold it; it now defers that commit to this state
              // so a fault raised in between is still classified at the ORIGINAL
              // privilege. int_new_cpl is the staged target CPL and has been correct
              // all along -- tss_stk_off already addressed the TSS with it.
              ss_int_bad = (int_new_ss[15:2] == 14'd0)          // null selector
                        || !ss_int_a[4] || ss_int_a[3] || !ss_int_a[1]  // not writable DATA
                        || (int_new_ss[1:0] != int_new_cpl)     // RPL must equal the new CPL
                        || (ss_int_a[6:5]   != int_new_cpl);    // DPL must equal the new CPL
              // ---- REVIEW1_Aug2 C-07: VALIDATE the TSS-supplied SS before installing.
              // This loaded selector/base/limit/attr unconditionally -- no table limit,
              // RPL, DPL, writable-data, type or Present check -- so a malformed TSS
              // handed the handler an arbitrary stack segment. IA-32 (interrupt with a
              // stack switch) requires:
              //   * a non-null SS selector                       -> #TS(0) otherwise
              //   * SS.RPL == the target CS DPL (the new CPL)    -> #TS(sel)
              //   * SS.DPL == the new CPL                        -> #TS(sel)
              //   * a WRITABLE DATA segment (S=1, type[3]=0, W)  -> #TS(sel)
              //   * present                                      -> #SS(sel)
              // Checked BEFORE any commit, exactly as the outer-IRET SS is.
              //
              // ---- REVIEW2_aug2 C-03 (third bullet): the comment above was FALSE.
              // seg_sel/seg_base/seg_limit[SS] were written HERE, above this check,
              // while seg_attr and ss_b were written below it. A rejected SS therefore
              // left SS half-installed: the selector, base and limit named the REJECTED
              // descriptor while the attributes and B-bit still described the OLD stack.
              // Every later consumer that pairs them -- the #TS/#SS frame push itself,
              // the expand-down limit test (which reads attr AND limit), and any handler
              // that reports SS -- then saw a selector and a hidden cache that describe
              // two different segments. All five writes now sit on the accepted path, so
              // SS is either fully replaced or wholly untouched.
              if (ss_int_bad || !ss_int_a[7]) begin
                start_fault(ss_int_a[7] ? 8'd10 : 8'd12, 1'b1,
                            {16'd0, int_new_ss} & 32'h0000_FFFC, int_src_pc);
              end else begin
                // REVIEW1_Aug3 R2-C04: STAGE, do not install. The new SS hidden
                // state and CPL used to commit HERE, before S_INT_PUSH's pageable
                // frame writes -- so a #PF on any frame word observed the new
                // SS/CPL with the old CS/EIP and a partially written frame. The
                // validated descriptor parks in int_ss_*; S_INT_PROBE validates
                // the frame's page plan and captures the translations; only
                // then does the context commit.
                int_ss_base   <= desc_base(desc);
                int_ss_limit  <= desc_limit(desc);
                int_ss_attr   <= desc_attr(desc);
                // REVIEW_aug2 H-01: capture SS.B here too (staged now).
                int_ss_b      <= desc[54];
                // The frame-slot plan, latched once: S_INT_PUSH addresses by
                // this formula (frm_slot_off). A call-gate frame is 4 header
                // slots (SS, ESP/SP, CS, EIP/IP) + cg_pcount parameter slots,
                // in GATE-WIDTH units (QEMU helper_lcall_protected: push size
                // follows the gate's type, the wrap mask the NEW stack's B).
                if (from_v86) begin
                  int_frm_nslots <= int_has_err ? 6'd10 : 6'd9;
                  int_frm_wide   <= 1'b1;
                end else if (cg_xpl) begin
                  int_frm_nslots <= 6'd4 + {1'b0, cg_pcount};
                  int_frm_wide   <= cg_wide;
                end else begin
                  int_frm_nslots <= int_has_err ? 6'd6 : 6'd5;
                  int_frm_wide   <= !int_frm16;
                end
                // Build the page plan sequentially.  This state occurs before
                // S_INT_PROBE and before the staged SS/CPL context commits, so
                // its latency is architecturally invisible while removing the
                // old 36-slot combinational cone from normal timing paths.
                frame_plan_start <= 1'b1;
                frm_pg_i       <= 3'd0;
                frm_pg_markd   <= 1'b0;
                int_step       <= 4'd0;
                state          <= S_INT_PLAN_ARM;
              end
            end
          end
        end

        // The start pulse is registered.  Keep one arm state between it and
        // completion observation so a held ``done`` from a prior frame cannot
        // be mistaken for this plan before the planner consumes start.
        S_INT_PLAN_ARM: state <= S_INT_PLAN;

        S_INT_PLAN: begin
          if (frame_plan_done) begin
            for (int i = 0; i < 4; i++) begin
              frm_pg_val[i]  <= frame_plan_val[i];
              frm_pg_lin [i] <= frame_plan_lin[i];
              frm_pg_addr[i] <= frame_plan_addr[i];
              frm_pg_mid [i] <= frame_plan_mid[i];
            end
            frm_pg_n     <= {2'd0, frame_plan_val[0]} + {2'd0, frame_plan_val[1]}
                         + {2'd0, frame_plan_val[2]} + {2'd0, frame_plan_val[3]};
            frm_pg_i     <= 3'd0;
            frm_pg_markd <= 1'b0;
            state        <= S_INT_PROBE;
          end
        end

        // S_INT_PROBE: validate the frame's PAGE PLAN before the staged stack
        // context commits. The bus arm issues NO transaction (bd_req stays 0):
        // the TLB lookup keys off cur_lin and the walk divert off xlate_miss,
        // so a missing page is walked in and a protection failure raises #PF
        // with the OLD context fully intact (the staged SS/CPL never became
        // visible, no frame byte was written).
        //
        // The probe walks the plan's distinct pages in push order, one beat
        // per page -- not per slot: every page the wrapped layout can touch
        // is in the plan, so no frame byte can land on an unprobed page. The
        // slot-start pages are probed AT the slot's start address (CR2 = the
        // faulting push, silicon's attribution); a lo page at its base.
        //
        // Two phases. VALIDATION (frm_pg_markd=0) only proves presence +
        // write permission: the dirty term is masked out of xlate_miss, so a
        // clean (D=0) entry is NOT walked here -- a fault on a later plan
        // page restarts the delivery with the old context and silicon's D
        // bits untouched (the probe is not a write). Each page's physical
        // frame and D bit are captured. If any validated page was clean, the
        // D-MARK phase (frm_pg_markd=1) rewalks the plan once: the dirty
        // term is live again, each clean entry is walked and D-set while the
        // OLD context is still installed, so the post-commit pushes can
        // neither fault nor walk. S_INT_PUSH then translates through the
        // captured frames (frm_pg_hit), never the DTLB -- a direct-mapped
        // eviction between probe and push cannot resurrect a walk.
        S_INT_PROBE: begin
          if (!xlate_miss && !perm_fault) begin
            logic [19:0] lkpg;
            logic        lkdirty;
`ifdef VEN_FE_PIPE
            lkpg    = fe_dtlb_phys;
            lkdirty = fe_dtlb_dirty;
`else
            lkpg    = dtlb_lk_phys[31:12];
            lkdirty = dtlb_lk_dirty;
`endif
            if (!frm_pg_markd) begin
              // validation: capture this page's mapping (D as it stands)
              frm_pg_phys [frm_pg_i[1:0]] <= lkpg;
              frm_pg_dirty[frm_pg_i[1:0]] <= lkdirty;
            end
            if (frm_pg_i != frm_pg_n - 3'd1) begin
              frm_pg_i <= frm_pg_i + 3'd1;
            end else if (!frm_pg_markd &&
                         !(lkdirty &&
                           (((frm_pg_dirty | (4'b0001 << frm_pg_i[1:0])) & frm_pg_val)
                             == frm_pg_val))) begin
              // a validated page is clean: run the D-mark phase
              frm_pg_i     <= 3'd0;
              frm_pg_markd <= 1'b1;
            end else begin
              // Every frame page is now proven present+writable+dirty (or the
              // D-mark phase just made it so).
              // With parameters to copy, the staged context must NOT commit
              // yet -- the params live on the OLD stack, whose SS this commit
              // replaces. Read them first; S_CG_PRD runs this same commit on
              // its last beat. (A faulting param read is then delivered with
              // the old context fully intact and zero frame bytes written --
              // exactly like a faulting probe page.)
              if (cg_xpl && (cg_pcount != 5'd0)) begin
                cg_beat      <= 6'd0;
                frm_pg_i     <= 3'd0;
                frm_pg_markd <= 1'b0;
                int_step     <= 4'd0;
                state        <= S_CG_PRD;
              end else begin
              // Commit the staged stack context and build the frame. The
              // pushes cannot fault -- every page's mapping is captured in
              // the plan (present, writable, dirty), and a straddling beat is
              // split by the fragment engine.
              seg_sel  [SG_SS] <= int_new_ss;
              seg_base [SG_SS] <= int_ss_base;
              seg_limit[SG_SS] <= int_ss_limit;
              seg_attr [SG_SS] <= int_ss_attr;
              seg_pm_loaded[SG_SS] <= 1'b1;   // R2-H07: validated (staged) PM load
              // (was the S_INT_SS commit, REVIEW2_aug2 C-03): the privilege change
              // and the stack it depends on become visible together -- now after
              // the frame extent is also proven.
              cpl_r            <= int_new_cpl;
              ss_b             <= int_ss_b;
              frm_pg_i         <= 3'd0;
              frm_pg_markd     <= 1'b0;
              int_step         <= 4'd0;
              cg_beat          <= 6'd0;   // R2-H05: frame beats count from 0
              state            <= S_INT_PUSH;
              end
            end
          end
        end

        // S_CG_PRD (REVIEW1_Aug3 R2-H05): call-gate PARAMETER COPY, source half.
        // One beat per parameter, read from the OLD stack (still installed:
        // S_INT_PROBE diverted here instead of committing), unit = the gate
        // width, offset wrapping per the OLD stack's B bit (QEMU
        // helper_lcall_protected: old_ssp + ((ESP + i*u) & old_sp_mask)). The
        // values park in cg_params[]; S_INT_PUSH's cg_xpl beats store them in
        // push order (highest-address param first). The commit that S_INT_PROBE
        // deferred runs on the LAST beat, once every source byte is in a
        // register and nothing on the bus can still fault for this transfer.
        S_CG_PRD: begin
          if (mem_ack) begin
            cg_params[cg_beat[4:0]] <= cg_wide ? mem_rdata
                                               : {16'd0, mem_rdata[15:0]};
            if (cg_beat == ({1'b0, cg_pcount} - 6'd1)) begin
              seg_sel  [SG_SS] <= int_new_ss;
              seg_base [SG_SS] <= int_ss_base;
              seg_limit[SG_SS] <= int_ss_limit;
              seg_attr [SG_SS] <= int_ss_attr;
              seg_pm_loaded[SG_SS] <= 1'b1;   // R2-H07: validated (staged) PM load
              cpl_r            <= int_new_cpl;
              ss_b             <= int_ss_b;
              frm_pg_i         <= 3'd0;
              frm_pg_markd     <= 1'b0;
              int_step         <= 4'd0;
              cg_beat          <= 6'd0;
              state            <= S_INT_PUSH;
            end else begin
              cg_beat <= cg_beat + 6'd1;
            end
          end
        end
