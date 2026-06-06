// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/core_int_deliver.svh — RAW case-arm text `included inside core.sv's
// always_ff `unique case (state)` (R2 modularization). NOT a standalone unit
// (no module/always wrapper); pasted verbatim at the original FSM site, netlist
// identical. Covers the M2S.3 IDT-delivery micro-sequence + #DB extra record:
//   S_INT_GATE (read IDT gate), S_INT_CS (gate CS desc), S_INT_PUSH (push the
//   exception frame, load CS:EIP), S_DB_EXTRA (#DB extra retire record).
        // ===================================================================
        // M2S.3 — IDT DELIVERY micro-sequence (gated sys_mode). Reached from a
        // software INT/INT3/INTO/UD2 (S_DECODE) or a hardware fault DECISION
        // (S_SEGLD/S_LJMP #GP/#NP/#SS, S_WALK #PF — via start_fault). Reads the
        // gate, reads the gate's CS descriptor, pushes the exception frame, then
        // loads CS:EIP and retires ONCE (q_pc = the faulting/INT instruction's
        // PC, post-state = the pushed frame + new CS:EIP + gated IF/TF).
        // SAME-PRIVILEGE only: the frame is pushed on the current SS:ESP (cross-
        // privilege stack switch via the TSS is M2S.4).
        //
        // GATE PROTECTION CHECKS DEFERRED (M2S.4 / negative tests): this path does
        // NOT check the gate's Present bit (an absent gate -> #NP(v*8+2)), the gate
        // DPL for a software INT n (IA-32 6.12.1.2 requires gate.DPL >= CPL else
        // #GP(v*8+2); HW faults/INT3/INTO bypass this), or the target CS descriptor
        // via seg_load_fault (a bad/absent CS -> #GP/#NP). The CPL0 corpus uses
        // all-present DPL0 gates and a present 32-bit code CS (0x08), so none can
        // fire; a fault DURING delivery escalates to #DF, which (with cross-priv)
        // is M2S.4. The gate is loaded/CS-descriptor read unconditionally here.
        // ===================================================================
        // S_INT_GATE: read IDT[vec] (8 bytes @ idt_base + vec*8, 2 word reads).
        //   word0 = {selector[15:0], offset[15:0]}
        //   word1 = {offset[31:16], attr[7:0], 8'b0}  (attr at bits[15:8])
        // attr[3:0]: 0xE = 32-bit interrupt gate (clears IF), 0xF = trap gate.
        S_INT_GATE: begin
          if (mem_ack) begin
            if (int_step == 4'd0) begin
              int_lo <= mem_rdata; int_step <= 4'd1;
            end else begin
              logic [7:0] gattr;
              gattr        = mem_rdata[15:8];
              int_gate_off <= {mem_rdata[31:16], int_lo[15:0]};
              int_gate_sel <= int_lo[31:16];
              int_gate_trap<= gattr[0];   // 0xF trap -> leave IF; 0xE int -> clear IF
              int_step     <= 4'd0;
              // M2S.4 GATE PROTECTION (deferred from M2S.3):
              //   (1) gate not Present -> #NP(vec*8 + IDT bit). The error code for
              //       an IDT-sourced fault is (vec<<3)|2 (the IDT/EXT bits).
              //   (2) SOFTWARE INT n/INT3/INTO with gate.DPL < CPL -> #GP(vec*8+2)
              //       (IA-32 6.12.1.2; HW faults bypass this — int_sw==0).
              // A fault HERE is a nested delivery fault; we re-enter S_INT_GATE for
              // the new vector. (A second nesting would escalate toward #DF; the
              // corpus never triggers it, so the single re-vector is sufficient and
              // honest — full #DF chaining is a documented follow-on.)
              if (!gattr[7]) begin
                start_fault(8'd11, 1'b1, {21'd0, int_vec, 3'b010}, int_src_pc);
              end else if (int_sw && (gattr[6:5] < cpl_r)) begin
                start_fault(8'd13, 1'b1, {21'd0, int_vec, 3'b010}, int_src_pc);
              end else begin
                state      <= S_INT_CS;
              end
            end
          end
        end

        // S_INT_CS: read the gate's CS descriptor (8 bytes @ gdt_base + sel&~7).
        // Load the hidden CS base/limit/attr (like a far-jump CS load). The new
        // CPL = the target CS.DPL (a conforming code seg keeps CPL; a non-
        // conforming code seg sets CPL = DPL). M2S.4:
        //   - TARGET CS PROTECTION: present (else #NP), is a code segment, and
        //     DPL <= CPL (a more-privileged or equal handler) -> else #GP.
        //   - CROSS-PRIV: when the target CS.DPL < CPL the handler is MORE
        //     privileged: capture old SS:ESP, set the target CPL, and route to
        //     S_INT_TSS to load SS:ESP from TSS.ssN:espN before the push. SAME-
        //     PRIV (DPL == CPL): push on the current stack as in M2S.3.
        S_INT_CS: begin
          if (mem_ack) begin
            if (int_step == 4'd0) begin
              int_lo <= mem_rdata; int_step <= 4'd1;
            end else begin
              logic [63:0] desc;
              logic [7:0]  cattr;
              logic [1:0]  tgt_dpl;
              logic        cs_bad;
              desc    = {mem_rdata, int_lo};
              cattr   = desc_attr(desc);
              tgt_dpl = desc_dpl(cattr);
              // target CS must be present, a code segment, DPL <= the EFFECTIVE
              // CPL (V86 forces eff_cpl=3, so a DPL0 monitor CS is accepted).
              cs_bad  = !desc_present(cattr) || !desc_s(cattr) ||
                        !seg_is_code(cattr) || (tgt_dpl > eff_cpl);
              if (cs_bad) begin
                // bad target CS -> #NP(sel) if not present, else #GP(sel). Error
                // code = the gate's code selector with the IDT/EXT bits.
                int_step <= 4'd0;
                start_fault(desc_present(cattr) ? 8'd13 : 8'd11, 1'b1,
                            {16'd0, int_gate_sel[15:3], 3'b010}, int_src_pc);
              end else begin
                seg_sel  [SG_CS] <= int_gate_sel;
                seg_base [SG_CS] <= desc_base(desc);
                seg_limit[SG_CS] <= desc_limit(desc);
                seg_attr [SG_CS] <= cattr;
                cpl_r            <= tgt_dpl;     // CPL = target CS.DPL
                cs_d             <= desc[54];
                int_step         <= 4'd0;
                // M7.2: latch whether THIS delivery's source was V86 (eflags[17] is
                // still set here — it is cleared on the S_INT_PUSH final beat). A V86
                // source always crosses to a lower-priv PM handler, so it falls into
                // the cross-priv arm; from_v86 makes S_INT_PUSH push the 9-word frame.
                // ROBUSTNESS (M7.2 review): gate the latch on the SAME cross-priv
                // predicate that loads int_new_esp/SS from the TSS. A correct V86
                // monitor's IDT gate always targets a CPL0 handler (tgt_dpl<eff_cpl=3),
                // so this is a no-op for every valid delivery (corpus stays 949/949).
                // A malformed V86 gate to a DPL3 target would otherwise take the
                // same-priv push arm yet still set from_v86=1, making S_INT_PUSH emit
                // the 9-word frame off a never-loaded int_new_esp/SS base -> a corrupt
                // frame at a stale address. Pinning from_v86 to the cross-priv arm
                // closes that latent path with no functional change.
                from_v86 <= v86 && (tgt_dpl < eff_cpl);
                if (tgt_dpl < eff_cpl) begin
                  // CROSS-PRIV (includes EVERY V86 delivery, eff_cpl=3): freeze the
                  // interrupted task's CS:SS:ESP for the frame (seg_sel[] here still
                  // hold the OLD values), record the target CPL, read TSS.ssN:espN.
                  xpl_active   <= 1'b1;
                  int_old_cs   <= seg_sel[SG_CS];
                  int_old_ss   <= seg_sel[SG_SS];
                  int_old_esp  <= gpr[R_ESP];
                  int_new_cpl  <= tgt_dpl;
                  // M7.2 V86: freeze the four data selectors + the V86 EFLAGS image
                  // (VM still set) so the 9-word frame pushes GS,FS,DS,ES + the V86
                  // SS,ESP,EFLAGS,CS,EIP. (Harmless for a non-V86 cross-priv: unused.)
                  int_old_ds   <= seg_sel[SG_DS];
                  int_old_es   <= seg_sel[SG_ES];
                  int_old_fs   <= seg_sel[SG_FS];
                  int_old_gs   <= seg_sel[SG_GS];
                  int_old_eflags <= eflags;
                  state        <= S_INT_TSS;
                end else begin
                  xpl_active   <= 1'b0;          // SAME-PRIV: push on current stack
                  state        <= S_INT_PUSH;
                end
              end
            end
          end
        end

        // S_INT_PUSH: push the exception frame (32-bit gate), one word per beat,
        // at descending stack addresses (so the handler sees, low->high:
        // [errcode], EIP, CS, EFLAGS). Beat 0 EFLAGS @ ESP-4, 1 CS @ ESP-8,
        // 2 EIP @ ESP-12, 3 errcode @ ESP-16 (only when int_has_err). On the
        // final beat: ESP -= frame size, load EIP <- gate offset, clear IF/TF on
        // an interrupt gate (trap gate leaves them), and RETIRE the delivery.
        S_INT_PUSH: begin
          if (mem_ack) begin
            logic last;
            // last push beat: SAME-PRIV = 2 (EIP) / 3 (errcode); CROSS-PRIV = 4
            // (EIP) / 5 (errcode), since the larger frame adds old SS + old ESP.
            // M7.2 V86 (from_v86, always cross-priv): the 9-WORD frame
            //   beat 0 GS, 1 FS, 2 DS, 3 ES, 4 SS, 5 ESP, 6 EFLAGS, 7 CS, 8 EIP
            //   (+ beat 9 errcode when int_has_err) — last = 8 (EIP) / 9 (errcode).
            if (from_v86)
              last = int_has_err ? (int_step == 4'd9) : (int_step == 4'd8);
            else if (xpl_active)
              last = int_has_err ? (int_step == 4'd5) : (int_step == 4'd4);
            else
              last = int_has_err ? (int_step == 4'd3) : (int_step == 4'd2);
            if (last) begin
              logic [31:0] fsz;
              if (from_v86) begin
                // V86: 9-word frame (40 bytes w/ errcode, 36 without) on the TSS
                // stack. The new (CPL0) SS:base were loaded in S_INT_SS; ESP drops to
                // the top of the pushed frame.
                fsz = int_has_err ? 32'd40 : 32'd36;
                gpr[R_ESP] <= int_new_esp - fsz;
              end else if (xpl_active) begin
                // CROSS-PRIV: the new (CPL0) SS:base were already loaded in
                // S_INT_SS; ESP now drops to the top of the pushed frame on the
                // TSS stack. fsz = 20 (5 words) or 24 (6 words w/ errcode).
                fsz = int_has_err ? 32'd24 : 32'd20;
                gpr[R_ESP] <= int_new_esp - fsz;
                // CPL already lowered when S_INT_CS loaded the target CS (RPL = the
                // gate selector's RPL = 0); xpl_active is cleared below.
              end else begin
                fsz = int_has_err ? 32'd16 : 32'd12;
                gpr[R_ESP] <= gpr[R_ESP] - fsz;
              end
              xpl_active <= 1'b0;
              eip        <= int_gate_off;
              // IA-32 6.12.1: on ANY interrupt/trap-gate entry the CPU clears TF
              // (bit8), NT (bit14), RF (bit16) and VM (bit17). An INTERRUPT gate
              // additionally clears IF (bit9); a TRAP gate leaves IF. The pushed
              // EFLAGS (beat 0) is the PRE-clear value, so this only masks the live
              // eflags after the frame is on the stack. NT/RF/VM are 0 throughout
              // the non-V86 corpus, so masking them is a no-op there; under V86 the
              // VM-clear is the LOAD-BEARING transition into the PM monitor.
              //   common mask = TF|NT|RF|VM = 0x0003_4100; +IF (0x200) for int gate.
              if (!int_gate_trap)
                eflags <= eflags & ~32'h0003_4300;   // clear IF+TF+NT+RF+VM (int gate)
              else
                eflags <= eflags & ~32'h0003_4100;   // clear TF+NT+RF+VM (trap gate)
              // M7.2 V86: a V86->PM delivery ZEROES DS/ES/FS/GS (selector + hidden
              // base/limit/attr) on entry (IA-32: the V86 data segments are not
              // valid PM selectors; the monitor reloads flat ones). SS was loaded
              // from TSS.SS0 in S_INT_SS; CS was loaded in S_INT_CS.
              if (from_v86) begin
                for (int s = 0; s < NUM_SEG; s++) begin
                  if (s == int'(SG_DS) || s == int'(SG_ES) ||
                      s == int'(SG_FS) || s == int'(SG_GS)) begin
                    seg_sel  [s] <= 16'd0;
                    seg_base [s] <= 32'd0;
                    seg_limit[s] <= 32'd0;
                    seg_attr [s] <= 8'd0;
                  end
                end
              end
              from_v86      <= 1'b0;
              q_pc          <= int_src_pc;   // stamp the delivering instruction's PC
              retire_valid  <= 1'b1;
              int_step      <= 4'd0;
              // M6B Erratum 79: this #GP just delivered from a V86 POPF/IRET that
              // trapped at IOPL<3, and a data breakpoint was armed on the (never-
              // accessed) SS:ESP. On the affected stepping the #DB is erroneously
              // delivered AS SOON AS the #GP handler is entered. Chain it now: the
              // #GP retired ONCE (above) into the #GP handler entry; we immediately
              // re-enter the IDT FSM for vector 1 (#DB), pushing the #GP handler's
              // FIRST instruction (int_gate_off, just committed into eip) as the
              // saved CS:EIP — the documented Implication. dr6 gets the matched
              // Bn bits sticky-set. arm_db sets state<=S_INT_GATE itself, so it
              // takes priority over the db_wp_extra/S_PIPE choice below. INERT
              // unless err79_pending (only set with errata_en[ERR_DBGP] ON + a real
              // SS:ESP data-bp on a V86 POPF/IRET), so the clean path is unchanged.
              // ROBUSTNESS: only chain when THIS completing delivery is the V86
              // #GP (from_v86 && int_vec==13) the latch was raised for, so a stray
              // latch (a nested gate fault diverting this delivery before it
              // reached here, which the well-formed corpus never hits) can never
              // mis-chain the #DB onto an unrelated delivery — it just clears.
              if (err79_pending && from_v86 && int_vec == 8'd13) begin
                err79_pending <= 1'b0;
                // saved CS:EIP = the #GP handler's first instruction (int_gate_off).
                // #DB is a FAULT here (re-report of the handler entry), no errcode.
                arm_db({28'd0, err79_dr6_bits}, int_gate_off, int_gate_off);
              end
              else if (err79_pending) begin
                // not the matching delivery (defensive) — drop the stale latch and
                // fall through to the normal completion below.
                err79_pending <= 1'b0;
                if (db_wp_extra) state <= S_DB_EXTRA;
                else             state <= S_PIPE;
              end
              // M2S.6: a DATA-watchpoint #DB needs the extra handler-entry record
              // (the qemu watchpoint single-step quirk). Divert to S_DB_EXTRA to
              // emit it before the handler runs; all other deliveries go to S_PIPE.
              else if (db_wp_extra) state <= S_DB_EXTRA;
              else             state <= S_PIPE;
            end else begin
              int_step <= int_step + 4'd1;
            end
          end
        end

        // M2S.6 — S_DB_EXTRA: the data-watchpoint extra record. The S_INT_PUSH
        // delivery above already committed eip <- handler entry + the pushed frame
        // and retired ONCE (stamped at the store's PC). qemu's gdbstub then emits a
        // SECOND record at the handler-entry PC with the SAME state (the resumption
        // point, before the handler's first instruction). Re-stamp q_pc = eip (now
        // the handler entry) and retire once more, unchanged, then run the handler.
        S_DB_EXTRA: begin
          q_pc         <= eip;        // handler entry PC (eip was set in S_INT_PUSH)
          retire_valid <= 1'b1;
          db_wp_extra  <= 1'b0;
          state        <= S_PIPE;
        end
