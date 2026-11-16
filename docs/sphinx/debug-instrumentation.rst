=========================================================
Debug Instrumentation, PMU Telemetry & Clock Control
=========================================================

This page documents the on-die observability, performance-monitoring counters,
runtime clock synthesis, Verilator forensics, and gate-level simulation tools
used to verify and diagnose Ventium on the **RK-XCZU15EG-F**
(``xczu15eg-ffvb1156-2-i``, Vivado **2025.2**, board-qualified image
``c0e3fe43``, ``161`` defines including ``VEN_DBG_CORE``, ``40.264133 MHz``
post-route STA sign-off).

.. contents::
   :local:
   :depth: 2

Three layers of observability
=============================

Ventium provides three complementary diagnostic layers:

1. **On-Die PL Telemetry & Control (0xA000_0000 AXI-Lite Aperture):**
   ``ven_mgmt_axil.v`` and ``ven_soc_dbg.sv`` (enabled under ``+define+VEN_DBG_CORE``)
   expose 64-bit cycle and retirement counters (both ``primary/U`` and
   ``total U+V``), retired-PC trace rings, versioned forensic freeze frames,
   quiescent boundary halt/step/breakpoint controls, and AXI read/write
   profilers (``ven_axi_read_profiler.sv``, ``ven_axi_write_profiler.sv``),
   alongside passive 128-RAMB36 VGA frame capture (``ven_video_capture.sv``) and
   hardware PS/2 injection mailboxes (``ven_ps2_mailbox.sv``).
2. **Board Admission & Guard Tools (fpga/board-tools/):**
   ``ven_board_probe.py``, ``ven_cold_clock.py``, ``ven_uv_fast_guard.py``,
   ``ven_record_stream.py``, and ``ven_encode_recording.py`` enforce ABI
   capability checks, cold 40 MHz clock verification, unstepped ``U/V +
   fast-pipe`` execution guards, posted-DDR4 drain verification, and lossless
   RGB332 video capture.
3. **Verilator & Gate-Level Simulation Harnesses (verif/, ao486-sim/):**
   Cycle/functional ``.vtrace`` lockstep against the pinned QEMU Pentium oracle,
   AXI beat-gap fuzzing (``AXI_RGAP``), randomized 2-state reset seeding, and
   Vivado ``xsim`` post-synthesis netlist checks for BRAM anti-decloning.

``0xA000_0000`` AXI-Lite management & debug aperture (RK-XCZU15EG-F)
====================================================================

On the RK-XCZU15EG-F ZynqMP block design, ``M_AXI_HPM0_FPD`` maps a **64 KiB**
aperture at physical base ``0xA000_0000`` into ``ven_mgmt_axil.v``. Because
the 128-bit HPM0-to-AXI4-Lite downsizer forwards lane-0 32-bit words, **all
registers sit on 0x10-byte-aligned offsets** (``addr[3:0] == 4'h0``; use
naturally aligned 32-bit accesses, never short unaligned ``memcpy`` slices over
Device memory):

