==========================================
Reference library — sources behind Ventium
==========================================

Ventium is reconstructed entirely from **public sources**: Intel's period
manuals, datasheets and errata; the academic and trade literature on the P5
microarchitecture; independent timing measurements; die-photo reverse
engineering; and open-source emulators used as differential oracles. This page
catalogs that material — what each source is, why the project needs it, and
where it lives.

A standing caveat, stated up front in the library's own ``REF.md``: **true RTL
accuracy is not achievable from public sources alone.** Intel never published
RTL, microcode listings, the validation database, the scoreboard logic, or every
erratum-triggering corner case. What the public record *does* support — and what
Ventium targets — is an **ISA-compatible, cycle/microarchitecture-approximate**
replica of a chosen stepping (P5/P54C, non-MMX), validated by differential
testing rather than by claiming gate-level fidelity.


The archive: ``ventium-refs``
=============================

The bulk of the cited material is snapshotted in the **``ventium-refs`` git
submodule** (~220 MB of PDFs/HTML, layout mirroring the numbered sections of
``REF.md``). Three files anchor it:

.. list-table::
   :header-rows: 1
   :widths: 22 78

   * - File
     - Role
   * - ``REF.md``
     - The annotated bibliography and acquisition strategy — *why* each class of
       source matters and what behaviour it pins down. The authoritative
       narrative; the numbered sections below follow it.
   * - ``MANIFEST.md``
     - The on-disk catalog: every archived file, its ``REF.md`` row, and its
       original source URL (re-fetchable; verify with ``sha256sum -c
       CHECKSUMS.txt``).
   * - ``00-index/INDEX.md``
     - A **page-referenced** "abstracted index" of every PDF (~240 KB total) with
       a *Find by topic* map, so an agent can locate the right document and page
       without loading multi-MB PDFs.


§1 — Canonical Intel documentation
==================================

Ground truth for the ISA and the part's published behaviour.

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Document (archive filename)
     - Why it is needed
   * - **Pentium Processor Family Developer's Manual** Vol 1/2/3 (Jul 1995,
       ``241428/241429/241430-004``) and the **1997 combined** manual
     - Core architecture, the PF/D1/D2/EX/WB pipeline, U/V pairing, caches, TLBs,
       pins, bus cycles, x87, performance counters, APIC/SMM/debug. Vol 2 covers
       the 82496/82497 + 82491/82493 external L2 cache chipset; Vol 3 is the
       ISA-visible execution environment.
   * - **1995 Pentium Processors and Related Components** data book
     - 61 MB superset of Vol 1 + datasheets + app notes for that vintage.
   * - **Pentium Processor datasheet** (``241997-010``, + hi-res scan)
     - Pin-level bus protocol: ``ADS#``, ``BRDY#``, ``NA#``, ``KEN#``,
       ``CACHE#``, ``HITM#``, ``LOCK#``, ``M/IO#``, ``D/C#``, ``W/R#``, reset/
       INIT/BIST, AC/DC timing.
   * - **Pentium Specification Updates** (``242480-022``, ``242480-041`` final
       P54C, ``243185-004`` P55C/MMX)
     - Mandatory: errata are part of "accurate" behaviour. ``242480-022`` is the
       direct source for the FDIV (Erratum 23), FIST (20), MOV-``moffs`` (59) and
       F00F (81) models; ``-041`` is the final P54C roll-up.
   * - **IA-32 Software Developer's Manual** — 1997 (``243190/91/92-001``) and
       current (``325462``, 2025-02)
     - Period-correct IA-32 semantics, cross-checked against the modern SDM.
   * - **Intel MultiProcessor Specification v1.4**
     - Local-APIC / IO-APIC / MP-table behaviour for OS-visible MP correctness.


§2 — Pipeline and internal-structure sources
============================================

