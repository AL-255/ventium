// ventium_soc.sv — Ventium M8.1 SoC integration top (core + 8259 PIC + 8254 PIT).
//
// The FIRST SoC-integration top (docs PROGRESS_Jun04.md "M8" + the M8.0 design).
// It stands up the on-die interrupt subsystem the bare-metal pirqsoc test needs:
//
//     +----------+   io_*  (PMIO)   +-----------+      irq_in[0]   +----------+
//     |          |<---------------->| PMIO dec  |                  |          |
//     |  core    |   intr  <--------|           |   int_out <------| ven_pic  |
//     | soc_en=1 |   inta   ------->|  ven_pic  |   inta    ------>| (8259A   |
//     |          |   inta_vector <--|  ven_pit  |   inta_vector <--|  master/ |
//     |          |                  |           |                  |  slave)  |
//     +----+-----+                  +-----+-----+                  +----+-----+
//          | mem_*                        | (0x40-0x43)                 ^ out0
//          v                              v                            /
//      (TB memory)                    +--------+   out0 -> irq_in[0]   /
//                                     |ven_pit |----------------------/
//                                     | (8254) |
//                                     +--------+
//
// DESIGN CONTRACT (the M8.1 deltas this top relies on, all PROVEN ADDITIVE in
// rtl/core/core.sv, gated on the NEW `soc_en` input — INERT in ventium_top):
//   * soc_en=1 turns ON the external-interrupt divert in the core's S_DECODE
//     priority chain (SMI > NMI > maskable INTR), driving the EXISTING verified
//     S_INT_GATE -> S_INT_CS -> S_INT_PUSH IDT delivery FSM via the int_sw=0
//     hardware-fault entry. A maskable INTR is taken only when EFLAGS.IF=1 and
//     the one-instruction STI/MOV-SS shadow is clear; the core pulses `inta` the
//     same clock and latches the PIC-supplied `inta_vector`.
//   * soc_en=1 also routes plain IN/OUT through the core's io_* seam (S_IO) so
//     the PMIO decoder below can service the PIC/PIT programming, EXCEPT the
//     `out 0xf4` isa-debug-exit terminator which still HALTs (no retire) — the
//     trace ends at the post-readback point, exactly like the qemu checkpoint.
//
// This top mirrors ventium_top's reset-init + the single DPI retire point so the
// SAME Verilator TB driver (a --soc mode that loads the bare-metal image, cold-
// resets at F000:FFF0, and serves mem_*) produces the system-mode retire trace.
// ventium_top is NOT modified — this is a separate, additional integration top.
//
// ventium_pkg is supplied on the build command line (single compilation unit).

