=========================================================
Bus & peripheral system — theory of operation
=========================================================

This page explains *how the chipset actually works*: how the core reaches a
peripheral, how a register access is sequenced, how interrupts are delivered,
how DMA and memory-mapped devices behave, and how a device can be moved between
the PL fabric and the PS A53 without changing any of it. The high-level map is in
:doc:`/architecture`; the RTL-vs-software placement is in
:doc:`/soc/peripheral-split`.

.. graphviz:: /diagrams/ventium-soc.dot

.. contents::
   :local:
   :depth: 1

Two buses out of the core
=========================

Everything a program does that leaves the register file travels on one of **two
independent buses** the core (``core.sv``, ``soc_en=1``) exposes:

* **The memory bus** (``mem_*``) — every load/store and instruction fetch. A
  single-beat request/ack protocol: ``mem_req`` + ``mem_we`` + ``mem_addr`` +
  ``mem_wdata`` + ``mem_wstrb`` go out, ``mem_rdata`` + ``mem_ack`` come back.
  It feeds the L1 caches → the AXI master → PS-DDR (on the board) or the BFM
  memory (in the testbench).
* **The port-I/O bus** (``io_*``, the "PMIO" bus) — every ``IN``/``OUT``. The
  core raises ``io_req`` with ``io_addr`` (the 16-bit port), ``io_we`` (direction),
  ``io_size`` (1/2/4 bytes), and ``io_wdata``, then **parks in the ``S_IO`` state
  until ``io_ack``**.

The distinction matters: a *port* peripheral (PIC, PIT, UART, …) lives on the
port-I/O bus; a *memory-mapped* region (the VGA framebuffer at ``0xA0000``) lives
on the memory bus. They are decoded by different logic and never interfere.

Anatomy of a port-I/O transaction
=================================

``OUT 0x21, AL`` (mask the PIC) or ``IN AL, 0x60`` (read the keyboard) both run
the same cycle in ``ventium_soc``:

.. code-block:: text

   1. core decodes IN/OUT -> enters S_IO, drives io_req=1, io_addr=port,
      io_we=dir, io_wdata=data.  The core is now STALLED.
   2. ventium_soc's PMIO decoder (a big always_comb) computes one chip-select
      per device from io_addr:  cs_pic = io_req && (io_addr==0x20 || 0x21 || ...)
      cs_pit, cs_rtc, cs_uart, ...  At most one cs is high.
   3. the selected device sees cs=1 this clock: a WRITE commits on the posedge;
      a READ drives its register byte COMBINATIONALLY onto its rdata.
   4. a priority read-mux selects the live device:
        io_rdata = cs_pic ? pic_rdata : cs_pit ? pit_rdata : ... : 32'd0
      and io_ack = io_req (same-cycle), so the response is ready THIS clock.
   5. at the posedge the core latches io_rdata (for an IN) and leaves S_IO ->
      the instruction retires.  An undecoded port acks with 0 (never stalls).

So a port access is **one clock** in the common case. The core stalling on
``io_ack`` is the hook that lets a slow device take longer (DMA, or a PS-offloaded
device — see below) without any change to the core.

The device interface contract
==============================

Every port peripheral (``rtl/soc/ven_*.sv``) presents the same small interface,
so the decoder treats them uniformly:

.. code-block:: systemverilog

   module ven_<dev> (
     input  clk, rst,            // rst is synchronous, ACTIVE-HIGH (PC RESET)
     input  cs,                  // the SoC asserts this only on a port hit
     input  we,                  // 1 = OUT (CPU write), 0 = IN (CPU read)
     input  [15:0] addr,         // the I/O port (device decodes the offset)
     input  [7:0]  wdata,
     output [7:0]  rdata,        // COMBINATIONAL off the registers
     // + device-specific outputs (irq lines, the A20 gate, a tx byte, ...)
   );

Two rules make these models bit-exact and same-cycle:

* **Reads are combinational** off the registered state (``rdata`` is valid the
  clock ``cs`` is up), so ``io_ack`` can be combinational.
* **Read side-effects are clocked.** A read that mutates state (the UART LSR
  clear, the RTC ``REG_C`` read-then-clear, the 8042 OBF dequeue, the FDC FIFO
  advance, the VGA DAC auto-increment) applies that change on the posedge where
  ``cs && !we``, exactly once per access. Writes commit on the posedge where
  ``cs && we``. This is the "combinational value, clocked effect" split that
  keeps a read both same-cycle and side-effect-correct.

Memory-mapped devices and A20
=============================

Not every device is a port. The VGA **framebuffer** is the mode-13h pixel memory
at ``0xA0000``: it is spliced into the **memory** path. When the VGA is in
chain-4 mode, ``ventium_soc`` decodes core memory accesses in
``0xA0000–0xAFFFF`` to ``ven_vga_fb`` (intercepting ``mem_rdata`` for that
aperture and routing writes to the VRAM) instead of backing RAM; outside that
mode the region is ordinary memory. The same splice pattern is how a future
memory-BAR device (a framebuffer/MMIO PCI card) would attach.

