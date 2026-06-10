// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// soc/ven_uart16550.sv — Ventium SoC PC peripheral: NS16550A UART (M8.5).
//
// COM1 at I/O 0x3F8..0x3FF, ISA IRQ4. 8 byte-wide registers, with the DLAB
// (LCR bit7) banking of offsets 0/1 onto the divisor latch:
//
//   off  DLAB=0 read / write     DLAB=1 read / write
//   ---  ---------------------   --------------------
//    0   RBR (rx)  / THR (tx)    DLL (divisor low)
//    1   IER       / IER         DLM (divisor high)
//    2   IIR (r)   / FCR (w)     IIR / FCR        (FCR/IIR are NOT DLAB-banked)
//    3   LCR       / LCR         LCR              (bit7 = DLAB)
//    4   MCR       / MCR
//    5   LSR (r)                 (read-only line status)
//    6   MSR (r)                 (read-only modem status)
//    7   SCR       / SCR         (scratch byte)
//
// GROUNDING (authoritative): QEMU 8.2.2 hw/char/serial.c, mirrored under
//   ventium-refs/07-p5-emulation-harness/build/qemu/hw/char/serial.c
// This module matches the CPU-OBSERVABLE register read/write behaviour of that
// 16550A model (the M8.5 differential-vs-qemu-system SoC gate checks the
// SYNCHRONOUS subset: register round-trips + the reset LSR/IIR values). The
// asynchronous RX-data / loopback / interrupt-delivery paths are an explicit
// oracle boundary — qemu drives them off a host chardev + transmit timer the
// single-step golden cannot reproduce — and are covered by the unit self-check,
// exactly like the 8042 OBF host-queue boundary (see verif/soc).
//
// QEMU reset values (serial_reset): ier=0, iir=NO_INT(0x01), lcr=0,
//   lsr=TEMT|THRE(0x60), msr=DCD|DSR|CTS(0xB0), mcr=OUT2(0x08), scr=0,
//   divider=0x0C (DLL=0x0C, DLM=0x00; 9600 baud @ 115200 base).
// Write masks: IER &= 0x0F; MCR &= 0x1F; LCR/SCR/DLL/DLM/THR full byte.
// IIR top two bits reflect FIFO-enabled (FCR bit0): 0b11 -> 0xC0, else 0.

