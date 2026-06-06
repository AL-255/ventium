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
                  pf_errcode <= {eff_cpl == 2'd3, walk_is_write, 1'b0};
                  walk_pf <= 1'b1;
                  start_fault(8'd14, 1'b1,
                              {29'd0, eff_cpl == 2'd3, walk_is_write, 1'b0}, q_pc);
                end else if (is_big) begin
                  // 4 MiB large page: PDE is the leaf. Write A/D back if needed,
                  // else fill the TLB directly (reuse step-1's PDE writeback arm).
                  if (!pde[5] || (walk_is_write && !pde[6])) begin
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
                            | ((is_big && walk_is_write) ? 32'h0000_0040 : 32'd0);
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
                  pf_errcode <= {eff_cpl == 2'd3, walk_is_write, 1'b0};
                  walk_pf <= 1'b1;
                  start_fault(8'd14, 1'b1,
                              {29'd0, eff_cpl == 2'd3, walk_is_write, 1'b0}, q_pc);
                end else if (!pte[5] || (walk_is_write && !pte[6])) begin
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
