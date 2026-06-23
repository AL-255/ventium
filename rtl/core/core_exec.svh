// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/core_exec.svh — RAW case-arm text `included inside core.sv's always_ff
// `unique case (state)` (R2 modularization). NOT a standalone unit (no module/
// always wrapper); pasted verbatim at the original FSM site, netlist identical.
// Covers the largest single arm — the integer execute/commit:
//   S_EXEC (ALU/flags commit, flag ops, MUL/DIV, sys-op dispatch incl. the
//   SYS_* -> S_LGDT/S_SEGLD/S_LJMP/S_LTR routing and INT/IRET entry).
// Its block-local `automatic` vars (do_store/new_eip/flags_*) are declared
// inside this arm's begin/end, so they travel with the text.
        // -------------------------------------------------------------------
        S_EXEC: begin
          logic do_store, do_retire;
          logic [31:0] new_eip;
          logic flags_we;
          logic [31:0] flags_val;
          do_store=1'b0; do_retire=1'b1; new_eip=next_eip; flags_we=q_writes_flags; flags_val=flags_out;

          if (q_cld) begin eflags<=eflags & ~32'h0000_0400; flags_we=1'b0; end
          else if (q_std) begin eflags<=eflags | 32'h0000_0400; flags_we=1'b0; end
          else if (q_clc) begin eflags<=eflags & ~32'h0000_0001; flags_we=1'b0; end // CF<-0
          else if (q_stc) begin eflags<=eflags | 32'h0000_0001;  flags_we=1'b0; end // CF<-1
          else if (q_cmc) begin eflags<=eflags ^ 32'h0000_0001;  flags_we=1'b0; end // CF<-~CF
          else if (q_cli) begin eflags<=eflags & ~32'h0000_0200; flags_we=1'b0; end // IF<-0
          else if (q_sti) begin eflags<=eflags | 32'h0000_0200;  flags_we=1'b0;     // IF<-1
            // M8.1: STI sets IF but the interrupt window stays SHADOWED for exactly
            // the one instruction that follows STI (IA-32 HF_INHIBIT_IRQ). Set the
            // shadow here (in S_EXEC, the STI's retire clock); the next S_DECODE
            // boundary sees it set (INTR blocked for that one instruction) and clears
            // it. INERT when soc_en==0 (irq_shadow is only ever read by intr_take).
            irq_shadow <= 1'b1;
          end // IF<-1
          // ---- M2S.1 system ops with no memory operand --------------------
          else if (q_sysop==SYS_MOVCR_TO) begin
            // MOV CRn, r32. M2S.1 made CR0.PE active (real->protected); M2S.2 makes
            // CR0.PG (paging enable), CR3 (PDBR) and CR4.PSE active. Writing CR0.PE
            // is the real->protected transition; writing CR0.PG turns paging on
            // (its own retire record, cr0 0x6...->0xe...). A CR3 load (new page-
            // directory base) flushes the TLBs (IA-32 §4.10: MOV CR3 invalidates
            // all non-global TLB entries) — for the gate this happens with PG still
            // 0 so the TLBs are already empty, but the flush keeps it correct.
            flags_we=1'b0;
            unique case (q_sys_creg)
              3'd0: creg0<=gpr_o[q_src_reg];
              3'd2: creg2<=gpr_o[q_src_reg];
              3'd3: begin
                creg3<=gpr_o[q_src_reg];
                // TLB flush (clear val bits only) now lands in u_itlb/u_dtlb via
                // tlb_flush (driven combinationally from this exact MOV CR3
                // condition; see the flush driver at the TLB instantiation).
              end
              default: creg4<=gpr_o[q_src_reg];
            endcase
          end
          else if (q_sysop==SYS_MOVCR_FROM) begin
            // MOV r32, CRn. R3: the dst-reg<-CRn write moved to the gpr writeback
            // driver (core_gpr_wb.svh, SYS_MOVCR_FROM arm).
            flags_we=1'b0;
          end
          // ---- M2S.6 MOV DRn <-> GPR (gated sys_mode via the sysop decode) ----
          // DR4/DR5 alias DR6/DR7 ONLY when CR4.DE=0 (P5 debug-extensions). When
          // CR4.DE=1 a MOV DR4/DR5 is #UD and is diverted in S_DECODE BEFORE we get
          // here, so reaching the 3'd4/3'd5 arms below implies CR4.DE=0 (legacy
          // alias). On WRITE the reserved-1 bits are forced (DR6 |= 0xFFFF0FF0,
          // DR7 |= 0x400) so the read-back is deterministic — qemu helper_set_dr does
          // exactly this in 32-bit mode (the upper-32 reserved mask never bites). A
          // GD-fault (DR7.GD set) is also taken BEFORE the access in S_DECODE, so by
          // the time we get here GD is not a concern for this op.
          else if (q_sysop==SYS_MOVDR_TO) begin
            flags_we=1'b0;
            unique case (q_sys_creg)
              3'd0: dr0 <= gpr_o[q_src_reg];
              3'd1: dr1 <= gpr_o[q_src_reg];
              3'd2: dr2 <= gpr_o[q_src_reg];
              3'd3: dr3 <= gpr_o[q_src_reg];
              // DR4 aliases DR6, DR5 aliases DR7 (CR4.DE=0; the corpus keeps DE=0).
              3'd4, 3'd6: dr6 <= gpr_o[q_src_reg] | DR6_FIXED_1;
              default:    dr7 <= gpr_o[q_src_reg] | DR7_FIXED_1;  // DR5/DR7
            endcase
          end
          else if (q_sysop==SYS_MOVDR_FROM) begin
            // R3: the dst-reg<-DRn write moved to the gpr writeback driver
            // (core_gpr_wb.svh, SYS_MOVDR_FROM arm).
            flags_we=1'b0;
          end
          else if (q_sysop==SYS_MOVSREG_FROM) begin
            // MOV r/m16, Sreg. R3: the dst-reg<-selector write moved to the gpr
            // writeback driver (core_gpr_wb.svh, SYS_MOVSREG_FROM arm).
            flags_we=1'b0;
          end
          else if (q_sysop==SYS_STR) begin
            // STR r/m16. R3: the dst-reg<-TR-selector write moved to the gpr
            // writeback driver (core_gpr_wb.svh, SYS_STR arm).
            flags_we=1'b0;
          end
          else if (q_sysop==SYS_MOVSREG_TO && !sys_mode && proxy_en) begin
            // M7.1 USER+proxy MOV Sreg, r16 (linux-user, no GDT): selector :=
            // value; the hidden base is FLAT (0) EXCEPT a %gs load of the musl TLS
            // GDT selector 0x33, which installs the latched gs_base (the
            // set_thread_area TLS base the proxy captured). This is exactly QEMU's
            // linux-user behaviour: `mov gs,0x33` makes %gs:off resolve at the TLS
            // base; every other flat user selector keeps base 0. The limit/attr
            // are the flat 4 GB data defaults (unused by the func compare).
            flags_we=1'b0;
            seg_sel [q_sys_sreg] <= gpr_o[q_src_reg][15:0];
            if (q_sys_sreg == 3'(SG_GS) && gpr_o[q_src_reg][15:0]==16'h0033)
              seg_base[q_sys_sreg] <= gs_base_r;        // TLS base for %gs:off
            else
              seg_base[q_sys_sreg] <= 32'd0;            // flat
            seg_limit[q_sys_sreg]<= 32'hFFFF_FFFF;
            seg_attr [q_sys_sreg]<= 8'h93;
