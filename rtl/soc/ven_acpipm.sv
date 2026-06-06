// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ============================================================================
// ven_acpipm.sv -- Ventium SoC (M8) ACPI PM Timer device (PIIX4 PM base+0x08)
// ============================================================================
//
// DEVICE: ACPI Power-Management Timer.
//   Port (PIIX4 PM I/O base + 0x08) => 0x608 in the Win95 boot map.
//   ACCESS: 32-bit READ. Writes are IGNORED.
//   Returns a FREE-RUNNING 24-bit counter that ticks at PM_TIMER_FREQUENCY.
//
// GROUNDING (CPU-observable semantics, QEMU 8.2.2):
//   ventium-refs/.../qemu/hw/acpi/core.c
//     acpi_pm_tmr_get_clock(): muldiv64(virtual_ns, PM_TIMER_FREQUENCY, 1e9)
//     acpi_pm_tmr_get():       return d & 0xffffff;          // 24-bit value
//     acpi_pm_tmr_read():      return acpi_pm_tmr_get(opaque);// any width/addr
//     acpi_pm_tmr_write():     /* nothing */                 // writes ignored
//   ventium-refs/.../qemu/include/hw/acpi/acpi.h
//     #define PM_TIMER_FREQUENCY 3579545
//   memory_region_init_io(..., "acpi-tmr", 4); add_subregion(parent, 8, ...)
//     => the timer region is 4 bytes wide, lives at PM base + 8.
//
//   So, CPU-observable: a 32-bit IN at 0x608 returns {8'h00, count[23:0]}, a
//   monotonically increasing value wrapping at 2^24. An OUT does nothing.
//
// WIDTH NOTE (per task): this device is a 32-bit read. Unlike the byte
//   peripherals (8-bit rdata), this module exposes BOTH:
//     - rdata     [7:0]  : the COMMON byte interface (low byte, addr-selected)
//                          so the future ventium_soc PMIO decoder can wire it
//                          uniformly with the byte devices for 8-bit IN.
//     - rdata32   [31:0] : the native 32-bit value the decoder uses for the
//                          dword IN that the ACPI driver actually issues.
//   Both are COMBINATIONAL off the counter register (same-cycle-ack contract).
//
// CADENCE (structural, NOT oracled): the 3.579545 MHz tick is derived from the
//   SoC clk by a fractional accumulator. The exact instantaneous count value
//   at a given cycle is NOT checked against QEMU (QEMU samples a host virtual
//   clock; we sample clk) -- only the CPU-observable PROPERTIES are oracled:
//     (a) 24-bit width / wrap (count & 0x00FFFFFF, bit 24+ never visible),
//     (b) monotonic increase between reads,
//     (c) writes ignored,
//     (d) the average rate equals PM_TIMER_FREQUENCY given CLK_HZ.
//   Relationship: each clk, an accumulator advances by PM_TIMER_FREQUENCY; when
//   it reaches CLK_HZ it wraps and the 24-bit counter ticks once. Over one
//   second (CLK_HZ clks) the counter advances by exactly PM_TIMER_FREQUENCY
//   ticks (modulo the residual carried in the accumulator). This makes the
//   clk->3.579545 MHz relationship explicit and parameterizable.
//
// EXTRA: none. No IRQ / SCI in the boot path (the PM-timer overflow SCI in QEMU
//   is not exercised by the Win95 boot histogram), so no IRQ output is provided.
//
// INTERFACE: common Ventium SoC device contract.
//   rst : SYNCHRONOUS, ACTIVE-HIGH (PC RESET).
//   cs  : chip-select from the SoC PMIO decoder (asserted on a 0x608 hit).
//   we  : 1 = OUT (write), 0 = IN (read).
//   READS  are combinational off the register.
//   WRITES commit on the clocked edge when (cs & we) -- here a no-op (ignored),
//          modeled explicitly so the contract is uniform with other devices.
// ============================================================================

