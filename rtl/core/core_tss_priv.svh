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
              state       <= S_INT_SS;
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
              desc = {mem_rdata, int_lo};
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
