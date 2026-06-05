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
              3'd0: creg0<=gpr[q_src_reg];
              3'd2: creg2<=gpr[q_src_reg];
              3'd3: begin
                creg3<=gpr[q_src_reg];
                // TLB flush (clear val bits only) now lands in u_itlb/u_dtlb via
                // tlb_flush (driven combinationally from this exact MOV CR3
                // condition; see the flush driver at the TLB instantiation).
              end
              default: creg4<=gpr[q_src_reg];
            endcase
          end
          else if (q_sysop==SYS_MOVCR_FROM) begin
            // MOV r32, CRn.
            flags_we=1'b0;
            unique case (q_sys_creg)
              3'd0: gpr[q_dst_reg]<=creg0;
              3'd2: gpr[q_dst_reg]<=creg2;
              3'd3: gpr[q_dst_reg]<=creg3;
              default: gpr[q_dst_reg]<=creg4;
            endcase
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
              3'd0: dr0 <= gpr[q_src_reg];
              3'd1: dr1 <= gpr[q_src_reg];
              3'd2: dr2 <= gpr[q_src_reg];
              3'd3: dr3 <= gpr[q_src_reg];
              // DR4 aliases DR6, DR5 aliases DR7 (CR4.DE=0; the corpus keeps DE=0).
              3'd4, 3'd6: dr6 <= gpr[q_src_reg] | DR6_FIXED_1;
              default:    dr7 <= gpr[q_src_reg] | DR7_FIXED_1;  // DR5/DR7
            endcase
          end
          else if (q_sysop==SYS_MOVDR_FROM) begin
            flags_we=1'b0;
            unique case (q_sys_creg)
              3'd0: gpr[q_dst_reg] <= dr0;
              3'd1: gpr[q_dst_reg] <= dr1;
              3'd2: gpr[q_dst_reg] <= dr2;
              3'd3: gpr[q_dst_reg] <= dr3;
              3'd4, 3'd6: gpr[q_dst_reg] <= dr6;   // DR4 aliases DR6
              default:    gpr[q_dst_reg] <= dr7;   // DR5/DR7
            endcase
          end
          else if (q_sysop==SYS_MOVSREG_FROM) begin
            // MOV r/m16, Sreg -> write the selector value (zero-extended) to reg.
            flags_we=1'b0;
            gpr[q_dst_reg]<=reg_merge(gpr[q_dst_reg], {16'd0, seg_sel[q_sys_sreg]}, 3'd2, 1'b0);
          end
          else if (q_sysop==SYS_STR) begin
            // STR r/m16 -> write the current TR selector (zero-extended) to reg.
            flags_we=1'b0;
            gpr[q_dst_reg]<=reg_merge(gpr[q_dst_reg], {16'd0, tr_sel}, 3'd2, 1'b0);
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
            seg_sel [q_sys_sreg] <= gpr[q_src_reg][15:0];
            if (q_sys_sreg == 3'(SG_GS) && gpr[q_src_reg][15:0]==16'h0033)
              seg_base[q_sys_sreg] <= gs_base_r;        // TLS base for %gs:off
            else
              seg_base[q_sys_sreg] <= 32'd0;            // flat
            seg_limit[q_sys_sreg]<= 32'hFFFF_FFFF;
            seg_attr [q_sys_sreg]<= 8'h93;
`ifdef M7_PROXY_DEBUG
            $display("[M7DBG] mov sreg=%0d sel=0x%04x gs_base_r=0x%08x -> base=0x%08x",
                     q_sys_sreg, gpr[q_src_reg][15:0], gs_base_r,
                     (q_sys_sreg==3'(SG_GS) && gpr[q_src_reg][15:0]==16'h0033) ? gs_base_r : 32'd0);
`endif
          end
          else if (q_sysop==SYS_MOVSREG_TO) begin
            // REAL-MODE MOV Sreg, r16: selector = value; hidden base = sel<<4.
            // Real mode does no descriptor / protection checks (no GDT consulted);
            // the hidden attr stays the present R/W data default.
            flags_we=1'b0;
            seg_sel [q_sys_sreg] <= gpr[q_src_reg][15:0];
            seg_base[q_sys_sreg] <= {12'd0, gpr[q_src_reg][15:0], 4'd0};
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
                if (q_is_lea) gpr[q_dst_reg]<=q_ea;
                else if (q_is_pop && q_mem_write) begin
                  // POP m: stack value (mem_load_data) -> memory dest; ESP += w.
                  do_store=1'b1; do_retire=1'b0;
                end else if (q_is_pop) begin
                  gpr[q_dst_reg]<=reg_merge(gpr[q_dst_reg], wmask(mem_load_data,q_w), q_w, 1'b0);
                  if (q_dst_reg!=R_ESP) gpr[R_ESP]<=gpr[R_ESP]+{28'd0,q_w};
                end else if (q_mem_write) begin do_store=1'b1; do_retire=1'b0; end
                else if (q_writes_reg) gpr[q_dst_reg]<=reg_merge(dst_cur, alu_out, q_w, q_dst_high8);
              end

              K_SHIFT: begin
                // count masked to 0 -> NO flag change, NO value change (QEMU).
                if (sh_cnt==6'd0) begin
                  flags_we=1'b0;
                  if (q_mem_write) begin do_store=1'b1; do_retire=1'b0; end
                end else begin
                  if (q_mem_write) begin do_store=1'b1; do_retire=1'b0; end
                  else gpr[q_dst_reg]<=reg_merge(dst_cur, sh_out, q_w, q_dst_high8);
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
                logic [5:0] cnt; logic [31:0] r, shm1;
                cnt = q_shift_cl ? {1'b0,gpr[R_ECX][4:0]} : {1'b0,q_shift_imm};
                if (cnt==6'd0) flags_we=1'b0;
                else begin
                  r = shld_result(q_shrd, dst_cur, reg_read(q_src_reg,q_w,1'b0), cnt, q_w);
                  // shm1 = dst shifted by (count-1) (same direction) = QEMU CC_SRC.
                  shm1 = q_shrd ? (wmask(dst_cur,q_w) >> (cnt-6'd1))
                                : wmask(wmask(dst_cur,q_w) << (cnt-6'd1), q_w);
                  gpr[q_dst_reg]<=reg_merge(dst_cur, r, q_w, 1'b0);
                  begin logic [31:0] fl;
                    fl=eflags & 32'hFFFF_F72A;
                    fl[0]=shld_cf(q_shrd, dst_cur, cnt, q_w); fl[2]=parity8(r[7:0]); fl[4]=1'b0;
                    fl[6]=(wmask(r,q_w)==32'd0); fl[7]=sbit(r,q_w);
                    fl[11]=sbit(shm1,q_w)^sbit(r,q_w); fl[1]=1'b1;
                    eflags<=fl;
                  end
                  flags_we=1'b0;
                end
              end

              K_MULDIV: begin
                logic [31:0] srcv;
                srcv = q_mem_read ? wmask(mem_load_data,q_w) : reg_read(q_src_reg,q_w,q_src_high8);
                unique case (q_md)
                  3'd4: begin // MUL (unsigned)
                    logic [63:0] p; logic [31:0] lo; logic ovf; logic [31:0] fl;
                    if (q_w==3'd1)      p={48'd0, ({8'd0,gpr[R_EAX][7:0]}*{8'd0,srcv[7:0]})};
                    else if (q_w==3'd2) p={32'd0, ({16'd0,gpr[R_EAX][15:0]}*{16'd0,srcv[15:0]})};
                    else                p={32'd0,gpr[R_EAX]}*{32'd0,srcv};
                    if (q_w==3'd1) begin lo={24'd0,p[7:0]};  ovf=(p[15:8]!=8'd0);  gpr[R_EAX]<={gpr[R_EAX][31:16],p[15:0]}; end
                    else if (q_w==3'd2) begin lo={16'd0,p[15:0]}; ovf=(p[31:16]!=16'd0);
                      gpr[R_EAX]<={gpr[R_EAX][31:16],p[15:0]}; gpr[R_EDX]<={gpr[R_EDX][31:16],p[31:16]}; end
                    else begin lo=p[31:0]; ovf=(p[63:32]!=32'd0); gpr[R_EAX]<=p[31:0]; gpr[R_EDX]<=p[63:32]; end
                    // QEMU compute_all_mul: ZF/SF/PF from low result, AF=0, CF=OF=ovf
                    fl=eflags&32'hFFFF_F72A; fl[1]=1'b1;
                    fl[0]=ovf; fl[11]=ovf; fl[2]=parity8(lo[7:0]); fl[4]=1'b0;
                    fl[6]=(wmask(lo,q_w)==32'd0); fl[7]=sbit(lo,q_w);
                    eflags<=fl; flags_we=1'b0;
                  end
                  3'd5: begin // IMUL one-operand (signed)
                    logic signed [63:0] p; logic [31:0] lo; logic ovf; logic [31:0] fl;
                    if (q_w==3'd1)      p=$signed({{8{srcv[7]}},srcv[7:0]}) * $signed({{8{gpr[R_EAX][7]}},gpr[R_EAX][7:0]});
                    else if (q_w==3'd2) p=$signed({{16{srcv[15]}},srcv[15:0]}) * $signed({{16{gpr[R_EAX][15]}},gpr[R_EAX][15:0]});
                    else                p=$signed(srcv) * $signed(gpr[R_EAX]);
                    if (q_w==3'd1) begin lo={24'd0,p[7:0]};  ovf=($signed(p)!=$signed({{56{p[7]}},p[7:0]}));   gpr[R_EAX]<={gpr[R_EAX][31:16],p[15:0]}; end
                    else if (q_w==3'd2) begin lo={16'd0,p[15:0]}; ovf=($signed(p)!=$signed({{48{p[15]}},p[15:0]}));
                      gpr[R_EAX]<={gpr[R_EAX][31:16],p[15:0]}; gpr[R_EDX]<={gpr[R_EDX][31:16],p[31:16]}; end
                    else begin lo=p[31:0]; ovf=($signed(p)!=$signed({{32{p[31]}},p[31:0]})); gpr[R_EAX]<=p[31:0]; gpr[R_EDX]<=p[63:32]; end
                    fl=eflags&32'hFFFF_F72A; fl[1]=1'b1;
                    fl[0]=ovf; fl[11]=ovf; fl[2]=parity8(lo[7:0]); fl[4]=1'b0;
                    fl[6]=(wmask(lo,q_w)==32'd0); fl[7]=sbit(lo,q_w);
                    eflags<=fl; flags_we=1'b0;
                  end
                  3'd6: begin // DIV
                    if (q_w==3'd1) begin
                      logic [15:0] num; logic [15:0] qq, rr;
                      num=gpr[R_EAX][15:0]; qq=num/{8'd0,srcv[7:0]}; rr=num%{8'd0,srcv[7:0]};
                      gpr[R_EAX]<={gpr[R_EAX][31:16], rr[7:0], qq[7:0]};
                    end else if (q_w==3'd2) begin
                      logic [31:0] num,qq,rr;
                      num={gpr[R_EDX][15:0],gpr[R_EAX][15:0]}; qq=num/{16'd0,srcv[15:0]}; rr=num%{16'd0,srcv[15:0]};
                      gpr[R_EAX]<={gpr[R_EAX][31:16], qq[15:0]};
                      gpr[R_EDX]<={gpr[R_EDX][31:16], rr[15:0]};
                    end else begin
                      logic [63:0] num,qq,rr;
                      num={gpr[R_EDX],gpr[R_EAX]}; qq=num/{32'd0,srcv}; rr=num%{32'd0,srcv};
                      gpr[R_EAX]<=qq[31:0]; gpr[R_EDX]<=rr[31:0];
                    end
                    flags_we=1'b0;
                  end
                  default: begin // IDIV /7
                    if (q_w==3'd1) begin
                      logic signed [15:0] num,den,qq,rr;
                      num=$signed(gpr[R_EAX][15:0]); den=$signed({{8{srcv[7]}},srcv[7:0]});
                      qq=num/den; rr=num%den;
                      gpr[R_EAX]<={gpr[R_EAX][31:16], rr[7:0], qq[7:0]};
                    end else if (q_w==3'd2) begin
                      logic signed [31:0] num,den,qq,rr;
                      num=$signed({gpr[R_EDX][15:0],gpr[R_EAX][15:0]}); den=$signed({{16{srcv[15]}},srcv[15:0]});
                      qq=num/den; rr=num%den;
                      gpr[R_EAX]<={gpr[R_EAX][31:16], qq[15:0]};
                      gpr[R_EDX]<={gpr[R_EDX][31:16], rr[15:0]};
                    end else begin
                      logic signed [63:0] num,den,qq,rr;
                      num=$signed({gpr[R_EDX],gpr[R_EAX]}); den=$signed({{32{srcv[31]}},srcv});
                      qq=num/den; rr=num%den;
                      gpr[R_EAX]<=qq[31:0]; gpr[R_EDX]<=rr[31:0];
                    end
                    flags_we=1'b0;
                  end
                endcase
              end

              K_IMUL2: begin
                logic [31:0] s1,s2,lo; logic ov; logic [31:0] fl;
                s1 = q_mem_read ? wmask(mem_load_data,q_w) : reg_read(q_src_reg,q_w,1'b0);
                s2 = q_imul_3op ? q_imul_imm : reg_read(q_dst_reg,q_w,1'b0);
                if (q_w==3'd2) begin logic signed [31:0] pp;
                  pp=$signed({{16{s1[15]}},s1[15:0]})*$signed({{16{s2[15]}},s2[15:0]});
                  lo={16'd0,pp[15:0]};
                  gpr[q_dst_reg]<=reg_merge(dst_cur, {16'd0,pp[15:0]}, q_w, 1'b0);
                  ov=(pp!=$signed({{16{pp[15]}},pp[15:0]}));
                end else begin logic signed [63:0] pp; pp=$signed(s1)*$signed(s2);
                  lo=pp[31:0];
                  gpr[q_dst_reg]<=reg_merge(dst_cur, pp[31:0], q_w, 1'b0);
                  ov=(pp!=$signed({{32{pp[31]}},pp[31:0]}));
                end
                // QEMU CC_OP_MUL: ZF/SF/PF from low result, AF=0, CF=OF=ov.
                fl=eflags&32'hFFFF_F72A; fl[1]=1'b1;
                fl[0]=ov; fl[11]=ov; fl[2]=parity8(lo[7:0]); fl[4]=1'b0;
                fl[6]=(wmask(lo,q_w)==32'd0); fl[7]=sbit(lo,q_w);
                eflags<=fl;
                flags_we=1'b0;
              end

              K_EXT: begin
                logic [31:0] s,r;
                s = q_mem_read ? mem_load_data : reg_read(q_src_reg, q_ext_srcw, q_src_high8);
                if (q_ext_srcw==3'd1) r = q_ext_signed ? {{24{s[7]}},s[7:0]} : {24'd0,s[7:0]};
                else                  r = q_ext_signed ? {{16{s[15]}},s[15:0]} : {16'd0,s[15:0]};
                // Destination width follows the operand-size: a 0x66-prefixed
                // MOVZX/MOVSX (66 0F B6/B7/BE/BF) writes a 16-bit register and
                // must PRESERVE [31:16]; the unprefixed form writes the full 32.
                gpr[q_dst_reg]<=reg_merge(gpr[q_dst_reg], r, q_w, 1'b0);
              end

              K_SETCC: begin
                if (q_mem_write) begin do_store=1'b1; do_retire=1'b0; end
                else gpr[q_dst_reg]<=reg_merge(gpr[q_dst_reg], {31'd0,cond_true(q_cc,eflags)}, 3'd1, q_dst_high8);
                flags_we=1'b0;
              end

              K_BITTEST: begin
                logic [4:0] idx; logic bv; logic [31:0] cur,res;
                // Register-direct / immediate bit index is taken modulo the
                // operand size: mod 16 for a 0x66-prefixed (16-bit) operand,
                // mod 32 otherwise. (Memory-operand bit-string forms, which use
                // the full index to address a different byte, are not decoded
                // here — they HALT — so masking the index is correct for all
                // forms reaching this block.)
                cur=wmask(dst_cur,q_w);
                idx = q_bit_imm ? q_imm[4:0] : reg_read(q_src_reg,3'd4,1'b0)[4:0];
                if (q_w==3'd2) idx = {1'b0, idx[3:0]};   // mod 16
                bv = cur[idx];
                unique case (q_bit_op)
                  3'd5: res=cur | (32'd1<<idx);
                  3'd6: res=cur & ~(32'd1<<idx);
                  3'd7: res=cur ^ (32'd1<<idx);
                  default: res=cur;
                endcase
                // Modify forms (BTS/BTR/BTC) write the destination at operand
                // width, preserving [31:16] for the 16-bit form.
                if (q_writes_reg) gpr[q_dst_reg]<=reg_merge(gpr[q_dst_reg], res, q_w, 1'b0);
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
                if (!q_shrd) begin for (int i=hi;i>=0;i--) if (s[i]) idx=i[31:0]; end // BSF lowest
                else         begin for (int i=0;i<=hi;i++) if (s[i]) idx=i[31:0]; end // BSR highest
                if (!zero) gpr[q_dst_reg]<=reg_merge(gpr[q_dst_reg], idx, q_w, 1'b0);  // dest unchanged on src==0 (QEMU)
                // QEMU sets CC_OP_LOGIC with CC_DST = the SOURCE operand:
                //   ZF=(src==0) [defined]; SF=MSB(src); PF=parity(src); CF=OF=AF=0.
                begin logic [31:0] fl; fl=eflags & 32'hFFFF_F72A;
                  fl[0]=1'b0; fl[2]=parity8(s[7:0]); fl[4]=1'b0;
                  fl[6]=zero; fl[7]=sbit(s,q_w); fl[11]=1'b0; fl[1]=1'b1; eflags<=fl; end
                flags_we=1'b0;
              end

              K_XCHG: begin
                if (q_mem_write) begin do_store=1'b1; do_retire=1'b0; end
                else begin
                  logic [31:0] a,b;
                  a=reg_read(q_dst_reg,q_w,q_dst_high8); b=reg_read(q_src_reg,q_w,q_src_high8);
                  gpr[q_dst_reg]<=reg_merge(gpr[q_dst_reg], b, q_w, q_dst_high8);
                  gpr[q_src_reg]<=reg_merge(gpr[q_src_reg], a, q_w, q_src_high8);
                end
                flags_we=1'b0;
              end

              K_CMPXCHG: begin
                // Flags = CMP accumulator,temp (always written, both forms). The
                // conditional accumulator update (acc <- temp when NOT equal) is
                // committed here for both forms. Source store / dst-reg write is
                // conditional on equality.
                eflags<=cmpxchg_flags; flags_we=1'b0;
                if (!cmpxchg_eq)
                  gpr[R_EAX]<=reg_merge(gpr[R_EAX], cmpxchg_temp, q_w, 1'b0);
                if (q_mem_write) begin
                  // memory form: write src (equal) or temp-unchanged (not equal)
                  // in S_STORE. Latch the decision NOW — the accumulator update
                  // above changes EAX, so the live cmpxchg_eq is no longer valid
                  // by the S_STORE clock.
                  cmpxchg_wrsrc_r<=cmpxchg_eq;
                  do_store=1'b1; do_retire=1'b0;
                end else begin
                  // register form: on equality the dst GPR gets src; otherwise it
                  // is left unchanged (the accumulator already took temp above).
                  if (cmpxchg_eq)
                    gpr[q_dst_reg]<=reg_merge(gpr[q_dst_reg],
                                              reg_read(q_src_reg,q_w,q_src_high8),
                                              q_w, q_dst_high8);
                end
              end

              K_BSWAP: begin logic [31:0] v; v=gpr[q_dst_reg];
                gpr[q_dst_reg]<={v[7:0],v[15:8],v[23:16],v[31:24]}; end

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
              // Reached only under cosim_en (the decode gates K_CPUID on cosim_en); the
              // existing corpus never executes CPUID, so this arm is inert there.
              K_CPUID: begin
                unique case (gpr[R_EAX])
                  32'h0000_0000: begin
                    gpr[R_EAX]<=32'h0000_0001; gpr[R_EBX]<=32'h756e_6547;
                    gpr[R_ECX]<=32'h6c65_746e; gpr[R_EDX]<=32'h4965_6e69;
                  end
                  32'h4000_0000: begin
                    gpr[R_EAX]<=32'h4000_0001; gpr[R_EBX]<=32'h5447_4354;
                    gpr[R_ECX]<=32'h4354_4743; gpr[R_EDX]<=32'h4743_5447;
                  end
                  default: begin
                    gpr[R_EAX]<=32'h0000_0543; gpr[R_EBX]<=32'h0000_0800;
                    gpr[R_ECX]<=32'h8000_0000; gpr[R_EDX]<=32'h0080_03bd;
                  end
                endcase
                flags_we=1'b0;   // CPUID modifies no flags
              end

              K_CONV: begin
                if (!q_conv_cdq) begin
                  if (q_w==3'd2) gpr[R_EAX]<={gpr[R_EAX][31:16], {8{gpr[R_EAX][7]}}, gpr[R_EAX][7:0]};
                  else           gpr[R_EAX]<={{16{gpr[R_EAX][15]}}, gpr[R_EAX][15:0]};
                end else begin
                  if (q_w==3'd2) gpr[R_EDX]<={gpr[R_EDX][31:16], {16{gpr[R_EAX][15]}}};
                  else           gpr[R_EDX]<={32{gpr[R_EAX][31]}};
                end
              end

              K_STKMISC: begin
                unique case (q_sm)
                  SM_LAHF: gpr[R_EAX]<={gpr[R_EAX][31:16], eflags[7:0], gpr[R_EAX][7:0]};
                  SM_SAHF: begin logic [31:0] fl; fl=eflags;
                    fl[7]=gpr[R_EAX][15]; fl[6]=gpr[R_EAX][14]; fl[4]=gpr[R_EAX][12];
                    fl[2]=gpr[R_EAX][10]; fl[0]=gpr[R_EAX][8]; fl[1]=1'b1; eflags<=fl; end
                  SM_PUSHF: begin do_store=1'b1; do_retire=1'b0; end
                  SM_POPF: begin
                    // EFLAGS <- [ESP], USER-MODE mask: status flags + DF/TF/AC/
                    // ID/NT writable; IF/IOPL/VM/RF preserved (QEMU CPL=3 popf).
                    // writable = CF|PF|AF|ZF|SF|TF|DF|OF|NT|AC|ID = 0x244DD5.
                    eflags<=((mem_load_data & 32'h0024_4DD5) |
                             (eflags & ~32'h0024_4DD5)) | 32'h0000_0002;
                    gpr[R_ESP]<=gpr[R_ESP]+{28'd0,q_w};
                  end
                  // LEAVE: ESP<-EBP (full, stack-addr width), then pop (E)BP.
                  // A 0x66 LEAVE pops a 16-bit BP (preserve EBP[31:16]) and the
                  // stack slot is 2 bytes wide, so ESP = old EBP + 2.
                  SM_LEAVE: begin
                    gpr[R_EBP]<=reg_merge(gpr[R_EBP], wmask(mem_load_data,q_w), q_w, 1'b0);
                    gpr[R_ESP]<=gpr[R_EBP]+{28'd0,q_w};
                  end
                  SM_PUSHA, SM_POPA: begin do_retire=1'b0; state<=S_USEQ; step<=4'd0; end
                  default: ;
                endcase
                flags_we=1'b0;
              end

              K_STR: begin
                // one element; with REP iterate via S_USEQ keeping pc fixed.
                logic [31:0] cx;
                logic        rep_active, last_iter, cmp_term, store_needed;
                cx = gpr[R_ECX];
                rep_active = (q_rep || q_repne);
                // ECX==0 degenerate REP: no element, just advance EIP, one record.
                if (rep_active && cx==32'd0) begin
                  // no memory effect; retire as a no-op (handled by do_retire below)
                  do_retire=1'b1; flags_we=1'b0; new_eip=next_eip;
                end else begin
                  // execute one element this cycle
                  store_needed = q_str_storedi; // MOVS/STOS write [EDI]
                  // update pointers / flags / regs for this element:
                  if (q_str_loadsi)  gpr[R_ESI]<=gpr[R_ESI]+str_step;
                  if (q_str_storedi) gpr[R_EDI]<=gpr[R_EDI]+str_step;
                  if (q_str_scandi)  gpr[R_EDI]<=gpr[R_EDI]+str_step;
                  if (q_st==ST_LODS) gpr[R_EAX]<=reg_merge(gpr[R_EAX], wmask(mem_load_data,q_w), q_w, 1'b0);
                  if (q_str_scandi) begin eflags<=str_flags; end
                  flags_we=1'b0;

                  if (rep_active) begin
                    cx = cx - 32'd1;
                    gpr[R_ECX]<=cx;
                    // termination: ECX reaches 0, or (REPE/REPNE) ZF condition.
                    cmp_term = 1'b0;
                    if (q_str_scandi) begin
                      if (q_rep)   cmp_term = (str_flags[6]==1'b0); // REPE: stop when ZF=0
                      if (q_repne) cmp_term = (str_flags[6]==1'b1); // REPNE: stop when ZF=1
                    end
                    last_iter = (cx==32'd0) || cmp_term;
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
                  // re-read gpr[EDI]).
                  str_store_addr <= gpr[R_EDI];
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
                    new_eip = (q_w==3'd2) ? {16'd0,mem_load_data[15:0]} : mem_load_data;
                    gpr[R_ESP]<=gpr[R_ESP]+{28'd0,q_w};
                  end
                  CT_RETN_IMM: begin
                    new_eip = (q_w==3'd2) ? {16'd0,mem_load_data[15:0]} : mem_load_data;
                    gpr[R_ESP]<=gpr[R_ESP]+{28'd0,q_w}+{16'd0,q_ret_imm};
                  end
                  CT_LOOP, CT_LOOPE, CT_LOOPNE: begin
                    // 0x67 address-size: the count register is CX (low 16):
                    // decrement preserves ECX[31:16] and the taken test is CX!=0.
                    logic [31:0] cx; logic take; logic zero_after;
                    if (q_cnt16) begin
                      cx = {gpr[R_ECX][31:16], (gpr[R_ECX][15:0]-16'd1)};
                      zero_after = (cx[15:0]==16'd0);
                    end else begin
                      cx = gpr[R_ECX]-32'd1;
                      zero_after = (cx==32'd0);
                    end
                    gpr[R_ECX]<=cx;
                    take=~zero_after;
                    if (q_ct==CT_LOOPE)  take=take & eflags[6];
                    if (q_ct==CT_LOOPNE) take=take & ~eflags[6];
                    new_eip = take ? (next_eip+q_rel) : next_eip;
                    flags_we=1'b0;
                  end
                  CT_JECXZ: begin
                    logic cx_zero;
                    cx_zero = q_cnt16 ? (gpr[R_ECX][15:0]==16'd0) : (gpr[R_ECX]==32'd0);
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
