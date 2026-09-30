// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/core_load.svh — RAW case-arm text `included inside core.sv's always_ff
// `unique case (state)` (R2 modularization). NOT a standalone unit (no module/
// always wrapper); pasted verbatim at the original FSM site, netlist identical.
// Covers the data-load arms:
//   S_LOAD (memory source / RMW dst / [ESI]/[EDI]), S_LOAD2 (CMPS 2nd operand),
//   S_FLOAD (x87 memory operand read).
        S_LOAD: begin
          // ---- REVIEW2 C-02: page-crossing split ------------------------------
          // Beat 1 of a crossing access: keep its data (the LOW bytes are the first
          // page's, correctly translated) and re-issue for the SECOND page. The FSM
          // stays in S_LOAD, so the bus driver + cur_lin -- both of which key off
          // xp_pend -- present the next page's base and it gets its OWN TLB
          // lookup/walk/permission check. Nothing is committed on this beat.
          if (mem_ack && xp_cross) begin
            xp_lo    <= mem_rdata;
            xp_first <= 3'(13'h1000 - {1'b0, cur_lin[11:0]});
            xp_w     <= load_beat_w;
            xp_pend  <= 1'b1;
          end else
          if (mem_ack) begin
            // Beat 2 (or a normal, non-crossing access). On a split, merge: the low
            // xp_first bytes came from the first page, the rest from THIS beat, whose
            // low bytes start at the second page's base.
            // ---- REVIEW_aug2 C-03: ONE merged load value, used by EVERY consumer.
            // The split merge previously wrote only mem_load_data, while MOVS, OUTS and
            // the far-pointer arms below went on reading the RAW second beat -- so a
            // page-crossing MOVSW/MOVSD/OUTSW/OUTSD or far pointer forwarded page 2's
            // beat instead of the reconstructed operand. Compute it once here and read
            // ld_val everywhere; the raw mem_rdata must not be consumed in this arm.
`ifdef VEN_P54_MOV_ACK_RETIRE
            ld_val = p54_mov_ack_load_value;
`else
            begin
              logic [5:0] sh;
              sh = 6'(xp_first) << 3;
              ld_val = xp_pend ? ((xp_lo & ~(32'hFFFF_FFFF << sh))  // first-page bytes
                                  | (mem_rdata << sh))             // second page supplies the rest
                               : mem_rdata;
            end
`endif
            if (xp_pend) xp_pend <= 1'b0;
            mem_load_data <= ld_val;
            // VEN FIX (Win95 REP MOVSB relocation): capture the MOVS store byte SINGLE-HOP, directly at
            // THIS iteration's validated load ack, into str_store_data — instead of routing it through the
            // GLOBAL persistent mem_load_data (core.sv:2301 ST_MOVS: str_wdata=mem_load_data), which another
            // memory op (self-referential fetch/BIOS-ROM table read) can clobber before S_EXEC consumes it
            // under real FPGA latency. The S_EXEC re-latch for MOVS is skipped (core_exec.svh) so the store
            // uses ONLY this byte. Store wrote a scancode table where the load served code -> the desync.
            if (q_kind==K_STR && q_st==ST_MOVS && q_str_storedi)
              str_store_data <= ld_val;   // C-03: merged, not the raw beat
            // OUTS: capture the port-out element SINGLE-HOP at this load ack too — the SAME
            // clobber hazard as MOVS above. The S_EXEC re-latch read the clobbered global
            // (a constant), so Win95's first disk WRITE pushed one stale word 256x and
            // overwrote the FAT root directory with a uniform pattern (0x1c38).
            if (q_kind==K_STR && q_st==ST_OUTS)
              ins_data <= wmask(ld_val, q_w);   // C-03: merged, not the raw beat
            // M5 finding [med] (D-cache state consistency): a SLOW-PATH data load
            // (displacement/SIB load, RMW source, string/stack load) must mutate
            // the D-cache timing model exactly like the oracle's p5_mem (which runs
            // l1_access for EVERY memory op, not just register-indirect loads). Do
            // the 2-way LRU access here and DEFER a read-miss/misalign penalty to
            // the next instruction (read-allocate), so a line warmed by a slow-path
            // access is later seen RESIDENT by a fast-path load (and vice-versa).
            // Gated on cycle_mode (func mode does no cycle accounting).
            if (cycle_mode) begin
              logic [31:0] la; logic [6:0] pen;
              la = slow_dmem_addr; pen = 7'd0;
              // dc_lu_hit/dc_acc_* are driven to `la` (slow_dmem_addr) this clock.
              if (!dc_lu_hit)            pen = pen + P5_DMISS;
              // Use the memory SOURCE extent, not the destination q_w:
              // MOVSX/MOVZX word+2 is one bank access, and bytes never split.
              if (p5_data_misaligned(la, {1'b0,load_beat_w}))
                pen = pen + P5_MISALIGN;
              pending_mem_pen <= pen;
            end
            // F3 — FF /5 JMPF / FF /3 CALLF (far indirect through memory): mem_rdata
            // is the 4-byte {selector[31:16], offset[15:0]} far pointer just read.
            if (q_jmpf_mem) begin
              if (q_w==3'd4) begin
                // 32-bit far JMP indirect (m16:32): off = full mem_rdata; the 2-byte
                // selector is at [mem+4] -> 2nd S_LOAD2 read, then commit CS:EIP.
                q_ljmp_off <= ld_val;
                state <= S_LOAD2;
              end else if (seg_real) begin
                // real-mode far JMP (m16:16): CS.sel=sel, CS.base=sel<<4, EIP=off.
                seg_sel [SG_CS] <= ld_val[31:16];
                seg_base[SG_CS] <= {12'd0, ld_val[31:16], 4'd0};
                seg_attr[SG_CS] <= 8'h9B;
                seg_pm_loaded[SG_CS] <= 1'b0;   // R2-H07: real-mode load
                eip <= {16'd0, ld_val[15:0]};
                retire_valid <= 1'b1; state <= S_PIPE;
              end else begin
                // PROTECTED-mode far JMP (m16:16): stage the target, then hand off to
                // S_LJMP — the SAME CS-descriptor load path the direct far JMP uses
                // (GDT/LDT read, seg_load_fault delivery, cs_d/CPL from the descriptor).
                q_ljmp_sel <= ld_val[31:16];
                q_ljmp_off <= {16'd0, ld_val[15:0]};
                // REVIEW2_aug2 H-07: bound the selector BEFORE S_LJMP issues the
                // descriptor read. The dispatch precheck only covers the IMMEDIATE
                // far JMP; this indirect form loads its selector from memory and
                // reached S_LJMP unchecked.
                if (far_sel_bad(ld_val[31:16]))
                  start_fault(8'd13, 1'b1,
                              {16'd0, ld_val[31:16]} & 32'h0000_FFFC, q_pc);
                else begin seg_step <= 1'b0; state <= S_LJMP; end
              end
            end else if (q_callf_mem) begin
              if (q_w==3'd4) begin
                // 32-bit far CALL indirect (m16:32): off = full mem_rdata; selector
                // @[mem+4] via S_LOAD2, then S_LCALL pushes CS:next_eip + loads CS:off.
                q_ljmp_off <= ld_val;
                state <= S_LOAD2;
              end else begin
                // stage the target; S_LCALL then pushes CS:next_eip + loads CS:off.
                q_ljmp_off <= {16'd0, ld_val[15:0]};
                q_ljmp_sel <= ld_val[31:16];
                // A real/V86 far pointer carries a segment value, not a descriptor
                // selector.  The protected-mode precheck added for C-06 used to run
                // unconditionally here, interpreting values such as the VGA ROM's
                // C000 segment as a GDT index and trapping before BIOS POST.  Keep the
                // real-mode route identical to the immediate far-CALL path; only a
                // protected transfer probes a descriptor before touching the stack.
                if (seg_real) begin
                  seg_step <= 1'b0; lcall_pend <= 1'b0; state <= S_LCALL;
                end else if (far_sel_bad(ld_val[31:16]))
                  start_fault(8'd13, 1'b1,
                              {16'd0, ld_val[31:16]} & 32'h0000_FFFC, q_pc);
                // REVIEW2_aug2 C-06: validate the descriptor BEFORE pushing -- the
                // indirect forms take the same probe path as the immediate one, or
                // they would reach S_LCALL with stale lc_cs_* staging.
                else begin seg_step <= 1'b0; lcall_pend <= 1'b1; state <= S_LJMP; end
              end
            end
            else if (q_kind==K_STR && q_st==ST_CMPS) state<=S_LOAD2;
            // BOUND / CMPXCHG8B read a SECOND word ([mem+w]) before executing.
            else if (q_kind==K_BOUND || q_kind==K_CX8B) state<=S_LOAD2;
            // 32-bit far-ptr load (LDS/LES/LSS/LFS/LGS, m16:32): off=mem_load_data
            // (@[mem]); the SELECTOR is 2 bytes @[mem+4] -> a 2nd S_LOAD2 read.
            else if (q_seg_load && !q_seg_load_lo && q_w==3'd4) state<=S_LOAD2;
            else if (rep_movs_load_fuse) begin
              // str_store_data above is THIS element's merged source, including
              // page-crossing loads. No partial source beat may reach this arm.
              // GPR writeback mirrors this edge; S_STORE retains all destination
              // permission/fragment checks and the original fault rollback.
              str_store_addr <= str_edi;
              str_pre_esi <= gpr_o[R_ESI];
              str_pre_edi <= gpr_o[R_EDI];
              str_pre_ecx <= gpr_o[R_ECX];
              str_next_eip <= (dec_cx == 32'd0) ? next_eip : q_pc;
              state <= S_STORE;
`ifndef SYNTHESIS
              if (ven_repcontlog_en)
                $display("[MOVSFUSE] LOAD cyc=%0d pc=%08x esi=%08x edi=%08x ecx=%08x split=%0b",
                         core_cyc, q_pc, gpr_o[R_ESI], gpr_o[R_EDI], gpr_o[R_ECX], xp_pend);
`endif
            end
`ifdef VEN_P54_MOV_ACK_RETIRE
            else if (p54_mov_ack_take)
              retire_reference_integer(next_eip,1'b0,eflags);
`endif
            else state<=S_EXEC;
          end
        end
        S_LOAD2: begin
          // REVIEW1_Aug2 C-03: the crossing split, identical in shape to S_LOAD above.
          // Beat 1 keeps the low bytes and re-issues for the second page (the bus
          // driver and cur_lin both redirect off xp_pend); beat 2 merges. Nothing is
          // committed on the first beat, so a fault on page 2 leaves no partial state.
          if (mem_ack && xp_cross) begin
            xp_lo    <= mem_rdata;
            xp_first <= 3'(13'h1000 - {1'b0, cur_lin[11:0]});
            xp_w     <= load_beat_w;
            xp_pend  <= 1'b1;
          end else
          if (mem_ack) begin
            // REVIEW1_Aug2 C-03: ONE merged value for this arm, for the same reason
            // C-03's first half gave S_LOAD its ld_val -- the selector arms below read
            // it too, so a crossing far pointer must not forward page 2's raw beat.
            begin
              logic [5:0] sh2;
              sh2 = 6'(xp_first) << 3;
              ld2_val = xp_pend ? ((xp_lo & ~(32'hFFFF_FFFF << sh2))
                                   | (mem_rdata << sh2))
                                : mem_rdata;
            end
            if (xp_pend) xp_pend <= 1'b0;
            // 32-bit far JMP/CALL indirect (m16:32): the 2nd read is the 2-byte
            // selector @[mem+4]; q_ljmp_off already holds the full 32-bit offset.
            if (q_jmpf_mem) begin
              if (seg_real) begin
                // real-mode far JMP (m16:32): CS.base=sel<<4, EIP=32-bit offset.
                seg_sel [SG_CS] <= ld2_val[15:0];
                seg_base[SG_CS] <= {12'd0, ld2_val[15:0], 4'd0};
                seg_attr[SG_CS] <= 8'h9B;
                seg_pm_loaded[SG_CS] <= 1'b0;   // R2-H07: real-mode load
                eip <= q_ljmp_off;                 // full 32-bit offset (NOT truncated)
                retire_valid <= 1'b1; state <= S_PIPE;
              end else begin
                // PROTECTED-mode far JMP (m16:32): q_ljmp_off already holds the 32-bit
                // offset; stage the selector and hand off to the S_LJMP CS-descriptor load.
                q_ljmp_sel <= ld2_val[15:0];
                // REVIEW2_aug2 H-07: same bound for the m16:32 indirect far JMP.
                if (far_sel_bad(ld2_val[15:0]))
                  start_fault(8'd13, 1'b1,
                              {16'd0, ld2_val[15:0]} & 32'h0000_FFFC, q_pc);
                else begin seg_step <= 1'b0; state <= S_LJMP; end
              end
            end else if (q_callf_mem) begin
              q_ljmp_sel <= ld2_val[15:0];       // q_ljmp_off already 32-bit
              // Same mode split as the m16:16 form above.  In real/V86 mode the
              // second word is a segment value and must never be table-checked.
              if (seg_real) begin
                seg_step <= 1'b0; lcall_pend <= 1'b0; state <= S_LCALL;
              end else if (far_sel_bad(ld2_val[15:0]))
                start_fault(8'd13, 1'b1,
                            {16'd0, ld2_val[15:0]} & 32'h0000_FFFC, q_pc);
              // REVIEW2_aug2 C-06: same probe-first routing for the m16:32 form.
              else begin seg_step <= 1'b0; lcall_pend <= 1'b1; state <= S_LJMP; end
            end else begin
              mem_load_data2<=ld2_val; state<=S_EXEC;
              // CMPS second operand [EDI] is also a data load -> D-cache access.
              // dc_lu_hit/dc_acc_* are driven to gpr_o[R_EDI] this clock (S_LOAD2).
              if (cycle_mode) begin
                logic [6:0] pen; pen=7'd0;
                if (!dc_lu_hit)               pen = pen + P5_DMISS;
                if (p5_data_misaligned(gpr_o[R_EDI], {1'b0,load_beat_w}))
                  pen = pen + P5_MISALIGN;
                pending_mem_pen <= pen;
              end
            end
          end
        end

        // -------------------------------------------------------------------
        // S_FLOAD: read the x87 memory operand (m16/m32 = 1 word, m64 = 2,
        // m80 = 3) into f_mem80, LSB-first. Bus addresses q_ea + 4*f_step.
        // -------------------------------------------------------------------
        S_FLOAD: begin
`ifdef VEN_FP_SHARED
          if (q_f_mem_write) begin
            // A shared-top store mutates x87 state at its command edge, so this
            // is a no-bus write-permission sweep.  The page-cross phase holds
            // f_step until both pages of this beat have passed.
            if (fp_store_probe_advance &&
                (fp_store_probe_second || !fp_store_probe_cross)) begin
              if ((q_f_mbytes<=4'd4) ||
                  (q_f_mbytes==4'd8 && f_step==4'd1) ||
                  (q_f_mbytes==4'd10 && f_step==4'd2)) begin
                f_step<=4'd0; state<=S_FEXEC;
                if (fp_shared_store_probe_cmd && fp_shared_cmd_valid &&
                    fp_shared_cmd_ready) begin
                  // Command acceptance is irrevocable only after the final
                  // probe.  This response-producing store keeps its normal
                  // ordered wait and cannot retire from the probe edge.
                  state<=S_FP_SHARED_WAIT;
                end
              end else f_step<=f_step+4'd1;
            end
          end else
`endif
          if (mem_ack) begin
`ifdef VEN_FP_LOAD64
            // The optional high half belongs to this same registered, complete
            // resident-line response.  fp_load64_take proves the entire operand
            // was checked and stays in one translated page.  MMIO, crossings,
            // partial fills and debug-active instructions keep both old beats.
            if (fp_load64_take) begin
              f_mem80[63:0] <= {bus_rdata_hi, mem_rdata};
            end else
`endif
            begin
              unique case (f_step)
                4'd0: f_mem80[31:0]  <= mem_rdata;
                4'd1: f_mem80[63:32] <= mem_rdata;
                default: f_mem80[79:64] <= mem_rdata[15:0];
              endcase
            end
            // total words needed: m16/m32->1, m64->2, m80->3
            if (fp_load64_take || (q_f_mbytes<=4'd4) ||
                (q_f_mbytes==4'd8 && f_step==4'd1) ||
                (q_f_mbytes==4'd10 && f_step==4'd2)) begin
              f_step<=4'd0; state<=S_FEXEC;
`ifdef VEN_FP_SHARED
              if (fp_shared_load_cmd && fp_shared_cmd_valid && fp_shared_cmd_ready) begin
                if (fp_shared_accept_retire) begin
                  eip<=next_eip; retire_valid<=1'b1; x87_touched_r<=1'b1;
                  state<=S_PIPE;
                end else state<=S_FP_SHARED_WAIT;
`ifndef SYNTHESIS
                if (ven_fpdirectlog_en)
                  $display("[FPLOADCMD] ACCEPT cyc=%0d pc=%08x bytes=%0d immediate=%0b",
                           core_cyc, q_pc, q_f_mbytes, fp_shared_accept_retire);
`endif
              end
`endif
            end else f_step<=f_step+4'd1;
          end
        end
