// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/core_gpr_wb.svh — the GPR WRITEBACK DRIVER case-arms, `included ONCE inside
// core.sv's gpr-writeback `always_comb` (R3 modularization). NOT a standalone unit
// (no module / always wrapper); pasted at the `case (state)` site inside that one
// driver. Contains ONLY gpr writes: each arm reproduces the FSM's per-arm gating
// conditions and the corresponding `gpr_we[idx]=1'b1; gpr_wd[idx]=expr;` (the same
// value the original `gpr[idx] <= expr` committed). Every non-gpr statement
// (eflags/eip/seg/cr/retire/store/flags bookkeeping) is intentionally stripped.
// Block-local temporaries needed to form a gpr write VALUE are recomputed here
// from module-level signals (pure functions of the pre-edge state). Reads are
// gpr_o[] (the registered value), matching the FSM exactly.

`ifdef VEN_IDIV_ITER
        // S_DIV_BUSY: commit quotient/remainder to EAX(/EDX) when the iterative
        // divider finishes without a #DE.
        S_DIV_BUSY: begin
          if (eng_int_done && !eng_int_derr) begin
            if (q_w==3'd1)
              begin gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]={gpr_o[R_EAX][31:16], eng_int_rem[7:0], eng_int_quot[7:0]}; end
            else if (q_w==3'd2) begin
              gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]={gpr_o[R_EAX][31:16], eng_int_quot[15:0]};
              gpr_we[R_EDX]=1'b1; gpr_wd[R_EDX]={gpr_o[R_EDX][31:16], eng_int_rem[15:0]};
            end else begin
              gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]=eng_int_quot[31:0];
              gpr_we[R_EDX]=1'b1; gpr_wd[R_EDX]=eng_int_rem[31:0];
            end
          end
        end
`endif

