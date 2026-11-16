=========================================================
Bus & Peripheral Theory of Operation
=========================================================

This page documents how the Ventium P5/P54C processor communicates with system
memory, programmed I/O (PMIO), interrupts, DMA, and Zynq UltraScale+ management
services on the **RK-XCZU15EG-F** (``xczu15eg-ffvb1156-2-i``, Vivado **2025.2**,
board-qualified image ``c0e3fe43``, ``40.264133 MHz`` post-route STA
sign-off, ``0.515778001`` total U+V / ``0.397847833`` primary/U Quake gameplay
IPC across cycles ``28,696,827,616–32,989,404,795``). See :doc:`/architecture`
for the top-level block map and :doc:`/soc/peripheral-split` for the division
of work between PL RTL and the Cortex-A53 PS.

.. graphviz:: /diagrams/ventium-soc.dot

.. contents::
   :local:
   :depth: 1

Two CPU bus seams: AXI4 memory & PMIO port I/O
==============================================

Every off-core transaction leaving ``ventium_top`` / ``ventium_l1_axi`` travels
on one of two independent interfaces:

* **64-bit AXI4 Memory Master** (``ven_axi_master.sv`` behind ``ven_l1d.sv`` and
  ``icache.sv``) — carries 32-byte burst cache-line fills, write-back evictions,
  and byte-exact non-cacheable (UC) MMIO reads/writes. Non-cacheable reads are
  fragmented into aligned power-of-two single-beat ``AR`` requests with exact
  ``ARSIZE`` so adjacent device lanes are never disturbed and no transaction
  crosses a 4 KiB page boundary.
* **Port-I/O Seam** (``io_*``) — carries ``IN``, ``OUT``, ``INS``, and ``OUTS``
  transactions (16-bit port address, 1/2/4-byte width, read/write strobes). The
  core parks in ``S_IO`` until the platform returns ``io_ack`` and after any
  required external memory drain completes.

Deployed PC/AT chipset integration (``ven_ao486_shim`` + ``ao486_MiSTer``)
==========================================================================

In both ``ao486-sim/`` and the RK-XCZU15EG-F FPGA build (``rtl_ven_core.f`` +
``rtl_ven_soc.f``), ``ao486-sim/ven/ven_ao486_shim.sv`` and
``ven_axi2avalon.sv`` replace the 486 CPU inside ``3rd-party/ao486_MiSTer/rtl/system.v``:

* **Full PC/AT Peripherals in PL RTL:** Cascaded ``8259A`` master/slave PICs
  (``0x20``/``0xA0``), ``8254`` PIT (``0x40–0x43``), dual ``8237`` DMA
  controllers (``0x00–0x0F``, ``0xC0–0xDF`` + page registers), ``MC146818``
  RTC/CMOS (``0x70``/``0x71``), ``8042`` PS/2 keyboard & mouse controller
  (``0x60``/``0x64``) + Port-92 fast-A20 (``0x92``), primary/secondary IDE
  (``0x1F0``/``0x170``) and floppy (``0x3F0–0x3F7``), full SVGA/VGA planar &
  linear controller (``0x3B0–0x3DF``, ``0xA0000–0xBFFFF``), and Sound Blaster 16
  + Yamaha OPL3 FM synthesis (``0x220``/``0x388``).
* **No Enabled Outer L2:** The ``ao486`` chipset's legacy outer L2 cache wrapper
  is bypassed; the deployed hardware relies exclusively on Ventium's full P5
  **8 KiB L1 I-Cache**, **8-bank 8 KiB L1 D-Cache**, and the 16-slot posted DDR4
  bridge below.
* **Physical Snoop Coherence & A20:** DMA writes and self-modifying CPU stores
  snoop both ``ven_l1d`` and ``icache`` using physical page tags (``ic_ptag``),
  avoiding linear-alias staleness across paging remaps. Changes to the combined
  8042/Port-92 A20 gate trigger ``a20_flush`` across executable caches.

16-slot posted DDR4 bridge & external-drain barrier
===================================================

``fpga/ven_ddram_axi_posted.sv`` sits between the PC/AT memory arbiter (running
on ``mmcm_clk``, ``40.000 MHz`` nominal) and the ZynqMP ``128-bit @ 100 MHz``
``S_AXI_HP0_FPD`` port (mapped to the ``256 MiB`` Linux ``no-map`` reserved DDR4
window ``0x6000_0000–0x6FFF_FFFF``):