The most important sources for reconstructing the *microarchitecture*.

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Source
     - What it reveals
   * - **Pentium Developer's Manual, Chapter 2** (in §1 above)
     - The canonical statement of the five integer stages, U/V pipes, the
       "simple-instruction" pairing rules, the four-state BTB predictor and
       mispredict penalties, and the eight-stage FPU pipeline + FXCH pairing.
   * - **Alpert & Avnon, "Architecture of the Pentium Microprocessor", IEEE
       Micro 1993** (``alpert-avnon-…``)
     - Intel-authored overview with implementation clues — the 256-entry,
       four-way BTB, branch-update timing, V-pipe branch pairing.
   * - **Microprocessor Report, "Intel Reveals Pentium Implementation Details",
       1993** (``mpr-pentium-implementation-1993``)
     - Secondary source on early P5 internals, pairing exceptions, rationale.


§3 — Optimization guides and timing tables
==========================================

Where latency/throughput numbers leak internal structure — the basis for the
cycle-accurate model and the AP-500 pairing table.

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Source
     - Why it matters
   * - **AP-500 / 241799**, *Optimizations for Intel's 32-Bit Processors* (rev
       001 & 002)
     - The primary pairing/timing source: U/V pipes, cache banks, BTB penalties,
       prefetch buffers, AGI stalls, prefix costs, alignment penalties, FPU
       scheduling, with concrete cycle-count examples.
   * - **AP-526 / 242816-003(a)**, *Intel Architecture Optimization Manual*
     - Later, broader latency/throughput and pairability tables.
   * - **Intel MMX Technology Developer's Manual** (``243006-001``)
     - MMX pipeline / relaxed pairing (only needed for a P55C target).
   * - **Agner Fog — instruction tables + microarchitecture guide**
     - Independent *measured* latencies, throughputs, pairability and pipe
       restrictions — invaluable cross-checks on the Intel numbers.
   * - **Granlund / GMP x86 timing tables**
     - Further independent integer latency/throughput measurements.


§4 — Performance-counter and measurement methodology
====================================================

No external artifacts — methodology only (``RDTSC``, the ``CTR0``/``CTR1`` /
``CESR`` performance counters, logic-analyzer capture). The event lists live in
the Developer's Manual Vol 1; this section is the placeholder for Ventium's own
microbenchmark harness and trace captures.


§5 — Die photos and silicon reverse engineering
===============================================

Used for floorplanning, ROM/PLA contents and block-level sanity checks — *not*
as a substitute for behavioural validation.

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Source
     - Use
   * - **Ken Shirriff's Pentium articles** (righto.com)
     - Standard-cell library (P54C, 600 nm, 4 metal layers), the FPU Kogge-Stone
       carry-lookahead adder, the FPU constant ROM, microcode circuitry, and —
       central to this project — the **reverse-engineered SRT division PLA** and
       the FDIV bug. Archived: ``shirriff-pentium-standard-cells.html``,
       ``shirriff-pentium-carry-lookahead.html``.
   * - **CPU Museum / Wikimedia P54C die photos**
     - High-resolution die/floorplan references for the cache arrays, FPU,
       integer datapaths and control ROMs.
   * - **Patents** (e.g. ``US5970235A`` pre-decoded instruction cache)
     - Design-background evidence on parallel x86 decode, the BTB, the divider —
       suggestive, not proof of the exact implementation.


§6 — Emulators and decoders (differential oracles)
==================================================

Functional references, **not** timing references. These are live upstream
projects (pulled at build/test time, not archived); see
``06-emulators-decoders/SOURCES.md``.

.. list-table::
   :header-rows: 1
   :widths: 26 74

   * - Project
     - Role in Ventium
   * - **QEMU (TCG)**
     - The primary differential oracle. Every Ventium gate runs a program on the
       RTL and on ``qemu -cpu pentium`` / ``qemu-system-i386`` and asserts
       bit-identical architectural (and, in cycle mode, retire) state.
   * - **Bochs**
     - Interpretable IA-32 functional reference from the 386 onward.
   * - **Intel XED · Capstone · Zydis**
     - Encode/decode oracles for differential decoder testing.
   * - **86Box · PCem · MAME · UniPCemu · DOSBox-X**
     - PC-platform (BIOS/chipset/VGA/PIC/PIT/RTC) behaviour references for the
       SoC peripherals.
   * - **K x86-64 semantics · Intel SDE**
     - Formal user-mode semantics / a modern Intel emulator, for ISA cross-checks
       (not Pentium-timing accurate).


