=================================================
UltraRAM L2 Cache Study (Uninstantiated)
=================================================

.. important::

   **Deployed Hardware Status (`c0e3fe43` on RK-XCZU15EG-F):**
   **No L2 cache is enabled or instantiated in Ventium.** Per project hardware
   policy, the deployed RK-XCZU15EG-F profile (``xczu15eg-ffvb1156-2-i``,
   ``40.264133 MHz`` post-route STA sign-off, ``0.515778001`` total U+V /
   ``0.397847833`` primary/U Quake gameplay IPC across cycles
   ``28,696,827,616–32,989,404,795``) uses **full Pentium P5 8 KiB L1
   instruction and 8-bank 8 KiB L1 data caches** directly feeding ``ven_axi_master``
   and the **16-slot posted DDR4 bridge** (``ven_ddram_axi_posted.sv``), with
   the outer ``ao486`` L2 wrapper bypassed and ``EN_L2=1`` elaboration-guarded
   off in ``ventium_l1_axi.sv``.

   This page preserves the standalone architectural and out-of-context (OOC)
   UltraRAM characterization of an optional 2 MiB backing-port L2 study block.

Where an L2 sits on the backing-port seam
=========================================

In the deployed ``VEN_L1_AXI`` memory hierarchy, ``ven_l1d`` already drives a
clean word/burst backing interface consumed by ``ven_axi_master`` and
``ven_ddram_axi_posted``::

   core mem_* ─► ven_l1d (8 KiB, WB) ─► ven_axi_master ─► ven_ddram_axi_posted ─► ZynqMP HP0 DDR4

The standalone ``ven_l2`` study block was designed as a transparent backing-port
filter (upstream slave ``u_*`` facing ``ven_l1d``, downstream master ``d_*``
facing ``ven_axi_master``)::

   ven_l1d.m_* ─► [u_*] ven_l2 (study) [d_*] ─► ven_axi_master.m_*

Because ``ven_l1d`` handles write-back/write-allocate caching, dual-port U+V
read hit return, and hit-under-ifill in the deployed ``c0e3fe43`` core while
``ven_ddram_axi_posted`` absorbs burst writebacks into a 16-slot posted queue
with CAM read-after-write bypass, physical DDR4 latency is hidden effectively
without adding an L2 lookup or coherence layer in front of DMA/MMIO.

UltraRAM array tiling (2 MiB / 8-way study geometry)
====================================================

The standalone study parameterized a **2 MiB, 32-byte line, 8-way
set-associative** write-back array mapped onto 64 ``URAM288`` primitives:

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Parameter
     - Study Value
   * - Capacity / Lines
     - ``2 MiB`` / ``32 B`` = ``65,536`` lines
   * - Data Array
     - ``65,536`` deep × ``256`` bits wide
   * - **URAM288 Tiling**
     - ``4`` URAM wide (64 data bits/tile + 8 spare ECC bits/tile) × ``16``-deep
       cascade = **64 URAM288** blocks
   * - Sets / Index / Tag
     - ``8,192`` sets (``addr[17:5]``), ``14``-bit tag (``addr[31:18]``)
   * - Metadata BRAM
     - ``8,192 × 135`` bits (``8 × {valid, dirty, tag14}`` + ``7``-bit tree-PLRU)

Microarchitectural properties studied
=====================================

* **Write-Back / Write-Allocate:** Store hits update the resident 256-bit URAM
  line in place and set ``dirty``; dirty victims write back 8 words before
  refilling.
* **Critical-Word / Forward-During-Fill:** Downstream read beats forward
  directly upstream (``u_ack = d_ack``) while populating the fill buffer.
* **Tree-PLRU Replacement:** Invalid ways fill first before consulting the 7-bit
  binary PLRU tree.
* **Post-Reset Tag Clear FSM:** Because UltraRAM and Block RAM lack global
  asynchronous reset, an initialization counter sweeps all sets clearing valid
  bits before asserting ``ready``.

Historical standalone OOC synthesis characterization
====================================================

Synthesized out-of-context (module standalone, ``RAM_RD_LAT=5``, Vivado 2025.2)
during early UltraScale+ sizing studies on an ``xck26-sfvc784-2LV-c`` target, the
isolated 2 MiB block closed post-route OOC timing at **155.0 MHz** (``WNS
+0.25 ns`` at ``6.7 ns`` target period; ``WHS +0.10 ns``), consuming ``64``
``URAM288``, ``34`` ``RAMB36E2``, ``2,250`` LUTs, ``1,261`` FFs, and ``0`` DSPs
(with ``URAM`` 16-high cascade read latency setting the OOC critical path).

Why the deployed platform omits L2
==================================

1. **Architectural Fidelity:** Real Socket 5/7 Pentium P5/P54C processors carry
   8 KiB on-die L1 I/D caches; external SRAM L2 resided on the motherboard
   northbridge (Intel 430FX/HX). Keeping the CPU subsystem strictly L1-only
   preserves clean P5 cache-timing semantics.
2. **Coherence & Non-DRAM Routing:** In the full MiSTer PC/AT platform, IDE/FDD
   DMA, planar VGA aperture accesses (``0xA0000–0xBFFFF``), PAM/TOM holes
   (``ven_cachemap.sv``), and physical I-cache snoops interact directly at the
   L1/AXI boundary; ``ventium_l1_axi.sv`` intentionally rejects ``EN_L2=1`` at
   elaboration (see ``docs/unsupported-isa.md`` §D) while ``ven_ddram_axi_posted``
   provides low-overhead posted DDR4 write buffering.

See :doc:`l1-parametric` and :doc:`l1-cache-performance` for the deployed 8 KiB
P5 L1 cache architecture.
