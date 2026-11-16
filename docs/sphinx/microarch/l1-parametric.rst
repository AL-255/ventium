=================================================
P5 L1 Cache & Associative TLB Geometry
=================================================

.. important::

   **Deployed Hardware Policy (`c0e3fe43` on RK-XCZU15EG-F):**
   The deployed Ventium profile uses **full Pentium P5 8 KiB L1 instruction and
   8 KiB L1 data caches** (``128 sets × 2 ways × 32 B lines``) and **NO enabled
   L2 cache**, paired with a **32-entry 4-way I-TLB** (``VEN_ITLB_ASSOC_4WAY``)
   and a **64-entry 4-way D-TLB** (``VEN_DTLB_ASSOC_4WAY``). Legacy reduced-cache
   defines (``VEN_CACHE_HALF`` and ``VEN_IC_NARROWB``) are permanently retired,
   fail elaboration in ``ventium_top.sv``, and **must never be revived**.

Ventium's L1 instruction and data caches implement the silicon Pentium P5/P54C
geometry: **8 KiB, 2-way set-associative, 32-byte line, 128 sets, LRU**. Every
integrated RTL, full-PC cosimulation, differential gate, and RK-XCZU15EG-F FPGA
build is pinned to this exact geometry so cache-size artifacts can never be
mistaken for core IPC gains. On board-qualified image ``c0e3fe43``
(``40.264133 MHz`` post-route STA sign-off), this hierarchy delivers
**0.515778001 total U+V Quake gameplay IPC** (``0.397847833`` primary/U-only
across cycles ``28,696,827,616–32,989,404,795``; ``+3.88%`` over ``2886d24c``).

Integrated cache & TLB configuration
====================================

Each L1 cache stores ``128 sets × 2 ways × 32 B = 8,192 B (8 KiB)``, with no
on-die or outer L2 cache enabled:

.. list-table:: Deployed ``c0e3fe43`` L1 & TLB hierarchy
   :header-rows: 1
   :widths: 24 38 38

   * - Structure
     - Instruction Side (``icache.sv``)
     - Data Side (``ven_l1d.sv``)
   * - **L1 Capacity**
     - **8 KiB** (``8`` RAMB36 data + LUTRAM tags)
     - **8 KiB** (LUTRAM tags + **8-way 32-bit word-interleaved banks**)
   * - **Sets / Ways / Line**
     - ``128`` / ``2-way`` / ``32 B``
     - ``128`` / ``2-way`` / ``32 B``
   * - **Index / Tag Slice**
     - ``addr[11:5]`` / ``addr[31:12]`` (+ physical snoop ``ic_ptag``)
     - ``addr[11:5]`` / ``addr[31:12]``
   * - **Read / Write Policy**
     - Dual-window fetch + narrow 32 B ``ic_res_line_base`` + ``pf_fill_addr_rep[0..3]``
     - Dual-port U+V read hit return (``ven_p54_hit_return.sv``), write-back / write-allocate, UC byte-exact bypass
   * - **Translation (tlb_assoc.sv)**
     - **32-entry 4-way I-TLB** (``VEN_ITLB_ASSOC_4WAY``) + resident ``VEN_FE_PIPE`` slice
     - **64-entry 4-way D-TLB** (``VEN_DTLB_ASSOC_4WAY``, 4 KiB & 4 MiB PSE) + front-end D-TLB slice

Upgrading the I-TLB from a 16-entry direct-mapped array (``tlb.sv``, retained
only for zero-define unit tests) to the **32-entry 4-way set-associative I-TLB**
in ``tlb_assoc.sv`` eliminated cross-page code conflict thrashing in DOS Quake
and Windows 95 while preserving single-cycle hit lookup via one-hot hit-way
factoring.

Two-way P5 LRU replacement
==========================

Both ``icache.sv`` and ``ven_l1d.sv`` implement true 2-way LRU replacement
using a per-way age rank ``age[set][way] ∈ {0, 1}`` (``0`` = MRU, ``1`` = LRU
victim). Reset initializes ages to ``{0, 1}`` so way 1 is selected first on a
cold set (matching classic 1-bit ``victim = ~lru`` with ``lru = 0`` at reset),
and any hit or fill on way *k* promotes *k* to MRU while aging the sibling way.

Leaf-module parameterization vs. fixed processor geometry
=========================================================

While ``VEN_CACHE_HALF`` and processor-level cache-size overrides are prohibited
and rejected at elaboration, the standalone ``icache`` and ``ven_l1d`` leaf
modules retain Verilog parameters (``SETS``, ``WAYS``) purely so unit testbenches
(``make l1``) can exercise small synthetic configurations for fast eviction/snoop
corner testing and verify index/tag width scaling:

* **Processor & M5 Cycle Verification:** ``make verify`` and the M5 cycle-band
  gates certify the fixed **8 KiB / 2-way / 128-set** geometry (``mb_dmiss`` CPI
  ``2.504``, ``+0.10%`` vs. the ``p5trace`` oracle; ``mb_imiss`` CPI ``6.002``,
  ``+0.03%``).
* **Standalone Leaf Sanity Check:** In isolated leaf simulation on a 12 KiB
  3-line-per-set stride kernel, the silicon-accurate 8 KiB 2-way geometry
  exhibits the expected conflict thrash (CPI ``2.50``), whereas a synthetic
  16 KiB 4-way leaf test fits all three lines per set (CPI ``0.54``) with
  identical architectural CRCs.

Only the **8 KiB / 2-way / 128-set** L1 geometry with **no L2** is
silicon-faithful and permitted in integrated Ventium builds. See
:doc:`l1-cache-performance` for the 2-way working-set knee analysis and
:doc:`l2-cache` for why L2 remains uninstantiated.
