=========================================================
Debug Instrumentation
=========================================================

This page catalogs every **debugging and bring-up feature** built into Ventium:
the on-die debug/trace unit, the diagnostic operating modes, the PS-side daemon
controls, the host tools, and the testbench probes. These are the instruments
used to localize silicon-only bugs — corruption that the idealized simulator
never reproduces — down to a single instruction on a running board, and to tell
*timing* faults from *functional/synthesis* faults from *software* faults
without guesswork.

The compile-time defines that gate these features (``VEN_DBG_CORE``,
``DBG_CORE=1``, …) are cataloged in :doc:`build-flags`; the bus/register
plumbing they ride on is in :doc:`soc/theory-of-operation`. This page documents
*what each instrument observes and how to drive it*.

.. contents::
   :local:
   :depth: 2

Overview: three layers of observability
========================================

Ventium is debuggable at three layers, from closest-to-silicon to host-side:

#. **On-die (PL fabric)** — the ``VEN_DBG_CORE`` debug/trace unit (``ven_soc_dbg``)
   taps committed architectural state, a program-counter ring, a freeze detector,
   performance counters, and an AXI read-beat trace, and exposes single-step and
   hardware-breakpoint control. The PS reads/writes it over the AXI-Lite control
   window. Present only in a ``DBG_CORE=1`` bitstream.
#. **PS-side software (A53)** — ``ven_soc_app`` (the SoC bring-up daemon) drives
   the on-die unit through command-line flags (breakpoint, single-step, peek,
   poke, flush, mode toggles) and adds ``ven_systrace``, a non-destructive
   observability layer (rings, histograms, a watchdog, a ``SIGUSR1`` snapshot).
#. **Host tools & testbench** — ``vpeek`` reads the DDR carveout, ``venclk.sh``
   sets the PL clock, and the Verilator testbench (``tb_main.cpp``) provides
   single-step, framebuffer dump, a *faithful* AXI read slave for beat-timing
   fuzzing, randomized X-initialization, and `$display` forensic probes.

A typical silicon-bug hunt walks down these layers: reproduce on the board,
freeze/breakpoint at the fault, read the committed state and PC ring, then use
the diagnostic modes (clock-lower, golden-L1, placement-swap) to classify the
fault and the testbench probes to reproduce and fix it.

On-die debug/trace unit (``VEN_DBG_CORE``)
==========================================