`ifdef M7_PROXY_DEBUG
            $display("[M7DBG] mov sreg=%0d sel=0x%04x gs_base_r=0x%08x -> base=0x%08x",
                     q_sys_sreg, gpr_o[q_src_reg][15:0], gs_base_r,
                     (q_sys_sreg==3'(SG_GS) && gpr_o[q_src_reg][15:0]==16'h0033) ? gs_base_r : 32'd0);
`endif
          end
          else if (q_sysop==SYS_MOVSREG_TO) begin
            // REAL-MODE MOV Sreg, r16: selector = value; hidden base = sel<<4.
            // Real mode does no descriptor / protection checks (no GDT consulted);
            // the hidden attr stays the present R/W data default.
            flags_we=1'b0;
            seg_sel [q_sys_sreg] <= gpr_o[q_src_reg][15:0];
            seg_base[q_sys_sreg] <= {12'd0, gpr_o[q_src_reg][15:0], 4'd0};
            seg_limit[q_sys_sreg]<= 32'h0000_FFFF;
            seg_attr [q_sys_sreg]<= 8'h93;
          end
          else if (q_sysop==SYS_LJMP) begin
            // REAL-MODE far jump: CS.sel = sel, CS.base = sel<<4, EIP = off.
            flags_we=1'b0;
            seg_sel [SG_CS] <= q_ljmp_sel;
            seg_base[SG_CS] <= {12'd0, q_ljmp_sel, 4'd0};
            seg_attr[SG_CS] <= 8'h9B;
            new_eip = q_ljmp_off;
          end
          else begin
            unique case (q_kind)
              K_ALU: begin
                // R3: all GPR writes in this arm (XLATB AL, LEA dst, POP dst/ESP,
                // ALU dst) moved to the gpr writeback driver (core_gpr_wb.svh,
                // K_ALU arm). Only the flags/store/state/seg-load logic stays here.
                if (q_xlat) begin
                  // XLATB: AL <- the byte loaded from [DS:(E)BX + AL]. No flags.
                  flags_we=1'b0;
                end
                else if (q_is_lea) begin end
                else if (q_is_pop && q_mem_write) begin
                  // POP m: stack value (mem_load_data) -> memory dest; ESP += w.
                  do_store=1'b1; do_retire=1'b0;
                end else if (q_is_pop && q_pop_sreg) begin
                  // F3 POP sreg (07/17/1F = ES/SS/DS). The selector comes off the
                  // stack (mem_load_data). ESP += w happens in the gpr writeback
                  // driver regardless of the branch taken below.
                  //   REAL/V86 (seg_real): hidden base = sel<<4, no GDT consulted.
                  //   PROTECTED  (!seg_real): the popped value is a PM SELECTOR — it
                  //     must be walked through the GDT/LDT exactly like MOV Sreg,r/m
                  //     (the S_SEGLD path). Computing base=sel<<4 in PM was the
                  //     DOS-Quake (task #102) bug: CWSDPMI's reflector does `pop ds`
                  //     (ds=0x33, GDT[6] base 0x2b570) and the sel<<4 shortcut stored
                  //     base 0x330 -> the dispatch vector landed at the wrong linear
                  //     and the CPL0 read-back saw 0 ("Division by Zero" abort).
                  if (seg_real) begin
                    seg_sel [q_sys_sreg] <= mem_load_data[15:0];
                    seg_base[q_sys_sreg] <= {12'd0, mem_load_data[15:0], 4'd0};
                  end else begin
                    // PM: latch the popped selector and walk the descriptor in
                    // S_SEGLD (target = q_lseg). Suppress this S_EXEC retire; the
                    // ESP increment still commits this cycle (gpr writeback driver).
                    seg_mem_sel    <= mem_load_data[15:0];
                    q_lseg         <= q_sys_sreg;
                    q_seg_from_mem <= 1'b1;
                    do_retire       = 1'b0;
                    state          <= S_SEGLD;
                  end
                end else if (q_is_pop) begin
                end else if (q_mem_write) begin do_store=1'b1; do_retire=1'b0; end
                else if (q_writes_reg) begin end
                // M9.5 LES/LDS/LSS/LFS/LGS: on top of the GPR (offset) write above,
                // load the target segment register from the HIGH half of the SAME
                // 4-byte far-pointer read (raw mem_load_data, not the width-masked
                // alu_out). Real mode: base = sel<<4, the present R/W data default.
                // Only decoded under seg_real + 16-bit operand (else HALT), so this
                // real-mode load is the only path reached.
                if (q_seg_load) begin
                  if (!seg_real && q_seg_load_lo) begin
                    // PM MOV Sreg,[mem]: the loaded 2-byte value is a PROTECTED-mode
                    // selector — latch it and walk the GDT/LDT descriptor in S_SEGLD
                    // (target seg = q_lseg). Suppress this S_EXEC retire.
                    seg_mem_sel    <= mem_load_data[15:0];
                    q_seg_from_mem <= 1'b1;
                    do_retire       = 1'b0;
                    state          <= S_SEGLD;
                  end else begin
                    // F3 MOV Sreg,[mem]: the 2-byte read IS the selector (LOW half);
                    // LES/LDS read a 4-byte far pointer and take the selector from the
                    // HIGH half. Both load base=sel<<4 (real/v86), limit 0xFFFF, attr 0x93.
                    seg_sel  [q_lseg] <= q_seg_load_lo ? mem_load_data[15:0]  : mem_load_data[31:16];
                    seg_base [q_lseg] <= q_seg_load_lo ? {12'd0, mem_load_data[15:0],  4'd0}
                                                       : {12'd0, mem_load_data[31:16], 4'd0};
                    seg_limit[q_lseg] <= 32'h0000_FFFF;
                    seg_attr [q_lseg] <= 8'h93;
                  end
                end
              end

              K_SHIFT: begin
                // count masked to 0 -> NO flag change, NO value change (QEMU).
                if (sh_cnt==6'd0) begin
                  flags_we=1'b0;
                  if (q_mem_write) begin do_store=1'b1; do_retire=1'b0; end
                end else begin
                  // R3: the dst-reg shift result write moved to the gpr writeback
                  // driver (core_gpr_wb.svh, K_SHIFT arm); only flags/store stay.
                  if (q_mem_write) begin do_store=1'b1; do_retire=1'b0; end
                  begin
                    logic [31:0] fl; logic ofb;
                    fl=eflags;
                    if (q_shrot inside {3'd4,3'd5,3'd6,3'd7}) begin
                      // SHL/SHR/SAR: SF/ZF/PF from result, AF=0, CF & OF per QEMU
                      // (CC_DST=result, CC_SRC=shm1): OF = MSB(shm1) ^ MSB(result).
                      fl=eflags & 32'hFFFF_F72A;
                      fl[0]=sh_cfout; fl[2]=parity8(sh_out[7:0]); fl[4]=1'b0;
                      fl[6]=(wmask(sh_out,q_w)==32'd0); fl[7]=sbit(sh_out,q_w);
                      fl[11]=sbit(sh_shm1,q_w) ^ sbit(sh_out,q_w);
                      fl[1]=1'b1;
                    end else begin
                      // ROL/ROR/RCL/RCR: only CF and OF change.
                      unique case (q_shrot)
                        3'd0: ofb = sbit(sh_out,q_w) ^ sh_out[0];               // ROL: MSB^LSB(res)
                        3'd1: ofb = sbit(sh_out,q_w) ^ sbit2(sh_out,q_w);       // ROR: MSB^(MSB-1)(res)
                        default: ofb = sbit(sh_val,q_w) ^ sbit(sh_out,q_w);     // RCL/RCR: MSB(src)^MSB(res)
                      endcase
                      fl[0]=sh_cfout; fl[11]=ofb; fl[1]=1'b1;
                    end
                    eflags<=fl;
                  end
                  flags_we=1'b0;
                end
              end

              K_SHLDRD: begin
                logic [31:0] shm1;
                // R3 HOIST: cnt (ex_shld_cnt) and the SHLD/SHRD result r (ex_shld_r)
                // are computed ONCE at module scope (core.sv) and shared with the gpr
                // writeback driver (core_gpr_wb.svh, K_SHLDRD arm). shm1 is FSM-only
                // (feeds the OF flag; the driver never needs it) so it stays here.
                if (ex_shld_cnt==6'd0) flags_we=1'b0;
                else begin
                  // shm1 = dst shifted by (count-1) (same direction) = QEMU CC_SRC.
                  shm1 = q_shrd ? (wmask(dst_cur,q_w) >> (ex_shld_cnt-6'd1))
                                : wmask(wmask(dst_cur,q_w) << (ex_shld_cnt-6'd1), q_w);
                  begin logic [31:0] fl;
                    fl=eflags & 32'hFFFF_F72A;
                    fl[0]=shld_cf(q_shrd, dst_cur, ex_shld_cnt, q_w); fl[2]=parity8(ex_shld_r[7:0]); fl[4]=1'b0;
                    fl[6]=(wmask(ex_shld_r,q_w)==32'd0); fl[7]=sbit(ex_shld_r,q_w);
                    fl[11]=sbit(shm1,q_w)^sbit(ex_shld_r,q_w); fl[1]=1'b1;
                    eflags<=fl;
                  end
                  flags_we=1'b0;
                end
              end

              K_MULDIV: begin
                // R3 HOIST: ex_srcv (the source operand), ex_mul_p / ex_imul_p
                // (the ONE multiplier) and ex_div_*/ex_idiv_* (the ONE native
                // divider) are computed at module scope (core.sv) and shared with
                // the gpr writeback driver (core_gpr_wb.svh, K_MULDIV arm). Here we
                // derive only the flag inputs (lo/ovf) + the #DE / occupancy effects.
                unique case (q_md)
                  3'd4: begin // MUL (unsigned)
                    logic [31:0] lo; logic ovf; logic [31:0] fl;
                    // R3: EAX/EDX product commit moved to the gpr writeback driver
                    // (core_gpr_wb.svh, K_MULDIV/3'd4); lo/ovf stay (feed flags).
                    if (q_w==3'd1) begin lo={24'd0,ex_mul_p[7:0]};  ovf=(ex_mul_p[15:8]!=8'd0);  end
                    else if (q_w==3'd2) begin lo={16'd0,ex_mul_p[15:0]}; ovf=(ex_mul_p[31:16]!=16'd0); end
                    else begin lo=ex_mul_p[31:0]; ovf=(ex_mul_p[63:32]!=32'd0); end
                    // QEMU compute_all_mul: ZF/SF/PF from low result, AF=0, CF=OF=ovf
                    fl=eflags&32'hFFFF_F72A; fl[1]=1'b1;
                    fl[0]=ovf; fl[11]=ovf; fl[2]=parity8(lo[7:0]); fl[4]=1'b0;
                    fl[6]=(wmask(lo,q_w)==32'd0); fl[7]=sbit(lo,q_w);
                    eflags<=fl; flags_we=1'b0;
                    // P5 MULTIPLY OCCUPANCY (cycle-modeled, p5model occ MUL=10, NP,
                    // U-pipe). The native `*` (now ex_mul_p) is the bit-exact result;
                    // the modeled occupancy is the deferred penalty occ-7 = 3 (same
                    // mechanism + measured slow-FSM base as the DIV occupancy below).
                    pending_mem_pen <= 7'd3;
                  end
                  3'd5: begin // IMUL one-operand (signed)
                    logic [31:0] lo; logic ovf; logic [31:0] fl;
                    // R3: EAX/EDX product commit moved to the gpr writeback driver
                    // (core_gpr_wb.svh, K_MULDIV/3'd5); lo/ovf stay (feed flags).
                    if (q_w==3'd1) begin lo={24'd0,ex_imul_p[7:0]};  ovf=($signed(ex_imul_p)!=$signed({{56{ex_imul_p[7]}},ex_imul_p[7:0]}));   end
                    else if (q_w==3'd2) begin lo={16'd0,ex_imul_p[15:0]}; ovf=($signed(ex_imul_p)!=$signed({{48{ex_imul_p[15]}},ex_imul_p[15:0]})); end
                    else begin lo=ex_imul_p[31:0]; ovf=($signed(ex_imul_p)!=$signed({{32{ex_imul_p[31]}},ex_imul_p[31:0]})); end
                    fl=eflags&32'hFFFF_F72A; fl[1]=1'b1;
                    fl[0]=ovf; fl[11]=ovf; fl[2]=parity8(lo[7:0]); fl[4]=1'b0;
                    fl[6]=(wmask(lo,q_w)==32'd0); fl[7]=sbit(lo,q_w);
                    eflags<=fl; flags_we=1'b0;
                    pending_mem_pen <= 7'd3;   // P5 IMUL occupancy (occ=10, occ-7)
                  end
                  3'd6: begin // DIV (unsigned) — with #DE (divide-by-zero / overflow)
`ifdef VEN_IDIV_ITER
                    // route to the iterative integer divider (ven_idiv); EAX/EDX +
                    // #DE commit on `done` in S_DIV_BUSY (engine started in core.sv).
                    flags_we=1'b0; do_retire=1'b0; state<=S_DIV_BUSY;
`ifdef VEN_DBG_CORE
                    dbg_de_num_r<=eng_int_num; dbg_de_den_r<=eng_int_den;
                    dbg_de_w_r<=q_w; dbg_de_eip_r<=q_pc;   // divide-#DE tap: latch operands
                    if (dbg_hook_cfg[0] && dbg_hook_cfg[1]) begin  // opcode-hook: DIV class
                      dbg_hook_seq<=dbg_hook_seq+8'd1; dbg_hook_eip<=q_pc;
                      dbg_hook_opa<=eng_int_num; dbg_hook_opb<=eng_int_den;
                      dbg_hook_meta<={8'd6, seg_sel[SG_CS], 5'd0, q_w};
                    end
`endif
`else
                    // R3 HOIST: quotient/remainder + #DE come from the ONE native
                    // divider at module scope (ex_div_*); the EAX/EDX write lives in
                    // the gpr writeback driver (core_gpr_wb.svh, K_MULDIV/3'd6).
                    flags_we=1'b0;
                    if (ex_div_dfault) begin
                      // #DE (vector 0): divide error. NO result write, EFLAGS
                      // unchanged. sys_mode DELIVERS through the IDT (the verified
                      // S_INT_GATE FSM, FAULT semantics = push the faulting EIP);
                      // user mode loud-HALTs (no IDT). Matches QEMU, which raises
                      // #DE on div-by-zero AND on a quotient that overflows the
                      // destination width.
                      do_retire=1'b0;
`ifdef VEN_DBG_CORE
                      $display("tb: DIVDE w=%0d eip=%08x EDX=%08x EAX=%08x den=%08x",
                               q_w, q_pc, gpr_o[R_EDX], gpr_o[R_EAX], ex_srcv);
                      dbg_div_fault_q <= 1'b1;   // #DE delivered -> freeze the PC ring (freeze-on-#DE)
`endif
                      if (sys_mode) start_fault(8'd0, 1'b0, 32'd0, q_pc);
                      else          state<=S_HALT;
                    end else
                      // P5 DIVIDE OCCUPANCY (cycle-modeled, p5model occ DIV
                      // 17/25/41 for r/m8/16/32). The native helper above produces
                      // the bit-exact quotient/remainder; the modeled non-pipelined
                      // occupancy is charged as a DEFERRED penalty (occ minus the 7-
                      // clock measured slow-FSM cost of one reg-form divide) burned
                      // before the next issue — reusing the pending_mem_pen mechanism
                      // (the same way a D-cache miss penalty is folded into the next
                      // insn's pipe_free_at). Holds the U pipe so a dependent EDX:EAX
                      // consumer cannot issue until the divide latency elapses.
                      pending_mem_pen <= (q_w==3'd4) ? 7'd34 : (q_w==3'd2) ? 7'd18 : 7'd10;
`endif
                  end
                  default: begin // IDIV /7 (signed) — with #DE (div-by-zero / overflow)
`ifdef VEN_IDIV_ITER
                    flags_we=1'b0; do_retire=1'b0; state<=S_DIV_BUSY;   // -> ven_idiv
`ifdef VEN_DBG_CORE
                    dbg_de_num_r<=eng_int_num; dbg_de_den_r<=eng_int_den;
                    dbg_de_w_r<=q_w; dbg_de_eip_r<=q_pc;   // divide-#DE tap: latch operands
                    if (dbg_hook_cfg[0] && dbg_hook_cfg[1]) begin  // opcode-hook: IDIV class
                      dbg_hook_seq<=dbg_hook_seq+8'd1; dbg_hook_eip<=q_pc;
                      dbg_hook_opa<=eng_int_num; dbg_hook_opb<=eng_int_den;
                      dbg_hook_meta<={8'd7, seg_sel[SG_CS], 5'd0, q_w};
                    end
`endif
`else
                    // R3 HOIST: signed quotient/remainder + #DE come from the ONE
                    // native divider at module scope (ex_idiv_*); the EAX/EDX write
                    // lives in the gpr writeback driver (K_MULDIV/default).
                    flags_we=1'b0;
                    if (ex_idiv_dfault) begin
                      // #DE (vector 0). Same delivery/HALT policy as DIV above.
                      do_retire=1'b0;
`ifdef VEN_DBG_CORE
                      $display("tb: IDIVDE w=%0d eip=%08x EDX=%08x EAX=%08x den=%08x",
                               q_w, q_pc, gpr_o[R_EDX], gpr_o[R_EAX], ex_srcv);
                      dbg_div_fault_q <= 1'b1;   // #DE delivered -> freeze the PC ring (freeze-on-#DE)
`endif
                      if (sys_mode) start_fault(8'd0, 1'b0, 32'd0, q_pc);
                      else          state<=S_HALT;
                    end else
                      // P5 IDIV OCCUPANCY (cycle-modeled, p5model occ IDIV 22/30/46
                      // for r/m8/16/32 — a few clocks over DIV for the sign handling).
                      // Same deferred-penalty mechanism as DIV above (occ - 7).
                      pending_mem_pen <= (q_w==3'd4) ? 7'd39 : (q_w==3'd2) ? 7'd23 : 7'd15;
`endif
                  end
                endcase
              end

              K_IMUL2: begin
                logic [31:0] s1,s2,lo; logic ov; logic [31:0] fl;
                s1 = q_mem_read ? wmask(mem_load_data,q_w) : reg_read(q_src_reg,q_w,1'b0);
                s2 = q_imul_3op ? q_imul_imm : reg_read(q_dst_reg,q_w,1'b0);
                // R3: the dst-reg IMUL2 result write moved to the gpr writeback
                // driver (core_gpr_wb.svh, K_IMUL2 arm); lo/ov stay (feed flags).
                if (q_w==3'd2) begin logic signed [31:0] pp;
                  pp=$signed({{16{s1[15]}},s1[15:0]})*$signed({{16{s2[15]}},s2[15:0]});
                  lo={16'd0,pp[15:0]};
                  ov=(pp!=$signed({{16{pp[15]}},pp[15:0]}));
                end else begin logic signed [63:0] pp; pp=$signed(s1)*$signed(s2);
                  lo=pp[31:0];
                  ov=(pp!=$signed({{32{pp[31]}},pp[31:0]}));
                end
                // QEMU CC_OP_MUL: ZF/SF/PF from low result, AF=0, CF=OF=ov.
                fl=eflags&32'hFFFF_F72A; fl[1]=1'b1;
                fl[0]=ov; fl[11]=ov; fl[2]=parity8(lo[7:0]); fl[4]=1'b0;
                fl[6]=(wmask(lo,q_w)==32'd0); fl[7]=sbit(lo,q_w);
                eflags<=fl;
                flags_we=1'b0;
                pending_mem_pen <= 7'd3;   // P5 IMUL (2/3-operand) occupancy (occ=10)
              end

              K_EXT: begin
                // R3: the MOVZX/MOVSX dst-reg write moved to the gpr writeback
                // driver (core_gpr_wb.svh, K_EXT arm). No flags/store here.
              end

              K_SETCC: begin
                if (q_mem_write) begin do_store=1'b1; do_retire=1'b0; end
                // R3: else dst-reg<-cond write moved to the gpr writeback driver.
                flags_we=1'b0;
              end

              K_BITTEST: begin
                logic [4:0] idx; logic bv; logic [31:0] cur,res,srcv;
                // Register-direct / immediate bit index is taken modulo the
                // operand size: mod 16 for a 0x66-prefixed (16-bit) operand,
                // mod 32 otherwise. (Memory-operand bit-string forms, which use
                // the full index to address a different byte, are not decoded
                // here — they HALT — so masking the index is correct for all
                // forms reaching this block.)
                cur=wmask(dst_cur,q_w);
                // (Bind reg_read() to a temp first: IEEE 1800 forbids a
                // bit-select directly on a function-call result; Vivado enforces.)
                srcv = reg_read(q_src_reg,3'd4,1'b0);
                idx = q_bit_imm ? q_imm[4:0] : srcv[4:0];
                if (q_w==3'd2) idx = {1'b0, idx[3:0]};   // mod 16
                bv = cur[idx];
                unique case (q_bit_op)
                  3'd5: res=cur | (32'd1<<idx);
                  3'd6: res=cur & ~(32'd1<<idx);
                  3'd7: res=cur ^ (32'd1<<idx);
                  default: res=cur;
                endcase
                // Modify forms (BTS/BTR/BTC) write the destination — R3: that
                // dst-reg write moved to the gpr writeback driver (K_BITTEST arm).
                begin logic [31:0] fl; fl=eflags; fl[0]=bv; fl[1]=1'b1; eflags<=fl; end
                flags_we=1'b0;
              end

              K_BITSCAN: begin
                logic [31:0] s, idx; logic zero; int hi;
                // Operand-size aware: a 0x66-prefixed BSF/BSR (66 0F BC/BD)
                // operates on the low 16 bits, computes ZF from [15:0], and
                // writes a 16-bit destination index preserving [31:16].
                s = wmask(q_mem_read ? mem_load_data : reg_read(q_src_reg,q_w,1'b0), q_w);
                hi = (q_w==3'd2) ? 15 : 31;
                zero=(s==32'd0); idx=32'd0;
                // Constant loop bounds (0..31) with a runtime i<=hi guard: a
                // variable loop bound ('hi') is not statically unrollable by
                // Vivado synth (loop-convergence error), though Verilator accepts
                // it. Semantics are identical (only bits <=hi are considered).
                if (!q_shrd) begin for (int i=31;i>=0;i--) if (i<=hi && s[i]) idx=i[31:0]; end // BSF lowest
                else         begin for (int i=0;i<=31;i++) if (i<=hi && s[i]) idx=i[31:0]; end // BSR highest
                // R3: the BSF/BSR dst-reg index write (dest unchanged on src==0)
                // moved to the gpr writeback driver (core_gpr_wb.svh, K_BITSCAN arm).
                // QEMU sets CC_OP_LOGIC with CC_DST = the SOURCE operand:
                //   ZF=(src==0) [defined]; SF=MSB(src); PF=parity(src); CF=OF=AF=0.
                begin logic [31:0] fl; fl=eflags & 32'hFFFF_F72A;
                  fl[0]=1'b0; fl[2]=parity8(s[7:0]); fl[4]=1'b0;
                  fl[6]=zero; fl[7]=sbit(s,q_w); fl[11]=1'b0; fl[1]=1'b1; eflags<=fl; end
                flags_we=1'b0;
              end

              K_XCHG: begin
                if (q_mem_write) begin do_store=1'b1; do_retire=1'b0; end
                // R3: the register-form dst/src swap writes moved to the gpr
                // writeback driver (core_gpr_wb.svh, K_XCHG arm).
                flags_we=1'b0;
              end

              K_CMPXCHG: begin
                // Flags = CMP accumulator,temp (always written, both forms).
                // R3: the conditional accumulator (EAX) update and the register-form
                // dst-reg write moved to the gpr writeback driver (K_CMPXCHG arm).
                // Only flags + the store-decision latch stay here.
                eflags<=cmpxchg_flags; flags_we=1'b0;
                if (q_mem_write) begin
                  // memory form: write src (equal) or temp-unchanged (not equal)
                  // in S_STORE. Latch the decision NOW — the accumulator update
                  // (in the driver) changes EAX, so the live cmpxchg_eq is no longer
                  // valid by the S_STORE clock.
                  cmpxchg_wrsrc_r<=cmpxchg_eq;
                  do_store=1'b1; do_retire=1'b0;
                end
              end

              K_XADD: begin
                // XADD r/m,r:  TEMP = SRC + DEST;  SRC = DEST;  DEST = TEMP.
                // a_op is the OLD destination (mem_load_data for the RMW form, the
                // dst register otherwise) — the value the source register receives.
                // alu_out = dst+src (the SUM) with ADD flags in flags_out.
                if (q_mem_write) begin
                  // MEMORY form: the sum is stored in S_STORE (st_data=alu_out),
                  // which RE-READS the src register combinationally — so the SRC<-
                  // old-dst writeback is DEFERRED to S_STORE (K_XADD arm), otherwise
                  // clobbering src here would make alu_out read mem+mem next clock.
                  // The ADD flags are committed HERE (the do_store path skips the
                  // generic flag commit), exactly like K_CMPXCHG's mem form.
                  eflags <= flags_out; flags_we=1'b0;
                  do_store=1'b1; do_retire=1'b0;
                end else begin
                  // REGISTER form: SRC<-old dst, then DEST<-sum (src==dst -> SUM
                  // wins last). R3: both writes moved to the gpr writeback driver
                  // (core_gpr_wb.svh, K_XADD arm). Flags via the do_retire path.
                end
              end

              K_BOUND: begin
                // index (modrm_reg) must satisfy lower <= index <= upper, all SIGNED
                // at the operand width. lower=[mem]=mem_load_data, upper=[mem+w]=
                // mem_load_data2. BOUND writes no register and no flags.
                logic [31:0] idxv, lov, hiv;
                idxv = reg_read(q_src_reg,q_w,1'b0);
                lov  = wmask(mem_load_data ,q_w);
                hiv  = wmask(mem_load_data2,q_w);
                if (q_w==3'd2) begin              // sign-extend the 16-bit operands
                  idxv={{16{idxv[15]}},idxv[15:0]};
                  lov ={{16{lov [15]}},lov [15:0]};
                  hiv ={{16{hiv [15]}},hiv [15:0]};
                end
                flags_we=1'b0;
                if ($signed(idxv) < $signed(lov) || $signed(idxv) > $signed(hiv)) begin
                  // #BR (vector 5): BOUND range exceeded. FAULT semantics (push the
                  // faulting EIP). sys_mode delivers via the IDT; user mode loud-HALTs
                  // (no IDT) — exactly the #DE policy. Carries no error code.
                  do_retire=1'b0;
                  if (sys_mode) start_fault(8'd5, 1'b0, 32'd0, q_pc);
                  else          state<=S_HALT;
                end
                // in-bounds: do_retire stays 1 -> advance EIP, no state change.
              end

              K_CX8B: begin
                // CMPXCHG8B m64: low=[mem]=mem_load_data, high=[mem+4]=mem_load_data2.
                // Equal iff EDX:EAX == high:low. ONLY ZF is affected (CF/PF/AF/SF/OF
                // unchanged). Equal -> store ECX:EBX to [mem]:[mem+4] (2 beats via
                // S_USEQ) and ZF=1. Not equal -> EDX:EAX <- [mem64], ZF=0, no store.
                logic eq;
                eq = (mem_load_data == gpr_o[R_EAX]) && (mem_load_data2 == gpr_o[R_EDX]);
                eflags <= (eflags & ~(32'd1 << 6)) | (eq ? (32'd1 << 6) : 32'd0);
                flags_we=1'b0;
                if (eq) begin
                  do_retire=1'b0; state<=S_USEQ; step<=4'd0;   // conditional 2-word store
                end
                // R3: not-equal EDX:EAX <- [mem64] load moved to the gpr writeback
                // driver (core_gpr_wb.svh, K_CX8B arm).
              end

              K_BSWAP: begin
                // R3: the dst-reg byte-swap write moved to the gpr writeback driver
                // (core_gpr_wb.svh, K_BSWAP arm).
              end

              // ---- CPUID (0F A2) — deterministic leaf table for `-cpu pentium` ----
              // CPUID writes eax/ebx/ecx/edx as a pure function of the leaf (eAX).
              // It touches NO flags. These constants are the EXACT values qemu
              // `-cpu pentium` returns (verified against the golden's 261 CPUID
              // retirements in the 300k Win95 boot prefix), so this is a faithful
              // ISA model — NOT injected environment. The boot only ever needs three
              // distinct results:
              //   leaf 0x00000000 : max-basic-leaf=1 + "GenuineIntel" vendor string
              //                     (ebx="Genu" ecx="ntel" edx="ineI").
              //   leaf 0x40000000 : the TCG hypervisor leaf — max-hyp=0x40000001 +
              //                     the "TCGTCGTCG" signature (ebx/ecx/edx).
              //   everything else : qemu clamps to the leaf-1 Pentium result
              //                     (eax=0x543 family5/model4/step3, the P5 feature
              //                     flags edx=0x008003bd; ebx=0x800; ecx=0x80000000).
              //                     This covers leaf 1, the extended base 0x80000000,
              //                     and every unknown 0x4000_01xx..0x4000_ffxx leaf the
              //                     SeaBIOS hypervisor scan probes. ECX (subleaf) is
              //                     not consulted by any leaf this boot touches.
              // Reached under cosim_en (Win95 co-sim) OR soc_en (the M8/M9 SoC, where
              // real boot firmware probes CPUID); the decode gates K_CPUID on
              // (cosim_en||soc_en). The user-mode corpus has both off, so this arm is
              // inert there and that build stays byte-identical.
              // The leaf->result table is CPU-MODEL-SPECIFIC, and the SoC oracle
              // (qemu-system-i386 8.2.2 `-cpu pentium`) returns DIFFERENT CPUID than
              // the Win95 co-sim's qemu did (e.g. leaf-0 max=4 not 1, leaf-1 sig=0x663
              // not 0x543 — note 0x663 matches the SoC's non-cosim reset EDX). So the
              // table branches on soc_en: the SoC arm is the verified standard boot
              // leaf-set captured from the live qemu-system golden
              // (verif/sys/tests/psoccpuid); the cosim arm is the UNCHANGED Win95 model
              // (so the M7 lockstep stays byte-identical). soc_en and cosim_en are
              // mutually exclusive (tb_soc vs the Win95 co-sim TB).
              K_CPUID: begin
                // R3: the CPUID leaf->EAX/EBX/ECX/EDX result table moved to the gpr
                // writeback driver (core_gpr_wb.svh, K_CPUID arm — same soc_en/cosim
                // branch + per-leaf constants). CPUID modifies no flags.
                flags_we=1'b0;
              end

              // F3: RDTSC (0F 31) — EDX:EAX <= the 64-bit time-stamp counter. EAX is
              // the low 32 bits, EDX the high 32. Sampled the clock the instruction
              // executes (the same `tsc` the always_ff free-runs). No flags. Reached
              // only under cosim_en||soc_en (the decode gate); inert for user mode.
              K_RDTSC: begin
                // R3: EDX:EAX <= tsc moved to the gpr writeback driver (K_RDTSC arm).
                flags_we=1'b0;
              end

              K_CONV: begin
                // R3: CBW/CWDE (EAX) / CWD/CDQ (EDX) sign-extend writes moved to the
                // gpr writeback driver (core_gpr_wb.svh, K_CONV arm). No flags here.
              end

              K_STKMISC: begin
                unique case (q_sm)
                  SM_LAHF: begin end  // R3: AH<-flags write moved to the gpr writeback driver
                  SM_SAHF: begin logic [31:0] fl; fl=eflags;
                    fl[7]=gpr_o[R_EAX][15]; fl[6]=gpr_o[R_EAX][14]; fl[4]=gpr_o[R_EAX][12];
                    fl[2]=gpr_o[R_EAX][10]; fl[0]=gpr_o[R_EAX][8]; fl[1]=1'b1; eflags<=fl; end
                  SM_PUSHF: begin do_store=1'b1; do_retire=1'b0; end
                  SM_POPF: begin
                    // EFLAGS <- [ESP] with the architectural MODE/CPL-aware POPF
                    // writable mask (IA-32 SDM Vol.1 "POPF"). VM and RF are NEVER
                    // writable by POPF (kept in `eflags & ~mask`); bit1 is forced 1.
                    //   base  = CF|PF|AF|ZF|SF|TF|DF|OF|NT|AC|ID = 0x00244DD5
                    //           (status flags + TF/DF/NT/AC/ID — always writable).
                    //   + IF (0x200)  : writable unless CPL>IOPL in PM.
                    //   + IOPL(0x3000): writable only at the highest privilege —
                    //                   REAL MODE or PM CPL==0. (V86 NEVER loads
                    //                   IOPL/IF the privileged way here: at IOPL<3 it
                    //                   already #GP-trapped upstream in
                    //                   core_fetch_decode.svh and never reaches this
                    //                   arm; at IOPL==3 eff_cpl==3 so it takes the
                    //                   IF-only branch — POPF leaves IOPL/VM alone.)
                    // This is the DOS-Quake fix: CWSDPMI/go32 runs `popfd` in REAL
                    // MODE (cs=0x2593), where POPF must load IF AND IOPL. The old
                    // hardcoded 0x00244DD5 kept IOPL=0, diverging from qemu's IOPL=3
                    // and tripping CWSDPMI's exception reporter (the spurious #GP).
                    logic [31:0] popf_mask;
                    if (real_mode || (!seg_real && eff_cpl == 2'd0))
                      popf_mask = 32'h0024_7FD5;          // base | IF | IOPL
                    else if (!seg_real && eff_cpl <= iopl)
                      popf_mask = 32'h0024_4FD5;          // base | IF
                    else if (v86 && iopl == 2'd3)
                      popf_mask = 32'h0024_4FD5;          // V86 IOPL==3: IF only
                    else
                      popf_mask = 32'h0024_4DD5;          // base (CPL>IOPL): neither
                    // task #102 (EFLAGS.ID root): a 16-bit POPF (popfw, q_w==2 — the
                    // real-mode default with no 0x66) loads ONLY the low 16 EFLAGS
                    // bits; EFLAGS[31:16] (ID/VM/AC/...) are UNTOUCHED (IA-32 SDM
                    // "POPF"). The 32-bit mem_load_data carries the next stack word in
                    // [31:16]; without restricting the mask to 16 bits that high word
                    // leaks into bit21 (ID) — DOS-Quake's CWSDPMI/go32 switcher does a
                    // 16-bit `popf` (cs=0070:0x366) whose [esp+2] happens to have
                    // bit21 set, so ID got stuck set vs qemu (which masks `&= 0xffff`
                    // for MO_16). Mirror the 16-bit IRET (core_rmint.svh) here.
                    if (q_w == 3'd2) popf_mask = popf_mask & 32'h0000_FFFF;
                    // R3: the ESP+=w bump moved to the gpr writeback driver.
                    eflags<=((mem_load_data & popf_mask) |
                             (eflags & ~popf_mask)) | 32'h0000_0002;
                  end
                  // LEAVE: ESP<-EBP, then pop (E)BP. R3: both EBP/ESP writes moved to
                  // the gpr writeback driver (core_gpr_wb.svh, K_STKMISC/SM_LEAVE).
                  SM_LEAVE: begin end
                  SM_PUSHA, SM_POPA: begin do_retire=1'b0; state<=S_USEQ; step<=4'd0; end
                  // ENTER (level 0): push EBP now (store driven by the st_data mux:
                  // st_addr=ESP-w, st_data=EBP); S_STORE then sets EBP=ESP-w and
                  // ESP=ESP-w-alloc and retires.
                  SM_ENTER: begin do_store=1'b1; do_retire=1'b0; end
                  default: ;
                endcase
                flags_we=1'b0;
              end

              K_STR: begin
                // one element; with REP iterate via S_USEQ keeping pc fixed.
                logic [31:0] cx;
                logic        rep_active, last_iter, cmp_term, store_needed;
                cx = gpr_o[R_ECX];
                rep_active = (q_rep || q_repne);
                // ECX==0 degenerate REP: no element, just advance EIP, one record.
                // F3: a16 (q_cnt16) REP counts in CX (low 16) — test/decrement
                // must ignore stale ECX[31:16] (SeaBIOS POST leaves big values).
                if (rep_active && (q_cnt16 ? (cx[15:0]==16'd0) : (cx==32'd0))) begin
                  // no memory effect; retire as a no-op (handled by do_retire below)
                  do_retire=1'b1; flags_we=1'b0; new_eip=next_eip;
                end else begin
                  // execute one element this cycle
                  store_needed = q_str_storedi; // MOVS/STOS write [EDI]
                  // update pointers / flags / regs for this element:
                  // F3: a16 (q_cnt16) string updates touch ONLY SI/DI — the
                  // low 16 bits wrap mod 64K and ESI/EDI[31:16] are preserved
                  // (a DF=1 copy crossing 0 must wrap to 0xFFFF, not 32-bit -1).
                  // R3: the ESI/EDI/EAX(LODS)/ECX(REP) writes moved to the gpr
                  // writeback driver (core_gpr_wb.svh, K_STR arm). The post-decrement
                  // ECX (dec_cx) is the SHARED module-scope decrementer; the FSM
                  // uses it here for last_iter/new_eip, the driver writes it to ECX.
                  if (q_str_scandi) begin eflags<=str_flags; end
                  flags_we=1'b0;

                  if (rep_active) begin
                    cx = dec_cx;
                    // termination: ECX reaches 0, or (REPE/REPNE) ZF condition.
                    cmp_term = 1'b0;
                    if (q_str_scandi) begin
                      if (q_rep)   cmp_term = (str_flags[6]==1'b0); // REPE: stop when ZF=0
                      if (q_repne) cmp_term = (str_flags[6]==1'b1); // REPNE: stop when ZF=1
                    end
                    last_iter = (q_cnt16 ? (cx[15:0]==16'd0) : (cx==32'd0)) || cmp_term;
                    // Each REP iteration is its OWN retire record at the same PC.
                    // We retire here and, if not last, re-enter at the same PC.
                    if (last_iter) new_eip = next_eip;
                    else           new_eip = q_pc;   // stay on the REP instruction
                  end else begin
                    new_eip = next_eip;
                  end

                  if (store_needed) begin do_store=1'b1; do_retire=1'b0; end
                  else do_retire=1'b1;

                  // latch pre-increment [EDI] + data for the store stage (EDI is
                  // being incremented this cycle via NBA, so S_STORE must not
                  // re-read gpr_o[EDI]).
                  str_store_addr <= str_edi;   // F3: a16-masked DI
                  str_store_data <= str_wdata;
                  // remember the eip we want after this element commit
                  str_next_eip <= new_eip;
                end
              end

              K_CTRL: begin
`ifdef M7_PROXY_DEBUG
                if (q_ct==CT_CALLIND)
                  $display("[M7DBG] CALLIND @q_pc=0x%08x q_seg=%0d dbase=0x%08x q_ea=0x%08x mem_load_data=0x%08x target=0x%08x",
                           q_pc, q_seg, dbase, q_ea, mem_load_data, call_target);
`endif
                unique case (q_ct)
                  CT_CALLREL, CT_CALLIND: begin do_store=1'b1; do_retire=1'b0; end
                  CT_JMPIND: new_eip = call_target;
                  // Near RET: pop the return IP at operand width. A 0x66 RET
                  // pops a 16-bit IP (EIP truncated to 16 bits) and ESP+=2.
                  CT_RETN: begin
                    // R3: ESP+=w bump moved to the gpr writeback driver (K_CTRL/CT_RETN).
                    new_eip = (q_w==3'd2) ? {16'd0,mem_load_data[15:0]} : mem_load_data;
                  end
                  CT_RETN_IMM: begin
                    // R3: ESP+=w+imm bump moved to the gpr writeback driver (CT_RETN_IMM).
                    new_eip = (q_w==3'd2) ? {16'd0,mem_load_data[15:0]} : mem_load_data;
                  end
                  CT_LOOP, CT_LOOPE, CT_LOOPNE: begin
                    // 0x67 address-size: the count register is CX (low 16):
                    // decrement preserves ECX[31:16] and the taken test is CX!=0.
                    logic take; logic zero_after;
                    // R3 HOIST: dec_cx is the SHARED post-decrement ECX (core.sv);
                    // the FSM uses it for the taken test, the driver writes it to ECX.
                    zero_after = q_cnt16 ? (dec_cx[15:0]==16'd0) : (dec_cx==32'd0);
                    take=~zero_after;
                    if (q_ct==CT_LOOPE)  take=take & eflags[6];
                    if (q_ct==CT_LOOPNE) take=take & ~eflags[6];
                    new_eip = take ? (next_eip+q_rel) : next_eip;
                    flags_we=1'b0;
                  end
                  CT_JECXZ: begin
                    logic cx_zero;
                    cx_zero = q_cnt16 ? (gpr_o[R_ECX][15:0]==16'd0) : (gpr_o[R_ECX]==32'd0);
                    new_eip=cx_zero?(next_eip+q_rel):next_eip; flags_we=1'b0;
                  end
                  default: ;
                endcase
              end
            endcase
          end

          // commit (non-store, non-microseq path)
          if (do_retire) begin
            logic [31:0] cmt_eip;       // the EIP this instruction commits / fetches next
            logic [3:0]  xbp;           // instruction-breakpoint hit on the committed EIP
            cmt_eip = (q_is_branch && q_branch_taken) ? (next_eip+q_rel) : new_eip;
            // M7.3b: a 16-bit-operand-size near branch masks the taken target to 16
            // bits (IA-32: a near JMP/Jcc under a 16-bit operand size truncates EIP
            // to IP). q_br16 is 0 in 32-bit mode, so every prior gate is unchanged.
            if (q_br16 && q_is_branch && q_branch_taken)
              cmt_eip = {16'd0, cmt_eip[15:0]};
            if (flags_we) eflags<=flags_val;
            eip<=cmt_eip;
            // ---- M2S.6 #DB at the retire boundary (gated sys_mode). Checked in P5
            // priority: an INSTRUCTION breakpoint on the NEXT eip (FAULT, restart)
            // takes precedence over a TF single-step trap (so RF can be honoured);
            // else a TF single-step trap (TRAP, resume at cmt_eip). The triggering
            // instruction does NOT retire separately — arm_db fuses it (q_pc stamp).
            xbp = (sys_mode && !rf_at_issue) ? dr_match(seg_base[SG_CS]+cmt_eip, 1'b1)
                                             : 4'd0;
            if (sys_mode && xbp != 4'd0) begin
              // FAULT before cmt_eip; push cmt_eip (restart), stamp this insn's PC.
              arm_db({28'd0, xbp}, q_pc, cmt_eip);
            end
            else if (sys_mode && tf_at_issue) begin
              // TF single-step TRAP after this instruction; push cmt_eip (resume).
              arm_db(32'd1 << DR6_BS, q_pc, cmt_eip);
            end
            else begin
              retire_valid<=1'b1;
              state<=S_PIPE;   // re-enter fast path
            end
          end else if (do_store) begin
            state<=S_STORE;
          end
        end
