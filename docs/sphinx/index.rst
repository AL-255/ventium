=================================================
Ventium — P5/P54C Replica Reference Documentation
=================================================

.. important::

   **Official Source Code & Releases —** `https://github.com/AL-255/ventium <https://github.com/AL-255/ventium>`_

   All official Ventium SystemVerilog RTL, FPGA build scripts, and tagged source
   releases are published on GitHub at `https://github.com/AL-255/ventium <https://github.com/AL-255/ventium>`_
   (see `GitHub Releases <https://github.com/AL-255/ventium/releases>`_).

   The current board-qualified public release is ``v0.2.0-c0e3fe43`` on the
   ``main`` branch (hash-pinned in ``fpga/known_good_c0e3fe43.json``, ``161``
   hardware defines, **no private submodule required**), targeting
   **RK-XCZU15EG-F** (``xczu15eg-ffvb1156-2-i``, AMD Vivado **2025.2**):

   * **True 40 MHz Post-Route Static Timing Sign-Off:** ``40.264133 MHz``
     slow-corner period budget (``WNS = +0.164 ns``, ``WHS = +0.010 ns``, ``0``
     failing endpoints, ``0`` ``>=85%`` global routing hotspots, ``171,819``
     LUTs / ``30,703`` CLBs).
   * **Physical Standard Acceptance Suite Passed** (``U/V + system fast-pipe``,
     ``cycle_mode=1``): both standard **CoreMark** CRC seeds (``2.100128 /
     2.106796 CM/MHz``), cold **Windows 95 OSR2** multi-application GUI session
     with PS/2 keyboard/mouse + clean shutdown, and cold **DOS Quake**
     ``timedemo demo1`` (**8.0 FPS**, ``969`` frames in ``121.2 s`` at
     measured ``39.999802 MHz``).
   * **Verified Physical Quake Gameplay IPC:** **0.515778001 total U+V IPC**
     (``0.397847833`` primary/U-only IPC; counters include ``REP``-element
     retirement) across interior gameplay cycles
     ``28,696,827,616–32,989,404,795`` (prior ``2886d24c`` release baseline:
     ``0.496499864`` total U+V / ``0.383002768`` primary/U across cycles
     ``625,021,130,428–629,480,208,865``). Empirical single-board runtime MMCM
     DRP runs also passed at ``58.824 MHz`` (Win95 + Quake) and ``62.500 MHz``
     (Quake; STA sign-off covers ``40.000 MHz`` only).

Ventium is a high-fidelity reconstruction of the non-MMX Intel Pentium
(**P5/P54C**, Family 5, i586) microarchitecture in fully synthesizable
SystemVerilog. It models the 5-stage in-order dual-issue integer core (``PF`` →
``D1`` → ``D2`` → ``EX`` → ``WB``, U and V pipes, protected-mode ``S_PIPE``
load/store fast path, and full microsequencer/fragment engine), the shared
pipelined 80-bit ``floatx80`` x87 FPU (``fp_shared/``, zero-cycle ``FXCH``
rename queue, polynomial transcendentals, and radix-4 SRT divider/sqrt), split
**8 KiB 2-way L1 instruction and 8-bank L1 data caches** (with **no enabled L2**),
**32-entry 4-way I-TLB** and **64-entry 4-way D-TLB**, dual-ported **256-entry
4-way BTB**, and the full MiSTer PC/AT platform bridged to 16-slot posted DDR4
on Zynq UltraScale+.

Correctness is governed by **instruction-by-instruction differential lockstep
against a pinned QEMU Pentium oracle** across real, protected, V86, paged, and
system-management modes, complemented by physical FPGA acceptance on the
standard workload suite. Documented Pentium errata — the FDIV SRT PLA flaw
(:doc:`microarch/srt-divider`), F00F (Erratum 81), FIST overflow, MOV-``moffs``
false dependency, and Intel AP-500 pairing rules — are modeled explicitly behind
opt-in flags so both clean and erratum-faithful configurations remain verifiable.

Source Releases & Quickstart
============================

Clone the official repository from `https://github.com/AL-255/ventium <https://github.com/AL-255/ventium>`_
(or download tagged archives from `GitHub Releases <https://github.com/AL-255/ventium/releases>`_):

.. code-block:: bash

   git clone https://github.com/AL-255/ventium.git
   cd ventium

   # Public self-contained FPGA preflight & Vivado 2025.2 build (main branch):
   python3 -B fpga/build_known_good.py --check
   tclsh fpga/test_known_good_wrapper.tcl "$PWD"

* ``main`` **branch** publishes the frozen, self-contained 193-file hardware
  closure for board-qualified image ``c0e3fe43`` (``fpga/known_good_c0e3fe43.json``
  & ``fpga/build_known_good.py``).