``rtl/soc/ven_soc_dbg.sv`` is instantiated by ``ventium_kv260_core`` **only**
under ``\`ifdef VEN_DBG_CORE`` (env ``DBG_CORE=1``). It costs a little BRAM and
routing, so it is **off for the timing-critical production close** and **on for
a forensic / bring-up bitstream**. Probe ``R_DBG_CAP`` first: it reads
``0xDB01_0020`` (magic ``0xDB``, version ``1``, ring depth ``0x20`` = 32) when
the unit is present, and ``0`` otherwise.

The unit is mapped in the AXI-Lite control slave (``ven_soc_axil``) at the HPM0
aperture base ``0xA000_0000``, register block ``0x80``+. All offsets below are
from ``sw/ps/ven_soc_app/ven_soc_regs.h`` (which **must stay in lock-step** with
``ven_soc_axil.sv``).

.. list-table:: ``VEN_DBG_CORE`` register window (offset from ``0xA000_0000``)
   :header-rows: 1
   :widths: 10 14 12 64

   * - Offset
     - Name
     - Access
     - Meaning
   * - ``0x80``
     - ``R_DBG_CAP``
     - RO
     - Capability magic ``0xDB01_0020`` when present (else ``0``). **Probe first.**
   * - ``0x84``
     - ``R_DBG_EIP``
     - RO
     - Last-retired EIP (the committed program counter).
   * - ``0x88``
     - ``R_DBG_CS``
     - RO
     - Last-retired CS selector.
   * - ``0x8C``
     - ``R_DBG_ESP``
     - RO
     - Last-retired ESP.
   * - ``0x90``
     - ``R_DBG_EFLAGS``
     - RO
     - Last-retired EFLAGS.
   * - ``0x94``
     - ``R_DBG_STATE``
     - RO (live)
     - ``[5:0]`` FSM micro-state, ``[6]`` CR0.PE, ``[7]`` CR0.PG, ``[15:8]`` last
       interrupt/exception vector, ``[16]`` ``io_pending`` (parked in ``S_IO``),
       ``[17]`` ``cpu_hung``, ``[18]`` ``frozen``.
   * - ``0x98``
     - ``R_DBG_FAULT_PC``
     - RO (live)
     - EIP that sourced the current exception/IRQ.
   * - ``0x9C``
     - ``R_DBG_CR0``
     - RO (live)
     - Live CR0.
   * - ``0xA0`` / ``0xA4``
     - ``R_DBG_FROZEN_EIP`` / ``_ST``
     - RO
     - EIP and ``{fsm,vec,frozen}`` snapshot captured at the freeze (see below).
   * - ``0xA8``
     - ``R_DBG_TRACE_IDX``
     - RW
     - Write ``[4:0]`` = N-back ring index (0 = most-recent retired PC); read
       ``[13:8]`` = entries captured (saturates at depth 32).
   * - ``0xAC`` / ``0xB0``
     - ``R_DBG_TRACE_PC`` / ``_AUX``
     - RO
     - ``ring[idx]`` EIP, and ``{state[5:0], cs[15:0]}``. **1-clock BRAM read
       latency** — write ``0xA8``, do a dummy read of ``0xAC``, then read.
   * - ``0xB4``
     - ``R_DBG_CTRL``
     - W1P
     - ``[0]`` = clear perf counters + freeze snapshot + rings.
   * - ``0xB8``
     - ``R_DBG_FREEZE_TH``
     - RW
     - Stall-cycle threshold → take a freeze snapshot (``0`` = disabled).
   * - ``0xBC`` … ``0xD4``
     - ``R_DBG_PERF_*``
     - RO
     - ``CYC`` (64-bit), ``RET`` (64-bit retired), ``STALL`` (no-retire cycles),
       ``IO`` (``S_IO`` cycles), ``IRQ`` (external interrupts taken). CPI =
       ``CYC/RET``.
   * - ``0xD8``
     - ``R_DBG_BP_ADDR``
     - RW
     - Hardware breakpoint EIP.
   * - ``0xDC``
     - ``R_DBG_RUNCTL``
     - RW
     - ``[0]`` ``halt_req`` (hold the core parked), ``[1]`` W1P ``step`` (execute
       exactly one instruction), ``[2]`` ``bp_en``, ``[3]`` W1P ``bp_clr``; RO
       ``[8]`` = ``halted``.
   * - ``0xE0`` / ``0xE4`` / ``0xE8``
     - ``RD_ADDR`` / ``RD_DATA`` / ``RD_COUNT``
     - RO
     - **AXI read-beat trace ring** — the DDR address and raw RDATA of each
       accepted ``ven_axi_master`` read beat, indexed by the same ``0xA8`` index
       as the PC ring. Post-mortems a corrupted line fill.

Committed-state taps
--------------------

``EIP`` / ``CS`` / ``ESP`` / ``EFLAGS`` (``0x84``–``0x90``) are the *retired*
architectural state — what previously required a faithful-sim rebuild to
recover. On a halt or freeze they name exactly where the core stopped.
``R_DBG_STATE`` (``0x94``) adds the live FSM micro-state, the mode bits (real /
protected / paged), the last vector, and the ``io_pending`` / ``cpu_hung`` /
``frozen`` status in one read.

PC ring
-------

A 32-deep ring of the most-recently-retired program counters (plus
``{fsm,cs}`` aux). Walk it newest-to-oldest by writing ``R_DBG_TRACE_IDX``
(``0``\=newest) and reading ``R_DBG_TRACE_PC`` / ``_AUX`` (remember the 1-clock
BRAM read latency). The ring reconstructs the control-flow trail into a stall or
derail. ``R_DBG_TRACE_IDX[13:8]`` reports how many entries are valid.

Freeze detector
---------------

Set ``R_DBG_FREEZE_TH`` (``0xB8``) to a stall-cycle count: if the core goes that
many cycles with **no retire**, the unit latches a one-shot snapshot of the EIP
and ``{fsm,vec}`` into ``R_DBG_FROZEN_EIP`` / ``_ST`` (``0xA0`` / ``0xA4``) and
sets ``STATE[18]``. This catches a transient wedge whose state would otherwise
be overwritten before software can poll it. Clear with ``R_DBG_CTRL[0]``.

Performance counters
--------------------

Free-running 64-bit cycle and retired-instruction counters, plus stall / ``S_IO``
/ IRQ counters (``0xBC``–``0xD4``). Used both for **CPI measurement** and as a
**no-progress watchdog** input. Cleared by ``R_DBG_CTRL[0]``.

Single-step and hardware breakpoint
------------------------------------

``R_DBG_RUNCTL`` (``0xDC``) is the execution-control register:

* **Single-step** — pulse ``halt_req | step`` (``0x3``): the core executes
  **exactly one** instruction and re-parks (``halted``\=1). The printed committed
  EIP sequence *is* the executed instruction stream — an on-silicon instruction
  trace for a bug the simulator cannot reproduce.
* **Hardware breakpoint** — write ``R_DBG_BP_ADDR`` and set ``bp_en`` (``0x4``)
  **before releasing the core's reset**, so the core halts the first time the PC
  reaches the address. Combine with single-step to walk the trajectory from the
  breakpoint forward.

.. note::

   The single-step loop does not service ``S_SYSCALL_WAIT``: if a step lands on
   an ``int 0x80`` the core parks waiting for the proxy and will not re-halt.
   To step *past* a syscall, place the breakpoint **after** the syscall (the
   run-up to the breakpoint is continuous and is serviced by the main loop) and
   step from there.

AXI read-beat trace
-------------------

``RD_ADDR`` / ``RD_DATA`` / ``RD_COUNT`` (``0xE0``–``0xE8``) capture the DDR
address and raw RDATA of every accepted ``ven_axi_master`` read beat into a ring
indexed by ``R_DBG_TRACE_IDX``. It is the instrument for post-morteming a
**corrupted cache line fill**: read back the exact ``{addr, data}`` the fabric
delivered for each beat and compare against the staged DDR image.

Diagnostic operating modes
==========================

Three runtime modes (and one host knob) deliberately degrade or alter the
machine to *classify* a fault. Each is a controlled experiment.

Golden / "L1-useless" mode (``MODE.GOLDEN_L1``)
-----------------------------------------------

Set bit 7 of the ``R_MODE`` register (``0x10``), ``VEN_MODE_GOLDEN_L1``. When
set, ``ven_l1d`` drops **all** cached state — every line's valid bit **and** the
registered read window (``rd_window_q`` / ``rd_armed`` / ``rd_addr_q``) — after
**every completed core transaction**, so the next access fully re-fills from the
backing and re-captures fresh. No L1 state survives a transaction.

This tanks performance (every access misses), but produces a result that is
**uncontaminated by L1 line-staleness or read-window bugs**:

* if a fetch/data corruption **persists** with ``golden=1``, the bug is **not**
  in L1's carried state — it is downstream (the core fetch buffer / decode) or in
  a path shared by every access;
* if it **vanishes**, L1's carried state was the cause.

Driven from the daemon with ``--golden`` (see below) or by writing ``R_MODE``
directly; tied ``0`` = normal cached operation.

Cycle (dual-issue / fast-fetch) mode (``MODE.CYCLE``)
-----------------------------------------------------

Bit 1 of ``R_MODE``, ``VEN_MODE_CYCLE``. In functional mode every fetch is
routed to the slow ``S_FETCH`` path; in cycle mode the dual-issue U/V pipeline
and the **fast uop-cache fetch path** are used. Toggling it tells whether a
fetch/decode fault lives in the slow path, the fast path, or the shared L1 read
they both feed (a fault present in **both** modes is in the shared path). Driven
with ``--cycle``.

L1 invalidate (``CTRL.FLUSH_REQ``)
----------------------------------

A W1P pulse on the control register clears every L1 valid bit. Used after a PS
write that bypassed the L1 (the syscall proxy writes the carveout directly), and
as a debug knob (``--flush-each-step``) to force every fetch to miss and refill —
isolating a stale-line bug from a fill-corruption bug.

Clock control (``venclk.sh``)
-----------------------------

Not a core feature but the key *timing* discriminator. ``sw/ps/ven_soc_app/venclk.sh``
sets the PL0 clock divider via the PS CRL register ``0xFF5E_00C0``:

.. list-table::
   :header-rows: 1
   :widths: 20 20 60

   * - Command
     - Result
     - Use
   * - ``venclk.sh set 25``
     - 40 MHz
     - The timing-closure / sign-off operating point.
   * - ``venclk.sh set 33``
     - 30 MHz
     - Clock-lower test.
   * - ``venclk.sh set 50``
     - 20 MHz
     - Aggressive clock-lower test (period doubled).
   * - ``venclk.sh ramp``
     - 40→50 MHz
     - Overclock smoke-test (above 40 MHz is silicon-lottery).

**Clock-lower test:** if a fault is **byte-identical** at 20/30 MHz and 40 MHz,
it is **not** a setup-timing violation (more period would relieve setup). A fault
that only appears at higher clocks is a setup-margin/overclock effect.

PS-side daemon controls (``ven_soc_app``)
=========================================

The bring-up daemon (``sw/ps/ven_soc_app/ven_soc_app.c``) drives the on-die unit
and the carveout. The debug-relevant flags:

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Flag
     - Effect
   * - ``--bp <eip>``
     - Arm the on-die hardware breakpoint **before releasing the core**; on the
       hit, single-step ``--steps`` instructions, printing EIP/CS/FSM each.
   * - ``--steps <n>``
     - Number of instructions to single-step after the breakpoint hit (default 80).
   * - ``--flush-each-step``
     - Pulse ``CTRL.FLUSH_REQ`` (L1 invalidate) before every single-step, so each
       fetch misses and refills from DDR — removes the cache-staleness confound.
   * - ``--peek <gaddr>``
     - After staging, hexdump the carveout at the folded guest address (and exit).
       Tells a **staging error** (wrong bytes written to DDR) from a **fetch-read**
       bug (DDR correct, core reads wrong).
   * - ``--poke <gaddr> <hex>``
     - Overwrite the staged carveout with a controlled instruction stream, then
       run / single-step. Probes the fetch/decode datapath with a **known** byte
       sequence on real silicon (e.g. a marching pattern, or a minimal repro).
   * - ``--cycle``
     - Set ``MODE.CYCLE`` (dual-issue / fast uop-cache fetch path).
   * - ``--golden``
     - Set ``MODE.GOLDEN_L1`` (L1 flush-after-each-access; see above).

``dbg_dump_core()`` prints the full debug bundle — committed EIP/CS/ESP/EFLAGS,
FSM micro-state and mode, fault vector, CR0, the freeze snapshot, the perf
counters (with CPI), and the PC ring — on a watchdog fire, a ``cpu_hung``, a
``SIGTERM``, or a ``SIGUSR1``. It is a no-op on a non-``DBG_CORE`` bitstream
(``R_DBG_CAP`` ≠ magic).

``ven_systrace`` — non-destructive PS observability
---------------------------------------------------

``sw/ps/ven_soc_app/ven_systrace.{c,h}`` is an env-gated observability layer that
does **not** duplicate ``dbg_dump_core()``: a syscall/video event ring, a
heartbeat, a **no-progress watchdog** (fires if neither syscalls nor retire
advance for a timeout — a wedged proxy handshake or stuck core), a commit-verify
(``SYS_PEND`` must clear after ``RESP_VALID``), and a non-destructive
``SIGUSR1`` **snapshot** (prints syscalls / video bytes / first-frame status
without stopping the core). All recording is gated off by default so the
production hot path is unaffected.

Host tools
==========

``vpeek`` — carveout reader
---------------------------

``sw/ps/ven_soc_app/vpeek.c`` is a non-destructive reader of the 256 MB DDR
carveout, mapped **exactly** like ``ven_soc_app`` (open ``/dev/mem`` with
``O_RDWR | O_SYNC``, ``mmap`` the whole carveout at ``VEN_CARVEOUT_BASE``
``0x4000_0000``, ``MAP_SHARED``). This matters: ``busybox devmem`` maps a single
page and returns byte-lane-shifted/duplicated garbage for this carveout, so it is
**useless** for reading guest memory. ``vpeek`` folds the guest address into the
carveout (``addr & 0x0FFF_FFFF``) and prints each word plus its four little-endian
bytes (so a byte-lane bug is unmistakable). Read-only + ``MAP_SHARED``, so it is
safe to run alongside a halted ``ven_soc_app``. Requires ``sudo``::

   vpeek 0x08048000 8       # expect 464C457F 00010101 ...  ("\x7fELF")
   vpeek 0x40c34674 24      # the guest stack at a halt

Testbench debug features (``tb_main.cpp``)
==========================================

The Verilator testbench mirrors the on-die controls (so a sim repro and a board
repro use the same vocabulary) and adds sim-only forensics.

.. list-table::
   :header-rows: 1
   :widths: 34 66

   * - Flag / knob
     - Effect
   * - ``--dbg-step N``
     - Park the core from reset and single-step ``N`` instructions, logging the
       committed EIP/CS/ESP/FSM each — the sim counterpart of the on-die
       single-step (needs ``VEN_DBG_CORE``).
   * - ``--dbg-bp <eip>``
     - Arm a PC breakpoint and run free until the core parks at it.
   * - ``--golden``
     - Drive ``top->golden_l1`` (the L1-useless mode) in the ``VEN_L1_AXI`` build.
   * - ``--dump-fb <file>``
     - Dump the Quake framebuffer (``vid.buffer`` @ ``0x087a29e0``, 320×200×8) at
       exit, for an offline PNG render check.
   * - ``AXI_RGAP=1`` (+ ``AXI_RSEED`` / ``AXI_RFIRST`` / ``AXI_RGAPMAX`` / ``AXI_RGAPPROB``)
     - Make the testbench AXI read slave **faithful**: mid-burst ``RVALID``
       deassertions/gaps, randomized first-beat and inter-beat latency, and
       ``RREADY`` backpressure. R-channel beat-timing fuzzing — exposes a
       fill/handshake bug the idealized zero-gap slave would mask. Default-off so
       the differential corpus stays clean.
   * - ``+verilator+rand+reset+2`` ``+verilator+seed+N``
     - Randomized X-initialization (the testbench passes ``+verilator+*`` plusargs
       through to ``Verilated::commandArgs``). Build with
       ``--x-assign unique --x-initial unique``. Tests the **uninitialized-state**
       hypothesis: a register read before write that the 2-state model auto-zeroes
       but silicon resolves to a corrupting value.

Sim-only ``\`ifdef``-gated ``$display`` probes (inert by default, ignored by
synthesis):

* ``VEN_DERAIL_TRIP`` / ``VEN_TRIP_N`` (``dpi_retire.cpp``) — a tripwire that
  rings the last 64 committed ``{n, pc, esp}`` and trips when the committed EIP
  leaves the valid code range, dumping the window around the divergence.
* ``VEN_DBG_L1PROBE`` (``ven_l1d.sv``) — dumps ``{c_addr, boff, xline, rd_hit,
  st, rd_armed, rd_addr_q, rd_match, c_ack, c_rdata}`` per L1 access in a target
  address window: the L1 read-path forensic probe.
* ``VEN_DBG_FETCHPROBE`` (``core_fetch_decode.svh``) — dumps
  ``{eip, ibuf, op0, d_len, eff_opsize}`` in ``S_DECODE``: the instruction-length
  decode forensic probe.

Fault-classification playbook
=============================

The instruments above compose into a decision procedure for an observed
corruption. In order of cheapest-first:

#. **Staging vs. read** — ``vpeek`` the staged region. If DDR is byte-correct,
   the write/staging path is clean and the fault is in the read/fetch path.
#. **Reproduce minimally** — ``--poke`` a small controlled instruction stream and
   ``--bp`` + ``--steps`` to get a deterministic, few-instruction repro.
#. **Timing vs. functional** — ``venclk.sh set 50`` (20 MHz). Byte-identical at
   20 MHz ⇒ **not** setup timing (functional/synthesis).
#. **Staleness vs. fill** — ``--flush-each-step`` or ``MODE.GOLDEN_L1``. Fault
   gone ⇒ L1 carried state; fault persists ⇒ downstream of L1.
#. **Physical vs. structural** — re-flash a **different-placement** bitstream of
   the same RTL and re-run the repro. Byte-identical across placements ⇒
   **structural** synth-sim mismatch (not placement/hold timing).
#. **Reproduce in sim** — once classified, reproduce in the testbench:
   ``AXI_RGAP`` for beat-timing, ``+verilator+rand+reset`` for uninitialized
   state, or a gate-level sim of the synthesized netlist for a structural
   divergence — then fix and re-verify against the differential corpus.

This procedure was used to localize the F4 board-only instruction-fetch
corruption to a placement-independent structural synth-sim mismatch in the
``ven_l1d`` read mux (a live-vs-registered byte-select split), reproduced as a
12-byte ``--poke`` program and fixed by selecting the read window with the
**registered** capture address.
