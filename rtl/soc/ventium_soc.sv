// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

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
    input  wire logic        clk,
    input  wire logic        rst_n,     // active-low synchronous reset (core convention)

    // Reset-time architectural init (the TB drives these during reset). In SoC
    // mode the core boots in SYSTEM mode (boot_mode=1) so it cold-resets at
    // CS:EIP=F000:FFF0 itself; init_eip/init_esp are carried for parity with
    // ventium_top (the system reset seeds CS:EIP/regs internally).
    input  wire logic [31:0] init_eip,
    input  wire logic [31:0] init_esp,

    // boot-mode select. The SoC bare-metal image is a -bios at F000:FFF0, so the
    // TB drives 1 (system cold reset). Default-carried so the port list matches
    // the TB's expectations; 0 would be the user cold reset (unused here).
    input  wire logic        boot_mode,

    // F3 TB keystroke injection (sim-only top; the KV260 bitstream does not use
    // this module). Tie kbd_inj_valid=0 for byte-identical default behavior.
    input  wire logic        kbd_inj_valid,
    input  wire logic [7:0]  kbd_inj_data,
    output logic             kbd_inj_ready,

    // M0/M1 bus-functional-model memory port group (docs/rtl-interface.md §3).
    // The TB serves these from its flat memory (the BIOS image + RAM). The SoC
    // does NOT route memory through the PIC/PIT — those are PMIO-only devices.
    output logic        mem_req,
    output logic        mem_we,
    output logic [31:0] mem_addr,
    output logic [31:0] mem_wdata,
    output logic [3:0]  mem_wstrb,
    input  wire logic [31:0] mem_rdata,
    input  wire logic        mem_ack,

    // PS-offload port-I/O bridge seam: when a peripheral is PS-placed (+VEN_<DEV>_PS,
    // fpga/periph_split.config), its I/O port range is NOT serviced by a local RTL
    // device — it is forwarded here (to ven_soc_axil -> the A53 C model on the board;
    // to the C dispatch in tb_soc for verification). io_ps_ack/io_ps_rdata return the
    // result; the core stalls in S_IO until io_ps_ack, so the model's latency cannot
    // perturb the per-record stream. INERT in the all-RTL default (io_ps_req tied 0).
    output logic        io_ps_req,    // a PS-placed port is being accessed this clock
    output logic        io_ps_we,
    output logic [15:0] io_ps_addr,
    output logic [7:0]  io_ps_wdata,
    input  wire logic [7:0]  io_ps_rdata,
    input  wire logic        io_ps_ack
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
    // M8.5 COM1 UART = ISA IRQ4. Quiescent on the differential path (IER=0 / no
    // serial RX), like the IR1/IR8/IR12 precedent; live for board console use.
    pic_irq_in[4]     = uart_irq4;
    pic_irq_in[6]     = fdc_irq6;   // M8.9 floppy (quiescent on the diff: CLI)
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

  // ---- M8.4f memory bus: a 2-master priority mux (core vs IDE bus-master DMA) --
  // The single mem_* port to the TB is shared. The core's outputs are renamed
  // core_mem_*; the IDE DMA engine's master port is ide_dma_mem_*. While the DMA
  // is busy (ide_dma_busy) it OWNS the bus — and the core is parked in the held
  // BMIC-START OUT (io_ack gated below), so it is not issuing a memory request,
  // making a simple priority selector correct (no mid-beat corruption). The A20 gate
  // masks ONLY the core address (the DMA bypasses it — see the mem_addr assign below).
  logic [31:0] core_mem_addr;
  logic        core_mem_req, core_mem_we;
  logic [31:0] core_mem_wdata;
  logic [3:0]  core_mem_wstrb;
  logic        core_mem_ack;
  // M8.6: the core's read bus is the TB's mem_rdata EXCEPT when the M8.6 VGA
  // chain-4 framebuffer intercepts the access (cs_vram) -> then it is VRAM data.
  logic [31:0] core_mem_rdata;
  logic        ide_dma_busy;
  logic        ide_dma_mem_req, ide_dma_mem_we;
  logic [31:0] ide_dma_mem_addr, ide_dma_mem_wdata;
  logic [3:0]  ide_dma_mem_wstrb;

  // Two bus masters share the mem bus with the core: the IDE DMA (M8.4f) and the
  // fw_cfg DMA (F3). They are mutually exclusive; IDE has priority, then fw_cfg.
  assign mem_req        = ide_dma_busy ? ide_dma_mem_req   : fwcfg_dma_busy ? fwcfg_dma_mem_req   : core_mem_req;
  assign mem_we         = ide_dma_busy ? ide_dma_mem_we    : fwcfg_dma_busy ? fwcfg_dma_mem_we    : core_mem_we;
  assign mem_wdata      = ide_dma_busy ? ide_dma_mem_wdata : fwcfg_dma_busy ? fwcfg_dma_mem_wdata : core_mem_wdata;
  assign mem_wstrb      = ide_dma_busy ? ide_dma_mem_wstrb : fwcfg_dma_busy ? fwcfg_dma_mem_wstrb : core_mem_wstrb;
  // ack routing: to a DMA engine while it owns the bus, else to the core.
  assign core_mem_ack   = (ide_dma_busy || fwcfg_dma_busy) ? 1'b0 : mem_ack;
  // The CPU A20 gate masks ONLY the core's address; bus-master DMA addresses the
  // physical bus directly (qemu pci_dma_read/write bypass A20), so the DMA address is
  // muxed in UN-masked. (The <1MiB test buffer makes this a no-op, but it is the
  // faithful behavior — M8.4f review fold-back.)
  assign mem_addr = ide_dma_busy   ? ide_dma_mem_addr
                  : fwcfg_dma_busy ? fwcfg_dma_mem_addr
                  : (eff_a20 ? core_mem_addr : (core_mem_addr & ~32'h0010_0000));

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
      .mem_req      (core_mem_req),
      .mem_we       (core_mem_we),
      .mem_addr     (core_mem_addr),   // muxed (vs DMA) + A20-masked into mem_addr
      .mem_wdata    (core_mem_wdata),
      .mem_wstrb    (core_mem_wstrb),
      .mem_rdata    (core_mem_rdata),  // TB read bus, or VRAM data when cs_vram (M8.6)
      .mem_ack      (core_mem_ack),
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
  logic        cs_uart;                     // M8.5 COM1 UART (0x3F8..0x3FF)
  logic        cs_dma;                       // M8.7 8237 DMA ctrl0 (0x00-0x0F + pages)
  logic        cs_dma2;                      // M8.8 8237 DMA ctrl1 (0xC0-0xDF + pages)
  logic        cs_fdc;                       // M8.9 floppy controller (0x3F0-0x3F5,0x3F7)
  logic        cs_ide, cs_ide_ctl, cs_ide2, cs_ide2_ctl;
  logic        cs_pci_addr, cs_pci_data;   // M8.4f-pre: PCI config mechanism
  logic        cs_bmide;                    // M8.4f: bus-master IDE register block
  logic        cs_fwcfg_sel, cs_fwcfg_data; // F3: QEMU fw_cfg (0x510 sel / 0x511 data)
  logic        cs_fwdma_hi, cs_fwdma_lo;     // F3: fw_cfg DMA address (0x514 / 0x518)
  logic [31:0] ide_bm_rdata;                // M8.4f: BMIDE register read value
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
    // ---- M8.5 COM1 serial UART (NS16550A) ---------------------------------
    // The 8-register command block at 0x3F8..0x3FF (ISA IRQ4). Full window
    // selected; the device resolves the offset (addr[2:0]) + DLAB banking.
    cs_uart   = io_req && (io_addr >= 16'h03F8 && io_addr <= 16'h03FF);
    // ---- M8.7 8237 DMA controller 0 (channels 0-3) + AT page registers ----
    // Ports 0x00-0x0F (channel + control block) + the page registers qemu's
    // i8257 actually services (0x81/0x82/0x83/0x87 -> ch2/3/1/0). The unmapped
    // page ports (0x80/0x84-0x86) are NOT claimed (left to the default decode,
    // unchanged), matching qemu's portio registration exactly.
    cs_dma    = io_req && ((io_addr <= 16'h000F) ||
                           io_addr == 16'h0081 || io_addr == 16'h0082 ||
                           io_addr == 16'h0083 || io_addr == 16'h0087);
    // ---- M8.8 secondary 8237 (ctrl 1, channels 4-7, dshift=1) -------------
    // Channel+control block 0xC0-0xDF (registers 2-apart) + page regs at
    // 0x89/0x8A/0x8B/0x8F. Because dshift=1 cancels (init_chan <<1 vs read >>1),
    // the CPU-visible behaviour is identical to ctrl0 — a second ven_i8237 sees
    // the NORMALIZED address (0xC0-0xDF -> 0x00-0x0F via (a-0xC0)>>1; the page
    // ports -> 0x81/0x82/0x83/0x87 via 0x80|(a&7)).
    cs_dma2   = io_req && ((io_addr >= 16'h00C0 && io_addr <= 16'h00DF) ||
                           io_addr == 16'h0089 || io_addr == 16'h008A ||
                           io_addr == 16'h008B || io_addr == 16'h008F);
    // ---- M8.9 floppy controller (82077): 0x3F1-0x3F5 + 0x3F7. NOT 0x3F0, and
    // NOT 0x3F6 (that is the IDE alt-status, already decoded by cs_ide_ctl) —
    // matches qemu's FDC portio registration exactly.
    cs_fdc    = io_req && ((io_addr >= 16'h03F1 && io_addr <= 16'h03F5) ||
                           io_addr == 16'h03F7);
    // ---- M8.4 IDE/ATA primary channel -------------------------------------
    // Command block 0x1F0-0x1F7 + control block 0x3F6 (primary master, PIO).
    // The secondary channel (0x170-0x177/0x376) is decoded below (M8.4e).
    cs_ide     = io_req && (io_addr >= 16'h01F0 && io_addr <= 16'h01F7);
    cs_ide_ctl = io_req && (io_addr == 16'h03F6);
    // M8.4e secondary channel (empty ATAPI CD-ROM master): 0x170-0x177 + 0x376.
    cs_ide2     = io_req && (io_addr >= 16'h0170 && io_addr <= 16'h0177);
    cs_ide2_ctl = io_req && (io_addr == 16'h0376);
    // M8.4f-pre PCI config mechanism (PIIX3 IDE 00:01.1): CONFIG_ADDRESS (0xCF8,
    // dword) + CONFIG_DATA (0xCFC..0xCFF, 1/2/4-byte window). A minimal single-
    // function shim — just enough to map the bus-master IDE BAR4 (M8.4f).
    cs_pci_addr = io_req && (io_addr == 16'h0CF8);
    cs_pci_data = io_req && (io_addr >= 16'h0CFC && io_addr <= 16'h0CFF);
    // M8.4f bus-master IDE (BMIDE) register block: the 8-byte PRIMARY-channel window
    // at the PCI BAR4 base, decoded ONLY when PCI_COMMAND.IO (pci_cmd[0]) is set
    // (qemu unmaps the I/O BAR otherwise). bmide_base = pci_bar4[15:4]<<4; the
    // window base..base+7 -> io_addr[15:3] == {pci_bar4[15:4], 1'b0}.
    cs_bmide = io_req && pci_cmd[0] && (io_addr[15:3] == {pci_bar4[15:4], 1'b0});
    // F3 — QEMU fw_cfg (firmware config): 0x510 = selector (16-bit write), 0x511 =
    // data (read/write, auto-incrementing). SeaBIOS probes it via the "QEMU" signature.
    cs_fwcfg_sel  = io_req && (io_addr == 16'h0510);
    cs_fwcfg_data = io_req && (io_addr == 16'h0511);
    // fw_cfg DMA address register (BE64): high half at 0x514, low half at 0x518; the
    // low-half write triggers the transfer. (FW_CFG_ID=0x03 advertises this interface.)
    cs_fwdma_hi   = io_req && (io_addr == 16'h0514);
    cs_fwdma_lo   = io_req && (io_addr == 16'h0518);
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
  logic [7:0] uart_rdata;      // M8.5 COM1 UART byte read
  logic [7:0] dma_rdata;       // M8.7 8237 DMA ctrl0 byte read
  logic [7:0] dma2_rdata;      // M8.8 8237 DMA ctrl1 byte read
  logic [7:0] fdc_rdata;       // M8.9 floppy controller byte read
  logic       fdc_irq6;        // M8.9 floppy -> PIC IR6
  logic       uart_irq4;       // M8.5 COM1 -> master PIC IR4
  logic       uart_tx_valid;   // M8.5 THR-written strobe (board console seam)
  logic [7:0] uart_tx_data;
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
  // F3: overridable via +define so the FreeDOS sim can use a FAST timer (SeaBIOS's
  // yield/sti-hlt disk wait spins on the timer IRQ; at 1024 the IRQ0 period is ~67M
  // clk which is glacial + trips the TB quiescence detector). Absent => 1024 => the
  // pirqsoc gate is byte-identical. Sim-only (set only on the tb_soc Verilator line).
`ifndef VEN_PIT_TICK_DIV
  `define VEN_PIT_TICK_DIV 1024
`endif
  localparam int unsigned PIT_TICK_DIV = `VEN_PIT_TICK_DIV;
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
`ifndef VEN_RTC_PS
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
`else  // RTC on PS: the 0x70/0x71 range forwards to ven_rtc.c via the io-bridge.
  assign rtc_rdata = 8'h00; assign rtc_irq8 = 1'b0; assign rtc_nmi_dis = 1'b0;
`endif

  // 8042 PS/2 keyboard controller at 0x60 (data) / 0x64 (cmd/status).  Drives
  // IRQ1/IRQ12 + the A20 line (output-port bit1) + a CPU-reset request.  Its
  // keyboard/mouse OUTPUT-BUFFER path depends on an attached PS/2 device queue
  // (qemu-system populates it with async power-on bytes; this controller-only
  // model does not), so the per-record differential exercises ONLY the queue-
  // independent controller paths: the A20 enable/disable commands (0xDF/0xDD)
  // observed through the A20 mask, plus command writes that retire identically.
  // The OBF/data read path is covered by the standalone unit self-check — a
  // documented oracle boundary, like the LAPIC-eax-only / SMM-infeasible ones.
`ifndef VEN_I8042_PS
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
      .reset_req (kbd_reset_req),
      .inj_valid (kbd_inj_valid),
      .inj_data  (kbd_inj_data),
      .inj_ready (kbd_inj_ready)
  );
`else  // 8042 on PS: 0x60/0x64 forward to ven_i8042.c. NOTE the A20 gate output is
  // a PL-consumed signal — on the board the PS must drive the i8042 A20 state back
  // to eff_a20; here it ties off (port-92 still gates A20 in the diff, which drives
  // both A20 sources together, so the A20-mask test tracks port-92).
  assign kbd_rdata = 8'h00; assign kbd_irq1 = 1'b0; assign mouse_irq12 = 1'b0;
  assign kbc_a20 = 1'b0;    assign kbd_reset_req = 1'b0;
  assign kbd_inj_ready = 1'b0;   // no RTL kbd: TB injection unavailable
`endif

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
  // M8.5 COM1 serial UART (NS16550A) — 0x3F8..0x3FF, ISA IRQ4. The synchronous
  // register surface is per-record differentiable vs qemu-system (`psocuart`);
  // the RX/loopback/IRQ-delivery paths are the host-chardev oracle boundary (unit
  // self-check). The tx/rx seam is the real board-console hook: tx_valid/tx_data
  // stream THR bytes out (to a PS UART / FPGA pins) and rx_valid/rx_data feed
  // received bytes in. No serial input on the diff path -> rx held quiescent.
  // ===========================================================================
`ifndef VEN_UART_PS
  ven_uart16550 u_uart (
      .clk       (clk),
      .rst       (dev_rst),
      .cs        (cs_uart),
      .we        (io_we),
      .addr      (io_addr),
      .wdata     (io_wdata[7:0]),
      .rdata     (uart_rdata),
      .irq       (uart_irq4),
      .tx_valid  (uart_tx_valid),
      .tx_data   (uart_tx_data),
      .rx_valid  (1'b0),
      .rx_data   (8'h00)
  );
`else
  // UART is PS-placed: no RTL module; the cs_uart range forwards to the bridge.
  assign uart_rdata = 8'h00; assign uart_irq4 = 1'b0;
  assign uart_tx_valid = 1'b0; assign uart_tx_data = 8'h00;
`endif

  // ===========================================================================
  // M8.7 Intel 8237A DMA controller 0 (channels 0-3) + AT page registers. The
  // synchronous register surface (channel addr/count via the flip-flop, command/
  // status/mask/mode, page regs) is per-record differentiable vs qemu-system
  // (`psoc8237`); the actual DMA transfer / DREQ / TC is the oracle boundary.
  // ===========================================================================
  ven_i8237 u_dma (
      .clk   (clk),
      .rst   (dev_rst),
      .cs    (cs_dma),
      .we    (io_we),
      .addr  (io_addr),
      .wdata (io_wdata[7:0]),
      .rdata (dma_rdata)
  );

  // M8.9 floppy disk controller (82077) — 0x3F1-0x3F5 + 0x3F7.
`ifndef VEN_FDC_PS
  ven_i8272 u_fdc (
      .clk   (clk),
      .rst   (dev_rst),
      .cs    (cs_fdc),
      .we    (io_we),
      .addr  (io_addr),
      .wdata (io_wdata[7:0]),
      .rdata (fdc_rdata),
      .irq   (fdc_irq6)
  );
`else  // FDC on PS: 0x3F1-0x3F5+0x3F7 forward to ven_i8272.c.
  assign fdc_rdata = 8'h00; assign fdc_irq6 = 1'b0;
`endif

  // M8.8 secondary controller — same module, NORMALIZED address (dshift cancels).
  logic [15:0] dma2_addr;
  // page ports are 0x89/0x8A/0x8B/0x8F (< 0xC0); chan/cont is 0xC0-0xDF. (Both have
  // bit7=1, so use the 0xC0 boundary, not bit7, to tell them apart.)
  assign dma2_addr = (io_addr < 16'h00C0) ? (16'h0080 | {13'd0, io_addr[2:0]})  // page -> 0x8x
                                          : {12'd0, 4'((io_addr - 16'h00C0) >> 1)}; // chan/cont -> 0x0x
  ven_i8237 u_dma2 (
      .clk   (clk),
      .rst   (dev_rst),
      .cs    (cs_dma2),
      .we    (io_we),
      .addr  (dma2_addr),
      .wdata (io_wdata[7:0]),
      .rdata (dma2_rdata)
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
  logic [7:0] vga_seq_plane_mask, vga_seq_mem_mode, vga_gfx_mode, vga_gfx_misc;
`ifndef VEN_VGA_PS
  ven_vgaregs u_vga (
      .clk    (clk),
      .rst    (dev_rst),
      .cs     (cs_vga),
      .we     (io_we),
      .addr   (io_addr),
      .wdata  (io_wdata[7:0]),
      .rdata  (vga_rdata),
      .o_seq_plane_mask (vga_seq_plane_mask),
      .o_seq_mem_mode   (vga_seq_mem_mode),
      .o_gfx_mode       (vga_gfx_mode),
      .o_gfx_misc       (vga_gfx_misc)
  );
`else  // VGA registers on PS: 0x3B0-0x3DF forward to ven_vgaregs.c. The mode bits
  // feed the RTL chain-4 framebuffer (ven_vga_fb) — on the board the PS must drive
  // them back; here they tie off (chain4_en=0 -> the FB is dormant, which is fine
  // for the pvga register diff, but VGA-regs-PS + framebuffer-RTL needs the PS path).
  assign vga_rdata = 8'h00;
  assign vga_seq_plane_mask = 8'h00; assign vga_seq_mem_mode = 8'h00;
  assign vga_gfx_mode = 8'h00;       assign vga_gfx_misc = 8'h00;
`endif

  // ===========================================================================
  // M8.6 VGA mode-13h CHAIN-4 framebuffer (ven_vga_fb) — 64 KiB VRAM @ 0xA0000.
  // Spliced into the CPU memory path: when the VGA is in chain-4 mode and the
  // (A20-masked) core address falls in 0xA0000-0xAFFFF and no IDE DMA owns the
  // bus, the access is served by the VRAM module instead of backing RAM. The
  // intercept is GATED on chain4_en, so every non-chain-4 access (every existing
  // test/boot path) bypasses it untouched. Reads are combinational (single-beat).
  //
  // chain4_en mirrors qemu's chain-4 dispatch: SR4.CHN_4M (bit3) set AND the
  // memory-map window (GFX[6] bits 3:2) covers 0xA0000 (mode 0 = 0xA0000-0xBFFFF,
  // mode 1 = 0xA0000-0xAFFFF; both include this 64 KiB aperture).
  // ===========================================================================
  logic        chain4_en;
  logic        cs_vram;
  logic [31:0] vram_rdata;
  logic [15:0] masked_mem_addr;
  assign masked_mem_addr = mem_addr[15:0];   // window offset (0xA0000 base is 64K-aligned)
  assign chain4_en = vga_seq_mem_mode[3] && (vga_gfx_misc[3:2] inside {2'b00, 2'b01});
  assign cs_vram   = core_mem_req && !ide_dma_busy && chain4_en &&
                     (mem_addr >= 32'h000A_0000) && (mem_addr <= 32'h000A_FFFF);

  ven_vga_fb u_vga_fb (
      .clk        (clk),
      .rst        (dev_rst),
      .sel        (cs_vram),
      .we         (core_mem_we),
      .addr       (masked_mem_addr),
      .wdata      (core_mem_wdata),
      .wstrb      (core_mem_wstrb),
      .plane_mask (vga_seq_plane_mask[3:0]),
      .rdata      (vram_rdata),
      .scan_addr  (16'd0),          // board scan-out seam (PS/HDMI); idle in sim
      .scan_rdata (/* unconnected */)
  );

  // The core's read bus: VRAM data on a chain-4 framebuffer hit, else the TB's.
  assign core_mem_rdata = cs_vram ? vram_rdata : mem_rdata;

  // ACPI PM timer (PIIX4 PM base + 0x08 => 0x608).  Free-running 24-bit counter
  // derived from clk by a fractional accumulator (average rate PM_TIMER_FREQ).
  // Wired for connectivity + the OUT-0x608 write-inert differential; its READ
  // value is a documented oracle boundary (host-clock-derived + qemu's default
  // PM region disabled — see the M8.3 header note), covered by the standalone
  // ven_acpipm unit self-check.  Quiescent in the pvga differential.
`ifndef VEN_ACPIPM_PS
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
`else  // ACPI PM on PS: 0x608 forwards to ven_acpipm.c.
  assign acpipm_rdata = 8'h00; assign acpipm_rdata32 = 32'd0;
`endif

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
  // TB Makefile `soc:` target). DISK_SECTORS/CYLS/HEADS/SECS default to the pide
  // 64 KiB image geometry (qemu guess_chs_for_size(128) = 2/16/63) and are
  // OVERRIDABLE via +define (F3 FreeDOS boot needs a multi-MB disk). Verilator -G
  // can't reach a submodule param, so thread it through `ifndef-defaulted macros:
  // absent => 128/2/16/63 => the pide/pboot/seabios-boot gates are byte-identical;
  // the FreeDOS build passes e.g. +define+VEN_IDE_DISK_SECTORS=20160 (+CYLS=20).
  // SIM-ONLY: the macros are set only on the tb_soc Verilator line, never synthesis,
  // so the FPGA build keeps the 64 KiB disk.
`ifndef VEN_IDE_DISK_SECTORS
  `define VEN_IDE_DISK_SECTORS 128
`endif
`ifndef VEN_IDE_CYLS
  `define VEN_IDE_CYLS 2
`endif
`ifndef VEN_IDE_HEADS
  `define VEN_IDE_HEADS 16
`endif
`ifndef VEN_IDE_SECS
  `define VEN_IDE_SECS 63
`endif
  ven_ide #(.DISK_SECTORS(`VEN_IDE_DISK_SECTORS), .CYLS(`VEN_IDE_CYLS),
            .HEADS(`VEN_IDE_HEADS), .SECS(`VEN_IDE_SECS),
            .HAS_DMA(1'b1)) u_ide (
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
      .irq14  (ide_irq14),
      // M8.4f bus-master DMA: the BMIDE register block + the memory-master port.
      .cs_bm         (cs_bmide),
      .bm_wdata      (io_wdata),
      .bm_rdata      (ide_bm_rdata),
      .dma_busy      (ide_dma_busy),
      .dma_mem_req   (ide_dma_mem_req),
      .dma_mem_we    (ide_dma_mem_we),
      .dma_mem_addr  (ide_dma_mem_addr),
      .dma_mem_wdata (ide_dma_mem_wdata),
      .dma_mem_wstrb (ide_dma_mem_wstrb),
      .dma_mem_rdata (mem_rdata),
      .dma_mem_ack   (ide_dma_busy & mem_ack)   // ack only while the DMA owns the bus
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
      .irq14  (ide_irq15),
      // M8.4f: the secondary ATAPI CD has no bus-master DMA (HAS_DMA=0 -> the engine
      // is synthesized away and stays inert). The BMIDE/DMA outputs are intentionally
      // unconnected (the lint waiver scopes only these tie-offs).
      /* verilator lint_off PINCONNECTEMPTY */
      .cs_bm         (1'b0),
      .bm_wdata      (32'd0),
      .bm_rdata      (),
      .dma_busy      (),
      .dma_mem_req   (),
      .dma_mem_we    (),
      .dma_mem_addr  (),
      .dma_mem_wdata (),
      .dma_mem_wstrb (),
      /* verilator lint_on PINCONNECTEMPTY */
      .dma_mem_rdata (32'd0),
      .dma_mem_ack   (1'b0)
  );

  // ===========================================================================
  // M8.4f-pre — minimal PCI config shim (PIIX3 IDE function 00:01.1)
  // ---------------------------------------------------------------------------
  // The ONLY purpose is to map the bus-master IDE BAR4 (consumed by the M8.4f DMA
  // engine). Models exactly the b0/d1/f1 config registers a bare-metal driver
  // touches, with values empirically pinned to qemu-system-i386 8.2.2:
  //   reg 0x00 vendor/device = 0x70108086 (RO)
  //   reg 0x08 class/prog-if = 0x01018000 (class 0x0101 IDE, prog-if 0x80) (RO)
  //   reg 0x04 PCI_COMMAND   = R/W bits 0(IO)/1(MEM)/2(BUS-MASTER); reset 0x0000
  //   reg 0x20 BAR4          = R/W, low 4 bits read-only (bit0=1 I/O ind, 16-byte
  //                            region); reset 0x00000001; write 0xC000 -> 0xC001
  // CONFIG_ADDRESS[31]=enable, [23:16]=bus, [15:11]=dev, [10:8]=fn, [7:2]=reg.
  // Sub-dword CONFIG_DATA access: the core masks io_rdata to io_size on a read and
  // supplies the byte/word in io_wdata on a write (the test writes PCI_COMMAND as a
  // word and BAR4/CONFIG_ADDRESS as dwords). M8.5 generalizes the single-function
  // shim into a bus-0 enumeration: a per-devfn config table for the chipset-core
  // functions qemu's -machine pc creates (00:00.0 i440FX host, 00:01.0 PIIX3 ISA,
  // 00:01.1 IDE, 00:01.3 PIIX4-PM, 00:02.0 std-VGA) — vendor/device, status|command,
  // class, header-type (incl the 0x80 multifunction bit), subsystem; only the IDE
  // function's command + BAR4 are R/W. Any other devfn / bus!=0 / disabled reads
  // 0xFFFFFFFF (the absent-function reply). DEFERRED (a controlled enumeration never
  // reads them, so they cannot diverge): the e1000 NIC (00:03.0) + cap-list, the VGA
  // /e1000 memory BARs, and the chipset quirk registers (PAM/SMRAM/PIRQ/PMBASE).
  logic [31:0] pci_cfg_addr;     // CONFIG_ADDRESS latch (0xCF8)
  logic [15:0] pci_cmd;          // PCI_COMMAND (IDE reg 0x04 low word; R/W)
  logic [31:0] pci_bar4;         // IDE BAR4 (reg 0x20; R/W)
  // a config access targets bus 0 with the enable bit set; pci_devfn selects the
  // function, pci_reg the dword register.
  wire         pci_sel   = pci_cfg_addr[31] && (pci_cfg_addr[23:16] == 8'h00);
  wire [7:0]   pci_devfn = pci_cfg_addr[15:8];
  wire [7:0]   pci_reg   = {pci_cfg_addr[7:2], 2'b00};   // dword register number

  always_ff @(posedge clk) begin
    if (dev_rst) begin
      pci_cfg_addr <= 32'd0;
      pci_cmd      <= 16'h0000;
      pci_bar4     <= 32'h0000_0001;   // I/O BAR, unmapped (bit0 = I/O indicator)
    end else begin
      if (cs_pci_addr && io_we) pci_cfg_addr <= io_wdata;          // outl 0xCF8
      else if (cs_pci_data && io_we && pci_sel && pci_devfn == 8'h09) begin
        // CONFIG_DATA write to the IDE function (00:01.1) — the ONLY writable function
        // here (all others are RO enumeration rows; writes to them are no-ops). The
        // core delivers the written byte/word/dword in io_wdata[low].
        if (pci_reg == 8'h04) pci_cmd  <= io_wdata[15:0] & 16'h0007;          // IO|MEM|MASTER
        if (pci_reg == 8'h20) pci_bar4 <= {io_wdata[31:4], 4'b0001};          // 16B I/O BAR
      end
    end
  end

  // combinational CONFIG_DATA read: a per-devfn config table for the modeled bus-0
  // functions (values empirically pinned to the live gate qemu). An absent devfn /
  // bus!=0 / disabled-mechanism reads 0xFFFFFFFF; an unmodeled register OF A PRESENT
  // function reads 0 (the controlled test reads only the modeled registers).
  logic [31:0] pci_cfg_rdata;
  always_comb begin
    pci_cfg_rdata = 32'hFFFF_FFFF;                       // absent function / bus!=0 / disabled
    if (pci_sel) begin
      unique case (pci_devfn)
        8'h00: unique case (pci_reg)                     // 00:00.0 i440FX host bridge
                 8'h00:   pci_cfg_rdata = 32'h1237_8086; // vendor/device
                 8'h08:   pci_cfg_rdata = 32'h0600_0002; // class (host bridge) / rev
                 8'h2C:   pci_cfg_rdata = 32'h1100_1AF4; // subsystem
                 default: pci_cfg_rdata = 32'h0000_0000;
               endcase
        8'h08: unique case (pci_reg)                     // 00:01.0 PIIX3 ISA bridge
                 8'h00:   pci_cfg_rdata = 32'h7000_8086;
                 8'h04:   pci_cfg_rdata = 32'h0200_0000; // status 0x0200 | command 0 (RO)
                 8'h08:   pci_cfg_rdata = 32'h0601_0000; // class (ISA bridge)
                 8'h0C:   pci_cfg_rdata = 32'h0080_0000; // header-type 0x80 (multifunction)
                 8'h2C:   pci_cfg_rdata = 32'h1100_1AF4;
                 default: pci_cfg_rdata = 32'h0000_0000;
               endcase
        8'h09: unique case (pci_reg)                     // 00:01.1 PIIX3 IDE (R/W cmd + BAR4)
                 8'h00:   pci_cfg_rdata = 32'h7010_8086;
                 8'h04:   pci_cfg_rdata = {16'h0280, pci_cmd}; // status 0x0280 | command (R/W)
                 8'h08:   pci_cfg_rdata = 32'h0101_8000; // class (IDE) / prog-if 0x80
                 8'h20:   pci_cfg_rdata = pci_bar4;       // BAR4
                 8'h2C:   pci_cfg_rdata = 32'h1100_1AF4;
                 default: pci_cfg_rdata = 32'h0000_0000;
               endcase
        8'h0B: unique case (pci_reg)                     // 00:01.3 PIIX4 ACPI/PM
                 8'h00:   pci_cfg_rdata = 32'h7113_8086;
                 8'h04:   pci_cfg_rdata = 32'h0280_0000; // status 0x0280 | command 0
                 8'h08:   pci_cfg_rdata = 32'h0680_0003; // class (other bridge) / rev
                 8'h2C:   pci_cfg_rdata = 32'h1100_1AF4;
                 8'h3C:   pci_cfg_rdata = 32'h0000_0100; // interrupt pin A (byte 0x3D=1)
                 default: pci_cfg_rdata = 32'h0000_0000;
               endcase
        8'h10: unique case (pci_reg)                     // 00:02.0 std-VGA
                 8'h00:   pci_cfg_rdata = 32'h1111_1234;
                 8'h08:   pci_cfg_rdata = 32'h0300_0002; // class (VGA display)
                 8'h2C:   pci_cfg_rdata = 32'h1100_1AF4;
                 default: pci_cfg_rdata = 32'h0000_0000;
               endcase
        default: pci_cfg_rdata = 32'hFFFF_FFFF;          // unmodeled devfn -> absent reply
      endcase
    end
  end

  // ===========================================================================
  // F3 — QEMU fw_cfg (firmware configuration interface), enough for SeaBIOS POST.
  // 0x510 = a 16-bit SELECTOR (write); 0x511 = a DATA port whose read returns the
  // next byte of the selected item and AUTO-INCREMENTS a per-item offset (reset by a
  // selector write). SeaBIOS detects it via the "QEMU" signature (item 0x0000) and
  // then reads small config items. Items are walked in via the SeaBIOS gap-diff:
  // each `fwcfg_byte` row is the EXACT byte stream qemu returns for that selector
  // (so the per-record differential stays bit-exact). The big blobs (file dir, ACPI,
  // SMBIOS) come later in POST and are added as the walk reaches them.
  //   item 0x0000 FW_CFG_SIGNATURE : "QEMU"        (4 bytes 0x51 0x45 0x4D 0x55)
  // A one-shot access pulse (io_req rising edge) drives the offset auto-increment so
  // it advances exactly once per access regardless of how long io_req is held.
  // ===========================================================================
  logic [15:0] fwcfg_sel;
  logic [15:0] fwcfg_off;
  logic        io_req_d;
  wire         io_acc = io_req && !io_req_d;          // one-shot per access

  // fw_cfg DMA engine (a bus master). On the 0x518 trigger it reads the 16-byte
  // FWCfgDmaAccess struct {control BE32, length BE32, address BE64} from guest memory
  // at the latched control address, decodes control (SELECT 0x08 / READ 0x02 /
  // SKIP 0x04 / WRITE 0x10), transfers `length` bytes of the selected item to the
  // target address (READ) or advances the offset (SKIP), and clears control back to 0.
  // The core is parked (io_ack held) for the whole transfer (synchronous, like the
  // IDE bus-master DMA). All struct fields are BIG-ENDIAN.
  typedef enum logic [2:0] { FWD_IDLE, FWD_C, FWD_L, FWD_AH, FWD_AL, FWD_X, FWD_WB } fwd_e;
  fwd_e         fwd_st;
  logic [31:0]  fwdma_actl;     // control-struct guest address (latched, native)
  logic [31:0]  fwdma_ctl, fwdma_len, fwdma_tgt, fwdma_xoff;
  logic         fwdma_pend;     // a 0x518 trigger is being served (hold the io ack)
  logic         fwcfg_dma_busy;
  logic         fwcfg_dma_mem_req, fwcfg_dma_mem_we;
  logic [31:0]  fwcfg_dma_mem_addr, fwcfg_dma_mem_wdata;
  logic [3:0]   fwcfg_dma_mem_wstrb;
  function automatic logic [31:0] bswap32(input logic [31:0] x);
    bswap32 = {x[7:0], x[15:8], x[23:16], x[31:24]};
  endfunction
  assign fwcfg_dma_busy = (fwd_st != FWD_IDLE);

  // byte stream per (selector, offset). Unmodeled item / past end -> 0x00.
  function automatic logic [7:0] fwcfg_byte(input logic [15:0] sel, input logic [15:0] off);
    fwcfg_byte = 8'h00;
    unique case (sel)
      16'h0000: unique case (off)                     // FW_CFG_SIGNATURE = "QEMU"
                  16'd0: fwcfg_byte = 8'h51;          // 'Q'
                  16'd1: fwcfg_byte = 8'h45;          // 'E'
                  16'd2: fwcfg_byte = 8'h4D;          // 'M'
                  16'd3: fwcfg_byte = 8'h55;          // 'U'
                  default: fwcfg_byte = 8'h00;
                endcase
      16'h0001: fwcfg_byte = (off == 16'd0) ? 8'h03 : 8'h00;  // FW_CFG_ID = 0x03 (trad+DMA)
      // Other items qemu's bare `-machine pc -m 32` exposes (file_dir count, numa,
      // max_cpus, acpi_tables, smbios_entries, ...) all read back 0 here -> the
      // default 0x00 already matches. Non-zero blobs are added as the walk reaches them.
      default: fwcfg_byte = 8'h00;
    endcase
  endfunction

  // CONFIG_DATA-style little-endian assembly for byte/word/dword reads at 0x511.
  wire [31:0] fwcfg_rdata = { fwcfg_byte(fwcfg_sel, fwcfg_off + 16'd3),
                              fwcfg_byte(fwcfg_sel, fwcfg_off + 16'd2),
                              fwcfg_byte(fwcfg_sel, fwcfg_off + 16'd1),
                              fwcfg_byte(fwcfg_sel, fwcfg_off + 16'd0) };

  // fw_cfg DMA engine bus-master memory drive (combinational; the FSM sequences it).
  always_comb begin
    fwcfg_dma_mem_req=1'b0; fwcfg_dma_mem_we=1'b0; fwcfg_dma_mem_addr=32'd0;
    fwcfg_dma_mem_wdata=32'd0; fwcfg_dma_mem_wstrb=4'b0000;
    unique case (fwd_st)
      FWD_C:  begin fwcfg_dma_mem_req=1'b1; fwcfg_dma_mem_addr=fwdma_actl;          end
      FWD_L:  begin fwcfg_dma_mem_req=1'b1; fwcfg_dma_mem_addr=fwdma_actl+32'd4;    end
      FWD_AH: begin fwcfg_dma_mem_req=1'b1; fwcfg_dma_mem_addr=fwdma_actl+32'd8;    end
      FWD_AL: begin fwcfg_dma_mem_req=1'b1; fwcfg_dma_mem_addr=fwdma_actl+32'd12;   end
      FWD_X:  begin fwcfg_dma_mem_req=1'b1; fwcfg_dma_mem_we=1'b1;          // 1 byte
                    fwcfg_dma_mem_addr  = fwdma_tgt + fwdma_xoff;
                    fwcfg_dma_mem_wstrb = 4'b0001;
                    fwcfg_dma_mem_wdata = {24'd0, fwcfg_byte(fwcfg_sel, fwcfg_off + fwdma_xoff[15:0])}; end
      FWD_WB: begin fwcfg_dma_mem_req=1'b1; fwcfg_dma_mem_we=1'b1;          // clear control
                    fwcfg_dma_mem_addr=fwdma_actl; fwcfg_dma_mem_wstrb=4'b1111; fwcfg_dma_mem_wdata=32'd0; end
      default: ;
    endcase
  end

  always_ff @(posedge clk) begin
    if (dev_rst) begin
      fwcfg_sel <= 16'd0; fwcfg_off <= 16'd0; io_req_d <= 1'b0;
      fwd_st <= FWD_IDLE; fwdma_actl<=32'd0; fwdma_ctl<=32'd0; fwdma_len<=32'd0;
      fwdma_tgt<=32'd0; fwdma_xoff<=32'd0; fwdma_pend<=1'b0;
    end else begin
      io_req_d <= io_req;
      // ---- non-DMA fw_cfg: selector write (0x510) + data-port auto-increment (0x511)
      if (io_acc && cs_fwcfg_sel && io_we) begin
        fwcfg_sel <= io_wdata[15:0];                  // outw 0x510: select item, rewind
        fwcfg_off <= 16'd0;
      end else if (io_acc && cs_fwcfg_data && !io_we) begin
        fwcfg_off <= fwcfg_off + {13'd0, io_size};    // a data read advances by io_size
      end
      // ---- DMA engine FSM (the 0x518 trigger starts it; mem_rdata returns reads) ----
      // (0x514, the address high half, is ignored: the carveout is < 4 GiB.)
      unique case (fwd_st)
        FWD_IDLE: if (io_acc && cs_fwdma_lo && io_we) begin
                    fwdma_actl <= bswap32(io_wdata);  // BE low half = the struct address
                    fwdma_xoff <= 32'd0; fwdma_pend <= 1'b1; fwd_st <= FWD_C;
                  end
        FWD_C:  if (mem_ack) begin fwdma_ctl <= bswap32(mem_rdata); fwd_st <= FWD_L;  end
        FWD_L:  if (mem_ack) begin fwdma_len <= bswap32(mem_rdata); fwd_st <= FWD_AH; end
        FWD_AH: if (mem_ack) begin                    /* address high (assumed 0) */ fwd_st <= FWD_AL; end
        FWD_AL: if (mem_ack) begin
                  fwdma_tgt <= bswap32(mem_rdata);    // address low half (the buffer)
                  if (fwdma_ctl[3]) begin fwcfg_sel <= fwdma_ctl[31:16]; fwcfg_off <= 16'd0; end // SELECT
                  if (fwdma_ctl[1] && fwdma_len != 32'd0) fwd_st <= FWD_X;            // READ
                  else begin
                    if (fwdma_ctl[2]) fwcfg_off <= fwcfg_off + fwdma_len[15:0];        // SKIP
                    fwd_st <= FWD_WB;
                  end
                end
        FWD_X:  if (mem_ack) begin
                  if (fwdma_xoff + 32'd1 >= fwdma_len) begin
                    fwcfg_off <= fwcfg_off + fwdma_len[15:0]; fwd_st <= FWD_WB;
                  end else fwdma_xoff <= fwdma_xoff + 32'd1;
                end
        FWD_WB: if (mem_ack) begin fwdma_pend <= 1'b0; fwd_st <= FWD_IDLE; end
        default: fwd_st <= FWD_IDLE;
      endcase
    end
  end

  // ---- PS-offload select: is the accessed port a PS-placed peripheral? -------
  // (Per +VEN_<DEV>_PS from fpga/periph_split.config. 0 in the all-RTL default.)
  logic io_ps_sel;
  always_comb begin
    io_ps_sel = 1'b0;
`ifdef VEN_PIC_PS    io_ps_sel = io_ps_sel | cs_pic;    `endif
`ifdef VEN_PIT_PS    io_ps_sel = io_ps_sel | cs_pit;    `endif
`ifdef VEN_RTC_PS    io_ps_sel = io_ps_sel | cs_rtc;    `endif
`ifdef VEN_I8042_PS  io_ps_sel = io_ps_sel | cs_i8042;  `endif
`ifdef VEN_PORT92_PS io_ps_sel = io_ps_sel | cs_port92; `endif
`ifdef VEN_VGA_PS    io_ps_sel = io_ps_sel | cs_vga;     `endif
`ifdef VEN_ACPIPM_PS io_ps_sel = io_ps_sel | cs_acpipm; `endif
`ifdef VEN_UART_PS   io_ps_sel = io_ps_sel | cs_uart;   `endif
`ifdef VEN_FDC_PS    io_ps_sel = io_ps_sel | cs_fdc;    `endif
  end
  // forward the PS-selected access to the bridge (ven_soc_axil / the TB C dispatch).
  assign io_ps_req   = io_req && io_ps_sel;
  assign io_ps_we    = io_we;
  assign io_ps_addr  = io_addr;
  assign io_ps_wdata = io_wdata[7:0];

  // I/O response back to the core: combinational ack the same clock io_req is
  // up; the read data is the selected device's byte zero-extended to 32 bits.
  always_comb begin
    // M8.4f: every I/O acks the same clock — EXCEPT the BMIC-START OUT that launches
    // a DMA, which is HELD (io_ack=0) for the whole burst so the core parks in S_IO
    // (mem bus free) until the engine completes, exactly like qemu's synchronous
    // bmdma_cmd_writeb. ide_dma_busy is high for the launch clock + the run.
    // A PS-placed port instead waits on the bridge's io_ps_ack with io_ps_rdata.
    // The fw_cfg DMA trigger (write 0x518) is held un-acked (fwdma_pend) for the whole
    // transfer, so the core's OUT completes only after the DMA finishes (synchronous,
    // like the IDE bus-master write held during ide_dma_busy).
    io_ack   = io_ps_sel ? io_ps_ack : (io_req && !ide_dma_busy && !fwdma_pend);
    // OPEN BUS: an unmodeled / unassigned port reads back all-ones on a real PC and
    // in qemu (unassigned_io_read returns ~0), NOT 0. SeaBIOS probes absent ports
    // (e.g. `in 0x402` for the debug console) and branches on 0xFF; a 0 default
    // diverged. The modeled-device arms below overwrite this for claimed ports. Only
    // the SoC top uses this decode (ventium_top/make verify never instances it), and
    // the M8 gates only read CLAIMED ports, so they are unaffected.
    io_rdata = 32'hFFFF_FFFF;
    if      (io_ps_sel) io_rdata = {24'd0, io_ps_rdata};
    else if (cs_pic)    io_rdata = {24'd0, pic_rdata};
    else if (cs_pit)    io_rdata = {24'd0, pit_rdata};
    else if (cs_rtc)    io_rdata = {24'd0, rtc_rdata};
    else if (cs_i8042)  io_rdata = {24'd0, kbd_rdata};
    else if (cs_port92) io_rdata = {24'd0, p92_rdata};
    else if (cs_uart)   io_rdata = {24'd0, uart_rdata};   // M8.5 COM1
    else if (cs_dma)    io_rdata = {24'd0, dma_rdata};    // M8.7 8237 DMA ctrl0
    else if (cs_dma2)   io_rdata = {24'd0, dma2_rdata};   // M8.8 8237 DMA ctrl1
    else if (cs_fdc)    io_rdata = {24'd0, fdc_rdata};    // M8.9 floppy controller
    else if (cs_vga)    io_rdata = {24'd0, vga_rdata};
    // ACPI PM: return the native 32-bit value ({8'h0,count[23:0]}) so a future
    // dword IN reads the counter. Off the differential surface (never read by
    // pvga); present for connectivity / unit-check parity.
    else if (cs_acpipm) io_rdata = acpipm_rdata32;
    // IDE: 16-bit value (data-port word for 0x1F0; zero-extended register byte
    // otherwise). The pide test reads the data port with `inw` (16-bit).
    else if (cs_ide || cs_ide_ctl)   io_rdata = {16'd0, ide_rdata};
    else if (cs_ide2 || cs_ide2_ctl) io_rdata = {16'd0, ide2_rdata};
    // M8.4f-pre PCI config: CONFIG_ADDRESS read-back (0xCF8) + the CONFIG_DATA
    // window (0xCFC). The byte offset WITHIN the selected dword is the CONFIG_DATA
    // port's low 2 bits (0xCFC+k reads byte k), so shift the dword right by 8*k
    // before the core masks it to io_size. SeaBIOS reads the device-ID word via
    // `inw 0xCFE` (offset 2) -> dword>>16; without the shift it got the vendor (off 0).
    // Offset-0 accesses (0xCFC, the pide test) are the shift==0 identity, unchanged.
    else if (cs_pci_addr)            io_rdata = pci_cfg_addr;
    else if (cs_pci_data)            io_rdata = pci_cfg_rdata >> {io_addr[1:0], 3'b000};
    else if (cs_bmide)               io_rdata = ide_bm_rdata;   // M8.4f BMIDE regs
    else if (cs_fwcfg_data)          io_rdata = fwcfg_rdata;    // F3 QEMU fw_cfg data
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
                       rtc_nmi_dis, p92_reset_req, kbd_reset_req, acpipm_rdata,
                       uart_tx_valid, uart_tx_data};
  // verilator lint_on UNUSED

endmodule : ventium_soc

`default_nettype wire
