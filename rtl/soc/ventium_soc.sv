// ventium_soc.sv — Ventium SoC integration top.
//   M8.1: core + 8259 PIC + 8254 PIT (the on-die interrupt subsystem).
//   M8.2: + MC146818 RTC (0x70/0x71), 8042 keyboard ctrl (0x60/0x64),
//         port-92 fast-A20 (0x92), and the combined A20 address mask.
//   M8.3: + VGA register file (0x3B0..0x3DF) and ACPI PM timer (0x608).
//         This wires the last two built-but-unwired device models, completing
//         the 7-device set. The VGA register file is FULLY per-record
//         differentiable vs qemu-system (ATTR/MISC/SEQ/DAC/GFX/CRTC/IS1 with
//         write masks + the mono/color port aliasing), gated by the synchronous
//         `pvga` test. The ACPI PM timer is wired for connectivity but its READ
//         is a documented oracle boundary: qemu's default `-machine pc` leaves
//         the PIIX4 PM I/O region DISABLED (PMBASE unprogrammed -> 0x608 reads
//         0xFFFFFFFF as unassigned I/O), and even when enabled the PM-timer
//         value is host-clock-derived (not reproducible by a clk-sampled model)
//         -- exactly like the 8042-OBF host-queue boundary. Only the write-inert
//         + non-HALT property of an OUT 0x608 is differentiable (a no-op in BOTH
//         qemu (unassigned-write-ignored) and the RTL (acpi_pm_tmr_write does
//         nothing)); the value-read is covered by the standalone ven_acpipm unit
//         self-check (verif/soc/run_acpipm.sh). The pvga differential never READS
//         0x608, so the PM timer stays quiescent and cannot perturb the compare.
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

  // ---- device interrupt lines into the cascaded PIC (IR0..IR15 levels) -------
  // M8.1: PIT ch0 OUT -> master IR0.  M8.2 adds: i8042 keyboard -> master IR1,
  // MC146818 RTC -> slave IR8 (cascaded through master IR2), i8042 mouse ->
  // slave IR12.  IR1/IR8/IR12 have no autonomous stimulus in this minimal SoC
  // (no key/mouse event source; the psocdev test leaves the RTC interrupt
  // enables off), so they sit quiescent — the wiring is connectivity toward a
  // future keystroke / RTC-periodic workload, while the IR0 delivery path is the
  // one structurally exercised (the pirqsoc gate).  Quiescent inputs cannot
  // perturb the M8.2 per-record device-register differential.
  logic        pit_out0;     // PIT ch0 OUT  -> IR0
  logic        rtc_irq8;     // RTC          -> IR8  (slave)
  logic        kbd_irq1;     // i8042 kbd    -> IR1
  logic        mouse_irq12;  // i8042 mouse  -> IR12 (slave)
  logic        ide_irq14;    // primary IDE   -> IR14 (M8.4; polled-quiescent)
  logic        ide_irq15;    // secondary IDE -> IR15 (M8.4e; polled-quiescent)
  logic [15:0] pic_irq_in;
  always_comb begin
    pic_irq_in        = 16'd0;
    pic_irq_in[0]     = pit_out0;
    pic_irq_in[1]     = kbd_irq1;
    pic_irq_in[8]     = rtc_irq8;
    pic_irq_in[12]    = mouse_irq12;
    // M8.4 primary IDE = ISA IRQ14 (pci.c port_info {0x1f0,0x3f6,14}). The pide
    // test sets nIEN, so ide_irq14 stays 0 (polled) — connectivity toward a
    // future interrupt-driven IDE workload, exactly like the IR1/IR8/IR12
    // quiescent precedent; a quiescent input cannot perturb the differential.
    pic_irq_in[14]    = ide_irq14;
    pic_irq_in[15]    = ide_irq15;   // secondary IDE (slave-PIC IR7); quiescent (nIEN)
  end

  // ---- A20 gate (M8.2) -------------------------------------------------------
  // The classic PC A20 mask is the combination of the i8042 controller output-
  // port A20 bit and the port-92 "fast A20" bit; OR-combined here (the common
  // chipset gating).  The psocdev test always drives BOTH sources to the SAME
  // level, so this matches qemu-system's A20 line regardless of QEMU's last-
  // writer-wins detail, and at reset the i8042 (outport=0xCF, A20=1) holds A20
  // ENABLED — matching qemu's CPU a20_mask=~0 at reset.  When A20 is masked,
  // physical address bit 20 is forced low (the 1 MiB wraparound) on the core's
  // OUTGOING bus.  This is value-faithful: dcache_timing carries no data (load
  // data always returns via mem_rdata for the masked address), so a masked load
  // reads the wrapped location exactly as qemu-system does.
  logic        kbc_a20;      // i8042 output-port A20 bit (1 = A20 enabled)
  logic        p92_a20;      // port-92 bit1
  logic        eff_a20;      // effective A20 enable (1 = bit20 passes)
  assign eff_a20 = kbc_a20 | p92_a20;

  // core physical address before the A20 mask; the masked address leaves the SoC.
  logic [31:0] core_mem_addr;
  assign mem_addr = eff_a20 ? core_mem_addr
                            : (core_mem_addr & ~32'h0010_0000);

  // Device side outputs the M8.2 SoC observes but does not act on (yet):
  //  * rtc_nmi_dis : RTC index-port bit7 (NMI mask). NMI is tied off in this SoC.
  //  * *_reset_req : port-92 / i8042 CPU-reset request pulses. A live machine
  //    reset is not modeled here (the bare-metal psocdev never asserts them);
  //    they are surfaced + lint-sunk, to be wired to a reset controller later.
  logic        rtc_nmi_dis;
  logic        p92_reset_req;
  logic        kbd_reset_req;

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
      .mem_addr     (core_mem_addr),   // A20-masked into mem_addr below
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
  logic        cs_pic, cs_pit, cs_rtc, cs_i8042, cs_port92, cs_vga, cs_acpipm;
  logic        cs_ide, cs_ide_ctl, cs_ide2, cs_ide2_ctl;
  always_comb begin
    cs_pic = io_req && (io_addr == 16'h0020 || io_addr == 16'h0021 ||
                        io_addr == 16'h00A0 || io_addr == 16'h00A1 ||
                        io_addr == 16'h04D0 || io_addr == 16'h04D1);
    cs_pit = io_req && (io_addr == 16'h0040 || io_addr == 16'h0041 ||
                        io_addr == 16'h0042 || io_addr == 16'h0043);
    // ---- M8.2 PC-peripheral device selects --------------------------------
    cs_rtc    = io_req && (io_addr == 16'h0070 || io_addr == 16'h0071);
    cs_i8042  = io_req && (io_addr == 16'h0060 || io_addr == 16'h0064);
    cs_port92 = io_req && (io_addr == 16'h0092);
    // ---- M8.3 device selects ----------------------------------------------
    // VGA legacy register window (0x3B0..0x3DF) — the SAME window qemu's std-vga
    // decodes; the device internally returns 0xFF for the mono/color-aliased
    // invalid sub-range (matching qemu's vga_ioport_invalid), so the full window
    // is selected and the device resolves validity.
    cs_vga    = io_req && (io_addr >= 16'h03B0 && io_addr <= 16'h03DF);
    // ACPI PM timer (PIIX4 PM base 0x600 + 0x08). Wired for connectivity; its
    // read is a documented oracle boundary (see the M8.3 header note) — the pvga
    // differential never reads it, only the write-inert OUT 0x608 is exercised.
    cs_acpipm = io_req && (io_addr == 16'h0608);
    // ---- M8.4 IDE/ATA primary channel -------------------------------------
    // Command block 0x1F0-0x1F7 + control block 0x3F6 (primary master, PIO).
    // The secondary channel (0x170-0x177/0x376) is decoded below (M8.4e).
    cs_ide     = io_req && (io_addr >= 16'h01F0 && io_addr <= 16'h01F7);
    cs_ide_ctl = io_req && (io_addr == 16'h03F6);
    // M8.4e secondary channel (empty ATAPI CD-ROM master): 0x170-0x177 + 0x376.
    cs_ide2     = io_req && (io_addr >= 16'h0170 && io_addr <= 16'h0177);
    cs_ide2_ctl = io_req && (io_addr == 16'h0376);
  end

  // PC RESET for the devices is synchronous active-HIGH; the core's rst_n is
  // active-low. (Held with the core during the TB's reset window.)
  logic dev_rst;
  assign dev_rst = ~rst_n;

  // device read-data (byte-wide; combinational off the registers).
  logic [7:0] pic_rdata;
  logic [7:0] pit_rdata;
  logic [7:0] rtc_rdata;
  logic [7:0] kbd_rdata;
  logic [7:0] p92_rdata;
  logic [7:0] vga_rdata;       // M8.3 VGA register-file byte read
  logic [7:0] acpipm_rdata;    // M8.3 ACPI PM byte view (unused on the diff path)
  logic [31:0] acpipm_rdata32; // M8.3 ACPI PM native 32-bit value ({8'h0,count})
  logic [15:0] ide_rdata;      // M8.4 IDE: data-port word, else {8'h0,regbyte}
  logic [15:0] ide2_rdata;     // M8.4e secondary IDE (empty ATAPI CD)

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

  // ===========================================================================
  // M8.2 PC-peripheral devices (RTC + 8042 keyboard + port-92 A20).
  // ===========================================================================
  // MC146818 RTC/CMOS at 0x70 (index) / 0x71 (data).  TICK_DIV is set huge so
  // the (un-oracled, host-clock-derived) structural tick effectively never fires
  // during the short psocdev run — and in any case the differential reads only
  // TIME-INVARIANT registers (REG_D=0x80, REG_B, index-read=0xFF, a scratch CMOS
  // byte round-trip), never the time bytes / REG_A.UIP / REG_C flags, so the
  // tick can never perturb the per-record compare.
  ven_rtc #(.TICK_DIV(32'd1_193_182)) u_rtc (
      .clk         (clk),
      .rst         (dev_rst),
      .cs          (cs_rtc),
      .we          (io_we),
      .addr        (io_addr),
      .wdata       (io_wdata[7:0]),
      .rdata       (rtc_rdata),
      .irq8        (rtc_irq8),
      .nmi_disable (rtc_nmi_dis)
  );

  // 8042 PS/2 keyboard controller at 0x60 (data) / 0x64 (cmd/status).  Drives
  // IRQ1/IRQ12 + the A20 line (output-port bit1) + a CPU-reset request.  Its
  // keyboard/mouse OUTPUT-BUFFER path depends on an attached PS/2 device queue
  // (qemu-system populates it with async power-on bytes; this controller-only
  // model does not), so the per-record differential exercises ONLY the queue-
  // independent controller paths: the A20 enable/disable commands (0xDF/0xDD)
  // observed through the A20 mask, plus command writes that retire identically.
  // The OBF/data read path is covered by the standalone unit self-check — a
  // documented oracle boundary, like the LAPIC-eax-only / SMM-infeasible ones.
  ven_i8042 u_i8042 (
      .clk       (clk),
      .rst       (dev_rst),
      .cs        (cs_i8042),
      .we        (io_we),
      .addr      (io_addr),
      .wdata     (io_wdata[7:0]),
      .rdata     (kbd_rdata),
      .irq1      (kbd_irq1),
      .irq12     (mouse_irq12),
      .a20_gate  (kbc_a20),
      .reset_req (kbd_reset_req)
  );

  // Port-92 "fast A20" / System Control Port A at 0x92.
  ven_port92 u_port92 (
      .clk       (clk),
      .rst       (dev_rst),
      .cs        (cs_port92),
      .we        (io_we),
      .addr      (io_addr),
      .wdata     (io_wdata[7:0]),
      .rdata     (p92_rdata),
      .a20_gate  (p92_a20),
      .reset_req (p92_reset_req)
  );

  // ===========================================================================
  // M8.3 devices (VGA register file + ACPI PM timer).
  // ===========================================================================
  // VGA register file at the legacy 0x3B0..0x3DF window. CPU-observable register
  // set ONLY (no framebuffer/scan-out): ATTR/MISC/SEQ/DAC/GFX/CRTC/IS1 with the
  // per-index write masks and the mono/color port aliasing, matched to qemu
  // hw/display/vga.c (vga_ioport_read/write).  FULLY per-record differentiable vs
  // qemu-system (the `pvga` gate): the DAC 3-byte auto-increment, the ATTR
  // index/data flip-flop, and the IS1 dumb-retrace toggle are all DETERMINISTIC
  // (state-machine, not host-clock), and cs pulses exactly one clock per S_IO
  // access (io_ack=io_req), so the read side-effects commit exactly once.
  ven_vgaregs u_vga (
      .clk    (clk),
      .rst    (dev_rst),
      .cs     (cs_vga),
      .we     (io_we),
      .addr   (io_addr),
      .wdata  (io_wdata[7:0]),
      .rdata  (vga_rdata)
  );

  // ACPI PM timer (PIIX4 PM base + 0x08 => 0x608).  Free-running 24-bit counter
  // derived from clk by a fractional accumulator (average rate PM_TIMER_FREQ).
  // Wired for connectivity + the OUT-0x608 write-inert differential; its READ
  // value is a documented oracle boundary (host-clock-derived + qemu's default
  // PM region disabled — see the M8.3 header note), covered by the standalone
  // ven_acpipm unit self-check.  Quiescent in the pvga differential.
  ven_acpipm u_acpipm (
      .clk     (clk),
      .rst     (dev_rst),
      .cs      (cs_acpipm),
      .we      (io_we),
      .addr    (io_addr),
      .wdata   (io_wdata[7:0]),
      .rdata   (acpipm_rdata),
      .rdata32 (acpipm_rdata32)
  );

  // ===========================================================================
  // M8.4 IDE/ATA controller — primary channel, MASTER (unit 0), PIO mode.
  // ===========================================================================
  // Command block 0x1F0-0x1F7 + control block 0x3F6. One drive (the primary
  // master), PIO only (no DMA/PCI BAR4). FULLY per-record differentiable vs
  // qemu-system (the `pide` gate): the task-file registers + reset signature,
  // the IDENTIFY block, the READ SECTORS data (byte-identical to the single-
  // source disk image ven_ide $readmemh's + qemu -drive's), the absent-slave
  // masking, and DIAGNOSTIC. The disk hex path is supplied via the
  // -DVEN_IDE_DISK_HEX +define on the obj_dir_soc Verilator build line (the SoC
  // TB Makefile `soc:` target). DISK_SECTORS/CYLS/HEADS/SECS are pinned to the
  // pide 64 KiB image geometry (qemu guess_chs_for_size(128) = 2/16/63).
  ven_ide #(.DISK_SECTORS(128), .CYLS(2), .HEADS(16), .SECS(63)) u_ide (
      .clk    (clk),
      .rst    (dev_rst),
      .cs     (cs_ide),
      .cs_ctl (cs_ide_ctl),
      .we     (io_we),
      .addr   (io_addr),
      // 16-bit: the data port (0x1F0) carries a full word for WRITE SECTORS
      // (M8.4b, written via `outw`); the task-file registers use only [7:0].
      .wdata  (io_wdata[15:0]),
      .rdata  (ide_rdata),
      .irq14  (ide_irq14)
  );

  // M8.4e: the SECONDARY channel's master — the empty ATAPI CD-ROM qemu's
  // -machine pc auto-creates (ide1-cd0). IS_ATAPI=1 (0xEB14 signature, DIAGNOSTIC
  // status 0x00, IDENTIFY + all HD commands abort); HAS_DISK=0 (no media, so no
  // $readmemh — the disk[] array is allocated but never loaded or read). irq14
  // port carries IRQ15. The full ATAPI PACKET/IDENTIFY-PACKET surface is deferred.
  // DISK_SECTORS=128 matches the primary so the (unused) disk_byte index stays in
  // range; CYLS/HEADS/SECS are irrelevant (every CD data/IDENTIFY command aborts).
  ven_ide #(.DISK_SECTORS(128), .CYLS(2), .HEADS(16), .SECS(63),
            .IS_ATAPI(1'b1), .HAS_DISK(1'b0)) u_ide2 (
      .clk    (clk),
      .rst    (dev_rst),
      .cs     (cs_ide2),
      .cs_ctl (cs_ide2_ctl),
      .we     (io_we),
      .addr   (io_addr),
      .wdata  (io_wdata[15:0]),
      .rdata  (ide2_rdata),
      .irq14  (ide_irq15)
  );

  // I/O response back to the core: combinational ack the same clock io_req is
  // up; the read data is the selected device's byte zero-extended to 32 bits.
  always_comb begin
    io_ack   = io_req;                 // single-beat, every request acks at once
    io_rdata = 32'd0;
    if      (cs_pic)    io_rdata = {24'd0, pic_rdata};
    else if (cs_pit)    io_rdata = {24'd0, pit_rdata};
    else if (cs_rtc)    io_rdata = {24'd0, rtc_rdata};
    else if (cs_i8042)  io_rdata = {24'd0, kbd_rdata};
    else if (cs_port92) io_rdata = {24'd0, p92_rdata};
    else if (cs_vga)    io_rdata = {24'd0, vga_rdata};
    // ACPI PM: return the native 32-bit value ({8'h0,count[23:0]}) so a future
    // dword IN reads the counter. Off the differential surface (never read by
    // pvga); present for connectivity / unit-check parity.
    else if (cs_acpipm) io_rdata = acpipm_rdata32;
    // IDE: 16-bit value (data-port word for 0x1F0; zero-extended register byte
    // otherwise). The pide test reads the data port with `inw` (16-bit).
    else if (cs_ide || cs_ide_ctl)   io_rdata = {16'd0, ide_rdata};
    else if (cs_ide2 || cs_ide2_ctl) io_rdata = {16'd0, ide2_rdata};
    // undecoded port: ack with 0 (the tests never read one; avoids a stall).
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
                       core_cpu_hung, core_syscall_active, core_syscall_n,
                       rtc_nmi_dis, p92_reset_req, kbd_reset_req, acpipm_rdata};
  // verilator lint_on UNUSED

endmodule : ventium_soc

`default_nettype wire
