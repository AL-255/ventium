// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// soc/ven_i8272.sv — Ventium SoC PC peripheral: 82077/8272A floppy controller (M8.9).
//
// The CPU-visible SYNCHRONOUS register surface at I/O 0x3F0-0x3F5 + 0x3F7 (NOT
// 0x3F6 = IDE alt-status): SRA/SRB/DOR/TDR (0x3F1-0x3F3), MSR(read)/DSR(write)
// (0x3F4), the command/result FIFO (0x3F5), DIR(read)/CCR(write) (0x3F7), and the
// command-phase FSM for the DETERMINISTIC, no-disk, no-DMA, no-seek commands.
//
// GROUNDING (authoritative): QEMU 8.2.2 hw/block/fdc.c. The FDC command/result
// FIFO state machine is FULLY SYNCHRONOUS for these commands (no timers/BH), so
// the CPU-observable MSR handshake + result bytes single-step deterministically.
// MSR: 0x80 (RQM, idle/ready) -> 0x90 (RQM|CB, accumulating a multi-byte command)
// -> [handler runs] -> 0xD0 (RQM|DIO|CB, result ready) -> ... -> 0x80. The M8.9
// psocfdc gate proves this byte-identical to qemu-system.
//
// SUPPORTED (synchronous) commands: SENSE INTERRUPT STATUS (0x08, post-reset
// 4-drive polling ST0=0xC0..0xC3), VERSION (0x10->0x90), PART ID (0x18->0x41),
// LOCK (0x14/0x94 -> 0x10/0x00), SPECIFY (0x03+2, no result), CONFIGURE (0x13+3,
// no result), PERPENDICULAR (0x12+1, no result). Any other opcode -> INVALID
// (single result byte 0x80, ST0.INVCMD).
//
// ORACLE BOUNDARY (excluded — needs disk/DMA or async seek timing + IRQ): READ/
// WRITE/FORMAT/READ-ID/RECALIBRATE/SEEK, the DIR media-change bit, motor spin-up.
// The IRQ6 raised on reset-release is wired out (quiescent on the diff: CLI).

