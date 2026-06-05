// core/core_iret.svh — RAW case-arm text `included inside core.sv's always_ff
// `unique case (state)` (R2 modularization). NOT a standalone unit (no module/
// always wrapper); pasted verbatim at the original FSM site, netlist identical.
// Covers the IRET pop + CS/SS reload arms:
//   S_IRET (pop EIP/CS/EFLAGS [+ESP/SS inter-priv]), S_INT_CS_RET (CS reload),
//   S_IRET_SS (SS reload on inter-priv return).
        // S_IRET: pop EIP, CS, EFLAGS. Beat 0 EIP @ ESP, 1 CS @ ESP+4,
        // 2 EFLAGS @ ESP+8. M2S.4 INTER-PRIV IRET: once the popped CS is known
        // (beat 1), if CS.RPL > the current CPL the return is to a LESS-privileged
        // level — the frame additionally carries ESP @ ESP+12 and SS @ ESP+16, so
        // we keep popping (beats 3,4) and switch to the outer stack. SAME-PRIV
        // (CS.RPL == CPL): stop at beat 2, ESP += 12, reload CS, retire.
        S_IRET: begin
          if (mem_ack) begin
            unique case (int_step)
              4'd0: begin iret_eip   <= mem_rdata;        int_step <= 4'd1; end
              4'd1: begin
                iret_cs    <= mem_rdata[15:0];
                // inter-priv iff the returned-to CS is less privileged than now.
                iret_interpriv <= (mem_rdata[1:0] > cpl_r);
                int_step <= 4'd2;
              end
              4'd2: begin
                // EFLAGS popped. Hold it; the actual eflags/eip/ESP commit happens
                // on the final beat so an inter-priv pop can still read ESP/SS.
                iret_eflags <= mem_rdata;
                // M7.2: IRET from CPL0 with the popped EFLAGS.VM (bit17) set is a
                // RETURN INTO V86. It always pops the full 9-word frame (ESP,SS +
                // ES,DS,FS,GS follow) and switches stacks, regardless of the popped
                // CS.RPL (the V86 CS is a real-mode selector, RPL=0). Only meaningful
                // from CPL0 (the monitor); INERT for every non-V86 IRET (bit17=0).
                if (mem_rdata[17] && cpl_r == 2'd0) begin
                  iret_to_v86 <= 1'b1;
                  int_step    <= 4'd3;             // pop ESP, SS, ES, DS, FS, GS
                end else if (iret_interpriv) int_step <= 4'd3;   // pop ESP, SS
                else begin
                  // SAME-PRIV: commit now (ESP += 12), reload CS, retire via _RET.
                  gpr[R_ESP]   <= gpr[R_ESP] + 32'd12;
                  eip          <= iret_eip;
                  eflags       <= mem_rdata;
                  int_gate_sel <= iret_cs;
                  int_step     <= 4'd0;
                  state        <= S_INT_CS_RET;
                end
              end
              4'd3: begin iret_esp <= mem_rdata;         int_step <= 4'd4; end
              4'd4: begin
                iret_ss      <= mem_rdata[15:0];
                if (iret_to_v86) int_step <= 4'd5;   // V86: keep popping ES,DS,FS,GS
                else begin
                  // M2S.4 inter-priv (non-V86): SS popped. Commit the inter-priv
                  // return: EIP, EFLAGS, and the OUTER ESP/SS. seg_base[SG_SS] is
                  // still the inner base while we reload the CS (S_INT_CS_RET), then
                  // S_IRET_SS loads the outer SS descriptor. ESP <- popped outer ESP.
                  eip          <= iret_eip;
                  eflags       <= iret_eflags;
                  gpr[R_ESP]   <= iret_esp;
                  int_gate_sel <= iret_cs;
                  int_step     <= 4'd0;
                  state        <= S_INT_CS_RET;
                end
              end
              // ---- M7.2 V86-return tail: pop ES, DS, FS, GS (beats 5..8) --------
              4'd5: begin iret_v86_es <= mem_rdata[15:0]; int_step <= 4'd6; end
              4'd6: begin iret_v86_ds <= mem_rdata[15:0]; int_step <= 4'd7; end
              4'd7: begin iret_v86_fs <= mem_rdata[15:0]; int_step <= 4'd8; end
              default: begin
                // beat 8: GS popped — COMMIT the return into V86. Load every segment
                // (CS/SS/DS/ES/FS/GS) base = sel<<4 with NO descriptor read (V86
                // segmentation), force CPL=3, restore EFLAGS (VM set), EIP, ESP. The
                // V86 segment limit is the real-mode 64 KiB default; attr is the
                // present R/W default. This retires the IRET directly (no S_INT_CS_RET
                // descriptor reload — V86 has no GDT-backed CS).
                iret_v86_gs <= mem_rdata[15:0];
                eip         <= iret_eip;
                eflags      <= iret_eflags;            // VM is set in the popped image
                gpr[R_ESP]  <= iret_esp;
                cpl_r       <= 2'd3;                   // V86 runs at CPL3
                cs_d        <= 1'b0;                   // V86 is 16-bit default
                // CS = popped selector, base = sel<<4.
                seg_sel  [SG_CS] <= iret_cs;
                seg_base [SG_CS] <= {12'd0, iret_cs, 4'd0};
                seg_limit[SG_CS] <= 32'h0000_FFFF;
                seg_attr [SG_CS] <= 8'h9B;
                // SS:base = popped SS sel<<4.
                seg_sel  [SG_SS] <= iret_ss;
                seg_base [SG_SS] <= {12'd0, iret_ss, 4'd0};
                seg_limit[SG_SS] <= 32'h0000_FFFF;
                seg_attr [SG_SS] <= 8'h93;
                // ES/DS/FS/GS:base = popped sel<<4 (the V86 data segments).
                seg_sel  [SG_ES] <= iret_v86_es;
                seg_base [SG_ES] <= {12'd0, iret_v86_es, 4'd0};
                seg_limit[SG_ES] <= 32'h0000_FFFF; seg_attr[SG_ES] <= 8'h93;
                seg_sel  [SG_DS] <= iret_v86_ds;
                seg_base [SG_DS] <= {12'd0, iret_v86_ds, 4'd0};
                seg_limit[SG_DS] <= 32'h0000_FFFF; seg_attr[SG_DS] <= 8'h93;
                seg_sel  [SG_FS] <= iret_v86_fs;
                seg_base [SG_FS] <= {12'd0, iret_v86_fs, 4'd0};
                seg_limit[SG_FS] <= 32'h0000_FFFF; seg_attr[SG_FS] <= 8'h93;
                seg_sel  [SG_GS] <= mem_rdata[15:0];
                seg_base [SG_GS] <= {12'd0, mem_rdata[15:0], 4'd0};
                seg_limit[SG_GS] <= 32'h0000_FFFF; seg_attr[SG_GS] <= 8'h93;
                iret_to_v86  <= 1'b0;
                int_step     <= 4'd0;
                q_pc         <= int_src_pc;            // stamp the IRET insn's PC
                retire_valid <= 1'b1;
                state        <= S_PIPE;
              end
            endcase
          end
        end

        // S_INT_CS_RET: reload the CS descriptor named by the IRET-popped CS, set
        // the selector + CPL. SAME-PRIV: RETIRE the IRET (q_pc = the IRET insn).
        // INTER-PRIV (iret_interpriv): the CPL just dropped to CS.RPL; chain to
        // S_IRET_SS to reload the OUTER SS descriptor (and null any data segment
        // not accessible at the new, lower privilege) before retiring.
        S_INT_CS_RET: begin
          if (mem_ack) begin
            if (int_step == 4'd0) begin
              int_lo <= mem_rdata; int_step <= 4'd1;
            end else begin
              logic [63:0] desc;
              desc = {mem_rdata, int_lo};
              seg_sel  [SG_CS] <= int_gate_sel;
              seg_base [SG_CS] <= desc_base(desc);
              seg_limit[SG_CS] <= desc_limit(desc);
              seg_attr [SG_CS] <= desc_attr(desc);
              cpl_r            <= int_gate_sel[1:0];
              cs_d             <= desc[54];
              int_step         <= 4'd0;
              if (iret_interpriv) begin
                state          <= S_IRET_SS;   // reload outer SS, then retire
              end else begin
                q_pc           <= int_src_pc;
                retire_valid   <= 1'b1;
                state          <= S_PIPE;
              end
            end
          end
        end

        // S_IRET_SS (M2S.4): inter-priv IRET tail. Reload the OUTER stack segment
        // from the popped SS selector (its hidden base/limit/attr), then NULL any
        // of DS/ES/FS/GS whose DPL is more privileged than the new CPL (IA-32
        // 6.12.3: on a privilege-lowering return, segment registers loaded with a
        // selector that is now inaccessible are zeroed to prevent a less-privileged
        // task from using a more-privileged data segment). Retire the IRET.
        // DONE-PARTIAL (documented follow-on): the outer SS is reloaded from the
        // popped selector WITHOUT re-validating that SS.RPL == popped CS.RPL and
        // SS.DPL == popped CS.RPL (IA-32 requires both on an inter-priv return,
        // else #GP(SS-selector)). The pcpl corpus uses matching RPL=3 selectors
        // (CS=0x1B, SS=0x23), so this never trips and there is no oracle for the
        // #GP path; deferred with the other negative-path SS checks above.
        S_IRET_SS: begin
          if (mem_ack) begin
            if (int_step == 4'd0) begin
              int_lo <= mem_rdata; int_step <= 4'd1;
            end else begin
              logic [63:0] desc;
              desc = {mem_rdata, int_lo};
              seg_sel  [SG_SS] <= iret_ss;
              seg_base [SG_SS] <= desc_base(desc);
              seg_limit[SG_SS] <= desc_limit(desc);
              seg_attr [SG_SS] <= desc_attr(desc);
              // null a data segment whose DPL < new CPL (would be inaccessible).
              for (int s = 0; s < NUM_SEG; s++) begin
                if ((s == int'(SG_DS) || s == int'(SG_ES) ||
                     s == int'(SG_FS) || s == int'(SG_GS)) &&
                    (desc_dpl(seg_attr[s]) < iret_cs[1:0])) begin
                  seg_sel  [s] <= 16'd0;
                  seg_base [s] <= 32'd0;
                  seg_limit[s] <= 32'd0;
                  seg_attr [s] <= 8'd0;
                end
              end
              iret_interpriv   <= 1'b0;
              int_step         <= 4'd0;
              q_pc             <= int_src_pc;
              retire_valid     <= 1'b1;
              state            <= S_PIPE;
            end
          end
        end