`default_nettype none

module ventium_soc
  import ventium_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,     // active-low synchronous reset (core convention)

    // Reset-time architectural init (the TB drives these during reset). In SoC
    // mode the core boots in SYSTEM mode (boot_mode=1) so it cold-resets at
    // CS:EIP=F000:FFF0 itself; init_eip/init_esp are carried for parity with
    // ventium_top (the system reset seeds CS:EIP/regs internally).
    input  logic [31:0] init_eip,
    input  logic [31:0] init_esp,

    // boot-mode select. The SoC bare-metal image is a -bios at F000:FFF0, so the
    // TB drives 1 (system cold reset). Default-carried so the port list matches
    // the TB's expectations; 0 would be the user cold reset (unused here).
    input  logic        boot_mode,

    // M0/M1 bus-functional-model memory port group (docs/rtl-interface.md §3).
    // The TB serves these from its flat memory (the BIOS image + RAM). The SoC
    // does NOT route memory through the PIC/PIT — those are PMIO-only devices.
    output logic        mem_req,
    output logic        mem_we,
    output logic [31:0] mem_addr,
    output logic [31:0] mem_wdata,
    output logic [3:0]  mem_wstrb,
    input  logic [31:0] mem_rdata,
    input  logic        mem_ack
);

  // ===========================================================================
  // Core retire payload (mirror ventium_top so the DPI hook is identical).
  // ===========================================================================
  logic        core_retire_valid;
  logic [31:0] core_retire_pc;
  arch_state_t core_retire_state;

  logic        core_x87_touched;
  logic [15:0] core_fctrl, core_fstat, core_ftag;
  logic [79:0] core_st0, core_st1, core_st2, core_st3;
  logic [79:0] core_st4, core_st5, core_st6, core_st7;

  logic        core_pipe_valid, core_paired;
  logic [1:0]  core_pipe;
  logic        core_retire2_valid, core_retire2_paired;
  logic [31:0] core_retire2_pc;
  logic [1:0]  core_retire2_pipe;
  arch_state_t core_retire2_state;

  logic        core_retire_sys;
  logic [31:0] core_cr0, core_cr2, core_cr3, core_cr4;

  // Core outputs the SoC does not consume (sunk in the lint block below).
  logic        core_cpu_hung;
  logic        core_syscall_active;
  logic [63:0] core_syscall_n;

  // ===========================================================================
  // Core <-> PMIO seam + interrupt wiring.
  // ===========================================================================
  // I/O bus (the core's existing IN/OUT seam, here consumed by the PMIO decoder
  // — NOT exposed at the top; the PIC/PIT live entirely inside the SoC).
  logic        io_req;
  logic        io_we;
  logic [15:0] io_addr;
  logic [2:0]  io_size;   // access width in BYTES (the test uses byte I/O only)
  logic [31:0] io_wdata;
  logic [31:0] io_rdata;
  logic        io_ack;

  // INTR/INTA handshake.
  logic        core_intr;        // ven_pic.int_out -> core.intr
  logic        core_inta;        // core.inta       -> ven_pic.inta
  logic [7:0]  pic_inta_vector;  // ven_pic.inta_vector -> core.inta_vector

  // PIT ch0 OUT -> PIC IRQ0.
  logic        pit_out0;
  logic [15:0] pic_irq_in;       // device IRQ lines IR0..IR15 (only IR0 = pit_out0)
  assign pic_irq_in = {15'd0, pit_out0};

  // ===========================================================================
  // The core: soc_en=1 (external-interrupt path LIVE), boot_mode from the port,
  // every other gated mode INERT (cosim/proxy/bus/cycle/errata all 0). The io_*
  // seam binds to the internal PMIO decoder; intr/inta/inta_vector to the PIC.
  // ===========================================================================
  core u_core (
      .clk          (clk),
      .rst_n        (rst_n),
      .init_eip     (init_eip),
      .init_esp     (init_esp),
      .boot_mode    (boot_mode),
      .cycle_mode   (1'b0),
      .errata_en    (5'd0),
      .cpu_hung     (core_cpu_hung),
      .proxy_en           (1'b0),
      .syscall_active     (core_syscall_active),
      .syscall_n          (core_syscall_n),
      .syscall_resume_eip (32'd0),
      .syscall_eax        (32'd0),
      .syscall_apply_gs   (1'b0),
      .syscall_gs_base    (32'd0),
      // The Win95 port-I/O seam is REUSED for the SoC PMIO bus, but cosim_en
      // stays 0: under soc_en the core executes IN/OUT through S_IO without the
      // co-sim's golden-replay semantics (the device data comes from the real
      // ven_pic/ven_pit on io_rdata, not a replayed stream).
      .cosim_en     (1'b0),
      .io_req       (io_req),
      .io_we        (io_we),
      .io_addr      (io_addr),
      .io_size      (io_size),
      .io_wdata     (io_wdata),
      .io_rdata     (io_rdata),
      .io_ack       (io_ack),
      // ---- M8.1 external-interrupt path: LIVE in the SoC -------------------
      .soc_en       (1'b1),
      .intr         (core_intr),
      .nmi          (1'b0),            // no NMI source in this SoC (tied off)
      .inta         (core_inta),
      .inta_vector  (pic_inta_vector),
      .inta_valid   (1'b1),            // the master 8259 always supplies a vector
      .mem_req      (mem_req),
      .mem_we       (mem_we),
      .mem_addr     (mem_addr),
      .mem_wdata    (mem_wdata),
      .mem_wstrb    (mem_wstrb),
      .mem_rdata    (mem_rdata),
      .mem_ack      (mem_ack),
      .retire_valid (core_retire_valid),
      .retire_pc    (core_retire_pc),
      .retire_state (core_retire_state),
      .retire_x87_touched (core_x87_touched),
      .retire_fctrl (core_fctrl),
      .retire_fstat (core_fstat),
      .retire_ftag  (core_ftag),
      .retire_st0   (core_st0), .retire_st1 (core_st1),
      .retire_st2   (core_st2), .retire_st3 (core_st3),
      .retire_st4   (core_st4), .retire_st5 (core_st5),
      .retire_st6   (core_st6), .retire_st7 (core_st7),
      .retire_pipe_valid (core_pipe_valid),
      .retire_pipe       (core_pipe),
      .retire_paired     (core_paired),
      .retire2_valid     (core_retire2_valid),
      .retire2_pc        (core_retire2_pc),
      .retire2_state     (core_retire2_state),
      .retire2_pipe      (core_retire2_pipe),
      .retire2_paired    (core_retire2_paired),
      .retire_sys        (core_retire_sys),
      .retire_cr0        (core_cr0),
      .retire_cr2        (core_cr2),
      .retire_cr3        (core_cr3),
      .retire_cr4        (core_cr4)
  );

  // ===========================================================================
  // PMIO DECODER (combinational, mirrors the mem_* single-beat protocol).
  //
  // The core raises io_req for the S_IO clock(s) of an IN/OUT with io_addr the
  // 16-bit port and io_we the direction. We route to:
  //   * ven_pic : 0x20/0x21 (master), 0xA0/0xA1 (slave), 0x4D0/0x4D1 (ELCR)
  //   * ven_pit : 0x40..0x43 (channels 0/1/2 + the mode/command register)
  // and ack combinationally (the value is ready the same clock). The selected
  // device's cs is asserted ONLY while io_req && that-port-decodes, so a write
  // commits exactly once (on the rising edge the core latches the ack). reads are
  // pure-combinational off the device registers (zero-extended into io_rdata).
  //
  // The isa-debug-exit `out 0xf4` never reaches here (the core HALTs it in
  // S_DECODE), and an undecoded port acks with rdata 0 (the test never reads one)
  // so the core never stalls.
  // ===========================================================================
  logic        cs_pic, cs_pit;
  always_comb begin
    cs_pic = io_req && (io_addr == 16'h0020 || io_addr == 16'h0021 ||
                        io_addr == 16'h00A0 || io_addr == 16'h00A1 ||
                        io_addr == 16'h04D0 || io_addr == 16'h04D1);
    cs_pit = io_req && (io_addr == 16'h0040 || io_addr == 16'h0041 ||
                        io_addr == 16'h0042 || io_addr == 16'h0043);
  end

  // PC RESET for the devices is synchronous active-HIGH; the core's rst_n is
  // active-low. (Held with the core during the TB's reset window.)
  logic dev_rst;
  assign dev_rst = ~rst_n;

  // device read-data (byte-wide; combinational off the registers).
  logic [7:0] pic_rdata;
  logic [7:0] pit_rdata;

  ven_pic u_pic (
      .clk         (clk),
      .rst         (dev_rst),
      .cs          (cs_pic),
      .we          (io_we),
      .addr        (io_addr),
      .wdata       (io_wdata[7:0]),     // byte I/O (outb/inb)
      .rdata       (pic_rdata),
      .irq_in      (pic_irq_in),
      .int_out     (core_intr),
      .inta        (core_inta),
      .inta_vector (pic_inta_vector)
  );

  // ven_pit: the PIT tick is prescaled DOWN from the core clk by PIT_TICK_DIV so
  // the IRQ0 cadence is far slower than the CPU instruction rate. This is purely
  // STRUCTURAL (the de-risk: the exact instruction boundary each IRQ0 hits is a
  // function of the PIT/CPU clock ratio and is NOT differential). It must only be
  // SLOW ENOUGH that between two IRQ0 edges the mainline runs the full IRQ0
  // handler (re-arm + EOI + IRET) AND at least one spin-loop check, so:
  //   (a) the mainline is never starved (it always makes forward progress), and
  //   (b) after the N-th delivery the mainline reaches the spin-exit + `cli`
  //       BEFORE the (N+1)-th edge, so the counter is read as EXACTLY N (the
  //       deterministic, boundary-independent post-spin state — matches qemu).
  // With clk ~8 cycles/instruction and the handler ~12 instructions, a tick of
  // 1024 core clocks (count 0x40 => ~65k clocks ≈ ~8k instructions per IRQ0)
  // gives a wide margin. The post-spin checkpoint is INDEPENDENT of this choice;
  // only the (excluded-from-differential) cadence depends on it.
  localparam int unsigned PIT_TICK_DIV = 1024;
  ven_pit #(.TICK_DIV(PIT_TICK_DIV), .TICK_INC(1)) u_pit (
      .clk    (clk),
      .rst    (dev_rst),
      .cs     (cs_pit),
      .we     (io_we),
      .addr   (io_addr),
      .wdata  (io_wdata[7:0]),
      .rdata  (pit_rdata),
      .out0   (pit_out0)
  );

  // I/O response back to the core: combinational ack the same clock io_req is
  // up; the read data is the selected device's byte zero-extended to 32 bits.
  always_comb begin
    io_ack   = io_req;                 // single-beat, every request acks at once
    io_rdata = 32'd0;
    if (cs_pic)      io_rdata = {24'd0, pic_rdata};
    else if (cs_pit) io_rdata = {24'd0, pit_rdata};
    // undecoded port: ack with 0 (the test never reads one; avoids a stall).
  end

  // ===========================================================================
  // Single DPI retire point (identical to ventium_top so the SAME TB emits the
  // system-mode .vtrace). The core pulses retire_valid for one clock per
  // committed instruction with the post-commit architectural state.
  // ===========================================================================
  logic [63:0] retire_n;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      retire_n <= 64'd0;
    end else if (core_retire_valid) begin
`ifndef VTM_NO_DPI
      if (core_retire_sys)
        vtm_retire_sys(retire_n, core_cr0, core_cr2, core_cr3, core_cr4);
      vtm_retire_x87(
          retire_n,
          {16'd0, core_fctrl}, {16'd0, core_fstat}, {16'd0, core_ftag},
          core_st0[63:0], core_st0[79:64], core_st1[63:0], core_st1[79:64],
          core_st2[63:0], core_st2[79:64], core_st3[63:0], core_st3[79:64],
          core_st4[63:0], core_st4[79:64], core_st5[63:0], core_st5[79:64],
          core_st6[63:0], core_st6[79:64], core_st7[63:0], core_st7[79:64]);
      if (core_pipe_valid)
        vtm_retire_cycle(retire_n, {30'd0, core_pipe}, {31'd0, core_paired});
      vtm_retire(
          retire_n,
          core_retire_pc,
          core_retire_state.eflags,
          core_retire_state.eax, core_retire_state.ecx,
          core_retire_state.edx, core_retire_state.ebx,
          core_retire_state.esp, core_retire_state.ebp,
          core_retire_state.esi, core_retire_state.edi,
          core_retire_state.cs,  core_retire_state.ss,
          core_retire_state.ds,  core_retire_state.es,
          core_retire_state.fs,  core_retire_state.gs);
      if (core_retire2_valid) begin
        vtm_retire_x87(
            retire_n + 64'd1,
            {16'd0, core_fctrl}, {16'd0, core_fstat}, {16'd0, core_ftag},
            core_st0[63:0], core_st0[79:64], core_st1[63:0], core_st1[79:64],
            core_st2[63:0], core_st2[79:64], core_st3[63:0], core_st3[79:64],
            core_st4[63:0], core_st4[79:64], core_st5[63:0], core_st5[79:64],
            core_st6[63:0], core_st6[79:64], core_st7[63:0], core_st7[79:64]);
        vtm_retire_cycle(retire_n + 64'd1, {30'd0, core_retire2_pipe},
                         {31'd0, core_retire2_paired});
        vtm_retire(
            retire_n + 64'd1,
            core_retire2_pc,
            core_retire2_state.eflags,
            core_retire2_state.eax, core_retire2_state.ecx,
            core_retire2_state.edx, core_retire2_state.ebx,
            core_retire2_state.esp, core_retire2_state.ebp,
            core_retire2_state.esi, core_retire2_state.edi,
            core_retire2_state.cs,  core_retire2_state.ss,
            core_retire2_state.ds,  core_retire2_state.es,
            core_retire2_state.fs,  core_retire2_state.gs);
      end
`endif
      retire_n <= retire_n + (core_retire2_valid ? 64'd2 : 64'd1);
    end
  end

  // ===========================================================================
  // Lint sinks — outputs the SoC does not consume + the x87/pipe payload that is
  // emitted via the DPI hook (read in the always_ff above, but flagged UNUSED by
  // -Wall when the DPI is compiled out / for the combinational fan-in).
  // ===========================================================================
  // verilator lint_off UNUSED
  wire _unused_soc = &{1'b0, core_x87_touched, io_size, pit_rdata, pic_rdata,
                       core_cpu_hung, core_syscall_active, core_syscall_n};
  // verilator lint_on UNUSED

endmodule : ventium_soc

`default_nettype wire
