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
    // REVIEW1_Aug2 C-10: assert LOCK for every beat of a locked RMW. q_lock is latched
    // at decode and held until the next instruction, so the read beat AND the write
    // beat both carry it -- which is what lets a wrapper keep the bus across the pair.
    mem_lock = q_lock;
    // ---- REVIEW2_Aug1 C-06 -----------------------------------------------------
    // Publish, next to the address, whether this access goes THROUGH A SEGMENT at
    // all. Default: it does not. The arms that leave it 0 are exactly the ones that
    // address memory LINEARLY -- instruction fetch, prefetch, gate/descriptor/TSS
    // reads, page-table walks -- and subtracting a segment base from those is what
    // produced the measured off=0xfffe0528 underflows and their spurious rejections.
    // Set at the top of each arm that builds its address from a segment base, so it
    // lives with the code it describes rather than in a remote list in core.sv.
    cur_seg_rel=1'b0;
    // REVIEW1_Aug2 C-01: the access also carries WHICH segment governs it. Default to
    // dseg, which already resolves SS for push/pop/RET/PUSHA/LEAVE and ES for SCAS.
    // The arms below override it where the ADDRESS uses a different segment than dseg
    // names -- string STORES go to ES via dbase_edi while dseg names the string SOURCE
    // (DS), and the stack arms anchor on SS directly. Before this, the linear address
    // could be right while the LIMIT came from the wrong hidden descriptor.
    cur_seg_idx=dseg;
    unique case (state)
      // task #54: no bus transaction when the window is served from the I-cache.
      S_FETCH: begin mem_req=!sfetch_fast; mem_addr=flin+{27'd0,fetch_word,2'b00}; end
      S_PF:    begin mem_req=1'b1; mem_addr={pf_fill_addr[31:5],5'd0}+{27'd0,pf_word,2'b00}; end
      S_PIPE:  begin
        // a register-base load issued this clock reads [base] combinationally.
        // M2S.1: add the DS base (0 in user mode / flat PM).
        if (pipe_load_req) begin mem_req=1'b1; mem_addr=seg_base[SG_DS]+gpr_o[pipe_load_base]; end
        // I-cache miss detected this clock: fetch the fill line's WORD 0 NOW so the
        // detection clock is productive (finding [med] I-miss off-by-one). S_PF then
        // fetches words 1..7. mem_req for the load and the fill are mutually
        // exclusive: pf_miss => !pipe_bytes_ok => pipe_load_req is false.
        else if (pf_miss) begin mem_req=1'b1; mem_addr={pf_miss_fa[31:5],5'd0}; end
      end
      S_LOAD: begin
        mem_req=1'b1;
        cur_seg_rel=1'b1;  // REVIEW2_Aug1 C-06: segment-relative access
        if (q_is_pop || q_ct==CT_RETN || q_ct==CT_RETN_IMM ||
            (q_kind==K_STKMISC && q_sm==SM_POPF))
          mem_addr=dbase+stk16(gpr_o[R_ESP]);
        else if (q_kind==K_STKMISC && q_sm==SM_LEAVE)
          mem_addr=dbase+stk16(gpr_o[R_EBP]); // LEAVE reads [EBP] (the saved frame ptr)
        else if (q_kind==K_STR) begin
          // load order: movs/lods/cmps -> [ESI]; scas -> [EDI]
          // F3: a16 string EA uses SI/DI low-16 (str_esi/str_edi mask).
          if (q_st==ST_SCAS) mem_addr=dbase+str_edi;
          else               mem_addr=dbase+str_esi;
        end else if (q_xlat)
          // XLATB: byte at [DS:(E)BX + AL].
          // REVIEW_Jul29 M-06: this always used the full EBX, so the address-size-16
          // form (0x67, or real mode without a 0x67) indexed the table from EBX
          // instead of BX — a deterministic WRONG ADDRESS whenever EBX[31:16] was
          // non-zero. q_cnt16 is the latched effective-address-size-16 flag
          // (d_cnt16 = eff_addr, set for every instruction), which the string
          // pointers already use, so the correct operand is available with no new
          // plumbing.
          mem_addr = dbase
                   + (q_cnt16 ? {16'd0, gpr_o[R_EBX][15:0]} : gpr_o[R_EBX])
                   + {24'd0, gpr_o[R_EAX][7:0]};
        else mem_addr=opbase+q_ea;        // M7.1: opbase==dbase except a proxy
                                          // gs-override indirect-call operand read
        // REVIEW2 C-02: beat 2 of a page-crossing load re-issues at the SECOND page's
        // base so it gets its own translation and permission check. cur_lin in core.sv
        // carries the identical expression -- keep them in step (CHECK 5 enforces it).
        if (xp_pend) mem_addr = {mem_addr[31:12] + 20'd1, 12'd0};
      end
      S_LOAD2: begin mem_req=1'b1;
        cur_seg_rel=1'b1;  // REVIEW2_Aug1 C-06: segment-relative access
        // BOUND / CMPXCHG8B: the SECOND word is the upper bound / high dword at
        // [mem + w] (w=4 for 32-bit BOUND & CMPXCHG8B, 2 for a 16-bit BOUND).
        if (q_kind==K_BOUND || q_kind==K_CX8B) mem_addr=dbase+q_ea+{28'd0,q_w};
        // 32-bit far-ptr load (LDS/LES/LSS/LFS/LGS): selector is 2 bytes at [mem+4].
        else if (q_seg_load) mem_addr=dbase+q_ea+{28'd0,q_w};
        // 32-bit far JMP/CALL indirect (m16:32): selector 2 bytes at [mem+4]; use
        // opbase to match the first read (opbase+q_ea, S_LOAD line 44).
        else if (q_jmpf_mem || q_callf_mem) mem_addr=opbase+q_ea+{28'd0,q_w};
        else begin mem_addr=dbase_edi+str_edi;   // CMPS second operand ([EDI])
          cur_seg_idx=3'(SG_ES); end              // C-01: the [EDI] side is ES
        // REVIEW1_Aug2 C-03: page-crossing S_LOAD2 re-issues at the second page's
        // base. cur_lin in core.sv carries the identical expression (CHECK 5).
        if (xp_pend) mem_addr = {mem_addr[31:12] + 20'd1, 12'd0};
      end
      // Nested ENTER (level>0) micro-sequence: all accesses are STACK-relative (SS).
      // ent_rd beat reads the display source SS:[EBP-(ent_k-1)*w]; the push beat writes
      // ent_val to SS:[ESP-ent_k*w]. ESP/EBP stay at their pre-ENTER values until the
      // final commit (gpr_wb), so every address is a function of ent_k off the originals.
      S_ENTER: begin
        logic [31:0] koff, joff;   // declarations must precede statements
        cur_seg_rel=1'b1;  // REVIEW2_Aug1 C-06: segment-relative access
        koff = {26'd0, ent_k} * {29'd0, q_w};
        joff = ({26'd0, ent_k} - 32'd1) * {29'd0, q_w};
        mem_req = 1'b1;
        if (ent_rd) begin
          mem_addr = seg_base[SG_SS] + stk16(gpr_o[R_EBP] - joff);
        end else begin
          mem_we = 1'b1; mem_wstrb = strb_of(q_w);
          mem_addr  = seg_base[SG_SS] + stk16(gpr_o[R_ESP] - koff);
          mem_wdata = ent_val;
        end
      end
      // M2S.1 — LGDT/LIDT 6-byte read + PM descriptor fetches.
      S_LGDT: begin cur_seg_rel=1'b1; mem_req=1'b1; mem_addr=dbase+q_ea+{29'd0,seg_step,2'b00}; end
      S_SEGLD: begin
        // selector source: a GPR (reg-form MOV Sreg) or the latched mem value (PM mov-sreg-from-mem)
        logic [15:0] ssel; ssel = q_seg_from_mem ? seg_mem_sel : gpr_o[q_src_reg][15:0];
        mem_req=1'b1;  // TI bit (sel[2]) picks GDT vs LDT
        mem_addr=(ssel[2]?ldt_base:gdt_base)+{16'd0,ssel[15:3],3'd0}+{29'd0,seg_step,2'b00};
      end
      S_LJMP: begin mem_req=1'b1;   // far jmp/call target CS: TI bit picks GDT vs LDT
        mem_addr=(q_ljmp_sel[2]?ldt_base:gdt_base)+{16'd0,q_ljmp_sel[15:3],3'd0}+{29'd0,seg_step,2'b00};
      end
      // M9.5 — real-mode far CALL: 2-beat descending push on SS:SP. beat 0 pushes CS
      // at [SS:SP-w], beat 1 pushes the return IP at [SS:SP-2w]. ESP is unchanged
      // until the S_LCALL commit, so BOTH beats reference the OLD ESP. Width q_w
      // (2 real-mode default / 4 under 0x66) selects the byte-strobe + the SP steps.
      S_LCALL: begin
        // REVIEW1_Aug2 C-01: now checkable. This arm anchors on seg_base[SG_SS] and
        // says so explicitly, so the limit comes from SS rather than from whatever
        // dseg happened to name (which is why it was excluded before).
        cur_seg_rel=1'b1; cur_seg_idx=3'(SG_SS);
        mem_req=1'b1; mem_we=1'b1; mem_wstrb=(q_w==3'd2)?4'b0011:4'b1111;
        if (!seg_step) begin
          mem_addr  = seg_base[SG_SS] + stk16(gpr_o[R_ESP] - {28'd0,q_w});    // SP - w
          mem_wdata = {16'd0, seg_sel[SG_CS]};                             // push CS
        end else begin
          mem_addr  = seg_base[SG_SS] + stk16(gpr_o[R_ESP] - {27'd0,q_w,1'b0}); // SP - 2w
          mem_wdata = next_eip;                                           // push ret IP
        end
      end
      // M9.5 — RETF: 2-beat ascending pop on SS:SP. beat 0 pops IP at [SS:SP], beat 1
      // pops CS at [SS:SP+w]. ESP is unchanged until the S_RETF commit.
      S_RETF: begin
        mem_req=1'b1;
        // REVIEW1_Aug2 C-01: now checkable. This arm anchors on seg_base[SG_SS] and
        // says so explicitly, so the limit comes from SS rather than from whatever
        // dseg happened to name (which is why it was excluded before).
        cur_seg_rel=1'b1; cur_seg_idx=3'(SG_SS);
        if (!seg_step) mem_addr = seg_base[SG_SS] + stk16(gpr_o[R_ESP]);       // pop IP
        else           mem_addr = seg_base[SG_SS] + stk16(gpr_o[R_ESP]+{28'd0,q_w}); // pop CS
      end
      // M9.5 — SGDT/SIDT: 2-beat store of the 6-byte pseudo-descriptor (the exact
      // reverse of S_LGDT's read layout). beat 0 @[mem] = {base[15:0], limit[15:0]}
      // (4 bytes); beat 1 @[mem+4] = base[31:16] (2 bytes). SYS_SGDT -> GDTR, else IDTR.
      S_SGDT: begin
        mem_req=1'b1; mem_we=1'b1;
        cur_seg_rel=1'b1;  // REVIEW2_Aug1 C-06: segment-relative access
        mem_addr = dbase + q_ea + {29'd0, seg_step, 2'b00};
        if (!seg_step) begin
          mem_wstrb = 4'b1111;
          mem_wdata = (q_sysop==SYS_SGDT) ? {gdt_base[15:0], gdt_limit}
                                          : {idt_base[15:0], idt_limit};
        end else begin
          mem_wstrb = 4'b0011;
          mem_wdata = (q_sysop==SYS_SGDT) ? {16'd0, gdt_base[31:16]}
                                          : {16'd0, idt_base[31:16]};
        end
      end
      // F3 — real-mode IVT delivery. S_RMINT_RD: read the 4-byte IVT entry
      // {CS,IP} @ idt_base + vec*4 (one beat).
      S_RMINT_RD: begin
        mem_req=1'b1;
        mem_addr = idt_base + {22'd0, int_vec, 2'b00};
      end
      // S_RMINT_PUSH: descending 16-bit push of FLAGS (beat0 @SS:SP-2), CS
      // (beat1 @SS:SP-4), return IP (beat2 @SS:SP-6). ESP holds the OLD SP until
      // the S_RMINT_PUSH commit.
      S_RMINT_PUSH: begin
        cur_seg_rel=1'b1;  // REVIEW2_Aug1 C-06: segment-relative access
        mem_req=1'b1; mem_we=1'b1; mem_wstrb=4'b0011;
        mem_addr = seg_base[SG_SS] + stk16(gpr_o[R_ESP] - {27'd0, (int_step+4'd1), 1'b0});
        unique case (int_step)
          4'd0:    mem_wdata = {16'd0, eflags[15:0]};
          4'd1:    mem_wdata = {16'd0, seg_sel[SG_CS]};
          default: mem_wdata = {16'd0, int_ret_eip[15:0]};
        endcase
      end
      // S_RMIRET: ascending 16-bit pop of IP (beat0 @SS:SP), CS (beat1 @SS:SP+2),
      // FLAGS (beat2 @SS:SP+4).
      S_RMIRET: begin
        mem_req=1'b1;
        // REVIEW1_Aug2 C-01: now checkable. This arm anchors on seg_base[SG_SS] and
        // says so explicitly, so the limit comes from SS rather than from whatever
        // dseg happened to name (which is why it was excluded before).
        cur_seg_rel=1'b1; cur_seg_idx=3'(SG_SS);
        mem_addr = seg_base[SG_SS] + stk16(gpr_o[R_ESP] + {27'd0, int_step, 1'b0});
      end
      S_FLOAD: begin
        cur_seg_rel=1'b1;  // REVIEW2_Aug1 C-06: segment-relative access
        mem_req=1'b1; mem_addr=dbase+q_ea + {26'd0, f_step, 2'b00};   // base + q_ea + 4*f_step
      end
      // M11b: env/state transfers — one full dword per wide beat (f_seq_step).
      S_FENV_ST: begin
        cur_seg_rel=1'b1;  // REVIEW2_Aug1 C-06: segment-relative access
        mem_req=1'b1; mem_we=1'b1;
        mem_addr = dbase+q_ea + fenv_off;   // M-04: stride lives in fenv_off, not here
        // REVIEW1_Aug2 M-04: the 66h-prefixed form moves a 14-byte object -- one WORD
        // per beat from the 16-bit image. wstrb/wdata are byte-address relative (the
        // memory subsystem lane-shifts), exactly as the m16 S_FSTORE beat above.
        if (q_f_mbytes == 4'd2) begin
          mem_wstrb = 4'b0011;
          mem_wdata = {16'd0, fenv_image16[f_seq_step*16 +: 16]};
        end else begin
          mem_wstrb = 4'b1111;
          mem_wdata = fenv_image[f_seq_step*32 +: 32];
        end
      end
      S_FENV_LD: begin
        cur_seg_rel=1'b1;  // REVIEW2_Aug1 C-06: segment-relative access
        mem_req=1'b1; mem_addr=dbase+q_ea + fenv_off;  // M-04: 2-byte beats when 16-bit
      end
      S_FSTORE: begin
        cur_seg_rel=1'b1;  // REVIEW2_Aug1 C-06: segment-relative access
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
        cur_seg_rel=1'b1;  // REVIEW2_Aug1 C-06: segment-relative access
        mem_req=1'b1; mem_we=1'b1;
        if (q_kind==K_STR) begin
          // string store [EDI] uses ES.
          mem_wstrb=strb_of(q_w); mem_addr=dbase_edi+str_store_addr; mem_wdata=str_store_data;
          cur_seg_idx=3'(SG_ES);   // C-01: MOVS/STOS write ES:[EDI], not dseg's DS
        end else begin
          mem_wstrb=st_strb; mem_addr=stbase+st_addr; mem_wdata=st_data;
        end
        // ---- REVIEW2 C-02 (store half): PROBE-2 -> WRITE-1 -> WRITE-2 ----------
        // See core.sv for why this order needs no rollback. cur_lin carries the same
        // second-page redirect for phases 0 and 2 (CHECK 5 keeps them honest).
        if (xs_eff_act) begin
          logic [5:0] sh;
          sh = 6'(xs_first) << 3;
          unique case (xs_eff_ph)
            2'd0: begin  // PROBE the second page: translate + WRITE-permission check.
                    // REVIEW1_Aug2 C-02: NO BUS TRANSACTION. This used to leave
                    // mem_req=1 with mem_we=0, which is a real READ of page 2's base
                    // -- it could consume a read-sensitive MMIO register or allocate
                    // a cache line for a store that may never happen (if page 1 then
                    // faults). The probe needs the TRANSLATION and the PERMISSION
                    // check, not the data: the TLB lookup keys off cur_lin, and the
                    // walk divert keys off xlate_miss, neither of which needs a
                    // request. So drive the address for the lookup and nothing else.
                    mem_req   = 1'b0;
                    mem_we    = 1'b0;
                    mem_wstrb = 4'd0;
                    mem_addr  = {mem_addr[31:12] + 20'd1, 12'd0};
                  end
            2'd1: begin  // write only the FIRST page's bytes at the natural address
                    mem_wstrb = mem_wstrb & 4'((1 << xs_first) - 1);
                  end
            default: begin // write the remaining bytes at the SECOND page's base
                    mem_addr  = {mem_addr[31:12] + 20'd1, 12'd0};
                    mem_wstrb = 4'((1 << (xs_w - xs_first)) - 1);
                    mem_wdata = mem_wdata >> sh;
                  end
          endcase
        end
      end
      S_USEQ: begin
        mem_req=1'b1;
        cur_seg_rel=1'b1;  // REVIEW2_Aug1 C-06: segment-relative access
        if (q_kind==K_CX8B) begin
          // CMPXCHG8B equal-case store: EBX -> [mem] (beat 0), ECX -> [mem+4] (beat 1).
          mem_we=1'b1; mem_wstrb=4'b1111;
          mem_addr=dbase+q_ea+(step==4'd0 ? 32'd0 : {28'd0,q_w});
          mem_wdata=(step==4'd0) ? gpr_o[R_EBX] : gpr_o[R_ECX];
        end else if (q_sm==SM_PUSHA) begin
          // Width-aware: PUSHAD (q_w=4) pushes 8x32-bit @4-byte spacing; PUSHAW (q_w=2,
          // a CS16/D=0 segment, e.g. go32's DPMI context-save) pushes 8x16-bit @2-byte
          // spacing. The hardcoded-32-bit form silently corrupted PUSHAW/POPAW (the DOS-
          // Quake go32 high-half + ESP corruption). strb_of(q_w) selects the 16-bit lanes.
          mem_we=1'b1; mem_wstrb=strb_of(q_w);
          mem_addr=dbase+stk16(pusha_esp - (({28'd0,step}+32'd1)*{29'd0,q_w}));
          unique case (step)
            4'd0: mem_wdata=gpr_o[R_EAX];
            4'd1: mem_wdata=gpr_o[R_ECX];
            4'd2: mem_wdata=gpr_o[R_EDX];
            4'd3: mem_wdata=gpr_o[R_EBX];
            4'd4: mem_wdata=pusha_esp;     // original ESP
            4'd5: mem_wdata=gpr_o[R_EBP];
            4'd6: mem_wdata=gpr_o[R_ESI];
            default: mem_wdata=gpr_o[R_EDI];
          endcase
        end else begin // POPA: read ascending from ESP (q_w-spaced: POPAW=2, POPAD=4)
          mem_we=1'b0; mem_addr=dbase+stk16(gpr_o[R_ESP] + ({28'd0,step}*{29'd0,q_w}));
        end
      end
      // M2S.2 — the page-walk reads/writes the page tables in PHYSICAL memory.
      // walk_step: 0=read PDE, 1=write PDE (A bit), 2=read PTE, 3=write PTE (A/D).
      S_WALK: begin
        mem_req=1'b1;
        unique case (walk_step)
          3'd0: mem_addr = walk_pde_addr;                        // read PDE
          // write PDE: set A, and — on a 4 MiB LEAF page being WRITTEN — also D.
          // REVIEW_Jul29 H-04: this used to write A only, while core_walk.svh:67-68
          // latches `walk_pde | 0x20 | (is_big && walk_is_write ? 0x40 : 0)` and the
          // TLB fill (core.sv:3981-3990) fabricates A+D. So on the first write to a
          // clean 4 MiB page the TLB believed the page was dirty but the PDE IN
          // MEMORY stayed clean: software reading the tables saw the wrong dirty
          // state, and after any TLB invalidation the core rediscovered and re-"set"
          // a bit it never actually wrote. Mirror the walker's expression exactly so
          // memory and the internal latch agree.
          3'd1: begin mem_we=1'b1; mem_wstrb=4'b1111;
                      mem_addr  = walk_pde_addr;
                      mem_wdata = walk_pde | 32'h0000_0020
                                  | (((cr4_pse && walk_pde[7]) && walk_is_write
                                      && walk_wr_ok_big)   // REVIEW_aug2 C-04
                                     ? 32'h0000_0040 : 32'd0); end
          3'd2: mem_addr = walk_pte_addr;                        // read PTE
          default: begin mem_we=1'b1; mem_wstrb=4'b1111;         // write PTE (set A/D)
                      mem_addr = walk_pte_addr;
                      mem_wdata = walk_pte | 32'h0000_0020
                                  | ((walk_is_write && walk_wr_ok_4k)   // REVIEW_aug2 C-04
                                     ? 32'h0000_0040 : 32'd0); end
        endcase
      end
      // M2S.3 — IDT delivery: gate read, CS-descriptor read, frame pushes, IRET
      // pops, and the CS-descriptor reload. These are LINEAR addresses (the IDT/
      // GDT are at known linear bases; the stack uses SS.base+ESP) and ARE paged
      // when paging_on (the post-stage below translates them).
      S_INT_GATE: begin mem_req=1'b1;            // IDT[vec] @ idt_base + vec*8
        mem_addr = idt_base + {21'd0, int_vec, 3'd0} + {29'd0, int_step[0], 2'b00};
      end
      S_INT_CS: begin mem_req=1'b1;              // handler CS descriptor (TI picks GDT/LDT)
        mem_addr = (int_gate_sel[2]?ldt_base:gdt_base) + {16'd0, int_gate_sel[15:3], 3'd0}
                   + {29'd0, int_step[0], 2'b00};
      end
      S_INT_PUSH: begin mem_req=1'b1; mem_we=1'b1;
        // REVIEW1_Aug2 C-01: the interrupt frame is pushed on SS and its limit was
        // not checked at all -- this arm carried no segment identity.
        cur_seg_rel=1'b1; cur_seg_idx=3'(SG_SS);
        mem_wstrb = (!from_v86 && !xpl_active && int_gate_op16) ? 4'b0011 : 4'b1111;
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
        end else if (int_gate_op16) begin
          // SAME-PRIV 16-BIT GATE (mirrors the real-mode S_RMINT_PUSH 6-byte frame):
          // beat 0 FLAGS @ ESP-2, 1 CS @ ESP-4, 2 IP @ ESP-6 (2-byte slots). The
          // memmodel applies wstrb byte i to byte addr+i (memmodel.cpp:96-99), so a
          // wstrb=4'b0011 low-half write lands the 16-bit value at [addr..addr+1]
          // regardless of dword alignment — no byte-lane shift needed, exactly like
          // S_RMINT_PUSH. (errcode is impossible on a same-priv 16-bit software/HW
          // delivery in this corpus, but mirror the low-half default anyway.)
          mem_addr = seg_base[SG_SS]
                     + (gpr_o[R_ESP] - {27'd0, (int_step + 4'd1), 1'b0});
          unique case (int_step)
            4'd0:    mem_wdata = {16'd0, eflags[15:0]};
            4'd1:    mem_wdata = {16'd0, int_old_cs};   // interrupted CS (NOT handler) - DOS-Quake #GP fix
            4'd2:    mem_wdata = {16'd0, int_ret_eip[15:0]};
            default: mem_wdata = {16'd0, int_err[15:0]};
          endcase
        end else begin
          // SAME-PRIV 32-BIT GATE: beat 0 EFLAGS @ ESP-4, 1 CS @ ESP-8, 2 EIP @
          // ESP-12, 3 errcode @ ESP-16. The push uses the SS base (flat 0 here).
          mem_addr = seg_base[SG_SS] + gpr_o[R_ESP]
                     - ({28'd0, int_step} * 32'd4) - 32'd4;
          unique case (int_step)
            4'd0:    mem_wdata = eflags;
            4'd1:    mem_wdata = {16'd0, int_old_cs};   // interrupted CS (NOT handler) - DOS-Quake #GP fix
            4'd2:    mem_wdata = int_ret_eip;
            default: mem_wdata = int_err;
          endcase
        end
      end
      // REVIEW_aug2 C-06: S_IRET_SS is a DESCRIPTOR-TABLE read, not a stack pop. It
      // used to share the S_IRET arm below and therefore read
      //     seg_base[SG_SS] + ESP + step*4
      // -- i.e. two dwords from the OLD stack (and, after beat 4, at the freshly
      // installed OUTER ESP) -- and installed those arbitrary stack bytes as the new
      // SS base/limit/attr. Ordinary ring0->ring3 IRET was structurally wrong.
      // Address the GDT/LDT by the POPPED SS selector, honouring its TI bit, exactly
      // as S_INT_SS and S_INT_CS_RET already do. cur_lin mirrors this (CHECK 5).
      S_IRET_SS: begin mem_req=1'b1;
        mem_addr = (iret_ss[2] ? ldt_base : gdt_base)
                 + {16'd0, iret_ss[15:3], 3'd0} + ({29'd0, int_step[0], 2'b00});
      end
      S_IRET: begin mem_req=1'b1;                // pop EIP/CS/EFLAGS[+ESP/SS] asc
        cur_seg_rel=1'b1; cur_seg_idx=3'(SG_SS);   // REVIEW1_Aug2 C-01: SS-relative
        // 16-bit IRETW (same-priv only): ascending 2-byte pop IP @SP, CS @SP+2,
        // FLAGS @SP+4 (mirrors S_RMIRET). The memmodel returns a 32-bit dword at the
        // byte address (read32 @ addr), so the low 16 bits carry the popped word; the
        // S_IRET arm masks to [15:0] for IP/CS and merges FLAGS' high half. Inter-priv
        // / V86 IRET is never 16-bit in this corpus, so S_IRET_SS keeps the *4 stride.
        if (int_gate_op16)
          mem_addr = seg_base[SG_SS] + gpr_o[R_ESP] + ({27'd0, int_step, 1'b0});
        else
          mem_addr = seg_base[SG_SS] + gpr_o[R_ESP] + ({28'd0, int_step} * 32'd4);
      end
      S_INT_CS_RET: begin mem_req=1'b1;          // reload returned-to CS descriptor (TI: GDT/LDT)
        mem_addr = (int_gate_sel[2]?ldt_base:gdt_base) + {16'd0, int_gate_sel[15:3], 3'd0}
                   + {29'd0, int_step[0], 2'b00};
      end
      // M2S.4 — TR/TSS reads (run with paging OFF, like the other descriptor
      // reads; NOT re-translated by the post-stage below).
      S_LTR: begin mem_req=1'b1;                 // GDT TSS descriptor @ gdt_base
        mem_addr = gdt_base + {16'd0, gpr_o[q_src_reg][15:3], 3'd0}
                   + {29'd0, seg_step, 2'b00};
      end
      // REVIEW1_Aug2 M-03: beat 0 = TSS+0x66 (the I/O map base); beat 1 = the dword
      // holding the bitmap byte for this port. Both are TSS-relative and LINEAR, so
      // this arm sets no cur_seg_rel (see the C-01 default at the top).
      S_IOPERM: begin mem_req=1'b1;
        mem_addr = (int_step == 4'd0)
                 ? (tr_base + 32'h64)                       // dword holding [0x66]
                 : (tr_base + {16'd0, ioperm_base} + {19'd0, ioperm_port[15:3]});
      end
      S_INT_TSS: begin mem_req=1'b1;             // TSS.ssN:espN (ESPn then SSn)
        mem_addr = tr_base + tss_stk_off + {29'd0, int_step[0], 2'b00};
      end
      S_INT_SS: begin mem_req=1'b1;              // new SS descriptor (TI picks GDT/LDT)
        mem_addr = (int_new_ss[2]?ldt_base:gdt_base) + {16'd0, int_new_ss[15:3], 3'd0}
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
                   mem_wdata = gpr_o[3'(tsw_step - 5'd2)];
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
      S_TSW_LDT: begin mem_req=1'b1;             // new task's LDT descriptor @ GDT
        mem_addr = gdt_base + {16'd0, tsw_new_ldt[15:3], 3'd0}
                   + {29'd0, tsw_step[0], 2'b00};
      end
      // REVIEW2_aug2 C-05: NO descriptor read for a V86 incoming task -- its segment
      // values are real-mode paragraphs, and indexing the GDT with them reads an
      // arbitrary linear address that can #PF under paging. core_tsw.svh advances the
      // beat cadence itself in that case, so suppressing the request here cannot stall.
      S_TSW_SEG: begin mem_req=!tsw_eflags[17];  // reload incoming seg descriptors
        // beat = seg_idx*2 + half; the selector for seg_idx is tsw_sel[seg_idx]
        // (CS,SS,DS,ES,FS,GS order). TI bit (sel[2]) picks GDT vs the just-loaded LDT.
        // REVIEW2_aug2 C-05: the INCOMING task's LDT is staged (tsw_st_ldt_base) and
        // is not committed to ldt_base until S_TSW_BUSY, so address through the staged
        // copy. Using the live ldt_base here would resolve the new task's TI=1
        // selectors through the OUTGOING task's LDT.
        mem_addr = (tsw_sel[3'(tsw_step[4:1])][2]?tsw_st_ldt_base:gdt_base)
                   + {16'd0, tsw_sel[3'(tsw_step[4:1])][15:3], 3'd0}
                   + {29'd0, tsw_step[0], 2'b00};
      end
      S_TSW_BUSY: begin mem_req=1'b1; mem_we=1'b1; mem_wstrb=4'b0010;
        // Toggle the descriptor busy bit (access byte @ descriptor+5 = dword
        // descriptor+4, byte 1). Single-byte write via wstrb.
        //
        // ---- REVIEW2_aug2 C-05 (fifth bullet): ORDER MATTERS, and it was backwards.
        // The two writes straddle the final commit and cannot be made atomic here -- a
        // fault between them is possible in principle and IA-32 itself leaves such a
        // task switch for the #TS handler to clean up. What CAN be fixed is WHICH
        // partial state a fault leaves behind, and the old order left the worse one:
        //
        //   old  beat0 CLEAR outgoing, beat1 SET incoming.  A fault on beat 1 leaves
        //        the STILL-RUNNING task's descriptor marked AVAILABLE while it is very
        //        much still running -- so a later JMP to it succeeds and re-enters a
        //        task that never left, which is precisely what the busy bit exists to
        //        prevent.
        //   new  beat0 SET incoming, beat1 CLEAR outgoing.  A fault on beat 1 leaves
        //        the outgoing descriptor BUSY (true: that task is still running) and
        //        the incoming one busy but not entered -- a state the #TS handler can
        //        see and clear, and which cannot be mistaken for a free task.
        //
        // The commit still happens on the LAST beat's ack (core_tsw.svh), so clearing
        // the outgoing bit is now adjacent to the commit rather than four beats ahead
        // of it. Making the pair genuinely recoverable needs undoable descriptor
        // writes -- a probe-before-write or a rollback -- which is a bigger change and
        // is NOT done here.
        if (tsw_step == 5'd0) begin
          mem_addr  = gdt_base + {16'd0, tsw_new_sel[15:3], 3'd0} + 32'd4;
          mem_wdata = {16'd0, tsw_new_attr, 8'd0};         // incoming -> busy
        end else begin
          mem_addr  = gdt_base + {16'd0, tr_sel[15:3], 3'd0} + 32'd4;
          mem_wdata = {16'd0, (tr_attr & ~8'h02), 8'd0};   // outgoing -> available
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
    // REVIEW2 C-04: the descriptor / TSS states are no longer excluded -- they read and
    // write architecturally LINEAR structures and must translate. Only two exclusions
    // remain, and both are correct: S_WALK (a page-table walk is physical by
    // definition) and S_SMI_SAVE/S_RSM (the SMM save map is architecturally physical).
    //
    // S_LGDT stays excluded too: it reads the LGDT/LIDT pseudo-descriptor from an
    // ordinary data operand, so it is already covered by the normal data path -- it
    // was only in this list by association with the other "descriptor" states.
    //
    // REVIEW1_Aug2 C-09: the S_TSW_* states are NO LONGER excluded. They now have
    // cur_lin cases mirroring these arms exactly (core.sv), so they translate like any
    // other linear access and CHECK 5 holds them in step.
    if (paging_on && state != S_WALK &&
        // REVIEW_aug2 C-05: S_LGDT REMOVED from this exclusion -- LGDT/LIDT reads an
        // ordinary linear operand and must translate under paging (it was reading a
        // physical address). It now has a cur_lin case and is in `translatable`.
        // REVIEW1_Aug2 C-09: the five S_TSW_* states are OUT of this exclusion. They
        // now have cur_lin cases mirroring their arms above, so the task-switch
        // microsequence translates like every other linear access instead of driving
        // GDT/TSS linear addresses straight at physical memory.
        state != S_SMI_SAVE && state != S_RSM) begin
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
      // REVIEW2 C-03: snapshot the ARCHITECTURAL (pre-translate) bus address here,
      // after every case arm has driven it and before mem_xlate replaces it. The
      // assertion in core.sv compares this against cur_lin -- the address the TLB
      // lookup/walk actually used -- for every translatable request.
      mem_addr_pre = mem_addr;
      // REVIEW2 C-01: a permission fault must produce NO side effect -- no bus
      // transaction, no cache fill, no A/D writeback. Squash exactly like a TLB
      // miss does; the FSM arm below delivers the #PF on this same clock.
      if (xlate_miss || fe_xlate_pend || perm_fault) begin
        mem_req=1'b0; mem_we=1'b0; mem_addr=32'd0; mem_wdata=32'd0; mem_wstrb=4'd0;
      end else if (mem_req) begin
        mem_addr = mem_xlate(mem_addr, cur_is_d);
      end
    end
    // =========================================================================
    // REVIEW1_Aug2 C-01: a SEGMENT fault must suppress the faulting access.
    // =========================================================================
    // seg_access_fault was consumed by the FSM (core.sv, beside perm_fault) but was
    // NOT in the squash list above, so on a TLB hit -- or with paging off entirely --
    // the same clock both called start_fault(13) AND presented mem_req/mem_we to RAM,
    // L1, AXI or MMIO. A limit-violating STORE committed before the #GP; a load from
    // MMIO consumed a read-sensitive register before faulting.
    //
    // PLACEMENT, and this is the second time this exact mistake has been made in this
    // file: the squash above lives inside `if (paging_on && ...)`, so putting the
    // segment case there would have covered protected+paged only and done NOTHING in
    // real mode or in protected mode without paging -- where segment limits still
    // apply. That is precisely the A20 placement bug documented immediately below,
    // which was found only because a probe printed nothing while 52 writes occurred.
    // Segmentation is not conditional on paging, so the suppression is not either.
    //
    // Unconditional (not `ifdef VEN_SEG_ENFORCE`): seg_access_fault is tied to the
    // enforcement build by its own definition -- with enforcement off nothing raises
    // it, so this is inert there and cannot be left behind when the default flips.
    // Snapshot the request BEFORE suppressing it, so the +ven_seglog diagnostic can
    // still see that an access was attempted (qualifying it on the post-squash
    // mem_req makes it silent exactly when it matters).
    mem_req_pre_sq = mem_req;
    if (seg_access_fault) begin
      mem_req=1'b0; mem_we=1'b0; mem_addr=32'd0; mem_wdata=32'd0; mem_wstrb=4'd0;
    end
    // =========================================================================
    // REVIEW2 M-03: the A20 gate, applied to the FINAL physical address.
    // =========================================================================
    // A20 was ABSENT from the design -- no masking anywhere in the core and no
    // top-level control -- so accesses that must ALIAS at 1 MiB stayed distinct in
    // memory and in the caches.
    //
    // PLACEMENT: this MUST sit outside the `if (paging_on && ...)` block above. It
    // was first written inside it, right after mem_xlate(), on the reasoning that the
    // gate acts on the POST-TRANSLATION address. That reasoning is right but the
    // placement is wrong, because that whole tail only runs WITH PAGING ON -- so in
    // REAL MODE, which is exactly where A20 matters most (the HMA wrap that BIOS and
    // DOS depend on), the mask never executed at all. The directed test failed its
    // phase-2 check and an instrumented probe at the old site printed NOTHING for any
    // store, even though the run performed 52 writes. That zero-hit probe is what
    // located this: the branch simply is not on the real-mode store path.
    //
    // Here, at the end of the driver, mem_addr is the final physical address in EVERY
    // mode -- real mode (linear == physical), protected mode without paging, and
    // paged mode after mem_xlate(). That is where the gate sits on real silicon (on
    // the address pins), so one expression covers data, I-cache fills and page-walk
    // reads, and the physically-tagged L1D aliases correctly because it never sees
    // the unmasked bit.
    //
    // a20_on = the platform override AND the software latch (port 0x92 bit 1, latched
    // in the core's S_IO arm). Both default and reset to 1 = A20 ENABLED = no masking,
    // so every existing configuration is bit-identical until software clears it.
    if (mem_req && !a20_on) mem_addr[20] = 1'b0;

`ifndef SYNTHESIS
    // =========================================================================
    // REVIEW2 C-02 EXPOSURE COUNTER (measurement only -- changes no behaviour).
    // =========================================================================
    // C-02: a page-crossing access translates only its FIRST page. The high bytes
    // are taken from the physically adjacent frame, so when the two virtual pages
    // map to non-adjacent frames the access returns/writes the WRONG MEMORY, and a
    // required second-page #PF is suppressed.
    //
    // Unlike M-07's aliasing, this CANNOT be turned into a loud rejection: an
    // unaligned access spanning a 4 KiB boundary is perfectly legal x86 and real
    // code does it, so faulting on it would break the very guests that must run.
    // The only correct fix is the SPLIT (translate/check each piece, commit stores
    // only after every piece passes) -- the review's own fix-priority #1.
    //
    // What IS cheap and honest right now is to MEASURE the exposure rather than
    // assert it: count accesses that cross a page while paging is on. Zero means
    // the defect is real but unreached by the current gates (and explains why
    // nothing has caught it); non-zero means it is being hit today.
    if (mem_req && paging_on && fe_translatable
        && (({20'd0, mem_addr_pre[11:0]} + {29'd0, c02_bytes} - 32'd1) > 32'd4095))
      c02_xpage_hits = 1'b1;
    else
      c02_xpage_hits = 1'b0;
`endif
  end