`default_nettype none

module ven_i8272 (
    input  wire logic        clk,
    input  wire logic        rst,        // synchronous, ACTIVE-HIGH (PC RESET)
    input  wire logic        cs,         // chip-select: a 0x3F0-0x3F7 FDC port hit
    input  wire logic        we,         // 1 = OUT (CPU write), 0 = IN (CPU read)
    input  wire logic [15:0] addr,       // I/O port (offset = addr[2:0])
    input  wire logic [7:0]  wdata,
    output logic [7:0]       rdata,        // COMBINATIONAL off the registers
    output logic             irq           // FDC -> PIC IR6 (level; reset-release pulse held)
);

  // ---- register state -------------------------------------------------------
  // verilator lint_off PROCASSINIT
  logic [7:0] sra = 8'h00;
  logic [7:0] srb = 8'hC0;
  logic [7:0] dor = 8'h0C;     // nRESET | DMAEN (qemu reset value)
  logic [7:0] tdr = 8'h00;
  logic [7:0] dsr = 8'h00;
  logic [7:0] msr = 8'h80;     // RQM (ready for a command)
  logic [7:0] ccr = 8'h00;
  logic [7:0] dir = 8'h00;
  // verilator lint_on PROCASSINIT
  logic [1:0] cur_drv;
  logic [7:0] config_reg, precomp, perp, lock;
  logic [7:0] status0;          // ST0 base after reset
  logic [2:0] reset_sensei;     // post-reset 4-drive SENSE INTERRUPT poll counter
  logic       intpend;          // an interrupt is pending (cleared by result read)

  // ---- command/result FIFO FSM ---------------------------------------------
  logic [7:0] fifo [0:15];
  logic [3:0] dpos, dlen;       // position + expected length (command or result)
  logic       phase_res;        // 0 = command phase, 1 = result phase
  logic [7:0] cmd_op;           // the command opcode (fifo[0])

  // command total length (number of bytes incl. the opcode) for supported cmds.
  function automatic logic [3:0] cmd_clen(input logic [7:0] op);
    if ((op & 8'h7F) == 8'h14)      cmd_clen = 4'd1;  // LOCK (bit7 = lock flag)
    else case (op)
      8'h08:   cmd_clen = 4'd1;   // SENSE INTERRUPT STATUS
      8'h10:   cmd_clen = 4'd1;   // VERSION
      8'h18:   cmd_clen = 4'd1;   // PART ID
      8'h03:   cmd_clen = 4'd3;   // SPECIFY  (cmd + 2)
      8'h13:   cmd_clen = 4'd4;   // CONFIGURE (cmd + 3)
      8'h12:   cmd_clen = 4'd2;   // PERPENDICULAR (cmd + 1)
      default: cmd_clen = 4'd1;   // INVALID -> immediate 1-byte result
    endcase
  endfunction

  wire [2:0] off = addr[2:0];

  // ---- combinational read ---------------------------------------------------
  always_comb begin
    unique case (off)
      3'd1:    rdata = sra;
      3'd2:    rdata = dor | {6'd0, cur_drv};   // DOR read = dor | cur_drv
      3'd3:    rdata = tdr;
      3'd4:    rdata = msr;
      3'd5:    rdata = phase_res ? fifo[dpos] : 8'h00;   // FIFO result byte
      3'd7:    rdata = dir;
      default: rdata = 8'hFF;     // SRA-aliased / undecoded within window
    endcase
  end

  assign irq = intpend;

  // ---- clocked writes + FIFO FSM + read side effects ------------------------
  // effective command length: on the first byte use the just-written opcode.
  wire [3:0] eff_clen = (dpos == 4'd0) ? cmd_clen(wdata) : dlen;
  wire       cmd_last = (dpos + 4'd1) == eff_clen;     // this write completes the command

  always_ff @(posedge clk) begin
    if (rst) begin
      sra<=8'h00; srb<=8'hC0; dor<=8'h0C; tdr<=8'h00; dsr<=8'h00;
      msr<=8'h80; ccr<=8'h00; dir<=8'h00; cur_drv<=2'd0;
      config_reg<=8'h00; precomp<=8'h00; perp<=8'h00; lock<=8'h00;
      status0<=8'h00; reset_sensei<=3'd0; intpend<=1'b0;
      dpos<=4'd0; dlen<=4'd1; phase_res<=1'b0; cmd_op<=8'h00;
    end else if (cs && we) begin
      // ---------------- CPU OUT ----------------
      unique case (off)
        3'd2: begin // DOR: a 0->1 transition on bit2 (/RESET) runs the controller reset
          if (wdata[2] && !dor[2]) begin
            // fdctrl_reset(do_irq=1): RDYCHG on all drives, RQM ready, 4-drive sensei
            msr<=8'h80; phase_res<=1'b0; dpos<=4'd0; dlen<=4'd1;
            status0<=8'hC0; reset_sensei<=3'd4; intpend<=1'b1;
          end
          dor     <= wdata;
          cur_drv <= wdata[1:0];
        end
        3'd3: tdr <= wdata;
        3'd4: dsr <= wdata;
        3'd7: ccr <= wdata;
        3'd5: if (!phase_res) begin   // FIFO write only valid in command phase
          logic [7:0] op;
          logic [2:0] sidx;
          fifo[dpos] <= wdata;
          if (dpos == 4'd0) begin cmd_op <= wdata; dlen <= cmd_clen(wdata); end
          op   = (dpos == 4'd0) ? wdata : cmd_op;   // the command opcode
          sidx = 3'd4 - reset_sensei;               // post-reset drive poll index 0..3
          if (cmd_last) begin
            // ---- run the command handler synchronously ----
            if ((op & 8'h7F) == 8'h14) begin        // LOCK (0x14/0x94): result = flag<<4
              lock    <= {7'd0, op[7]};
              fifo[0] <= op[7] ? 8'h10 : 8'h00;
              phase_res<=1'b1; dlen<=4'd1; dpos<=4'd0; msr<=8'hD0;
            end else unique case (op)
              8'h08: begin // SENSE INTERRUPT STATUS (post-reset 4-drive polling)
                fifo[0] <= (reset_sensei != 3'd0) ? (8'hC0 | {6'd0, sidx[1:0]})
                          : (intpend ? (status0 | {6'd0, cur_drv}) : 8'h80);
                fifo[1] <= 8'h00;     // PCN (track) = 0
                if (reset_sensei != 3'd0) reset_sensei <= reset_sensei - 3'd1;
                phase_res<=1'b1; dlen<=4'd2; dpos<=4'd0; msr<=8'hD0;
              end
              8'h10:   begin fifo[0]<=8'h90; phase_res<=1'b1; dlen<=4'd1; dpos<=4'd0; msr<=8'hD0; end // VERSION
              8'h18:   begin fifo[0]<=8'h41; phase_res<=1'b1; dlen<=4'd1; dpos<=4'd0; msr<=8'hD0; end // PART ID
              8'h03:   begin phase_res<=1'b0; dlen<=4'd1; dpos<=4'd0; msr<=8'h80; end                 // SPECIFY
              8'h13:   begin config_reg<=fifo[2]; precomp<=wdata; phase_res<=1'b0; dlen<=4'd1; dpos<=4'd0; msr<=8'h80; end // CONFIGURE
              8'h12:   begin if (wdata[7]) perp<={5'd0,wdata[2:0]}; phase_res<=1'b0; dlen<=4'd1; dpos<=4'd0; msr<=8'h80; end // PERPENDICULAR
              default: begin fifo[0]<=8'h80; phase_res<=1'b1; dlen<=4'd1; dpos<=4'd0; msr<=8'hD0; end // INVALID -> ST0.INVCMD
            endcase
          end else begin
            dpos <= dpos + 4'd1;
            msr  <= 8'h90;            // RQM|CB: accumulating a multi-byte command
          end
        end
        default: ; // SRA/SRB read-only ports: writes ignored
      endcase
    end else if (cs && !we) begin
      // ---------------- CPU IN (result-phase side effects) ----------------
      if (off == 3'd5 && phase_res) begin
        if ((dpos + 4'd1) == dlen) begin
          phase_res<=1'b0; dlen<=4'd1; dpos<=4'd0; msr<=8'h80;
          intpend<=1'b0;              // reset_irq: clear pending interrupt
        end else begin
          dpos <= dpos + 4'd1;        // MSR stays 0xD0 (RQM|DIO|CB)
        end
      end
    end
  end

  // lint: srb/dsr/ccr/dir/config/precomp/perp/lock/sra are modelled-but-not-all-read
  // verilator lint_off UNUSED
  wire _unused = &{1'b0, srb, dsr, ccr, config_reg, precomp, perp, lock, sra, tdr};
  // verilator lint_on UNUSED

endmodule : ven_i8272

`default_nettype wire
