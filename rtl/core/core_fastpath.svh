// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/core_fastpath.svh — RAW case-arm text `included inside core.sv's
// always_ff `unique case (state)` (R2 modularization). NOT a standalone unit
// (no module/always wrapper); pasted verbatim at the original FSM site — it is
// the FIRST run of arms right after the `unique case (state)` header (which,
// with the FSM prologue, stays inline in core.sv). Netlist identical. Covers the
// dual-issue fast path + icache fill sequencing:
//   S_RESET (reset latch), S_PF (icache prefetch fill), S_PIPE (dual-issue).
        S_RESET: begin fetch_word<=3'd0; state<=S_PIPE; end

        // -------------------------------------------------------------------
        // S_PF: fill ONE 32-byte icache line (the line covering pf_fill_addr) via
        // 8 word reads, then return to the fast path. A cold line pays this fill
        // penalty once; thereafter the line is resident and re-fetches are free,
        // so a hot loop body converges to its steady-state CPI (the same icache
        // amortisation the p5model uses).
        // -------------------------------------------------------------------
        S_PF: begin
          if (mem_ack) begin
            // The word write into ic_data (+ the fill-complete tag/val/MRU on the
            // last word) lands in the icache module via the ic_fill_* driver below
            // (set=pf_fill_addr[11:5], way=pf_fill_way, off={pf_word,2'b00}). This
            // arm keeps only the fill SEQUENCING (the word counter + state return).
            if (pf_word==3'd7) begin
              pf_word<=3'd0;
              state<=S_PIPE;
            end else pf_word<=pf_word+3'd1;
          end
        end

        // -------------------------------------------------------------------
        // S_PIPE: the dual-issue fast path. Each clock issues 0/1/2 simple
        // instructions through the U (and, when paired, V) pipe, with AGI
        // interlock + BTB/2-bit branch prediction. Non-simple insns or a dry
        // prefetch buffer hand control to the proven multi-cycle FSM / refill.
        // -------------------------------------------------------------------
        S_PIPE: begin
`ifdef VEN_SYS_FASTPATH
          // ---- task #57: INTERRUPT ACCEPTANCE IN THE FAST PATH ----------------------
          // The fast path previously contained NO reference to smi_take/nmi_take/intr_take
          // and never left to S_DECODE, so while it was issuing the core COULD NOT BE
          // INTERRUPTED (core.sv:1678 accepts only in S_DECODE/S_HLTWAIT). That is why
          // enabling the fast path in sys_mode hung the boot in S_HLTWAIT with retires
          // frozen -- timer/keyboard/disk IRQs were simply never taken. It went unnoticed
          // forever because intr_take is gated on soc_en, which is 0 in user mode, and the
          // microbenchmarks are the only workloads that ever ran through here.
          //
          // Checked FIRST in the arm, i.e. at an INSTRUCTION BOUNDARY before anything
          // issues, so no U/V pair is left half-retired: this clock issues nothing and the
          // divert takes eip as the interrupted address. Priority SMI > NMI > INTR matches
          // the S_DECODE divert (core.sv:3597+). intr_take already folds in soc_en,
          // EFLAGS.IF and irq_shadow (core.sv:1679).
          //
          // CORRECTION: this comment used to end "...so the STI / MOV SS one-instruction
          // shadow is honoured without extra logic here." Half true and dangerously so.
          // Reading irq_shadow needs no extra logic, but CLEARING it did: the only clear
          // site was S_DECODE, a slow-FSM state. A fast path that never enters S_DECODE
          // therefore latched the shadow forever. The clear now lives in the retire arms
          // below, where the boundary actually is.
          // The CONDITION is fp_irq_divert (core.sv) so the mirrors consume the same
          // signal instead of re-typing it; only the TARGET selection stays here.
          if (fp_irq_divert) begin
            agi_wr0<=9'h100; agi_wr1<=9'h100;   // the divert writes no GPR this clock
            if (smi_take) begin
              // REVIEW2 C-08: was `smi_pending<=0; state<=S_SMI_SAVE;` only -- it did
              // NOT capture the resume EIP or reset the save sequencer, so RSM
              // resumed the wrong instruction. One shared task with the slow arm.
              smi_enter(eip);
            end else if (nmi_take) begin
              nmi_pending     <= 1'b0;
              nmi_in_progress <= 1'b1;
              start_fault(8'd2, 1'b0, 32'd0, eip);
              dlv_ext         <= 1'b1;          // NMI is an external event (EXT=1)
            end else begin
              start_fault(inta_vector, 1'b0, 32'd0, eip);
              dlv_ext         <= 1'b1;          // INTR is an external event (EXT=1)
            end
          end else
`endif
          if (dbg_fast_hold) begin
            // External execution debug parks at this fast-path instruction
            // boundary.  This is a true no-issue bubble: all S_PIPE mirrors use
            // fp_issue_block, and clearing AGI bookkeeping consumes a preceding
            // instruction's one-cycle dependency without manufacturing a new one.
            agi_wr0<=9'h100; agi_wr1<=9'h100;
          end else
          if (stall_cnt!=7'd0) begin
            // M5: burn a materialised stall clock (D-cache miss / misalign /
            // FP-latency wait). No retirement; cyc = clock-count-at-retire thus
            // grows by exactly the penalty for the instruction that issues once
            // the countdown reaches 0. The stall clock writes nothing, so it
            // cannot create a phantom AGI hazard next clock.
            stall_cnt<=stall_cnt-7'd1;
            agi_wr0<=9'h100; agi_wr1<=9'h100;
          end else if ((!pipe_bytes_ok || !exec_issue_ok)
`ifdef VEN_L1_AXI
                       && !(real_bus && !mem_ack)   // word-0 not ready -> bubble arm below
`endif
                      ) begin
            // icache miss on the line(s) covering the current insn: fill the
            // missing line (eip's line first, else the straddle line — the line of
            // either the decode-window end or the instruction's last byte). Each
            // fill = 8 word reads = imiss=8 clocks (the oracle penalty), emergent.
            // The 2-way victim is the not-MRU way (ic_lru^1), exactly the oracle's
            // `victim = s->lru ^ 1` (verif/qemu-plugins/p5trace.c:346).
            //
            // M5 finding [med] (I-miss off-by-one): the bus driver asserts the
            // fill's WORD-0 read in THIS detection clock (mem_addr = fill line base
            // when pf_miss is true), so this clock is productive — it captures word
            // 0 here and S_PF fetches words 1..7 (7 clocks). Total = 1 + 7 = 8
            // clocks = imiss exactly, with NO wasted transition clock (the old code
            // burned a non-fetching detection clock before the 8 fill clocks -> 9).
            // The word-0 write into ic_data lands in the icache module via the
            // ic_fill_* driver below (set=pf_miss_fa[11:5], way=victim, off=0). The
            // victim (ic_victim_o, the PRE-edge LRU way) is computed HERE in the
            // spine and latched into pf_fill_way so S_PF fills words 1..7 + the
            // fill-complete MRU into the SAME way (the module never recomputes it).
            //
            // !exec_issue_ok (an executable flush is asserted THIS cycle): a pure
            // bubble -- nothing issues from the about-to-be-invalidated arrays,
            // and the refill starts at word 0 only AFTER the clearing edge, so no
            // fill word lands inside the flush window. This is the consumption
            // half of the flush contract (the RSM stale-executable leak): the
            // comb-residency signals must NOT be gated (that closes a real loop
            // through the fragment engine's mem_ack -> tlb_flush), so the bubble
            // lives here in the FSM instead.
            pf_fill_addr <= pf_miss_fa;
            pf_fill_way  <= ic_victim_o[pf_miss_fa[5 +: IC_IDXW]];
            pf_word<= !exec_issue_ok ? 3'd0 : 3'd1;
            state<=S_PF;
`ifdef VEN_L1_AXI
          end else if (!pipe_bytes_ok) begin
            // P1-1 (real_bus): an icache miss whose fill WORD 0 the L1 has not yet
            // returned (mem_ack=0 while ven_l1d bursts the line from AXI). Bubble in
            // S_PIPE — capture nothing (ic_pf_miss_fill is gated the same way), do
            // NOT launch S_PF — until mem_ack. This is the I-side mirror of the
            // D-side load miss-stall. Reached only when real_bus && !mem_ack (the
            // condition above excludes it); inert in modes 0/1, absent by default.
            agi_wr0<=9'h100; agi_wr1<=9'h100;
`endif
`ifdef VEN_IC_BRAM
          end else if (!ic_fetch_ready) begin
            // +VEN_IC_BRAM: the line(s) for this insn are RESIDENT (pipe_bytes_ok) but
            // not yet in the registered BRAM read buffer (the synchronous read of them
            // is in flight THIS clock; the data lands on the next edge). Burn a
            // no-issue bubble; next clock the buffer tag matches flin and the insn
            // issues. Sequential fetch NEVER reaches here — a sequential line crossing
            // finds the new line already in buffer B (it prefetched flin's next line
            // last clock). This fires only on a REDIRECT to an un-buffered line
            // (sub-step 2b prefetches predicted-taken targets to remove even that).
            agi_wr0<=9'h100; agi_wr1<=9'h100;   // bubble writes nothing
`endif
`ifdef VEN_UOPCACHE
          end else if (!uop_hit || !cycle_mode) begin
            // PREDECODE-VALID GATE + ROBUST FUNCTIONAL-MODE FALLBACK.
            // `!cycle_mode`: in FUNCTIONAL (single-issue) mode — the board's Quake
            // run (cycle_mode=0) and the m3 func verify — route EVERY fetch to the
            // proven slow S_FETCH/S_DECODE decode, NOT the predecoded uop-cache slot.
            // The uop-cache predecode is only "common-case correct" (uopcache.sv:42:
            // the SMC/partial-fill/straddle-rewalk cases are follow-on), so in
            // functional mode (where correctness, not the M5 cycle model, is the
            // verdict) we DON'T TRUST the slot and use the reference decoder. This
            // drops the uop-cache *fast-path issue* at runtime in func mode (slower,
            // but the board only needs first-frame correctness for F4) WHILE KEEPING
            // the uop-cache HARDWARE synthesized — the twelve 32:1 byte-alignment
            // MUXF stay deleted (the congestion win), so timing/area are unchanged;
            // the slot BRAM is simply unused in func mode. cycle_mode=1 (the M5 cycle
            // kernels) STILL uses the fast path so the emergent-CPI model is intact.
            // This makes the +VEN_UOPCACHE func verify go 28 -> 0 (vs the spine-only
            // gate's 28) and is the robust path past the board's hardware-only
            // db-modrm fetch corruption (0x42->0x82) IF that lives in the fast path.
            //
            // `!uop_hit` (the original gate, still live for cycle_mode=1): the line is
            // RESIDENT (pipe_bytes_ok) + buffered
            // (ic_fetch_ready) but flin does NOT land on a VALID predecoded boundary,
            // for one of two reasons:
            //   (a) COLD: the line was just filled — the spine's inv_en cleared its
            //       predecode-valid (uopcache.sv:173) and the off-fast-path walker
            //       (W_WALK/W_WRITE) hasn't re-decoded it yet -> uc_pdvA=0.
            //   (b) STRADDLE / mid-insn start: the walker decodes each line FROM ITS
            //       OWN byte 0 (uopcache.sv:178); if an instruction from the PREVIOUS
            //       line spills across the 32-byte boundary into byte 0 of this line,
            //       this line's boundary map is mis-aligned -> uc_bvA[flin offset]=0
            //       (uopcache.sv:44 leaves the straddle re-walk as follow-on).
            // EITHER WAY the slot read (u_d) is STALE/garbage; issuing from it is the
            // F4 board Quake __init_libc retire-557 COLD-LINE fetch wedge/mis-decode
            // (a `mov` at 0x080985db whose window straddles into the cold line 0xe0,
            // or a fetch landing on byte 0 of 0xe0). Route to the slow S_FETCH/S_DECODE
            // path, which decodes flin DIRECTLY from the resident line (always correct,
            // straddle-robust). The walker finishes within a few clocks; the next fetch
            // reads uop_hit=1 and the fast path resumes. Placed BEFORE every u_d-
            // dependent arm so no garbage decode field is ever acted on. INERT (signal
            // absent) without VEN_UOPCACHE, so default `make verify` is byte-identical.
            agi_wr0<=9'h100; agi_wr1<=9'h100;
            fetch_word<=3'd0; state<=S_FETCH;
`endif
          end else if (pending_mem_pen!=7'd0) begin
            // M5: a previous load's D-cache miss/misalign penalty is DEFERRED to
            // the next instruction (p5model g.pending_mem_pen folded into the next
            // insn's pipe_free_at, verif/qemu-plugins/p5trace.c:420). Materialise
            // it as real stall clocks so the next retire's cyc carries the +dmiss
            // delta exactly where the oracle places it. This clock + the stall_cnt
            // countdown together burn `pending_mem_pen` clocks before any issue.
            stall_cnt<=pending_mem_pen-7'd1;
            pending_mem_pen<=7'd0;
            agi_wr0<=9'h100; agi_wr1<=9'h100;
`ifdef VEN_L1_AXI
          end else if (real_bus && pipe_load_req && !mem_ack) begin
            // P1-1: bus_mode=2 stalling L1 — a register-base load MISSED (mem_ack=0
            // while ven_l1d fills its line from AXI). The ISSUE arm below latches
            // gpr<=mem_rdata UNCONDITIONALLY (the same-cycle-BFM assumption), so
            // bubble the WHOLE issue until the fill completes and mem_ack rises; then
            // the load issues with valid data. Mirrors the !ic_fetch_ready bubble.
            // Inert in modes 0/1 (real_bus=0), absent in the default build.
            agi_wr0<=9'h100; agi_wr1<=9'h100;
`endif
`ifdef VEN_FP_PIPE
          end else if (fp_pipe_rd_haz) begin
            // +VEN_FP_PIPE: the deferred arith result is being committed to fpr
            // THIS clock (we_wabs); an FP op that reads that target must wait one
            // clock to see it. Burn a no-issue bubble — the commit lands on this
            // edge, so next clock fpp_valid=0 and the op issues with fresh data.
            agi_wr0<=9'h100; agi_wr1<=9'h100;
`endif
          end
`ifndef VEN_FP_PC_RELAX
          else if (u_d.is_fp && u_d.fp_kind==FK_ARITH && fctrl[9:8]!=2'b11) begin
            // M5 finding [low]: an FK_ARITH (D8 reg-form fadd/fsub/fmul/fdiv) under
            // a non-extended precision control word (PC != 11) must NOT silently
            // compute the full extended-precision result (the datapath only
            // implements 64-bit extended). The slow path HALTs loudly in this case
            // (Tier-3 deferral, see f_pc_bad below); the fast path must do the same
            // so cycle-mode FP cannot diverge functionally from QEMU's
            // programmed-precision rounding. Default cw 0x037f has PC=11 (fine), so
            // the gate kernels never trip this; non-default-PC code HALTs.
            // BUG #3 FIX: under +VEN_FP_PC_RELAX this fast-path HALT was UNGATED while
            // the slow-path f_pc_bad (core_fp_exec.svh) WAS gated -> a D8-form FMUL/
            // FADD under PC=24 (Quake atof @0xe938) took the fast path and HALTed on
            // HW even with the define. Now gated identically: PC!=11 arith falls to the
            // FP fast path and computes 80-bit (more precise than PC-narrowed; benign
            // for Quake, which stores back to f32). Matches the slow-path relax.
            state<=S_HALT; `ifdef VEN_DBG_CORE int_vec<=8'hE1; `endif
          end
`endif
          else if (u_d.is_fp) begin
            // M5: x87 FP fast path (cycle-mode whitelist). Functional execution
            // reuses the exact M3 helpers; the FP latency/throughput timing is
            // emergent from TWO distinct mechanisms, both mirroring the p5model
            // oracle (verif/qemu-plugins/p5trace.c):
            //   * RESULT LATENCY (fp_ready_cyc): a dependent FP consumer stalls
            //     until the producer's result is ready (issue+lat) -> dependent
            //     fadd chain CPI~3 (lat 3).
            //   * PIPE OCCUPANCY (fp_occ): the in-order pipe is held for `occ`
            //     clocks, so even a FOLLOWING INDEPENDENT op (integer or FP)
            //     cannot issue until the FP op's occupancy expires (oracle
            //     pipe_free_at=issue+occ; fdiv occ 39, fmul occ 2). This is what
            //     makes a single fdiv delay the integer work behind it.
            logic [31:0] dep_ready;
            // RAW on the x87 top-of-stack: a consumer/rmw (fp_role>=2) must wait
            // until the most recent FP producer's result is ready (fp_ready_cyc).
            dep_ready = (u_d.fp_role>=3'd2) ? fp_ready_cyc : 32'd0;
`ifdef VEN_FP_OVERLAP
            // GAP1: a FOLLOWING FP op (any is_fp that uses the x87 exec unit — i.e.
            // everything in this arm EXCEPT FXCH, which is a rename) waits until the
            // unit is free (fp_busy_cyc). Mirrors oracle ready=max(...,fp_busy_until)
            // for is_fp (fp_role>=1). Integer ops never reach this arm, so they overlap.
            if (u_d.fp_kind != FK_FXCH
                && $signed(fp_busy_cyc - core_cyc) > 0
                && $signed(fp_busy_cyc - dep_ready) > 0)
              dep_ready = fp_busy_cyc;
`endif
            // WRAP-ROBUST (Quake HW blocker #2): a real FP result-latency is <= fp_lat
            // (7-bit, <=127). A signed gap >= 128 means fp_ready_cyc is STALE across a
            // core_cyc (32-bit) WRAP — on HW, after the guest runs >~86 s (2^32 cyc @
            // 50 MHz) the FP-heavy Quake code sees a wrapped gap and spin-stalls in
            // S_PIPE ~2^31 cyc (tick frozen at an FDIV) — the second HW wedge, invisible
            // to a <2^32-cyc cosim. Clamp: gap>=128 => treat as ready (no stall). NEVER
            // fires in normal operation (gap<=fp_lat<128) so p5 timing + make-verify are
            // byte-identical; reproduced deterministically via +VEN_TEST_CYCWRAP.
            if (!fp_occ_pending && $signed(dep_ready - core_cyc) > 0
                && $signed(dep_ready - core_cyc) < 32'sd128) begin
              // stall until core_cyc reaches dep_ready (materialise the latency).
              stall_cnt <= 7'(dep_ready - core_cyc) - 7'd1;
              agi_wr0<=9'h100; agi_wr1<=9'h100;
            end else if (!fp_occ_pending && u_d.fp_occ > 7'd1) begin
              // deps satisfied; begin burning the pipe-occupancy clocks. Record the
              // issue cycle so the result-latency scoreboard is anchored to issue
              // (not to the later retire). THIS clock is the issue clock (occupancy
              // cycle 1) and the eventual commit clock is occupancy cycle `occ`;
              // between them we burn occ-2 stall clocks, so the op retires exactly
              // `occ` clocks after issue (oracle pipe_free_at = issue + occ).
              fp_issue_cyc <= core_cyc;
              fp_occ_pending <= 1'b1;
`ifdef VEN_FP_OVERLAP
              // GAP1 SPLIT: hold the INTEGER pipe only P5_FP_ISSUE_OCC clocks (this op
              // retires at issue+2, exactly oracle pipe_free_at=issue+P5_FP_ISSUE_OCC),
              // and put the real occ-long exec window on fp_busy_cyc so the FOLLOWING
              // integer ops issue in the FDIV shadow. Reuses the PROVEN occ-burn cadence
              // (retire after the burn), just with effective occ=2.
              stall_cnt   <= P5_FP_ISSUE_OCC - 7'd2;        // = 0 -> commit on issue+2
              fp_busy_cyc <= core_cyc + {25'd0, u_d.fp_occ}; // exec window (issue+39 for fdiv)
`else
              stall_cnt <= u_d.fp_occ - 7'd2;   // occ>=2 here; occ==2 => no stall
`endif
              agi_wr0<=9'h100; agi_wr1<=9'h100;
            end else begin
              // ---- issue + commit the FP op (retires at issue+occ) -----------
              // R2: the architectural state update (the FK_* fpr/ftop/fstat/fptag
              // writes that used to live here) is now driven onto u_fpu_state's
              // write ports by the fp_we_* combinational driver near the module
              // instance — it re-derives THIS exact issue+commit guard (mirroring
              // the icache ic_fp_commit driver) and computes the same values via
              // the same fpu_x87_pkg calls (fconst/fst/f_eval/f_arith_fstat). Only
              // the spine-side scoreboard + retire/EIP stay here.
              // scoreboard: a producer/rmw publishes its result at ISSUE+lat. For
              // an occ-burned op the issue cycle was recorded above; for an occ==1
              // op issue==commit clock (core_cyc) — both anchor to the real issue.
              if (u_d.fp_role==3'd1 || u_d.fp_role==3'd3)
                fp_ready_cyc <= (fp_occ_pending ? fp_issue_cyc : core_cyc)
                                + {25'd0, u_d.fp_lat};
              fp_occ_pending <= 1'b0;
              // I-cache LRU: mark this fetched line MRU (2-way LRU, per the oracle
              // per-fetch l1_access). FP ops are 2 bytes (no straddle in practice).
              // The touch lands in u_icache via tch0 (ic_tch0_* driver above, gated
              // on this exact FP-issue+commit arm).
              q_pc<=eip; retire_valid<=1'b1; x87_touched_r<=1'b1;
              // The STI / MOV-SS interrupt shadow lasts exactly ONE instruction and
              // was cleared ONLY in S_DECODE -- i.e. only on the slow path. See the
              // integer ISSUE arm below for the full note; an FP op is just as much
              // an instruction boundary, so it clears the shadow too.
              irq_shadow <= 1'b0;
              retire_pipe_valid<=1'b1; retire_pipe<=2'd0; retire_paired<=1'b0;
              agi_wr0<=9'h100; agi_wr1<=9'h100;   // FP writes no GP reg
`ifdef VEN_FXCH_FREE
              // GAP2: a free FXCH directly FOLLOWING this PUSH (FK_FLDC/FK_FLDSTI)
              // folds into THIS commit clock for ZERO added cycles (the P5 stack
              // rename). Its swap is driven by the folded fp_we_push+fp_we_sti below;
              // here we retire it as the V member and advance eip past BOTH. Only a
              // push absorbs it (the arith path defers under VEN_FP_PIPE); a lone or
              // post-arith FXCH falls through to its own occ=1 commit next clock.
              if ((u_d.fp_kind==FK_FLDC || u_d.fp_kind==FK_FLDSTI)
                  && v_d.is_fxch_free && v_bytes_ok && !dbg_pair_block && v_d.fp_sti!=3'd0) begin
                // task #56 layer 10: real mode / 16-bit address size WRAPS EIP at 64 KiB.
                // The fast path advanced a full 32-bit EIP with no wrap. Inert at w16=0.
                eip            <= u_d.w16 ? {16'd0, (eip[15:0] + {12'd0,u_d.len} + {12'd0,v_d.len})}
                                          :         (eip + {28'd0,u_d.len} + {28'd0,v_d.len});
                // REVIEW2 H-07: was unwrapped, unlike the integer arm's q_pc2 (:578).
                q_pc2          <= u_d.w16 ? {16'd0, (eip[15:0] + {12'd0,u_d.len})}
                                          :         (eip     + {28'd0,u_d.len});
                retire2_valid  <= 1'b1; retire2_pipe<=2'd1; retire2_paired<=1'b1;
              end else
`endif
              // task #56 layer 10: 16-bit address size wraps EIP at 64 KiB (real mode).
              eip <= u_d.w16 ? {16'd0, (eip[15:0] + {12'd0,u_d.len})}
                             :         (eip + {28'd0,u_d.len});
            end
          // task #55: sys_mode alone no longer forces the slow FSM -- only sys_mode WITHOUT the
          // fast path's assumptions holding (see sys_fp_ok in core.sv).
          // REVIEW Aug-1 C-01: this condition now lives in exactly ONE place (fp_sys_bail,
          // core.sv) and is consumed by the spine, the GPR mirror, BTB resolve, I-cache LRU,
          // and the D-side request. It must never be re-typed at a consumer again.
          end else if (fp_sys_bail) begin
            // hand this one instruction to the slow functional FSM. Clear the
            // AGI write-tracking: the slow op runs many cycles, so on return to
            // (M2S.1: a SYSTEM-mode core ALWAYS takes the slow FSM — the fast-path
            //  decoder assumes 32-bit/flat and is unaware of real-mode 16-bit
            //  defaults + segment bases. cycle_mode is 0 in the sys gate, so this
            //  costs nothing there, and user mode is untouched.)
            // S_PIPE the LAST fast-path write is no longer "the immediately
            // preceding clock" and must not trigger a PHANTOM AGI stall (p5model
            // AGI checks reg_wcycle==issue-1, plugin/p5model.c:451).
            agi_wr0<=9'h100; agi_wr1<=9'h100;
            fetch_word<=3'd0; state<=S_FETCH;
          end else if (mispred_bubbles!=3'd0) begin
            // burn a misprediction flush bubble (no retirement this clock).
            mispred_bubbles<=mispred_bubbles-3'd1;
            agi_wr0<=9'h100; agi_wr1<=9'h100;   // bubble writes nothing
          end else if (pipe_agi) begin
            // AGI 1-cycle interlock: stall this clock. The double-charge across
            // the immediately-following clock is prevented STRUCTURALLY by
            // clearing agi_wr0/agi_wr1 here (the stall clock writes nothing), so
            // next clock pipe_agi recomputes to 0 and the insn issues. This
            // charges the stall EVERY time the hazard exists (matching p5model's
            // per-issue reg_wcycle==issue-1 check, plugin/p5model.c:451) rather
            // than only the first time a given PC is seen -> correct for looped
            // AGI sites, where a fixed PC-suppressor would undercount stalls.
            agi_wr0<=9'h100; agi_wr1<=9'h100;   // stall clock writes nothing
          end else begin
            // ---- ISSUE: commit U, and V if paired -------------------------
            logic [8:0]  w0, w1;
            logic        do_v;
            logic [31:0] post_eip;
            logic [31:0] eip_nx;          // H-03: U-only next IP, 16-bit-wrapped
            logic        u_is_br, redirect, u_taken;
            logic [31:0] redir_tgt;
            do_v   = pipe_pair;
            w0=9'h100; w1=9'h100;

            // ---- I-cache LRU: mark the fetched line(s) MRU (2-way LRU, mirroring
            // the oracle's per-instruction l1_access). U's line, U's straddle line
            // (only when it crosses the boundary), and the paired V's line are the
            // lines actually fetched this clock. Order matches the oracle (U then
            // its straddle then V). These three touches now land in u_icache via the
            // tch0/tch1/tch2 ports (ic_tch*_* driver above), gated on this exact
            // integer-ISSUE arm, with the SAME U->straddle->V last-write-wins order.

            // ---- U commit ----  R3: the dst-reg writes (LEA/load/shift/ALU) moved
            // to the gpr writeback driver (core_gpr_wb.svh, S_PIPE ISSUE arm). The
            // AGI write-tracking (w0/w1), the D-cache penalty, and the flag commits
            // stay here.
            if (u_d.is_lea) begin
              if (u_d.dst!=R_ESP) w0={6'd0,u_d.dst};
            end else if (u_d.is_load) begin
              if (u_d.dst!=R_ESP) w0={6'd0,u_d.dst};
              // M5: L1 D-cache TIMING. The load data still comes from the BFM
              // (mem_rdata, above); here we run the real 2-way LRU hit/miss SM and
              // DEFER any miss penalty (read-allocate +dmiss) / misalign (+3) to
              // the next instruction, exactly as p5_mem()/p5model does. A line
              // that misses is allocated now (dc_acc_valid below) so re-references
              // hit. dc_lu_hit reads the PRE-access state (dc_lu_addr ==
              // gpr_o[u_d.base] this clock); the allocate is the dcache_timing
              // posedge driven by dc_acc_valid/dc_acc_addr (UNGATED — this U-pipe
              // load runs the SM in func and cycle mode alike).
              begin
                logic [6:0] pen;
                pen = 7'd0;
                if (!dc_lu_hit)                     pen = pen + P5_DMISS;
                if (gpr_o[u_d.base][1:0] != 2'b00)    pen = pen + P5_MISALIGN;
`ifdef VEN_L1_AXI
                // bus_mode=2: the REAL DDR latency is the only timing source — the
                // miss-stall gate already held the load for the actual fill. Suppress
                // the MODELED P5 penalty so it doesn't double-count (and stall-pile
                // toward the cosim cycle budget). mode-2 timing is functional-only.
                pending_mem_pen <= real_bus ? 7'd0 : pen;
`else
                pending_mem_pen <= pen;
`endif
              end
            end else if (u_d.is_shift) begin
              if (u_d.shimm!=5'd0) begin
                logic [31:0] fl;
                // SHL/SHR/SAL/SAR (shrot 4..7): SF/ZF/PF from result, AF=0,
                // CF & OF per QEMU (OF = MSB(shm1) ^ MSB(result)). Matches the
                // slow path's K_SHIFT block exactly (only this group reaches the
                // fast path; rotates fall back to the slow FSM).
                // REVIEW Aug-1 H-02: SF/OF/ZF are WIDTH-dependent. This block hard-coded
                // bit 31 and an all-32-bit zero test, so a 16-bit shift committed SF and
                // OF from bit 31 of a value whose architectural MSB is bit 15, and ZF
                // from bits the instruction does not write. The upipe16 suite (530/530)
                // does not cover this because the flag ASSEMBLY lives here in the spine,
                // not in u_pipe. PF is the low byte at every width, and CF arrives
                // width-aware from u_pipe's shrot helper, so only SF/ZF/OF change.
                // Width comes from u_d.w16, and the EXTRACTION uses the same wmask/
                // sbit helpers as the slow path's K_SHIFT arm (core_exec.svh) rather
                // than hand-rolled bit indices. Two formulas that must agree is the
                // C-01 pattern; one shared formula parameterised by width cannot
                // drift. Byte-identical to the slow path arm, term for term.
                logic [2:0] shw;
                shw = u_d.w16 ? 3'd2 : 3'd4;
                fl=eflags & 32'hFFFF_F72A;
                fl[0]=u_shcf; fl[2]=parity8(u_sh[7:0]); fl[4]=1'b0;
                fl[6]=(wmask(u_sh,shw)==32'd0);
                fl[7]=sbit(u_sh,shw);
                fl[11]=sbit(u_shm1,shw) ^ sbit(u_sh,shw);
                fl[1]=1'b1;
                eflags<=fl;
              end
              if (u_d.dst!=R_ESP) w0={6'd0,u_d.dst};
            end else if (u_d.is_branch || u_d.is_nop) begin
              // no register/flag write
            end else begin
              if (u_d.wreg) begin
                if (u_d.dst!=R_ESP) w0={6'd0,u_d.dst};
              end
              if (u_d.wflags) eflags<=u_flags;
            end

            // ---- V commit (paired) ----
            if (do_v) begin
              if (v_d.is_lea) begin
                if (v_d.dst!=R_ESP) w1={6'd0,v_d.dst};
              end else if (v_d.is_branch || v_d.is_nop) begin
                // V branch: handled via branch logic below
              end else begin
                if (v_d.wreg) begin
                  if (v_d.dst!=R_ESP) w1={6'd0,v_d.dst};
                end
                // a paired V that writes flags overrides U's flags (program
                // order: V is later). Only ALU/inc/dec reach here.
                if (v_d.wflags) eflags<=v_flags;
              end
            end

            // ---- branch resolution (U leads; or V branch when paired) -----
            // Determine the architectural taken decision + predicted target and
            // whether we mispredicted -> flush bubbles. The branch can be U
            // (unpaired) or the V member of a pair.
            u_is_br  = u_d.is_branch;
            u_taken  = 1'b0; redirect=1'b0; redir_tgt=32'd0;
            // REVIEW Aug-1 H-03: 16-bit sequential flow WRAPS IP at 64 KiB. Taken branch
            // targets got this in task #56 step G and the FP retire arm got it in layer
            // 10, but ordinary integer advance and NOT-TAKEN fallthrough were left
            // full-width -- so code running off offset FFFF walked into the next 64 KiB
            // linear region instead of wrapping to 0000. The asymmetry with the already-
            // fixed taken path is what made it easy to miss.
            //   eip_nx  = U-only next IP        (also the U not-taken fallthrough)
            //   post_eip= U(+V) next IP         (the no-branch advance)
            eip_nx   = u_d.w16 ? {16'd0, (eip[15:0] + {12'd0,u_d.len})}
                               :         (eip     + {28'd0,u_d.len});
            post_eip = u_d.w16
                     ? {16'd0, (eip[15:0] + {12'd0,u_d.len}
                                          + (do_v ? {12'd0,v_d.len} : 16'd0))}
                     :         (eip       + {28'd0,u_d.len}
                                          + (do_v ? {28'd0,v_d.len} : 32'd0));

            if (u_is_br) begin
              // U is the (sole) branch this clock.
              u_taken = u_d.br_cond ? u_d.br_taken : 1'b1;
              // H-03: not-taken fallthrough wraps (u_target is already truncated).
              redir_tgt = u_taken ? u_target : eip_nx;
              if (u_taken != u_pred_taken) begin
                mispred_bubbles <= 3'd3;     // U-pipe mispredict penalty
                redirect=1'b1;
              end else if (u_taken) redirect=1'b1;
              // BTB update for this U branch is applied by the bpred_btb module
              // on this posedge via the comb resolve port (btb_resolve_valid/
              // pc/taken), driven from the mirrored issue-gate + U arm above.
            end else if (do_v && v_d.is_branch) begin
              // V member is a simple branch (e.g. a jcc paired into V). Use the
              // flags FORWARDED from U (cmp/dec/test + jcc pairing case).
              logic v_taken; logic [31:0] vpc;
              // H-03: the V member's own PC and its not-taken fallthrough wrap too.
              vpc = eip_nx;
              v_taken = v_br_taken_eff;
              redir_tgt = v_taken ? v_target
                                  : (v_d.w16 ? {16'd0, (vpc[15:0] + {12'd0,v_d.len})}
                                             :         (vpc       + {28'd0,v_d.len}));
              if (v_taken != v_pred_taken) begin
                // Mispredict penalty matches the oracle resolve_pending_branch
                // (verif/qemu-plugins/p5trace.c:402-403): an UNCONDITIONAL taken
                // jmp/call mispredict is P5_MISPREDICT_UNCOND=3 REGARDLESS of pipe
                // (the `!pend_cond` case is checked first); only a CONDITIONAL Jcc
                // in the V pipe pays P5_MISPREDICT_V=4. The old code charged 4 for
                // a V jmp too (now V-pairable per finding [med]) -> +1 over oracle.
                mispred_bubbles <= v_d.br_cond ? 3'd4 : 3'd3;
                redirect=1'b1;
              end else if (v_taken) redirect=1'b1;
              // BTB update for this paired-V branch is applied by the bpred_btb
              // module on this posedge via the comb resolve port (driven from
              // the mirrored issue-gate + V arm above).
            end

            eip <= redirect ? redir_tgt : post_eip;
            agi_wr0<=w0; agi_wr1<=w1;

            // ---- retire records (cyc/pipe/paired emerge from the cadence) --
            q_pc <= eip;                       // primary (U) retire pc
            retire_valid <= 1'b1;
            // ---- STI / MOV-SS interrupt shadow ---------------------------
            // irq_shadow is SET in S_EXEC (core_exec.svh:32) by STI/MOV SS and was
            // CLEARED ONLY in S_DECODE (core_fetch_decode.svh:125). Both of those are
            // slow-FSM states. Once the fast path runs in sys_mode, an STI returns to
            // S_PIPE and, if the following instructions are all fast-path eligible,
            // S_DECODE is never entered -- so the shadow is NEVER cleared and
            // intr_take (core.sv:1679, gated on !irq_shadow) stays 0. Interrupts are
            // then blocked for the WHOLE run of fast instructions, not for one.
            //
            // `sti` followed by a tight polling loop is exactly the DOS/BIOS idiom,
            // and that loop is precisely the shape the fast path executes best, so
            // the failure is worst where it is most likely. It survives today only
            // because 53.7% of the boot stream is non-simple, so some instruction
            // wanders into S_DECODE soon enough to clear it.
            //
            // A retiring fast-path instruction IS an instruction boundary, so clear
            // it here for the same reason S_DECODE does. Ordering is right: the
            // divert arm at the top of S_PIPE sampled the REGISTERED irq_shadow this
            // clock (still set, correctly masking the shadowed instruction), and this
            // nonblocking clear opens the NEXT boundary. Shadow duration is exactly
            // one instruction, matching S_DECODE.
            irq_shadow <= 1'b0;
            retire_pipe_valid <= 1'b1;
            retire_pipe <= 2'd0;        // U
            retire_paired <= 1'b0;
            if (do_v) begin
              // GUARD: dual-issue (V retire) is CYCLE-MODE ONLY. retire2_state is
              // hardwired to the primary (U) `snap` and is NOT a valid post-commit
              // snapshot for the V instruction, so a paired V must never be emitted
              // in a state-checked (func) run. pipe_pair already ANDs cycle_mode;
              // this assertion locks that invariant so a future change that lets
              // pairing leak into func mode trips loudly instead of silently
              // comparing the wrong architectural state for the V member.
              // synopsys translate_off
              if (!cycle_mode) begin
                $error("core: paired V retire (do_v) in func mode (cycle_mode=0): retire2_state is U's snap, not the V insn's post-commit state");
              end
              // synopsys translate_on
              q_pc2 <= eip_nx;                  // V retire pc (H-03: 16-bit wrapped)
              retire2_valid <= 1'b1;
              retire2_pipe  <= 2'd1;    // V
              retire2_paired<= 1'b1;
            end
            // After a redirect the next S_PIPE clock re-checks icache presence
            // (pipe_bytes_ok) and fills the target line via S_PF if cold.
          end
        end
