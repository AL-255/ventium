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
          if (stall_cnt!=7'd0) begin
            // M5: burn a materialised stall clock (D-cache miss / misalign /
            // FP-latency wait). No retirement; cyc = clock-count-at-retire thus
            // grows by exactly the penalty for the instruction that issues once
            // the countdown reaches 0. The stall clock writes nothing, so it
            // cannot create a phantom AGI hazard next clock.
            stall_cnt<=stall_cnt-7'd1;
            agi_wr0<=9'h100; agi_wr1<=9'h100;
          end else if (!pipe_bytes_ok) begin
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
            // victim (~ic_lru_o, the PRE-edge not-MRU way) is computed HERE in the
            // spine and latched into pf_fill_way so S_PF fills words 1..7 + the
            // fill-complete MRU into the SAME way (the module never recomputes it).
            pf_fill_addr <= pf_miss_fa;
            pf_fill_way  <= ~ic_lru_o[pf_miss_fa[11:5]];
            pf_word<=3'd1; state<=S_PF;
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
`ifdef VEN_FP_PIPE
          end else if (fp_pipe_rd_haz) begin
            // +VEN_FP_PIPE: the deferred arith result is being committed to fpr
            // THIS clock (we_wabs); an FP op that reads that target must wait one
            // clock to see it. Burn a no-issue bubble — the commit lands on this
            // edge, so next clock fpp_valid=0 and the op issues with fresh data.
            agi_wr0<=9'h100; agi_wr1<=9'h100;
`endif
          end else if (u_d.is_fp && u_d.fp_kind==FK_ARITH && fctrl[9:8]!=2'b11) begin
            // M5 finding [low]: an FK_ARITH (D8 reg-form fadd/fsub/fmul/fdiv) under
            // a non-extended precision control word (PC != 11) must NOT silently
            // compute the full extended-precision result (the datapath only
            // implements 64-bit extended). The slow path HALTs loudly in this case
            // (Tier-3 deferral, see f_pc_bad below); the fast path must do the same
            // so cycle-mode FP cannot diverge functionally from QEMU's
            // programmed-precision rounding. Default cw 0x037f has PC=11 (fine), so
            // the gate kernels never trip this; non-default-PC code HALTs.
            state<=S_HALT;
          end else if (u_d.is_fp) begin
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
            if (!fp_occ_pending && $signed(dep_ready - core_cyc) > 0) begin
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
                  && v_d.is_fxch_free && v_bytes_ok && v_d.fp_sti!=3'd0) begin
                eip            <= eip + {28'd0,u_d.len} + {28'd0,v_d.len};
                q_pc2          <= eip + {28'd0,u_d.len};   // the FXCH's own pc (V retire)
                retire2_valid  <= 1'b1; retire2_pipe<=2'd1; retire2_paired<=1'b1;
              end else
`endif
              eip<=eip + {28'd0,u_d.len};
            end
          end else if (!u_d.simple || sys_mode) begin
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

            // ---- U commit ----
            if (u_d.is_lea) begin
              gpr[u_d.dst]<=gpr[u_d.base];
              if (u_d.dst!=R_ESP) w0={6'd0,u_d.dst};
            end else if (u_d.is_load) begin
              gpr[u_d.dst]<=mem_rdata;
              if (u_d.dst!=R_ESP) w0={6'd0,u_d.dst};
              // M5: L1 D-cache TIMING. The load data still comes from the BFM
              // (mem_rdata, above); here we run the real 2-way LRU hit/miss SM and
              // DEFER any miss penalty (read-allocate +dmiss) / misalign (+3) to
              // the next instruction, exactly as p5_mem()/p5model does. A line
              // that misses is allocated now (dc_acc_valid below) so re-references
              // hit. dc_lu_hit reads the PRE-access state (dc_lu_addr ==
              // gpr[u_d.base] this clock); the allocate is the dcache_timing
              // posedge driven by dc_acc_valid/dc_acc_addr (UNGATED — this U-pipe
              // load runs the SM in func and cycle mode alike).
              begin
                logic [6:0] pen;
                pen = 7'd0;
                if (!dc_lu_hit)                     pen = pen + P5_DMISS;
                if (gpr[u_d.base][1:0] != 2'b00)    pen = pen + P5_MISALIGN;
                pending_mem_pen <= pen;
              end
            end else if (u_d.is_shift) begin
              gpr[u_d.dst]<=u_sh;
              if (u_d.shimm!=5'd0) begin
                logic [31:0] fl;
                // SHL/SHR/SAL/SAR (shrot 4..7): SF/ZF/PF from result, AF=0,
                // CF & OF per QEMU (OF = MSB(shm1) ^ MSB(result)). Matches the
                // slow path's K_SHIFT block exactly (only this group reaches the
                // fast path; rotates fall back to the slow FSM).
                fl=eflags & 32'hFFFF_F72A;
                fl[0]=u_shcf; fl[2]=parity8(u_sh[7:0]); fl[4]=1'b0;
                fl[6]=(u_sh==32'd0); fl[7]=u_sh[31];
                fl[11]=u_shm1[31]^u_sh[31]; fl[1]=1'b1;
                eflags<=fl;
              end
              if (u_d.dst!=R_ESP) w0={6'd0,u_d.dst};
            end else if (u_d.is_branch || u_d.is_nop) begin
              // no register/flag write
            end else begin
              if (u_d.wreg) begin
                gpr[u_d.dst]<=u_alu;
                if (u_d.dst!=R_ESP) w0={6'd0,u_d.dst};
              end
              if (u_d.wflags) eflags<=u_flags;
            end

            // ---- V commit (paired) ----
            if (do_v) begin
              if (v_d.is_lea) begin
                gpr[v_d.dst]<=gpr[v_d.base];
                if (v_d.dst!=R_ESP) w1={6'd0,v_d.dst};
              end else if (v_d.is_branch || v_d.is_nop) begin
                // V branch: handled via branch logic below
              end else begin
                if (v_d.wreg) begin
                  gpr[v_d.dst]<=v_alu;
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
            post_eip = eip + {28'd0,u_d.len} + (do_v ? {28'd0,v_d.len} : 32'd0);

            if (u_is_br) begin
              // U is the (sole) branch this clock.
              u_taken = u_d.br_cond ? u_d.br_taken : 1'b1;
              redir_tgt = u_taken ? u_target : (eip + {28'd0,u_d.len});
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
              vpc = eip + {28'd0,u_d.len};
              v_taken = v_br_taken_eff;
              redir_tgt = v_taken ? v_target : (vpc + {28'd0,v_d.len});
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
              q_pc2 <= eip + {28'd0,u_d.len};   // V retire pc
              retire2_valid <= 1'b1;
              retire2_pipe  <= 2'd1;    // V
              retire2_paired<= 1'b1;
            end
            // After a redirect the next S_PIPE clock re-checks icache presence
            // (pipe_bytes_ok) and fills the target line via S_PF if cold.
          end
        end