§7 — Test suites
================

External and self-built conformance corpora. Beyond the project's own
differential corpus (decoder, ISA, x87, microarch-timing, bus/protocol
categories), the archive vendors:

.. list-table::
   :header-rows: 1
   :widths: 26 74

   * - Suite
     - Role
   * - **test386.asm** (``09-external-cpu-tests/``)
     - A standalone 80386+ CPU tester that runs as a BIOS replacement. Ventium's
       ``test386`` SoC gate boots it on ``ventium_soc`` and diffs it byte-for-byte
       against ``qemu-system-i386`` (GPL-3.0; source vendored in the archive).
   * - **P5 emulation harness** (``07-p5-emulation-harness/``)
     - A reproducible "golden reference" environment that runs P5/P54C code,
       enforces the P5-only instruction set, estimates Pentium clock cycles, and
       drives free benchmarks — the functional + cycle-estimate layer that must be
       right before the RTL can be checked against it (honest about stopping short
       of bus/errata/stepping accuracy).


§8 — RTL implementation and verification stack
==============================================

The tooling the replica is built and checked with:

* **SystemVerilog** RTL with a strict architectural-state model.
* **Verilator** for fast simulation (the ``make verify`` / ``verify-soc`` /
  ``verify-srt`` gates); Icarus/commercial simulators for compatibility.
* A **differential harness** against QEMU (and XED/Bochs) plus a golden trace
  format: retired instruction, EIP, EFLAGS, GPRs, segment-hidden state,
  CRx/DRx/MSRs, full x87 state, and the bus-cycle trace.
* A **high-precision FP oracle** (SoftFloat / MPFR-style) for x87 — necessary
  because 80-bit ``floatx80`` behaviour is *not* the same as C ``double``.


Sources for the SRT divider / FDIV-bug work
===========================================

The genuine radix-4 SRT divider (see :doc:`microarch/srt-divider`) was built
from the §5 reverse-engineering line plus the formal SRT literature. These are
the specific sources used; the two recent ones are not in the snapshot (pull as
needed, per ``MANIFEST.md``'s note that "Shirriff has more on the Pentium (FDIV
bug, …)"):

.. list-table::
   :header-rows: 1
   :widths: 44 56

   * - Source
     - Contribution
   * - Ken Shirriff, *"Intel's $475 million error: the silicon behind the Pentium
       division bug"* (righto.com, Dec 2024)
     - The die-photo reverse engineering of the quotient-selection PLA: radix-4,
       digit set ``{-2,-1,0,1,2}``, the 7-bit (``pppp.ppp``) × 5-bit (``1.dddd``)
       index, the carry-save "one cell low" effect, and the five missing ``+2``
       entries.
   * - Alan Edelman, *"The Mathematics of the Pentium Division Bug"*, SIAM Review
       39(1), 1997
     - The formal model: the recurrence and ``|p| ≤ (8/3)d`` bound, the
       quotient-selection table generator, the ones-complement carry-save
       datapath, the ``8·P_Bad ∈ {23,27,31,35,39}`` bad cells, the "six
       consecutive ones" divisor condition, and the "≥9 steps to failure" result.
   * - Coe & Tang, *"It Takes Six Ones to Reach a Flaw"* (1995)
     - The original reverse-engineered model Edelman formalises (the source of the
       bad-column values and the reachability proof).
   * - **Intel Spec Update 242480-022** (§1 archive)
     - The documented erratum: trigger pattern and worst-case severity (13th
       significant bit), the anchor for the M6 runtime model.
