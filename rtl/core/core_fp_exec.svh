// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/core_fp_exec.svh — RAW case-arm text `included inside core.sv's always_ff
// `unique case (state)` (R2 modularization). NOT a standalone unit (no module/
// always wrapper); pasted verbatim at the original FSM site, netlist identical.
// Covers the x87 execute/commit arms:
//   S_FEXEC (x87 compute + commit / hand off a store), S_FSTORE (store seq).
        // -------------------------------------------------------------------
        // S_FEXEC: x87 execute + commit. Updates fpr/ftop/fstat/fptag, sets
        // x87_touched_r, and either retires (advance EIP) or hands a memory
        // store to S_FSTORE. All arithmetic is bit-exact vs QEMU softfloat for
        // the corpus's normal operands (fpu_x87_pkg).
        // -------------------------------------------------------------------
        S_FEXEC: begin
          // R2: the x87 ARCHITECTURAL STATE update for S_FEXEC (the fpr/ftop/
          // fstat/fptag NBA writes that used to live in this case) is now driven
          // onto u_fpu_state's write ports by the fp_we_* combinational driver
          // near the module instance. That driver re-derives THIS exact arm
          // (state==S_FEXEC && !f_pc_bad) and the same per-fxop value computation
          // (via the same fpu_x87_pkg calls: f_eval/fconst/apply_cmp/fcom_codes/
          // fxam_codes/fx_sqrt/f_mem_as_*/f_arith_fstat + the fstore sticky flags),
          // so the state mutation is byte-identical. This block keeps ONLY the
          // SPINE control: the f_pc_bad->S_HALT gate, the f_do_store/f_do_retire
          // FSM transition, and the FNSTSW_AX cross-leaf gpr[EAX] write.
          logic f_do_store, f_do_retire;
          logic f_pc_bad;        // arithmetic requested under non-64-bit PC
          logic f_is_arith;
          f_do_store=1'b0; f_do_retire=1'b1;

          // Precision control (PC = fctrl[9:8]) other than 11 (64-bit extended)
          // is a Tier-3 deferral: the datapath only implements full extended
          // precision, so rather than silently mis-rounding we HALT loudly on an
          // arithmetic op requested under PC != 11. (Data movement / compares /
          // constants are precision-independent and proceed normally.)
          f_is_arith = (q_fxop==FX_AR_ST0_STI) || (q_fxop==FX_AR_STI_ST0) ||
                       (q_fxop==FX_AR_M32)     || (q_fxop==FX_AR_M64)     ||
                       (q_fxop==FX_AR_I16)     || (q_fxop==FX_AR_I32)     ||
                       (q_fxop==FX_FSQRT);
          f_pc_bad = f_is_arith && (fctrl[9:8] != 2'b11);
          if (f_pc_bad) begin
            state<=S_HALT;
          end else
          unique case (q_fxop)
            // ---- memory stores: defer to S_FSTORE ----
            // The store VALUE and its exception flags depend only on ST0/fctrl
            // (stable across the store beats); the sticky PE/IE latch into fstat
            // is driven by fp_we_* at this dispatch clock. FST m80 / FNSTCW /
            // FNSTSW m16 are exact (flags stay 0).
            FX_FST_M32, FX_FST_M64, FX_FST_M80,
            FX_FIST_M16, FX_FIST_M32, FX_FIST_M64,
            FX_FBSTP,
            FX_FNSTCW, FX_FNSTSW_M: begin
              f_do_store=1'b1; f_do_retire=1'b0;
            end
            // ---- FNSTSW AX (writes AX, no memory) — cross-leaf: reads fstat/ftop
            // from u_fpu_state and writes the integer file (stays in the spine).
            FX_FNSTSW_AX: begin
              gpr[R_EAX] <= {gpr[R_EAX][31:16],
                             (fstat & ~16'h3800) | ({13'd0,ftop}<<11)};
            end
            default: ;   // all other fxops mutate only FP state (driven by fp_we_*)
          endcase

          // f_pc_bad already routed to S_HALT above (no retire); only commit the
          // EIP/retire when we actually executed the op.
          if (!f_pc_bad) begin
`ifdef VEN_SRT_ITER
            // normal-operand FDIV/FSQRT: hand off to the iterative SRT engine and
            // wait in S_FP_BUSY (the result commits there via the fp_we_* driver).
            if (fp_iter_go) begin
              state<=S_FP_BUSY;
            end else
`endif
            if (f_do_retire) begin
`ifdef VEN_TRANSCENDENTAL
              // Transcendentals (#11): run the iterative engine first
              // (S_TRSC_BUSY), then commit + retire there. F2XM1 overwrites ST0
              // in place; FPATAN writes ST1 and pops (commit driver distinguishes).
              if (q_fxop==FX_F2XM1 || q_fxop==FX_FPATAN) begin
                state<=S_TRSC_BUSY;
              end else begin
`endif
`ifdef VEN_BCD_ITER
              // FBLD: run the iterative packed-BCD->FP engine first (S_FBLD_BUSY),
              // then push the floatx80 result + retire there (the 18-chained-*10
              // fx_bcd_to_fx was the worst LOGIC path under +VEN_FP_PIPE).
              if (q_fxop==FX_FBLD) begin
                state<=S_FBLD_BUSY;
              end else begin
`endif
`ifdef VEN_FP_PIPE
              // +VEN_FP_PIPE: a slow-arm arith that CAPTURED this clock (fp_pipe_cap)
              // defers its commit+retire to S_FEXEC_EX (the registered-operand
              // f_eval -> we_wabs path), splitting the f_mem80->f_eval->fpr cone.
              // Non-arith retiring ops (compares / FNSTSW_AX / loads) committed
              // same-cycle and retire here as before.
              if (fp_pipe_cap) state<=S_FEXEC_EX;
              else begin
                eip<=next_eip; retire_valid<=1'b1; x87_touched_r<=1'b1; state<=S_PIPE;
              end
`else
              eip<=next_eip; retire_valid<=1'b1; x87_touched_r<=1'b1; state<=S_PIPE;
