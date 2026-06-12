// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ============================================================================
// ven_i8042.sv -- Intel 8042 PS/2 keyboard/mouse controller for the Ventium SoC
//                 (M8 PC-peripheral device set).
//
// STANDALONE + SYNTHESIZABLE. Self-contained: no ventium_pkg, no external
// dependency. Built + unit-tested by its OWN harness under verif/soc/.
//
// GROUNDING: register semantics mirror QEMU 8.2.2 hw/input/pckbd.c
// (ventium-refs/.../hw/input/pckbd.c). This models the CPU-OBSERVABLE register
// read/write behavior of the controller: the status register, the controller
// command/data state machine (write_cmd), the controller-sourced output buffer
// (OBF, the "cbdata" path), the mode/command byte, the output port (outport),
// and the A20 / CPU-reset side effects.
//
// PORTS (Ventium SoC common register interface):
//   clk            : clock
//   rst            : SYNCHRONOUS, ACTIVE-HIGH reset (PC RESET)
//   cs             : chip-select (SoC PMIO decoder asserts for ports 0x60/0x64)
//   we             : 1 = OUT (CPU write), 0 = IN (CPU read)
//   addr[15:0]     : I/O port address (only addr[2] differentiates 0x60 vs 0x64:
//                    QEMU's mmio path uses (addr & mask); for ISA PMIO the
//                    decoder picks 0x60 (data) vs 0x64 (cmd/status). We decode
//                    bit2: 0x60 -> bit2=1, 0x64 -> bit2=1 too... so we decode by
//                    the low nibble explicitly: 0x64 has bit2 set & bit0 set;
//                    0x60 has bit2 set & bit0 clear. We use addr[2]&addr[0] for
//                    cmd/status, else data. See `is_cmd_port` below.)
//   wdata[7:0]     : CPU write data
//   rdata[7:0]     : CPU read data -- COMBINATIONAL off the registers
//   irq1           : keyboard IRQ line (IRQ1), level
//   irq12          : mouse IRQ line (IRQ12), level
//   a20_gate       : A20 mask line (1 = A20 enabled / addr bit 20 passes)
//   reset_req      : pulses high for one cycle on a CPU-reset request (0xFE /
//                    0xF0-pulse bit0 low / write-outport bit0=0)
//
// Reads are combinational (rdata = addressed register). Read SIDE EFFECTS
// (kbd_read_data dequeues the OBF + deasserts IRQ) commit on the clocked edge
// when (cs & ~we) hits the data port. Writes commit on the clocked edge when
// (cs & we).
// ============================================================================
`default_nettype none

module ven_i8042 (
    input  wire logic        clk,
    input  wire logic        rst,        // synchronous, active-high
    input  wire logic        cs,
    input  wire logic        we,
    // Common-interface port mandates the full 16-bit I/O address; this device
    // only needs addr[2] to discriminate 0x60 (data) from 0x64 (cmd/status).
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire logic [15:0] addr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire logic [7:0]  wdata,
    output logic [7:0]  rdata,       // combinational

    output logic        irq1,        // keyboard IRQ1
    output logic        irq12,       // mouse IRQ12
    output logic        a20_gate,    // A20 enable (1 = on)
    output logic        reset_req,   // 1-cycle pulse on CPU reset request

    // F3 TB keystroke injection (sim-only; the KV260 build does not instantiate
    // this module). When inj_valid && inj_ready, the scancode enters the output
    // buffer exactly like a controller-sourced byte: OBF sets, IRQ1 asserts via
    // the normal rule, the INT9 read of 0x60 dequeues it. Tie inj_valid=0 for
    // the differential gates (no behavior change).
    input  wire logic        inj_valid,
    input  wire logic [7:0]  inj_data,
    output logic             inj_ready   // OBF clear: a new byte can enter
);

  // --------------------------------------------------------------------------
  // Status register bits (KBD_STAT_*) -- pckbd.c lines 86-103
  // --------------------------------------------------------------------------
  localparam logic [7:0] STAT_OBF       = 8'h01; // output buffer full
  // STAT_IBF (0x02) input-buffer-full: not modeled (no busy/IBF latency here).
  localparam logic [7:0] STAT_SELFTEST  = 8'h04; // system flag (SYS)
  localparam logic [7:0] STAT_CMD       = 8'h08; // last write was command (0=data)
  localparam logic [7:0] STAT_UNLOCKED  = 8'h10; // keyboard unlocked
  localparam logic [7:0] STAT_MOUSE_OBF = 8'h20; // mouse output buffer full

  // --------------------------------------------------------------------------
  // Mode / command-byte bits (KBD_MODE_*) -- pckbd.c lines 105-121
  // --------------------------------------------------------------------------
  localparam logic [7:0] MODE_KBD_INT       = 8'h01; // kbd data -> IRQ1
  localparam logic [7:0] MODE_MOUSE_INT     = 8'h02; // mouse data -> IRQ12
  // MODE_SYS (0x04) system flag: set in the cmd byte but no behavioral effect.
  localparam logic [7:0] MODE_DISABLE_KBD   = 8'h10;
  localparam logic [7:0] MODE_DISABLE_MOUSE = 8'h20;

  // --------------------------------------------------------------------------
  // Output port bits (KBD_OUT_*) -- pckbd.c lines 123-134
  // --------------------------------------------------------------------------
  localparam logic [7:0] OUT_RESET     = 8'h01; // 1=normal, 0=reset
  localparam logic [7:0] OUT_A20       = 8'h02;
  localparam logic [7:0] OUT_OBF       = 8'h10;
  localparam logic [7:0] OUT_MOUSE_OBF = 8'h20;
  localparam logic [7:0] OUT_ONES      = 8'hcc; // default high bits (pckbd.c:134)

  // --------------------------------------------------------------------------
  // Controller commands (KBD_CCMD_*) -- pckbd.c lines 42-84
  // --------------------------------------------------------------------------
  localparam logic [7:0] CMD_READ_MODE     = 8'h20;
  localparam logic [7:0] CMD_WRITE_MODE    = 8'h60;
  // CMD_GET_VERSION (0xA1): not modeled (returns version byte; deferred).
  localparam logic [7:0] CMD_MOUSE_DISABLE = 8'hA7;
  localparam logic [7:0] CMD_MOUSE_ENABLE  = 8'hA8;
  localparam logic [7:0] CMD_TEST_MOUSE    = 8'hA9;
  localparam logic [7:0] CMD_SELF_TEST     = 8'hAA;
  localparam logic [7:0] CMD_KBD_TEST      = 8'hAB;
  localparam logic [7:0] CMD_KBD_DISABLE   = 8'hAD;
  localparam logic [7:0] CMD_KBD_ENABLE    = 8'hAE;
  localparam logic [7:0] CMD_READ_INPORT   = 8'hC0;
  localparam logic [7:0] CMD_READ_OUTPORT  = 8'hD0;
  localparam logic [7:0] CMD_WRITE_OUTPORT = 8'hD1;
  localparam logic [7:0] CMD_WRITE_OBUF    = 8'hD2;
  localparam logic [7:0] CMD_WRITE_AUX_OBUF= 8'hD3;
  localparam logic [7:0] CMD_WRITE_MOUSE   = 8'hD4;
  localparam logic [7:0] CMD_DISABLE_A20   = 8'hDD;
  localparam logic [7:0] CMD_ENABLE_A20    = 8'hDF;
  localparam logic [7:0] CMD_PULSE_3_0     = 8'hF0; // 0xF0-0xFF mask
  localparam logic [7:0] CMD_RESET         = 8'hFE;
  localparam logic [7:0] CMD_NO_OP         = 8'hFF;

  // --------------------------------------------------------------------------
  // Architectural state (mirrors KBDState fields that are CPU-observable)
  // --------------------------------------------------------------------------
  logic [7:0] status;     // status register (read at 0x64)
  logic [7:0] mode;       // mode / command byte
  logic [7:0] outport;    // output port P2
  logic [7:0] write_cmd;  // pending controller command awaiting a 0x60 data byte
                          // (0 = none; otherwise the CMD_* that armed it)
  logic [7:0] cbdata;     // controller-sourced output buffer (the "cbdata" path)
  logic [7:0] obdata;     // last byte handed to the CPU at 0x60

  // --------------------------------------------------------------------------
  // Port decode. The QEMU ISA registration maps the cmd/status register at
  // 0x64 and the data register at 0x60. The SoC decoder asserts `cs` for both;
  // we distinguish them by the address. 0x64 vs 0x60 differ in bit2:
  //   0x60 = 0b0110_0000  -> bit2 = 0  (data port)
  //   0x64 = 0b0110_0100  -> bit2 = 1  (cmd/status port)
  // So `is_cmd_port` = addr[2]. (matches QEMU mmio path's (addr & mask=0x4).)
  // --------------------------------------------------------------------------
  wire is_cmd_port  = addr[2];   // 1 => 0x64 (cmd/status), 0 => 0x60 (data)
  wire is_data_port = ~addr[2];

  // --------------------------------------------------------------------------
  // OBF source classification (subset of QEMU obsrc): the controller queue is
  // the only producer in this standalone model, so OBF is always controller-
  // sourced and never mouse-sourced => STAT_MOUSE_OBF stays 0 here.
  // --------------------------------------------------------------------------

  // --------------------------------------------------------------------------
  // Combinational read (rdata) -- no side effects here.
  //   read 0x64 -> status
  //   read 0x60 -> obdata if OBF set (dequeue happens on the clocked edge);
  //                else the last obdata (QEMU returns s->obdata regardless).
  // QEMU kbd_read_data: if OBF set it refreshes obdata from the source THEN
  // returns it. With the controller queue, the to-be-returned byte == cbdata.
  // --------------------------------------------------------------------------
  always_comb begin
    if (is_cmd_port) begin
      rdata = status;
    end else begin
      // data port
      if ((status & STAT_OBF) != 8'h00) begin
        rdata = cbdata;     // the byte that the clocked dequeue will commit
      end else begin
        rdata = obdata;     // stale last byte (QEMU: s->obdata)
      end
    end
  end

  assign inj_ready = (status & STAT_OBF) == 8'h00;

  // --------------------------------------------------------------------------
  // IRQ line generation (combinational, mirrors kbd_update_irq_lines).
  //   irq_kbd   = OBF & ~MOUSE_OBF & MODE_KBD_INT & ~MODE_DISABLE_KBD
  //   irq_mouse = OBF &  MOUSE_OBF & MODE_MOUSE_INT
  // --------------------------------------------------------------------------
  always_comb begin
    irq1  = 1'b0;
    irq12 = 1'b0;
    if ((status & STAT_OBF) != 8'h00) begin
      if ((status & STAT_MOUSE_OBF) != 8'h00) begin
        if ((mode & MODE_MOUSE_INT) != 8'h00) irq12 = 1'b1;
      end else begin
        if (((mode & MODE_KBD_INT) != 8'h00) &&
            ((mode & MODE_DISABLE_KBD) == 8'h00)) irq1 = 1'b1;
      end
    end
  end

  assign a20_gate = outport[1];  // OUT_A20

  // --------------------------------------------------------------------------
  // Normalize the 0xF0-0xFF "pulse output port bits 3-0" command (pckbd.c
  // lines 329-335): if (val & 0xF0)==0xF0, then bit0 low => treat as RESET,
  // else => NO_OP.
  // --------------------------------------------------------------------------
  function automatic logic [7:0] normalize_cmd(input logic [7:0] v);
    if ((v & CMD_PULSE_3_0) == CMD_PULSE_3_0) begin
      normalize_cmd = (v[0] == 1'b0) ? CMD_RESET : CMD_NO_OP;
    end else begin
      normalize_cmd = v;
    end
  endfunction

  // normalized command for cmd-port writes (combinational)
  wire [7:0] ncmd = normalize_cmd(wdata);

  // --------------------------------------------------------------------------
  // Clocked state machine.
  // --------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    // default: reset_req is a 1-cycle pulse
    reset_req <= 1'b0;

    if (rst) begin
      // kbd_reset(): mode = KBD_INT|MOUSE_INT, status = CMD|UNLOCKED,
      // outport = RESET|A20|ONES, pending cleared, OBF deasserted.
      mode      <= MODE_KBD_INT | MODE_MOUSE_INT;            // 0x03
      status    <= STAT_CMD | STAT_UNLOCKED;                 // 0x18
      outport   <= OUT_RESET | OUT_A20 | OUT_ONES;           // 0xCF
      write_cmd <= 8'h00;
      cbdata    <= 8'h00;
      obdata    <= 8'h00;
    end else if (inj_valid && ((status & STAT_OBF) == 8'h00) && !cs) begin
      // TB keystroke: controller-sourced byte path (kbd scancode -> OBF/IRQ1).
      cbdata <= inj_data;
      status <= (status | STAT_OBF) & ~STAT_MOUSE_OBF;
    end else if (cs && we && is_cmd_port) begin
      // ---------------------------------------------------------------------
      // WRITE to 0x64 (command). status bit3 (CMD) reflects last-write-was-cmd.
      // ---------------------------------------------------------------------
      status <= status | STAT_CMD;
      unique case (ncmd)
        CMD_READ_MODE: begin
          // queue the mode byte to the controller OBF
          cbdata <= mode;
          status <= (status | STAT_CMD | STAT_OBF) & ~STAT_MOUSE_OBF;
          outport <= (outport | OUT_OBF) & ~OUT_MOUSE_OBF;
        end
        CMD_WRITE_MODE,
        CMD_WRITE_OUTPORT,
        CMD_WRITE_OBUF,
        CMD_WRITE_AUX_OBUF,
        CMD_WRITE_MOUSE: begin
          // arm: next 0x60 data byte is consumed per this command
          write_cmd <= ncmd;
        end
        CMD_MOUSE_DISABLE: begin
          mode <= mode | MODE_DISABLE_MOUSE;
        end
        CMD_MOUSE_ENABLE: begin
          mode <= mode & ~MODE_DISABLE_MOUSE;
        end
        CMD_TEST_MOUSE: begin
          cbdata <= 8'h00;
          status <= (status | STAT_CMD | STAT_OBF) & ~STAT_MOUSE_OBF;
          outport <= (outport | OUT_OBF) & ~OUT_MOUSE_OBF;
        end
        CMD_SELF_TEST: begin
          // status |= SYS; queue 0x55
          cbdata <= 8'h55;
          status <= (status | STAT_CMD | STAT_SELFTEST | STAT_OBF) & ~STAT_MOUSE_OBF;
          outport <= (outport | OUT_OBF) & ~OUT_MOUSE_OBF;
        end
        CMD_KBD_TEST: begin
          cbdata <= 8'h00;
          status <= (status | STAT_CMD | STAT_OBF) & ~STAT_MOUSE_OBF;
          outport <= (outport | OUT_OBF) & ~OUT_MOUSE_OBF;
        end
        CMD_KBD_DISABLE: begin
          mode <= mode | MODE_DISABLE_KBD;
        end
        CMD_KBD_ENABLE: begin
          mode <= mode & ~MODE_DISABLE_KBD;
        end
        CMD_READ_INPORT: begin
          cbdata <= 8'h80;
          status <= (status | STAT_CMD | STAT_OBF) & ~STAT_MOUSE_OBF;
          outport <= (outport | OUT_OBF) & ~OUT_MOUSE_OBF;
        end
        CMD_READ_OUTPORT: begin
          cbdata <= outport;
          status <= (status | STAT_CMD | STAT_OBF) & ~STAT_MOUSE_OBF;
          outport <= (outport | OUT_OBF) & ~OUT_MOUSE_OBF;
        end
        CMD_ENABLE_A20: begin
          // a20 raise; outport |= A20
          outport <= outport | OUT_A20;
        end
        CMD_DISABLE_A20: begin
          outport <= outport & ~OUT_A20;
        end
        CMD_RESET: begin
          reset_req <= 1'b1;   // qemu_system_reset_request
        end
        CMD_NO_OP: begin
          // ignore
        end
        default: begin
          // unsupported cmd: QEMU logs guest error, no state change
        end
      endcase
    end else if (cs && we && is_data_port) begin
      // ---------------------------------------------------------------------
      // WRITE to 0x60 (data). status bit3 (CMD) cleared: last write was data.
      // Routed per the armed write_cmd (kbd_write_data).
      // ---------------------------------------------------------------------
      status    <= status & ~STAT_CMD;
      write_cmd <= 8'h00;        // consume the armed command (QEMU: s->write_cmd=0)
      unique case (write_cmd)
        CMD_WRITE_MODE: begin
          mode <= wdata;
          // irq lines recompute combinationally from the new mode
        end
        CMD_WRITE_OBUF: begin
          // kbd_queue(val, 0): controller-sourced OBF
          cbdata <= wdata;
          status <= ((status & ~STAT_CMD) | STAT_OBF) & ~STAT_MOUSE_OBF;
          outport <= (outport | OUT_OBF) & ~OUT_MOUSE_OBF;
        end
        CMD_WRITE_AUX_OBUF: begin
          // kbd_queue(val, 1): mouse-sourced controller OBF
          cbdata <= wdata;
          status <= (status & ~STAT_CMD) | STAT_OBF | STAT_MOUSE_OBF;
          outport <= outport | OUT_OBF | OUT_MOUSE_OBF;
        end
        CMD_WRITE_OUTPORT: begin
          // outport_write(val): set outport, drive A20 from bit1, reset if bit0=0
          outport <= wdata;
          if (wdata[0] == 1'b0) reset_req <= 1'b1;
        end
        CMD_WRITE_MOUSE: begin
          // ps2_write_mouse + reenable: mode &= ~DISABLE_MOUSE.
          // The PS/2 mouse response queue is deferred (minimal model); we
          // model the re-enable side effect only.
          mode <= mode & ~MODE_DISABLE_MOUSE;
        end
        default: begin
          // write_cmd == 0: a byte sent to the keyboard. PS/2 kbd response
          // queue is deferred (minimal model). Re-enables kbd interface.
          mode <= mode & ~MODE_DISABLE_KBD;
        end
      endcase
    end else if (cs && !we && is_data_port) begin
      // ---------------------------------------------------------------------
      // READ side effect at 0x60 (kbd_read_data): if OBF set, dequeue and
      // deassert IRQ -> clear OBF & MOUSE_OBF (status + outport), latch obdata.
      // ---------------------------------------------------------------------
      if ((status & STAT_OBF) != 8'h00) begin
        obdata  <= cbdata;
        status  <= status  & ~(STAT_OBF | STAT_MOUSE_OBF);
        outport <= outport & ~(OUT_OBF | OUT_MOUSE_OBF);
      end
    end
    // read of 0x64 (status): no side effect.
  end

endmodule

`default_nettype wire
