// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/core_bus_driver.svh — RAW MODULE-SCOPE text `included by core.sv (R2
// modularization). NOT a standalone unit (no module wrapper): it is the single
// combinational bus-request driver `always_comb` (the per-state mem_req/mem_addr/
// mem_we/mem_wdata/mem_wstrb `unique case (state)` PLUS the paging post-translate
// linear->physical tail), pasted verbatim at module scope at its original site,
// so the netlist is identical. All referenced signals/functions (mem_xlate,
// smm_off, cur_is_d, the SG_*/state enums) live in core.sv module scope.
  // ===========================================================================
  // Bus request generation (single combinational driver). Each arm computes the
  // LINEAR address into mem_addr; the post-stage below translates it.
  // ===========================================================================
  always_comb begin
    mem_req=1'b0; mem_we=1'b0; mem_addr=32'd0; mem_wdata=32'd0; mem_wstrb=4'd0;
    unique case (state)
      S_FETCH: begin mem_req=1'b1; mem_addr=flin+{27'd0,fetch_word,2'b00}; end
      S_PF:    begin mem_req=1'b1; mem_addr={pf_fill_addr[31:5],5'd0}+{27'd0,pf_word,2'b00}; end
      S_PIPE:  begin
        // a register-base load issued this clock reads [base] combinationally.
        // M2S.1: add the DS base (0 in user mode / flat PM).
        if (pipe_load_req) begin mem_req=1'b1; mem_addr=seg_base[SG_DS]+gpr[pipe_load_base]; end
        // I-cache miss detected this clock: fetch the fill line's WORD 0 NOW so the
        // detection clock is productive (finding [med] I-miss off-by-one). S_PF then
        // fetches words 1..7. mem_req for the load and the fill are mutually
        // exclusive: pf_miss => !pipe_bytes_ok => pipe_load_req is false.
        else if (pf_miss) begin mem_req=1'b1; mem_addr={pf_miss_fa[31:5],5'd0}; end
      end
      S_LOAD: begin
        mem_req=1'b1;
        if (q_is_pop || q_ct==CT_RETN || q_ct==CT_RETN_IMM ||
            (q_kind==K_STKMISC && q_sm==SM_POPF))
          mem_addr=dbase+gpr[R_ESP];
        else if (q_kind==K_STKMISC && q_sm==SM_LEAVE)
          mem_addr=dbase+gpr[R_EBP];     // LEAVE reads [EBP] (the saved frame ptr)
        else if (q_kind==K_STR) begin
          // load order: movs/lods/cmps -> [ESI]; scas -> [EDI]
          if (q_st==ST_SCAS) mem_addr=dbase+gpr[R_EDI];
          else               mem_addr=dbase+gpr[R_ESI];
        end else mem_addr=opbase+q_ea;   // M7.1: opbase==dbase except a proxy
                                          // gs-override indirect-call operand read
      end
      S_LOAD2: begin mem_req=1'b1; mem_addr=dbase_edi+gpr[R_EDI]; end
      // M2S.1 — LGDT/LIDT 6-byte read + PM descriptor fetches.
      S_LGDT: begin mem_req=1'b1; mem_addr=dbase+q_ea+{29'd0,seg_step,2'b00}; end
      S_SEGLD: begin mem_req=1'b1;
        mem_addr=gdt_base+{16'd0,gpr[q_src_reg][15:3],3'd0}+{29'd0,seg_step,2'b00};
      end
      S_LJMP: begin mem_req=1'b1;
        mem_addr=gdt_base+{16'd0,q_ljmp_sel[15:3],3'd0}+{29'd0,seg_step,2'b00};
      end
      // M9.5 — real-mode far CALL: 2-beat descending push on SS:SP. beat 0 pushes CS
      // at [SS:SP-w], beat 1 pushes the return IP at [SS:SP-2w]. ESP is unchanged
      // until the S_LCALL commit, so BOTH beats reference the OLD ESP. Width q_w
      // (2 real-mode default / 4 under 0x66) selects the byte-strobe + the SP steps.
      S_LCALL: begin
        mem_req=1'b1; mem_we=1'b1; mem_wstrb=(q_w==3'd2)?4'b0011:4'b1111;
        if (!seg_step) begin
          mem_addr  = seg_base[SG_SS] + (gpr[R_ESP] - {28'd0,q_w});         // SP - w
          mem_wdata = {16'd0, seg_sel[SG_CS]};                             // push CS
        end else begin
          mem_addr  = seg_base[SG_SS] + (gpr[R_ESP] - {27'd0,q_w,1'b0});   // SP - 2w
          mem_wdata = next_eip;                                           // push ret IP
        end
      end
      // M9.5 — RETF: 2-beat ascending pop on SS:SP. beat 0 pops IP at [SS:SP], beat 1
      // pops CS at [SS:SP+w]. ESP is unchanged until the S_RETF commit.
      S_RETF: begin
        mem_req=1'b1;
        if (!seg_step) mem_addr = seg_base[SG_SS] + gpr[R_ESP];            // pop IP
        else           mem_addr = seg_base[SG_SS] + (gpr[R_ESP]+{28'd0,q_w}); // pop CS
      end
      S_FLOAD: begin
        mem_req=1'b1; mem_addr=dbase+q_ea + {26'd0, f_step, 2'b00};   // base + q_ea + 4*f_step
      end
      // M11b: env/state transfers — one full dword per wide beat (f_seq_step).
      S_FENV_ST: begin
        mem_req=1'b1; mem_we=1'b1; mem_wstrb=4'b1111;
        mem_addr = dbase+q_ea + {25'd0, f_seq_step, 2'b00};
        mem_wdata = fenv_image[f_seq_step*32 +: 32];
      end
      S_FENV_LD: begin
        mem_req=1'b1; mem_addr=dbase+q_ea + {25'd0, f_seq_step, 2'b00};
      end
      S_FSTORE: begin
        mem_req=1'b1; mem_we=1'b1;
        mem_addr = dbase+q_ea + {26'd0, f_step, 2'b00};
        // the m80 third beat writes only 2 bytes; all others write a full word.
        if (q_f_mbytes==4'd10 && f_step==4'd2) mem_wstrb=4'b0011;
        else if (q_f_mbytes==4'd2)             mem_wstrb=4'b0011;   // m16 (cw/sw/int16)
        else                                   mem_wstrb=4'b1111;
        unique case (f_step)
          4'd0: mem_wdata = fstore_val[31:0];
          4'd1: mem_wdata = fstore_val[63:32];
          default: mem_wdata = {16'd0, fstore_val[79:64]};
        endcase
      end
      S_STORE: begin
        mem_req=1'b1; mem_we=1'b1;
        if (q_kind==K_STR) begin
          // string store [EDI] uses ES.
          mem_wstrb=strb_of(q_w); mem_addr=dbase_edi+str_store_addr; mem_wdata=str_store_data;
        end else begin
          mem_wstrb=st_strb; mem_addr=dbase+st_addr; mem_wdata=st_data;
        end
      end
      S_USEQ: begin
        mem_req=1'b1;
        if (q_sm==SM_PUSHA) begin
          mem_we=1'b1; mem_wstrb=4'b1111;
          mem_addr=dbase+pusha_esp - (32'd4*({28'd0,step}+32'd1));
          unique case (step)
            4'd0: mem_wdata=gpr[R_EAX];
            4'd1: mem_wdata=gpr[R_ECX];
            4'd2: mem_wdata=gpr[R_EDX];
            4'd3: mem_wdata=gpr[R_EBX];
            4'd4: mem_wdata=pusha_esp;     // original ESP
            4'd5: mem_wdata=gpr[R_EBP];
            4'd6: mem_wdata=gpr[R_ESI];
            default: mem_wdata=gpr[R_EDI];
          endcase
        end else begin // POPA: read ascending from ESP
          mem_we=1'b0; mem_addr=dbase+gpr[R_ESP] + (32'd4*{28'd0,step});
        end
      end
      // M2S.2 — the page-walk reads/writes the page tables in PHYSICAL memory.
      // walk_step: 0=read PDE, 1=write PDE (A bit), 2=read PTE, 3=write PTE (A/D).
      S_WALK: begin
        mem_req=1'b1;
        unique case (walk_step)
          3'd0: mem_addr = walk_pde_addr;                        // read PDE
          3'd1: begin mem_we=1'b1; mem_wstrb=4'b1111;            // write PDE (set A)
                      mem_addr = walk_pde_addr; mem_wdata = walk_pde | 32'h0000_0020; end
          3'd2: mem_addr = walk_pte_addr;                        // read PTE
          default: begin mem_we=1'b1; mem_wstrb=4'b1111;         // write PTE (set A/D)
                      mem_addr = walk_pte_addr;
                      mem_wdata = walk_pte | 32'h0000_0020
                                  | (walk_is_write ? 32'h0000_0040 : 32'd0); end
        endcase
      end
      // M2S.3 — IDT delivery: gate read, CS-descriptor read, frame pushes, IRET
      // pops, and the CS-descriptor reload. These are LINEAR addresses (the IDT/
      // GDT are at known linear bases; the stack uses SS.base+ESP) and ARE paged
      // when paging_on (the post-stage below translates them).
      S_INT_GATE: begin mem_req=1'b1;            // IDT[vec] @ idt_base + vec*8
        mem_addr = idt_base + {21'd0, int_vec, 3'd0} + {29'd0, int_step[0], 2'b00};
      end
      S_INT_CS: begin mem_req=1'b1;              // GDT[gate_sel] descriptor
        mem_addr = gdt_base + {16'd0, int_gate_sel[15:3], 3'd0}
                   + {29'd0, int_step[0], 2'b00};
      end
      S_INT_PUSH: begin mem_req=1'b1; mem_we=1'b1; mem_wstrb=4'b1111;
        if (from_v86) begin
          // M7.2 V86: push the 9-WORD V86 frame (+errcode) descending from the NEW
          // (TSS.SS0) stack. seg_base[SG_SS] is the CPL0 SS base loaded in S_INT_SS.
          // Beats, low->high stored value (matches the monitor's frame offsets):
          //   0 GS @ esp-4, 1 FS @ esp-8, 2 DS @ esp-12, 3 ES @ esp-16,
          //   4 SS @ esp-20, 5 ESP @ esp-24, 6 EFLAGS @ esp-28, 7 CS @ esp-32,
          //   8 EIP @ esp-36, 9 errcode @ esp-40.
          mem_addr = seg_base[SG_SS] + int_new_esp
                     - ({28'd0, int_step} * 32'd4) - 32'd4;
          unique case (int_step)
            4'd0:    mem_wdata = {16'd0, int_old_gs};
            4'd1:    mem_wdata = {16'd0, int_old_fs};
            4'd2:    mem_wdata = {16'd0, int_old_ds};
            4'd3:    mem_wdata = {16'd0, int_old_es};
            4'd4:    mem_wdata = {16'd0, int_old_ss};
            4'd5:    mem_wdata = int_old_esp;
            4'd6:    mem_wdata = int_old_eflags;        // V86 EFLAGS (VM still set)
            4'd7:    mem_wdata = {16'd0, int_old_cs};   // interrupted V86 CS
            4'd8:    mem_wdata = int_ret_eip;           // V86 EIP (faulting)
            default: mem_wdata = int_err;               // beat 9: #GP error code (0)
          endcase
        end else if (xpl_active) begin
          // M2S.4 CROSS-PRIV: push the LARGER 5-word (or 6-word w/ errcode) frame
          // descending from the NEW stack (TSS.espN). seg_base[SG_SS] is already
          // the new (CPL0) SS base after S_INT_SS. Beats, low->high stored value:
          //   0 old SS @ esp-4, 1 old ESP @ esp-8, 2 EFLAGS @ esp-12,
          //   3 CS @ esp-16, 4 EIP @ esp-20, 5 errcode @ esp-24.
          mem_addr = seg_base[SG_SS] + int_new_esp
                     - ({28'd0, int_step} * 32'd4) - 32'd4;
          unique case (int_step)
            4'd0:    mem_wdata = {16'd0, int_old_ss};
            4'd1:    mem_wdata = int_old_esp;
            4'd2:    mem_wdata = eflags;
            4'd3:    mem_wdata = {16'd0, int_old_cs};   // interrupted task's CS
            4'd4:    mem_wdata = int_ret_eip;
            default: mem_wdata = int_err;
          endcase
        end else begin
          // SAME-PRIV: beat 0 EFLAGS @ ESP-4, 1 CS @ ESP-8, 2 EIP @ ESP-12,
          // 3 errcode @ ESP-16. The push uses the SS base (flat 0 here).
          mem_addr = seg_base[SG_SS] + gpr[R_ESP]
                     - ({28'd0, int_step} * 32'd4) - 32'd4;
          unique case (int_step)
            4'd0:    mem_wdata = eflags;
            4'd1:    mem_wdata = {16'd0, seg_sel[SG_CS]};
            4'd2:    mem_wdata = int_ret_eip;
            default: mem_wdata = int_err;
          endcase
        end
      end
      S_IRET, S_IRET_SS: begin mem_req=1'b1;     // pop EIP/CS/EFLAGS[+ESP/SS] asc
        mem_addr = seg_base[SG_SS] + gpr[R_ESP] + ({28'd0, int_step} * 32'd4);
      end
      S_INT_CS_RET: begin mem_req=1'b1;          // reload returned-to CS descriptor
        mem_addr = gdt_base + {16'd0, int_gate_sel[15:3], 3'd0}
                   + {29'd0, int_step[0], 2'b00};
      end
      // M2S.4 — TR/TSS reads (run with paging OFF, like the other descriptor
      // reads; NOT re-translated by the post-stage below).
      S_LTR: begin mem_req=1'b1;                 // GDT TSS descriptor @ gdt_base
        mem_addr = gdt_base + {16'd0, gpr[q_src_reg][15:3], 3'd0}
                   + {29'd0, seg_step, 2'b00};
      end
      S_INT_TSS: begin mem_req=1'b1;             // TSS.ssN:espN (ESPn then SSn)
        mem_addr = tr_base + tss_stk_off + {29'd0, int_step[0], 2'b00};
      end
      S_INT_SS: begin mem_req=1'b1;              // new SS descriptor @ gdt_base
        mem_addr = gdt_base + {16'd0, int_new_ss[15:3], 3'd0}
                   + {29'd0, int_step[0], 2'b00};
      end
      // M2S.4b — HARDWARE TASK SWITCH accesses. The TSS + GDT are addressed
      // PHYSICALLY under the M2S.1/.2 identity-map convention (paging off in the
      // ptask corpus), so (like the other descriptor/TSS reads) these are NOT
      // re-translated by the post-stage below.
      S_TSW_SAVE: begin mem_req=1'b1; mem_we=1'b1; mem_wstrb=4'b1111;
        // write the outgoing state into the CURRENT TSS (tr_base) at the 32-bit
        // TSS offsets: 0 EIP@0x20, 1 EFLAGS@0x24, 2..9 GPR@0x28..0x44,
        // 10..15 ES/CS/SS/DS/FS/GS@0x48..0x5C, 16 LDTR@0x60.
        mem_addr = tr_base + {24'd0, tsw_save_off(tsw_step)};
        unique case (tsw_step)
          5'd0:    mem_wdata = tsw_save_eip;
          5'd1:    mem_wdata = eflags;
          5'd2,5'd3,5'd4,5'd5,5'd6,5'd7,5'd8,5'd9:
                   mem_wdata = gpr[3'(tsw_step - 5'd2)];
          5'd10:   mem_wdata = {16'd0, seg_sel[SG_ES]};
          5'd11:   mem_wdata = {16'd0, seg_sel[SG_CS]};
          5'd12:   mem_wdata = {16'd0, seg_sel[SG_SS]};
          5'd13:   mem_wdata = {16'd0, seg_sel[SG_DS]};
          5'd14:   mem_wdata = {16'd0, seg_sel[SG_FS]};
          5'd15:   mem_wdata = {16'd0, seg_sel[SG_GS]};
          default: mem_wdata = 32'd0;   // beat 16: LDTR (no LDT tracked => 0)
        endcase
      end
      S_TSW_READ: begin mem_req=1'b1;            // read the incoming TSS state
        mem_addr = tsw_new_base + {24'd0, tsw_read_off(tsw_step)};
      end
      S_TSW_SEG: begin mem_req=1'b1;             // reload incoming seg descriptors
        // beat = seg_idx*2 + half; the selector for seg_idx is tsw_sel[seg_idx]
        // (CS,SS,DS,ES,FS,GS order). Read GDT[sel] (two dword beats).
        mem_addr = gdt_base + {16'd0, tsw_sel[3'(tsw_step[4:1])][15:3], 3'd0}
                   + {29'd0, tsw_step[0], 2'b00};
      end
      S_TSW_BUSY: begin mem_req=1'b1; mem_we=1'b1; mem_wstrb=4'b0010;
        // toggle the descriptor busy bit (access byte @ descriptor+5 = dword
        // descriptor+4, byte 1). beat 0 CLEARS the outgoing TSS busy (B->9),
        // beat 1 SETS the incoming TSS busy (9->B). Single-byte write via wstrb.
        if (tsw_step == 5'd0) begin
          mem_addr  = gdt_base + {16'd0, tr_sel[15:3], 3'd0} + 32'd4;
          mem_wdata = {16'd0, (tr_attr & ~8'h02), 8'd0};   // outgoing -> available
        end else begin
          mem_addr  = gdt_base + {16'd0, tsw_new_sel[15:3], 3'd0} + 32'd4;
          mem_wdata = {16'd0, tsw_new_attr, 8'd0};         // incoming -> busy
        end
      end
      // M2S.5 — SMRAM save-map accesses. The SMRAM region is addressed PHYSICALLY
      // (SMBASE+0x8000+offset). SMM runs with paging off in the corpus, and the
      // save map is a fixed physical structure, so (like the descriptor/TSS reads)
      // these are NOT re-translated by the post-stage below.
      S_SMI_SAVE: begin mem_req=1'b1; mem_we=1'b1; mem_wstrb=4'b1111;
        mem_addr  = smbase + 32'h0000_8000 + {16'd0, smm_off(smm_step)};
        mem_wdata = smm_save_data(smm_step);
      end
      S_RSM: begin mem_req=1'b1;                  // read the save map back
        mem_addr  = smbase + 32'h0000_8000 + {16'd0, smm_off(smm_step)};
      end
      default: ;
    endcase
    // ---- paging post-translation: linear -> physical for the data/fetch states.
    // The descriptor / TSS-structure reads (S_LGDT/S_SEGLD/S_LJMP and M2S.4
    // S_LTR + the GDT read S_INT_SS + the TSS read S_INT_TSS) and the walk itself
    // (S_WALK) address PHYSICAL memory directly and are NOT re-translated. Per
    // IA-32 the GDT and TSS are linear structures, but the M2S.1/.2 identity-map
    // simplification reads them physically — S_INT_TSS is excluded consistently
    // with the sibling GDT read S_INT_SS (both feed the same cross-priv delivery).
    if (paging_on && state != S_WALK &&
        state != S_LGDT && state != S_SEGLD && state != S_LJMP &&
        state != S_LTR && state != S_INT_SS && state != S_INT_TSS &&
        state != S_SMI_SAVE && state != S_RSM &&
        // M2S.4b task-switch TSS/GDT reads+writes address physical memory directly.
        state != S_TSW_SAVE && state != S_TSW_READ &&
        state != S_TSW_SEG && state != S_TSW_BUSY) begin
      // CRITICAL (Phase-3 [high] fix): on a TLB MISS this clock the FSM diverts to
      // S_WALK (the clocked block, gated on the same `xlate_miss`), so the bus this
      // clock belongs to the PAGE WALK, not to this state's access. But `state` is
      // still the access state combinationally, so without this guard the driver
      // would assert mem_req (and, on a WRITE state, mem_we) with mem_addr =
      // mem_xlate(linear) — which on a MISS returns the UNTRANSLATED LINEAR address
      // (see mem_xlate). The single-beat memmodel would then commit a spurious
      // write to the linear==physical alias before the walk fills the TLB. SQUASH
      // the access entirely on a miss: the walk owns the bus, and the access is
      // re-driven (now TLB-resident, correct physical) when the FSM resumes.
      // +VEN_FE_PIPE: also squash during the page-crossing stall (fe_xlate_pend) —
      // the registered micro-TLB doesn't yet hold this page, so no request leaves with
      // a stale physical address; the FSM holds and re-drives next clock with the
      // freshly-registered translate. fe_xlate_pend is tied 0 in the default build, so
      // this is exactly the existing squash there.
      if (xlate_miss || fe_xlate_pend) begin
        mem_req=1'b0; mem_we=1'b0; mem_addr=32'd0; mem_wdata=32'd0; mem_wstrb=4'd0;
      end else if (mem_req) begin
        mem_addr = mem_xlate(mem_addr, cur_is_d);
      end
    end
  end
