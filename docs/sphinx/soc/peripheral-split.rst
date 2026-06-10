==============================================================
SoC peripherals — configurable RTL (PL) / software (PS) split
==============================================================

Ventium boots as a PC: around the core sits a chipset of standard peripherals,
each a synthesizable ``ven_*`` RTL module, each verified **per-record bit-exact
against qemu-system-i386**. On the KV260 the PL fabric is routing/congestion
bound, so not every peripheral can live in hardware. This page describes the
**config-selectable split**: a single config file chooses, per peripheral,
whether it runs in **RTL (the PL fabric)** or as a **C model on the PS A53** —
*without changing any verification guarantee*.

.. contents::
   :local:
   :depth: 1

The chipset
===========

.. list-table::
   :header-rows: 1
   :widths: 16 16 22 16

   * - Device
     - RTL module
     - I/O ports
     - Per-record gate
   * - 8259 PIC
     - ``ven_pic``
     - 0x20/0x21, 0xA0/0xA1, 0x4D0/1
     - pirqsoc
   * - 8254 PIT
     - ``ven_pit``
     - 0x40–0x43
     - pirqsoc
   * - MC146818 RTC
     - ``ven_rtc``
     - 0x70/0x71
     - psocdev
   * - 8042 kbd/mouse
     - ``ven_i8042``
     - 0x60, 0x64
     - psocdev
   * - port-92 fast-A20
     - ``ven_port92``
     - 0x92
     - psocdev
   * - VGA registers
     - ``ven_vgaregs``
     - 0x3B0–0x3DF
     - pvga
   * - VGA framebuffer
     - ``ven_vga_fb``
     - mem 0xA0000 (mode 13h)
     - pvgafb
   * - ACPI PM timer
     - ``ven_acpipm``
     - 0x608
     - pvga
   * - IDE/ATA (+busmaster DMA)
     - ``ven_ide``
     - 0x1F0–7/0x3F6, 0x170–7/0x376
     - pide
   * - 16550 UART (COM1)
     - ``ven_uart16550``
     - 0x3F8–0x3FF
     - psocuart
   * - 8237 DMA ×2
     - ``ven_i8237`` ×2
     - 0x00–0x0F, 0xC0–0xDF, pages
     - psoc8237/b
   * - 82077 floppy (FDC)
     - ``ven_i8272``
     - 0x3F1–0x3F5, 0x3F7
     - psocfdc

Two buses, two offload mechanisms
=================================

The core exposes **two** independent buses, and only one of them is the
PS-offload "bridge":

* **Port I/O** (``io_*`` seam) — every ``IN``/``OUT`` raises ``io_req`` with the
  16-bit port and direction, and the core **stalls in ``S_IO`` until ``io_ack``**.
  This is the bus a PS-placed peripheral is forwarded on.
* **Memory** (``mem_*`` seam) — loads/stores go to the L1/AXI subsystem and
  PS-DDR. The VGA framebuffer splices into *this* path (it intercepts the
  0xA0000 mode-13h aperture); it is **not** part of the port-I/O bridge.

The port-I/O PS-offload bridge
------------------------------

``ventium_soc``'s PMIO decoder classifies each ``io_req`` port as either a local
RTL device (``cs_pic``, ``cs_uart``, …) **or** a PS-placed one (``io_ps_sel``,
computed from the ``+VEN_<DEV>_PS`` flags). When it is PS-placed:

.. code-block:: text

   core IN/OUT ──io_req──► ventium_soc PMIO decode ──io_ps_sel?──► io_ps_* ──►
        ▲                                                          ven_soc_axil
        │                                                          (AXI-Lite slave)
        └──────────────── io_ack / io_ps_rdata ◄───────────────────── A53 C model

``ven_soc_axil`` holds ``io_ack=0``, IRQs the PS GIC; the A53 reads the request
over AXI, runs the matching C model in ``sw/ps_periph/``, writes the result back,
and the bridge pulses ``io_ack=1`` with the data. **Because the core stalls until
``io_ack``, the A53 round-trip latency cannot change the instruction's result —
only the value matters** — which is exactly why the per-record differential is
unaffected by where a peripheral lives.

The same ``<dev>.c`` compiles into the **A53 firmware** (``gcc``, C) and into
``tb_soc`` (``g++``, C++) for verification — it is a 1:1 behavioural port of the
``ven_*.sv`` RTL.

Selecting the split
===================

``fpga/periph_split.config`` lists each peripheral and its placement:

.. code-block:: text

   pic     rtl    # bus-critical -> keep in PL
   pit     rtl
   port92  rtl
   ide     rtl
   dma     rtl
   dma2    rtl
   rtc     ps     # slow -> A53 C model
   i8042   ps
   vga     ps
   acpipm  ps
   uart    ps
   fdc     ps

