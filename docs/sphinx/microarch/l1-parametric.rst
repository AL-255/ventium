=================================================
Parametric L1 caches — size and associativity
=================================================

Ventium's L1 instruction and data caches are **8 KB, 2-way set-associative,
32-byte line, 128 sets, LRU** — the Pentium silicon geometry, and the one the
cycle model is validated against. That geometry is now **parametric**: the set
count *and* the associativity of each L1 can be set at compile time, so the core
can be re-built as a 4 KB direct-mapped-ish, a 16 KB 4-way, a 32 KB 8-way, or any
power-of-two combination — for FPGA area/Fmax studies and cache design-space
exploration. The default build is **bit- and cycle-identical** to the original.

Compile-time knobs
==================

Geometry is selected by ``+define`` flags (no source edit needed). Size of each
L1 = ``sets × ways × 32 B``.

.. list-table::
   :header-rows: 1
   :widths: 26 40 14

   * - Define
     - Effect
     - Default
   * - ``VEN_L1_SETS=N``
     - set count for **both** I$ and D$
     - 128
   * - ``VEN_L1_WAYS=N``
     - associativity for **both** I$ and D$
     - 2
   * - ``VEN_IC_SETS=N`` / ``VEN_IC_WAYS=N``
     - I-cache only (overrides the ``VEN_L1_*`` value)
     - —
   * - ``VEN_DC_SETS=N`` / ``VEN_DC_WAYS=N``
     - D-cache only (overrides the ``VEN_L1_*`` value)
     - —
   * - ``VEN_CACHE_HALF``
     - legacy shortcut: 64 sets (4 KB) both L1s
     - —

``N`` is a power of two. Examples (built into a private ``obj_dir`` so they never
clobber the canonical one)::

   # 16 KB 4-way (both L1s)
   make -C verif/tb rtl OBJDIR=obj_dir_4way VL_EXTRA_DEFINES="+define+VEN_L1_WAYS=4"

   # 8-way I$, 256-set 2-way D$
   make -C verif/tb rtl OBJDIR=obj_dir_mix \
        VL_EXTRA_DEFINES="+define+VEN_IC_WAYS=8 +define+VEN_DC_SETS=256"

The set-index width (``$clog2(SETS)``), tag width (``32-5-idx``) and way-index
width (``$clog2(WAYS)``) all derive automatically; the tag/valid/data arrays and
the line store scale with the parameters.

Generalising the LRU without disturbing the default
===================================================

The original 2-way replacement carried **one bit per set** — ``lru`` = the
most-recently-used way, with ``victim = ~lru``. That does not generalise: an
N-way victim needs the full recency order, not just the MRU way.

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

Default is preserved; non-default is functionally correct
==========================================================

**The default 8 KB / 2-way / 128-set build is bit- and cycle-identical** to the
pre-parameterisation core:

* ``make verify`` — 77 / 77 programs functionally diff-clean vs QEMU.
* ``make m5`` — every cycle band green, with the cache kernels unchanged:
  ``mb_dmiss`` CPI **2.504** (abs-cyc **+0.10 %** vs the oracle) and ``mb_imiss``
  CPI **6.002** (**+0.03 %**) — the sub-0.1 % deltas are the proof the age-LRU's
  victim sequence matches the original 2-way LRU clock-for-clock.
* the standalone ``l1d`` RTL gate passes.

**Non-default geometries are functionally correct** but are *not* matched by the
fixed 2-way / 128-set ``p5trace.so`` cycle oracle, so ``make verify`` / M4 / M5
certify only the default geometry. A 16 KB 4-way build was checked directly:

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

Only the **2-way / 128-set** geometry is silicon-accurate and cycle-validated
against the oracle. Other geometries change the miss *sequence* (and at non-2-way
the replacement is no longer the P5's), so they are area/perf experiments, not a
verification config. See :doc:`l1-cache-performance` for what the cache size
actually buys on the cycle-accurate model, and :doc:`srt-divider` for the
broader cycle-model methodology.
