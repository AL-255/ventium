// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// soc/ven_fan_ctrl.sv — KV260 temperature-controlled cooling fan (PL-only).
//
// Reads the SoC's on-die temperature from a PL SYSMONE4 (the Xilinx System
// Management Wizard, continuous temperature mode: temp[15:0] + eos), maps it
// LINEARLY to an 8-bit PWM duty cycle, and drives the fan transistor pin
// (KV260 package pin A12, LVCMOS33) with a low-frequency PWM. Entirely in the
// PL — no PS / Linux involvement, so the fan works the instant the bitstream
// loads. Modeled on Tai-Min's "KV260 temperature-controlled cooling fan"
// (hackster.io): a clock divider -> temperature->PWM map -> PWM generator,
// here folded into one synthesizable module with a dead-sensor fail-safe.
//
// Algorithm (matches the reference): below FAN_OFF_C the fan is off, above
// FAN_FULL_C it runs at 100%, linear in between. Temperature is the UltraScale+
// SYSMONE4 10-bit transfer: centi-degC = (code10 * 50931 / 1024) - 28023.
//
// Default PWM: the 8-bit duty counter ticks at PWM_TICK_HZ (2 kHz) so the fan
// PWM period is 256 ticks ~= 7.8 Hz (the reference's working point; a small fan
// integrates this to a proportional speed). All rates are parameters.

// The high bits of the 32-bit signed math accumulator (duty_calc) are
// intentionally unused — the duty is clamped to 8 bits.
/* verilator lint_off UNUSEDSIGNAL */
module ven_fan_ctrl #(
    parameter int CLK_HZ      = 40_000_000, // PL0 clock (pl_clk0) feeding clk
    parameter int PWM_TICK_HZ = 2_000,      // 8-bit duty counter tick rate
    parameter int FAN_OFF_C   = 0,          // <= this temperature -> fan off
    parameter int FAN_FULL_C  = 65          // >= this temperature -> fan 100%
)(
    input  logic        clk,
    input  logic        rst_n,
    // ---- SYSMONE4 / System Management Wizard temperature bus ----------------
    input  logic [9:0]  temp,    // System Management Wizard temp_out[9:0] (10-bit ADC code)
    input  logic        eos,     // end-of-sequence: a fresh temperature this clk
    // ---- fan drive ----------------------------------------------------------
    output logic        fan_pwm  // -> package pin A12 (LVCMOS33), fan transistor
);
  localparam int TICK_DIV    = CLK_HZ / PWM_TICK_HZ;   // clk cycles per duty tick
  localparam int OFF_CENTI   = FAN_OFF_C  * 100;
  localparam int FULL_CENTI  = FAN_FULL_C * 100;
  localparam int SPAN_CENTI  = FULL_CENTI - OFF_CENTI; // linear span (centi-degC)
  // fixed-point slope: duty = (centi - OFF) * RECIP >> 20, RECIP = 255*2^20/span
  localparam int RECIP       = (255 * (1 << 20)) / SPAN_CENTI;
  localparam int EOS_TIMEOUT = CLK_HZ;                 // ~1 s with no sample = dead
  localparam int TICKW       = $clog2(TICK_DIV);
  localparam int WDW         = $clog2(EOS_TIMEOUT);

  // ---- latch the temperature on end-of-sequence ---------------------------
  // temp_out[9:0] is already the 10-bit temperature ADC code.
  logic [9:0] code_q;
  always_ff @(posedge clk) begin
    if (!rst_n)   code_q <= 10'd0;
    else if (eos) code_q <= temp;
  end

  // ---- code -> centi-degC -> 8-bit duty (combinational map) ----------------
  logic signed [31:0] centi, duty_calc;
  always_comb begin
    centi = ((($signed({22'd0, code_q})) * 32'sd50931) >>> 10) - 32'sd28023;
    if      (centi <= OFF_CENTI)  duty_calc = 32'sd0;
    else if (centi >= FULL_CENTI) duty_calc = 32'sd255;
    else                          duty_calc = ((centi - OFF_CENTI) * RECIP) >>> 20;
  end
  logic [7:0] duty;
  always_ff @(posedge clk) begin
    if (!rst_n) duty <= 8'd0;
    else        duty <= duty_calc[7:0];
  end

  // ---- dead-sensor fail-safe: no eos for ~1 s -> force the fan to 100% so a
  // hung SYSMON can never let the board overheat. ---------------------------
  logic [WDW-1:0] wd;
  logic           dead;
  always_ff @(posedge clk) begin
    if (!rst_n)               begin wd <= '0; dead <= 1'b0; end
    else if (eos)             begin wd <= '0; dead <= 1'b0; end
    else if (wd == WDW'(EOS_TIMEOUT-1)) dead <= 1'b1;
    else                      wd <= wd + 1'b1;
  end

  // ---- low-frequency 8-bit PWM ---------------------------------------------
  logic [TICKW-1:0] tick;
  logic [7:0]       pwm_cnt;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      tick <= '0; pwm_cnt <= 8'd0; fan_pwm <= 1'b0;
    end else if (tick == TICKW'(TICK_DIV-1)) begin
      tick    <= '0;
      pwm_cnt <= pwm_cnt + 8'd1;                 // free-running 0..255
      fan_pwm <= dead ? 1'b1 : (pwm_cnt < duty); // high while below duty
    end else begin
      tick <= tick + 1'b1;
    end
  end
  /* verilator lint_on UNUSEDSIGNAL */

endmodule : ven_fan_ctrl