``python3 fpga/scripts/gen_periph_split.py`` turns it into ``+VEN_<DEV>_PS``
RTL-build flags (``fpga/build/periph_split.vdefs``) and a C dispatch table
(``verif/tb/ps_periph_table.inc``). **With nothing marked ``ps`` the SoC is the
all-RTL build, byte-identical to before.** Each ``ps`` device is dropped from RTL
(``ifndef VEN_<DEV>_PS``), so its placement actually frees PL fabric; its port
range is decoded into ``io_ps_sel`` and forwarded to the C model.

Verification — "C model == RTL == qemu"
=======================================

Each C model is proven bit-exact with the **same per-record gate**, just with the
device served by the C model instead of the RTL module:

.. code-block:: console

   $ bash verif/soc/run-soc-ps-cosim-gate.sh uart   # build +VEN_UART_PS, run psocuart
   ...
   PS-OFFLOAD COSIM GATE (uart): EQUIVALENT (C model == RTL == qemu)

``run-soc-ps-cosim-all.sh`` runs them all; it is part of the soc-gate aggregate.

.. list-table::
   :header-rows: 1
   :widths: 14 22 16 12

   * - Device
     - C model
     - Test
     - Cosim
   * - uart
     - ``ven_uart16550.c``
     - psocuart
     - EQUIVALENT (110)
   * - rtc
     - ``ven_rtc.c``
     - psocdev
     - EQUIVALENT (122)
   * - i8042
     - ``ven_i8042.c``
     - psocdev
     - EQUIVALENT (122)
   * - acpipm
     - ``ven_acpipm.c``
     - pvga
     - EQUIVALENT (292)
   * - fdc
     - ``ven_i8272.c``
     - psocfdc
     - EQUIVALENT (116)
   * - vga
     - ``ven_vgaregs.c``
     - pvga
     - EQUIVALENT (292)

EQUIVALENT means the C model is byte-identical to qemu over every retired
instruction — the same bar the RTL module met.

Read side-effects and the bridge
--------------------------------

The bridge calls ``io_read`` **exactly once per access** (a ``ps_busy`` latch in
``tb_soc`` / the AXI handshake on the board), so a C model puts any *read
side-effect* inline — mirroring the RTL's clocked side-effect. Examples that must
match the RTL precisely: the UART LSR/MSR read-clears, the RTC ``REG_C``
read-then-clear, the 8042 OBF dequeue on a 0x60 read, the FDC FIFO advance, and
the VGA DAC-palette / ATTR flip-flop auto-increments.

Cross-domain couplings (board follow-ups)
=========================================

Three peripherals produce a **signal the PL consumes**, not just a read value.
When PS-placed, that signal must travel *back* from the A53 to the fabric (an
``io_ps``-class output path), which is a board-integration follow-up. The
register **differential is still EQUIVALENT** because each test keeps the
consuming logic consistent another way:

* **8042 → A20 gate.** ``eff_a20 = kbc_a20 | p92_a20``. ``psocdev`` drives both
  A20 sources together and keeps **port-92 in RTL**, so ``eff_a20`` tracks
  port-92; the tied-off ``kbc_a20`` is unobserved on the diff.
* **VGA regs → framebuffer mode bits.** ``ven_vga_fb`` derives ``chain4_en`` from
  ``ven_vgaregs``' SEQ/GFX bits. With the regs on PS those tie off
  (``chain4_en=0`` → the framebuffer is dormant), which is correct for ``pvga``
  (it never touches 0xA0000). A VGA-regs-PS **and** framebuffer-RTL board build
  needs the PS to drive the mode bits back.
* **Device IRQs.** A PS device's interrupt (UART IRQ4, RTC IRQ8, FDC IRQ6, …) is
  tied off in the PL; on the board the PS injects it through ``ven_soc_axil``.
  The differential tests run with interrupts disabled, so these lines are
  quiescent and do not perturb the per-record stream.

Adding a peripheral to PS
=========================

1. Port ``rtl/soc/ven_<dev>.sv``'s register logic to ``sw/ps_periph/<model>.c``
   (a plain-C, also-valid-C++ file with a ``<model>_new()`` ctor returning a
   ``ven_periph_t*``; copy ``ven_uart16550.c``).
2. Register it in ``tb_soc.cpp``'s ``ps_devs`` (port range → ctor) and add the
   row to ``PERIPH`` in ``gen_periph_split.py``.
3. Gate the RTL instance with ``ifndef VEN_<DEV>_PS`` (tie its outputs in the
   ``else`` arm) and add ``cs_<dev>`` to the ``io_ps_sel`` chain.
4. Flip the device to ``ps`` in ``fpga/periph_split.config`` and run
   ``bash verif/soc/run-soc-ps-cosim-gate.sh <dev>`` → EQUIVALENT.
