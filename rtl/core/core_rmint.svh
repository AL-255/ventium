// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/core_rmint.svh — RAW case-arm text `included inside core.sv's always_ff
// `unique case (state)`. F3 REAL-MODE (PE=0) IVT interrupt delivery + IRET, the
// firmware/BIOS path (INT 10h/13h/16h/21h). Pure real mode only — V86 and
// protected mode keep the 8-byte-gate S_INT_* / S_IRET path (core_int_deliver.svh /
// core_iret.svh). The IVT is 256 four-byte {offset,selector} entries at idt_base
// (0:0 at reset, relocatable by LIDT).
        // -------------------------------------------------------------------
        // S_RMINT_RD: read the 4-byte IVT entry for int_vec — {selector[31:16],
        // offset[15:0]} @ idt_base + vec*4 (one beat). Latch the new CS:IP.
        // -------------------------------------------------------------------
        S_RMINT_RD: begin
          if (mem_ack) begin
            int_gate_off <= {16'd0, mem_rdata[15:0]};   // new IP
            int_gate_sel <= mem_rdata[31:16];            // new CS selector
            int_step     <= 4'd0;
            state        <= S_RMINT_PUSH;
          end
        end

        // -------------------------------------------------------------------
        // S_RMINT_PUSH: descending 16-bit push of FLAGS, CS, return IP (the bus
        // driver supplies the addr/data per beat). On the 3rd beat: drop SP by 6,
        // load CS (base=sel<<4) + EIP from the IVT entry, clear IF/TF (real-mode
        // interrupt also clears RF/AC — 0 in a real-mode firmware), and retire ONCE
        // stamped at the INT instruction's PC.
        // -------------------------------------------------------------------
        S_RMINT_PUSH: begin
          if (mem_ack) begin
            if (int_step != 4'd2) int_step <= int_step + 4'd1;
            else begin
              gpr[R_ESP]      <= gpr[R_ESP] - 32'd6;
              seg_sel [SG_CS] <= int_gate_sel;
              seg_base[SG_CS] <= {12'd0, int_gate_sel, 4'd0};
              seg_attr[SG_CS] <= 8'h9B;
              eip             <= int_gate_off;
              eflags          <= eflags & ~32'h0005_0300;   // clear IF|TF|RF|AC
              q_pc            <= int_src_pc;                 // stamp the INT's PC
              retire_valid    <= 1'b1;
              int_step        <= 4'd0;
              state           <= S_PIPE;
            end
          end
        end

        // -------------------------------------------------------------------
        // S_RMIRET: ascending 16-bit pop of IP, CS, FLAGS. On the 3rd beat: load
        // CS (base=sel<<4) + EIP, restore the low-16 EFLAGS (settable bits incl IF),
        // bump SP by 6, and retire stamped at the IRET's PC.
        // -------------------------------------------------------------------
        S_RMIRET: begin
          if (mem_ack) begin
            unique case (int_step)
              4'd0: begin iret_eip <= {16'd0, mem_rdata[15:0]}; int_step <= 4'd1; end
              4'd1: begin iret_cs  <= mem_rdata[15:0];          int_step <= 4'd2; end
              default: begin
                seg_sel [SG_CS] <= iret_cs;
                seg_base[SG_CS] <= {12'd0, iret_cs, 4'd0};
                seg_attr[SG_CS] <= 8'h9B;
                eip             <= iret_eip;
                // 16-bit IRET restores the low-16 settable flags (CF..NT incl IF/IOPL);
                // bit1 reads 1; EFLAGS[31:16] (VM/AC/ID/...) are untouched by a 16-bit pop.
                eflags          <= {eflags[31:16], ((mem_rdata[15:0] & 16'h7FD5) | 16'h0002)};
                gpr[R_ESP]      <= gpr[R_ESP] + 32'd6;
                q_pc            <= int_src_pc;
                retire_valid    <= 1'b1;
                int_step        <= 4'd0;
                state           <= S_PIPE;
              end
            endcase
          end
        end
