==========================================
References & Verification Oracles
==========================================

Ventium is reconstructed from **public architectural, timing, and silicon
reverse-engineering sources**: Intel's period Pentium manuals, datasheets, and
specification updates; academic and trade microarchitecture analyses;
independent instruction-timing measurements; die-photo reverse engineering; and
open-source IA-32 emulators used as differential oracles.

Official Ventium source code and hardware releases are published at
`https://github.com/AL-255/ventium <https://github.com/AL-255/ventium>`_
(`Releases <https://github.com/AL-255/ventium/releases>`_).

.. note::

   **Scope & Submodule Boundary:** Intel never published P5 RTL, microcode ROM
   listings, or internal validation vectors. Ventium targets an
   **ISA-compatible, cycle- and microarchitecture-faithful** synthesizable
   reconstruction of the non-MMX Pentium (P5/P54C, Family 5), governed by
   instruction-by-instruction differential lockstep against a pinned QEMU
   Pentium oracle and physical FPGA standard-suite qualification.

   The ``ventium-refs`` submodule cited below is a **private maintainer
   archive** holding the pinned QEMU oracle and reference PDFs for the
   ``experimental/uv-fast-ipc-apr`` differential harness — it is **never
   required** to clone, verify, or synthesize the self-contained public ``main``
   FPGA release (``fpga/known_good_c0e3fe43.json`` / ``fpga/build_known_good.py``).

§1 — Canonical Intel documentation
==================================

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Document
     - Architectural Role in Ventium
   * - **Pentium Processor Family Developer's Manual** Vol 1/2/3 (Jul 1995,
       ``241428/241429/241430-004``) & **1997 Combined Manual**
     - ``PF``/``D1``/``D2``/``EX``/``WB`` pipeline stages, U/V pairing rules,
       split 8 KiB L1 caches, TLBs, 64-bit P5 bus cycles, x87 FPU, SMM, and
       execution environment.
   * - **Pentium Processor Datasheet** (``241997-010``)
     - Pin-level 64-bit external bus protocol (``ADS#``, ``BRDY#``, ``NA#``,
       ``KEN#``, ``CACHE#``, ``HITM#``, ``LOCK#``, ``AHOLD``, ``BOFF#``) modeled
       in ``rtl/bus/biu_p5.sv``.
   * - **Pentium Specification Updates** (``242480-022``, ``242480-041`` final
       P54C)
     - Authoritative source for optional P54C errata models: FDIV (Erratum 23),
       FIST overflow (Erratum 20), MOV-``moffs`` pairing (Erratum 59), and F00F
       lock-up (Erratum 81).
   * - **IA-32 Software Developer's Manual** (1997 ``243190/91/92-001`` & modern
       SDM)
     - Protected-mode segmentation, 4 KiB / 4 MiB paging, task switching, call
       gates, V86 mode, and precise exception precedence.

§2 — Pipeline and microarchitecture literature
==============================================

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Source
     - Contribution
   * - **Alpert & Avnon, "Architecture of the Pentium Microprocessor"**, *IEEE
       Micro* (1993)
     - Dual-issue U/V datapath structure, **256-entry 4-way BTB**, branch
       resolution timing, and V-pipe branch pairing.
   * - **Microprocessor Report, "Intel Reveals Pentium Implementation Details"**
       (1993)
     - Early P5 decode, prefix, and pairing corner cases.
   * - **RTL Engineering — Pentium P5 / x86 Front-End Analyses**
       (`@RTLEngineering <https://www.youtube.com/@RTLEngineering>`_)
     - Independent public-record analyses of P5 variable-length dual decode
       (`Part 1 <https://www.youtube.com/watch?v=Ju8BTMJb5Kc>`_,
       `Decode Sim <https://www.youtube.com/watch?v=f--MBGeVSSg>`_) and Quake's
       overlapped x87/integer execution (`Quake & Pentium FPU
       <https://www.youtube.com/watch?v=DWVhIvZlytc>`_).

§3 — Optimization guides and measured timing tables
===================================================

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Source
     - Contribution
   * - **Intel AP-500 / 241799**, *Optimizations for Intel's 32-Bit Processors*
     - Primary U/V pairing classification (``UV`` / ``PU`` / ``PV`` / ``NP``),
       L1D bank conflict rules, AGI interlocks, prefix penalties, and ``FXCH``
       scheduling.
   * - **Intel AP-526 / 242816-003**, *Intel Architecture Optimization Manual*
     - Expanded integer and x87 latency/throughput tables.
   * - **Agner Fog — Instruction Tables & Microarchitecture Guide** &
       **Granlund / GMP x86 Timing Tables**
     - Independent silicon cycle-count cross-checks on Pentium P5/P54C hardware.

§4 — Die-photo reverse engineering & SRT division mathematics
=============================================================

.. list-table::
   :header-rows: 1
   :widths: 44 56

   * - Source
     - Contribution
   * - **Ken Shirriff**, *"Intel's $475 million error: the silicon behind the
       Pentium division bug"* (righto.com, Dec 2024) & Pentium cell/CLA articles
     - Die-photo reverse engineering of the P54C standard-cell library, FPU
       carry-lookahead adder, constant ROM, and radix-4 SRT quotient-selection
       PLA (:doc:`microarch/srt-divider`).
   * - **Alan Edelman**, *"The Mathematics of the Pentium Division Bug"*, *SIAM
       Review* 39(1), 1997 (formalizing **Coe & Tang**, 1995)
     - Formal carry-save SRT recurrence, ``|p| ≤ (8/3)d`` convergence interval,
       threshold-table generator (``tools/srt/srt_model.py``), and the five
       reachable ``8·P_Bad ∈ {23, 27, 31, 35, 39}`` flaw cells.

§5 — Differential oracles, simulation & physical acceptance stack
=================================================================

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Tool / Gate
     - Role in Ventium Verification
   * - **Pinned QEMU Pentium Oracle** (``ventium-refs``)
     - Correctness authority for ``make verify`` and ``make verify-sys`` (real,
       protected, paged, V86, SMM, and 80-bit ``floatx80`` x87 lockstep via
       ``verif/diff/tracefmt.py`` ``.vtrace`` streams; distribution QEMU is not
       interchangeable).
   * - **Intel XED · Capstone · Bochs · SoftFloat**
     - Independent instruction length/decode and 80-bit extended-precision
       rounding cross-checks.
   * - **Verilator 5 & Subsystem Gates**
     - ``make verify``, ``make verify-sys``, ``make l1``, ``make bus bus-sva``,
       ``make lint``, and full-PC ``ao486-sim/`` simulation.
   * - **Physical RK-XCZU15EG-F Standard Acceptance Suite**
     - Board-level qualification on ``xczu15eg-ffvb1156-2-i`` (Vivado 2025.2) in
       mandatory ``U/V + system fast-pipe`` mode (``cycle_mode=1``): (1) both
       4,000-iteration **CoreMark** CRC seeds, (2) cold **Windows 95 OSR2** GUI
       desktop + PS/2 interaction + clean shutdown, and (3) cold **DOS Quake**
       ``timedemo demo1`` (``8.0 FPS`` at ``40.000 MHz`` on image
       ``c0e3fe43``, **0.515778001 total U+V gameplay IPC** / ``0.397847833``
       primary/U across cycles ``28,696,827,616–32,989,404,795``).
