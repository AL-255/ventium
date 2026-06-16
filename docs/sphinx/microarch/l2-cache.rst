=================================================
UltraRAM L2 Cache
=================================================

The KV260 part (``xck26-sfvc784``) carries **64 UltraRAM blocks — 18 Mb** that
the integer core and its 8 KB L1s leave entirely idle. ``ven_l2`` turns all of
them into a large, write-back, set-associative **L2** that sits between the L1's
word-granular backing port and the PS-DDR4 AXI master, to **hide the long DDR
round-trip** behind a multi-megabyte on-chip working set. It is a **standalone**
block as of this drop — fully synthesizable and unit-checked, but nothing in the
core/SoC instantiates it yet; the RTL lives at ``rtl/northbridge/ven_l2.sv`` (the
memory-controller-hub home for the L2 and the DDR path), with the full design
blueprint in ``fpga/L2_DESIGN.md``.

Where it fits — a drop-in for the backing-port seam
===================================================

The memory subsystem already speaks **one** word-granular *backing port* that
``ven_l1d`` drives and ``ven_axi_master`` consumes::

   core mem_* ─► ven_l1d ─(backing port)─► ven_axi_master ─► AXI4 ─► PS-DDR

``ven_l2`` is a drop-in for that wire. It is a **slave** of the backing protocol
on its upstream port (``u_*``, so ``ven_l1d``'s master plugs straight in) and a
**master** of the same protocol on its downstream port (``d_*``, so
``ven_axi_master``'s slave plugs straight in)::

   ven_l1d.m_* ─► [u_*] ven_l2 [d_*] ─► ven_axi_master.m_*

Wiring it in later is therefore a **pure rewire** — no change to ``ven_l1d`` or
``ven_axi_master``. Because the L1 fill is *blocking*, the L2 only ever sees one
upstream transaction at a time, so it needs **no MSHR / hit-under-miss**: the
latency hiding comes from capacity, fast on-chip hits, and write-back absorption,
not request-level parallelism.

Geometry → exact UltraRAM tiling
================================

Defaults: **2 MiB, 32-byte line, 8-way**. The 32-byte line matches the L1 fill
granularity and the ``p5trace`` oracle line, so cache behaviour stays consistent
and one L2 miss is exactly one downstream fill. The data array tiles onto the
URAM column **perfectly**:

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Quantity
     - Value
   * - lines
     - 2 MiB / 32 B = 65536
   * - DATA array
     - 65536 deep × **256 bits** wide
   * - **URAM tiling**
     - 256 b = **4 URAM-wide** (64 data bits/tile; each URAM288 word is 72 b →
       4×8 = 32 spare parity bits/word, reserved for SECDED ECC) × 65536/4096 =
       **16 URAM-deep cascade** = **64 URAM288** (every block on the device)
   * - sets
     - 65536 / 8 = 8192 (index = ``addr[17:5]``)
   * - tag
     - ``addr[31:18]`` = 14 b
   * - META array
     - 8192 deep × 135 b BRAM: per set = 8 × ``{valid,dirty,tag14}`` + 7 tree-PLRU
       bits ≈ **1.1 Mb**

Vivado cascades URAM up to 16-high, so the data array maps to exactly **4 columns
× 16 = the 64 URAM288** on the part. Capacity / line / associativity are
parameters; the unit gates instantiate a tiny 1 KiB / 2-way L2 so init and
evictions simulate fast.

Microarchitecture
=================

* **Policy** — write-back, write-allocate. A store *hit* RMWs the resident line
  in place and marks it dirty (no DDR); a store *miss* fills then merges (no DDR
  write until eviction). A clean victim is dropped; a dirty victim is written
  back (8 word writes) before its slot is refilled. This **absorbs the L1's
  write-through store stream** — a dirty line reaches DDR once, on eviction, not
  per store.
* **Hit path** — serial **TAG → DATA**: read the indexed set's packed tags,
  compare all ways, then read the selected way's 256-bit line from URAM. A read
  hit streams the 8 words upstream; a write hit byte-writes the store into the
  line in place.
* **Read-miss path — forward-during-fill.** Each DDR word is handed straight to
  the L1 (``u_ack = d_ack``) *as it arrives* and simultaneously captured into the
  fill buffer, so the L2 adds ≈ 0 latency over a bare DDR fill while still
  populating itself for next time.
* **Replacement** — tree-PLRU, but an **invalid** way is always preferred (fill
  cold capacity before evicting anything).
* **Line-straddling stores** are split into line *L* and line *L+1* and run as
  two sequential transactions with a single upstream ack — mirroring the per-word
  split ``ven_axi_master`` does today, but at line granularity.
* **Init** — URAM/BRAM have no global reset, so an init FSM walks all sets
  clearing valid bits after reset; ``ready`` is low until done.

A stuck DDR is handled **out-of-band**: ``ven_axi_master`` raises its own sticky
``bus_err`` (it holds AXI ``VALID``, it does *not* synthesize an ack), and that
wires straight to the core's ``bus_err`` → ``S_HALT`` override — it is not part
of the backing-port wire the L2 splices into. The core halts and the PS resets
the PL, so a wedge in the L2 fill/writeback FSM is moot under that reset.

Verification
============

Three standalone Verilator gates (run from the repo root, all green with
``--assert``):

* ``verif/l1/run-l2-gate.sh`` — focused L2 logic against a synthetic DDR with a
  configurable per-word latency and access counters: hit = **0 DDR reads**,
  write-back = **0 DDR writes**, byte-correct dirty eviction, sub-word / unaligned
  / cross-line straddle stores, ``dirty == modified``, single-outstanding.
* ``verif/l1/run-l2-axi-gate.sh`` — **end-to-end through the real**
  ``ven_axi_master`` **+** ``axi_slave_bfm`` (RD/WR latency + a mid-burst RVALID
  bubble + the 32→40-bit remap): fills become one **INCR8** burst, dirty
  writebacks become single-beat writes, an L2 hit issues **no AR**.
* ``verif/l1/run-l2-stress-gate.sh`` — an **8× capacity overrun** that thrashes
  the cache (conflict + capacity misses, dirty-eviction churn), golden-checks
  every read, captures the DDR transaction trace, and a final cold-sweep flush
  proves the DDR backing equals the golden model **word-for-word — no dirty data
  lost** across the overrun (e.g. one run: 1449 fills, 656 writebacks, 65 KiB
  moved).

The design was hardened by a five-dimension adversarial review (backing-port
faithfulness, FSM liveness, cache correctness, URAM inference, protocol corners)
with every finding cross-checked by independent skeptics.

FPGA results — standalone OOC on the K26
========================================

Synthesized **out-of-context** (the module alone, no core/SoC — its ``u_*``/``d_*``
ports become OOC pins) and run all the way through **place + route** on
``xck26-sfvc784-2LV-c`` in Vivado 2025.2, default geometry (2 MiB / 8-way,
``RAM_RD_LAT=5``). Reproduce with::

   vivado -mode batch -source fpga/scripts/synth_l2_ooc.tcl -notrace -tclargs <period_ns>

**Fmax ≈ 155 MHz** (post-route). ``Fmax = 1 / (period − WNS)``:

.. list-table::
   :header-rows: 1
   :widths: 34 16 16 34

   * - Target period
     - WNS
     - Fmax
     - Note
   * - 6.7 ns (149 MHz)
     - **+0.25 ns**
     - **155.0 MHz**
     - meets timing — the trustworthy number
   * - 2.5 ns (400 MHz)
     - −4.18 ns
     - 149.8 MHz
     - over-constrained cross-check (agrees)

Hold is met (WHS +0.10 ns). **Area** (the block is almost pure memory):

.. list-table::
   :header-rows: 1
   :widths: 34 22 22 22

   * - Resource
     - Used
     - Available
     - Utilisation
   * - **URAM288**
     - **64**
     - 64
     - **100 %**
   * - Block RAM (RAMB36E2)
     - 34
     - 144
     - 23.6 %
   * - CLB LUTs
     - 2 250
     - 117 120
     - 1.92 %
   * - CLB Registers (FF)
     - 1 261
     - 234 240
     - 0.54 %
   * - CARRY8 / F7 mux
     - 14 / 46
     - —
     - ≈ 0.1 %
   * - DSP
     - 0
     - 1 248
     - 0 %

The headline is the **100 % URAM utilisation** — the whole point of the block,
now confirmed on silicon-accurate tooling: it consumes every one of the device's
64 UltraRAM blocks for 2 MiB of data, plus ~24 % of BRAM for tags + PLRU, behind
a tiny ~2 % LUT / 0.5 % FF control footprint and **zero DSP**.

The Fmax limiter — URAM cascade pipelining
==========================================

The critical path is the **URAM cascade read** (``l2_data_reg_uram_*_Cas_AddrA``)
plus the tag compare. Vivado flags the data array as *under-pipelined*:

.. note::

   ``[Synth 8-6013] UltraRAM "ven_l2/l2_data_reg" is under-pipelined and may not
   meet performance target : Pipeline stages found = 4; Recommended = 9.``

A 16-tile-deep URAM column wants its read pipelined roughly one register per few
tiles. The default ``RAM_RD_LAT=5`` lets Vivado absorb **4** cascade stages →
155 MHz; raising ``RAM_RD_LAT`` toward ~10 would let it absorb the recommended 9
and lift Fmax further, at the cost of a few more hit-latency cycles. Either way
**155 MHz is ~3–4× the core's ~40–50 MHz operating point** (see
:doc:`fp-commit-pipeline` for the routed-Fmax wall the integer/FP core hits), so
the L2 is comfortably **not** a timing bottleneck even under-pipelined.

Status & follow-on
==================

Standalone and verified; **not yet wired into the core**. The integration path is
an I/D backing-port arbiter (merging the icache and L1-D backing streams) plus a
``bus_mode`` to route through the L2; then SECDED ECC over the 32 spare URAM
parity bits, a writeback buffer so a dirty eviction does not serialize in front
of the fill, burst (vs per-word) dirty writeback, and a next-line/stride
prefetcher.

See :doc:`l1-parametric` and :doc:`l1-cache-performance` for the L1 cache
design-space and what cache capacity buys on the cycle-accurate model.