`default_nettype none

module ven_uart16550 (
    input  wire logic        clk,
    input  wire logic        rst,     // synchronous, ACTIVE-HIGH (PC RESET)
    input  wire logic        cs,      // chip-select: a 0x3F8..0x3FF port hit
    input  wire logic        we,      // 1 = OUT (CPU write), 0 = IN (CPU read)
    input  wire logic [15:0] addr,    // I/O port address (offset = addr[2:0])
    input  wire logic [7:0]  wdata,
    output logic [7:0]       rdata,   // COMBINATIONAL off the registers

    // device-specific I/O seam (for the real board console; INERT in the diff) --
    output logic        irq,          // COM1 -> PIC IR4 (level)
    output logic        tx_valid,     // 1-clk strobe: a byte was written to THR
    output logic [7:0]  tx_data,      // the THR byte (valid with tx_valid)
    input  wire logic        rx_valid, // 1-clk strobe: a received byte is available
    input  wire logic [7:0]  rx_data   // the received byte (latched into RBR)
);

  // ---- CPU-visible register state (QEMU reset values) -----------------------
  // verilator lint_off PROCASSINIT
  logic [7:0] ier = 8'h00;
  logic [7:0] lcr = 8'h00;
  logic [7:0] mcr = 8'h08;   // OUT2
  logic [7:0] lsr = 8'h60;   // TEMT | THRE
  logic [7:0] msr = 8'hB0;   // DCD | DSR | CTS
  logic [7:0] scr = 8'h00;
  logic [7:0] fcr = 8'h00;
  logic [7:0] dll = 8'h0C;   // divisor low  (9600 baud)
  logic [7:0] dlm = 8'h00;   // divisor high
  logic [7:0] rbr = 8'h00;   // receive buffer
  // verilator lint_on PROCASSINIT

  wire        dlab = lcr[7];
  wire [2:0]  off  = addr[2:0];

  // LSR bit positions: [0]=DR data-ready, [5]=THRE, [6]=TEMT.
  // IIR: bit0=1 -> no interrupt pending; bits[7:6]=FIFO enabled (FCR[0]).
  // The transmit path completes instantly in this model (no real baud delay):
  // THRE/TEMT stay 1, so an OUT to THR is observably write-inert (LSR unchanged)
  // unless IER.THRE is set (then the THRE interrupt is the async boundary).
  logic [7:0] iir;
  always_comb begin
    iir = 8'h01;                           // default: no interrupt pending
    // pending sources (priority: RX-line-status > RX-data > THRE > modem),
    // mirroring qemu serial_update_irq. We surface only the ID bits here.
    if (ier[2] && (lsr[1] | lsr[2] | lsr[3] | lsr[4]))      iir = 8'h06; // RX line status
    else if (ier[0] && lsr[0])                              iir = 8'h04; // RX data ready
    else if (ier[1] && lsr[5])                              iir = 8'h02; // THR empty
    else if (ier[3] && |msr[3:0])                           iir = 8'h00; // modem status
    if (fcr[0]) iir[7:6] = 2'b11;          // FIFO-enabled indication
  end

  // level interrupt out = any enabled source active (qemu serial_update_irq).
  assign irq = (ier[0] & lsr[0]) | (ier[1] & lsr[5]) |
               (ier[2] & (lsr[1] | lsr[2] | lsr[3] | lsr[4])) |
               (ier[3] & (|msr[3:0]));

  // ---- combinational read ---------------------------------------------------
  always_comb begin
    unique case (off)
      3'd0: rdata = dlab ? dll : rbr;      // DLL / RBR
      3'd1: rdata = dlab ? dlm : ier;      // DLM / IER
      3'd2: rdata = iir;                   // IIR (read); FCR is write-only
      3'd3: rdata = lcr;
      3'd4: rdata = mcr;
      3'd5: rdata = lsr;
      3'd6: rdata = msr;
      3'd7: rdata = scr;
    endcase
  end

  // ---- writes / RX latch / reads with side effects (clocked) ----------------
  always_ff @(posedge clk) begin
    tx_valid <= 1'b0;                      // 1-clk strobe default

    if (rst) begin
      ier <= 8'h00; lcr <= 8'h00; mcr <= 8'h08; lsr <= 8'h60;
      msr <= 8'hB0; scr <= 8'h00; fcr <= 8'h00; dll <= 8'h0C;
      dlm <= 8'h00; rbr <= 8'h00;
    end else begin
      // asynchronous receive: a delivered byte lands in RBR and raises LSR.DR
      // (the board/PS RX seam; never pulsed during the synchronous diff).
      if (rx_valid) begin
        rbr    <= rx_data;
        lsr[0] <= 1'b1;                     // DR = data ready
      end

      if (cs && we) begin
        // ---- CPU OUT -----------------------------------------------------
        unique case (off)
          3'd0: if (dlab) dll <= wdata;
                else begin
                  tx_data  <= wdata;        // THR: transmit (instant in model)
                  tx_valid <= 1'b1;
                end
          3'd1: if (dlab) dlm <= wdata;
                else      ier <= wdata & 8'h0F;
          3'd2: fcr <= wdata;               // FCR (FIFO control)
          3'd3: lcr <= wdata;
          3'd4: mcr <= wdata & 8'h1F;
          3'd5: ;                            // LSR read-only
          3'd6: ;                            // MSR read-only
          3'd7: scr <= wdata;
        endcase
      end else if (cs && !we) begin
        // ---- CPU IN (read side effects) ----------------------------------
        // Reading RBR clears DR; reading LSR clears the error/break bits (none
        // set on the diff path); reading MSR clears the delta bits (low nibble).
        if (off == 3'd0 && !dlab) lsr[0]   <= 1'b0;
        if (off == 3'd5)          lsr[4:1] <= 4'b0000;
        if (off == 3'd6)          msr[3:0] <= 4'b0000;
      end
    end
  end

endmodule : ven_uart16550

`default_nettype wire
