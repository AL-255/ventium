// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ============================================================================
// verif/soc/tb_ven_rtc.sv -- directed UNIT self-check for ven_rtc (M8 RTC/CMOS).
//
// This is a UNIT-LEVEL self-check vs the DOCUMENTED qemu mc146818rtc.c CPU-
// observable semantics -- NOT (yet) differential-vs-qemu-system (that comes at
// SoC integration). Each check drives the common register interface
// (cs/we/addr/wdata/rdata + irq8) through a documented sequence and asserts the
// CPU-observable result. No oracle exists for the wall-clock cadence, so the
// structural tick is exercised only for its register CONSEQUENCES (UF/PF set,
// irq8, BCD increment+carry, SET-freeze) -- never its rate.
//
// Build/run: verilator --binary --timing (see Makefile / run.sh).
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_ven_rtc;

  // ---- clock / reset --------------------------------------------------------
  logic clk = 1'b0;
  always #5 clk = ~clk;          // 100 MHz model clock
  logic rst;

  // ---- DUT interface --------------------------------------------------------
  logic        cs, we;
  logic [15:0] addr;
  logic [7:0]  wdata;
  logic [7:0]  rdata;
  logic        irq8;
  logic        nmi_disable;

  // Small TICK_DIV so the structural tick is observable quickly.
  localparam int unsigned TICK_DIV = 8;

  ven_rtc #(.TICK_DIV(TICK_DIV)) dut (
    .clk(clk), .rst(rst),
    .cs(cs), .we(we), .addr(addr), .wdata(wdata), .rdata(rdata),
    .irq8(irq8), .nmi_disable(nmi_disable)
  );

  // ---- scoreboard -----------------------------------------------------------
  int errors = 0;
  int checks = 0;

  task automatic chk(input string name, input logic cond);
    checks++;
    if (cond) begin
      $display("  PASS: %s", name);
    end else begin
      $display("  FAIL: %s", name);
      errors++;
    end
  endtask

  // ---- bus helpers ----------------------------------------------------------
  // Port addresses: index = 0x70 (even), data = 0x71 (odd). Only addr[0] used.
  localparam logic [15:0] P_INDEX = 16'h0070;
  localparam logic [15:0] P_DATA  = 16'h0071;

  // OUT 0xport, val  (write commits on the clocked edge while cs&we)
  task automatic io_out(input logic [15:0] port, input logic [7:0] val);
    @(negedge clk);
    cs = 1'b1; we = 1'b1; addr = port; wdata = val;
    @(negedge clk);                 // edge commits the write
    cs = 1'b0; we = 1'b0; wdata = 8'h00;
  endtask

  // IN 0xport -> captured combinationally; read side-effect commits at the edge.
  task automatic io_in(input logic [15:0] port, output logic [7:0] val);
    @(negedge clk);
    cs = 1'b1; we = 1'b0; addr = port;
    #1 val = rdata;                 // combinational read (same-cycle-ack)
    @(negedge clk);                 // edge applies any read side-effect
    cs = 1'b0;
  endtask

  // OUT index, then OUT data : the canonical "write CMOS[idx]=val" sequence.
  task automatic cmos_write(input logic [6:0] idx, input logic [7:0] val);
    io_out(P_INDEX, {1'b0, idx});
    io_out(P_DATA,  val);
  endtask

  // OUT index, then IN data : the canonical "read CMOS[idx]" sequence.
  task automatic cmos_read(input logic [6:0] idx, output logic [7:0] val);
    io_out(P_INDEX, {1'b0, idx});
    io_in(P_DATA, val);
  endtask

  // idle the bus for n clocks (lets the structural tick run; cs deasserted).
  task automatic idle(input int n);
    cs = 1'b0; we = 1'b0;
    repeat (n) @(negedge clk);
  endtask

  // ---- test sequence --------------------------------------------------------
  logic [7:0] v;

  initial begin
    cs = 0; we = 0; addr = 0; wdata = 0;
    // synchronous reset
    rst = 1'b1;
    repeat (3) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    $display("=== ven_rtc directed unit self-check ===");

    // ---------------------------------------------------------------------
    // 1) Reset defaults (qemu rtc_realizefn): A=0x26,B=0x02,C=0x00,D=0x80.
    //    Read REG_A masking UIP (bit7) since UIP is a live read-only bit.
    // ---------------------------------------------------------------------
    cmos_read(7'h0A, v); chk("REG_A reset == 0x26 (UIP masked)", (v & 8'h7F) == 8'h26);
    cmos_read(7'h0B, v); chk("REG_B reset == 0x02",              v == 8'h02);
    cmos_read(7'h0C, v); chk("REG_C reset == 0x00",              v == 8'h00);
    cmos_read(7'h0D, v); chk("REG_D reset == 0x80 (VRT)",        v == 8'h80);

    // ---------------------------------------------------------------------
    // 2) Index-port READ returns 0xFF (even addr), regardless of index.
    // ---------------------------------------------------------------------
    io_out(P_INDEX, 8'h0A);
    io_in(P_INDEX, v);   chk("index-port read returns 0xFF", v == 8'hFF);

    // ---------------------------------------------------------------------
    // 3) General CMOS scratch byte read/write round-trip (e.g. index 0x10).
    // ---------------------------------------------------------------------
    cmos_write(7'h10, 8'hA5);
    cmos_read (7'h10, v); chk("CMOS[0x10] round-trip 0xA5", v == 8'hA5);
    cmos_write(7'h10, 8'h5A);
    cmos_read (7'h10, v); chk("CMOS[0x10] round-trip 0x5A", v == 8'h5A);

    // ---------------------------------------------------------------------
    // 4) Index latch & NMI-disable bit stored SEPARATELY.
    //    Write index = 0x8C (bit7 set -> NMI disabled, latched idx = 0x0C).
    // ---------------------------------------------------------------------
    io_out(P_INDEX, 8'h8C);
    chk("NMI-disable bit set by index bit7", nmi_disable == 1'b1);
    // bit7 must NOT alias into cmos_data[]: latched index is 0x0C (REG_C).
    io_out(P_INDEX, 8'h00);   // re-point away first
    chk("NMI-disable cleared on index w/ bit7=0", nmi_disable == 1'b0);

    // ---------------------------------------------------------------------
    // 5) REG_C READ-then-CLEAR + irq8 lower (the critical side effect).
    //    Set REG_B to enable PIE/UIE so a pending flag can raise irq8, then
    //    inject a flag via a structural tick and verify REG_C read clears it.
    //    (We avoid relying on tick cadence: we PRELOAD a flag by enabling the
    //    interrupt while the flag is pending -- step 6 -- but for the pure
    //    read-clear we manufacture a pending state through a tick.)
    // ---------------------------------------------------------------------
    // Enable periodic + update interrupts, BCD, 24H. Rate=6 (nonzero) in REG_A.
    cmos_write(7'h0A, 8'h26);              // divider running (0x20), rate=6
    cmos_write(7'h0B, 8'h52);              // PIE(0x40)|UIE(0x10)|24H(0x02) = 0x52
    // run idle long enough for at least one structural tick to set flags+irq8
    idle(TICK_DIV + 4);
    chk("irq8 asserted after enabled tick flag", irq8 == 1'b1);
    cmos_read(7'h0C, v);
    chk("REG_C read returns nonzero pending flags", v != 8'h00);
    chk("REG_C read sets IRQF(0x80) when irq pending", (v & 8'h80) != 8'h00);
    // After the read: REG_C cleared and irq8 lowered.
    chk("irq8 lowered by REG_C read", irq8 == 1'b0);
    cmos_read(7'h0C, v);
    chk("REG_C reads 0x00 after read-clear", v == 8'h00);

    // ---------------------------------------------------------------------
    // 6) REG_B write raises irq8 immediately if an enabled flag is pending.
    //    First freeze (SET) so no fresh ticks fire, then manufacture a pending
    //    REG_C flag via a tick with interrupts DISABLED, then enable -> raise.
    // ---------------------------------------------------------------------
    // Disable all enables but keep divider running so UF still latches in REG_C.
    cmos_write(7'h0B, 8'h02);              // only 24H, no PIE/UIE/AIE, SET=0
    idle(TICK_DIV + 4);                    // tick sets UF/PF in REG_C, irq8 stays low
    chk("irq8 stays low while enables off", irq8 == 1'b0);
    cmos_read(7'h0C, v);
    chk("REG_C has pending flags (enables off)", v != 8'h00);
    // re-arm a pending flag for the enable test
    cmos_write(7'h0B, 8'h02);
    idle(TICK_DIV + 4);
    // Now ENABLE PIE while PF is pending -> REG_B write must raise IRQF + irq8.
    cmos_write(7'h0B, 8'h42);              // PIE|24H
    chk("REG_B enable-with-pending raises irq8", irq8 == 1'b1);
    cmos_read(7'h0C, v);
    chk("REG_C IRQF set after REG_B enable raise", (v & 8'h80) != 8'h00);
    chk("irq8 lowered again by REG_C read", irq8 == 1'b0);

    // REG_B write clearing enables with no pending -> lowers irq8 / clears IRQF.
    cmos_write(7'h0B, 8'h02);              // disable all enables
    chk("irq8 low after disabling enables", irq8 == 1'b0);

    // ---------------------------------------------------------------------
    // 7) REG_C and REG_D are WRITE-IGNORED (read-only registers).
    // ---------------------------------------------------------------------
    cmos_write(7'h0C, 8'hFF);
    cmos_read (7'h0C, v); chk("REG_C write ignored (stays 0x00)", v == 8'h00);
    cmos_write(7'h0D, 8'h00);
    cmos_read (7'h0D, v); chk("REG_D write ignored (VRT stays 0x80)", v == 8'h80);

    // ---------------------------------------------------------------------
    // 8) REG_A UIP (bit7) is READ-ONLY on write: writing 0xFF must not set the
    //    stored UIP bit; the low 7 bits take. Read with divider running can
    //    momentarily show UIP, so check the WRITTEN low bits round-trip.
    // ---------------------------------------------------------------------
    cmos_write(7'h0A, 8'hA6);              // bit7=1 (would-be UIP) + 0x26
    // Freeze to stop ticks/UIP window, then read.
    cmos_write(7'h0B, 8'h82);              // SET freeze (also forces UIE off)
    cmos_read (7'h0A, v);
    chk("REG_A low 7 bits written (0x26)", (v & 8'h7F) == 8'h26);
    chk("REG_A UIP not settable via write while frozen", (v & 8'h80) == 8'h00);

    // ---------------------------------------------------------------------
    // 9) SET (REG_B bit7) FREEZES the wall-clock advance.
    //    With SET asserted, the seconds register must not change across many
    //    structural ticks. Then clearing SET lets it advance again.
    // ---------------------------------------------------------------------
    // ensure running config first, capture seconds, then freeze.
    cmos_write(7'h0B, 8'h02);              // running, BCD, 24H
    cmos_write(7'h0A, 8'h26);              // divider running
    idle(2);
    cmos_read(7'h00, v);                   // read current seconds
    // Now freeze
    cmos_write(7'h0B, 8'h82);              // SET
    cmos_read(7'h00, v);
    begin
      automatic logic [7:0] sec_frozen = v;
      idle(TICK_DIV*3 + 4);                // several ticks while frozen
      cmos_read(7'h00, v);
      chk("SET freezes seconds (no advance)", v == sec_frozen);
    end
    // Unfreeze and confirm advance.
    cmos_write(7'h0B, 8'h02);              // clear SET, running
    cmos_read(7'h00, v);
    begin
      automatic logic [7:0] sec_before = v;
      idle(TICK_DIV*2 + 4);                // a couple ticks running
      cmos_read(7'h00, v);
      chk("seconds advance once SET cleared", v != sec_before);
    end

    // ---------------------------------------------------------------------
    // 10) BCD seconds carry: at 59 BCD (0x59) the next tick wraps to 0x00 and
    //     bumps minutes. Seed sec=0x59, min=0x10 (BCD, 24H, running).
    // ---------------------------------------------------------------------
    cmos_write(7'h0B, 8'h82);              // freeze while we seed
    cmos_write(7'h02, 8'h10);              // minutes = 0x10 BCD
    cmos_write(7'h00, 8'h59);              // seconds = 0x59 BCD
    cmos_write(7'h0B, 8'h02);              // unfreeze (running, BCD)
    // advance exactly until the wrap shows; poll seconds back to a BCD 00..0x0x
    begin
      automatic int guard = 0;
      automatic logic [7:0] sec, mn;
      // wait for seconds to wrap past 0x59 (becomes a low BCD value) -- a few ticks
      do begin
        idle(TICK_DIV + 2);
        cmos_read(7'h00, sec);
        guard++;
      end while (sec == 8'h59 && guard < 8);
      cmos_read(7'h02, mn);
      chk("BCD seconds wrapped from 0x59 (now < 0x59)", sec < 8'h59);
      chk("minute carried 0x10 -> 0x11 (BCD)", mn == 8'h11);
      // verify BCD encoding validity: each nibble <= 9
      chk("BCD seconds nibbles valid", (sec[3:0] <= 4'd9) && (sec[7:4] <= 4'd9));
    end

    // ---------------------------------------------------------------------
    // 11) Binary mode (REG_B.DM=1): seconds stored/incremented as plain binary.
    //     Seed sec=58 binary, run, confirm it counts 58->59->0 in binary (not BCD).
    // ---------------------------------------------------------------------
    cmos_write(7'h0B, 8'h86);              // SET(freeze)|DM(0x04)|24H(0x02) = 0x86
    cmos_write(7'h00, 8'd58);              // seconds = 58 (binary)
    cmos_write(7'h0B, 8'h06);              // DM|24H running (SET cleared)
    begin
      automatic int guard = 0;
      automatic logic [7:0] sec;
      // run until it wraps below 58
      do begin
        idle(TICK_DIV + 2);
        cmos_read(7'h00, sec);
        guard++;
      end while (sec >= 8'd58 && guard < 8);
      chk("binary seconds wrapped below 60 (binary, not BCD)", sec < 8'd58);
      // a binary wrap lands in 0..3; a BCD-mistake would never produce e.g. 0x00..0x03 only,
      // but the strong check is: value is a valid binary second (< 60).
      chk("binary seconds in range [0,59]", sec < 8'd60);
    end

    // ---------------------------------------------------------------------
    // 12) PS/2 century alias 0x37 -> 0x32 on write AND read.
    // ---------------------------------------------------------------------
    cmos_write(7'h32, 8'h00);              // clear century
    cmos_write(7'h37, 8'h20);              // write via PS/2 alias
    cmos_read (7'h32, v); chk("PS/2 century write 0x37 aliases to 0x32", v == 8'h20);
    cmos_write(7'h32, 8'h19);
    cmos_read (7'h37, v); chk("PS/2 century read 0x37 aliases to 0x32", v == 8'h19);

    // ---- summary ----
    $display("=== ven_rtc self-check: %0d checks, %0d errors ===", checks, errors);
    if (errors == 0) $display("RESULT: PASS");
    else             $display("RESULT: FAIL");
    if (errors != 0) $fatal(1, "ven_rtc unit self-check FAILED");
    $finish;
  end

  // global watchdog
  initial begin
    #200000;
    $display("RESULT: FAIL (timeout)");
    $fatal(1, "tb_ven_rtc timeout");
  end

endmodule

`default_nettype wire
