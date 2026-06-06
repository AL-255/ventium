// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/core_smm.svh — RAW case-arm text `included inside core.sv's always_ff
// `unique case (state)` (R2 modularization). NOT a standalone unit: it has no
// module/always wrapper and is textually pasted into the FSM at the original
// site, so the netlist is identical. Covers the M2S.5 SMM arms:
//   S_SMI_SAVE (SMI# entry: write the P5 save-state map, then ENTER SMM)
//   S_RSM      (read the save map back, COMMIT restored arch state, resume)
// Block-local `automatic` vars (none here) and the SG_/SMM_LAST/NUM_* params
// live in core.sv module scope, visible after textual inclusion.
        // ===================================================================
        // M2S.5 — SMM ENTRY (S_SMI_SAVE) + RSM (S_RSM). Gated sys_mode.
        //
        // SMI# entry: write the CPU state to the SMRAM save-state map (P5 Table
        // 20-1 offsets @ SMBASE+0x8000+offset), one dword per beat (the bus arm
        // drives the address+data per smm_step). After the last beat ENTER SMM:
        //   CR0 PE/PG/EM/TS cleared, CS sel=SMBASE>>4 base=SMBASE limit big,
        //   DS/ES/FS/GS/SS bases 0 limits big, EIP=0x8000, smm_active=1, and
        //   retire ONCE (q_pc = the resume EIP = the interrupted instruction; the
        //   post-state row is the SMM-handler entry context). The SMM handler then
        //   runs real-mode-like flat and ends with RSM.
        // RSM: read the whole save map back into rsm_* (one dword per beat), then
        //   on the last beat COMMIT the restored architectural state in a single
        //   clock (honoring a handler-modified SMBASE/resume-EIP) and resume.
        //
        // SMM_LAST = the final beat index (0-based). Beats:
        //   0..5  CR0,CR3,CR4,CR2,EFLAGS,EIP        6..13 EAX..EDI (gpr[0..7])
        //   14..19 CS,SS,DS,ES,FS,GS selectors      20..25 seg base[0..5]
        //   26..31 seg limit[0..5]                  32..37 seg attr[0..5]
        //   38 GDT base  39 IDT base  40 {gdtl,idtl}
        //   41 SMBASE slot  42 SMM rev id  43 auto-HALT  44 {cs_d,cpl}
        // ===================================================================
        S_SMI_SAVE: begin
          if (mem_ack) begin
            if (smm_step == SMM_LAST) begin
              // ---- last save beat: ENTER SMM ----
              // CR0: clear PE(0)/EM(2)/TS(3)/PG(31). (NE/others left; the corpus
              // CR0 here is 0x60000011 -> 0x60000010 after clearing PE.)
              creg0 <= creg0 & ~32'h8000_000D;
              // CS: real-mode-like, base = SMBASE, selector = SMBASE>>4, big limit.
              seg_sel  [SG_CS] <= smbase[19:4];
              seg_base [SG_CS] <= smbase;
              seg_limit[SG_CS] <= 32'hFFFF_FFFF;   // SMM uses 4 GiB segment limits
              seg_attr [SG_CS] <= 8'h93;            // present R/W (SMM flat data-like)
              // DS/ES/FS/GS/SS: base 0, big limit (real-mode-like flat).
              for (int s = 1; s < NUM_SEG; s++) begin
                seg_sel  [s] <= 16'd0;
                seg_base [s] <= 32'd0;
                seg_limit[s] <= 32'hFFFF_FFFF;
                seg_attr [s] <= 8'h93;
              end
              cs_d      <= 1'b0;          // SMM default operand/addr size = 16-bit
              cpl_r     <= 2'd0;          // SMM runs at CPL0
              eip       <= 32'h0000_8000; // SMM entry point = SMBASE + 0x8000
              smm_active<= 1'b1;
              smm_step  <= 6'd0;
              // retire the SMI-entry: q_pc = the interrupted insn (the resume EIP).
              q_pc         <= smm_resume_eip;
              retire_valid <= 1'b1;
              state        <= S_PIPE;
            end else begin
              smm_step <= smm_step + 6'd1;
            end
          end
        end

        S_RSM: begin
          if (mem_ack) begin
            // latch each read-back dword into the matching rsm_* holding reg.
            unique case (smm_step)
              6'd0:  rsm_cr0    <= mem_rdata;
              6'd1:  rsm_cr3    <= mem_rdata;
              6'd2:  rsm_cr4    <= mem_rdata;
              6'd3:  rsm_cr2    <= mem_rdata;
              6'd4:  rsm_eflags <= mem_rdata;
              6'd5:  rsm_eip    <= mem_rdata;
              6'd6,6'd7,6'd8,6'd9,6'd10,6'd11,6'd12,6'd13:
                     rsm_gpr[3'(smm_step - 6'd6)]  <= mem_rdata;
              6'd14,6'd15,6'd16,6'd17,6'd18,6'd19:
                     rsm_sel[3'(smm_step - 6'd14)] <= mem_rdata[15:0];
              6'd20,6'd21,6'd22,6'd23,6'd24,6'd25:
                     rsm_base[3'(smm_step - 6'd20)]  <= mem_rdata;
              6'd26,6'd27,6'd28,6'd29,6'd30,6'd31:
                     rsm_limit[3'(smm_step - 6'd26)] <= mem_rdata;
              6'd32,6'd33,6'd34,6'd35,6'd36,6'd37:
                     rsm_attr[3'(smm_step - 6'd32)]  <= mem_rdata[7:0];
              6'd38: rsm_gdtb   <= mem_rdata;
              6'd39: rsm_idtb   <= mem_rdata;
              6'd40: begin rsm_gdtl <= mem_rdata[15:0]; rsm_idtl <= mem_rdata[31:16]; end
              6'd41: rsm_smbase <= mem_rdata;
              6'd42: ;  // SMM revision id (read-only; not restored)
              6'd43: ;  // auto-HALT restart slot (no HALT in the corpus; ignored)
              // beat 44 = {cs_d, cpl}: committed directly from mem_rdata in the
              // final-beat block below (a latched copy here would be one clock late).
              default: ;
            endcase
            if (smm_step == SMM_LAST) begin
              // ---- last restore beat: COMMIT the restored architectural state ---
              // honoring a handler-modified resume EIP + SMBASE (both writeable).
              creg0   <= rsm_cr0;  creg3 <= rsm_cr3;  creg4 <= rsm_cr4;  creg2 <= rsm_cr2;
              eflags  <= rsm_eflags;
              eip     <= rsm_eip;
              for (int g = 0; g < NUM_GPR; g++) gpr[g] <= rsm_gpr[g];
              for (int s = 0; s < NUM_SEG; s++) begin
                seg_sel  [s] <= rsm_sel  [s];
                seg_base [s] <= rsm_base [s];
                seg_limit[s] <= rsm_limit[s];
                seg_attr [s] <= rsm_attr [s];
              end
              gdt_base <= rsm_gdtb; idt_base <= rsm_idtb;
              gdt_limit<= rsm_gdtl; idt_limit<= rsm_idtl;
              smbase   <= rsm_smbase;     // handler-relocatable SMBASE
              // {cs_d, cpl} are committed straight from the freshly-read word on
              // THIS final beat (the read-back case above intentionally does NOT
              // stage beat 44 in a holding reg). A latched copy would not be
              // visible until the next clock — which never comes — leaving the
              // resumed mainline in 16-bit operand/address mode (stale cs_d) and
              // mis-decoding its 32-bit insns, so the commit must read mem_rdata.
              cs_d     <= mem_rdata[0];
              cpl_r    <= mem_rdata[2:1];
              smm_active<= 1'b0;          // leave SMM
              smm_step <= 6'd0;
              // retire the RSM: q_pc = the RSM insn; the post-state row is the
              // RESUMED interrupted context (its restored GPRs/segs/CRx/EIP).
              q_pc         <= int_src_pc;
              retire_valid <= 1'b1;
              state        <= S_PIPE;
            end else begin
              smm_step <= smm_step + 6'd1;
            end
          end
        end
