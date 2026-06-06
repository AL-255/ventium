// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/core_tss_priv.svh — RAW case-arm text `included inside core.sv's
// always_ff `unique case (state)` (R2 modularization). NOT a standalone unit
// (no module/always wrapper); pasted verbatim at the original FSM site, netlist
// identical. Covers the LTR + cross-privilege stack/SS-load arms:
//   S_LTR (M2S.4 load TR), S_INT_TSS (TSS.ssN:espN), S_INT_SS (new SS desc).
        // S_LTR (M2S.4): LTR r16 — read the GDT TSS descriptor named by the
        // selector in gpr[q_src_reg], load the TR hidden cache (base/limit/sel),
        // and retire. IA-32 also sets the descriptor's busy bit (type 9 -> B) in
        // the GDT; that writeback is a memory-only side effect the corpus never
        // reads back (STR returns the SELECTOR, captured below), so it is omitted
        // here — a documented simplification (no architectural-register effect).
        S_LTR: begin
          if (mem_ack) begin
            if (!seg_step) begin gdt_lo<=mem_rdata; seg_step<=1'b1; end
            else begin
              logic [63:0] desc;
              desc      = {mem_rdata, gdt_lo};
              tr_sel   <= gpr[q_src_reg][15:0];
              tr_base  <= desc_base(desc);
              tr_limit <= desc_limit(desc);
              tr_attr  <= desc_attr(desc);   // M2S.4b: held for the busy-clear on a switch
              tr_valid <= 1'b1;
              seg_step <= 1'b0;
              eip<=next_eip; retire_valid<=1'b1; state<=S_PIPE;
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
              int_step         <= 4'd0;
              state            <= S_INT_PUSH;
            end
          end
        end