.. list-table:: ``ven_mgmt_axil`` / ``ven_soc_dbg`` register banks (base ``0xA000_0000``)
   :header-rows: 1
   :widths: 16 24 10 50

   * - Offset
     - Register / Bank
     - Access
     - Function
   * - ``0x000``
     - ``IDENT``
     - RO
     - Platform signature ``0xA0486V01``.
   * - ``0x010``
     - ``MGMT_A``
     - RW
     - Held ``mgmt_address`` for MiSTer BIOS/IDE/FDD sector transfers.
   * - ``0x020``
     - ``CTRL``
     - RW
     - ``[0]`` ``CORE_RESET`` (hold guest reset), ``[1]`` ``RUN``, ``[8]`` ``IRQ_EN``.
   * - ``0x030`` / ``0x040``
     - ``MGMT_WD`` / ``MGMT_RD``
     - WO / RO
     - 1-cycle ``mgmt_write`` / ``mgmt_read`` data strobes to ``system.v``.
   * - ``0x050``
     - ``STATUS``
     - RO
     - ``[2:0]`` ``ide0_req``, ``[5:3]`` ``ide1_req``, ``[7:6]`` ``fdd_req``,
       ``[8]`` ``core_running``, ``[9]`` ``cpu_hung``.
   * - ``0x060`` / ``0x070``
     - ``DBG`` / ``DBG2``
     - RO
     - Memory-path observability word & last instruction fetch address.
   * - ``0x100`` / ``0x110``
     - ``PERF_CYC_LO`` / ``_HI``
     - RO
     - Free-running 64-bit core clock cycle counter.
   * - ``0x120`` / ``0x130``
     - ``PERF_RET_LO`` / ``_HI``
     - RO
     - 64-bit ``primary/U`` retirement counter (see IPC accounting rules below;
       ``total U+V`` retirement counter exported alongside PMU bank).
   * - ``0x140`` / ``0x150``
     - ``PERF_IO`` / ``PERF_IRQ``
     - RO
     - Cumulative ``S_IO`` wait cycles and acknowledged external interrupts.
   * - ``0x200``–``0x270``
     - ``FREEZE_CTX``
     - RO
     - Versioned snapshot capability + latched freeze frame (``EIP``, ``CS``,
       ``ESP``, ``EFLAGS``, ``fault_pc``, ``CR0``, ``FSM state``, ``vector``)
       captured atomically before forensic guest reset.
   * - ``0x280``–``0x2C0``
     - ``EXEC_DBG``
     - RW / RO
     - Quiescent boundary ``halt_req``, ``step`` (W1P), ``bp_en``, ``bp_addr``,
       ``arch_sel`` / ``arch_data`` register scan, and execution-debug ABI
       capability word.
   * - ``0x380``–``0x3A0``
     - ``KBD_MAILBOX``
     - WO / RO
     - Hardware PS/2 Set-2 keyboard byte submit, transport status, & capability.
   * - ``0x400``–``0x4A0``
     - ``MOUSE_MAILBOX``
     - RW / RO
     - Hosted PS/2 mouse packet injection mailbox (``ven_ps2_mailbox.sv``).

Mandatory IPC accounting & ``U/V + fast-pipe`` guard rules
==========================================================

When measuring performance or qualifying workloads on hardware, follow these
invariants strictly:

* **Distinguish total U+V from primary/U Retirement:** ``primary/U``
  counts one event per retired instruction or U+V pair, whereas ``total U+V``
  accumulates ``ventium_top.retire_n`` (``1`` for single issue, ``2`` for a
  paired U+V retirement). Both counters include **per-element REP string
  iterations** (not deduplicated macroinstructions). On image ``c0e3fe43``,
  interior DOS Quake gameplay (cycles ``28,696,827,616–32,989,404,795``)
  achieved **0.515778001 total U+V IPC** and **0.397847833 primary/U
  IPC** (``506,223,958`` paired V retirements; prior ``2886d24c`` baseline:
  ``0.496499864`` total U+V / ``0.383002768`` primary/U across cycles
  ``625,021,130,428–629,480,208,865``).
* **Baseline Counter Epochs Independently:** ``primary/U`` survives guest reset
  whereas ``total U+V`` clears on guest reset; always compute ``Δevents / Δcycles``
  across matched interior gameplay intervals (never startup, BIOS, or CoreMark).
* **Never Step or Arm Intended-V Breakpoints in Acceptance Runs:** Instruction
  ``STEP`` and breakpoints targeting a V-slot instruction force slow-path
  serialization and suppress U/V pairing. ``ven_board_probe.py`` (``prepare-cold``)
  and ``ven_uv_fast_guard.py`` verify execution-debug ABI compatibility, clear
  breakpoints before cold release, and confirm actual ``S_PIPE`` paired
  retirement in post-run trace rings.
* **start_fault Comparator Caveat:** Enabling fault-freeze
  (``dbg_cmp_cfg[22]``) counts every ``start_fault`` entry — which **includes
  ordinary external hardware IRQ delivery** (e.g. PIT ``IRQ0`` vector ``0x08``),
  not solely unexpected CPU exceptions.

