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
            // M2S.5 — SMI# source (gated sys_mode). The psmm corpus fires SMI by
            // writing the local-APIC ICR-low (physical 0xFEE00300) with delivery
            // mode = SMI (bits[10:8]==010). QEMU's APIC honours APIC_DM_SMI ->
            // cpu_interrupt(CPU_INTERRUPT_SMI) (hw/intc/apic.c) and the SMI is taken
            // at the next instruction boundary. We model that EXACTLY: on the ICR
            // write whose value carries the SMI delivery mode, latch smi_pending so
            // the SMI is recognised at the next S_DECODE boundary (it is NOT taken
            // mid-instruction). This is the RTL SMI-sourcing path that lets the same
            // bare-metal psmm.bin drive the RTL SMM round-trip (the gdbstub single-
            // step oracle masks SMI, so this is structurally self-checked — README).
            // mem_addr here is the post-translate physical address (paging off in
            // the corpus => linear==physical), so comparing it directly is correct.
            if (sys_mode && !smm_active && mem_we &&
                mem_addr == 32'hFEE0_0300 && mem_wdata[10:8] == 3'b010)
              smi_pending <= 1'b1;
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
                else begin retire_valid<=1'b1; state<=S_PIPE; end
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
