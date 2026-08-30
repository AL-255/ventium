=================================================
P5 L1 Cache Geometry
=================================================

Ventium's L1 instruction and data caches are **8 KB, 2-way set-associative,
32-byte line, 128 sets, LRU** — the Pentium silicon geometry, and the one the
cycle model is validated against. Every integrated RTL, cosimulation, and FPGA
profile is pinned to that geometry. This prevents cache-size-dependent
performance or coherence behaviour from being mistaken for a processor
improvement; the shipping build is **bit- and cycle-identical** to the P5
geometry used by the oracle.

Integrated configuration
========================

The processor has one L1 configuration. Size of each L1 is
``128 sets × 2 ways × 32 B = 8 KiB``.

.. list-table::
   :header-rows: 1
   :widths: 26 40 14

   * - Property
     - I$
     - D$
   * - Capacity
     - 8 KiB
     - 8 KiB
   * - Sets / ways / line
     - 128 / 2 / 32 B
     - 128 / 2 / 32 B
   * - Index / tag
     - ``addr[11:5]`` / ``addr[31:12]``
     - ``addr[11:5]`` / ``addr[31:12]``

``VEN_CACHE_HALF`` and the integrated cache set/way value defines were
retired. The ``icache`` and ``ven_l1d`` *leaf modules* retain module
parameters so their derived index/tag arithmetic can be unit-tested at
multiple legal sizes. Those tests are not alternative processor
configurations.

Two-way P5 LRU
==============

The original 2-way replacement carried **one bit per set** — ``lru`` = the
most-recently-used way, with ``victim = ~lru``. The extracted cache leaf has a
general age-rank representation internally, but the integrated P5 always has
two ways.

The replacement is a **per-way age-counter true-LRU**. Each way of a set holds a
rank ``age[set][way]`` ∈ ``0 … WAYS-1`` (0 = MRU, WAYS-1 = LRU); the ranks of a
set are always a permutation of ``0 … WAYS-1``. The **victim** is the way whose
age is ``WAYS-1``. On any access (hit or fill) to way *k*, every way more recent
than *k* (age < *k*'s age) ages by one and *k* becomes MRU (age 0). The icache
exposes the chosen victim as ``ic_victim_o`` so the spine's fill-way selection
stays uniform (it simply reads ``ic_victim_o`` instead of the old ``~ic_lru_o``).

This encoding **reduces exactly to the old behaviour at WAYS=2**: reset ages
``{0,1}`` make the first victim way 1 — identical to ``~lru`` with ``lru`` reset
to 0; a hit/fill on way *k* moves *k* to MRU and the other way to LRU, exactly as
``lru <= k`` did. So the default build's hit test, victim sequence, and recency
updates are byte-for-byte the same — which the cycle gates confirm below.

P5 configuration verification
==============================

**The default 8 KB / 2-way / 128-set build is bit- and cycle-identical** to the
pre-parameterisation core:

* ``make verify`` — 77 / 77 programs functionally diff-clean vs QEMU.
* ``make m5`` — every cycle band green, with the cache kernels unchanged:
  ``mb_dmiss`` CPI **2.504** (abs-cyc **+0.10 %** vs the oracle) and ``mb_imiss``
  CPI **6.002** (**+0.03 %**) — the sub-0.1 % deltas are the proof the age-LRU's
  victim sequence matches the original 2-way LRU clock-for-clock.
* the standalone ``l1d`` RTL gate passes.

Historical standalone leaf-module geometry experiments were functionally
correct but are *not* processor configurations and are not matched by the fixed
2-way / 128-set ``p5trace.so`` cycle oracle. ``make verify`` / M4 / M5 certify
the fixed P5 geometry above. A 16 KB 4-way leaf experiment was checked directly:

* it builds clean;
* a CoreMark free-run on the 4-way cache produces CRC output **byte-identical to
  qemu-native** (the cache is architecturally transparent, so any valid geometry
  yields identical results);
* associativity does what it should — a 12 KB working set striding one load per
  32-byte line over 128 sets puts **3 lines in every set**, which **thrashes the
  2-way cache (CPI 2.50, every access a conflict miss)** but **fits the 4-way
  cache (CPI 0.54)** — a **4.65× speedup** from conflict-miss elimination alone:

.. list-table::
   :header-rows: 1
   :widths: 28 18 18 36

   * - Geometry (12 KB working set)
     - lines/set
     - CPI
     - outcome
   * - 8 KB, 2-way, 128 sets
     - 3 > 2 ways
     - 2.50
     - conflict thrash (100 % miss)
   * - 16 KB, 4-way, 128 sets
     - 3 ≤ 4 ways
     - 0.54
     - fits (≈ 0 miss) — 4.65× faster

Fidelity caveat
===============

Only the **2-way / 128-set** geometry is silicon-accurate, is implemented in
the processor, and is cycle-validated against the oracle. See
:doc:`l1-cache-performance` for the fixed-cache performance characterization,
and :doc:`srt-divider` for the broader cycle-model methodology.
