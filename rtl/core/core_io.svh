// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

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
            // REVIEW2 M-03: the A20 gate control latch. Port 0x92 ("fast A20" /
            // System Control Port A) bit 1: 1 = A20 enabled, 0 = A20 forced low so
            // physical addresses wrap at 1 MiB. Bit 0 is FAST RESET and is ignored
            // here.
            //
            // WHY THE LATCH IS IN THE CORE. On real silicon this is a chipset
            // register, and it was first written in ventium_top. That does not work:
            // the port-0x92 OUT is serviced by the PS in one build, by a co-sim DPI
            // hook in another and by in-PL devices in a third, and the top-level
            // io_req/io_ack handshake is not observable at a clock edge in all of
            // them -- an instrumented probe there never fired once. The core's own
            // S_IO arm is the ONE place that sees every completed I/O write in every
            // configuration, because it is the same condition the core already uses
            // to retire the OUT. ventium_top keeps an `a20_gate` PLATFORM OVERRIDE
            // input (ANDed with this latch) so a real chipset can still force A20 low.
            //
            // The write is observed, NOT intercepted: the OUT still goes out on the
            // I/O bus exactly as before, so whatever already services 0x92 is
            // unaffected.
            if (q_io_write && q_io_port == 16'h0092) a20_r <= io_wdata[1];
            // ---- REVIEW1_Aug2 H-10: the KEYBOARD-CONTROLLER A20 path ---------------
            // Port 0x92 is the "fast" A20. The CLASSIC route -- which is what real BIOS
            // and DOS use, and what HIMEM.SYS falls back to -- goes through the 8042:
            //     OUT 0x64, 0xD1     command: write the output port
            //     OUT 0x60, <data>   bit 1 of <data> is A20
            // Nothing in this design connected that to the gate. ventium_top ties its
            // a20_gate override high and the SoC modules that would decode 0x60/0x64
            // are not in this checkout, so the classic sequence changed NOTHING and the
            // address mask stayed put.
            //
            // Handled HERE for exactly the reason the port-0x92 latch is (see above):
            // the core's S_IO arm is the one place that observes every completed I/O
            // write in every configuration. Two-step, because the data byte's meaning
            // depends on the command that preceded it -- kbc_d1_armed is set by the
            // 0xD1 command and consumed by the next write to 0x60.
            //
            // Observed, not intercepted: both OUTs still go out on the I/O bus, so
            // whatever services the 8042 is unaffected.
            if (q_io_write && q_io_port == 16'h0064)
              // 0xD1 arms the output-port write; ANY other command cancels it, so an
              // unrelated 8042 command cannot leave the core primed to misread the
              // next 0x60 data byte as an A20 update.
              kbc_d1_armed <= (io_wdata[7:0] == 8'hD1);
            if (q_io_write && q_io_port == 16'h0060 && kbc_d1_armed) begin
              a20_r        <= io_wdata[1];
              kbc_d1_armed <= 1'b0;
            end
            // OUTS (K_STR ST_OUTS, routed here per element): retire with the string
            // loop EIP latched in S_EXEC (q_pc while REP has elements left, next_eip
            // on the last), exactly like the S_STORE string retire. Plain IN/OUT
            // keeps next_eip.
            io_eip = (q_kind==K_STR) ? str_next_eip : next_eip;
            // R3: the IN value -> AL/AX/eAX write moved to the gpr writeback driver
            // (core_gpr_wb.svh, S_IO arm).
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
          cx = gpr_o[R_ECX];
          rep_active = (q_rep || q_repne);
          // F3: a16 REP INS counts in CX (low 16) — see the K_STR arm.
          if (rep_active && (q_cnt16 ? (cx[15:0]==16'd0) : (cx==32'd0))) begin
            // Degenerate REP INS with ECX==0: no port read, no store — advance EIP
            // and retire one no-op record (matches qemu's degenerate-REP record).
            eip <= next_eip;
            if (sys_mode && tf_at_issue) arm_db(32'd1 << DR6_BS, q_pc, next_eip);
            else begin retire_valid <= 1'b1; state <= S_PIPE; end
          end else if (io_ack) begin
            // Capture the IN value, set up THIS element's store + pointer/count
            // update, then go to S_STORE (str_store_addr/data latched below).
            ins_data <= wmask(io_rdata, q_io_w);   // width-masked device value
            // R3: the EDI += width and ECX -= 1 (REP) writes moved to the gpr
            // writeback driver (core_gpr_wb.svh, S_INS arm). dec_cx is the
            // SHARED post-decrement ECX (core.sv); the FSM uses it for last_iter /
            // str_next_eip, the driver writes it to ECX.
            if (rep_active) begin
              cx = dec_cx;
              last_iter = q_cnt16 ? (cx[15:0]==16'd0) : (cx==32'd0);
              str_next_eip <= last_iter ? next_eip : q_pc;  // loop at q_pc if more
            end else begin
              str_next_eip <= next_eip;            // non-REP: single element
            end
            str_store_addr <= str_edi;             // pre-increment [DI] (a16-masked)
            str_store_data <= wmask(io_rdata, q_io_w);
            state <= S_STORE;
          end
        end