* ``experimental/uv-fast-ipc-apr`` **branch** retains ongoing core/cache/APR
  development and the full Verilator/QEMU differential harness (``make verify``,
  ``make verify-sys``, ``make l1``, ``make bus bus-sva``, ``make lint``);
  post-freeze experimental edits do not inherit ``c0e3fe43``'s physical
  qualification without re-verification.

Simulated Dhrystone 2.1 Comparison (``DMIPS/MHz`` vs. ``z486`` & ``ao486``)
---------------------------------------------------------------------------

Simulated in Verilator (``v5.046``) on the frozen ``c0e3fe43`` RTL profile
(``U/V + system fast-pipe``, ``cycle_mode=1``, ``--l1-axi``, 4 KiB paging,
8 KiB I$ + 8 KiB 8-bank D$, ``ΔN = 2,000`` ``RDTSC``-bracketed steady-state
iterations, all 20 Weicker self-checks verified; harness in
``verif/bench/dhrystone/``), compared against published scores in the
`z486 repository <https://github.com/nand2mario/z486>`_ and
`z486 technical report <https://nand2mario.github.io/posts/2026/z486/>`_
(VAX 11/780 ``1757`` Dhrystones/s divisor):

.. list-table::
   :header-rows: 1
   :widths: 26 28 12 18 16

   * - Core / Profile
     - Compiler Flags & Cache
     - Cyc / Iter
     - Loop IPC (``U+V`` / ``U``)
     - **DMIPS / MHz**
   * - ``ao486`` *(published)*
     - ``-march=i386 -O3 -fno-inline`` (2 KB I$ + 4 KB D$)
     - ``2,934.0``
     - ``CPI 4.556``
     - **0.194** (``1.00x``)
   * - ``z486`` *(published 20260813)*
     - ``-march=i386 -O3 -fno-inline`` (8 KB I$ + 8 KB D$)
     - ``1,725.0``
     - ``CPI 2.800`` *(Oct rev ~2.0)*
     - **0.330** (``1.70x``)
   * - **Ventium** ``c0e3fe43`` *(exact z486 table flags)*
     - ``-march=i386 -O3 -fno-inline`` (8 KiB I$ + 8 KiB D$)
     - **955.0**
     - ``0.6555`` / ``0.4953`` (``24.4%`` V)
     - **0.5960** (**3.07x** ``ao486`` / **1.81x** ``z486``)
   * - **Ventium** ``c0e3fe43`` *(exact z486 Makefile)*
     - ``-march=i386 -O2 -DREG=register``
     - **905.3**
     - ``0.6573`` / ``0.4894`` (``25.6%`` V)
     - **0.6287** (**3.24x** ``ao486`` / **1.91x** ``z486``)
   * - **Ventium** ``c0e3fe43`` *(Pentium no-inline)*
     - ``-march=pentium -mtune=pentium -O3 -fno-inline``
     - **852.0**
     - ``0.7688`` / ``0.5775`` (``24.9%`` V)
     - **0.6680** (**3.44x** ``ao486`` / **2.02x** ``z486``)
   * - **Ventium** ``c0e3fe43`` *(Pentium -O2)*
     - ``-march=pentium -mtune=pentium -O2 -DREG=register``
     - **797.2**
     - ``0.7753`` / ``0.5746`` (``25.9%`` V)
     - **0.7139** (**3.68x** ``ao486`` / **2.16x** ``z486``)

.. note::

   Simulated Dhrystone 2.1 is an L1-resident synthetic microbenchmark and never
   substitutes for physical-board acceptance or verified DOS Quake interior
   gameplay IPC (``0.515778001`` total U+V on ``c0e3fe43``).

Documentation Map
=================

The :doc:`System Architecture <architecture>` overview describes the P5/P54C
pipeline, shared x87 FPU, caches/TLBs, and RK-XCZU15EG-F PC/AT platform. The
:doc:`Instruction Catalog <isa/index>` and :doc:`Interactive Opcode Map <isa/opcode-map>`
walk every integer, system, and x87 instruction category together with its
datapath routing and U/V pairing class.

.. toctree::
   :maxdepth: 2
   :caption: Overview

   architecture

.. toctree::
   :maxdepth: 2
   :caption: Reference

   isa/index
   isa/opcode-map

.. toctree::
   :maxdepth: 2
   :caption: Microarchitecture deep dives

   microarch/srt-divider
   microarch/fp-commit-pipeline
   microarch/l1-cache-performance
   microarch/l1-parametric
   microarch/l2-cache

.. toctree::
   :maxdepth: 2
   :caption: SoC / Peripherals

   soc/theory-of-operation
   soc/peripheral-split

.. toctree::
   :maxdepth: 2
   :caption: Debug & bring-up

   debug-instrumentation

.. toctree::
   :maxdepth: 1
   :caption: Project resources

   build-flags
   reference-library
