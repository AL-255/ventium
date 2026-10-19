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
              // ---- REVIEW2_aug2 C-03 (fourth bullet, prerequisite): a 16-bit (286)
              // gate -- type 0x6/0x7, gattr[3]=0 -- has a SIXTEEN-bit offset. Word1
              // bits [31:16] are RESERVED there, not offset bits. This assembled them
              // in unconditionally, so a 286 gate with nonzero reserved bits committed
              // a garbage upper half straight into eip at :226. Well-formed tables zero
              // them, which is why the corpus never showed it -- but the CPU must IGNORE
              // them, not trust the table. Masking here is also what makes the CS-limit
              // check below safe: comparing an unmasked 16-bit gate offset against the
              // limit would fault spuriously on the DPMI 16-bit-gate path the
              // int_gate_op16 comment above describes as live.
              int_gate_off <= gattr[3] ? {mem_rdata[31:16], int_lo[15:0]}
                                       : {16'd0,            int_lo[15:0]};
`ifdef VEN_C03_PROBE
              if (!gattr[3])
                $display("[C03-G16] 16-bit gate vec=%0d reserved=%04h %s", int_vec,
                         mem_rdata[31:16],
                         (mem_rdata[31:16] != 16'd0) ? "NONZERO -- mask CHANGES eip" : "zero");
`endif
              int_gate_sel <= int_lo[31:16];
              int_gate_trap<= gattr[0];   // 0xF trap -> leave IF; 0xE int -> clear IF
              // Gate SIZE bit gattr[3]: 0 = 16-bit gate (type 0x6 int / 0x7 trap ->
              // 6-byte IP:CS:FLAGS frame, 2-byte slots, ESP -= 6); 1 = 32-bit gate
              // (type 0xE/0xF -> 12-byte EIP:CS:EFLAGS frame, the legacy path). Only
              // the SAME-PRIV push arm honours this (cross-priv/V86 stay 32-bit; the
              // corpus has no 16-bit cross-priv gate). A DPMI host running in 16-bit
              // PM (cs_d=0) installs 16-bit gates, so a gated INT under it must push
              // the 6-byte frame or the matching IRETW pops a 12-byte-shifted frame.
              int_gate_op16<= !gattr[3];
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
              // REVIEW2 H-03: the gate TYPE was never validated -- any 8 bytes at
              // IDT[vec] were interpreted as a gate, so a task gate, a call gate, a
              // data descriptor or plain garbage was decoded as an interrupt/trap gate
              // and its "offset"/"selector" fields used to transfer control. Only
              // types 0x6/0x7 (16-bit int/trap) and 0xE/0xF (32-bit int/trap) are
              // legal here; S=0 (system) is required. A bad type is #GP(vec*8+2).
              //
              // NOTE: task gates (type 0x5) are a legitimate IDT entry that this core
              // does not implement. Faulting is the honest behaviour -- previously
              // such a gate was silently misinterpreted as an interrupt gate, which is
              // strictly worse than a diagnosable #GP.
              //
              // REVIEW_Aug4 A4-H05: the architectural order -- gate S/type FIRST
              // (#GP), then the software-INT DPL check (#GP), presence LAST (#NP).
              // QEMU's do_interrupt_protected is the same; a not-present gate with
              // a bad type reported #NP here, where both oracles say #GP.
              if (gattr[4] || !(gattr[3:0] inside {4'h6,4'h7,4'hE,4'hF})) begin
                // S must be 0 (system descriptor) and the type must be int/trap gate.
                start_fault(8'd13, 1'b1, {21'd0, int_vec, 3'b010}, int_src_pc);
              end else if (int_sw && (gattr[6:5] < cpl_r)) begin
                start_fault(8'd13, 1'b1, {21'd0, int_vec, 3'b010}, int_src_pc);
              end else if (!gattr[7]) begin
                start_fault(8'd11, 1'b1, {21'd0, int_vec, 3'b010}, int_src_pc);
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
              // REVIEW1_Aug2 C-07: a CONFORMING code target keeps the current CPL and
              // does not switch stacks. Both facts derive from one bit, so name it once
              // and use it for the CPL, the stack-switch branch and the V86 latch.
              logic        int_tgt_conf, int_xpriv;
              // REVIEW2_aug2 C-03 (fifth bullet): the LAST byte the S_INT_TSS pair of
              // reads will touch. Derived from tgt_dpl, NOT from tss_stk_off: that
              // signal is a function of int_new_cpl, which is assigned NONBLOCKING a
              // few lines below, so it still holds the PREVIOUS delivery's CPL here
              // and would bound the wrong window. Same registered-vs-combinational
              // distinction H-08 settled for the IRET target limit.
              //   layout: ESPn at 4 + n*8, SSn at 8 + n*8  ->  last byte = 11 + n*8
              logic [31:0] tss_last;
              desc    = {mem_rdata, int_lo};
              cattr   = desc_attr(desc);
              tgt_dpl = desc_dpl(cattr);
              tss_last = 32'd11 + ({30'd0, tgt_dpl} << 3);
              int_tgt_conf = seg_is_code(cattr) && cattr[2];   // code + C bit
              int_xpriv    = !int_tgt_conf && (tgt_dpl < eff_cpl);
              // target CS must be present, a code segment, DPL <= the EFFECTIVE
              // CPL (V86 forces eff_cpl=3, so a DPL0 monitor CS is accepted).
              // REVIEW_Aug4 A4-H05: the checks are ORDERED -- S/type/privilege
              // (#GP) before presence (#NP), QEMU's do_interrupt_protected
              // order. The collapsed cs_bad + "NP iff P=0" form reported #NP for
              // a not-present DATA descriptor, where both oracles say #GP.
              cs_bad  = !desc_s(cattr) || !seg_is_code(cattr) || (tgt_dpl > eff_cpl);
              if (cs_bad) begin
                // bad target CS (type/privilege) -> #GP(sel). The blamed
                // descriptor is the gate's code selector in the GDT/LDT, not
                // the IDT entry: TI from the selector, IDT=0, EXT = the
                // latched delivery event class (dlv_ext: 1 only for NMI/INTR
                // -- a software INT or synchronous exception is internal).
                int_step <= 4'd0;
                start_fault(8'd13, 1'b1,
                            selector_error_ext(int_gate_sel, dlv_ext), int_src_pc);
              end else if (!desc_present(cattr)) begin
                // presence is the sole failing check -> #NP(sel).
                int_step <= 4'd0;
                start_fault(8'd11, 1'b1,
                            selector_error_ext(int_gate_sel, dlv_ext), int_src_pc);
              // ---- REVIEW2_aug2 C-03 (fourth bullet): the handler OFFSET was never
              // compared against the destination CS limit. A gate naming a valid,
              // present, correctly-privileged code segment but an offset past its end
              // installed the handler context and then began fetching outside the
              // segment -- the fault surfaced later, from the handler's own first
              // fetch, with CS/CPL already switched and (cross-priv) a stack switch
              // already begun. IA-32: the offset is checked as part of delivery and
              // raises #GP(0) -- error code ZERO, not the selector, because the fault
              // is attributed to the target address rather than to a bad descriptor.
              // desc_limit() granularity-scales, and desc is the descriptor read in
              // THIS state, so this is the same combinational-vs-registered
              // distinction H-08 settled for the IRET target.
              end else if (int_gate_off > desc_limit(desc)) begin
