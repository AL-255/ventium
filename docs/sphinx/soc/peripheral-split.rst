==============================================================
SoC Peripherals: PL Hardware vs. PS Management Services
==============================================================

.. important::

   **Current Platform Architecture (`c0e3fe43` on RK-XCZU15EG-F):**
   On the current **RK-XCZU15EG-F** target (``xczu15eg-ffvb1156-2-i``, ``341,280``
   LUTs, Vivado **2025.2**), **100% of PC/AT chipset peripherals execute natively
   in PL RTL** inside the integrated MiSTer ``ao486`` platform
   (``rtl_ven_soc.f``, consuming just ``8,280`` LUTs / ``2.43%`` of the device).
   The earlier KV260 (``xck26``) ``VEN_<DEV>_PS`` port-I/O C-model offload bridge
   is **retired historical bring-up infrastructure** and is not part of the
   deployed ``c0e3fe43`` hardware profile.

.. contents::
   :local:
   :depth: 1

Deployed PL / PS division on RK-XCZU15EG-F
==========================================

Moving from the LUT-constrained KV260 to the **RK-XCZU15EG-F** allowed the
entire cycle-accurate PC/AT peripheral subsystem to reside in programmable logic
while reserving the ARM Cortex-A53 Processing System (PS) strictly for
out-of-band media backing, input injection, capture, and telemetry:

.. list-table:: Deployed ``c0e3fe43`` subsystem ownership (``40.264133 MHz`` STA-closed)
   :header-rows: 1
   :widths: 26 20 54

   * - Function
     - Domain
     - Implementation & Role
   * - **Interrupts, Timers & DMA**
     - **PL RTL** (``mmcm_clk``)
     - ``pic.v`` (dual 8259A), ``pit.v`` (8254), ``dma.v`` (dual 8237), ``rtc.v``
       (MC146818) — deterministic cycle-local ``IN``/``OUT`` & ``INTR``/``INTA``.
   * - **VGA & Audio**
     - **PL RTL** (``mmcm_clk``)
     - ``vga.v`` (planar/linear VGA + ``136.5`` BRAM36 chipset RAMs) and
       ``sound.v`` / ``opl3.sv`` / ``saa1099.sv`` (Sound Blaster 16 + OPL3).
   * - **PS/2 Keyboard & Mouse**
     - **PL RTL + PS Mailbox**
     - ``ps2.v`` + ``ven_ps2_device.sv`` run the 8042 protocol in PL; PS feeds
       queued Set-2 keystrokes and mouse packets via ``ven_ps2_mailbox.sv``
       (``0xA000_0380–0x4A0``) with zero CPU port-stall overhead.
   * - **IDE HDD & Floppy**
     - **PL RTL + PS Sector Backing**
     - ``ide.v`` and ``floppy.v`` implement ATA/FDC taskfiles and DMA in PL; a
       user-space PS daemon services sector requests over the ``mgmt_*`` bridge
       (``ven_mgmt_axil.v`` @ ``0xA000_0000``) against VHD/image files.
   * - **Main Memory (DDR4)**
     - **PL Posted Bridge → PS HP0**
     - ``ven_ddram_axi_posted.sv`` (16-slot posted write queue + RAW CAM bypass
       + external drain barrier) crosses ``128b @ 100 MHz`` into ZynqMP
       ``S_AXI_HP0_FPD`` (``0x6000_0000`` ``256 MiB`` ``no-map`` DDR4).
   * - **VGA Capture, Clock & PMU**
     - **PL Observers → PS HPM0/GPIO**
     - ``ven_video_capture.sv`` (128-RAMB36 passive RGB332 capture),
       ``ven_pll_ctrl.sv`` (EMIO GPIO MMCM DRP), and ``ven_soc_dbg.sv``
       (``primary/U`` & ``total U+V`` retirement counters and freeze/trace rings).

This clean hardware/host split enables cold Windows 95 OSR2 GUI interactive
sessions and DOS Quake ``timedemo demo1`` (``8.0 FPS`` at ``39.999802 MHz``,
**0.515778001 total U+V gameplay IPC** / ``0.397847833`` primary/U across
cycles ``28,696,827,616–32,989,404,795``) without A53 interrupt round-trips on
hot ``IN``/``OUT`` ports such as the PIT timer, PIC mask registers, VGA
sequencer/planar latches, or PS/2 status byte.

Historical KV260 PMIO PS-offload architecture (retired)
=======================================================

During early KV260 (``xck26-sfvc784-2LV-c``) bring-up, fabric congestion
motivated an optional per-peripheral compile-time split on the standalone
``ventium_soc`` wrapper:

* **Mechanism:** Because ``core.sv`` stalls in ``S_IO`` until ``io_ack`` asserts,
  the legacy PMIO decoder could forward selected port ranges (``+VEN_UART_PS``,
  ``+VEN_RTC_PS``, ``+VEN_I8042_PS``, ``+VEN_VGA_PS``, ``+VEN_FDC_PS``,
  ``+VEN_ACPIPM_PS``) across AXI-Lite to C device models running on the A53
  while keeping timing-critical devices (PIC, PIT, IDE, Port-92) in PL.
* **Why Instruction Differentials Stayed Exact:** Because ``S_IO`` blocked
  retirement until the A53 wrote back ``io_rdata`` and pulsed ``io_ack``,
  variable AXI-Lite service latency did not alter per-instruction architectural
  state, provided read side-effects (UART LSR clear, RTC ``REG_C`` clear, 8042
  OBF pop, VGA attribute flip-flop) executed once per bus transaction.
* **Why It Was Retired:** Forwarding VGA register writes, 8042 polling, and
  cross-domain A20/IRQ side-bands through A53 software serialized interactive OS
  workloads (Windows 95 and DOS games). Migrating to the RK-XCZU15EG-F and the
  integrated ``ao486_MiSTer`` PL chipset eliminated the PMIO software proxy
  entirely.
