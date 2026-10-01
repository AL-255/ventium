// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/core_bus_driver.svh — RAW MODULE-SCOPE text `included by core.sv (R2
// modularization). NOT a standalone unit (no module wrapper): it is the single
// combinational bus-request driver `always_comb` (the per-state bd_req/bd_addr/
// bd_we/bd_wdata/bd_wstrb `unique case (state)` PLUS the paging post-translate
// linear->physical tail), pasted verbatim at module scope at its original site,
// so the netlist is identical. All referenced signals/functions (mem_xlate,
// smm_off, cur_is_d, the SG_*/state enums) live in core.sv module scope.
  // ===========================================================================
  // Segment-identity publication (cur_seg_rel / cur_seg_idx) — REVIEW2_Aug1
  // C-06 / REVIEW1_Aug2 C-01, SPLIT OUT of the bus driver below by R2-M02.
  //
  // cur_seg_rel: whether this access goes THROUGH A SEGMENT at all. Default: it
  // does not. The states that leave it 0 are exactly the ones that address
  // memory LINEARLY -- instruction fetch, prefetch, gate/descriptor/TSS reads,
  // page-table walks. cur_seg_idx: WHICH segment governs the access. Default
  // dseg, which already resolves SS for push/pop/RET/PUSHA/LEAVE and ES for
  // SCAS; the overrides below are where the ADDRESS uses a different segment
  // than dseg names -- string STORES go to ES via dbase_edi while dseg names
  // the string SOURCE (DS), and the stack arms anchor on SS directly.
  //
  // WHY A SEPARATE DRIVER: sharing the bus driver's always_comb closed a
  // BLOCK-LEVEL combinational cycle (UNOPTFLAT on cur_seg_rel): cur_seg_rel ->
  // acc_usr -> perm_fault -> the bus block's fault squash -> (same block)
  // cur_seg_rel. The identity depends only on state/dseg and a few q_* shape
  // flags -- never on cur_lin or perm_fault -- so with its own driver the
  // cycle is gone. KEEP THE TWO BLOCKS IN STEP: a bus arm below that builds
  // its address from a segment base MUST have a matching arm here (the seg
  // gates grade exactly this).
  // ===========================================================================
  // Keep the instruction/state classification separate from the physical-beat
  // qualifier.  The fragment engine may blank bd_req for a crossing-store
  // page-2 probe, and translation/permission logic can squash a request after
  // this driver has selected its state arm.  LOCK# must never escape on either
  // kind of non-transaction; `mem_req` is the final, post-fragment request.
  // There is no feedback path: mem_req depends on bd_req and fragment shaping,
  // never on either lock signal.
  logic bd_lock_beat;
  assign bd_lock_beat = q_lock && ((state == S_LOAD) ||
                                   ((state == S_LOAD2) && (q_kind == K_CX8B)) ||
                                   (state == S_STORE) ||
                                   ((state == S_USEQ) && (q_kind == K_CX8B)));
  assign mem_lock = bd_lock_beat && mem_req;

  always_comb begin
    cur_seg_rel = 1'b0;
    cur_seg_idx = dseg;
    unique case (state)
      S_LGDT, S_SGDT, S_ENTER,
      S_FLOAD, S_FENV_ST, S_FENV_LD, S_FSTORE,
      S_USEQ, S_RMINT_PUSH:
        cur_seg_rel = 1'b1;   // segment-relative access, dseg governs
      S_LOAD: begin
        cur_seg_rel = 1'b1;
        // The same selector supplies opbase: an explicit PUSH/CALL operand
        // uses its own segment; POP/RET's implicit stack read stays on SS.
        cur_seg_idx = opseg;
      end
      S_PIPE: begin
        // The checked U-side data forms select DS or SS from their decoded
        // addressing base. Classify them as guest segment accesses so D-TLB
        // U/S permission handling cannot treat a CPL3 access as supervisor.
        // System-mode stores remain slow (core.sv).
        // Instruction-fill S_PIPE requests leave this false.
        cur_seg_rel = pipe_load_req || pipe_store_req;
        cur_seg_idx = pipe_mem_seg;
      end
      S_LCALL, S_RETF, S_RMIRET,
      S_INT_PROBE, S_CG_PRD, S_INT_PUSH, S_IRET: begin
        cur_seg_rel = 1'b1;
        cur_seg_idx = 3'(SG_SS);   // REVIEW1_Aug2 C-01: SS-relative
      end
      S_LOAD2: begin
        cur_seg_rel = 1'b1;
        // BOUND/CMPXCHG8B, far-ptr seg load, and far JMP/CALL indirect read the
        // second word off the DATA segment; only the CMPS second operand is ES.
        if (!(q_kind==K_BOUND || q_kind==K_CX8B) && !q_seg_load
            && !(q_jmpf_mem || q_callf_mem))
          cur_seg_idx = 3'(SG_ES);   // C-01: the CMPS [EDI] side is ES
      end
      S_STORE: begin
        cur_seg_rel = 1'b1;
        // POP m writes its explicit operand, not the SS used for its read.
        // Follow stbase's canonical selector; strings retain their ES side.
        cur_seg_idx = stseg;
        if (q_kind==K_STR)
          cur_seg_idx = 3'(SG_ES);   // C-01: MOVS/STOS write ES:[EDI]
      end
      default: ;
    endcase
  end
  // ===========================================================================
  // Bus request generation (single combinational driver). The address is
  // cur_lin for every translatable state (R2-M02; the post-stage below
  // translates it); only the physical-by-definition states keep address arms.
  // ===========================================================================
  always_comb begin
    bd_req =1'b0; bd_we =1'b0; bd_addr =32'd0; bd_wdata =32'd0; bd_wstrb =4'd0;
    // LOCK# is a qualifier for actual RMW OPERAND beats, not a sticky property of
    // the decoded instruction.  q_lock may legally survive a page walk, a no-request
    // cross-page store probe, or fault delivery until the common abort funnel clears
    // it; leaking it there makes a pin-level wrapper lock unrelated traffic and makes
    // the L1/AXI seam mistake a walk for an aborted RMW.  The separate
    // mem_lock_hold output preserves local-DMA exclusion across those detours.
    //
    // S_LOAD2/S_USEQ are only operand beats for CMPXCHG8B.  CMPS/far-pointer/
    // PUSHA traffic must never inherit LOCK# just because an older descriptor was
    // still latched.
    unique case (state)
      // task #54: no bus transaction when the window is served from the I-cache.
      // (R2-M02 family 6: the fetch addresses are cur_lin too.)
      S_FETCH: begin bd_req =!(sfetch_fast || sfetch_uop_fast || sfetch_short_fast || sfetch_resident_fast); end
      S_PF:    begin bd_req =1'b1; end
      S_PIPE:  begin
        // A checked DS/SS effective-address read/store issued this clock. The
        // source and byte-width metadata belong to the same transaction packet.
        // Read strobes are equally important: a byte MMIO read must not fetch
        // three adjacent registers or invent a cross-page access at offset FFF.
        if (pipe_load_req) begin
          bd_req=1'b1; bd_wstrb=fp_mem_read_strobe(pipe_u_eff);
        end
        else if (pipe_store_req) begin
          bd_req=1'b1; bd_we=1'b1;
          bd_wstrb=pipe_u_eff.w8 ? 4'b0001 : 4'b1111; bd_wdata=pipe_store_data;
        end
        // I-cache miss detected this clock: fetch the fill line's WORD 0 NOW so the
        // detection clock is productive (finding [med] I-miss off-by-one). S_PF then
        // fetches words 1..7. bd_req for the load and the fill are mutually
        // exclusive: pf_miss => !pipe_bytes_ok => pipe_load_req is false.
        // !exec_issue_ok: a flush cycle is a pure bubble -- the word-0 request
        // starts from S_PF after the invalidating edge instead.
        else if (pf_miss && exec_issue_ok) begin bd_req =1'b1; end
      end
      S_LOAD: begin
        bd_req =1'b1;
        // REVIEW1_Aug3 R2-H01: carry the read SIZE on the seam (strobe form), so a
        // non-cacheable/MMIO read can be issued at its exact byte extent instead
        // of a conservative full word. Inert for every cacheable/BBM consumer.
        bd_wstrb = xp_read_strb; // exact first/remaining page fragment, including three bytes
        // (R2-M02 family 7: ALL address shapes -- pop/LEAVE/string/XLAT/plain and
        // the xp_pend second-page re-issue -- via cur_lin. The selection logic
        // lives only in the cur_lin_nat mirror in core.sv now.)
      end
      S_LOAD2: begin bd_req =1'b1;
        bd_wstrb = xp_read_strb;   // exact far-pointer selector/data page fragment
        // BOUND / CMPXCHG8B: the SECOND word is the upper bound / high dword at
        // [mem + w] (w=4 for 32-bit BOUND & CMPXCHG8B, 2 for a 16-bit BOUND).
        // 32-bit far-ptr load (LDS/LES/LSS/LFS/LGS): selector is 2 bytes at [mem+4].
        // 32-bit far JMP/CALL indirect (m16:32): selector 2 bytes at [mem+4].
        // (R2-M02: all address shapes via cur_lin; segment identity above.)
      end
      // Nested ENTER (level>0) micro-sequence: all accesses are STACK-relative (SS).
      // ent_rd beat reads the display source SS:[EBP-(ent_k-1)*w]; the push beat writes
      // ent_val to SS:[ESP-ent_k*w]. ESP/EBP stay at their pre-ENTER values until the
      // final commit (gpr_wb), so every address is a function of ent_k off the originals.
      S_ENTER: begin
        // (R2-M02: both beat addresses via cur_lin; the koff/joff offsets live
        // in the cur_lin mirror now.)
        bd_req = 1'b1;
        if (!ent_rd) begin
          bd_we = 1'b1; bd_wstrb = strb_of(q_w);
          bd_wdata = ent_val;
        end
      end
      // M2S.1 — LGDT/LIDT 6-byte read + PM descriptor fetches.
      S_LGDT: begin bd_req =1'b1; end   // (R2-M02: address via cur_lin)
      S_SEGLD: begin
        // selector source: a GPR (reg-form MOV Sreg) or the latched mem value (PM
        // mov-sreg-from-mem) -- the cur_lin mirror computes it the same way.
        // REVIEW1_Aug3 R2-C02: a NULL load performs NO descriptor read -- the FSM
        // faults (CS/SS) or installs an explicit null hidden cache (data segs)
        // without touching GDT[0]. seg_null_load is the same predicate at module
        // level; the translation predicate uses it too (the pltr lesson).
        // (R2-M02: the descriptor address is cur_lin.)
        bd_req =!seg_null_load;  // TI bit (sel[2]) picks GDT vs LDT
      end
      S_DQUERY: begin bd_req = !dq_pre_invalid; end
      S_LJMP: begin bd_req =1'b1;   // far jmp/call target CS: TI bit picks GDT vs LDT (R2-M02: cur_lin)
      end
      // M9.5 — real-mode far CALL: 2-beat descending push on SS:SP. beat 0 pushes CS
      // at [SS:SP-w], beat 1 pushes the return IP at [SS:SP-2w]. ESP is unchanged
      // until the S_LCALL commit, so BOTH beats reference the OLD ESP. Width
      // lc_callw (q_w for a direct call; the GATE's width for a gated one, R2-H05)
      // selects the byte-strobe + the SP steps.
      S_LCALL: begin
        // REVIEW1_Aug2 C-01: now checkable. This arm anchors on seg_base[SG_SS] and
        // says so explicitly, so the limit comes from SS rather than from whatever
        // dseg happened to name (which is why it was excluded before).
        bd_req =1'b1; bd_we =1'b1; bd_wstrb =(lc_callw==3'd2)?4'b0011:4'b1111;
        // (R2-M02: both beat addresses via cur_lin.)
        if (!seg_step) begin
          bd_wdata = {16'd0, seg_sel[SG_CS]};                             // push CS
        end else begin
          bd_wdata = next_eip;                                           // push ret IP
        end
      end
      // M9.5 — RETF: 2-beat ascending pop on SS:SP. beat 0 pops IP at [SS:SP], beat 1
      // pops CS at [SS:SP+w]. ESP is unchanged until the S_RETF commit.
      S_RETF: begin
        bd_req =1'b1;
        // Reads use producer-relative byte enables too: the zero-strobe
        // legacy fallback means four bytes, which over-reads word frames.
        bd_wstrb = (q_w==3'd2) ? 4'b0011 : 4'b1111;
        // REVIEW1_Aug2 C-01: now checkable. This arm anchors on seg_base[SG_SS] and
        // says so explicitly, so the limit comes from SS rather than from whatever
        // dseg happened to name (which is why it was excluded before).
        // REVIEW2_aug2 C-06: an OUTER-level return keeps popping -- ESP at +2w and SS
        // at +3w. ESP is NOT bumped at beat 1 for this case (see core_gpr_wb.svh), so
        // these stay anchored to the ORIGINAL inner ESP and the arithmetic is plain.
        // REVIEW1_Aug3 R2-H05 follow-up (B1, found by pcgparam): with a RETF imm16
        // the outer ESP/SS slots sit ABOVE the imm16 bytes the inner frame discards
        // (QEMU helper_ret_protected: sp += addend BEFORE the outer pops) -- every
        // prior cross-priv RETF in the corpus had imm=0, so this was unreachable
        // until parameter-copy call gates made imm!=0 returns routine.
        // (R2-M02: all three beat addresses via cur_lin.)
      end
      // M9.5 — SGDT/SIDT: 2-beat store of the 6-byte pseudo-descriptor (the exact
      // reverse of S_LGDT's read layout). beat 0 @[mem] = {base[15:0], limit[15:0]}
      // (4 bytes); beat 1 @[mem+4] = base[31:16] (2 bytes). SYS_SGDT -> GDTR, else IDTR.
      S_SGDT: begin
        bd_req =!sgdt_probe_q; bd_we =!sgdt_probe_q;
        // (R2-M02: address via cur_lin.)
        if (!seg_step) begin
          bd_wstrb = 4'b1111;
          bd_wdata = (q_sysop==SYS_SGDT) ? {gdt_base[15:0], gdt_limit}
                                          : {idt_base[15:0], idt_limit};
        end else begin
          bd_wstrb = 4'b0011;
          bd_wdata = (q_sysop==SYS_SGDT) ? {16'd0, gdt_base[31:16]}
                                          : {16'd0, idt_base[31:16]};
          if (q_w == 3'd2) bd_wdata[15:8] = 8'd0;
        end
      end
      // F3 — real-mode IVT delivery. S_RMINT_RD: read the 4-byte IVT entry
      // {CS,IP} @ idt_base + vec*4 (one beat).
      S_RMINT_RD: begin
        bd_req = rm_read_armed;
        bd_addr = idt_base + {22'd0, int_vec, 2'b00};
      end
      // S_RMINT_PUSH: descending 16-bit push of FLAGS (beat0 @SS:SP-2), CS
      // (beat1 @SS:SP-4), return IP (beat2 @SS:SP-6). ESP holds the OLD SP until
      // the S_RMINT_PUSH commit.
      S_RMINT_PUSH: begin
        bd_req =1'b1; bd_we =1'b1; bd_wstrb =4'b0011;
        bd_addr = seg_base[SG_SS] + stk16(gpr_o[R_ESP] - {27'd0, (int_step+4'd1), 1'b0});
        unique case (int_step)
          4'd0:    bd_wdata = {16'd0, eflags[15:0]};
          4'd1:    bd_wdata = {16'd0, seg_sel[SG_CS]};
          default: bd_wdata = {16'd0, int_ret_eip[15:0]};
        endcase
      end
      // S_RMIRET: ascending 16-bit pop of IP (beat0 @SS:SP), CS (beat1 @SS:SP+2),
      // FLAGS (beat2 @SS:SP+4).
      S_RMIRET: begin
        bd_req = rm_read_armed;
        // REVIEW1_Aug2 C-01: now checkable. This arm anchors on seg_base[SG_SS] and
        // says so explicitly, so the limit comes from SS rather than from whatever
        // dseg happened to name (which is why it was excluded before).
        bd_addr = seg_base[SG_SS] + stk16(gpr_o[R_ESP] + {27'd0, int_step, 1'b0});
      end
      S_FLOAD: begin
        // R2-H01: read size on the seam -- matches cur_size for this beat (the
        // m80 third beat and the m16 forms are 2 bytes, everything else 4).
        bd_wstrb = ((q_f_mbytes==4'd10 && f_step==4'd2) || (q_f_mbytes==4'd2))
                 ? 4'b0011 : 4'b1111;
`ifdef VEN_FP_SHARED
        // Stores are pre-probed by the shared-FPU adapter.  Permission/TLB
        // lookup is driven from cur_lin/cur_is_w, while the port stays quiet:
        // a destination may be MMIO, so issuing a speculative read is not safe.
        bd_req = !q_f_mem_write;
`else
        bd_req =1'b1;   // (R2-M02: address via cur_lin)
`endif
      end
      // M11b: env/state transfers — one full dword per wide beat (f_seq_step).
      S_FENV_ST: begin
        bd_req =1'b1; bd_we =1'b1;
        // (R2-M02: address via cur_lin; the stride lives in fenv_off on that side too.)
        // REVIEW1_Aug2 M-04: the 66h-prefixed form moves a 14-byte object -- one WORD
        // per beat from the 16-bit image. wstrb/wdata are byte-address relative (the
        // memory subsystem lane-shifts), exactly as the m16 S_FSTORE beat above.
        if (q_f_mbytes == 4'd2) begin
          bd_wstrb = 4'b0011;
`ifdef VEN_FP_SHARED
          bd_wdata = {16'd0, fp_shared_store_data_q[f_seq_step*16 +: 16]};
`else
          bd_wdata = {16'd0, fenv_image16[f_seq_step*16 +: 16]};
`endif
        end else begin
          bd_wstrb = 4'b1111;
`ifdef VEN_FP_SHARED
          bd_wdata = fp_shared_store_data_q[f_seq_step*32 +: 32];
`else
          bd_wdata = fenv_image[f_seq_step*32 +: 32];
`endif
        end
      end
      S_FENV_LD: begin
`ifdef VEN_FP_SHARED
        // FNSTENV/FNSAVE use this load sequencer as the same no-bus destination
        // write-permission probe; FLDENV/FRSTOR remain real reads.
        bd_req = !q_f_mem_write;
`else
        bd_req =1'b1;   // (R2-M02: address via cur_lin; 2-byte beats when 16-bit)
`endif
      end
      S_FSTORE: begin
        // A4-H01: an UNMASKED stack fault commits nothing -- suppress the
        // transaction entirely (the FSM arm retires without waiting for ack).
`ifdef VEN_FP_SHARED
        // An unmasked stack fault returned no store response and retired from
        // S_FP_SHARED_WAIT, so reaching this state always means pre-probed data.
        bd_req =1'b1; bd_we =1'b1;
`else
        bd_req =!(fp_flt_q && !fctrl[0]);
        bd_we  =!(fp_flt_q && !fctrl[0]);
`endif
        // (R2-M02: address via cur_lin.)
        // the m80 third beat writes only 2 bytes; all others write a full word.
        if (q_f_mbytes==4'd10 && f_step==4'd2) bd_wstrb =4'b0011;
        else if (q_f_mbytes==4'd2)             bd_wstrb =4'b0011;   // m16 (cw/sw/int16)
        else                                   bd_wstrb =4'b1111;
        unique case (f_step)
          4'd0: bd_wdata = fstore_val[31:0];
          4'd1: bd_wdata = fstore_val[63:32];
          default: bd_wdata = {16'd0, fstore_val[79:64]};
        endcase
      end
      S_STORE: begin
        bd_req =1'b1; bd_we =1'b1;
        // (R2-M02 family 7: both address shapes -- string [EDI] and stbase+st_addr
        // -- via cur_lin (st_lin_nat); the xs phase redirect lives there too.)
        if (q_kind==K_STR) begin
          // string store [EDI] uses ES (the segment identity block above).
          bd_wstrb =strb_of(q_w); bd_wdata =str_store_data;
        end else begin
          bd_wstrb =st_strb; bd_wdata =st_data;
        end
        // ---- REVIEW2 C-02 (store half): PROBE-2 -> WRITE-1 -> WRITE-2 ----------
        // See core.sv for why this order needs no rollback. cur_lin carries the
        // second-page redirect for phases 0 and 2 (it is the only address now).
        if (xs_eff_act) begin
          logic [5:0] sh;
          sh = 6'(xs_first) << 3;
          unique case (xs_eff_ph)
            2'd0: begin  // PROBE the second page: translate + WRITE-permission check.
                    // REVIEW1_Aug2 C-02: NO BUS TRANSACTION. This used to leave
                    // bd_req =1 with bd_we =0, which is a real READ of page 2's base
                    // -- it could consume a read-sensitive MMIO register or allocate
                    // a cache line for a store that may never happen (if page 1 then
                    // faults). The probe needs the TRANSLATION and the PERMISSION
                    // check, not the data: the TLB lookup keys off cur_lin, and the
                    // walk divert keys off xlate_miss, neither of which needs a
                    // request. So drive the address for the lookup and nothing else.
                    bd_req = 1'b0;
                    bd_we = 1'b0;
                    bd_wstrb = 4'd0;
                  end
            2'd1: begin  // write only the FIRST page's bytes at the natural address
                    bd_wstrb = bd_wstrb & 4'((1 << xs_first) - 1);
                  end
            default: begin // write the remaining bytes at the SECOND page's base
                    bd_wstrb = 4'((1 << (xs_w - xs_first)) - 1);
                    bd_wdata = bd_wdata >> sh;
                  end
          endcase
        end
      end
      S_USEQ: begin
        bd_req =1'b1;
        // (R2-M02: all three address shapes via cur_lin.)
        if (q_kind==K_CX8B) begin
          // CMPXCHG8B equal-case store: EBX -> [mem] (beat 0), ECX -> [mem+4] (beat 1).
          bd_we =1'b1; bd_wstrb =4'b1111;
          bd_wdata =(step==4'd0) ? gpr_o[R_EBX] : gpr_o[R_ECX];
        end else if (q_sm==SM_PUSHA) begin
          // Width-aware: PUSHAD (q_w=4) pushes 8x32-bit @4-byte spacing; PUSHAW (q_w=2,
          // a CS16/D=0 segment, e.g. go32's DPMI context-save) pushes 8x16-bit @2-byte
          // spacing. The hardcoded-32-bit form silently corrupted PUSHAW/POPAW (the DOS-
          // Quake go32 high-half + ESP corruption). strb_of(q_w) selects the 16-bit lanes.
          bd_we =1'b1; bd_wstrb =strb_of(q_w);
          unique case (step)
            4'd0: bd_wdata =gpr_o[R_EAX];
            4'd1: bd_wdata =gpr_o[R_ECX];
            4'd2: bd_wdata =gpr_o[R_EDX];
            4'd3: bd_wdata =gpr_o[R_EBX];
            4'd4: bd_wdata =pusha_esp;     // original ESP
            4'd5: bd_wdata =gpr_o[R_EBP];
            4'd6: bd_wdata =gpr_o[R_ESI];
            default: bd_wdata =gpr_o[R_EDI];
          endcase
        end else begin // POPA: read ascending from ESP (q_w-spaced: POPAW=2, POPAD=4)
          bd_we =1'b0;
        end
      end
      // M2S.2 — the page-walk reads/writes the page tables in PHYSICAL memory.
      // walk_step: 0=read PDE, 1=write PDE (A bit), 2=read PTE, 3=write PTE (A/D).
      S_WALK: begin
        bd_req =1'b1;
        unique case (walk_step)
          3'd0: bd_addr = walk_pde_addr;                        // read PDE
          // write PDE: set A, and — on a 4 MiB LEAF page being REALLY written — also D.
          // REVIEW_Jul29 H-04: this used to write A only, while core_walk.svh's
          // step-1 arm latches the same A/D update and the TLB fill reconstructs
          // it: on the first write to a clean 4 MiB page the TLB believed the
          // page was dirty but the PDE IN MEMORY stayed clean. Mirror the
          // walker's expression exactly so memory and the internal latch agree.
          // A4-C01: the D term keys on walk_set_dirty, NOT walk_is_write -- a
          // crossing-write PROBE walks with the write class (for W/R permission
          // and the #PF error code) but must not change architectural D state:
          // if page 1 then faults, the store never happened.
          3'd1: begin bd_we =1'b1; bd_wstrb =4'b1111;
                      bd_addr = walk_pde_addr;
                      bd_wdata = walk_pde | 32'h0000_0020
                                  | (((cr4_pse && walk_pde[7]) && walk_set_dirty
                                      && walk_wr_ok_big)   // REVIEW_aug2 C-04
                                     ? 32'h0000_0040 : 32'd0); end
          3'd2: bd_addr = walk_pte_addr;                        // read PTE
          default: begin bd_we =1'b1; bd_wstrb =4'b1111;         // write PTE (set A/D)
                      bd_addr = walk_pte_addr;
                      bd_wdata = walk_pte | 32'h0000_0020
                                  | ((walk_set_dirty && walk_wr_ok_4k)   // REVIEW_aug2 C-04
                                     ? 32'h0000_0040 : 32'd0); end
        endcase
      end
      // M2S.3 — IDT delivery: gate read, CS-descriptor read, frame pushes, IRET
      // pops, and the CS-descriptor reload. These are LINEAR addresses (the IDT/
      // GDT are at known linear bases; the stack uses SS.base+ESP) and ARE paged
      // when paging_on (the post-stage below translates them).
      // REVIEW1_Aug3 R2-M02 (family 1): the ADDRESS lines for this whole family
      // are deleted -- every state here is translatable, so the post-stage drives
      // bd_addr = cur_lin and the per-arm copies were provably-dead duplicates
      // (CHECK 5 asserted that per request for months). req/we/wstrb/wdata and
      // the segment identities stay: those are NOT duplicated.
      S_INT_GATE: begin bd_req =1'b1;            // IDT[vec] @ idt_base + vec*8 (cur_lin)
      end
      S_INT_CS: begin bd_req =1'b1;              // handler CS descriptor (TI picks GDT/LDT; cur_lin)
      end
      // REVIEW1_Aug3 R2-C04: the frame-extent probe issues NO bus transaction --
      // the TLB lookup keys off cur_lin and the walk divert off xlate_miss, so a
      // missing frame page is still walked in before any frame write. cur_seg_rel
      // marks it an SS-relative access for the limit-check class.
      S_INT_PROBE: begin bd_req =1'b0;
      end
      // REVIEW1_Aug3 R2-H05: call-gate parameter read off the OLD stack (still
      // installed). Read strobes are the gate-width unit relative to bd_addr,
      // so the byte-exact path touches exactly the param's bytes. (R2-M02:
      // address line deleted -- cur_lin covers it.)
      S_CG_PRD: begin bd_req =1'b1; bd_we =1'b0;
        bd_wstrb = cg_wide ? 4'b1111 : 4'b0011;
      end
      S_INT_PUSH: begin bd_req =1'b1; bd_we =1'b1;
        // REVIEW1_Aug2 C-01: the interrupt frame is pushed on SS and its limit was
        // not checked at all -- this arm carried no segment identity.
        // A4-H03: word strobes for EVERY 16-bit frame (same-priv AND cross-priv
        // non-call); the call gate re-derives its own width below.
        bd_wstrb = (int_frm16 && !cg_xpl) ? 4'b0011 : 4'b1111;
        if (from_v86) begin
          // M7.2 V86: push the 9-WORD V86 frame (+errcode) descending from the NEW
          // (TSS.SS0) stack. seg_base[SG_SS] is the CPL0 SS base loaded in S_INT_SS.
          // Beats, low->high stored value (matches the monitor's frame offsets):
          //   0 GS @ esp-4, 1 FS @ esp-8, 2 DS @ esp-12, 3 ES @ esp-16,
          //   4 SS @ esp-20, 5 ESP @ esp-24, 6 EFLAGS @ esp-28, 7 CS @ esp-32,
          //   8 EIP @ esp-36, 9 errcode @ esp-40.  (R2-M02: address via cur_lin.)
          unique case (int_step)
            4'd0:    bd_wdata = {16'd0, int_old_gs};
            4'd1:    bd_wdata = {16'd0, int_old_fs};
            4'd2:    bd_wdata = {16'd0, int_old_ds};
            4'd3:    bd_wdata = {16'd0, int_old_es};
            4'd4:    bd_wdata = {16'd0, int_old_ss};
            4'd5:    bd_wdata = int_old_esp;
            4'd6:    bd_wdata = int_old_eflags;        // V86 EFLAGS (VM still set)
            4'd7:    bd_wdata = {16'd0, int_old_cs};   // interrupted V86 CS
            4'd8:    bd_wdata = int_ret_eip;           // V86 EIP (faulting)
            default: bd_wdata = int_err;               // beat 9: #GP error code (0)
          endcase
        end else if (xpl_active && cg_xpl) begin
          // REVIEW1_Aug3 R2-H05: the cross-privilege CALL-GATE frame, in
          // gate-width units with the parameter copy inline. Beats (cg_beat),
          // descending from the TSS stack pointer:
          //   0 old SS, 1 old ESP (SP low word for a 16-bit gate),
          //   2..1+n params (highest-address param FIRST: QEMU's copy loop
          //   reads i = n-1 downto 0 and pushes each, so push beat b stores
          //   cg_params[n+1-b]), 2+n old CS, 3+n return EIP (IP word).
          // The offset wraps per the NEW stack's B bit (stk16 -- ss_b is the
          // installed new stack here), matching QEMU's PUSHW/PUSHL sp_mask.
          // (R2-M02: address via cur_lin.)
          bd_wstrb = cg_wide ? 4'b1111 : 4'b0011;
          if (cg_beat == 6'd0)
            bd_wdata = {16'd0, int_old_ss};
          else if (cg_beat == 6'd1)
            bd_wdata = cg_wide ? int_old_esp : {16'd0, int_old_esp[15:0]};
          else if (cg_beat < (6'd2 + {1'b0, cg_pcount})) begin
            logic [4:0] pidx;
            pidx = cg_pcount + 5'd1 - cg_beat[4:0];
            bd_wdata = cg_wide ? cg_params[pidx] : {16'd0, cg_params[pidx][15:0]};
          end else if (cg_beat == (6'd2 + {1'b0, cg_pcount}))
            bd_wdata = {16'd0, int_old_cs};
          else
            bd_wdata = cg_wide ? int_ret_eip : {16'd0, int_ret_eip[15:0]};
        end else if (xpl_active) begin
          // M2S.4 CROSS-PRIV: push the LARGER 5-word (or 6-word w/ errcode) frame
          // descending from the NEW stack (TSS.espN). seg_base[SG_SS] is already
          // the new (CPL0) SS base after S_INT_SS. Beats, low->high stored value:
          //   32-bit gate: 0 old SS @ esp-4, 1 old ESP @ esp-8, 2 EFLAGS @ esp-12,
          //     3 CS @ esp-16, 4 EIP @ esp-20, 5 errcode @ esp-24.
          //   A4-H03 16-bit gate: 0 old SS @ sp-2, 1 old SP @ sp-4, 2 FLAGS @ sp-6,
          //     3 CS @ sp-8, 4 IP @ sp-10, 5 errcode @ sp-12 (word slots, low-half
          //     strobe -- one width decision, int_frm16).
          // (R2-M02: address via cur_lin.)
          // REVIEW2_aug2 C-06: a cross-privilege CALL GATE reuses this frame, minus
          // the EFLAGS word -- a far CALL does not save flags. So under cg_xpl the
          // frame is old SS, old ESP, return CS, return EIP (4 dwords, 16 bytes) and
          // beat 2 is CS rather than EFLAGS.
          if (int_frm16 && !cg_xpl) begin
            unique case (int_step)
              4'd0:    bd_wdata = {16'd0, int_old_ss};
              4'd1:    bd_wdata = {16'd0, int_old_esp[15:0]};
              4'd2:    bd_wdata = {16'd0, eflags[15:0]};
              4'd3:    bd_wdata = {16'd0, int_old_cs};
              4'd4:    bd_wdata = {16'd0, int_ret_eip[15:0]};
              default: bd_wdata = {16'd0, int_err[15:0]};
            endcase
          end else begin
          unique case (int_step)
            4'd0:    bd_wdata = {16'd0, int_old_ss};
            4'd1:    bd_wdata = int_old_esp;
            4'd2:    bd_wdata = cg_xpl ? {16'd0, int_old_cs} : eflags;
            4'd3:    bd_wdata = cg_xpl ? int_ret_eip : {16'd0, int_old_cs};
            4'd4:    bd_wdata = int_ret_eip;
            default: bd_wdata = int_err;
          endcase
          end
        end else if (int_gate_op16) begin
          // SAME-PRIV 16-BIT GATE (mirrors the real-mode S_RMINT_PUSH 6-byte frame):
          // beat 0 FLAGS @ ESP-2, 1 CS @ ESP-4, 2 IP @ ESP-6 (2-byte slots). The
          // memmodel applies wstrb byte i to byte addr+i (memmodel.cpp:96-99), so a
          // wstrb=4'b0011 low-half write lands the 16-bit value at [addr..addr+1]
          // regardless of dword alignment — no byte-lane shift needed, exactly like
          // S_RMINT_PUSH. (errcode is impossible on a same-priv 16-bit software/HW
          // delivery in this corpus, but mirror the low-half default anyway.)
          // (R2-M02: address via cur_lin.)
          unique case (int_step)
            4'd0:    bd_wdata = {16'd0, eflags[15:0]};
            4'd1:    bd_wdata = {16'd0, int_old_cs};   // interrupted CS (NOT handler) - DOS-Quake #GP fix
            4'd2:    bd_wdata = {16'd0, int_ret_eip[15:0]};
            default: bd_wdata = {16'd0, int_err[15:0]};
          endcase
        end else begin
          // SAME-PRIV 32-BIT GATE: beat 0 EFLAGS @ ESP-4, 1 CS @ ESP-8, 2 EIP @
          // ESP-12, 3 errcode @ ESP-16. The push uses the SS base (flat 0 here).
          // (R2-M02: address via cur_lin.)
          unique case (int_step)
            4'd0:    bd_wdata = eflags;
            4'd1:    bd_wdata = {16'd0, int_old_cs};   // interrupted CS (NOT handler) - DOS-Quake #GP fix
            4'd2:    bd_wdata = int_ret_eip;
            default: bd_wdata = int_err;
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
      S_IRET_SS: begin bd_req =1'b1;
      end
      S_IRET: begin bd_req =1'b1;                // pop EIP/CS/EFLAGS[+ESP/SS] asc
        // (REVIEW1_Aug2 C-01: SS-relative -- the segment identity block above.)
        // Read only the current word/dword slot, matching cur_size. In
        // particular, uncached/MMIO stack reads may not consume two extra
        // bytes. Addresses and SS.B wrapping come from cur_lin (R2-M02).
        bd_wstrb = int_gate_op16 ? 4'b0011 : 4'b1111;
      end
      S_INT_CS_RET: begin bd_req =1'b1;          // reload returned-to CS descriptor (TI: GDT/LDT; cur_lin)
      end
      // M2S.4 — TR/TSS reads. (R2-M02: family 1 — all addressed by cur_lin and
      // translated by the post-stage like any other linear access.)
      S_LTR: begin
        // REVIEW_Aug3 H-11b: two new shapes. A null LLDT (lldt_null_q) issues NO
        // descriptor read -- the FSM commits the invalid LDTR directly, so GDT[0]
        // is never touched (it could #PF under paging). An LTR busy beat
        // (ltr_busy_q) writes type 9->B at descriptor+5 before TR commits,
        // mirroring the S_TSW_BUSY single-byte form.
        bd_req = !lldt_null_q;
        if (ltr_busy_q) begin
          bd_we = 1'b1;
          bd_wstrb = 4'b0010;
          bd_wdata = {16'd0, (ltr_attr_q | 8'h02), 8'd0};
        end
        // (R2-M02: both address shapes via cur_lin.)
      end
      // REVIEW1_Aug2 M-03: beat 0 = TSS+0x66 (the I/O map base); beat 1 = the dword
      // holding the bitmap byte for this port. Both are TSS-relative and LINEAR, so
      // this arm sets no cur_seg_rel (see the C-01 default at the top).
      S_NTRET_RD: begin bd_req =1'b1; end   // tr_base (R2-M02: via cur_lin)
      S_IOPERM: begin bd_req =1'b1;
      end
      S_INT_TSS: begin bd_req =1'b1;             // TSS.ssN:espN (ESPn then SSn; cur_lin)
      end
      S_INT_SS: begin bd_req =1'b1;              // new SS descriptor (TI picks GDT/LDT; cur_lin)
      end
      // M2S.4b — HARDWARE TASK SWITCH accesses. (R2-M02: family 2 — every state
      // here is translatable since REVIEW1_Aug2 C-09, so the address lines are
      // deleted and cur_lin drives them; the cur_lin mirrors in core.sv match
      // the deleted arms exactly, staged-LDT base and busy-beat order included.
      // req/we/wstrb/wdata stay.)
      S_TSW_SAVE: begin bd_req =1'b1; bd_we =1'b1; bd_wstrb =4'b1111;
        // write the outgoing state into the CURRENT TSS (tr_base) at the 32-bit
        // TSS offsets: 0 EIP@0x20, 1 EFLAGS@0x24, 2..9 GPR@0x28..0x44,
        // 10..15 ES/CS/SS/DS/FS/GS@0x48..0x5C, 16 LDTR@0x60.
        unique case (tsw_step)
          5'd0:    bd_wdata = tsw_save_eip;
          // R2-H04: the staged outgoing image (NT already cleared for an NT
          // return at the S_LJMP arm) -- live EFLAGS is no longer mutated early.
          5'd1:    bd_wdata = tsw_save_eflags;
          5'd2,5'd3,5'd4,5'd5,5'd6,5'd7,5'd8,5'd9:
                   bd_wdata = gpr_o[3'(tsw_step - 5'd2)];
          5'd10:   bd_wdata = {16'd0, seg_sel[SG_ES]};
          5'd11:   bd_wdata = {16'd0, seg_sel[SG_CS]};
          5'd12:   bd_wdata = {16'd0, seg_sel[SG_SS]};
          5'd13:   bd_wdata = {16'd0, seg_sel[SG_DS]};
          5'd14:   bd_wdata = {16'd0, seg_sel[SG_FS]};
          5'd15:   bd_wdata = {16'd0, seg_sel[SG_GS]};
          default: bd_wdata = 32'd0;   // beat 16: LDTR (no LDT tracked => 0)
        endcase
      end
      S_TSW_READ: begin bd_req =1'b1;            // read the incoming TSS state (cur_lin)
      end
      S_TSW_LDT: begin bd_req =1'b1;             // new task's LDT descriptor @ GDT (cur_lin)
      end
      // REVIEW2_aug2 C-05: NO descriptor read for a V86 incoming task -- its segment
      // values are real-mode paragraphs, and indexing the GDT with them reads an
      // arbitrary linear address that can #PF under paging. core_tsw.svh advances the
      // beat cadence itself in that case, so suppressing the request here cannot stall.
      S_TSW_SEG: begin bd_req =!tsw_eflags[17] && !tsw_seg_oob && !tsw_seg_null;  // reload incoming seg descriptors
        // beat = seg_idx*2 + half; the selector for seg_idx is tsw_sel[seg_idx]
        // (CS,SS,DS,ES,FS,GS order). TI bit (sel[2]) picks GDT vs the just-loaded LDT.
        // REVIEW2_aug2 C-05: the INCOMING task's LDT is staged (tsw_st_ldt_base) and
        // is not committed to ldt_base until S_TSW_BUSY, so address through the staged
        // copy. Using the live ldt_base here would resolve the new task's TI=1
        // selectors through the OUTGOING task's LDT. (R2-M02: address via cur_lin,
        // which carries the same staged-base expression.)
      end
      S_TSW_BUSY: begin bd_req =1'b1; bd_we =1'b1; bd_wstrb =4'b0010;
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
          bd_wdata = {16'd0, tsw_new_attr, 8'd0};         // incoming -> busy
        end else if (tsw_call) begin
          // REVIEW_Aug3 C-04: a CALL task switch writes the OUTGOING TR selector
          // into the incoming TSS's back-link field (offset 0, a word) and leaves
          // the outgoing descriptor BUSY -- the caller remains an active task and
          // is returned to via NT-IRET, which is exactly what the busy bit means.
          bd_wdata = {16'd0, tr_sel};
          bd_wstrb = 4'b0011;
        end else begin
          bd_wdata = {16'd0, (tr_attr & ~8'h02), 8'd0};   // outgoing -> available
        end
        // (R2-M02: all three address shapes via cur_lin.)
      end
      // M2S.5 — SMRAM save-map accesses. The SMRAM region is addressed PHYSICALLY
      // (SMBASE+0x8000+offset). SMM runs with paging off in the corpus, and the
      // save map is a fixed physical structure, so (like the descriptor/TSS reads)
      // these are NOT re-translated by the post-stage below.
      S_SMI_SAVE: begin bd_req =1'b1; bd_we =1'b1; bd_wstrb =4'b1111;
        bd_addr = smbase + 32'h0000_8000 + {16'd0, smm_off(smm_step)};
        bd_wdata = smm_save_data(smm_step);
      end
      S_RSM: begin bd_req =1'b1;                  // read the save map back
        bd_addr = smbase + 32'h0000_8000 + {16'd0, smm_off(smm_step)};
      end
      default: ;
    endcase
    // =========================================================================
    // REVIEW1_Aug3 R2-M02: THE CANONICAL REQUEST ADDRESS, UNCONDITIONAL.
    //
    // The FIRST migration attempt deleted family-1's address arms outright, on
    // the reading that the REVIEW2_aug2 C-04 override made them dead. It did
    // not: the override lived INSIDE the paging_on block, so with paging OFF
    // the arms were the only address source (measured: pcpl's LTR descriptor
    // read went to the top-of-block default and #GP'd at the LTR -- every
    // p* test that reaches an LTR/cross-priv gate unpaged wedged the same way).
    //
    // The collapse is done properly here instead: the override is UNCONDITIONAL.
    // For a translatable state the architectural linear address is cur_lin --
    // with paging on, the TLB looked it up and the walk filled it; with paging
    // off, linear == physical and cur_lin == cur_lin_nat is exactly the address
    // the deleted arms computed. States that are NOT translatable (real-mode
    // machinery, S_WALK, S_SMI_SAVE/S_RSM) keep their own arms untouched.
    if (fe_translatable) bd_addr = cur_lin;
    mem_addr_pre = bd_addr;
    // ---- paging post-translation: linear -> physical. EVERYTHING translatable
    // passes through here -- data/fetch, the descriptor/TSS-structure reads
    // (they are architecturally LINEAR structures), and the task-switch
    // microsequence. Only two exclusions remain, both correct: S_WALK (a
    // page-table walk is physical by definition) and S_SMI_SAVE/S_RSM (the SMM
    // save map is architecturally physical).
    if (paging_on && state != S_WALK &&
        state != S_SMI_SAVE && state != S_RSM) begin
      // CRITICAL (Phase-3 [high] fix): on a TLB MISS this clock the FSM diverts to
      // S_WALK (the clocked block, gated on the same `xlate_miss`), so the bus this
      // clock belongs to the PAGE WALK, not to this state's access. But `state` is
      // still the access state combinationally, so without this guard the driver
      // would assert bd_req (and, on a WRITE state, bd_we) with bd_addr =
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
      // (R2-M02: the mem_addr_arm snapshot is gone with CHECK 5; the cur_lin
      // override above is unconditional.)
      // REVIEW2 C-01: a permission fault must produce NO side effect -- no bus
      // transaction, no cache fill, no A/D writeback. Squash exactly like a TLB
      // miss does; the FSM arm below delivers the #PF on this same clock.
      if (xlate_miss || fe_xlate_pend || perm_fault) begin
        bd_req =1'b0; bd_we =1'b0; bd_addr =32'd0; bd_wdata =32'd0; bd_wstrb =4'd0;
      end else if (bd_req) begin
        bd_addr = mem_xlate(bd_addr, cur_is_d);
      end
    end
    // =========================================================================
    // REVIEW1_Aug2 C-01: a SEGMENT fault must suppress the faulting access.
    // =========================================================================
    // seg_access_fault was consumed by the FSM (core.sv, beside perm_fault) but was
    // NOT in the squash list above, so on a TLB hit -- or with paging off entirely --
    // the same clock both called start_fault(13) AND presented bd_req/bd_we to RAM,
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
    // bd_req makes it silent exactly when it matters).
    // A cancellable REP-STOS shadow is not an attempted access yet.  Keep it
    // out of the pre-squash observation too: otherwise fragment/SMC auxiliary
    // logic could treat an event-cancelled descriptor as a real request while
    // the final bus pins are blanked below.
    mem_req_pre_sq = bd_req && !rep_stos_stream_preissue_block &&
                              !rep_movs_stream_preissue_block;
    if (sync_access_fault || rep_stos_stream_preissue_block ||
        rep_movs_stream_preissue_block) begin
      bd_req =1'b0; bd_we =1'b0; bd_addr =32'd0; bd_wdata =32'd0; bd_wstrb =4'd0;
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
    // Here, at the end of the driver, bd_addr is the final physical address in EVERY
    // mode -- real mode (linear == physical), protected mode without paging, and
    // paged mode after mem_xlate(). That is where the gate sits on real silicon (on
    // the address pins), so one expression covers data, I-cache fills and page-walk
    // reads, and the physically-tagged L1D aliases correctly because it never sees
    // the unmasked bit.
    //
    // a20_on = the platform override AND the software latch (port 0x92 bit 1, latched
    // in the core's S_IO arm). Both default and reset to 1 = A20 ENABLED = no masking,
    // so every existing configuration is bit-identical until software clears it.
    if (bd_req && !a20_on) bd_addr[20] = 1'b0;
    if (fp_async_hold) bd_req = 1'b0;

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
    if (bd_req && paging_on && fe_translatable
        && (({20'd0, mem_addr_pre[11:0]} + {29'd0, c02_bytes} - 32'd1) > 32'd4095))
      c02_xpage_hits = 1'b1;
    else
      c02_xpage_hits = 1'b0;
`endif
  end