**A20.** Before the memory request leaves the SoC it passes the classic A20 gate:
``eff_a20 = kbc_a20 | p92_a20`` (the 8042 output-port A20 bit OR the port-92
bit 1). When A20 is masked, physical address bit 20 is forced low — the 1 MiB
wraparound — exactly as the real chipset does.

Interrupt delivery
==================

A peripheral signals work with an **IRQ line**. The lines are gathered into a
16-bit vector and fed to the cascaded 8259A pair:

.. code-block:: text

   pit_out0  -> IR0     uart  -> IR4     rtc   -> IR8 (slave)
   kbd       -> IR1     fdc   -> IR6     mouse -> IR12 (slave)
   ide       -> IR14/15 (slave, polled/nIEN -> quiescent)
        |
        v
   ven_pic (8259A master + slave cascade, 0x20/0x21 + 0xA0/0xA1)
        |  int_out (INTR)
        v
   core:  takes INTR only when EFLAGS.IF=1 and no STI/MOV-SS shadow ->
          pulses inta -> the PIC supplies inta_vector -> the core runs the
          EXISTING IDT delivery FSM (the same S_INT_GATE -> S_INT_CS -> push
          path a hardware fault uses).

The core's decode priority is **SMI > NMI > maskable INTR**. Several IRQ lines
are wired but driven quiescent (the polled IDE channels, a PS-placed device's
tied-off IRQ), so they are present for a real workload yet cannot perturb the
single-step differential — qemu's gdbstub masks async IRQ during single-step, so
the directed tests run with interrupts disabled by construction.

Direct memory access (DMA)
==========================

Two DMA mechanisms coexist:

* **Legacy 8237 DMA** (``ven_i8237`` ×2, channels 0–7). The CPU programs the
  channel base address/count, mode, and mask through the port-I/O bus
  (``0x00–0x0F`` + page registers, and the secondary at ``0xC0–0xDF``). The
  register surface (the LSB/MSB flip-flop, status, mask, page registers) is what
  the SoC models; the *actual transfer* (a device asserting DREQ) is the
  oracle boundary.
* **IDE bus-master DMA**. ``ven_ide``'s DMA engine has its own memory-master port
  (``ide_dma_mem_*``) muxed into the shared ``mem_*`` bus by a 2-master priority
  selector. When the CPU launches a transfer (the BMIC-START ``OUT``), the SoC
  **holds ``io_ack=0`` for the whole burst** so the core parks in ``S_IO`` (its
  memory bus idle) while the DMA owns it — exactly qemu's synchronous
  ``bmdma_cmd_writeb``. This reuses the same stall-until-ack contract a normal
  port access relies on.

PCI configuration space
=======================

The SoC answers PCI config cycles through a small shim: ``CONFIG_ADDRESS``
(``0xCF8``, a dword latch) selects bus/devfn/register, and ``CONFIG_DATA``
(``0xCFC``) reads/writes the selected config dword. Today it implements the
single PIIX3 IDE function (so the BIOS can map the bus-master IDE BAR4); a device
with a programmable I/O BAR is then decoded like ``cs_bmide`` — gated on
``PCI_COMMAND.IO`` and the programmed BAR base. Generalising the shim to a full
per-devfn config space is the step a discoverable add-in card (e.g. a graphics
card) would need.

Moving a peripheral to the PS A53
=================================

Because the core **stalls until ``io_ack``**, a port peripheral does not have to
live in the PL at all. When a device is PS-placed, its port range is decoded into
``io_ps_sel`` and forwarded on the ``io_ps_*`` bridge to ``ven_soc_axil`` → the
A53, which runs the device's C model and acks back. The round-trip latency is
invisible to correctness — only the returned value matters — so the same
per-record differential holds. This is how the design fits the congestion-bound
KV260 fabric; the full mechanism, the config knob, and the verification are in
:doc:`/soc/peripheral-split`.

Boot
====

The bare-metal images boot the way a real PC does. The image is a BIOS at
``F000:FFF0``; the core cold-resets there in system mode (``boot_mode=1``),
transitions real → protected (``CR0.PE``, a CS far-jump to a flat 32-bit segment),
and — for a disk boot — chain-loads sector 0 from the IDE disk to ``0000:7C00``
and far-jumps into it (the ``pbootrm``/``pbootdma`` gates exercise exactly this).
From there it programs the chipset over the buses described above.

Why it is verifiable
====================

Every device interaction in this system is either **synchronous** (a register
``IN``/``OUT`` or an A20-masked memory access) or an explicitly-bounded
asynchronous path (a host-clock RTC tick, a DMA transfer, a device queue) that is
held quiescent. The synchronous surface single-steps deterministically, so each
peripheral is graded **per-record** against ``qemu-system-i386`` — the architectural
state after *every retired instruction* must match byte-for-byte. The same bar
applies whether a device runs in RTL or as a PS C model. The aggregate of these
gates is ``verif/soc/run-all-soc-gates.sh``.
