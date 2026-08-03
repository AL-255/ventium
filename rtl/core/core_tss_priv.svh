// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/core_tss_priv.svh — RAW case-arm text `included inside core.sv's
// always_ff `unique case (state)` (R2 modularization). NOT a standalone unit
// (no module/always wrapper); pasted verbatim at the original FSM site, netlist
// identical. Covers the LTR + cross-privilege stack/SS-load arms:
//   S_LTR (M2S.4 load TR), S_INT_TSS (TSS.ssN:espN), S_INT_SS (new SS desc).
        // S_LTR (M2S.4): LTR r16 — read the GDT TSS descriptor named by the
        // selector in gpr_o[q_src_reg], load the TR hidden cache (base/limit/sel),
        // and retire. IA-32 also sets the descriptor's busy bit (type 9 -> B) in
        // the GDT; that writeback is a memory-only side effect the corpus never
        // reads back (STR returns the SELECTOR, captured below), so it is omitted
        // here — a documented simplification (no architectural-register effect).
        S_LTR: begin
          if (mem_ack) begin
            if (!seg_step) begin gdt_lo<=mem_rdata; seg_step<=1'b1; end
            else begin
              logic [63:0] desc; logic [7:0] dattr; logic [15:0] dsel;
              logic bad_sel, bad_type, not_present, lldt_null;
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
              // REVIEW2_aug2 H-10: a NULL selector is legal for LLDT and illegal for
              // LTR, so the two cannot share this term. `lldt $0` is the ordinary way
              // software INVALIDATES LDTR (every task switch to a task with no LDT does
              // it), and rejecting it with #GP breaks that outright. LTR keeps the null
              // rejection: TR must always name a real TSS.
              lldt_null   = (q_sysop == SYS_LLDT) && (dsel[15:3] == 13'd0) && !dsel[2];
              bad_sel     = !lldt_null
                         && ((dsel[15:3] == 13'd0) || dsel[2]
                          || ({16'd0, dsel[15:3], 3'd0} + 32'd7 > {16'd0, gdt_limit}));
              // A null LLDT names no descriptor, so there is nothing to type- or
              // present-check; the GDT[0] bytes just read are the null descriptor and
              // must be ignored rather than validated.
              bad_type    = !lldt_null
                         && (dattr[4]   // S must be 0 (system descriptor)
                          || (q_sysop==SYS_LLDT ? (dattr[3:0] != 4'h2)
                                                : (dattr[3:0] != 4'h9)));
              not_present = !lldt_null && !dattr[7];
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
                // REVIEW2_aug2 H-10: a null selector INVALIDATES LDTR -- selector 0 and
                // a zero limit, so any later LDT-backed reference is out of range rather
                // than resolving through a stale base.
                ldt_sel   <= lldt_null ? 16'd0 : dsel;
                ldt_base  <= lldt_null ? 32'd0 : desc_base(desc);
                ldt_limit <= lldt_null ? 16'd0 : desc_limit16(desc);
              end else begin
                tr_sel   <= dsel;
                tr_base  <= desc_base(desc);
                tr_limit <= desc_limit(desc);
                tr_attr  <= desc_attr(desc);   // M2S.4b: held for the busy-clear on a switch
                tr_valid <= 1'b1;
              end
              seg_step <= 1'b0;
              eip<=next_eip; retire_valid<=1'b1; state<=S_PIPE;
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
              if (({16'd0, ioperm_base} + {19'd0, ioperm_last[15:3]}) > tr_limit)
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
              // [VEN-ESP0] the TSS.ESPn value pulled from memory for a cross-priv
              // delivery. Compares vs golden (0x3862): 0x3860 => TSS memory corrupt
              // (earlier bug); 0x3862 => the frame/writeback math drops the 2 bytes.
              if (creg3==32'h0007e000)
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
              // cpl_r already holds the NEW CPL: S_INT_CS committed it before chaining
              // here, and this arm only runs on the cross-privilege path.
              ss_int_bad = (int_new_ss[15:2] == 14'd0)          // null selector
                        || !ss_int_a[4] || ss_int_a[3] || !ss_int_a[1]  // not writable DATA
                        || (int_new_ss[1:0] != cpl_r)           // RPL must equal the new CPL
                        || (ss_int_a[6:5]   != cpl_r);          // DPL must equal the new CPL
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
                seg_sel  [SG_SS] <= int_new_ss;
                seg_base [SG_SS] <= desc_base(desc);
                seg_limit[SG_SS] <= desc_limit(desc);
                seg_attr [SG_SS] <= desc_attr(desc);
                // REVIEW_aug2 H-01: capture SS.B here too. ss_b was updated ONLY on the
                // ordinary segment-load path, so a cross-privilege delivery onto a
                // 16-bit inner stack kept the PREVIOUS descriptor's width and pushed the
                // frame with the wrong address size.
                ss_b             <= desc[54];
                int_step         <= 4'd0;
                state            <= S_INT_PUSH;
              end
            end
          end
        end