module ven_acpipm #(
    // SoC clock frequency in Hz. Default is a placeholder; the integrator wires
    // the real ventium_soc clk rate here so the average PM-timer rate is
    // PM_TIMER_FREQUENCY. Must be >= PM_TIMER_FREQUENCY (one tick per clk max).
    parameter int unsigned CLK_HZ        = 33_000_000,
    parameter int unsigned PM_TIMER_FREQ = 3_579_545
) (
    input  logic        clk,
    input  logic        rst,        // synchronous, active-high (PC RESET)
    input  logic        cs,         // chip-select (decoder: port 0x608 hit)
    input  logic        we,         // 1 = OUT (write), 0 = IN (read)
    input  logic [15:0] addr,       // I/O port address
    input  logic [7:0]  wdata,      // write data (ignored by this device)

    output logic [7:0]  rdata,      // common byte read (addr-selected byte)
    output logic [31:0] rdata32     // native 32-bit read ({8'h0, count[23:0]})
);

    // ------------------------------------------------------------------------
    // Fractional accumulator that derives the PM_TIMER_FREQ tick from clk.
    //   acc += PM_TIMER_FREQ each clk; when acc >= CLK_HZ, subtract CLK_HZ and
    //   emit one tick. Average tick rate = PM_TIMER_FREQ ticks per CLK_HZ clks
    //   = PM_TIMER_FREQ Hz. The residual (acc mod CLK_HZ) carries the fraction
    //   so there is no long-term drift.
    // ------------------------------------------------------------------------
    localparam int unsigned ACC_W = $clog2(CLK_HZ) + 1;

    logic [ACC_W-1:0] acc_q;
    logic [23:0]      count_q;   // the free-running 24-bit ACPI PM counter
    logic             tick;

    // tick when the accumulator (after adding this cycle's increment) crosses
    // CLK_HZ. Use the registered acc_q + increment >= CLK_HZ.
    assign tick = (acc_q + PM_TIMER_FREQ[ACC_W-1:0]) >= CLK_HZ[ACC_W-1:0];

    always_ff @(posedge clk) begin
        if (rst) begin
            acc_q   <= '0;
            count_q <= 24'h000000;   // acpi_pm_tmr_reset path starts at 0
        end else begin
            // fractional accumulator
            if (tick)
                acc_q <= (acc_q + PM_TIMER_FREQ[ACC_W-1:0]) - CLK_HZ[ACC_W-1:0];
            else
                acc_q <= acc_q + PM_TIMER_FREQ[ACC_W-1:0];

            // free-running 24-bit counter (wraps at 2^24, == d & 0xffffff).
            // WRITE side of the contract: an OUT to 0x608 is IGNORED (QEMU
            // acpi_pm_tmr_write does nothing) -- (cs & we) deliberately has NO
            // effect on count_q. The counter advances ONLY on a tick, so a
            // write that lands on a tick cycle still gets the tick (and nothing
            // else); a write on a non-tick cycle leaves count_q unchanged.
            if (tick)
                count_q <= count_q + 24'd1;
        end
    end

    // ------------------------------------------------------------------------
    // READ: combinational off the counter register (same-cycle-ack).
    //   Native dword value is {8'h00, count[23:0]} for ANY addr (QEMU returns
    //   the full 24-bit value regardless of access offset/width).
    //   The byte view selects a byte by addr[1:0] for an 8-bit IN.
    // ------------------------------------------------------------------------
    logic [31:0] tmr_val;
    assign tmr_val = {8'h00, count_q};        // == acpi_pm_tmr_get() & 0xffffff

    assign rdata32 = tmr_val;

    always_comb begin
        if (cs && !we) begin
            unique case (addr[1:0])
                2'b00:   rdata = tmr_val[7:0];
                2'b01:   rdata = tmr_val[15:8];
                2'b10:   rdata = tmr_val[23:16];
                default: rdata = tmr_val[31:24];   // 8'h00
            endcase
        end else begin
            rdata = 8'h00;
        end
    end

    // This device IGNORES write data and only decodes addr[1:0] for the byte
    // view. wdata[7:0] and addr[15:2] are part of the COMMON interface but
    // unused here -- sink them explicitly so the DUT stays -Wall clean.
    logic _unused;
    assign _unused = &{1'b0, wdata, addr[15:2]};

endmodule