`endif
`ifdef VEN_BCD_ITER
              end
`endif
`ifdef VEN_TRANSCENDENTAL
              end
`endif
            end else begin
`ifdef VEN_BCD_ITER
              // FBSTP: run the iterative FP->BCD engine first (S_BCD_BUSY) so the
              // 18-chained-/10 conversion is multi-cycle, then store.
              if (q_fxop==FX_FBSTP) state<=S_BCD_BUSY;
              else begin state<=S_FSTORE; f_step<=4'd0; end
`else
              state<=S_FSTORE; f_step<=4'd0;
`endif
            end
          end
        end

`ifdef VEN_FP_PIPE
        // S_FEXEC_EX: slow-arm FP-execute 2nd stage. The result was computed from
        // the REGISTERED fpp_* operands and is written to fpr via we_wabs (which
        // the fp_we_* driver asserts unconditionally while fpp_valid) THIS clock —
        // the same edge we retire on, so the per-retire architectural state is
        // exact. eip/q_fxop are unchanged since S_FEXEC (we did not retire there),
        // so next_eip is still correct.
        S_FEXEC_EX: begin
          eip<=next_eip; retire_valid<=1'b1; x87_touched_r<=1'b1; state<=S_PIPE;
        end
`endif

`ifdef VEN_BCD_ITER
        // S_BCD_BUSY: wait for the iterative FP->packed-BCD engine; latch its
        // {ie,pe,bcd} store value (consumed by fstore_val + the fstat sticky in the
        // fp_we_* driver), then run the store (S_FSTORE).
        S_BCD_BUSY: begin
          if (eng_bcd_done) begin
            fbcd_result_q <= eng_bcd_result;
            state<=S_FSTORE; f_step<=4'd0;
          end
        end

        // S_FBLD_BUSY: wait for the iterative packed-BCD->floatx80 engine. The push
        // of eng_fbld_result is driven onto u_fpu_state's we_push port by the
        // fp_we_* driver on THIS (done) clock; here we retire + advance EIP in the
        // same clock, so the per-retire architectural state is exact.
        S_FBLD_BUSY: begin
          if (eng_fbld_done) begin
            eip<=next_eip; retire_valid<=1'b1; x87_touched_r<=1'b1; state<=S_PIPE;
          end
        end
`endif

`ifdef VEN_TRANSCENDENTAL
        // S_TRSC_BUSY: wait for the iterative x87 transcendental engine (F2XM1).
        // The floatx80 result + fstat PE are driven onto u_fpu_state's we_top /
        // we_fstat ports by the fp_we_* driver on the engine's `done` clock; here
        // we retire + advance EIP the same clock (per-retire arch state exact).
        S_TRSC_BUSY: begin
          if (eng_trsc_done) begin
            eip<=next_eip; retire_valid<=1'b1; x87_touched_r<=1'b1; state<=S_PIPE;
          end
        end
`endif

`ifdef VEN_SRT_ITER
        // -------------------------------------------------------------------
        // S_FP_BUSY: wait for the iterative SRT FDIV/FSQRT engine. The 80-bit
        // result + fstat are driven onto u_fpu_state by the fp_we_* driver on the
        // engine's `done` clock; here we only retire + advance EIP (mirrors the
        // S_FEXEC retire). The busy-wait serialises, so a dependent next insn
        // reads the committed result correctly.
        // -------------------------------------------------------------------
        S_FP_BUSY: begin
          if (fp_iter_done) begin
            eip<=next_eip; retire_valid<=1'b1; x87_touched_r<=1'b1; state<=S_PIPE;
          end
        end
`endif

        // -------------------------------------------------------------------
        // S_FSTORE: write the x87 store operand to memory over 1..3 bus beats,
        // then (for FSTP/FISTP) pop, advance EIP and retire. Memory contents are
        // not gate-compared, but stores are implemented faithfully.
        // -------------------------------------------------------------------
        S_FSTORE: begin
          if (mem_ack) begin
            // words needed: m16/cw/sw->1, m32->1, m64->2, m80->3
            if ((q_f_mbytes<=4'd4) ||
                (q_f_mbytes==4'd8 && f_step==4'd1) ||
                (q_f_mbytes==4'd10 && f_step==4'd2)) begin
              // last beat: the POP (fptag[ftop]<=1; ftop++) for FSTP/FISTP is
              // driven onto u_fpu_state's we_pop port by fp_we_* (which re-derives
              // this exact last-beat condition). Here we only retire + advance EIP.
              eip<=next_eip; retire_valid<=1'b1; x87_touched_r<=1'b1; state<=S_PIPE; f_step<=4'd0;
            end else f_step<=f_step+4'd1;
          end
        end
