// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/core_load.svh — RAW case-arm text `included inside core.sv's always_ff
// `unique case (state)` (R2 modularization). NOT a standalone unit (no module/
// always wrapper); pasted verbatim at the original FSM site, netlist identical.
// Covers the data-load arms:
//   S_LOAD (memory source / RMW dst / [ESI]/[EDI]), S_LOAD2 (CMPS 2nd operand),
//   S_FLOAD (x87 memory operand read).
        S_LOAD: begin
          if (mem_ack) begin
            mem_load_data<=mem_rdata;
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
              if (la[1:0] != 2'b00)      pen = pen + P5_MISALIGN;
              pending_mem_pen <= pen;
            end
            if (q_kind==K_STR && q_st==ST_CMPS) state<=S_LOAD2;
            else state<=S_EXEC;
          end
        end
        S_LOAD2: begin
          if (mem_ack) begin
            mem_load_data2<=mem_rdata; state<=S_EXEC;
            // CMPS second operand [EDI] is also a data load -> D-cache access.
            // dc_lu_hit/dc_acc_* are driven to gpr[R_EDI] this clock (S_LOAD2).
            if (cycle_mode) begin
              logic [6:0] pen; pen=7'd0;
              if (!dc_lu_hit)               pen = pen + P5_DMISS;
              if (gpr[R_EDI][1:0]!=2'b00)   pen = pen + P5_MISALIGN;
              pending_mem_pen <= pen;
            end
          end
        end

        // -------------------------------------------------------------------
        // S_FLOAD: read the x87 memory operand (m16/m32 = 1 word, m64 = 2,
        // m80 = 3) into f_mem80, LSB-first. Bus addresses q_ea + 4*f_step.
        // -------------------------------------------------------------------
        S_FLOAD: begin
          if (mem_ack) begin
            unique case (f_step)
              4'd0: f_mem80[31:0]  <= mem_rdata;
              4'd1: f_mem80[63:32] <= mem_rdata;
              default: f_mem80[79:64] <= mem_rdata[15:0];
            endcase
            // total words needed: m16/m32->1, m64->2, m80->3
            if ((q_f_mbytes<=4'd4) ||
                (q_f_mbytes==4'd8 && f_step==4'd1) ||
                (q_f_mbytes==4'd10 && f_step==4'd2)) begin
              f_step<=4'd0; state<=S_FEXEC;
            end else f_step<=f_step+4'd1;
          end
        end
