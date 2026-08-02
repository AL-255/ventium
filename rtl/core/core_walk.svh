// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/core_walk.svh — RAW case-arm text `included inside core.sv's always_ff
// `unique case (state)` (R2 modularization). NOT a standalone unit (no module/
// always wrapper); pasted verbatim at the original FSM site, netlist identical.
// Covers the M2S.2 two-level page-table walk arm:
//   S_WALK (read PDE -> write A; read PTE -> write A/D; fill the TLB).
        // M2S.2 — S_WALK: the 2-level page-table walk for a TLB miss.
        //   step 0: read PDE @ (CR3&~0xFFF)+lin[31:22]*4
        //   step 1: (4 KiB only) write PDE back with A(bit5) set, if it was clear
        //   step 2: read PTE @ (PDE&~0xFFF)+lin[21:12]*4
        //   step 3: write PTE back with A (and D on a write) set, if clear
        // On a 4 MiB page (CR4.PSE & PDE.PS) the PDE is the leaf: step 0 -> the
        // PDE-A/D writeback (reusing step 1's bus arm, then fill). A missing
        // Present bit is a #PF DECISION (CR2 + error code); delivery is M2S.3 so
        // it HALTs here (the gate tests are clean + never fault). The TLB stores
        // the effective {US,RW,P} = AND of the PDE and PTE permission bits.
        // -------------------------------------------------------------------
        S_WALK: begin
          if (mem_ack) begin
            unique case (walk_step)
              // -------- step 0: PDE read --------
              3'd0: begin
                logic [31:0] pde; logic is_big;
                pde    = mem_rdata;
                walk_pde <= pde;
                is_big = cr4_pse && pde[7];
                if (!pde[0]) begin
                  // PDE not present -> #PF (vector 14). M2S.3: DELIVER through the
                  // IDT. Set CR2 (the faulting linear addr) + the error code
                  // {US,RW,P} (P=0 here, RW from the access, US from the real CPL),
                  // then vector. #PF is a FAULT -> push the FAULTING EIP (q_pc) so
                  // IRET restarts the access after the handler maps the page.
                  creg2  <= walk_lin;
                  // US bit = the EFFECTIVE CPL (V86 forces 3) at the faulting access.
                  pf_errcode <= {walk_usr_lat, walk_is_write, 1'b0};   // H-03: latched class
                  walk_pf <= 1'b1;
`ifdef VEN_DBG_WD
                  $display("[VEN-PFW] #PF PDE-np lin=%08h pde=%08h pde_addr=%08h @cs:eip=%04x:%08h cr3=%08h w=%b",
                           walk_lin, pde, {creg3[31:12], walk_lin[31:22], 2'b00}, seg_sel[SG_CS], q_pc, creg3, walk_is_write);
`endif
                  start_fault(8'd14, 1'b1,
                              {29'd0, walk_usr_lat, walk_is_write, 1'b0}, q_pc);   // H-03
                end else if (is_big && (pde[21:13] != 9'd0)) begin
                  // ---- REVIEW1_Aug2 H-03: RESERVED BITS in a 4 MiB PDE ------------
                  // For 32-bit (non-PAE) paging without PSE-36, bits 21:13 of a
                  // 4 MiB PDE are RESERVED and must be zero. The walker never looked:
                  // tlb_fill_pfn is {pde[31:22], 10'd0}, so those bits were silently
                  // DISCARDED and the access mapped somewhere the entry did not name.
                  // IA-32 requires #PF with RSVD=1 -- and it must be raised BEFORE any
                  // A/D writeback or TLB fill, which is why this arm sits ahead of
                  // both. P=1 (the entry IS present; that is what distinguishes a
                  // reserved-bit fault from a not-present one) and RSVD=1 (bit 3).
                  //
                  // NOT included, deliberately: the review's other example, a PDE with
                  // PS=1 while CR4.PSE=0. The SDM has bit 7 IGNORED in that case, not
                  // reserved, so treating the entry as an ordinary 4 KiB PDE -- which
                  // `is_big = cr4_pse && pde[7]` already does -- is correct, and
                  // faulting it would be a new bug.
                  walk_pf <= 1'b1;
                  // REVIEW2_aug2 H-04: CR2 must name the faulting LINEAR address. The
                  // not-present arms assign it; this one did not, so a reserved-bit #PF
                  // left software reading a STALE CR2 -- it would fix up, or report, the
                  // wrong page entirely. Every #PF exit from this walker must set it.
                  creg2   <= walk_lin;
                  start_fault(8'd14, 1'b1,
                              {28'd0, 1'b1, walk_usr_lat, walk_is_write, 1'b1}, q_pc);   // H-03
                end else if (is_big) begin
                  // 4 MiB large page: PDE is the leaf. Write A/D back if needed,
                  // else fill the TLB directly (reuse step-1's PDE writeback arm).
                  if (!pde[5] || (walk_set_dirty && !pde[6])) begin
                    walk_step <= 3'd1;   // writes PDE with A(+D for big-page write)
                  end else begin
                    // 4 MiB fill committed combinationally into u_itlb/u_dtlb this
                    // clock (tlb_fill driver below, gated walk_for_d==IS_D).
                    state <= walk_ret_state;
                  end
                end else begin
                  // 4 KiB page: need the PTE. First set A on the PDE if clear.
                  walk_pte_addr <= {pde[31:12], walk_lin[21:12], 2'b00};
                  if (!pde[5]) walk_step <= 3'd1;   // write PDE.A then read PTE
                  else         walk_step <= 3'd2;   // PDE.A already set: read PTE
                end
              end
              // -------- step 1: PDE writeback (A, +D for a 4 MiB write) --------
              3'd1: begin
                logic is_big;
                is_big = cr4_pse && walk_pde[7];
                // reflect the just-written bits into the latched PDE.
                walk_pde <= walk_pde | 32'h0000_0020
                            | ((is_big && walk_set_dirty && walk_wr_ok_big)  // REVIEW_aug2 C-04
                               ? 32'h0000_0040 : 32'd0);
                if (is_big) begin
                  // 4 MiB fill (PDE-writeback path) committed combinationally into
                  // u_itlb/u_dtlb this clock (tlb_fill driver below).
                  state <= walk_ret_state;
                end else begin
                  walk_step <= 3'd2;   // now read the PTE
                end
              end
              // -------- step 2: PTE read --------
              3'd2: begin
                logic [31:0] pte;
                pte = mem_rdata;
                walk_pte <= pte;
                if (!pte[0]) begin
                  // PTE not present -> #PF (vector 14): DELIVER. CR2 + error code
                  // {US,RW,P=0}; push the FAULTING EIP (q_pc) so IRET restarts the
                  // access once the handler maps the page (the pfault demand-page).
                  creg2  <= walk_lin;
                  // US bit = the EFFECTIVE CPL (V86 forces 3) at the faulting access.
                  pf_errcode <= {walk_usr_lat, walk_is_write, 1'b0};   // H-03: latched class
                  walk_pf <= 1'b1;
`ifdef VEN_DBG_WD
                  $display("[VEN-PFW] #PF PTE-np lin=%08h @cs:eip=%04x:%08h w=%b for_d=%b ret_state=%s q_mrd=%b q_mwr=%b q_ea=%08h ibuf=%016h | eax=%08h ebx=%08h ecx=%08h edx=%08h esi=%08h edi=%08h ebp=%08h esp=%08h | segsel cs=%04x ss=%04x ds=%04x es=%04x fs=%04x gs=%04x | segbase ss=%08h ds=%08h es=%08h fs=%08h gs=%08h",
                           walk_lin, seg_sel[SG_CS], q_pc, walk_is_write, walk_for_d, walk_ret_state.name(), q_mem_read, q_mem_write, q_ea, dbg_ibuf,
                           gpr_o[R_EAX], gpr_o[R_EBX], gpr_o[R_ECX], gpr_o[R_EDX],
                           gpr_o[R_ESI], gpr_o[R_EDI], gpr_o[R_EBP], gpr_o[R_ESP],
                           seg_sel[SG_CS], seg_sel[SG_SS], seg_sel[SG_DS], seg_sel[SG_ES], seg_sel[SG_FS], seg_sel[SG_GS],
                           seg_base[SG_SS], seg_base[SG_DS], seg_base[SG_ES], seg_base[SG_FS], seg_base[SG_GS]);
`endif
                  start_fault(8'd14, 1'b1,
                              {29'd0, walk_usr_lat, walk_is_write, 1'b0}, q_pc);   // H-03
                end else if (!pte[5] || (walk_set_dirty && !pte[6])) begin
                  walk_step <= 3'd3;   // set A (+D on write) in the PTE
                end else begin
                  // 4 KiB fill committed combinationally into u_itlb/u_dtlb this
                  // clock (tlb_fill driver below, gated walk_for_d==IS_D).
                  state <= walk_ret_state;
                end
              end
              // -------- step 3: PTE writeback (A + D) then fill --------
              default: begin
                // 4 KiB fill (PTE-writeback path; pte_new = walk_pte | A | D)
                // committed combinationally into u_itlb/u_dtlb this clock (the
                // tlb_fill driver below recomputes pte_new identically).
                state <= walk_ret_state;
              end
            endcase
          end
        end
