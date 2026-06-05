// core/core_io.svh — RAW case-arm text `included inside core.sv's always_ff
// `unique case (state)` (R2 modularization). NOT a standalone unit (no module/
// always wrapper); pasted verbatim at the original FSM site, netlist identical.
// Covers the M7.3 port-I/O arms:
//   S_IO (IN/OUT bus handshake under cosim), S_INS (INS string-in).
        // -------------------------------------------------------------------
        // M7.3b PORT I/O — the IN/OUT bus handshake (entered only under cosim_en).
        // Single-beat, combinational-OK ack (mirrors the mem bus). On io_ack:
        //   * IN  (q_io_write=0): write the io_rdata VALUE the TB replayed from the
        //     golden dev_in into AL/AX/eAX, width-aware via reg_merge. This is the
        //     sole environment injection — no CPU register/flag/eip is fabricated.
        //   * OUT (q_io_write=1): nothing to write back; the value already went out
        //     combinationally on io_wdata. (The TB's cosim isa-debug-exit `out 0xf4`
        //     stops the run there.)
        // Then advance EIP past the IN/OUT and RETIRE one record (so the RTL trace
        // carries the row compare_stream.py grades against the golden). IN/OUT do
        // NOT touch EFLAGS. #DB checks mirror the normal retire path for fidelity.
        // -------------------------------------------------------------------
        S_IO: begin
          if (io_ack) begin
            logic [31:0] io_eip;
            logic [3:0]  io_xbp;
            io_eip = next_eip;
            if (!q_io_write)
              gpr[R_EAX] <= reg_merge(gpr[R_EAX], wmask(io_rdata, q_io_w), q_io_w, 1'b0);
            eip <= io_eip;
            io_xbp = (sys_mode && !rf_at_issue) ? dr_match(seg_base[SG_CS]+io_eip, 1'b1)
                                                : 4'd0;
            if (sys_mode && io_xbp != 4'd0)
              arm_db({28'd0, io_xbp}, q_pc, io_eip);     // instr breakpoint at next eip
            else if (sys_mode && tf_at_issue)
              arm_db(32'd1 << DR6_BS, q_pc, io_eip);     // TF single-step trap
            else begin
              retire_valid <= 1'b1;
              state <= S_PIPE;
            end
          end
        end

        // -------------------------------------------------------------------
        // M7.3c INS (port-input string) — per-element IN handshake (cosim only).
        // Each element: IN a byte/word/dword from port DX (the co-sim replays the
        // recorded dev_in value on io_rdata), then STORE it to ES:[EDI] via the
        // existing K_STR S_STORE path (which advances EIP / loops on the REP). The
        // string bookkeeping (EDI += step, ECX -= 1 under REP, last-iter EIP) is set
        // up HERE, mirroring the K_STR S_EXEC element arm, so S_STORE just writes
        // str_store_data to [EDI] and retires/loops exactly as MOVS/STOS do. INS
        // touches NO flags. The IN value is the ONLY injected environment.
        S_INS: begin
          logic [31:0] cx;
          logic        rep_active, last_iter;
          cx = gpr[R_ECX];
          rep_active = (q_rep || q_repne);
          if (rep_active && cx==32'd0) begin
            // Degenerate REP INS with ECX==0: no port read, no store — advance EIP
            // and retire one no-op record (matches qemu's degenerate-REP record).
            eip <= next_eip;
            if (sys_mode && tf_at_issue) arm_db(32'd1 << DR6_BS, q_pc, next_eip);
            else begin retire_valid <= 1'b1; state <= S_PIPE; end
          end else if (io_ack) begin
            // Capture the IN value, set up THIS element's store + pointer/count
            // update, then go to S_STORE (str_store_addr/data latched below).
            ins_data <= wmask(io_rdata, q_io_w);   // width-masked device value
            gpr[R_EDI] <= gpr[R_EDI] + str_step;   // EDI += width (DF direction)
            if (rep_active) begin
              cx = cx - 32'd1;
              gpr[R_ECX] <= cx;
              last_iter = (cx==32'd0);
              str_next_eip <= last_iter ? next_eip : q_pc;  // loop at q_pc if more
            end else begin
              str_next_eip <= next_eip;            // non-REP: single element
            end
            str_store_addr <= gpr[R_EDI];          // pre-increment [EDI]
            str_store_data <= wmask(io_rdata, q_io_w);
            state <= S_STORE;
          end
        end