Programmable MMCM clock control & DDR4 safety
=============================================

The deployed RK-XCZU15EG-F platform drives ``mmcm_clk`` from a dedicated
``MMCME4_ADV`` (``100 MHz`` PS reference × ``10`` = ``1.0 GHz`` VCO, divided by
``N``; boot default ``N = 25`` → ``40.000 MHz``) controlled over EMIO GPIO
by ``fpga/ven_pll_ctrl.sv`` (XAPP888 DRP sequence):

* **Cold 40 MHz Admission:** Before launching any cold workload, run
  ``fpga/board-tools/ven_cold_clock.py`` while guest reset is held to verify
  ``39.5–40.5 MHz`` actual core frequency, ``0x6000_0000–0x6FFF_FFFF`` ``no-map``
  DDR4 reservation in ``/proc/iomem``, and zero premature retirements.
* **Posted-DDR4 Drain Interlock:** Never assert reset, read closed guest RAM, or
  change the MMCM divider until ``ven_ddram_axi_posted`` reports its 16-slot
  write queue externally drained (``50440003``).
* **STA Boundary vs. Runtime DRP Overclocking:** Static timing sign-off covers
  ``40.000 MHz`` (``40.264133 MHz`` post-route budget). Empirical single-board
  DRP runs at ``58.824 MHz`` (``N = 17``, Win95 + Quake) and ``62.500 MHz``
  (``N = 16``, Quake) are silicon margin measurements, not multi-board STA
  guarantees.

Verilator testbench & gate-level simulation forensics
=====================================================

The Verilator harnesses (``verif/tb/tb_main.cpp`` and ``ao486-sim/``) mirror the
hardware debug controls and add simulation-only fault-injection probes:

.. list-table:: Simulation debug knobs
   :header-rows: 1
   :widths: 34 66

   * - Knob / Define
     - Purpose
   * - ``--l1-axi`` (with ``+define+VEN_L1_AXI``)
     - Selects the real ``ventium_l1_axi`` backend in ``tb_main.cpp`` (compiling
       with ``VEN_L1_AXI`` alone does not switch the TB backend; verify AXI
       traffic explicitly).
   * - ``--dbg-step N`` / ``--dbg-bp <eip>``
     - Single-step or park at a hardware PC breakpoint under ``VEN_DBG_CORE``
       (diagnostic only; suppresses pairing).
   * - ``--golden``
     - Drives ``golden_l1`` (flush L1 valid & read windows after every access)
       to isolate carried-state cache staleness from downstream decode bugs.
   * - ``AXI_RGAP=1`` (+ seed/gap parameters)
     - Injects mid-burst ``RVALID`` bubbles and variable beat latencies on the
       AXI4 read slave to catch burst-fill handshake hazards.
   * - ``+verilator+rand+reset+2``
     - Randomizes 2-state power-up registers/memories (built with
       ``--x-assign unique --x-initial unique``) to expose uninitialized-state
       reads before reset release.
   * - ``xsim`` + ``[Synth 8-223]`` check
     - Runs Xilinx gate-level simulation against ``unisims_ver`` / ``secureip``
       and checks synthesis logs in-context (``-top core -flatten_hierarchy
       rebuilt``) to verify dual-read BRAM arrays (such as ``icache.sv``) are
       never silently merged by RAM-equivalence decloning.

.. note::

   **Historical KV260 Note:** Early bring-up documentation referenced
   ``ventium_kv260_core``, ``ven_soc_app`` byte-offset registers
   (``0x80..0xE8``), a ``0x4000_0000`` DDR carveout, and ``venclk.sh`` PS CRL
   divider writes. Those KV260 recipes are obsolete; always use the
   ``0x6000_0000`` ``no-map`` DDR4 reservation, ``ven_pll_ctrl`` EMIO DRP clock
   controller, and ``0x10``-aligned ``ven_mgmt_axil`` registers on
   RK-XCZU15EG-F (see ``HOW_TO_RUN_FPGA.md``).
