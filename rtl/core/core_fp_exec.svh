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
            if (f_do_retire) begin
              eip<=next_eip; retire_valid<=1'b1; x87_touched_r<=1'b1; state<=S_PIPE;
            end else begin
              state<=S_FSTORE; f_step<=4'd0;
            end
          end
        end

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
