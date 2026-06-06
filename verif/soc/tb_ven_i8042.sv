// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ============================================================================
// tb_ven_i8042.sv -- directed UNIT self-check for the Ventium SoC i8042 device.
//
// Drives the common register interface (cs/we/addr/wdata/rdata + irq1/irq12/
// a20_gate/reset_req) through the DOCUMENTED QEMU 8.2.2 hw/input/pckbd.c
// sequences and asserts the CPU-OBSERVABLE results match the spec.
//
// This is a UNIT-level self-check vs the documented behavior (NOT yet
// differential-vs-qemu-system; that comes at SoC integration). Each `check`
// records PASS/FAIL with the observed vs expected value.
//
// Run with Verilator: verilator --binary --timing (see Makefile / run.sh).
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_ven_i8042;

  // ---- ports of 0x60 / 0x64 (low byte; high byte irrelevant to the device)
  localparam logic [15:0] PORT_DATA = 16'h0060;
  localparam logic [15:0] PORT_CMD  = 16'h0064;

  // ---- DUT I/O ------------------------------------------------------------
  logic        clk = 1'b0;
  logic        rst;
  logic        cs, we;
  logic [15:0] addr;
  logic [7:0]  wdata;
  logic [7:0]  rdata;
  logic        irq1, irq12, a20_gate, reset_req;

  always #5 clk = ~clk;  // 100 MHz

  ven_i8042 dut (
    .clk(clk), .rst(rst), .cs(cs), .we(we), .addr(addr), .wdata(wdata),
    .rdata(rdata), .irq1(irq1), .irq12(irq12),
    .a20_gate(a20_gate), .reset_req(reset_req)
  );

  // ---- scoreboard ---------------------------------------------------------
  int pass_cnt = 0;
  int fail_cnt = 0;

  task automatic check(input string name, input logic [31:0] got,
                       input logic [31:0] exp);
    if (got === exp) begin
      pass_cnt++;
      $display("  PASS  %-44s got=0x%02h", name, got[7:0]);
    end else begin
      fail_cnt++;
      $display("  FAIL  %-44s got=0x%02h exp=0x%02h", name, got[7:0], exp[7:0]);
    end
  endtask

  task automatic check_bit(input string name, input logic got, input logic exp);
    if (got === exp) begin
      pass_cnt++;
      $display("  PASS  %-44s got=%0b", name, got);
    end else begin
      fail_cnt++;
      $display("  FAIL  %-44s got=%0b exp=%0b", name, got, exp);
    end
  endtask

  // ---- bus driver primitives (synchronous: commit on the posedge) ---------
  // IO_WRITE: assert cs/we/addr/wdata across one rising edge, then idle.
  task automatic io_write(input logic [15:0] a, input logic [7:0] d);
    @(negedge clk);
    cs = 1'b1; we = 1'b1; addr = a; wdata = d;
    @(negedge clk);            // the posedge in between commits the write
    cs = 1'b0; we = 1'b0; addr = '0; wdata = '0;
  endtask

  // IO_READ_RAW: combinational rdata is valid while cs&~we are asserted; the
  // read side-effect (data-port dequeue) commits on the enclosed posedge.
  // Returns the combinational rdata sampled while cs is asserted (pre-edge),
  // i.e. the value the CPU latches this access -- matching QEMU's
  // read-returns-current-buffer-then-applies-dequeue ordering.
  task automatic io_read(input logic [15:0] a, output logic [7:0] d);
    @(negedge clk);
    cs = 1'b1; we = 1'b0; addr = a;
    #1;                        // let combinational rdata settle
    d = rdata;                 // CPU latches this (combinational off regs)
    @(negedge clk);            // the posedge in between applies read side-effect
    cs = 1'b0; addr = '0;
  endtask

  // Read status (0x64) -- no side effect, can sample combinationally any time.
  task automatic rd_status(output logic [7:0] d);
    io_read(PORT_CMD, d);
  endtask

  task automatic do_reset();
    rst = 1'b1; cs = 1'b0; we = 1'b0; addr = '0; wdata = '0;
    @(negedge clk); @(negedge clk);
    rst = 1'b0;
    @(negedge clk);
  endtask

  // ---- expected constants (mirror pckbd.c) --------------------------------
  localparam logic [7:0] STAT_OBF      = 8'h01;
  localparam logic [7:0] STAT_SYS      = 8'h04;
  localparam logic [7:0] STAT_CMD      = 8'h08;
  localparam logic [7:0] STAT_UNLOCKED = 8'h10;
  localparam logic [7:0] STAT_MOBF     = 8'h20;
  localparam logic [7:0] RESET_STATUS  = STAT_CMD | STAT_UNLOCKED;       // 0x18
  localparam logic [7:0] RESET_MODE    = 8'h03;                          // KBD|MOUSE INT
  localparam logic [7:0] RESET_OUTPORT = 8'h01 | 8'h02 | 8'hCC;          // 0xCF

  logic [7:0] d, st;

  initial begin
    $display("=== tb_ven_i8042: directed unit self-check vs QEMU pckbd.c ===");

    // ====================================================================
    // 1. RESET STATE  (kbd_reset)
    // ====================================================================
    do_reset();
    rd_status(st);
    check("reset: status == CMD|UNLOCKED (0x18)", st, RESET_STATUS);
    check_bit("reset: a20_gate asserted (outport A20)", a20_gate, 1'b1);
    check_bit("reset: irq1 deasserted (OBF clear)", irq1, 1'b0);
    check_bit("reset: irq12 deasserted", irq12, 1'b0);

    // ====================================================================
    // 2. READ MODE BYTE (0x20): queues mode (0x03) to OBF
    // ====================================================================
    io_write(PORT_CMD, 8'h20);
    rd_status(st);
    check("read-mode: status OBF set", st & STAT_OBF, STAT_OBF);
    check("read-mode: status MOUSE_OBF clear", st & STAT_MOBF, 8'h00);
    check_bit("read-mode: irq1 raised (OBF & KBD_INT)", irq1, 1'b1);
    io_read(PORT_DATA, d);
    check("read-mode: 0x60 returns mode 0x03", d, RESET_MODE);
    rd_status(st);
    check("read-mode: OBF cleared after data read", st & STAT_OBF, 8'h00);
    check_bit("read-mode: irq1 deasserted after read", irq1, 1'b0);

    // ====================================================================
    // 3. SELF-TEST (0xAA): status|=SYS, queue 0x55
    // ====================================================================
    do_reset();
    io_write(PORT_CMD, 8'hAA);
    rd_status(st);
    check("self-test: status SYS set", st & STAT_SYS, STAT_SYS);
    check("self-test: status OBF set", st & STAT_OBF, STAT_OBF);
    io_read(PORT_DATA, d);
    check("self-test: 0x60 returns 0x55", d, 8'h55);
    rd_status(st);
    check("self-test: SYS sticky after read", st & STAT_SYS, STAT_SYS);
    check("self-test: OBF cleared after read", st & STAT_OBF, 8'h00);

    // ====================================================================
    // 4. KBD INTERFACE TEST (0xAB): queue 0x00
    // ====================================================================
    do_reset();
    io_write(PORT_CMD, 8'hAB);
    io_read(PORT_DATA, d);
    check("kbd-iface-test: 0x60 returns 0x00", d, 8'h00);

    // ====================================================================
    // 5. WRITE COMMAND BYTE (0x60 cmd): next 0x60 data sets mode.
    //    Write mode = 0x01 (KBD_INT only) then read it back via 0x20.
    // ====================================================================
    do_reset();
    io_write(PORT_CMD, 8'h60);        // arm write-cmd-byte
    io_write(PORT_DATA, 8'h01);       // mode := 0x01 (KBD_INT, no MOUSE_INT)
    io_write(PORT_CMD, 8'h20);        // read mode back
    io_read(PORT_DATA, d);
    check("write-cmd-byte: mode read back == 0x01", d, 8'h01);

    // ====================================================================
    // 6. DISABLE / ENABLE KBD (0xAD / 0xAE): gates IRQ1.
    //    With kbd disabled, even with OBF+KBD_INT, irq1 must stay low.
    // ====================================================================
    do_reset();
    io_write(PORT_CMD, 8'hAD);        // disable kbd interface (mode |= 0x10)
    io_write(PORT_CMD, 8'h20);        // queue mode -> OBF
    rd_status(st);
    check("kbd-disable: OBF set", st & STAT_OBF, STAT_OBF);
    check_bit("kbd-disable: irq1 suppressed", irq1, 1'b0);
    io_read(PORT_DATA, d);            // drain
    io_write(PORT_CMD, 8'hAE);        // re-enable kbd interface
    io_write(PORT_CMD, 8'h20);        // queue mode -> OBF again
    check_bit("kbd-enable: irq1 raised again", irq1, 1'b1);
    io_read(PORT_DATA, d);            // drain

    // ====================================================================
    // 7. READ OUTPORT (0xD0): queues outport (reset default = 0xCF, but
    //    after queueing OBF the outport also gets OUT_OBF=0x10 set, so the
    //    queued snapshot is 0xCF | 0x10 = 0xDF). QEMU sets OBF in the SAME
    //    kbd_update_irq pass, but kbd_queue snapshots outport BEFORE OBF is
    //    re-applied... Actually QEMU queues s->outport (current) THEN
    //    kbd_update_irq sets OUT_OBF. The CPU-observed dequeued byte is the
    //    pre-OBF outport snapshot = 0xCF.
    // ====================================================================
    do_reset();
    io_write(PORT_CMD, 8'hD0);        // read outport -> queue it
    io_read(PORT_DATA, d);
    check("read-outport: 0x60 returns 0xCF (RESET|A20|ONES)", d, RESET_OUTPORT);

    // ====================================================================
    // 8. A20 OFF / ON (0xDD / 0xDF): toggles outport bit1 -> a20_gate.
    // ====================================================================
    do_reset();
    check_bit("a20: default on after reset", a20_gate, 1'b1);
    io_write(PORT_CMD, 8'hDD);        // disable A20
    check_bit("a20: 0xDD turns A20 off", a20_gate, 1'b0);
    io_write(PORT_CMD, 8'hDF);        // enable A20
    check_bit("a20: 0xDF turns A20 on", a20_gate, 1'b1);

    // ====================================================================
    // 9. WRITE OUTPORT (0xD1): next 0x60 -> outport. bit1->A20, bit0=0->reset.
    //    9a: write 0xDD (bit1=0 -> A20 off, bit0=1 -> no reset)
    //    9b: write 0xFE (bit0=0 -> reset_req pulse, bit1=1 -> A20 on)
    // ====================================================================
    do_reset();
    io_write(PORT_CMD, 8'hD1);        // arm write-outport
    io_write(PORT_DATA, 8'h0D);       // bit1=0 (A20 off), bit0=1 (no reset)
    check_bit("write-outport 0x0D: A20 off", a20_gate, 1'b0);

    do_reset();
    io_write(PORT_CMD, 8'hD1);        // arm write-outport
    // 9b: drive 0x02 (bit1=1 A20 on, bit0=0 -> reset). Watch reset_req pulse.
    fork
      io_write(PORT_DATA, 8'h02);
      begin : watch_rst
        logic saw_rst;
        saw_rst = 1'b0;
        repeat (3) begin
          @(posedge clk);
          if (reset_req) saw_rst = 1'b1;
        end
        check_bit("write-outport bit0=0: reset_req pulsed", saw_rst, 1'b1);
      end
    join
    check_bit("write-outport 0x02: A20 on", a20_gate, 1'b1);

    // ====================================================================
    // 10. CPU RESET PULSE (0xFE): one-cycle reset_req.
    // ====================================================================
    do_reset();
    fork
      io_write(PORT_CMD, 8'hFE);
      begin : watch_fe
        logic saw_rst;
        saw_rst = 1'b0;
        repeat (3) begin
          @(posedge clk);
          if (reset_req) saw_rst = 1'b1;
        end
        check_bit("cmd 0xFE: reset_req pulsed", saw_rst, 1'b1);
      end
    join

    // ====================================================================
    // 11. PULSE-OUTPUT (0xF0-0xFF): bit0 low => reset, bit0 high => no-op.
    //     0xFF = no-op (no reset). 0xF0 has bit0=0 => reset.
    // ====================================================================
    do_reset();
    fork
      io_write(PORT_CMD, 8'hFF);      // NO_OP: must NOT reset
      begin : watch_ff
        logic saw_rst;
        saw_rst = 1'b0;
        repeat (3) begin
          @(posedge clk);
          if (reset_req) saw_rst = 1'b1;
        end
        check_bit("cmd 0xFF (no-op): NO reset", saw_rst, 1'b0);
      end
    join

    do_reset();
    fork
      io_write(PORT_CMD, 8'hF0);      // pulse bits 3-0, bit0=0 => reset
      begin : watch_f0
        logic saw_rst;
        saw_rst = 1'b0;
        repeat (3) begin
          @(posedge clk);
          if (reset_req) saw_rst = 1'b1;
        end
        check_bit("cmd 0xF0 (bit0=0): reset_req pulsed", saw_rst, 1'b1);
      end
    join

    // ====================================================================
    // 12. STATUS CMD/DATA bit (0x08): set on cmd write, clear on data write.
    // ====================================================================
    do_reset();
    io_write(PORT_CMD, 8'hAD);        // a command write
    rd_status(st);
    check("status: CMD bit set after 0x64 write", st & STAT_CMD, STAT_CMD);
    io_write(PORT_CMD, 8'h60);        // arm write-cmd-byte
    io_write(PORT_DATA, 8'h03);       // a data write -> clears CMD bit, mode=0x03
    rd_status(st);
    check("status: CMD bit clear after 0x60 write", st & STAT_CMD, 8'h00);

    // ====================================================================
    // 13. READ DATA with OBF CLEAR returns stale obdata, no underflow.
    // ====================================================================
    do_reset();
    io_read(PORT_DATA, d);            // OBF clear at reset -> returns obdata(0)
    check("read 0x60 with OBF clear: returns 0x00", d, 8'h00);
    rd_status(st);
    check("read 0x60 OBF-clear: status unchanged", st, RESET_STATUS);

    // ====================================================================
    // 14. WRITE-OBUF (0xD2): inject a byte into the kbd OBF (kbd-sourced).
    // ====================================================================
    do_reset();
    io_write(PORT_CMD, 8'hD2);        // arm write-obuf
    io_write(PORT_DATA, 8'hAB);       // queue 0xAB as kbd OBF
    rd_status(st);
    check("write-obuf: OBF set", st & STAT_OBF, STAT_OBF);
    check("write-obuf: MOUSE_OBF clear (kbd-sourced)", st & STAT_MOBF, 8'h00);
    check_bit("write-obuf: irq1 raised", irq1, 1'b1);
    io_read(PORT_DATA, d);
    check("write-obuf: 0x60 returns 0xAB", d, 8'hAB);

    // ====================================================================
    // 15. WRITE-AUX-OBUF (0xD3): mouse-sourced OBF -> MOUSE_OBF + irq12.
    // ====================================================================
    do_reset();
    io_write(PORT_CMD, 8'hD3);        // arm write-aux-obuf
    io_write(PORT_DATA, 8'h5A);       // queue 0x5A as mouse OBF
    rd_status(st);
    check("write-aux-obuf: OBF set", st & STAT_OBF, STAT_OBF);
    check("write-aux-obuf: MOUSE_OBF set", st & STAT_MOBF, STAT_MOBF);
    check_bit("write-aux-obuf: irq12 raised (MOUSE_INT)", irq12, 1'b1);
    check_bit("write-aux-obuf: irq1 NOT raised", irq1, 1'b0);
    io_read(PORT_DATA, d);
    check("write-aux-obuf: 0x60 returns 0x5A", d, 8'h5A);
    rd_status(st);
    check("write-aux-obuf: MOUSE_OBF cleared after read", st & STAT_MOBF, 8'h00);

    // ====================================================================
    // SUMMARY
    // ====================================================================
    $display("=== tb_ven_i8042: %0d PASS, %0d FAIL ===", pass_cnt, fail_cnt);
    if (fail_cnt == 0) begin
      $display("RESULT: ALL CHECKS PASSED");
      $finish;
    end else begin
      $display("RESULT: FAILURES PRESENT");
      $fatal(1, "tb_ven_i8042: %0d check(s) failed", fail_cnt);
    end
  end

  // global watchdog
  initial begin
    #100000;
    $fatal(1, "tb_ven_i8042: TIMEOUT");
  end

endmodule

`default_nettype wire