1. **16-Slot Posted Write Queue & RAW CAM Bypass:** Cache writebacks and burst
   stores enqueue into a 16-entry FIFO so the CPU/L1D is not stalled on full
   ZynqMP DDR4 write round-trips. Incoming DDR reads probe a content-addressable
   comparator (CAM) across all 16 in-flight posted slots, forwarding or draining
   matching addresses so read-after-write order is exact.
2. **True Architectural Drain Barrier:** Because posted write acceptance is
   **not** external DDR4 ``BVALID`` completion, Ventium preserves a strict
   hardware drain/fault barrier before serializing boundaries — specifically
   **port I/O (IN/OUT), PS-initiated debug halts, guest resets, and
   runtime MMCM clock changes** (``50440003`` drained status check).

Interrupt delivery (``INTR`` / ``INTA``)
========================================

Peripheral IRQ lines (PIT ``IRQ0``, PS/2 keyboard ``IRQ1`` & mouse ``IRQ12``,
floppy ``IRQ6``, Sound Blaster ``IRQ5``/``IRQ7``, RTC ``IRQ8``, IDE
``IRQ14``/``IRQ15``) feed the cascaded ``8259A`` pair in ``pic.v``:

.. code-block:: text

   Device IRQs ──► 8259A Master/Slave (pic.v) ──INTR──► ventium_top (core.sv)
                        ▲                                     │
                        └──────── INTA / 8-bit vector ◄───────┘

``core.sv`` arbitrates interrupts strictly at instruction boundaries with
architectural priority **SMI > NMI > maskable INTR** (honoring ``EFLAGS.IF`` and
``STI`` / ``MOV SS`` / ``POP SS`` inhibit shadows), completes the ``INTA``
vector handshake, and dispatches through the real-mode IVT or protected/V86-mode
IDT (including hardware stack switches via ``ven_frame_plan.sv``).

ZynqMP ``0xA000_0000`` management, media, & clock control
=========================================================

Rather than emulating PC/AT registers in software, the ZynqMP Cortex-A53 PS
services backing media and telemetry over two dedicated PL interfaces:

* **64 KiB AXI-Lite Aperture (M_AXI_HPM0_FPD @ 0xA000_0000,
  ven_mgmt_axil.v):** Drives the MiSTer ``mgmt_*`` bus to load BIOS/VGA ROMs
  and stream IDE/floppy sectors on demand, feeds hardware PS/2 keyboard & mouse
  injection mailboxes (``ven_ps2_mailbox.sv``), and exposes the ``ven_soc_dbg``
  on-die debug/PMU banks (64-bit ``primary/U`` and ``total U+V`` retirement
  counters, forensic freeze context, quiescent boundary halt/step/breakpoint,
  and AXI read/write profilers; see :doc:`/debug-instrumentation`).
* **Passive Framebuffer Capture (ven_video_capture.sv):** Taps rendered VGA
  frames into a 128-RAMB36 dual-port buffer for lossless RGB332 host streaming
  without perturbing CPU or DDR4 timing.
* **Programmable Core Clock (ven_pll_ctrl.sv):** Reprograms a dedicated
  ``MMCME4_ADV`` (``100 MHz * 10 / N``, boot ``N = 25`` → ``40.000 MHz``) via
  XAPP888 DRP over EMIO GPIO while guest reset is held and posted DDR4 writes
  are verified drained.

Historical standalone ``ventium_soc`` bring-up model
====================================================

During early bare-metal CPU bring-up (prior to integrating ``ao486_MiSTer``), a
lightweight single-clock ``ventium_soc`` wrapper paired ``ventium_top`` with
minimal ``ven_*`` register models (combinational ``rdata`` on ``cs && !we``,
clocked read/write side-effects on ``posedge clk``) so directed assembly tests
and ``test386`` could be compared per-instruction against ``qemu-system-i386``
with async IRQs masked. That bring-up harness has been retired on both
``main`` and ``experimental/uv-fast-ipc-apr`` in favor of the full PC/AT
platform documented above and the ``make verify`` / ``make verify-sys`` /
``ao486-sim`` verification suites.
