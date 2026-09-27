// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/core_store_useq.svh — RAW case-arm text `included inside core.sv's
// always_ff `unique case (state)` (R2 modularization). NOT a standalone unit
// (no module/always wrapper); pasted verbatim at the original FSM site, netlist
// identical. Covers the store + micro-sequenced arms:
//   S_STORE (memory dest / push word), S_USEQ (PUSHA/POPA/POPF/REP micro-seq).

        // -------------------------------------------------------------------
        S_STORE: begin
          // ---- REVIEW2 C-02 (store half): PROBE-2 -> WRITE-1 -> WRITE-2 --------
          // A crossing store must not commit ANY byte until BOTH pages are known
          // translatable and writable. Phase 0 probes the second page (translated,
          // write-permission checked, mem_we=0 so nothing is written); phase 1 writes
          // the first page's bytes; phase 2 writes the second page's. Nothing is
          // retired until phase 2 acks, so the instruction is atomic with respect to
          // a fault on either page. Detection is arm-first: latch xs_first from the
          // pre-translate offset the moment the crossing store is seen.
          // REVIEW1_Aug2 C-02: the probe no longer issues a bus transaction, so it
          // cannot complete on mem_ack. It completes when the SECOND page's
          // translation has RESOLVED and is permitted: a TLB hit with no permission
          // or segment fault. On a miss the FSM diverts to S_WALK (driven by
          // xlate_miss, not by mem_req) and returns here, where the lookup now hits.
          // A fault on page 2 is delivered by the arms in core.sv and never reaches
          // this point, so the store is still all-or-nothing.
          if (xs_cross_now && !xs_act && !xlate_miss && !perm_fault
              && !seg_access_fault && !fe_xlate_pend) begin
            xs_act   <= 1'b1;
            xs_first <= 3'(13'h1000 - {1'b0, st_lin_nat[11:0]});
            xs_ph    <= 2'd1;          // page 2 validated -> write the first page
          end else if (mem_ack && xs_act && (xs_ph == 2'd1)) begin
            xs_ph    <= 2'd2;          // first page written -> write the second
          end else
          if (mem_ack) begin
            if (xs_act) begin xs_act <= 1'b0; xs_ph <= 2'd0; end
            begin
            logic [3:0] wr_hit;   // M2S.6: data-write breakpoint hit (DR6.Bn) bits
            // M2S.6 — DATA-WRITE breakpoint detection (gated sys_mode). This store
            // is committing; if its LINEAR address matches an armed DR7 write
            // breakpoint (R/W=01 or 11), the store completes but a #DB TRAP fires
            // AFTER it (the trap pushes the NEXT eip — IRET resumes past the store).
            // wr_hit selects the matched DR6.Bn bits; the default (K_ALU `mov
            // mem,reg`) retire path below diverts to arm_db instead of retiring,
            // fusing the store's record with the delivery (q_pc stamp, like the
            // qemu gdbstub). mem_addr is post-translate physical, but paging is off
            // in the corpus (linear==physical) and the breakpoint linear is the same
            // cur_lin the access used, so compute it the same way.
            wr_hit = sys_mode ? dr_match((q_kind==K_STR) ? (dbase_edi+str_store_addr)
                                                         : (dbase+st_addr), 1'b0)
                              : 4'd0;
            // M5 finding [med]: a STORE mutates the D-cache (read-allocate write-back
            // allocates/updates LRU) but adds NO miss penalty (oracle p5_mem:
            // `if (!hit && !store) pending += dmiss` — stores skip the penalty). A
            // misaligned store still costs +3. Run the LRU SM so a line warmed by a
            // store is later seen RESIDENT by a load (the divergent-state bug).
            if (cycle_mode) begin
              logic [31:0] sa;
              sa = (q_kind==K_STR) ? str_store_addr : st_addr;
              // The LRU access is the dcache_timing posedge (dc_acc_valid driven
              // to this S_STORE access, dc_acc_addr == sa). Stores add no miss
              // penalty (skip the dc_lu_hit test) but a misaligned store costs +3.
              if (sa[1:0] != 2'b00) pending_mem_pen <= pending_mem_pen + P5_MISALIGN;
            end
            unique case (q_kind)
              K_CTRL: begin // CALL: push done, set EIP (width-aware ESP adjust)
                // R3: ESP-=w bump moved to the gpr writeback driver (S_STORE/K_CTRL).
                eip<=call_target;
                // M2S.6: a TF single-step trap (and/or a data-write breakpoint on
                // the pushed return address) fuses with this CALL's record — qemu
                // delivers a #DB on EVERY single-stepped instruction. Resume EIP is
                // the CALL target (where execution continues). See the do_retire
                // and `default` arms for the priority/fusing rationale.
                if (sys_mode && (wr_hit != 4'd0 || tf_at_issue)) begin
                  arm_db((wr_hit != 4'd0 ? {28'd0, wr_hit} : 32'd0)
                       | (tf_at_issue   ? (32'd1 << DR6_BS) : 32'd0),
                         q_pc, call_target);
                  if (wr_hit != 4'd0) db_wp_extra <= 1'b1;
                end
                else begin retire_valid<=1'b1; state<=S_PIPE; end
              end
              K_XCHG: begin // XCHG r/m,r mem: reg <- old mem
                // R3: the src-reg<-old-mem write moved to the gpr writeback driver
                // (core_gpr_wb.svh, S_STORE/K_XCHG arm).
                eip<=next_eip;
                if (sys_mode && (wr_hit != 4'd0 || tf_at_issue)) begin
                  arm_db((wr_hit != 4'd0 ? {28'd0, wr_hit} : 32'd0)
                       | (tf_at_issue   ? (32'd1 << DR6_BS) : 32'd0),
                         q_pc, next_eip);
                  if (wr_hit != 4'd0) db_wp_extra <= 1'b1;
                end
                else begin retire_valid<=1'b1; state<=S_PIPE; end
              end
              K_STKMISC: begin // PUSHF (ESP-=w) or ENTER (push EBP then build frame)
                // R3: ENTER's EBP/ESP frame writes and PUSHF's ESP-=w moved to the
                // gpr writeback driver (core_gpr_wb.svh, S_STORE/K_STKMISC arm).
                eip<=next_eip;
                if (sys_mode && (wr_hit != 4'd0 || tf_at_issue)) begin
                  arm_db((wr_hit != 4'd0 ? {28'd0, wr_hit} : 32'd0)
                       | (tf_at_issue   ? (32'd1 << DR6_BS) : 32'd0),
                         q_pc, next_eip);
                  if (wr_hit != 4'd0) db_wp_extra <= 1'b1;
                end
                else begin retire_valid<=1'b1; state<=S_PIPE; end
              end
              K_XADD: begin // XADD memory form: sum already stored; now SRC <- old [mem]
                // The store wrote alu_out (mem+src); the source register receives the
                // OLD memory value (a_op = wmask(mem_load_data)). Doing the writeback
                // HERE (not in S_EXEC) keeps the store's combinational alu_out reading
                // the original src this clock. Flags were committed in S_EXEC.
                // R3: the src-reg<-old-mem write moved to the gpr writeback driver
                // (core_gpr_wb.svh, S_STORE/K_XADD arm).
                eip<=next_eip;
                if (sys_mode && (wr_hit != 4'd0 || tf_at_issue)) begin
                  arm_db((wr_hit != 4'd0 ? {28'd0, wr_hit} : 32'd0)
                       | (tf_at_issue   ? (32'd1 << DR6_BS) : 32'd0),
                         q_pc, next_eip);
                  if (wr_hit != 4'd0) db_wp_extra <= 1'b1;
                end
                else begin retire_valid<=1'b1; state<=S_PIPE; end
              end
              K_STR: begin // MOVS/STOS element stored
                eip<=str_next_eip;
                // String stores already computed wr_hit with the K_STR address; a
                // mid-string TF step or a data-write breakpoint fuses here too. (The
                // corpus single-steps only a nop, so wr_hit==0 && !tf_at_issue here
                // today and this stays the bit-identical retire — but a stepped/
                // watched string op now correctly delivers, matching qemu.)
                if (sys_mode && (wr_hit != 4'd0 || tf_at_issue)) begin
                  arm_db((wr_hit != 4'd0 ? {28'd0, wr_hit} : 32'd0)
                       | (tf_at_issue   ? (32'd1 << DR6_BS) : 32'd0),
                         q_pc, str_next_eip);
                  if (wr_hit != 4'd0) db_wp_extra <= 1'b1;
                end
                else begin
`ifdef VEN_REP_STOS_STREAM
                  // A streamed descriptor is already the NEXT REP element: it
                  // did not visit S_EXEC, so its GPR commit happens through the
                  // S_STORE writeback mirror on this very ACK.  Build only one
                  // further shadow from those post-current values; do not expose
                  // them in gpr_o before this element's retire snapshot.
                  if (rep_stos_stream_q && rep_stos_stream_continue) begin
`ifndef SYNTHESIS
                    if (ven_repstreamlog_en)
                      $display("[REPSTREAM] ACK cyc=%0d pc=%08x addr=%08x ecx=%08x dec=%08x continue=1 arm=%0b shape=%0b valid=%0b align=%0b/%0b pen=%0d stall=%0d",
                               core_cyc, q_pc, mem_addr, gpr_o[R_ECX], dec_cx,
                               rep_stos_stream_arm, rep_stos_cont_shape,
                               !rep_stos_cont_inval_now,
                               (str_store_addr[1:0] == 2'b00),
                               (st_lin_nat[1:0] == 2'b00), pending_mem_pen,
                               stall_cnt);
`endif
                    rep_stos_cont_q <= 1'b0;
                    rep_stos_cont_redecode_q <= 1'b0;
                    rep_stos_stream_q <= 1'b1;
                    rep_stos_stream_started_q <= 1'b0;
                    str_store_addr <= gpr_o[R_EDI] + str_step;
                    str_pre_esi <= gpr_o[R_ESI];
                    str_pre_edi <= gpr_o[R_EDI] + str_step;
                    str_pre_ecx <= dec_cx;
                    str_store_data <= str_wdata;
                    // `dec_cx` is the just-ACKed descriptor's post-count.  It
                    // is the NEXT shadow's pre-count, so that next descriptor
                    // is final exactly when dec_cx==1.
                    str_next_eip <= (dec_cx == 32'd1) ? next_eip : q_pc;
                    retire_valid<=1'b1;
                    state<=S_STORE;
                  end else if (!rep_stos_stream_q && rep_stos_stream_arm) begin
                    // D0 followed the mature S_EXEC->S_STORE path and has
                    // already advanced live EDI/ECX.  Retire D0, but capture D1
                    // only in the existing store descriptor registers; this is
                    // the one-entry shadow that enables one ACK per clock.
                    rep_stos_cont_q <= 1'b0;
                    rep_stos_cont_redecode_q <= 1'b0;
                    rep_stos_stream_q <= 1'b1;
                    rep_stos_stream_started_q <= 1'b0;
                    str_store_addr <= gpr_o[R_EDI];
                    str_pre_esi <= gpr_o[R_ESI];
                    str_pre_edi <= gpr_o[R_EDI];
                    str_pre_ecx <= gpr_o[R_ECX];
                    str_store_data <= str_wdata;
                    str_next_eip <= (gpr_o[R_ECX] == 32'd1) ? next_eip : q_pc;
`ifndef SYNTHESIS
                    if (ven_repstreamlog_en)
                      $display("[REPSTREAM] PREP cyc=%0d pc=%08x addr=%08x ecx=%08x next=%08x",
                               core_cyc, q_pc, gpr_o[R_EDI], gpr_o[R_ECX],
                               (gpr_o[R_ECX] == 32'd1) ? next_eip : q_pc);
`endif
                    retire_valid<=1'b1;
                    state<=S_STORE;
                  end else begin
                    // A started descriptor may have seen an event, debugger
                    // park, timing debt, or executable invalidation.  It has
                    // committed, so fall back to the ordinary S_PIPE boundary
                    // rather than cancelling/replaying it.
                    if (rep_stos_stream_q) begin
`ifndef SYNTHESIS
                      if (ven_repstreamlog_en)
                        if (!rep_stos_cont_shape)
                          $display("[REPSTREAM] END cyc=%0d pc=%08x addr=%08x ecx=%08x arm=%0b cont_arm=%0b shape=%0b eip_eq=%0b dbg=%0b smi=%0b nmi=%0b intr=%0b poison=%0b inval=%0b align=%0b/%0b xseff=%0b exec_ok=%0b pen=%0d stall=%0d pipe=%0b occ=%0b",
                                   core_cyc, q_pc, mem_addr, gpr_o[R_ECX],
                                   rep_stos_stream_arm, rep_stos_cont_arm,
                                   rep_stos_cont_shape, (eip == q_pc), dbg_block_issue,
                                   smi_take, nmi_take, intr_take,
                                   rep_stos_cont_poison_q, rep_stos_cont_inval_now,
                                   (str_store_addr[1:0] == 2'b00),
                                   (st_lin_nat[1:0] == 2'b00), xs_eff_act,
                                   exec_issue_ok, pending_mem_pen, stall_cnt,
                                   pipe_mem_active_q, fp_occ_pending);
                        else
                          $display("[REPSTREAM] FALLBACK cyc=%0d pc=%08x addr=%08x ecx=%08x arm=%0b cont_arm=%0b shape=%0b eip_eq=%0b dbg=%0b smi=%0b nmi=%0b intr=%0b poison=%0b inval=%0b align=%0b/%0b xseff=%0b exec_ok=%0b pen=%0d stall=%0d pipe=%0b occ=%0b",
                                   core_cyc, q_pc, mem_addr, gpr_o[R_ECX],
                                   rep_stos_stream_arm, rep_stos_cont_arm,
                                   rep_stos_cont_shape, (eip == q_pc), dbg_block_issue,
                                   smi_take, nmi_take, intr_take,
                                   rep_stos_cont_poison_q, rep_stos_cont_inval_now,
                                   (str_store_addr[1:0] == 2'b00),
                                   (st_lin_nat[1:0] == 2'b00), xs_eff_act,
                                   exec_issue_ok, pending_mem_pen, stall_cnt,
                                   pipe_mem_active_q, fp_occ_pending);
`endif
                      rep_stos_stream_q <= 1'b0;
                      rep_stos_stream_started_q <= 1'b0;
                    end
`endif
                  // The continuation is armed only AFTER this final store
                  // acknowledgement and only for the audited non-final F3 AB
                  // shape.  It still returns through S_PIPE, where events,
                  // debug, flushes, and real memory/occupancy timing stalls
                  // take priority before the next iteration enters S_EXEC.
                  // A deferred branch-recovery count is deliberately carried
                  // through the continuation and charged once after final REP.
`ifndef SYNTHESIS
                  // This site is inside the final S_STORE acknowledgement and
                  // adjacent to the actual token write, so ARM cannot merely
                  // describe an earlier combinationally eligible string shape.
                  if (ven_repcontlog_en && !rep_movs_stream_arm &&
                      (rep_stos_cont_arm || rep_movs_cont_arm))
                    $display("[REPCONT] ARM cyc=%0d q_pc=%08x paddr=%08x store_ack=1 arm=1",
                             core_cyc, q_pc, mem_addr);
`endif
                  rep_stos_cont_q <= rep_stos_cont_arm || rep_movs_cont_arm;
                  // An invalidation can precede this terminal ACK by several
                  // request clocks, so an unsafe candidate gets an explicit
                  // one-shot slow-path recovery marker rather than falling into
                  // the ordinary S_PIPE frontend with stale q_* provenance.
                  rep_stos_cont_redecode_q <= rep_stos_cont_redecode_arm;
                  retire_valid<=1'b1;
                  state<=S_PIPE;
                  if (rep_movs_stream_arm) begin
                    // Only the previous element's final store ACK creates this
                    // next source owner. Live ESI/EDI/ECX already describe the
                    // precise boundary; do not advance them a second time.
                    // S_LOAD's preissue gate still yields to events/SMC before
                    // any read or page-walk side effect can occur.
                    rep_stos_cont_q <= 1'b0;
                    rep_stos_cont_redecode_q <= 1'b0;
                    agi_wr0 <= 9'h100;
                    agi_wr1 <= 9'h100;
                    irq_shadow <= 1'b0;
                    step <= 4'd0;
                    f_step <= 4'd0;
                    state <= S_LOAD;
`ifndef SYNTHESIS
                    if (ven_repcontlog_en)
                      $display("[MOVSSTREAM] ARM cyc=%0d pc=%08x esi=%08x edi=%08x ecx=%08x",
                               core_cyc, q_pc, gpr_o[R_ESI], gpr_o[R_EDI], gpr_o[R_ECX]);
`endif
                  end
`ifdef VEN_REP_STOS_STREAM
                  end
`endif
                end
              end
              default: begin
                // R3: the push/pop ESP adjust moved to the gpr writeback driver
                // (core_gpr_wb.svh, S_STORE/default arm).
                if (q_writes_flags && q_kind==K_ALU) eflags<=flags_out;
                eip<=next_eip;
                // M2S.6: a data-write breakpoint (TRAP, fires AFTER the store) or a
                // TF single-step trap fuses this store's record with the #DB
                // delivery (q_pc stamp, push next_eip = resume past the store). A
                // data breakpoint additionally needs the qemu watchpoint extra
                // handler-entry record (S_DB_EXTRA via db_wp_extra).
                if (sys_mode && (wr_hit != 4'd0 || tf_at_issue)) begin
                  arm_db((wr_hit != 4'd0 ? {28'd0, wr_hit} : 32'd0)
                       | (tf_at_issue   ? (32'd1 << DR6_BS) : 32'd0),
                         q_pc, next_eip);
                  if (wr_hit != 4'd0) db_wp_extra <= 1'b1;
                end
                else begin
                  retire_valid<=1'b1; state<=S_PIPE;
                end
              end
            endcase
            end   // REVIEW2 C-02: closes the phase-guard `begin`
          end
        end

        // -------------------------------------------------------------------
        // S_USEQ: PUSHA / POPA micro-sequence (8 word transfers).
        S_USEQ: begin
          if (mem_ack) begin
            if (q_kind==K_CX8B) begin
              // CMPXCHG8B equal-case store: beat 0 = EBX@[mem], beat 1 = ECX@[mem+4].
              // ZF was already committed in S_EXEC; retire after the second beat.
              if (step==4'd1) begin eip<=next_eip; retire_valid<=1'b1; state<=S_PIPE; end
              else step<=step+4'd1;
            end else if (q_sm==SM_PUSHA) begin
              // push order: EAX,ECX,EDX,EBX,ESP(orig),EBP,ESI,EDI
              // R3: the final ESP commit moved to the gpr writeback driver (S_USEQ).
              if (step==4'd7) begin
                eip<=next_eip; retire_valid<=1'b1; state<=S_PIPE;
              end else step<=step+4'd1;
            end else begin // POPA: pop EDI,ESI,EBP,(skip ESP),EBX,EDX,ECX,EAX
              // R3: the per-beat GPR pops + the final ESP commit moved to the gpr
              // writeback driver (core_gpr_wb.svh, S_USEQ arm).
              if (step==4'd7) begin
                eip<=next_eip; retire_valid<=1'b1; state<=S_PIPE;
              end else step<=step+4'd1;
            end
          end
        end

        // -------------------------------------------------------------------
        // S_ENTER: nested ENTER (level>0) display-copy micro-sequence. Beats:
        //   push #1        = EBP        (ent_rd=0, ent_val=EBP, set in S_EXEC)
        //   push #2..level = display[j] : read SS:[EBP-j*w] (ent_rd=1) then push it
        //   push #level+1  = FrameTemp  = ESP-w
        // EBP/ESP commit on the final push is in core_gpr_wb.svh (S_ENTER arm).
        S_ENTER: begin
          if (mem_ack) begin
            if (ent_rd) begin
              // display source read completed -> latch it, then push it next beat
              ent_val <= wmask(mem_rdata, q_w);
              ent_rd  <= 1'b0;
            end else if (({1'b0, q_imm[20:16]} + 6'd1) == ent_k) begin
              // just pushed FrameTemp (the (level+1)th push) -> done
              eip<=next_eip; retire_valid<=1'b1; state<=S_PIPE;
            end else begin
              ent_k <= ent_k + 6'd1;
              if ((ent_k + 6'd1) <= {1'b0, q_imm[20:16]}) begin
                ent_rd <= 1'b1;                         // next push is a display copy: read first
              end else begin
                ent_rd  <= 1'b0;                        // next push is FrameTemp = ESP-w
                ent_val <= wmask(gpr_o[R_ESP] - {28'd0, q_w}, q_w);
              end
            end
          end
        end
