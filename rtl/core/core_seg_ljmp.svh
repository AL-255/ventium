// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/core_seg_ljmp.svh — RAW case-arm text `included inside core.sv's
// always_ff `unique case (state)` (R2 modularization). NOT a standalone unit
// (no module/always wrapper); pasted verbatim at the original FSM site, netlist
// identical. Covers the M2S.1 descriptor-table reads + protected-mode far jmp:
//   S_LGDT (LGDT/LIDT pseudo-descriptor read), S_SEGLD (MOV-to-Sreg desc load),
//   S_LJMP (far JMP CS desc load / task-switch entry).
        // -------------------------------------------------------------------
        // M2S.1 — S_LGDT: read the 6-byte LGDT/LIDT pseudo-descriptor (limit[2] +
        // base[4]) from memory at q_ea via two word reads, then load GDTR/IDTR.
        // beat 0: word @q_ea   = { base[15:0], limit[15:0] }
        // beat 1: word @q_ea+4 = { ........., base[31:16] }
        // -------------------------------------------------------------------
        S_LGDT: begin
          if (mem_ack) begin
            if (!seg_step) begin
              gdt_lo <= mem_rdata;     // limit[15:0] | base[15:0]
              seg_step <= 1'b1;
            end else begin
              // base[31:16] is the low half of the second word.
              logic [31:0] nb; logic [15:0] nl;
              nl = gdt_lo[15:0];
              nb = {mem_rdata[15:0], gdt_lo[31:16]};
              if (q_sysop==SYS_LGDT) begin gdt_base<=nb; gdt_limit<=nl; end
              else begin idt_base<=nb; idt_limit<=nl; end
              eip<=next_eip; retire_valid<=1'b1; state<=S_PIPE; seg_step<=1'b0;
            end
          end
        end

        // -------------------------------------------------------------------
        // M2S.1 — S_SEGLD: PROTECTED-mode MOV Sreg, r16. Read the 8-byte GDT
        // descriptor at gdt_base + (sel & ~7) via two word reads, decode the
        // hidden base/limit/attr, and load the segment. The protection DECISION
        // (present/type/DPL + null-SS/CS rules, CPL=cpl_r, RPL=sel[1:0]) is
        // genuinely COMPUTED here via seg_load_fault(); fault *delivery* through
        // the IDT is M2S.3, so a raised decision can only HALT loudly (it never
        // silently mis-loads). The pseg corpus loads only clean descriptors, so
        // the decision is always "no fault" and this never halts — but a wrong/
        // absent/mis-typed descriptor WOULD now be caught here (spec §3).
        // -------------------------------------------------------------------
        S_SEGLD: begin
          if (mem_ack) begin
            logic [15:0] msel;
            logic        mnull;
            msel  = gpr[q_src_reg][15:0];
            mnull = (msel[15:3] == 13'd0);
            // M2S.3 — selector index past the GDT limit -> #GP(13) carrying the
            // selector as the error code (the descriptor read was out of bounds;
            // we discard it). A NULL selector (idx 0) skips the limit check (a
            // null load into DS/ES/FS/GS is legal). Checked on beat 0 so we
            // deliver before consuming the (garbage) descriptor.
            if (!seg_step && !mnull &&
                ({16'd0, msel[15:3], 3'd0} + 32'd7 > {16'd0, gdt_limit})) begin
              start_fault(8'd13, 1'b1, {16'd0, msel}, q_pc);
              seg_step<=1'b0;
            end else if (!seg_step) begin gdt_lo<=mem_rdata; seg_step<=1'b1; end
            else begin
              logic [63:0] desc;
              logic [7:0]  attr;
              logic        is_ss;
              desc  = {mem_rdata, gdt_lo};
              attr  = desc_attr(desc);
              is_ss = (q_sys_sreg == 3'(SG_SS));
              // PROTECTION DECISION (M2S.1) -> now DELIVERED through the IDT (M2S.3).
              if (seg_load_fault(1'b0, is_ss, msel, attr, cpl_r)) begin
                // #NP/#SS/#GP — error code = selector (idx<<3 | TI | EXT=0).
                start_fault(seg_fault_vec(1'b0, is_ss, msel, attr), 1'b1,
                            {16'd0, msel[15:3], 3'd0}, q_pc);
                seg_step<=1'b0;
              end else begin
                seg_sel  [q_sys_sreg] <= msel;
                seg_base [q_sys_sreg] <= desc_base(desc);
                seg_limit[q_sys_sreg] <= desc_limit(desc);
                seg_attr [q_sys_sreg] <= attr;
                eip<=next_eip; retire_valid<=1'b1; state<=S_PIPE; seg_step<=1'b0;
              end
            end
          end
        end

        // -------------------------------------------------------------------
        // M2S.1 — S_LJMP: PROTECTED-mode far JMP. Read the CS descriptor from the
        // GDT, load CS.sel/base/limit/attr, derive CPL=CS.RPL, and set EIP to the
        // jump offset. This is the second half of the real->protected transition
        // (the CR0.PE write retired separately): its own retire record, switching
        // to 32-bit PM. The CS protection DECISION (present/code-type/null) is
        // COMPUTED via seg_load_fault(); delivery is M2S.3 (a raised decision
        // HALTs). The pseg far jump targets a present 32-bit code seg => no fault.
        // -------------------------------------------------------------------
        S_LJMP: begin
          if (mem_ack) begin
            if (!seg_step) begin gdt_lo<=mem_rdata; seg_step<=1'b1; end
            else begin
              logic [63:0] desc;
              logic [7:0]  attr;
              desc = {mem_rdata, gdt_lo};
              attr = desc_attr(desc);
              // M2S.4b — a far JMP whose target descriptor is a SYSTEM descriptor
              // (S=0) is a HARDWARE TASK SWITCH when it names an available (type
              // 0x9) or busy (0xB) 32-bit TSS: SAVE the outgoing state into the
              // current TSS, LOAD the incoming state from the new TSS, reload the
              // segments, toggle the descriptor busy bits, set the new TR + CR0.TS,
              // and resume the incoming task. A JMP does NOT set NT / the back-link
              // (only a CALL/interrupt-task-gate does — see the deferral note below).
              // Capture the new TSS descriptor (base/limit/sel/access) here, then
              // run the S_TSW_* micro-sequence. Other system descriptors (task gate
              // 0x5, call gate, LDT, ...) are not in the corpus -> HALT cleanly.
              if (!desc_s(attr)) begin
                if (desc_present(attr) &&
                    (desc_type(attr) == 4'h9 || desc_type(attr) == 4'hB)) begin
                  // HARDWARE TASK SWITCH to a 32-bit TSS.
                  tsw_new_base  <= desc_base(desc);
                  tsw_new_limit <= desc_limit(desc);
                  tsw_new_sel   <= q_ljmp_sel;
                  tsw_new_attr  <= attr | 8'h02;     // incoming busy bit set (9->B)
                  tsw_save_eip  <= next_eip;          // outgoing resume EIP (after jmp)
                  tsw_step      <= 5'd0;
                  seg_step      <= 1'b0;
                  state         <= S_TSW_SAVE;
                end else begin
                  state<=S_HALT; seg_step<=1'b0;     // other system descriptors
                end
              end else if (seg_load_fault(1'b1, 1'b0, q_ljmp_sel, attr, cpl_r)) begin
                // #GP/#NP on a far-jump CS load -> DELIVER (error code = selector).
                start_fault(seg_fault_vec(1'b1, 1'b0, q_ljmp_sel, attr), 1'b1,
                            {16'd0, q_ljmp_sel[15:3], 3'd0}, q_pc);
                seg_step<=1'b0;
              end else begin
                seg_sel  [SG_CS] <= q_ljmp_sel;
                seg_base [SG_CS] <= desc_base(desc);
                seg_limit[SG_CS] <= desc_limit(desc);
                seg_attr [SG_CS] <= attr;
                cpl_r    <= q_ljmp_sel[1:0];  // CPL = CS.RPL after a far jump
                cs_d <= desc[54];   // D/B bit: 1 => 32-bit default operand/addr size
                eip<=q_ljmp_off; retire_valid<=1'b1; state<=S_PIPE; seg_step<=1'b0;
              end
            end
          end
        end

