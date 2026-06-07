// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ============================================================================
// rtl/soc/ven_rtc.sv -- MC146818 RTC/CMOS device for the Ventium SoC (M8).
//
// STANDALONE, SYNTHESIZABLE. Self-contained (no ventium_pkg dependency). NOT
// added to rtl/ventium.f; built+unit-tested only by its own verif/soc/ harness.
//
// GROUNDING: CPU-observable register semantics mirror QEMU 8.2.2
//   hw/rtc/mc146818rtc.c  (cmos_ioport_write / cmos_ioport_read) and
//   include/hw/rtc/mc146818rtc_regs.h.  This is what the later
//   differential-vs-qemu-system SoC gate will check, so this module matches the
//   CPU read/write side of those two functions exactly (the host-clock derived
//   wall-time math -- get_guest_rtc_ns / rtc_update_time / alarm scheduling -- is
//   NOT modeled; see "MODELED vs DEFERRED" below).
//
// PMIO map (RTC_ISA_BASE 0x70):
//   0x70  index port  -- WRITE-ONLY: latch cmos_index = wdata & 0x7f;
//                        bit7 = NMI-disable, stored SEPARATELY (nmi_disable_q,
//                        does NOT alias into cmos_data[]). READ returns 0xFF.
//   0x71  data  port  -- WRITE: commit to cmos_data[cmos_index] (with the
//                        per-register rules below). READ: return the addressed
//                        CMOS byte (with REG_C read-then-clear side effect).
//   The decoder convention is: cs asserted, addr[0]==0 -> index port (even),
//   addr[0]==1 -> data port (odd). (QEMU keys the same way: `(addr & 1) == 0`.)
//
// REG_A (0x0A): periodic-rate bits[3:0]; divider bits[6:4] (0x70 mask);
//               UIP 0x80 is READ-ONLY (write preserves the live UIP bit).
// REG_B (0x0B): SET 0x80 (freeze wall-clock advance), PIE 0x40 / AIE 0x20 /
//               UIE 0x10 (IRQ enables), SQWE 0x08, DM 0x04 (1=binary 0=BCD),
//               24H 0x02. On write: if (data & cmos_data[C] & REG_C_MASK)!=0
//               raise IRQF+irq8; else clear IRQF + lower irq8. (matches qemu)
// REG_C (0x0C): IRQF 0x80 / PF 0x40 / AF 0x20 / UF 0x10. READ-then-CLEAR: a CPU
//               READ of 0x0C returns the latched flags THEN zeroes REG_C and
//               LOWERS irq8 (the critical side effect). REG_C is WRITE-IGNORED.
// REG_D (0x0D): VRT 0x80 (battery-valid; reset value 0x80). WRITE-IGNORED.
// Time regs: SEC 0x00 / MIN 0x02 / HR 0x04 / DOW 0x06 / DOM 0x07 / MON 0x08 /
//            YR 0x09 + CENTURY 0x32. PS/2 century alias 0x37 -> 0x32 (qemu maps
//            RTC_IBM_PS2_CENTURY_BYTE to RTC_CENTURY on both read and write).
//
// RESET DEFAULTS (qemu rtc_realizefn): A=0x26, B=0x02, C=0x00, D=0x80.
//
// INTERFACE: the COMMON SoC device interface (clk/rst/cs/we/addr/wdata/rdata)
// + the device-specific output irq8. rst is SYNCHRONOUS, ACTIVE-HIGH (PC RESET).
// Register WRITES commit on a clocked edge when (cs & we); READS are
// COMBINATIONAL off the registers (same-cycle-ack), with read side-effects
// (REG_C clear, PS/2 century index remap) applied on the clocked edge when
// (cs & ~we). irq8 is a registered level output (1 = asserting).
//
// ---------------------------------------------------------------------------
// MODELED vs DEFERRED (honest):
//  MODELED (CPU-observable, oracled by the directed self-check):
//   * 128-byte cmos_data[] read/write through index+data ports.
//   * index latch (wdata & 0x7f) + separate NMI-disable bit; index read = 0xFF.
//   * REG_A UIP read-only-on-write; REG_C read-then-clear + irq8 lower;
//     REG_C/REG_D write-ignore; REG_B write -> immediate IRQF raise/lower per
//     (B & C & REG_C_MASK); PS/2 century 0x37 remap.
//   * SET (REG_B bit7) FREEZES the structural wall-clock tick (sec stops
//     advancing) -- the CPU-observable freeze semantics.
//   * irq8 level output: raised by REG_B-enable-with-pending and by the
//     structural tick setting an enabled flag; lowered by REG_C read / by a
//     REG_B write that leaves no enabled pending flag.
//  STRUCTURAL, NOT ORACLED (cadence is real-time-derived in qemu, untestable
//  here without a host clock oracle):
//   * The 1 Hz update tick + the periodic-interrupt tick are driven off `clk`
//     via a parameterized prescaler (CLK_HZ / TICK_DIV). The CADENCE is NOT
//     checked against qemu (qemu derives it from the host monotonic clock);
//     only the *consequences* of a tick (UF/PF set, irq8, BCD/binary increment,
//     SET-freeze) are register-observable and are checked structurally.
//   * UIP (REG_A 0x80) is asserted for a short structural window before the
//     update tick; the exact 244us hold is not reproduced (no host clock).
//   * The alarm (AF / REG_*_ALARM matching) and the qemu lost-tick / coalesced
//     IRQ reinjection policy are DEFERRED (not exercised by Win95 boot path).
//   * Wall-clock time is a free-running BCD/binary counter seeded at reset
//     (2026-06-05 00:00:00, DOW=Fri) -- absolute value is not oracled; the SoC
//     gate seeds it from the host like qemu's rtc_set_date_from_host.
// ============================================================================
`default_nettype none

module ven_rtc #(
    // Structural tick prescaler: one 1 Hz "update" tick every TICK_DIV clocks.
    // Cadence is NOT oracled (see header). Default tiny so the unit TB can
    // observe a tick quickly; the SoC instance overrides to CLK_HZ.
    parameter int unsigned TICK_DIV = 16
) (
    input  wire logic        clk,
    input  wire logic        rst,        // SYNCHRONOUS, ACTIVE-HIGH (PC RESET)

    input  wire logic        cs,         // chip-select (decoder asserts for 0x70/0x71)
    input  wire logic        we,         // 1 = OUT (CPU write), 0 = IN (CPU read)
    input  wire logic [15:0] addr,       // I/O port address (bit0 selects index/data)
    input  wire logic [7:0]  wdata,      // write data
    output logic [7:0]  rdata,      // read data (COMBINATIONAL off the registers)

    output logic        irq8,       // RTC interrupt line (level, 1 = asserting)
    output logic        nmi_disable // bit7 of the last index-port write (NMI mask)
);

  // -------------------------------------------------------------------------
  // CMOS register indices (mc146818rtc_regs.h)
  // -------------------------------------------------------------------------
  localparam logic [6:0] RTC_SECONDS       = 7'h00;
  localparam logic [6:0] RTC_MINUTES       = 7'h02;
  localparam logic [6:0] RTC_HOURS         = 7'h04;
  localparam logic [6:0] RTC_DAY_OF_WEEK   = 7'h06;
  localparam logic [6:0] RTC_DAY_OF_MONTH  = 7'h07;
  localparam logic [6:0] RTC_MONTH         = 7'h08;
  localparam logic [6:0] RTC_YEAR          = 7'h09;
  localparam logic [6:0] RTC_REG_A         = 7'h0A;
  localparam logic [6:0] RTC_REG_B         = 7'h0B;
  localparam logic [6:0] RTC_REG_C         = 7'h0C;
  localparam logic [6:0] RTC_REG_D         = 7'h0D;
  localparam logic [6:0] RTC_CENTURY       = 7'h32;
  localparam logic [6:0] RTC_PS2_CENTURY   = 7'h37;

  // Bit masks (mc146818rtc_regs.h). Bit-position aliases are referenced by index
  // ([7]/[6]/.. ) elsewhere; the masks below are the ones used as 8-bit values.
  localparam logic [7:0] REG_A_UIP  = 8'h80;
  localparam logic [7:0] REG_B_UIE  = 8'h10;
  localparam logic [7:0] REG_C_IRQF = 8'h80;
  localparam logic [7:0] REG_C_PF   = 8'h40;
  localparam logic [7:0] REG_C_AF   = 8'h20;
  localparam logic [7:0] REG_C_UF   = 8'h10;
  localparam logic [7:0] REG_C_MASK = 8'h70;   // PF|AF|UF (interrupt sources)

  // -------------------------------------------------------------------------
  // State
  // -------------------------------------------------------------------------
  logic [7:0] cmos_data [0:127];   // 128-byte CMOS
  logic [6:0] cmos_index;          // latched index (wdata & 0x7f)
  logic       nmi_disable_q;       // bit7 of last index write (stored separately)
  logic       irq8_q;              // registered irq8 level

  // structural tick prescaler (cadence NOT oracled)
  logic [31:0] tick_cnt;
  logic        tick_1hz;           // pulses high one clock every TICK_DIV clocks

  assign irq8        = irq8_q;
  assign nmi_disable = nmi_disable_q;

  // effective index for this access (PS/2 century 0x37 aliases to 0x32) ------
  function automatic logic [6:0] eff_index(input logic [6:0] idx);
    eff_index = (idx == RTC_PS2_CENTURY) ? RTC_CENTURY : idx;
  endfunction

  // running = wall clock advances: SET clear AND divider bits[6:4] <= 0x20.
  // (qemu rtc_running: !(REG_B & SET) && (REG_A & 0x70) <= 0x20.)
  function automatic logic rtc_running();
    rtc_running = (~(cmos_data[RTC_REG_B][7])) &&
                  ((cmos_data[RTC_REG_A] & 8'h70) <= 8'h20);
  endfunction

  // -------------------------------------------------------------------------
  // COMBINATIONAL READ (rdata) -- same-cycle-ack contract.
  //   index port (addr[0]==0) -> 0xFF
  //   data  port (addr[0]==1) -> cmos_data[eff_index] (REG_C clear is a clocked
  //   side effect, but the *returned* value is the pre-clear latched byte).
  // qemu REG_A read OR-s in UIP when an update is in progress -- model from the
  // structural tick window (not the precise 244us hold).
  // -------------------------------------------------------------------------
  logic [6:0] rd_idx;
  always_comb begin
    rd_idx = eff_index(cmos_index);
    if (addr[0] == 1'b0) begin
      rdata = 8'hFF;                       // index port read -> 0xFF
    end else begin
      unique case (rd_idx)
        RTC_REG_A: begin
          // UIP (read-only) reflected live; structural pre-tick window.
          rdata = cmos_data[RTC_REG_A] & ~REG_A_UIP;
          if (uip_window) rdata = rdata | REG_A_UIP;
        end
        default:   rdata = cmos_data[rd_idx];
      endcase
    end
  end

  // UIP structural window: assert UIP the clock BEFORE a 1Hz tick fires while
  // the clock is running. NOT the precise qemu 244us hold (no host oracle).
  logic uip_window;
  assign uip_window = rtc_running() && (tick_cnt == (TICK_DIV-1)) ;

  // -------------------------------------------------------------------------
  // Wall-clock increment helpers (BCD or binary per REG_B.DM).
  //   bcd:    value held as packed BCD (tens<<4 | ones)
  //   binary: value held as plain binary
  // We keep the cmos time bytes in whatever representation REG_B.DM selects and
  // increment accordingly so a CPU read sees a self-consistent encoding. (Absolute
  // value is not oracled; only the encoding + carry behavior is structural.)
  // -------------------------------------------------------------------------
  function automatic logic [7:0] inc_field(input logic [7:0] v,
                                            input logic [7:0] modulo, // exclusive max in *decimal*
                                            input logic       binmode,
                                            output logic      carry);
    logic [7:0] dec;       // decoded decimal value
    logic [7:0] nxt;
    begin
      dec = binmode ? v : ((v >> 4) * 8'd10 + (v & 8'h0F));
      if (dec + 8'd1 >= modulo) begin
        nxt   = 8'd0;
        carry = 1'b1;
      end else begin
        nxt   = dec + 8'd1;
        carry = 1'b0;
      end
      inc_field = binmode ? nxt : (((nxt / 8'd10) << 4) | (nxt % 8'd10));
    end
  endfunction

  // -------------------------------------------------------------------------
  // Structural tick prescaler
  // -------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      tick_cnt <= 32'd0;
      tick_1hz <= 1'b0;
    end else begin
      if (tick_cnt == (TICK_DIV-1)) begin
        tick_cnt <= 32'd0;
        tick_1hz <= 1'b1;
      end else begin
        tick_cnt <= tick_cnt + 32'd1;
        tick_1hz <= 1'b0;
      end
    end
  end

  // -------------------------------------------------------------------------
  // Main clocked register process
  // -------------------------------------------------------------------------
  integer i;
  logic [7:0] new_b;
  logic       c_sec, c_min, c_hr;
  logic [7:0] nsec, nmin, nhr;
  logic       binmode;
  logic [7:0] new_irqs;        // tick-set flags newly raised

  // c_hr (the hour-rollover carry) is intentionally discarded: day/month/year
  // rollover is DEFERRED (not on the Win95 boot path). Tie it off for lint.
  logic       unused_carry;
  assign unused_carry = c_hr;
  // Only addr[0] selects index/data; upper address bits are decoded upstream.
  logic       unused_addr;
  assign unused_addr = ^{addr[15:1], 1'b0};

  // The blocking temporaries below (new_b/new_irqs/binmode/nsec/nmin/nhr) are
  // intentional intra-clock locals (computed-then-used within one evaluation of
  // this always_ff); flag-clean to use '=' for them here.
  /* verilator lint_off BLKSEQ */
  always_ff @(posedge clk) begin
    if (rst) begin
      // qemu rtc_realizefn defaults
      for (i = 0; i < 128; i = i + 1) cmos_data[i] <= 8'h00;
      cmos_data[RTC_REG_A] <= 8'h26;
      cmos_data[RTC_REG_B] <= 8'h02;   // 24H, BCD
      cmos_data[RTC_REG_C] <= 8'h00;
      cmos_data[RTC_REG_D] <= 8'h80;   // VRT
      // seed a deterministic wall time (BCD, 24H): 2026-06-05 00:00:00, DOW=Fri(6)
      cmos_data[RTC_SECONDS]      <= 8'h00;
      cmos_data[RTC_MINUTES]      <= 8'h00;
      cmos_data[RTC_HOURS]        <= 8'h00;
      cmos_data[RTC_DAY_OF_WEEK]  <= 8'h06;  // 1=Sun..7=Sat ; Fri=6
      cmos_data[RTC_DAY_OF_MONTH] <= 8'h05;
      cmos_data[RTC_MONTH]        <= 8'h06;
      cmos_data[RTC_YEAR]         <= 8'h26;  // year %100 = 26
      cmos_data[RTC_CENTURY]      <= 8'h20;  // 20xx
      cmos_index    <= 7'h00;
      nmi_disable_q <= 1'b0;
      irq8_q        <= 1'b0;
    end else begin
      // ---------------------------------------------------------------------
      // CPU access (write commit / read side-effects) -- takes priority over a
      // coincident structural tick (the tick reflects the post-access state).
      // ---------------------------------------------------------------------
      if (cs && we) begin
        // ---- WRITE ----
        if (addr[0] == 1'b0) begin
          // index port: latch addr & store NMI-disable bit separately
          cmos_index    <= wdata[6:0];
          nmi_disable_q <= wdata[7];
        end else begin
          // data port: per-register write rules (qemu cmos_ioport_write)
          unique case (eff_index(cmos_index))
            RTC_REG_A: begin
              // UIP (0x80) is read-only: keep the live UIP, take the rest.
              cmos_data[RTC_REG_A] <=
                  (wdata & ~REG_A_UIP) | (cmos_data[RTC_REG_A] & REG_A_UIP);
            end
            RTC_REG_B: begin
              new_b = wdata;
              // SET mode also forces UIE off (qemu: data &= ~REG_B_UIE).
              if (new_b[7]) new_b = new_b & ~REG_B_UIE;
              cmos_data[RTC_REG_B] <= new_b;
              // If enabling an IRQ whose flag is already pending -> raise now;
              // else clear IRQF + lower irq8. (qemu REG_B write tail.)
              if ((new_b & cmos_data[RTC_REG_C] & REG_C_MASK) != 8'h00) begin
                cmos_data[RTC_REG_C] <= cmos_data[RTC_REG_C] | REG_C_IRQF;
                irq8_q               <= 1'b1;
              end else begin
                cmos_data[RTC_REG_C] <= cmos_data[RTC_REG_C] & ~REG_C_IRQF;
                irq8_q               <= 1'b0;
              end
            end
            RTC_REG_C, RTC_REG_D: begin
              // read-only: write ignored
            end
            default: begin
              cmos_data[eff_index(cmos_index)] <= wdata;
            end
          endcase
          // PS/2 century alias: qemu remaps cmos_index to RTC_CENTURY on a
          // write to 0x37 (it sticks). Mirror that.
          if (cmos_index == RTC_PS2_CENTURY) cmos_index <= RTC_CENTURY;
        end
      end else if (cs && !we) begin
        // ---- READ side effects ----
        // PS/2 century read alias (qemu remaps index then falls through).
        if (addr[0] == 1'b1) begin
          if (cmos_index == RTC_PS2_CENTURY) cmos_index <= RTC_CENTURY;
          if (eff_index(cmos_index) == RTC_REG_C) begin
            // READ-then-CLEAR: zero REG_C and LOWER irq8 (critical side effect).
            cmos_data[RTC_REG_C] <= 8'h00;
            irq8_q               <= 1'b0;
          end
        end
      end else begin
        // -------------------------------------------------------------------
        // No CPU access this clock: service the structural wall-clock tick.
        // Cadence NOT oracled; consequences (UF/PF, irq8, BCD inc, freeze) are.
        // -------------------------------------------------------------------
        if (tick_1hz) begin
          // periodic flag: set PF whenever divider running + periodic rate != 0
          new_irqs = 8'h00;
          if (((cmos_data[RTC_REG_A] & 8'h70) <= 8'h20) &&
              (cmos_data[RTC_REG_A][3:0] != 4'h0)) begin
            new_irqs = new_irqs | REG_C_PF;
          end
          if (rtc_running()) begin
            // advance the BCD/binary seconds.. with carry, unless SET freeze.
            binmode = cmos_data[RTC_REG_B][2];  // DM
            nsec = inc_field(cmos_data[RTC_SECONDS], 8'd60, binmode, c_sec);
            cmos_data[RTC_SECONDS] <= nsec;
            if (c_sec) begin
              nmin = inc_field(cmos_data[RTC_MINUTES], 8'd60, binmode, c_min);
              cmos_data[RTC_MINUTES] <= nmin;
              if (c_min) begin
                nhr = inc_field(cmos_data[RTC_HOURS], 8'd24, binmode, c_hr);
                cmos_data[RTC_HOURS] <= nhr;
                // (day/month/year rollover deferred -- not Win95-boot relevant)
              end
            end
            // update-ended flag every second the clock is running
            new_irqs = new_irqs | REG_C_UF;
          end
          // Latch newly-raised flags into REG_C.
          cmos_data[RTC_REG_C] <= cmos_data[RTC_REG_C] | new_irqs;
          // Raise irq8 if any newly-raised flag is enabled in REG_B.
          //   PF<->PIE, UF<->UIE, AF<->AIE
          if (((new_irqs & REG_C_PF) != 8'h00 && cmos_data[RTC_REG_B][6]) ||
              ((new_irqs & REG_C_UF) != 8'h00 && cmos_data[RTC_REG_B][4]) ||
              ((new_irqs & REG_C_AF) != 8'h00 && cmos_data[RTC_REG_B][5])) begin
            cmos_data[RTC_REG_C] <= cmos_data[RTC_REG_C] | new_irqs | REG_C_IRQF;
            irq8_q               <= 1'b1;
          end
        end
      end
    end
  end
  /* verilator lint_on BLKSEQ */

endmodule

`default_nettype wire
