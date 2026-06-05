// core/core_tsw.svh — RAW case-arm text `included inside core.sv's always_ff
// `unique case (state)` (R2 modularization). NOT a standalone unit (no module/
// always wrapper); pasted verbatim at the original FSM site, netlist identical.
// Covers the M2S.4b hardware task-switch micro-sequence arms:
//   S_TSW_SAVE / S_TSW_READ / S_TSW_SEG / S_TSW_BUSY.
        // M2S.4b — HARDWARE TASK SWITCH (gated sys_mode; IA-32 SDM Vol.3 §7.3).
        // Reached from S_LJMP when a far JMP targets a 32-bit available/busy TSS.
        // The micro-sequence: SAVE outgoing state -> READ incoming state -> reload
        // incoming segment descriptors -> toggle the GDT busy bits -> COMMIT.
        // The TSS / GDT are linear structures addressed PHYSICALLY under the
        // M2S.1/.2 identity-map convention (paging is off in the ptask corpus), so
        // these accesses are NOT re-translated (excluded in the post-translate).
        // ===================================================================
        // S_TSW_SAVE: write the OUTGOING task state into the CURRENT TSS (tr_base),
        // one dword per beat at the documented 32-bit-TSS offsets. The store data +
        // address are driven by the bus arm; this block only advances the beat and,
        // after the last save, moves to read the incoming state.
        S_TSW_SAVE: begin
          if (mem_ack) begin
            if (tsw_step == 5'd16) begin tsw_step <= 5'd0; state <= S_TSW_READ; end
            else tsw_step <= tsw_step + 5'd1;
          end
        end

        // S_TSW_READ: read the INCOMING task state from the NEW TSS (tsw_new_base)
        // into the tsw_* holding regs. Beats: 0 CR3@0x1C, 1 EIP@0x20, 2 EFLAGS@0x24,
        // 3..10 GPR[0..7]@0x28..0x44, 11..16 ES/CS/SS/DS/FS/GS@0x48..0x5C, 17 LDTR
        // @0x60 (no LDT tracked in this RTL; the read result is discarded).
        S_TSW_READ: begin
          if (mem_ack) begin
            unique case (tsw_step)
              5'd0:  tsw_cr3    <= mem_rdata;
              5'd1:  tsw_eip    <= mem_rdata;
              5'd2:  tsw_eflags <= mem_rdata;
              5'd3,5'd4,5'd5,5'd6,5'd7,5'd8,5'd9,5'd10:
                     tsw_gpr[3'(tsw_step - 5'd3)] <= mem_rdata;
              5'd11: tsw_sel[SG_ES] <= mem_rdata[15:0];
              5'd12: tsw_sel[SG_CS] <= mem_rdata[15:0];
              5'd13: tsw_sel[SG_SS] <= mem_rdata[15:0];
              5'd14: tsw_sel[SG_DS] <= mem_rdata[15:0];
              5'd15: tsw_sel[SG_FS] <= mem_rdata[15:0];
              5'd16: tsw_sel[SG_GS] <= mem_rdata[15:0];
              default: ;   // beat 17 = LDTR (no LDT machinery; discarded)
            endcase
            if (tsw_step == 5'd17) begin tsw_step <= 5'd0; state <= S_TSW_SEG; end
            else tsw_step <= tsw_step + 5'd1;
          end
        end

        // S_TSW_SEG: reload the hidden descriptor (base/limit/attr) of each of the
        // 6 incoming segment selectors from the GDT, exactly like a normal segment
        // load (two 4-byte reads per descriptor). beat = seg_idx*2 + half, segment
        // order CS,SS,DS,ES,FS,GS (the seg_* array order). A null selector (index 0)
        // reads GDT[0] = all-zeros -> a null (base/limit/attr 0) segment. The new
        // selectors are committed here; CPL = the new CS.RPL, cs_d = its D/B bit.
        S_TSW_SEG: begin
          if (mem_ack) begin
            if (!tsw_step[0]) begin
              tsw_seg_lo <= mem_rdata; tsw_step <= tsw_step + 5'd1;
            end else begin
              logic [63:0] desc;
              logic [2:0]  sidx;
              logic [7:0]  sattr;
              desc  = {mem_rdata, tsw_seg_lo};
              sidx  = 3'(tsw_step[4:1]);     // 0..5 = CS,SS,DS,ES,FS,GS
              sattr = desc_attr(desc);
              seg_sel  [sidx] <= tsw_sel[sidx];
              seg_base [sidx] <= desc_base(desc);
              seg_limit[sidx] <= desc_limit(desc);
              seg_attr [sidx] <= sattr;
              if (sidx == 3'(SG_CS)) begin
                cpl_r <= tsw_sel[SG_CS][1:0];  // CPL = new CS.RPL
                cs_d  <= desc[54];              // D/B: 32-bit default op/addr size
              end
              if (tsw_step == 5'd11) begin tsw_step <= 5'd0; state <= S_TSW_BUSY; end
              else tsw_step <= tsw_step + 5'd1;
            end
          end
        end

        // S_TSW_BUSY: toggle the descriptor busy bits in the GDT, then COMMIT the
        // incoming task state + retire ONCE. For a JMP the OUTGOING TSS busy bit is
        // CLEARED (type B->9, beat 0) and the INCOMING one is SET (9->B, beat 1).
        // The busy bytes are written as a single byte (the access byte at descriptor
        // +5) via mem_wstrb in the bus arm. On the final beat: load the incoming
        // EIP/EFLAGS/GPRs/CR3, point TR at the new TSS, set CR0.TS=1 (every task
        // switch sets TS), and retire with q_pc = the JMP's PC (held from S_LJMP).
        // NT / the back-link are NOT touched (a JMP, not a CALL — see deferral).
        S_TSW_BUSY: begin
          if (mem_ack) begin
            if (tsw_step == 5'd0) begin
              tsw_step <= 5'd1;
            end else begin
              // ---- COMMIT the incoming task ----
              eip     <= tsw_eip;
              eflags  <= tsw_eflags;
              for (int g = 0; g < NUM_GPR; g++) gpr[g] <= tsw_gpr[g];
              creg3   <= tsw_cr3;                 // new task CR3 (0 here; paging off)
              creg0   <= creg0 | 32'h0000_0008;   // CR0.TS = 1 on every task switch
              // new TR <- the incoming TSS descriptor (now busy).
              tr_sel  <= tsw_new_sel;
              tr_base <= tsw_new_base;
              tr_limit<= tsw_new_limit;
              tr_attr <= tsw_new_attr;
              tr_valid<= 1'b1;
              tsw_step<= 5'd0;
              // retire the task switch: q_pc still holds the JMP's PC (the golden
              // stamps the switch record at the ljmp). The post-state row is the
              // INCOMING task context (reloaded GPRs/segs/EIP + CR0.TS + new EFLAGS).
              retire_valid <= 1'b1;
              state        <= S_PIPE;
            end
          end
        end