`ifdef VEN_PS_PROXY
        // S_SYSCALL_WAIT: on the PS response, EAX <= syscall result.
        S_SYSCALL_WAIT: begin
          if (syscall_resp_valid) begin
            gpr_we[0]=1'b1; gpr_wd[0]=syscall_eax;
          end
        end
`endif

        // Protected far-pointer loads (LES/LDS/LSS/LFS/LGS) have two
        // architectural destinations. Commit the offset only on the SAME shared
        // success event that installs the validated segment descriptor; never in
        // S_EXEC, where a later descriptor fault would otherwise expose a partial
        // instruction. Real/V86 loads retain the ordinary S_EXEC writeback.
        S_SEGLD: begin
          if (segld_commit_ok && q_seg_from_mem && q_seg_load
              && !q_seg_load_lo && q_writes_reg) begin
            gpr_we[q_dst_reg]=1'b1;
            gpr_wd[q_dst_reg]=reg_merge(gpr_o[q_dst_reg],
                                        wmask(mem_load_data,q_w), q_w, 1'b0);
          end
        end

        // -------------------------------------------------------------------
        // S_EXEC — the integer execute/commit arm. The flag-only and seg/cr/dr-
        // only sysop branches are kept as EMPTY guards so the mutual-exclusion
        // ordering of the later gpr-writing branches is preserved verbatim.
        S_EXEC: begin
          if (q_cld) begin end
          else if (q_std) begin end
          else if (q_clc) begin end
          else if (q_stc) begin end
          else if (q_cmc) begin end
          else if (q_cli) begin end
          else if (q_sti) begin end
          else if (q_sysop==SYS_MOVCR_TO) begin end
          else if (q_sysop==SYS_MOVCR_FROM) begin
            unique case (q_sys_creg)
              3'd0: begin gpr_we[q_dst_reg]=1'b1; gpr_wd[q_dst_reg]=reg_merge(gpr_o[q_dst_reg], creg0, q_w, 1'b0); end  // q_w=4 MOV r32,CR0 (full) / q_w=2 SMSW r16
              3'd2: begin gpr_we[q_dst_reg]=1'b1; gpr_wd[q_dst_reg]=creg2; end
              3'd3: begin gpr_we[q_dst_reg]=1'b1; gpr_wd[q_dst_reg]=creg3; end
              default: begin gpr_we[q_dst_reg]=1'b1; gpr_wd[q_dst_reg]=creg4; end
            endcase
          end
          else if (q_sysop==SYS_MOVDR_TO) begin end
          else if (q_sysop==SYS_MOVDR_FROM) begin
            unique case (q_sys_creg)
              3'd0: begin gpr_we[q_dst_reg]=1'b1; gpr_wd[q_dst_reg]=dr0; end
              3'd1: begin gpr_we[q_dst_reg]=1'b1; gpr_wd[q_dst_reg]=dr1; end
              3'd2: begin gpr_we[q_dst_reg]=1'b1; gpr_wd[q_dst_reg]=dr2; end
              3'd3: begin gpr_we[q_dst_reg]=1'b1; gpr_wd[q_dst_reg]=dr3; end
              3'd4, 3'd6: begin gpr_we[q_dst_reg]=1'b1; gpr_wd[q_dst_reg]=dr6; end
              default:    begin gpr_we[q_dst_reg]=1'b1; gpr_wd[q_dst_reg]=dr7; end
            endcase
          end
          else if (q_sysop==SYS_MOVSREG_FROM) begin
            // R2-M01: a 32-bit destination zero-extends the selector (the QEMU/P5
            // contract); a 16-bit destination merges as before.
            gpr_we[q_dst_reg]=1'b1;
            gpr_wd[q_dst_reg]=(q_w==3'd4) ? {16'd0, seg_sel[q_sys_sreg]}
                                          : reg_merge(gpr_o[q_dst_reg], {16'd0, seg_sel[q_sys_sreg]}, 3'd2, 1'b0);
          end
          else if (q_sysop==SYS_STR) begin
            gpr_we[q_dst_reg]=1'b1;
            gpr_wd[q_dst_reg]=(q_w==3'd4) ? {16'd0, tr_sel}
                                          : reg_merge(gpr_o[q_dst_reg], {16'd0, tr_sel}, 3'd2, 1'b0);
          end
          else if (q_sysop==SYS_SLDT) begin
            gpr_we[q_dst_reg]=1'b1;
            gpr_wd[q_dst_reg]=(q_w==3'd4) ? {16'd0, ldt_sel}
                                          : reg_merge(gpr_o[q_dst_reg], {16'd0, ldt_sel}, 3'd2, 1'b0);
          end
          else if (q_sysop==SYS_MOVSREG_TO && !sys_mode && proxy_en) begin end
          else if (q_sysop==SYS_MOVSREG_TO) begin end
          else if (q_sysop==SYS_LJMP) begin end
          else begin
            unique case (q_kind)
              K_ALU: begin
                if (q_xlat) begin
                  gpr_we[R_EAX]=1'b1;
                  gpr_wd[R_EAX]=reg_merge(gpr_o[R_EAX], {24'd0, mem_load_data[7:0]}, 3'd1, 1'b0);
                end
                // LEA writes the effective address at the OPERAND size: a 16-bit LEA
                // (lea r16,[m]) writes only the low 16 bits, preserving dest[31:16];
                // only a 32-bit LEA overwrites the full register. (DOS-Quake root: go32's
                // `lea bx,[bp-0x18]` must keep EBX[31:16]=the client's EBX high half.)
                else if (q_is_lea) begin gpr_we[q_dst_reg]=1'b1;
                  gpr_wd[q_dst_reg]=reg_merge(gpr_o[q_dst_reg], q_ea, q_w, 1'b0); end
                else if (q_is_pop && q_mem_write) begin end
                else if (q_is_pop && q_pop_sreg) begin
                  gpr_we[R_ESP]=1'b1; gpr_wd[R_ESP]=gpr_o[R_ESP]+{28'd0,q_w};
                end else if (q_is_pop) begin
                  gpr_we[q_dst_reg]=1'b1;
                  gpr_wd[q_dst_reg]=reg_merge(gpr_o[q_dst_reg], wmask(mem_load_data,q_w), q_w, 1'b0);
                  if (q_dst_reg!=R_ESP) begin gpr_we[R_ESP]=1'b1; gpr_wd[R_ESP]=gpr_o[R_ESP]+{28'd0,q_w}; end
                end else if (q_mem_write) begin end
                else if (q_writes_reg
                         && !(q_seg_load && !q_seg_load_lo && !seg_real)) begin
                  gpr_we[q_dst_reg]=1'b1; gpr_wd[q_dst_reg]=reg_merge(dst_cur, alu_out, q_w, q_dst_high8);
                end
              end

              K_SHIFT: begin
                if (sh_cnt==6'd0) begin end
                else begin
                  if (q_mem_write) begin end
                  else begin gpr_we[q_dst_reg]=1'b1; gpr_wd[q_dst_reg]=reg_merge(dst_cur, sh_out, q_w, q_dst_high8); end
                end
              end

              K_SHLDRD: begin
                // R3 HOIST: ex_shld_cnt (count) + ex_shld_r (result) are the SHARED
                // module-scope values (core.sv); the FSM arm uses the same ones for
                // the cnt==0 guard + flags. No local recompute / second shifter.
                if (ex_shld_cnt==6'd0) begin end
                else if (q_mem_write) begin end   // memory dst: result stored to [mem] (S_STORE), no GPR
                else begin
                  gpr_we[q_dst_reg]=1'b1; gpr_wd[q_dst_reg]=reg_merge(dst_cur, ex_shld_r, q_w, 1'b0);
                end
              end

              K_MULDIV: begin
                // R3 HOIST: ex_mul_p / ex_imul_p (the ONE multiplier) and
                // ex_div_*/ex_idiv_* (the ONE native divider, /0-guarded) are the
                // SHARED module-scope values (core.sv); the FSM arm reads the same
                // ones for flags / #DE. No local recompute = no second `*` / `/`.
                unique case (q_md)
                  3'd4: begin // MUL (unsigned)
                    if (q_w==3'd1) begin gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]={gpr_o[R_EAX][31:16],ex_mul_p[15:0]}; end
                    else if (q_w==3'd2) begin
                      gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]={gpr_o[R_EAX][31:16],ex_mul_p[15:0]};
                      gpr_we[R_EDX]=1'b1; gpr_wd[R_EDX]={gpr_o[R_EDX][31:16],ex_mul_p[31:16]};
                    end else begin
                      gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]=ex_mul_p[31:0];
                      gpr_we[R_EDX]=1'b1; gpr_wd[R_EDX]=ex_mul_p[63:32];
                    end
                  end
                  3'd5: begin // IMUL one-operand (signed)
                    if (q_w==3'd1) begin gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]={gpr_o[R_EAX][31:16],ex_imul_p[15:0]}; end
                    else if (q_w==3'd2) begin
                      gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]={gpr_o[R_EAX][31:16],ex_imul_p[15:0]};
                      gpr_we[R_EDX]=1'b1; gpr_wd[R_EDX]={gpr_o[R_EDX][31:16],ex_imul_p[31:16]};
                    end else begin
                      gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]=ex_imul_p[31:0];
                      gpr_we[R_EDX]=1'b1; gpr_wd[R_EDX]=ex_imul_p[63:32];
                    end
                  end
                  3'd6: begin // DIV (unsigned)
`ifndef VEN_IDIV_ITER
                    if (!ex_div_dfault) begin
                      if (q_w==3'd1) begin gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]={gpr_o[R_EAX][31:16], ex_div_rr[7:0], ex_div_qq[7:0]}; end
                      else if (q_w==3'd2) begin gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]={gpr_o[R_EAX][31:16], ex_div_qq[15:0]};
                                                gpr_we[R_EDX]=1'b1; gpr_wd[R_EDX]={gpr_o[R_EDX][31:16], ex_div_rr[15:0]}; end
                      else begin gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]=ex_div_qq[31:0];
                                 gpr_we[R_EDX]=1'b1; gpr_wd[R_EDX]=ex_div_rr[31:0]; end
                    end
`endif
                  end
                  default: begin // IDIV /7 (signed)
`ifndef VEN_IDIV_ITER
                    if (!ex_idiv_dfault) begin
                      if (q_w==3'd1) begin gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]={gpr_o[R_EAX][31:16], ex_idiv_rr[7:0], ex_idiv_qq[7:0]}; end
                      else if (q_w==3'd2) begin gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]={gpr_o[R_EAX][31:16], ex_idiv_qq[15:0]};
                                                gpr_we[R_EDX]=1'b1; gpr_wd[R_EDX]={gpr_o[R_EDX][31:16], ex_idiv_rr[15:0]}; end
                      else begin gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]=ex_idiv_qq[31:0];
                                 gpr_we[R_EDX]=1'b1; gpr_wd[R_EDX]=ex_idiv_rr[31:0]; end
                    end
`endif
                  end
                endcase
              end

              K_IMUL2: begin
                logic [31:0] s1,s2;
                s1 = q_mem_read ? wmask(mem_load_data,q_w) : reg_read(q_src_reg,q_w,1'b0);
                s2 = q_imul_3op ? q_imul_imm : reg_read(q_dst_reg,q_w,1'b0);
                if (q_w==3'd2) begin logic signed [31:0] pp;
                  pp=$signed({{16{s1[15]}},s1[15:0]})*$signed({{16{s2[15]}},s2[15:0]});
                  gpr_we[q_dst_reg]=1'b1; gpr_wd[q_dst_reg]=reg_merge(dst_cur, {16'd0,pp[15:0]}, q_w, 1'b0);
                end else begin logic signed [63:0] pp; pp=$signed(s1)*$signed(s2);
                  gpr_we[q_dst_reg]=1'b1; gpr_wd[q_dst_reg]=reg_merge(dst_cur, pp[31:0], q_w, 1'b0);
                end
              end

              K_EXT: begin
                logic [31:0] s,r;
                s = q_mem_read ? mem_load_data : reg_read(q_src_reg, q_ext_srcw, q_src_high8);
                if (q_ext_srcw==3'd1) r = q_ext_signed ? {{24{s[7]}},s[7:0]} : {24'd0,s[7:0]};
                else                  r = q_ext_signed ? {{16{s[15]}},s[15:0]} : {16'd0,s[15:0]};
                gpr_we[q_dst_reg]=1'b1; gpr_wd[q_dst_reg]=reg_merge(gpr_o[q_dst_reg], r, q_w, 1'b0);
              end

              K_SETCC: begin
                if (q_mem_write) begin end
                else begin gpr_we[q_dst_reg]=1'b1;
                  gpr_wd[q_dst_reg]=reg_merge(gpr_o[q_dst_reg], {31'd0,cond_true(q_cc,eflags)}, 3'd1, q_dst_high8); end
              end

              K_BITTEST: begin
                logic [4:0] idx; logic [31:0] cur,res,srcv;
                cur=wmask(dst_cur,q_w);
                srcv = reg_read(q_src_reg,3'd4,1'b0);
                idx = q_bit_imm ? q_imm[4:0] : srcv[4:0];
                if (q_w==3'd2) idx = {1'b0, idx[3:0]};
                unique case (q_bit_op)
                  3'd5: res=cur | (32'd1<<idx);
                  3'd6: res=cur & ~(32'd1<<idx);
                  3'd7: res=cur ^ (32'd1<<idx);
                  default: res=cur;
                endcase
                if (q_writes_reg) begin gpr_we[q_dst_reg]=1'b1; gpr_wd[q_dst_reg]=reg_merge(gpr_o[q_dst_reg], res, q_w, 1'b0); end
              end

              K_BITSCAN: begin
                logic [31:0] s, idx; logic zero; int hi;
                s = wmask(q_mem_read ? mem_load_data : reg_read(q_src_reg,q_w,1'b0), q_w);
                hi = (q_w==3'd2) ? 15 : 31;
                zero=(s==32'd0); idx=32'd0;
                if (!q_shrd) begin for (int i=31;i>=0;i--) if (i<=hi && s[i]) idx=i[31:0]; end
                else         begin for (int i=0;i<=31;i++) if (i<=hi && s[i]) idx=i[31:0]; end
                if (!zero) begin gpr_we[q_dst_reg]=1'b1; gpr_wd[q_dst_reg]=reg_merge(gpr_o[q_dst_reg], idx, q_w, 1'b0); end
              end

              K_XCHG: begin
                if (q_mem_write) begin end
                else begin
                  logic [31:0] a,b;
                  a=reg_read(q_dst_reg,q_w,q_dst_high8); b=reg_read(q_src_reg,q_w,q_src_high8);
                  if (q_dst_reg == q_src_reg) begin
                    // Same GPR, different byte halves (e.g. `xchg ch,cl`, `xchg ah,al`):
                    // both writes target one register, so CHAIN the second merge off the
                    // first's result. Two independent reg_merge(gpr_o,...) would each start
                    // from the ORIGINAL value, so the later write discards the earlier byte
                    // (only one half swaps). q_dst_high8 != q_src_high8 here.
                    gpr_we[q_dst_reg]=1'b1;
                    gpr_wd[q_dst_reg]=reg_merge(reg_merge(gpr_o[q_dst_reg], b, q_w, q_dst_high8),
                                                a, q_w, q_src_high8);
                  end else begin
                    gpr_we[q_dst_reg]=1'b1; gpr_wd[q_dst_reg]=reg_merge(gpr_o[q_dst_reg], b, q_w, q_dst_high8);
                    gpr_we[q_src_reg]=1'b1; gpr_wd[q_src_reg]=reg_merge(gpr_o[q_src_reg], a, q_w, q_src_high8);
                  end
                end
              end

              K_CMPXCHG: begin
                if (!cmpxchg_eq) begin
                  gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]=reg_merge(gpr_o[R_EAX], cmpxchg_temp, q_w, 1'b0);
                end
                if (q_mem_write) begin end
                else begin
                  if (cmpxchg_eq) begin
                    gpr_we[q_dst_reg]=1'b1;
                    gpr_wd[q_dst_reg]=reg_merge(gpr_o[q_dst_reg], reg_read(q_src_reg,q_w,q_src_high8), q_w, q_dst_high8);
                  end
                end
              end

              K_XADD: begin
                if (q_mem_write) begin end
                else begin
                  gpr_we[q_src_reg]=1'b1; gpr_wd[q_src_reg]=reg_merge(gpr_o[q_src_reg], a_op, q_w, q_src_high8);
                  gpr_we[q_dst_reg]=1'b1; gpr_wd[q_dst_reg]=reg_merge(dst_cur, alu_out, q_w, q_dst_high8);
                end
              end

              K_BOUND: begin end

              K_CX8B: begin
                logic eq;
                eq = (mem_load_data == gpr_o[R_EAX]) && (mem_load_data2 == gpr_o[R_EDX]);
                if (eq) begin end
                else begin
                  gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]=mem_load_data;
                  gpr_we[R_EDX]=1'b1; gpr_wd[R_EDX]=mem_load_data2;
                end
              end

              K_BSWAP: begin logic [31:0] v; v=gpr_o[q_dst_reg];
                gpr_we[q_dst_reg]=1'b1; gpr_wd[q_dst_reg]={v[7:0],v[15:8],v[23:16],v[31:24]}; end

              K_CPUID: begin
                if (soc_en) begin
                  // task #102 DOS-Quake fix: the SoC CPUID table previously returned a
                  // qemu-DEFAULT-cpu (qemu64, family-6, sig 0x663, EDX=0x0781abfd P6
                  // feature set incl. CMOV/SEP/PGE/PAT) signature. But the DOS-Quake
                  // boot oracle — and psoccpuid's own documented oracle — is
                  // qemu-system-i386 `-cpu pentium` (P54C, family-5, sig 0x543,
                  // EDX=0x008003bd, leaf-0 max-basic-leaf=1). go32/CWSDPMI reads
                  // CPUID(1) on startup: the bogus 0x663/P6 signature made it
                  // misidentify the CPU and take its real-mode exception-reporter path
                  // (spurious #GP at `mov es,bx`, ending DOS-Quake early). The true
                  // Pentium table below (identical to the non-soc `-cpu pentium` arm,
                  // probed live from `-cpu pentium`) makes the boot match the oracle.
                  // qemu `-cpu pentium` clamps every undefined leaf to the leaf-1
                  // result, so only leaf 0 and 0x40000000 (TCG) are distinct.
                  unique case (gpr_o[R_EAX])
                    32'h0000_0000: begin gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]=32'h0000_0001; gpr_we[R_EBX]=1'b1; gpr_wd[R_EBX]=32'h756e_6547;
                                         gpr_we[R_ECX]=1'b1; gpr_wd[R_ECX]=32'h6c65_746e; gpr_we[R_EDX]=1'b1; gpr_wd[R_EDX]=32'h4965_6e69; end
                    32'h4000_0000: begin gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]=32'h4000_0001; gpr_we[R_EBX]=1'b1; gpr_wd[R_EBX]=32'h5447_4354;
                                         gpr_we[R_ECX]=1'b1; gpr_wd[R_ECX]=32'h4354_4743; gpr_we[R_EDX]=1'b1; gpr_wd[R_EDX]=32'h4743_5447; end
                    32'h4000_0001: begin gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]=32'h0000_0000; gpr_we[R_EBX]=1'b1; gpr_wd[R_EBX]=32'h0000_0000;
                                         gpr_we[R_ECX]=1'b1; gpr_wd[R_ECX]=32'h0000_0000; gpr_we[R_EDX]=1'b1; gpr_wd[R_EDX]=32'h0000_0000; end
                    default:       begin gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]=32'h0000_0543; gpr_we[R_EBX]=1'b1; gpr_wd[R_EBX]=32'h0000_0800;
                                         gpr_we[R_ECX]=1'b1; gpr_wd[R_ECX]=32'h8000_0000; gpr_we[R_EDX]=1'b1; gpr_wd[R_EDX]=32'h0080_03bd; end
                  endcase
                end else begin
                  unique case (gpr_o[R_EAX])
                    32'h0000_0000: begin
                      gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]=32'h0000_0001; gpr_we[R_EBX]=1'b1; gpr_wd[R_EBX]=32'h756e_6547;
                      gpr_we[R_ECX]=1'b1; gpr_wd[R_ECX]=32'h6c65_746e; gpr_we[R_EDX]=1'b1; gpr_wd[R_EDX]=32'h4965_6e69;
                    end
                    32'h4000_0000: begin
                      gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]=32'h4000_0001; gpr_we[R_EBX]=1'b1; gpr_wd[R_EBX]=32'h5447_4354;
                      gpr_we[R_ECX]=1'b1; gpr_wd[R_ECX]=32'h4354_4743; gpr_we[R_EDX]=1'b1; gpr_wd[R_EDX]=32'h4743_5447;
                    end
                    default: begin
                      gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]=32'h0000_0543; gpr_we[R_EBX]=1'b1; gpr_wd[R_EBX]=32'h0000_0800;
                      gpr_we[R_ECX]=1'b1; gpr_wd[R_ECX]=32'h8000_0000; gpr_we[R_EDX]=1'b1; gpr_wd[R_EDX]=32'h0080_03bd;
                    end
                  endcase
                end
              end

              K_RDTSC: begin
                gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]=tsc[31:0];
                gpr_we[R_EDX]=1'b1; gpr_wd[R_EDX]=tsc[63:32];
              end

              K_CONV: begin
                if (!q_conv_cdq) begin
                  if (q_w==3'd2) begin gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]={gpr_o[R_EAX][31:16], {8{gpr_o[R_EAX][7]}}, gpr_o[R_EAX][7:0]}; end
                  else           begin gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]={{16{gpr_o[R_EAX][15]}}, gpr_o[R_EAX][15:0]}; end
                end else begin
                  if (q_w==3'd2) begin gpr_we[R_EDX]=1'b1; gpr_wd[R_EDX]={gpr_o[R_EDX][31:16], {16{gpr_o[R_EAX][15]}}}; end
                  else           begin gpr_we[R_EDX]=1'b1; gpr_wd[R_EDX]={32{gpr_o[R_EAX][31]}}; end
                end
              end

              K_STKMISC: begin
                unique case (q_sm)
                  SM_LAHF: begin gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]={gpr_o[R_EAX][31:16], eflags[7:0], gpr_o[R_EAX][7:0]}; end
                  SM_SAHF: begin end
                  SM_PUSHF: begin end
                  SM_POPF: begin
                    gpr_we[R_ESP]=1'b1; gpr_wd[R_ESP]=gpr_o[R_ESP]+{28'd0,q_w};
                  end
                  SM_LEAVE: begin
                    gpr_we[R_EBP]=1'b1; gpr_wd[R_EBP]=reg_merge(gpr_o[R_EBP], wmask(mem_load_data,q_w), q_w, 1'b0);
                    gpr_we[R_ESP]=1'b1; gpr_wd[R_ESP]=gpr_o[R_EBP]+{28'd0,q_w};
                  end
                  SM_PUSHA, SM_POPA: begin end
                  SM_ENTER: begin end
                  default: ;
                endcase
              end

              K_STR: begin
                logic [31:0] cx;
                logic        rep_active;
                cx = gpr_o[R_ECX];
                rep_active = (q_rep || q_repne);
                if (rep_active && (q_cnt16 ? (cx[15:0]==16'd0) : (cx==32'd0))) begin end
                else begin
                  if (q_str_loadsi) begin gpr_we[R_ESI]=1'b1; gpr_wd[R_ESI]=q_cnt16
                      ? {gpr_o[R_ESI][31:16], gpr_o[R_ESI][15:0]+str_step[15:0]}
                      : gpr_o[R_ESI]+str_step; end
                  if (q_str_storedi) begin gpr_we[R_EDI]=1'b1; gpr_wd[R_EDI]=q_cnt16
                      ? {gpr_o[R_EDI][31:16], gpr_o[R_EDI][15:0]+str_step[15:0]}
                      : gpr_o[R_EDI]+str_step; end
                  if (q_str_scandi) begin gpr_we[R_EDI]=1'b1; gpr_wd[R_EDI]=q_cnt16
                      ? {gpr_o[R_EDI][31:16], gpr_o[R_EDI][15:0]+str_step[15:0]}
                      : gpr_o[R_EDI]+str_step; end
                  if (q_st==ST_LODS) begin gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]=reg_merge(gpr_o[R_EAX], wmask(mem_load_data,q_w), q_w, 1'b0); end
                  if (rep_active) begin
                    // R3 HOIST: dec_cx is the SHARED post-decrement ECX (core.sv).
                    gpr_we[R_ECX]=1'b1; gpr_wd[R_ECX]=dec_cx;
                  end
                end
              end

              K_CTRL: begin
                unique case (q_ct)
                  CT_CALLREL, CT_CALLIND: begin end
                  CT_JMPIND: begin end
                  CT_RETN: begin
                    gpr_we[R_ESP]=1'b1; gpr_wd[R_ESP]=gpr_o[R_ESP]+{28'd0,q_w};
                  end
                  CT_RETN_IMM: begin
                    gpr_we[R_ESP]=1'b1; gpr_wd[R_ESP]=gpr_o[R_ESP]+{28'd0,q_w}+{16'd0,q_ret_imm};
                  end
                  CT_LOOP, CT_LOOPE, CT_LOOPNE: begin
                    // R3 HOIST: dec_cx is the SHARED post-decrement ECX (core.sv).
                    gpr_we[R_ECX]=1'b1; gpr_wd[R_ECX]=dec_cx;
                  end
                  CT_JECXZ: begin end
                  default: ;
                endcase
              end
            endcase
          end
        end

        // -------------------------------------------------------------------
        // M7.3 port-I/O arms.
        S_IO: begin
          if (io_ack) begin
            if (!q_io_write) begin
              gpr_we[R_EAX]=1'b1;
              gpr_wd[R_EAX]=reg_merge(gpr_o[R_EAX], wmask(io_rdata, q_io_w), q_io_w, 1'b0);
            end
          end
        end

        S_INS: begin
          logic [31:0] cx;
          logic        rep_active;
          cx = gpr_o[R_ECX];
          rep_active = (q_rep || q_repne);
          if (rep_active && (q_cnt16 ? (cx[15:0]==16'd0) : (cx==32'd0))) begin end
          else if (io_ack) begin
            gpr_we[R_EDI]=1'b1; gpr_wd[R_EDI]=q_cnt16
                ? {gpr_o[R_EDI][31:16], gpr_o[R_EDI][15:0]+str_step[15:0]}
                : gpr_o[R_EDI] + str_step;
            if (rep_active) begin
              // R3 HOIST: dec_cx is the SHARED post-decrement ECX (core.sv).
              gpr_we[R_ECX]=1'b1; gpr_wd[R_ECX]=dec_cx;
            end
          end
        end

        // -------------------------------------------------------------------
        // store / micro-sequence arms.
        S_STORE: begin
          if (mem_ack) begin
            unique case (q_kind)
              K_CTRL: begin // CALL push: ESP -= w
                gpr_we[R_ESP]=1'b1; gpr_wd[R_ESP]=gpr_o[R_ESP]-{28'd0,q_w};
              end
              K_XCHG: begin // XCHG r/m,r mem: reg <- old mem
                gpr_we[q_src_reg]=1'b1;
                gpr_wd[q_src_reg]=reg_merge(gpr_o[q_src_reg], wmask(mem_load_data,q_w), q_w, q_src_high8);
              end
              K_STKMISC: begin // PUSHF (ESP-=w) or ENTER (EBP<-ESP-w, ESP<-ESP-w-alloc)
                if (q_sm==SM_ENTER) begin
                  // EBP<-ESP-w (new frame ptr), ESP<-ESP-w-alloc. reg_merge preserves
                  // EBP/ESP[31:16] for the 16-bit real-mode form (q_w=2); the 32-bit
                  // form (q_w=4) is a full write -> byte-identical to the prior code.
                  gpr_we[R_EBP]=1'b1; gpr_wd[R_EBP]=reg_merge(gpr_o[R_EBP], gpr_o[R_ESP]-{28'd0,q_w}, q_w, 1'b0);
                  gpr_we[R_ESP]=1'b1; gpr_wd[R_ESP]=reg_merge(gpr_o[R_ESP], gpr_o[R_ESP]-{28'd0,q_w}-{16'd0,q_imm[15:0]}, q_w, 1'b0);
                end else begin
                  gpr_we[R_ESP]=1'b1; gpr_wd[R_ESP]=gpr_o[R_ESP]-{28'd0,q_w};  // PUSHF
                end
              end
              K_XADD: begin // XADD memory form: SRC <- old [mem]
                gpr_we[q_src_reg]=1'b1;
                gpr_wd[q_src_reg]=reg_merge(gpr_o[q_src_reg], wmask(mem_load_data,q_w), q_w, q_src_high8);
              end
              K_STR: begin end  // string store: pointer/count already updated in S_EXEC
              default: begin
                if (q_is_push) begin gpr_we[R_ESP]=1'b1; gpr_wd[R_ESP]=gpr_o[R_ESP]-{28'd0,q_w}; end
                if (q_is_pop)  begin gpr_we[R_ESP]=1'b1; gpr_wd[R_ESP]=gpr_o[R_ESP]+{28'd0,q_w}; end // POP m
              end
            endcase
          end
        end

        // -------------------------------------------------------------------
        // S_WALK — string-store fault-restart ROLLBACK (Quake task #20 2nd bug).
        // A REP MOVS/STOS advances ESI/EDI/ECX in S_EXEC, BEFORE the element's store
        // commits in S_STORE. If that store demand-page-faults, S_STORE diverts to the
        // page walk (walk_ret_state==S_STORE) and the PDE-np(step0)/PTE-np(step2) #PF is
        // decided HERE. Left as-is, ESI/EDI/ECX are one element PAST the faulter, so the
        // IA-32 string RESTART (IRET back to the same REP prefix) SKIPS the faulting
        // element — the store is silently lost (the Quake page-table writer dropped
        // table[0], null-crashing the client). Roll them back to the pre-advance snapshot
        // latched in S_EXEC (str_store_addr = pre-advance EDI, str_pre_esi/ecx) so the
        // restart re-does exactly that element. xlate_miss==0 during S_WALK (S_WALK is a
        // non-translatable state), so this arm is reached; gpr_we defaults to 0 on every
        // other walk clock, so it is a no-op except on the fault-decision clock.
        S_WALK: begin
          if (mem_ack && walk_is_write && (walk_ret_state==S_STORE)
              && (q_kind==K_STR) && q_str_storedi
              && ((walk_step==3'd0 && !mem_rdata[0]) || (walk_step==3'd2 && !mem_rdata[0]))) begin
            gpr_we[R_EDI]=1'b1; gpr_wd[R_EDI]=str_pre_edi;                          // pre-advance EDI (full)
            if (q_str_loadsi)         begin gpr_we[R_ESI]=1'b1; gpr_wd[R_ESI]=str_pre_esi; end  // MOVS src ptr
            if (q_rep || q_repne)     begin gpr_we[R_ECX]=1'b1; gpr_wd[R_ECX]=str_pre_ecx; end  // REP count
          end
        end

        S_USEQ: begin
          if (mem_ack) begin
            if (q_kind==K_CX8B) begin end
            else if (q_sm==SM_PUSHA) begin
              // Width-aware ESP delta: PUSHAD pops 32 (8x4), PUSHAW 16 (8x2).
              if (step==4'd7) begin gpr_we[R_ESP]=1'b1; gpr_wd[R_ESP]=pusha_esp - (32'd8*{29'd0,q_w}); end
            end else begin // POPA
              // reg_merge(...,q_w,..): POPAD (q_w=4) writes the full 32-bit slot; POPAW
              // (q_w=2, the CS16/D=0 form go32 uses) writes only the low 16 and PRESERVES
              // each register's high half. The prior raw `=mem_rdata` corrupted the high
              // 16 of every register under POPAW (the DOS-Quake EBX-high root cause).
              unique case (step)
                4'd0: begin gpr_we[R_EDI]=1'b1; gpr_wd[R_EDI]=reg_merge(gpr_o[R_EDI], mem_rdata, q_w, 1'b0); end
                4'd1: begin gpr_we[R_ESI]=1'b1; gpr_wd[R_ESI]=reg_merge(gpr_o[R_ESI], mem_rdata, q_w, 1'b0); end
                4'd2: begin gpr_we[R_EBP]=1'b1; gpr_wd[R_EBP]=reg_merge(gpr_o[R_EBP], mem_rdata, q_w, 1'b0); end
                4'd3: ; // skip ESP slot
                4'd4: begin gpr_we[R_EBX]=1'b1; gpr_wd[R_EBX]=reg_merge(gpr_o[R_EBX], mem_rdata, q_w, 1'b0); end
                4'd5: begin gpr_we[R_EDX]=1'b1; gpr_wd[R_EDX]=reg_merge(gpr_o[R_EDX], mem_rdata, q_w, 1'b0); end
                4'd6: begin gpr_we[R_ECX]=1'b1; gpr_wd[R_ECX]=reg_merge(gpr_o[R_ECX], mem_rdata, q_w, 1'b0); end
                default: begin gpr_we[R_EAX]=1'b1; gpr_wd[R_EAX]=reg_merge(gpr_o[R_EAX], mem_rdata, q_w, 1'b0); end
              endcase
              if (step==4'd7) begin gpr_we[R_ESP]=1'b1; gpr_wd[R_ESP]=gpr_o[R_ESP]+(32'd8*{29'd0,q_w}); end
            end
          end
        end

        // -------------------------------------------------------------------
        // S_ENTER: nested ENTER final commit (on the (level+1)th push). EBP<-FrameTemp
        // (=ESP-w), ESP<-ESP-(level+1)*w-alloc. reg_merge keeps the high half for the
        // 16-bit real-mode form (q_w=2); full write for the 32-bit form.
        S_ENTER: begin
          if (mem_ack && !ent_rd && (({1'b0, q_imm[20:16]} + 6'd1) == ent_k)) begin
            logic [31:0] tot;
            tot = ({26'd0, ({1'b0, q_imm[20:16]} + 6'd1)} * {29'd0, q_w}) + {16'd0, q_imm[15:0]};
            gpr_we[R_EBP]=1'b1; gpr_wd[R_EBP]=reg_merge(gpr_o[R_EBP], gpr_o[R_ESP]-{28'd0,q_w}, q_w, 1'b0);
            gpr_we[R_ESP]=1'b1; gpr_wd[R_ESP]=reg_merge(gpr_o[R_ESP], gpr_o[R_ESP]-tot,        q_w, 1'b0);
          end
        end

        // -------------------------------------------------------------------
        // M9.5 real-mode far CALL / RET arms (gpr write only on beat 1).
        S_LCALL: begin
          // R2-H05: lc_callw = the gate width for a gated call, q_w otherwise.
          if (mem_ack && seg_step) begin
            gpr_we[R_ESP]=1'b1; gpr_wd[R_ESP]=gpr_o[R_ESP] - {27'd0, lc_callw, 1'b0};
          end
        end

        S_RETF: begin
          // REVIEW2_aug2 C-06: an OUTER-level return does not ADVANCE the inner ESP --
          // it REPLACES ESP from the frame, at the single validated commit in
          // S_IRET_SS. Bumping it here would also move the anchor the bus driver uses
          // to address the remaining ESP/SS pops, so the beat-1 detection has to
          // suppress this write on the same clock it fires. The condition is the
          // popped CS.RPL, exactly as in the S_RETF arm of core_seg_ljmp.svh.
          // REVIEW_Aug3 H-02: a PROTECTED same-privilege RETF no longer advances ESP
          // here either -- the popped target CS is validated only later, in S_LJMP,
          // and a rejected target must fault with ESP untouched. The advance is
          // staged (retf_same/retf_esp_adj at the beat-1 handoff) and fires on
          // retf_commit_w in the S_LJMP arm below. Only the REAL-MODE form (which
          // has no later validation stage) still advances ESP at the pop.
          if (mem_ack && seg_step && !retf_out && seg_real) begin
            gpr_we[R_ESP]=1'b1; gpr_wd[R_ESP]=gpr_o[R_ESP] + {27'd0, q_w, 1'b0} + {16'd0, q_ret_imm};
          end
        end

        // REVIEW_Aug3 H-02: the deferred same-privilege protected RETF ESP advance.
        // retf_commit_w is the S_LJMP arm's accept condition computed combinationally
        // in core.sv, so this fires on exactly the clock the target CS commits --
        // and never on a selector/descriptor/offset fault (start_fault cleared
        // retf_same, and the commit predicate itself excludes those cases).
        S_LJMP: begin
          if (retf_commit_w) begin
            gpr_we[R_ESP]=1'b1; gpr_wd[R_ESP]=gpr_o[R_ESP] + retf_esp_adj;
          end
        end

        // -------------------------------------------------------------------
`ifdef VEN_FP_SHARED
        // The shared top supplies FNSTSW AX on its response, after the command
        // edge that also owns the FP-state mutation.  Capture it on the same edge
        // as the conservative in-order x87 retirement.
        S_FP_SHARED_WAIT: begin
          if (fp_shared_rsp_valid && fp_shared_rsp_ax_valid) begin
            gpr_we[R_EAX]=1'b1;
            gpr_wd[R_EAX]={gpr_o[R_EAX][31:16], fp_shared_rsp_ax};
          end
        end
`else
        // S_FEXEC: only the FNSTSW AX cross-leaf gpr[EAX] write (gated !f_pc_bad).
        S_FEXEC: begin
          logic f_is_arith, f_pc_bad;
          f_is_arith = (q_fxop==FX_AR_ST0_STI) || (q_fxop==FX_AR_STI_ST0) ||
                       (q_fxop==FX_AR_M32)     || (q_fxop==FX_AR_M64)     ||
                       (q_fxop==FX_AR_I16)     || (q_fxop==FX_AR_I32)     ||
                       (q_fxop==FX_FSQRT);
`ifdef VEN_FP_PC_RELAX
          f_pc_bad = 1'b0;
`else
          f_pc_bad = f_is_arith && (fctrl[9:8] != 2'b11);
`endif
          if (!f_pc_bad && q_fxop==FX_FNSTSW_AX) begin
            gpr_we[R_EAX]=1'b1;
            gpr_wd[R_EAX]={gpr_o[R_EAX][31:16], (fstat & ~16'h3800) | ({13'd0,ftop}<<11)};
          end
        end
`endif

        // -------------------------------------------------------------------
        // M2S.5 RSM: restore the GPR file on the final read-back beat.
        S_RSM: begin
          if (mem_ack && (smm_step == SMM_LAST))
            for (int g = 0; g < NUM_GPR; g++) begin gpr_we[g]=1'b1; gpr_wd[g]=rsm_gpr[g]; end
        end

        // -------------------------------------------------------------------
        // M2S.4b task switch: load the incoming GPRs on the commit beat.
        S_TSW_BUSY: begin
          if (mem_ack && (tsw_step != 5'd0))
            for (int g = 0; g < NUM_GPR; g++) begin gpr_we[g]=1'b1; gpr_wd[g]=tsw_gpr[g]; end
        end

        // -------------------------------------------------------------------
        // M2S.3 IDT delivery: ESP drop on the last push beat.
        S_INT_PUSH: begin
          if (mem_ack) begin
            logic last;
            logic [31:0] fsz;
            if (from_v86)
              last = int_has_err ? (int_step == 4'd9) : (int_step == 4'd8);
            else if (xpl_active)
              last = cg_xpl ? (cg_beat == (6'd3 + {1'b0, cg_pcount}))   // R2-H05
                            : (int_has_err ? (int_step == 4'd5) : (int_step == 4'd4));
            else
              last = int_has_err ? (int_step == 4'd3) : (int_step == 4'd2);
            if (last) begin
              if (from_v86) begin
                fsz = int_has_err ? 32'd40 : 32'd36;
                // SET_ESP through the new (SS0) stack's B mask, like every
                // other cross-priv frame: a 16-bit SS0 replaces only ESP[15:0]
                // and the low word WRAPS (QEMU sp_mask semantics).
                gpr_we[R_ESP]=1'b1;
                gpr_wd[R_ESP]= ss_b ? (int_new_esp - fsz)
                                    : ((gpr_o[R_ESP] & 32'hFFFF_0000)
                                       | ((int_new_esp - fsz) & 32'h0000_FFFF));
              end else if (xpl_active && cg_xpl) begin
                // REVIEW1_Aug3 R2-H05: the call-gate ESP commit. fsz = the 4
                // header slots + cg_pcount params, in gate-width units; the
                // result commits through the NEW stack's B mask (SET_ESP(sp,
                // sp_mask) in QEMU: a 16-bit new stack replaces only ESP[15:0]).
                fsz = cg_wide ? (32'd16 + {25'd0, cg_pcount, 2'b00})
                              : (32'd8  + {26'd0, cg_pcount, 1'b0});
                gpr_we[R_ESP]=1'b1;
                gpr_wd[R_ESP]= ss_b ? (int_new_esp - fsz)
                                    : ((gpr_o[R_ESP] & 32'hFFFF_0000)
                                       | ((int_new_esp - fsz) & 32'h0000_FFFF));
              end else if (xpl_active) begin
                // A4-H03: one frame plan. A 16-bit interrupt/trap gate (int_frm16)
                // pushes a WORD frame: 10 bytes (SS, SP, FLAGS, CS, IP), 12 with an
                // error code -- this used to charge the 32-bit 20/24 regardless of
                // gate width, so a 16-bit cross-priv delivery landed the handler at
                // the wrong ESP. The commit wraps through the NEW stack's B mask,
                // exactly like the call-gate arm above (SET_ESP(sp, sp_mask)).
                fsz = int_frm16 ? (int_has_err ? 32'd12 : 32'd10)
                                : (int_has_err ? 32'd24 : 32'd20);
                gpr_we[R_ESP]=1'b1;
                gpr_wd[R_ESP]= ss_b ? (int_new_esp - fsz)
                                    : ((gpr_o[R_ESP] & 32'hFFFF_0000)
                                       | ((int_new_esp - fsz) & 32'h0000_FFFF));
`ifdef VEN_DBG_WD
                // Generic cross-privilege handler-stack writeback trace.
                $display("[VEN-ESPWR] XPL handler ESP<=%08h = int_new_esp(%08h) - fsz(%0d) has_err=%b vec=%0d @cs:eip=%04x:%08h",
                         int_new_esp - fsz, int_new_esp, fsz, int_has_err, int_vec, seg_sel[SG_CS], eip);
`endif
              end else if (int_gate_op16) begin
                // SAME-PRIV 16-BIT GATE: 6-byte IP:CS:FLAGS frame, 8-byte with an
                // error code (A4-H03 -- the errcode size was hard-charged 6).
                // SP wraps in the low 16 bits on a 16-bit stack (SS.B=0),
                // preserving ESP's upper half -- mirroring the wrap the xpl and
                // call-gate arms already do.
                fsz = int_has_err ? 32'd8 : 32'd6;
                gpr_we[R_ESP]=1'b1;
                gpr_wd[R_ESP]= ss_b ? (gpr_o[R_ESP] - fsz)
                                    : ((gpr_o[R_ESP] & 32'hFFFF_0000)
                                       | ((gpr_o[R_ESP] - fsz) & 32'h0000_FFFF));
              end else begin
                fsz = int_has_err ? 32'd16 : 32'd12;
                gpr_we[R_ESP]=1'b1; gpr_wd[R_ESP]=gpr_o[R_ESP] - fsz;
              end
            end
          end
        end

        // -------------------------------------------------------------------
        // IRET pop arm: ESP commits on the same-priv / inter-priv / V86 final beat.
        S_IRET: begin
          if (mem_ack) begin
            unique case (int_step)
              4'd2: begin
                // 16-bit IRETW (int_gate_op16) is always the same-priv 6-byte commit
                // (SP += 6); guard the V86/inter-priv suppression off so a garbage
                // high-half VM bit (from the dword read of a 2-byte slot) can't divert.
                // REVIEW_aug2 C-07 (mirror drift): the inter-priv suppression carried a
                // `!int_gate_op16` that core_iret.svh no longer has -- once the 16-bit
                // inter-privilege IRET was un-gated there, a 16-bit outer-level return
                // took the pop-ESP/SS path in the FSM while THIS driver still added 6 to
                // ESP at beat 2, so beats 3 and 4 read their ESP/SS slots from the wrong
                // offsets. The privilege decision is iret_interpriv in both places now.
                if (!int_gate_op16 && mem_rdata[17] && cpl_r == 2'd0) begin end
                else if (iret_interpriv) begin end
                // REVIEW1_Aug2 C-06: the same-privilege ESP advance no longer happens
                // here either. It commits with EIP/EFLAGS/CS in S_INT_CS_RET, gated by
                // the shared iret_cs_commit -- a frame rejected for a bad CS must leave
                // ESP pointing at the frame so the IRET is restartable.
                else begin end
              end
              4'd4: begin
                // REVIEW_aug2 C-07: ESP no longer commits here. On the inter-priv path
                // it commits with the rest of the frame, in S_IRET_SS, gated by the
                // SAME predicate the FSM uses (iret_ss_commit) -- see the S_IRET_SS arm
                // below. The V86 return still commits at beat 8.
              end
              4'd0, 4'd1, 4'd3, 4'd5, 4'd6, 4'd7: ;
              default: begin gpr_we[R_ESP]=1'b1; gpr_wd[R_ESP]=iret_esp; end  // beat 8 (V86 commit)
            endcase
          end
        end
        // REVIEW_aug2 C-07: the OUTER ESP of an inter-privilege IRET. It commits with
        // CS/SS/EIP/EFLAGS on the single validated commit clock, never before -- a frame
        // rejected for a bad SS must leave the inner ESP untouched. iret_ss_commit is
        // the same expression core_iret.svh branches on (defined once, in core.sv), so
        // the two drivers cannot disagree about whether the frame was accepted.
        S_IRET_SS: begin
          if (iret_ss_commit) begin
            gpr_we[R_ESP]=1'b1;
            // The restore's mask follows the OUTER stack's B bit (mem_rdata[22]
            // = desc[54] of the popped SS descriptor at this commit clock):
            // 32-bit outer stack -> full assignment; 16-bit -> the popped SP
            // word replaces SP only, preserving the handler ESP's upper half
            // (QEMU's SET_ESP(sp, get_sp_mask(ss_e2))). esp_arch_dst exempts
            // the write from the generic 16-bit-stack post-process.
            gpr_wd[R_ESP]= mem_rdata[22] ? iret_esp
                                         : {gpr_o[R_ESP][31:16], iret_esp[15:0]};
          end
        end
        // REVIEW1_Aug2 C-06: the SAME-PRIVILEGE ESP advance, on the validated commit
        // clock. iret_cs_commit is the same expression core_iret.svh branches on.
        S_INT_CS_RET: begin
          if (iret_cs_commit) begin gpr_we[R_ESP]=1'b1;
            gpr_wd[R_ESP]=gpr_o[R_ESP] + (int_gate_op16 ? 32'd6 : 32'd12); end
        end

        // -------------------------------------------------------------------
        // F3 real-mode IVT delivery / IRET: ESP adjust on the final beat.
        S_RMINT_PUSH: begin
          if (mem_ack && (int_step == 4'd2)) begin
            gpr_we[R_ESP]=1'b1; gpr_wd[R_ESP]=gpr_o[R_ESP] - 32'd6;
          end
        end

        S_RMIRET: begin
          if (rm_read_armed && mem_ack) begin
            unique case (int_step)
              4'd0, 4'd1: ;
              default: begin gpr_we[R_ESP]=1'b1; gpr_wd[R_ESP]=gpr_o[R_ESP] + 32'd6; end
            endcase
          end
        end

        // -------------------------------------------------------------------
        // S_DECODE: the int-0x80 proxy syscall fold (non-VEN_PS_PROXY) writes EAX.
        // The preceding else-if branches (no gpr write) are kept as empty guards so
        // the mutual-exclusion ordering of the proxy branch is preserved verbatim.
        S_DECODE: begin
          // Must mirror core_fetch_decode.svh exactly: a quiescent debugger
          // park owns the boundary, and a host STEP defers asynchronous delivery
          // until the one requested instruction has retired.
          if (dbg_block_issue) begin end
          else if (smi_pending && sys_mode && !smm_active && !dbg_step_active) begin end
          else if (nmi_take && !dbg_step_active) begin end
          else if (intr_take && !dbg_step_active) begin end
          else if (DBG_GD_ENABLE && sys_mode &&
                   (d_sysop==SYS_MOVDR_TO || d_sysop==SYS_MOVDR_FROM) && dr7[DR7_GD]) begin end
          else if (sys_mode && creg4[3] &&
                   (d_sysop==SYS_MOVDR_TO || d_sysop==SYS_MOVDR_FROM) &&
                   (d_sys_creg==3'd4 || d_sys_creg==3'd5)) begin end
          else if (v86 && iopl < 2'd3 &&
                   (d_cli || d_sti ||
                    (d_kind==K_STKMISC && (d_sm==SM_PUSHF || d_sm==SM_POPF)) ||
                    d_int_imm || d_iret)) begin end
          else if (d_io) begin end
          else if (proxy_en && d_int80) begin
`ifndef VEN_PS_PROXY
            gpr_we[0]=1'b1; gpr_wd[0]=syscall_eax;
`endif
          end
        end

        // -------------------------------------------------------------------
        // S_PIPE — the dual-issue fast path. GPR writes happen ONLY in the final
        // ISSUE `else` arm (U commit + paired-V commit). The whole preceding else-
        // if chain is reproduced as empty guards so the ISSUE arm is reached under
        // the SAME condition (every bubble/miss/stall path falls through to it).
        S_PIPE: begin
          // An accepted interrupt diverts the spine BEFORE anything issues, so this
          // clock must write no GPR. Without this arm the chain fell through to ISSUE
          // and committed a register for an instruction that never retired (and, since
          // EIP is not advanced on the divert, re-executes after IRET).
          if (fp_issue_block) begin end
          else if (stall_cnt!=7'd0) begin end
          else if (!pipe_bytes_ok
`ifdef VEN_L1_AXI
                       && !(real_bus && !mem_ack)
`endif
                      ) begin end
`ifdef VEN_L1_AXI
          else if (!pipe_bytes_ok) begin end
`endif
`ifdef VEN_IC_BRAM
          else if (!ic_fetch_ready) begin end
`endif
`ifdef VEN_UOPCACHE
          else if (!uop_hit || !cycle_mode) begin end
`endif
          else if (pending_mem_pen!=7'd0) begin end
`ifdef VEN_L1_AXI
          else if (real_bus && pipe_load_req && !mem_ack) begin end
`endif
`ifdef VEN_FP_PIPE
          else if (fp_pipe_rd_haz) begin end
`endif
          else if (u_d.is_fp && u_d.fp_kind==FK_ARITH && fctrl[9:8]!=2'b11) begin end
          else if (u_d.is_fp) begin end   // FP path writes no GP register
          // REVIEW Aug-1 C-01: was a hand-copied `!u_d.simple || sys_mode`, which went
          // stale when task #55 relaxed the spine. Consume the canonical predicate.
          else if (fp_sys_bail) begin end
          else if (mispred_bubbles!=3'd0) begin end
          else if (pipe_agi) begin end
          else begin
            // ---- U commit ----
            if (u_d.is_lea) begin
              gpr_we[u_d.dst]=1'b1; gpr_wd[u_d.dst]=gpr_o[u_d.base];
            end else if (u_d.is_load) begin
              gpr_we[u_d.dst]=1'b1; gpr_wd[u_d.dst]=mem_rdata;
            end else if (u_d.is_shift) begin
              // REVIEW Aug-1 (H-02 companion): a 16-bit shift must PRESERVE the upper
              // half of its destination. This wrote all 32 bits unconditionally, which
              // is the same defect class as C-01 one arm over. Use the slow path's
              // canonical width-aware merge, exactly as the ALU arm below does.
              gpr_we[u_d.dst]=1'b1;
              gpr_wd[u_d.dst]= reg_merge(gpr_o[u_d.dst], u_sh, u_d.w16 ? 3'd2 : 3'd4, 1'b0);
            end else if (u_d.is_branch || u_d.is_nop) begin
              // no register write
            end else begin
              // 16-bit ops must PRESERVE the destination's upper half, so use the SLOW
              // path's canonical width-aware merge (reg_merge, as at :57) rather than a
              // hand-rolled {gpr[31:16], alu[15:0]} concat. One shared helper for every
              // width; nothing here to drift out of sync with the slow path.
              //
              // CORRECTION (this comment previously said the VEN_D16_NOWREG bisect
              // "proved the defect is here"). It did not. That bisect reached POST only
              // because rejecting register-writing instructions removed exactly the ones
              // whose writes were being DISCARDED by the stale guard a few lines up
              // (C-01) -- the write VALUE was never wrong. The hand-rolled concat was in
              // fact bit-identical to reg_merge at w==2, so that change could not have
              // altered behaviour either way. Kept for the shared-helper reason above.
              if (u_d.wreg) begin gpr_we[u_d.dst]=1'b1;
                gpr_wd[u_d.dst]= reg_merge(gpr_o[u_d.dst], u_alu, u_d.w16 ? 3'd2 : 3'd4, 1'b0); end
            end
            // ---- V commit (paired) ----
            if (pipe_pair) begin
              if (v_d.is_lea) begin
                gpr_we[v_d.dst]=1'b1; gpr_wd[v_d.dst]=gpr_o[v_d.base];
              end else if (v_d.is_branch || v_d.is_nop) begin
                // no register write
              end else begin
                if (v_d.wreg) begin gpr_we[v_d.dst]=1'b1;
                  gpr_wd[v_d.dst]= reg_merge(gpr_o[v_d.dst], v_alu, v_d.w16 ? 3'd2 : 3'd4, 1'b0); end
              end
            end
          end
        end