`ifdef VEN_C03_PROBE
                $display("[C03-OFF] handler offset %08h > CS limit %08h (vec=%0d)",
                         int_gate_off, desc_limit(desc), int_vec);
`endif
                int_step <= 4'd0;
                start_fault(8'd13, 1'b1, 32'd0, int_src_pc);
              end else begin
                // FIX (DOS-Quake #GP): capture the interrupted CS for the same-priv
                // frame push BEFORE seg_sel[SG_CS] is overwritten with the handler CS.
                // The same-priv S_INT_PUSH CS-push (core_bus_driver.svh) read
                // seg_sel[SG_CS], which by then already held int_gate_sel -> it pushed
                // the HANDLER CS, not the interrupted CS. Masked in the corpus (handler
                // CS == interrupted CS, both 0x08); exposed by DPMI int 0x31 (cs 0x87
                // client -> 0x2b host, both DPL3 = same-priv): the resume frame then
                // restored the HOST CS and the worker resumed as the host instead of
                // the client -> #GP. (The cross-priv arm re-captures int_old_cs below;
                // same value, harmless.)
                int_old_cs       <= seg_sel[SG_CS];
                // ---- REVIEW2_aug2 C-03 (first bullet): STAGE the target CS hidden
                // state instead of installing it here. These four writes used to land
                // the moment the descriptor was accepted, so the TSS bound check, the
                // new-SS validation and the frame push -- every one of which can fault
                // -- ran with the handler's CS already in the hidden cache. A fault
                // there was then classified, and its own frame built, against a CS the
                // interrupted code never had. Committed with eip at the end of
                // S_INT_PUSH, which is the single point where the delivery is known to
                // have succeeded. int_gate_sel already holds the selector.
                int_cs_base      <= desc_base(desc);
                int_cs_limit     <= desc_limit(desc);
                int_cs_attr      <= cattr;
                // ---- REVIEW1_Aug2 C-07: CONFORMING targets do not change CPL -----
                // A conforming code segment with DPL <= CPL is a legal interrupt
                // target and the CPU keeps running at the CURRENT privilege -- no CPL
                // change and NO stack switch. This unconditionally set CPL to the
                // target's DPL and then took the stack-switch branch whenever
                // tgt_dpl < eff_cpl, turning a same-privilege conforming transfer into
                // a spurious privilege transition: CPL silently dropped and the
                // handler ran on a TSS stack it was never supposed to get.
                // ---- REVIEW2_aug2 C-03 (staging, CPL half): commit the new CPL HERE
                // only on the SAME-PRIVILEGE path, where it is a no-op anyway (a
                // conforming target keeps eff_cpl; a non-conforming same-priv target
                // has tgt_dpl == eff_cpl, since cs_bad already rejected tgt_dpl >
                // eff_cpl and int_xpriv covers tgt_dpl < eff_cpl).
                //
                // On the CROSS-PRIVILEGE path it is now DEFERRED to S_INT_SS, where
                // the new stack is accepted. Committing it here was observable, not
                // theoretical: with cpl_r already lowered to the target's DPL, any
                // fault raised later in delivery -- including the #TS from the TSS
                // bound check below -- was classified against the NEW privilege. A
                // #TS handler reached through a DPL3 conforming gate (the only kind
                // that can report a broken TSS, since it needs no stack switch) was
                // then rejected by its own tgt_dpl > eff_cpl test and escalated.
                // Measured on ptsslim before this change:
                //   [FAULT] vec=10 err=00000028 depth=0   the #TS, correct
                //   [FAULT] vec=13 err=00000032 depth=1   #GP: handler CS refused
                //   [FAULT] vec=11 err=00000042 depth=2   escalation -> no report
                // int_new_cpl already carried the staged value and tss_stk_off already
                // used it, so nothing between here and S_INT_SS needed cpl_r.
                //
                // STILL OPEN: the CS hidden state (seg_sel/base/limit/attr/cs_d) is
                // committed above and is NOT staged. A late fault therefore still
                // pushes the handler's CS rather than the interrupted one. That is the
                // remainder of C-03's first bullet and needs the iret_cs_*-style
                // staging registers; it is not done here.
                if (!int_xpriv)
                  cpl_r          <= int_tgt_conf ? eff_cpl : tgt_dpl;
                int_cs_d         <= desc[54];   // REVIEW2_aug2 C-03: staged, not live
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
                from_v86 <= v86 && int_xpriv;
`ifdef VEN_DBG_WD
                // Cross-privilege decision trace for page faults.  This diagnostic is
                // intentionally guest-independent and is available only in a debug build.
                if (int_vec==8'd14)
                  $display("[VEN-XPL] vec=%0d tgt_dpl=%0d eff_cpl=%0d cpl_r=%0d v86=%b -> %s @cs:eip=%04x:%08h old_esp=%08h",
                           int_vec, tgt_dpl, eff_cpl, cpl_r, v86, int_xpriv?"XPL":"SAME",
                           seg_sel[SG_CS], eip, gpr_o[R_ESP]);
`endif
                if (int_xpriv) begin
                  // CROSS-PRIV (includes EVERY V86 delivery, eff_cpl=3): freeze the
                  // interrupted task's CS:SS:ESP for the frame (seg_sel[] here still
                  // hold the OLD values), record the target CPL, read TSS.ssN:espN.
                  xpl_active   <= 1'b1;
                  int_old_cs   <= seg_sel[SG_CS];
                  int_old_ss   <= seg_sel[SG_SS];
                  int_old_esp  <= gpr_o[R_ESP];
                  int_new_cpl  <= tgt_dpl;
                  // M7.2 V86: freeze the four data selectors + the V86 EFLAGS image
                  // (VM still set) so the 9-word frame pushes GS,FS,DS,ES + the V86
                  // SS,ESP,EFLAGS,CS,EIP. (Harmless for a non-V86 cross-priv: unused.)
                  int_old_ds   <= seg_sel[SG_DS];
                  int_old_es   <= seg_sel[SG_ES];
                  int_old_fs   <= seg_sel[SG_FS];
                  int_old_gs   <= seg_sel[SG_GS];
                  int_old_eflags <= eflags;
                  // ---- REVIEW2_aug2 C-03 (fifth bullet): REQUIRE a loaded TSS and
                  // BOUND the ssN:espN read against tr_limit before issuing it. Both
                  // signals existed and were consumed by NOTHING -- they sat in the
                  // lint sink at core.sv:7699-7709 with a comment stating outright
                  // that the negative cases "would consult" them. A cross-privilege
                  // delivery with no TSS loaded, or a TSS truncated before ssN:espN,
                  // read whatever memory followed tr_base and used it as the handler's
                  // stack selector and pointer.
                  //
                  // IA-32 raises #TS for both: error code 0 when no TSS is loaded (no
                  // selector to name), the TR selector when the TSS is too small.
                  //
                  // HONEST LIMITATION: this rejects the read, but CS/CPL were already
                  // committed above, so the #TS still begins from a partially
                  // installed handler context. That is C-03's REMAINING bullet (stage
                  // the whole control context to one commit point) and is not fixed
                  // here. Bounding the read is strictly better than performing it out
                  // of bounds, and it does not depend on the staging rework landing.
`ifdef VEN_C03_PROBE
                  $display("[C03-TSSB] xpriv deliver vec=%0d tgt_dpl=%0d tr_valid=%0b tr_limit=%0h tss_last=%0d -> %s",
                           int_vec, tgt_dpl, tr_valid, tr_limit, tss_last,
                           (!tr_valid || (tss_last > tr_limit)) ? "#TS" : "ok");
`endif
                  if (!tr_valid)
                    start_fault(8'd10, 1'b1, 32'd0, int_src_pc);
                  else if (tss_last > tr_limit)
                    start_fault(8'd10, 1'b1,
                                {16'd0, tr_sel} & 32'h0000_FFFC, int_src_pc);
                  else
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
              // REVIEW2_aug2 C-06: a call-gate frame is one word shorter (no EFLAGS),
              // so it ends at beat 3. It never carries an error code.
              // REVIEW1_Aug3 R2-H05: ...plus cg_pcount parameter slots, counted by
              // cg_beat (the frame can be 35 beats, past int_step's 4 bits).
              last = cg_xpl ? (cg_beat == (6'd3 + {1'b0, cg_pcount}))
                            : (int_has_err ? (int_step == 4'd5) : (int_step == 4'd4));
            else
              last = int_has_err ? (int_step == 4'd3) : (int_step == 4'd2);
            if (last) begin
              // R3: the ESP drop to the top of the pushed frame (V86 9-word / cross-
              // priv 5-6-word / same-priv 3-4-word, all gated on int_has_err) moved to
              // the gpr writeback driver (core_gpr_wb.svh, S_INT_PUSH arm).
              xpl_active <= 1'b0;
              cg_xpl     <= 1'b0;   // REVIEW2_aug2 C-06
              cg_beat    <= 6'd0;   // R2-H05: retire the frame beat counter with it
              // The frame page plan has served its delivery; retire it so a
              // later same-priv push can never match a captured page.
              frm_pg_val   <= 4'd0;
              frm_pg_markd <= 1'b0;
              // ---- REVIEW2_aug2 C-03 (first bullet): THE SINGLE COMMIT POINT for the
              // handler's control context. CS's selector and hidden cache land here,
              // with eip, once the whole frame is on the stack and nothing further in
              // this delivery can fault. Until now they were installed back in
              // S_INT_CS, so a #TS/#SS/#GP/#PF raised anywhere in between started from
              // a handler CS the interrupted code never executed in.
              seg_sel  [SG_CS] <= int_gate_sel;
              seg_base [SG_CS] <= int_cs_base;
              seg_limit[SG_CS] <= int_cs_limit;
              seg_attr [SG_CS] <= int_cs_attr;
              seg_pm_loaded[SG_CS] <= 1'b1;   // R2-H07: validated (staged) PM load
              cs_d             <= int_cs_d;
              eip        <= int_gate_off;
              // IA-32 6.12.1: on ANY interrupt/trap-gate entry the CPU clears TF
              // (bit8), NT (bit14), RF (bit16) and VM (bit17). An INTERRUPT gate
              // additionally clears IF (bit9); a TRAP gate leaves IF. The pushed
              // EFLAGS (beat 0) is the PRE-clear value, so this only masks the live
              // eflags after the frame is on the stack. NT/RF/VM are 0 throughout
              // the non-V86 corpus, so masking them is a no-op there; under V86 the
              // VM-clear is the LOAD-BEARING transition into the PM monitor.
              //   common mask = TF|NT|RF|VM = 0x0003_4100; +IF (0x200) for int gate.
              // REVIEW2_aug2 C-06: NONE of this applies to a far CALL through a call
              // gate. A CALL does not clear IF/TF/NT/VM -- it is not an exception
              // entry, and masking IF here would silently disable interrupts across
              // every cross-privilege call.
              if (cg_xpl)
                complete_reference_rf();            // ordinary CALL completed
              else if (!int_gate_trap)
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
                    // R2-H07: V86-entry zeroing is NOT a PM load -- a V86 guest's
                    // null-ish selectors are ordinary real-mode-style values and
                    // must not be caught by the PM null/not-present checks.
                    seg_pm_loaded[s] <= 1'b0;
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
              // REVIEW_aug2 H-04: the delivery COMPLETED -- control is now at the
              // handler's first instruction, so a fault from here on is a fresh one,
              // not a nested delivery fault. Clearing it here (rather than at the
              // handler's first retire) is what makes the depth mean "a delivery is
              // in flight" and nothing more.
              dlv_depth <= 2'd0; dlv_ctrb <= 1'b0; dlv_pf <= 1'b0;
            end else begin
              int_step <= int_step + 4'd1;
              cg_beat  <= cg_beat + 6'd1;   // R2-H05: cg_xpl frames count here
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
