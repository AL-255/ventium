===================
Verilog build flags
===================

Ventium's RTL is built around a single convention: **the default build — no
defines at all — is the verification baseline**. It is the configuration every
differential gate runs, byte- and cycle-identical to the golden model
(QEMU for architectural state, ``p5trace`` for the cycle traces). Every build
flag in the project *opts in* to something on top of that baseline, and every
opted-in configuration is itself pushed back through the differential battery
before it is trusted.

The flags divide into two kinds. **Behaviour-preserving implementation
options** change *how* a result is computed — an iterative engine instead of a
combinational cone, a BRAM instead of LUTRAM, a pipeline register on a critical
path — and exist purely for FPGA Fmax and area. These must stay architecturally
bit-exact, and either cycle-identical or inside the loose M4/M5 cycle bands;
they are what the KV260 bitstream configurations set. **Behaviour-adding
options** change *what* the core does — the authentic FDIV flaw, eight new
transcendental instructions, a P5 cycle-model refinement, a real AXI bus —
and each one carries its own oracle and its own gate, because the default
golden no longer applies to it.

This page is the complete reference: every conditional-compilation define and
build parameter in the tree, what it gates, who sets it, and how (or whether)
it is verified. File references are given as paths; the authoritative location
is always the ``ifdef`` in the source itself.

.. contents::
   :local:
   :depth: 1

Quick reference
===============

.. list-table::
   :header-rows: 1
   :widths: 24 16 22 38

   * - Flag
     - Kind
     - Default
     - Purpose
   * - **x87 FPU implementation**
     -
     -
     -
   * - ``VEN_FP_PIPE``
     - boolean define
     - off — single-cycle FP execute
     - 1-deep FP-execute commit pipeline (defer commit to N+1) for Fmax.
   * - ``VEN_FP_PIPE2``
     - boolean define
     - off (inert without ``VEN_FP_PIPE``)
     - Second commit stage at the ``f_eval_s1``/``f_eval_s2`` boundary; the K26
       60 MHz close.
   * - ``VEN_FP_OVERLAP``
     - boolean define
     - off — serialized, matches oracle
     - P5 cycle gap 1: independent integer ops overlap an in-flight FDIV
       (own oracle variant).
   * - ``VEN_FXCH_FREE``
     - boolean define
     - off — FXCH costs 1 clock
     - P5 cycle gap 2: an FXCH following a stack push folds in for free
       (own oracle variant).
   * - ``VEN_SRT_ITER``
     - boolean define
     - off — combinational FDIV/FSQRT
     - Multi-cycle iterative SRT divide and square-root engines, bit-exact.
   * - ``VEN_SRT_DIV``
     - boolean define
     - no-op (legacy)
     - Historical name; the genuine SRT divider is now the unconditional
       default.
   * - ``VEN_SRT_FDIV_BUG``
     - boolean define
     - off — correct PLA
     - The authentic Pentium FDIV flaw (buggy quotient-selection PLA).
   * - ``VEN_DIV_EXACT``
     - boolean define
     - off — SRT engine is default
     - Opt *back* to the behavioural wide divide (fast-sim escape hatch).
   * - ``VEN_BCD_ITER``
     - boolean define
     - off — combinational BCD cones
     - Iterative FBSTP/FBLD packed-BCD conversion engines, bit-exact.
   * - ``VEN_BCD_DIV100``
     - boolean define
     - off everywhere
     - One divide-by-100 per BCD step instead of two chained divide-by-10
       (Fmax micro-optimisation inside ``ven_bcd``).
   * - ``VEN_TRANSCENDENTAL``
     - boolean define
     - off — opcodes HALT
     - Adds the 8 x87 transcendental instructions via iterative engines.
   * - ``VEN_TRSC_SILICON``
     - boolean define
     - inert (reserved)
     - Planned silicon-accuracy mode select for the transcendental engines;
       not implemented.
   * - **Front-end and L1 caches**
     -
     -
     -
   * - ``VEN_BTB_PIPE``
     - boolean define
     - off — combinational resolve
     - Registers the BTB resolve inputs; cycle-neutral Fmax fix.
   * - ``VEN_UOPCACHE``
     - boolean define
     - off — live byte-window decode
     - Predecode-on-fill micro-op cache; the fix for the x86 byte-window MUXF
       congestion wall.
   * - ``VEN_UOPCACHE_CHECK``
     - boolean define
     - off
     - Sim scaffold re-instantiating the reference decode beside the µop-cache
       slot read.
   * - ``VEN_FE_PIPE``
     - boolean define
     - off — live TLB lookups
     - Page-keyed fetch/data micro-TLB register; breaks the ``eip`` self-loop
       (+1 clock per page crossing).
   * - ``VEN_IC_BRAM``
     - boolean define
     - off — async LUTRAM lines
     - Block-RAM icache line store with registered reads and predicted-target
       prefetch.
   * - ``VEN_IC_NARROWB``
     - boolean define
     - off — full-width port B
     - Halves the icache straddle read port (distributed-RAM front end only).
   * - ``VEN_CACHE_HALF``
     - boolean define
     - off — 128 sets per L1
     - Both L1s halved to 64 sets (4 KB each); FPGA area/congestion option.
   * - ``VEN_IC_SETS``
     - valued define (int)
     - 128
     - I-cache set-count override for geometry sweeps.
   * - ``VEN_IC_WAYS``
     - valued define (int)
     - 2
     - I-cache associativity override (parametric true LRU).
   * - ``VEN_DC_SETS``
     - valued define (int)
     - 128
     - D-cache timing-model set-count override.
   * - ``VEN_DC_WAYS``
     - valued define (int)
     - 2
     - D-cache timing-model associativity override.
   * - **Integer core and build plumbing**
     -
     -
     -
   * - ``VEN_IDIV_ITER``
     - boolean define
     - off — combinational divide
     - Multi-cycle restoring DIV/IDIV engine replacing the native ``/``/``%``
       cone.
   * - ``SYNTHESIS``
     - boolean define
     - unset in simulation
     - Strips sim-only ``$fatal`` elaboration guards and bound SVA.
   * - ``VTM_NO_DPI``
     - boolean define
     - unset in simulation
     - Elides the four DPI-C retire-observation imports and call sites.
   * - ``VTM_HAVE_DPI_HEADER``
     - C++ macro (self-defined)
     - auto-detected
     - ``dpi_retire.cpp`` header-detection plumbing; never user-set.
   * - ``M7_PROXY_DEBUG``
     - boolean define
     - off
     - ``$display`` taps on the syscall-proxy / sreg-load / indirect-call
       paths.
   * - ``F2_DBG``
     - boolean define
     - off
     - ``$display`` tap in the F2XM1 engine's pack stage.
   * - **Memory system and SoC platform**
     -
     -
     -
   * - ``VEN_L1_AXI``
     - boolean define
     - off — BFM memory port
     - Real L1 data cache plus AXI4 master to PS-DDR (bus mode 2).
   * - ``VEN_L1_SETS``
     - valued define (int)
     - 128
     - Umbrella set-count knob for both in-core L1s at once.
   * - ``VEN_L1_WAYS``
     - valued define (int)
     - 2
     - Umbrella associativity knob for both in-core L1s at once.
   * - ``VEN_AXI_CDC``
     - boolean define
     - off — single-clock bypass
     - Dual-clock async-FIFO bridge inside the L1/AXI subsystem.
   * - ``VEN_KV260_SOC``
     - boolean define
     - off
     - PS-facing seams: ``retire_count``, F3 interrupt injection, DDR-carveout
       address remap.
   * - ``VEN_PS_PROXY``
     - boolean define
     - off — same-clock proxy
     - Stalling ``S_SYSCALL_WAIT`` handshake for the future PS syscall bridge.
   * - ``VEN_PBLOCK``
     - environment variable (Tcl)
     - unset
     - Vivado soft-Pblock floorplan experiment; **not a Verilog define**.
   * - **Peripheral RTL/PS split**
     -
     -
     -
   * - ``VEN_UART_PS``
     - boolean define
     - off — device in RTL
     - COM1 16550 UART served by the PS C model.
   * - ``VEN_VGA_PS``
     - boolean define
     - off — device in RTL
     - VGA register file served by the PS C model (framebuffer goes dormant).
   * - ``VEN_RTC_PS``
     - boolean define
     - off — device in RTL
     - MC146818 RTC/CMOS served by the PS C model.
   * - ``VEN_PIT_PS``
     - boolean define
     - off — keep off
     - Latent hook only; the 8254 PIT is pinned in PL (IRQ0 timebase).
   * - ``VEN_PIC_PS``
     - boolean define
     - off — keep off
     - Latent hook only; the 8259 PIC is pinned in PL (INTR/INTA latency).
   * - ``VEN_I8042_PS``
     - boolean define
     - off — device in RTL
     - 8042 keyboard controller served by the PS C model.
   * - ``VEN_FDC_PS``
     - boolean define
     - off — device in RTL
     - 82077/8272A floppy controller served by the PS C model.
   * - ``VEN_ACPIPM_PS``
     - boolean define
     - off — device in RTL
     - ACPI PM timer served by the PS C model.
   * - ``VEN_PORT92_PS``
     - boolean define
     - off — keep off
     - Latent hook only; port-92 fast-A20 is pinned in PL (gates the address
       bus).
   * - **Peripheral tunables and debug instrumentation**
     -
     -
     -
   * - ``VEN_IDE_DISK_HEX``
     - valued define (path)
     - undefined — no disk load
     - Hex disk-image path ``$readmemh``-loaded into ``ven_ide``'s backing
       store.
   * - ``VEN_IDE_DISK_SECTORS``
     - valued define (int)
     - 128
     - Disk size in sectors; sizes the array, the LBA28 bound and IDENTIFY.
   * - ``VEN_IDE_CYLS``
     - valued define (int)
     - 2
     - IDE logical cylinder count (IDENTIFY geometry).
   * - ``VEN_IDE_HEADS``
     - valued define (int)
     - 16
     - IDE logical head count (IDENTIFY + CHS→LBA translation).
   * - ``VEN_IDE_SECS``
     - valued define (int)
     - 63
     - IDE sectors per track (IDENTIFY + CHS→LBA translation).
   * - ``VEN_IDE_TRACE``
     - boolean define
     - off
     - Five ``$display`` trace points on the IDE register/data paths.
   * - ``VEN_RTC_EXTMEM_KB``
     - valued define (int)
     - 0 — legacy CMOS
     - Seeds the CMOS extended-memory registers SeaBIOS sizes RAM from.
   * - ``VEN_PIT_TICK_DIV``
     - valued define (int)
     - 1024
     - PIT tick prescaler — simulation IRQ0 cadence only.
   * - ``VEN_DBG_WD``
     - boolean define
     - off
     - One-shot 150 000-cycle no-retire watchdog ``$display``.
   * - ``VEN_DBG_SSBASE``
     - boolean define
     - off
     - Real-mode segment-base / high-ESP forensic probes.

x87 FPU implementation
======================

This family covers the flags around the x87 FPU: the radix-4 SRT FDIV/FSQRT
datapath, the FBSTP/FBLD packed-BCD converters, the FP-execute commit
pipeline, the in-core transcendental engines, and two P5 cycle-model "gap"
features (FDIV/integer overlap, free FXCH). The default build uses
single-cycle combinational x87 functions (``rtl/fpu/fpu_x87_pkg.sv``,
``rtl/core/ventium_x87_pkg.sv``) that are bit-exact against QEMU softfloat at
every retire — and note that the genuine SRT divider with the *correct* PLA is
now the ``fx_div`` **default** (still bit-exact); ``VEN_DIV_EXACT`` opts back
to the behavioural wide divide.

The family splits cleanly in two. The implementation/Fmax options
(``VEN_SRT_ITER``, ``VEN_BCD_ITER``, ``VEN_FP_PIPE``, ``VEN_FP_PIPE2``,
``VEN_BCD_DIV100``, ``VEN_DIV_EXACT``) must stay bit-exact and band-safe; the
first four are what the KV260 FPGA builds set, while ``VEN_BCD_DIV100`` and
``VEN_DIV_EXACT`` are manual/sim-side options in the same class. The architectural opt-ins change visible
behaviour and carry their own oracles and gates: ``VEN_SRT_FDIV_BUG`` (the
authentic Pentium FDIV flaw), ``VEN_TRANSCENDENTAL`` (eight new instructions),
and ``VEN_FP_OVERLAP``/``VEN_FXCH_FREE`` (cycle-trace changes graded against
``fpovl=1``/``fxchfree=1`` variants of the ``p5trace`` oracle). Two names in
this family are *not* live ``ifdef``\ s at all: ``VEN_SRT_DIV`` is a legacy flag
whose semantics became the default in commit ``3791e46``, and
``VEN_TRSC_SILICON`` is a reserved, intentionally inert name.

``VEN_FP_PIPE``
---------------

Enables the 1-deep FP-execute commit pipeline that splits the
``eip → icache → decode → f_eval → fpr`` critical cone across two clocks.
``fx_add`` alone is roughly 14 ns of logic, so a single-cycle FP execute can
never clear 66 MHz (problem P0-5 in ``fpga/TIMING_PROBLEMS.md``). Without the
flag, ``f_eval`` is computed *and* committed in the same clock as issue (fast
arm) or as ``S_FEXEC`` dispatch (slow arm); the ``fpp_*`` registers are absent
and the ``we_wabs`` port is tied 0.

On the **fast arm** (cycle-mode ``S_PIPE`` arithmetic), issue captures the
operands, aluop, rounding control and *absolute* destination into ``fpp_*``
pipeline registers; the result is computed the next clock from the registered
operands and written through a new absolute-indexed
``we_wabs``/``we_wabs_fstat`` port on ``rtl/fpu/fpu_top.sv``. A one-clock
read-after-write hazard (``fp_pipe_rd_haz``) stalls a same-clock role-0/1
reader of the in-flight target. On the **slow arm** (``S_FEXEC``
memory-operand arithmetic), the ``s_arf`` cone is dropped and a new FSM state
``S_FEXEC_EX`` evaluates from the registered ``fpp_*`` and commits via
``we_wabs`` *in the same clock as the retire* (``rtl/core/core_fp_exec.svh``).
That same-clock pairing is mandatory: the functional differential harness
checks architectural state at retire, so a plain one-clock defer would read
stale state — the documented functional-mode-retire-check trap. The FP
scoreboard already publishes results at ``issue + latency`` (``fadd`` = 3), so
the N+1 commit lands before any role ≥ 2 consumer reads it and the M5 FP
cycle bands hold by construction. The flag also cut area: LUT utilisation
91.7 % → 82.85 %.

It gates the ``S_FEXEC_EX`` state, the ``fpp_*`` capture/advance registers,
the ``we_wabs`` port group, the suppression of the same-cycle
``fp_we_top``/``fp_we_fstat`` writes, and the issue-side commit bubble — all
in ``rtl/core/core.sv``, ``rtl/core/core_fp_exec.svh``,
``rtl/core/core_fastpath.svh`` and ``rtl/fpu/fpu_top.sv``.

Set by every KV260 SoC bitstream config (``fpga/scripts/impl_kv260_soc.tcl``),
the half-cache and path-probe scripts (``fpga/scripts/apr_hc_pnr.tcl``,
``fpga/scripts/synth_paths_retime.tcl``,
``fpga/scripts/synth_paths_icbram.tcl``), and the A/B cycle gate's base define
set (``verif/fppipe/run-fp-pipe2-ab.sh``). It composes with ``VEN_SRT_ITER``:
with it, the deferred commit uses the split
``f_eval_s2(f_eval_s1(...))`` sharing a single ``round_pack`` cone (−999 LUT),
safe only because the iterative engine owns divide; without it the full
``f_eval`` is kept, because divides do defer through this port. It is the
parent of ``VEN_FP_PIPE2`` (whose ``ifdef`` is nested inside it), and the
``VEN_FXCH_FREE`` fold only absorbs an FXCH after a *push* because the
arithmetic path defers under this flag.

One honest caveat: ``fp_pipe_rd_haz`` protects role-0/1 readers
(FXCH/FLDSTI/slow FST/FCOM), but the icache LRU-touch driver does not
replicate the bubble; the code argues this is band-safe because those readers
never appear in the graded throughput kernels. ``VEN_FP_PIPE`` is therefore
*band-preserving*, not proven byte-cycle-identical for arbitrary role-0/1
sequences. Validation: the default ``make verify`` 75/75 is unaffected; with
the flag, ``make m3`` 75/75, ``make verify`` 75/75, and ``mb_faddchain`` CPI
2.989 / ``mb_fpindep`` 1.152 — both in band.

``VEN_FP_PIPE2``
----------------

The second pipeline stage for the FP commit — the flag behind the K26
half-cache 60 MHz milestone (see :doc:`/microarch/fp-commit-pipeline`). With
``VEN_FP_PIPE`` alone, the deferred commit runs the *whole* ``f_eval``
(``s1`` front → ``s2`` round) in the single commit clock — an ~80-level /
~43-CARRY8 cone from ``fpp_*`` through ``fx_round_pack`` to ``fpr`` that caps
routed Fmax around 52 MHz. ``VEN_FP_PIPE2`` inserts exactly one register
(``fpp2_s1``, of type ``fx_pipe_t``) at the ``f_eval_s1``/``f_eval_s2``
boundary: the captured op's front half (unpack/align/add-or-mul) runs in clock
N+1 and only the short round-pack plus the ``we_wabs`` write runs in N+2. The
result lands in ``fpr`` at issue+2, still at or before the scoreboard publish
at issue+3, so per-retire architectural state and the FP cycle bands are
*identical* to the 1-stage build with no oracle change. The read-after-write
hazard window widens to span both in-flight slots.

Measured on the half-cache OOC build: routed 63.0 MHz (then 65.3 MHz with
``VEN_BCD_DIV100``); synthesis sees the FADD cone leave the critical path
(59.4 → 78.4 MHz synth), the worst path becomes the iterative BCD engine
(``u_bcd``), and only with ``VEN_BCD_DIV100`` added does the binder move to
the ``fpp → fpp2_s1`` stage-1 front (``docs/fpga-synthesis.md``). It is proven
**cycle-safe by a dedicated A/B gate** (``verif/fppipe/run-fp-pipe2-ab.sh``,
``make verify-fppipe2``) that builds two testbenches differing only by this
define and requires the A and B ``--cycle`` traces to be byte-identical on
both kernels (``mb_faddchain`` and ``mb_fpindep``), plus a separate band
check of B against the ``p5trace`` golden (12 % tolerance) on each.

Set by ``fpga/scripts/impl_kv260_soc.tcl`` (production define list), by
``fpga/scripts/apr_hc_pnr.tcl`` when the ``FP_PIPE2=1`` environment knob is
given (output tagged ``_fp2``), and as TB "B" of the A/B gate. It **requires
``VEN_FP_PIPE``** (nested ``ifdef`` — silently inert without it) **and
``VEN_SRT_ITER``**: the split eval's divide arm returns an early zero, which
is only unreachable because the iterative engine owns divide. There is no
compile-time error if ``VEN_SRT_ITER`` is missing — such a build would
silently mis-divide deferred FDIVs; the guard is by convention. Note also that
the A/B gate proves equivalence to the 1-stage build, not directly to the
default — it deliberately inherits ``VEN_FP_PIPE``'s band/oracle validation.

``VEN_FP_OVERLAP``
------------------

Gap 1 of the P5 cycle-model gaps identified from the RTL Engineering
transcripts and shared with the ``p5trace.c`` oracle: the real P5 overlaps
independent integer work with a long FDIV, the default model does not. Without
the flag there is one in-order ``pipe_free_at = issue + occ`` — an FDIV
(occupancy 39) blocks even independent *integer* ops behind it for the full
39 clocks, matching the default oracle.

With the flag, a 32-bit ``fp_busy_cyc`` register models when the single x87
execution unit becomes free. An issuing FP arithmetic op holds the integer
pipe only ``P5_FP_ISSUE_OCC = 2`` clocks (retiring at issue+2) while the real
occupancy window moves onto ``fp_busy_cyc`` — so following independent integer
ops issue and retire inside the FDIV shadow, while a following FP op (FXCH
exempt, as a rename) waits until ``fp_busy_cyc``. The wait is mirrored in all
three replicated guards — the fast-path issue arm
(``rtl/core/core_fastpath.svh``), the icache LRU-touch driver and the
``fp_we_*`` commit driver (``rtl/core/core.sv``) — so spine and drivers agree
on the commit clock.

This is an **architectural (cycle-trace) change**: ``mb_fdivint``'s CPI drops
from the serialized ~1.73 to the 1.20–1.47 band. It therefore has its own
differential gate: ``verif/run-m5.sh`` builds a separate testbench into
``obj_dir_fpovl`` with ``+define+VEN_FP_OVERLAP`` and grades only the manifest
``"fpovl": true`` kernels against an ``fpovl=1`` variant of the ``p5trace``
oracle; every other kernel keeps the default golden and testbench
byte/cycle-identical. ``verif/m5_metrics.py`` enforces a two-part band:
(1) CPI below the 1.50 ceiling of the serialized default (overlap present)
and (2) absolute cycles tracking the ``fpovl=1`` golden within tolerance —
the trailing FP producer still paying the unit-busy wait is a property of
the kernel and its golden (the manifest band description), pinned only
indirectly through the absolute-cycle match. No FPGA config or default
verify build sets it. It must never be
combined with the default golden — and note the inversion of fidelity: this
flag is the *more* faithful P5 model; the default build is the one matching
the unmodified oracle, not real silicon.

``VEN_FXCH_FREE``
-----------------

Gap 2: the real P5 FXCH is a free stack rename; by default every FXCH costs
``occ = 1`` (its own commit clock), so a ``fadd``+``fxch`` pair is 2 clocks —
matching the default oracle. With the flag, decode marks ``D9 C8+i`` with
``is_fxch_free = 1`` and ``fp_occ = 0`` (``rtl/core/decode.sv``; the field
exists unconditionally in ``rtl/core/ventium_decode_pkg.sv``). In the cycle
fast path, a free ``fxch %st(i)`` (i ≠ 0) that directly follows a push
(``FK_FLDC`` constant load or ``FK_FLDSTI``) folds into that push's commit
clock for zero added cycles: the architectural effect is computed as one
combined write — ``we_push`` places the old ``st(i-1)`` into the new ST0 slot
and ``we_sti(i-1)`` places the pushed constant/copy into ``st(i)``, using
pre-edge ``ftop`` addressing — while the spine retires the FXCH as the V-pair
member (``retire2_*``) and advances ``eip`` past both instructions
(``rtl/core/core_fastpath.svh``). A lone or post-arithmetic FXCH falls through
to its own ``occ = 1`` commit; only a push absorbs it, because under
``VEN_FP_PIPE`` the arithmetic result is deferred and not yet in ``fpr`` at
the would-be fold clock.

Architectural cycle-trace change with its own gate: ``verif/run-m5.sh`` builds
a separate testbench into ``obj_dir_fxch`` and grades only the manifest
``"fxchfree": true`` kernels (``mb_fxch``) against the ``fxchfree=1`` oracle.
No FPGA config or default build sets it. Gotchas: ``fxch %st(0)`` is
deliberately *not* folded (the ``fp_sti != 0`` guard), and the combined write
relies on pre-edge ``ftop`` addressing (``we_push`` targets ``fpr[ftop-1]``,
``we_sti(i-1)`` targets ``fpr[ftop+i-1]``) — easy to mis-derive when reasoning
about the swap.

``VEN_SRT_ITER``
----------------

Routes normal-operand FDIV/FDIVR and positive-normal FSQRT through
multi-cycle iterative engines — the D8b/P0-1 rework that made the core fit the
KV260 at all (commit ``3791e46``: LUT 518 % → 111 %, DSP 320 → 95). Without
it, FDIV/FSQRT execute combinationally in one ``S_FEXEC`` clock via
``fx_srt_div`` (36 radix-4 steps fully unrolled — roughly 126 256-bit adders
in synthesis) and ``fx_sqrt`` (a 128-step restoring isqrt): fine for
Verilator, hopeless for FPGA timing and area.

The flag adds the FSM state ``S_FP_BUSY`` and instantiates
``rtl/fpu/fpu_srt_div.sv`` (one radix-4 SRT step per clock, ``NSTEP = 36``,
the per-step body lifted verbatim from ``fx_srt_div`` so the committed
``floatx80`` is bit-identical) and ``fpu_sqrt_iter``. Eligibility is computed
in the ``fp_we_*`` driver: finite-nonzero ``a`` and ``b`` for divide (all six
``FX_AR_*`` forms with aluop 6/7, excluding runtime-errata divides),
finite-nonzero non-negative ST0 for sqrt. Eligible ops start the engine from
``S_FEXEC``, the FSM busy-waits, and result plus ``fstat`` commit through the
same write ports on the engine-done clock, retiring that clock. Because every
operand that would reach the deep loops is engine-routed, both combinational
loops are **stubbed out of synthesis** under the flag (``fx_srt_div`` returns
a zero-significand placeholder for finite-nonzero operands; ``fx_sqrt``'s
finite-nonzero arm likewise stubs out the isqrt loop, returning the operand
unchanged) — the zero/Inf/NaN guards remain live. ``rtl/core/decode.sv``
additionally drops ``fdiv``/``fdivr`` from the cycle fast-path FP
classification so they always take the slow FSM.

Functionally bit-exact: ``make m3`` with the flag passes 74/74 including
``tx_sqrt``, and the standalone ``verify-srt-iter`` gates assert bit-exactness
against the golden for *both* PLAs. Execution latency becomes the engine step
count — an implementation artifact, **not** the P5 occ-39; the FP scoreboard
deliberately keeps the fixed oracle latencies, and the functional harness
needs a larger quiesce window (``verif/run-m3.sh``'s ``QUIESCE`` env knob
defaults to 64 — pass ``QUIESCE=512`` for the ``+VEN_SRT_ITER`` build, the
in-script comment's recommended value; an FSQRT idles ~66 clocks).

Set by every FPGA define list and synthesis probe, by the A/B gate's base
defines, and documented as the canonical ``VL_EXTRA_DEFINES`` example in
``verif/tb/Makefile``. It is the by-convention prerequisite for
``VEN_FP_PIPE``'s split-eval optimisation and for ``VEN_FP_PIPE2``; the
engine's buggy-PLA input mirrors ``VEN_SRT_FDIV_BUG`` (``ENG_DIV_BUGGY``), so
the FDIV flaw survives the iterative rewrite.

Two gotchas. First, bit-exact is not timing-neutral: the quiesce window must
be raised and cycle-mode fdiv bands do not apply. Second, the errata
interplay: a runtime ``ERR_FDIV``-enabled divide is excluded from the engine
route and falls back to ``fx_div_errata → fx_div → fx_srt_div`` — whose
finite-nonzero path is *stubbed* under this flag — so the M6 Erratum-23
runtime mode appears broken under ``+VEN_SRT_ITER`` (even the canonical
published vector takes sign/exponent from the stubbed "clean" value). The M6
errata gates run on the default build; that combination is unverified
territory.

``VEN_SRT_DIV``
---------------

**Legacy, vestigial — defining it today changes nothing**; there is no live
``ifdef VEN_SRT_DIV`` anywhere in the RTL. At M8.5 (commit ``9e6e329``) the
``fx_div`` dispatcher read ``ifdef VEN_SRT_DIV → fx_srt_div`` (with nested
``VEN_SRT_FDIV_BUG`` selecting the buggy PLA), ``else → fx_div_exact``.
Commit ``3791e46`` inverted the polarity: the genuine SRT datapath with the
correct PLA became the unconditional hardware default ("bit-exact vs
``fx_div_exact``/QEMU"), and the opt-*out* became ``VEN_DIV_EXACT``.

The name now survives only in comments and documentation — the feature header
in ``rtl/fpu/fpu_x87_pkg.sv``, a ``Makefile`` note, and *stale* docs that
still describe the old default: ``verif/srt/README.md`` ("with no defines the
divider is ``fx_div_exact``") and ``docs/sphinx/microarch/srt-divider.rst``
both contradict the current code, while ``fpga/TARGETS.md`` has the current
truth. Nothing in the build system sets it; both PLAs are graded by
``verify-srt`` against ``tools/srt/srt_model.py`` with the testbench driving
the ``buggy`` input directly, no define needed. Anyone auditing "which divider
is default" from the README will get the wrong answer.

``VEN_SRT_FDIV_BUG``
--------------------

Selects the **buggy quotient-selection PLA** — the authentic Pentium FDIV
flaw, reproduced from first principles with no operand special-cased.
``fx_srt_pla`` in ``rtl/fpu/fpu_x87_pkg.sv`` models the five PLA cells that
should hold +2 but were never programmed (Edelman: ``8*P_Bad`` in
{23, 27, 31, 35, 39} for divisor columns ``d4`` in {1, 4, 7, 10, 13}); with
``buggy = 1`` those cells return digit 0. The define flips two sites: the
combinational dispatcher ``fx_div`` passes ``buggy = 1'b1``, and — under
``VEN_SRT_ITER`` — the iterative engine's ``ENG_DIV_BUGGY = 1'b1``
(``rtl/core/core.sv``), so the flaw survives the multi-cycle rewrite.

Validated outcomes: ``4195835/3145727`` flaws to
``0x3FFF_AAB7F6392A768638`` (the documented double ``0x3FF556FEC7254ED1``,
wrong at the 13th significant bit, the bug hit at iteration 8);
``5505001/294911`` also flaws; the negative controls ``7654321/3145727`` and
``4195835/3.0`` stay clean. This is an architectural change — deliberately
*not* bit-exact vs QEMU — so it can never join the default verify track. Its
oracle is the single-source Python golden ``tools/srt/srt_model.py``; the
``verify-srt``/``verify-srt-iter`` gates grade both PLAs by driving the
``buggy`` input directly, so they pass without the define being set. It is
distinct from the M6 runtime Erratum-23 model (``fx_div_errata``,
``errata_en`` bit 0), which only reproduces the one published vector and stays
in the default build.

No committed config sets it — purely a user opt-in. Gotchas: QEMU computes
the *correct* quotient, so any differential gate against QEMU will (correctly)
fail under this flag; ``VEN_DIV_EXACT`` is checked first in ``fx_div``, so
combining the two silently yields the exact divider with no flaw; and a
triggering divisor alone is not sufficient to flaw (``7654321/3145727`` is
clean), so spot-checking with one operand pair gives false confidence either
way.

``VEN_DIV_EXACT``
-----------------

The opt-**out** escape hatch: routes ``fx_div`` to ``fx_div_exact``, a plain
behavioural wide-integer divide ("kept as a fast-sim escape hatch; NOT the
hardware path"). Because both ``fx_div_exact`` and the correct-PLA
``fx_srt_div`` are correctly-rounded ``floatx80`` division — validated equal
over an 8 000-divide random corpus — the flag is architecturally neutral;
results stay bit-exact vs QEMU. It exists purely to make pure-Verilator
simulation of the combinational divider cheaper (the unrolled SRT function is
a 36-step loop per call in sim).

It is checked *first* in the ``fx_div`` dispatcher, so it takes silent
precedence over ``VEN_SRT_FDIV_BUG``. Under ``VEN_SRT_ITER`` it is largely
moot for committed results — normal divides are engine-routed before
``fx_div`` is consulted — but the non-engine fallback paths (specials, the
errata path) still call ``fx_div``, which makes ``VEN_DIV_EXACT`` the actual
workaround if runtime ``ERR_FDIV`` semantics were ever needed under
``VEN_SRT_ITER``. Nothing in committed configs sets it (documented in
``fpga/TARGETS.md``). Despite the name it is not "more exact" than the
default — both are correctly rounded — and the stale ``verif/srt/README.md``
still calls ``fx_div_exact`` the default; the code comment in
``rtl/fpu/fpu_x87_pkg.sv`` is authoritative.

``VEN_BCD_ITER``
----------------

Replaces both rare-but-deep packed-BCD conversion cones with multi-cycle
iterative engines. Without it, FBSTP converts FP → packed BCD via the
combinational ``fx_fx_to_bcd`` (18 *chained* divide-by-10 stages, an
~182-deep CARRY8 cone — historically the whole core's worst timing path)
inside the ``fstore_val`` mux, and FBLD pushes ``fx_bcd_to_fx`` (18 chained
multiply-by-10, ~189 levels — the worst pure-logic path once FP arithmetic was
pipelined) directly in ``S_FEXEC``.

The flag adds two FSM states. **FBSTP**: ``S_FEXEC`` starts
``rtl/fpu/ven_bcd.sv``, which performs the FP → int64 conversion once in its
idle state (including the 10^18/int64 overflow check producing the packed-BCD
indefinite and IE), then extracts the 18 BCD digits at two divide-by-10 steps
per clock (~9 clocks); the FSM waits in ``S_BCD_BUSY``, latches
``{ie, pe, bcd}`` on done, feeds it to ``fstore_val``, and the IE/PE ``fstat``
sticky is *deferred* to the engine-done clock, because the flags are not known
at dispatch. **FBLD**: ``S_FEXEC`` defers the push and starts
``rtl/fpu/ven_bcd_to_fp.sv``, which accumulates digits MSD-first at two
multiply-by-10 steps per clock and converts int64 → ``floatx80`` once at the
end; the push of the engine result is driven on the done clock, the *same*
clock ``S_FBLD_BUSY`` retires, so per-retire architectural state is exact.

Both engines are bit-exact to their combinational originals (``make
verify-bcd`` / ``make verify-fbld``; ``make m3`` with the flag is 74/74
including ``tx_bcd_st``/``tx_bcd_ld``). A pure implementation/Fmax-area
option — no architectural change, no dedicated differential oracle needed
beyond the standalone bit-exact gates plus the m3 run. Set by every KV260
config, the half-cache and probe scripts, and the A/B gate base defines. It is
the parent of ``VEN_BCD_DIV100``, and the FBLD engine was motivated by
``VEN_FP_PIPE`` (which made ``fx_bcd_to_fx`` the worst logic path). Gotcha:
FBSTP's IE/PE flags *must* be deferred — the generic store sticky-flag arm is
explicitly skipped for ``FX_FBSTP``; forgetting that pairing is the classic
way to double-set or zero the flags.

``VEN_BCD_DIV100``
------------------

A micro-optimisation *inside* ``ven_bcd``'s per-clock digit-extract step, so
it is meaningless without ``VEN_BCD_ITER``. By default the step extracts two
digits with two chained divide-by-10 operations (~54 levels / ~41 CARRY8 in
series). With the flag it computes a single divide-by-100 (the only wide
reciprocal-multiply on the ``q`` feedback) and derives both low digits from
the 7-bit remainder, halving the per-clock carry cone. It is bit-exact *and*
cycle-neutral — the two-digits-per-clock cadence, state machine and outputs
are unchanged; ``make verify-bcd`` (40 k vectors) passes either way and the
default ``make verify`` stayed 77/77 (commit ``a26045d``).

A pure Fmax option with a narrow applicability window: it only helps when
``u_bcd`` is the worst path, which is true in the OOC
half-cache + ``VEN_FP_PIPE2`` configuration (synthesis 78.4 → 80.6 MHz,
routed 63.0 → 65.3 MHz on the XCK26) — in the full SoC the eip/TLB front-end
cluster binds long before ``u_bcd``, so the committed configurations leave it
**off** there. No committed
script or config sets it; it was applied manually (an extra define on the
``apr_hc_pnr.tcl`` define list) during the half-cache experiments. The
default is deliberate: even though strictly bit-exact and
cycle-neutral, it only pays when ``u_bcd`` is the binding path — which the
full SoC is not.

``VEN_TRANSCENDENTAL``
----------------------

The architectural opt-in for the eight x87 transcendental instructions
(project issue #11). Without it, the ``D9 F0/F1/F2/F3/F9/FB/FE/FF`` opcodes
(F2XM1, FYL2X, FPTAN, FPATAN, FYL2XP1, FSINCOS, FSIN, FCOS) stay
``d_unknown`` in decode and the core **HALTs** on them, keeping ``make
verify`` 77/77 byte-identical.

With the flag, decode arms appear, ``S_FEXEC`` routes the eight fxops to a new
busy-wait state ``S_TRSC_BUSY``, and four engine instances are created:
``rtl/fpu/fpu_f2xm1.sv`` (a verbatim transcription of qemu-8.2.2's
``helper_f2xm1`` and its softfloat routines, with a 65-entry ROM),
``fpu_fpatan``, ``fpu_fyl2x`` (a mode input serves both FYL2X and FYL2XP1)
and ``fpu_fsincos`` (one engine computes sin *and* cos, serving
FSIN/FCOS/FSINCOS/FPTAN; octant reduction via a 3-part Cody-Waite π/2 plus
Taylor). Commit happens on the engine-done clock, which is the retire clock:
F2XM1 overwrites ST0 in place; FPATAN/FYL2X/FYL2XP1 write ST1 then pop;
FSINCOS does ``we_top(sin)`` plus ``we_push(cos)``; FPTAN commits
``tan = fx_div(sin, cos)`` and pushes +1.0; out-of-range trig (\|x\| ≥ 2^63)
sets C2 and leaves ST0 unchanged.

The oracle is split (``verif/trsc/README.md``). **Group B**
(F2XM1/FPATAN/FYL2X/FYL2XP1) is bit-exact vs ``qemu-i386``, whose softfloat is
deterministic there; the executable reference is ``tools/p5xtrans/qref.c``,
itself validated bit-for-bit against the pinned QEMU. **Group A**
(FSIN/FCOS/FSINCOS/FPTAN) deliberately *diverges* from QEMU (which calls the
host glibc at double precision) and is instead bit-exact vs the
silicon-accuracy shared-polynomial model (~1.8 ulp vs ``__float128``; the
core-vs-qemu spread of ~1000 ulp is reported, not gated). The flag therefore
has its own gate suite: standalone engine gates against ``qref`` in all four
rounding modes, plus in-core gates that build the cosim testbench with the
define into ``obj_dir_trsc`` and run the ``tx_*`` differential programs. FP
scoreboard timing is unchanged (engine done-latency is an implementation
artifact per ``docs/m11-transcendental-spec.md``). It is **not** in any FPGA
config.

Interactions: the engines reuse ``fx_mul``/``fx_add`` from ``fpu_x87_pkg``,
and the FPTAN commit calls ``fx_div`` — so the division flags
(``VEN_DIV_EXACT``/``VEN_SRT_FDIV_BUG``) influence FPTAN's tangent. Under
``VEN_SRT_ITER`` that ``fx_div`` call sits *outside* the engine-routed path,
i.e. on the combinational ``fx_div`` whose finite-nonzero SRT body is stubbed
— verify before combining the two flags for FPTAN; the committed trsc gates
run without ``VEN_SRT_ITER``. Gotchas: a naive QEMU diff on FSIN/FCOS fails
by design (the checker compares against the model instead), and the
default-build behaviour for these opcodes is HALT, not a #UD trap — real-world
code using transcendentals requires the flag.

``VEN_TRSC_SILICON``
--------------------

Reserved and currently **unimplemented**: there is no
``ifdef VEN_TRSC_SILICON`` anywhere in the RTL or build system — the name
exists only in comments (``rtl/fpu/fpu_f2xm1.sv``, ``tools/p5xtrans/qref.c``);
the M11 spec documents the ``SILICON`` parameter seam and the design
conclusion without ever naming the macro. The seam it would drive does exist: every transcendental
engine declares ``parameter bit SILICON = 1'b0`` (``fpu_f2xm1``,
``fpu_fpatan``, ``fpu_fyl2x``, ``fpu_fsincos``), and the instances in
``rtl/core/core.sv`` never override it.

The inertness is a design conclusion, not an omission.
``docs/m11-transcendental-spec.md`` records that (a) bit-exact-to-silicon is
unachievable from public data (undumped transcendental microcode, unpublished
Remez coefficients), and (b) for Group B, QEMU's softfloat algorithm *is
itself* the accuracy-faithful silicon one (80-bit table + Horner +
reconstruct, ~0.5 ulp) — a single datapath serves both the bit-exact-vs-qemu
gate and silicon fidelity, so the parameter is reserved/inert. For Group A the
shipped shared-polynomial model already is the silicon-accuracy target.
``tools/p5xtrans/p5xtrans.c`` remains the independent silicon-accuracy oracle
(agrees with ``qref`` to <1 ulp). If the flag were ever implemented it would
be an architectural-mode change requiring its own silicon-model oracle, since
the QEMU differential gates for Group B would no longer apply. Do not assume
it does anything because comments reference it.

Front-end and L1 caches
=======================

This family covers the fetch/decode front end — the BTB, the icache, the
predecoded micro-op cache, the page-keyed fetch micro-TLB — and the parametric
L1 geometry knobs. Per project convention every flag is opt-in: the default
build is the byte/cycle-identical golden-matched reference, and each flag is
one of (a) a bit-exact Fmax/area implementation option whose cycle behaviour
is identical or stays inside the loose M4/M5 bands (``VEN_BTB_PIPE``,
``VEN_IC_NARROWB``, ``VEN_IC_BRAM``); (b) an architecturally bit-exact but
explicitly non-cycle-faithful demonstrator (``VEN_FE_PIPE``,
``VEN_CACHE_HALF``) plus the common-case-correct, not-yet-verify-hardened
``VEN_UOPCACHE``; or
(c) a numeric geometry parameter for cache sweeps (``VEN_IC_SETS``,
``VEN_IC_WAYS``, ``VEN_DC_SETS``, ``VEN_DC_WAYS``, plus the umbrella
``VEN_L1_SETS``/``VEN_L1_WAYS`` pair described with the SoC platform family).

The deployable KV260 SoC bitstream sets ``VEN_BTB_PIPE`` + ``VEN_IC_BRAM`` +
``VEN_UOPCACHE`` + ``VEN_CACHE_HALF`` + ``VEN_FE_PIPE`` (plus the FP and
iterative-engine flags), via ``fpga/scripts/impl_kv260_soc.tcl``; simulation
sweeps set the geometry knobs through ``verif/tb/Makefile``'s
``VL_EXTRA_DEFINES`` passthrough into separate object directories. The
narrative arc documented in ``fpga/TIMING_PROBLEMS.md`` and
``docs/fpga-synthesis.md``: the single-cycle x86 byte-window decode's MUXF
density is the congestion wall, the micro-op cache is the only lever that ever
reduced it (first OOC route, 51.7 MHz), half-cache relieved the tail, and
``VEN_FE_PIPE`` made the full SoC route at all.

``VEN_BTB_PIPE``
----------------

Registers the BTB resolve inputs (``resolve_valid``/``resolve_pc``/
``resolve_taken``) one clock, so the 2-bit-counter update's clock enable comes
from a flop instead of the combinational ``issue_arm`` net
(``rtl/core/bpred_btb.sv``). This lifts the ~13-level BTB tail off the
~63-level ``eip → icache → decode → issue_arm → btb_ctr`` critical path. The
predict ports always read pre-update state (read-before-write off the
registered arrays), so applying the update one clock later only shifts *when*
the predictor warms — it never changes which instructions retire, only (in
principle) prediction timing.

A three-agent investigation established that BRAM was the wrong fix for this
path (the BTB is 64 deep, won't infer BRAM, and is only 21 % of the path); the
registered update is the cycle-safe lever, and it measured **cycle-neutral** —
``mb_brloop``/``mb_brrandom`` absolute cycle counts identical to baseline —
while taking OOC synthesis from 58 to 59.5 MHz (P0-6, commit ``ab3001e``).
Purely an implementation/Fmax option, included in essentially every FPGA
config (the deployable SoC, both ``apr_run.tcl`` configurations,
``apr_hc_pnr.tcl``, ``bd_kv260_soc.tcl``, the path/probe scripts — which mark
it as a removable define) and in the A/B sim builds of the FP_PIPE2 gate, so
the cycle-equivalence gate implicitly exercises it in simulation.

One nuance: the in-module comment claims the delayed update is absorbed by the
loose cycle bands, but P0-6 measured it stronger — absolute cycles identical
on the branch kernels. Strictly, it *can* change a prediction by one resolve,
so treat it as bit-exact-architectural / band-validated-cycle rather than
formally cycle-identical.

``VEN_UOPCACHE``
----------------

The P0-11 predecode-on-fill micro-op cache — the textbook P6/Sandy-Bridge fix
for the x86 byte-window MUXF congestion wall. Without it, the fast path
gathers twelve bytes via the ``ub[]``/``vb[]`` 32:1 byte selects out of the
two icache line buffers and decodes U and the V candidate live each clock with
two ``decode`` instances.

With the flag, ``rtl/mem/uopcache.sv`` is enabled: a 3-state walker FSM
re-runs the *same* pure ``decode`` leaf over a freshly filled 32-byte line
after the multi-cycle ``S_PF`` fill completes (the spine never stalls on the
walker — its ``pd_busy`` output is unconnected) — decoding the fixed bottom
6 bytes of a
``residual`` register and barrel-shifting right by the decoded length, so no
``flin``-indexed wide byte mux ever exists — and stores ``NSLOT = 8``
fixed-width ``fpd_t`` slots plus a 32-entry byte→slot boundary map per
(set, way) in registered-read (``ram_style = "block"``) BRAM stores replicated
A/B. In ``rtl/core/core.sv`` the spine accumulates the fill burst into
``pf_line_buf`` and pulses ``pd_start`` the clock after ``fill_done`` (also
invalidating that set/way's predecode-valid); the fast path then *deletes* the
twelve 32:1 byte gathers and the live decoders, reading
``u_d = slotsA[bslot(flin[4:0])]`` and ``v_d`` as literally the next slot
(killing the ``flin + lenU`` V-base serialization too), with ``br_taken`` —
the only flag-dependent ``fpd_t`` field — re-evaluated against live
``eflags``.

Results: the first-ever MUXF reduction (MUXF7 −22 %, MUXF8 −33 %) and the
first configuration to *route* OOC at 15 ns (51.7 MHz routed, where the
narrowb config dies with 42 392 overlaps). Its registered slot-read timing
mirrors ``VEN_IC_BRAM``, and every setter defines the two together: the
deployable SoC, ``apr_run.tcl`` (CONFIG=uopcache), ``apr_hc_pnr.tcl``, and the
uopcache path/probe scripts.

The major caveat: **not verify-hardened**. The architectural-correctness
backstops are unbuilt — ``uop_hit`` and ``uc_v_avail`` are computed but
consumed *nowhere*, and the planned ``S_PIPE !uop_ready`` stall arm and
branch-into-the-middle re-predecode are explicitly still unbuilt
(``fpga/TIMING_PROBLEMS.md``, ``docs/fpga-synthesis.md``). A fetch from a
resident-but-not-yet-predecoded line, or a branch into the middle of a
predecoded boundary, reads stale or wrong slots with no stall. It is a
synthesis/APR Fmax demonstrator (common-case correct), not a
differential-gate-verified configuration — yet it *is* in the deployable
KV260 bitstream. The default/narrowb build is the verified production
reference. It also conflicts with any I-cache wider than 2 ways: the uopcache way
ports are 1 bit and the store is sized ``IC_SETS*2``, so
``VEN_IC_WAYS``/``VEN_L1_WAYS`` greater than 2 with ``VEN_UOPCACHE`` would
silently alias ways (1-way is safe but wastes half the slot store).

``VEN_UOPCACHE_CHECK``
----------------------

A sim-only structural-equivalence scaffold layered inside the
``VEN_UOPCACHE`` branch: it re-instantiates the live ``ub[]``/``vb[]``
byte-window gather plus two reference decoders (producing
``u_d_ref``/``v_d_ref`` from the actual icache bytes) alongside the slot-read
``u_d``/``v_d``, with the stated intent of asserting that the slot read equals
the live gather decode for every issued ``flin``. The ``ifdef`` block lives
solely in ``rtl/core/core.sv``; ``rtl/mem/uopcache.sv`` carries only a header
comment describing the flag, whose "asserts slot read == live decode" wording
is aspirational. Because it resurrects the 12 × 32:1 gather it must
never appear in a synthesis build.

As of the current tree the define only builds the parallel reference path:
**no assert or comparison statement consumes** ``u_d_ref``/``v_d_ref``
anywhere (true since the introducing commit ``4cdf7eb``). The "equivalence
gate" is scaffolding for manual waveform comparison or future hardening, not
an automated checker; any claim that the uopcache is machine-checked
equivalent via this flag is unsupported. No build script sets it — manual
``VL_EXTRA_DEFINES`` use only, and it is a no-op without ``VEN_UOPCACHE``
(the block is nested). Closing the gap — a real per-issue assert plus the
``uop_ready`` stall — is the documented verify-hardening work.

``VEN_FE_PIPE``
---------------

A page-keyed micro-TLB register that breaks the architectural ``eip``
self-loop (``eip`` → I-TLB hit carry chain → ``ic_present`` → uop slot read →
next ``eip``) — the cone that made the full-SoC KV260 build unroutable at
~41 MHz. Without the flag, ``xlate_miss`` and ``mem_xlate`` read the live
combinational I-TLB/D-TLB lookups (the 16-entry vpn-compare carry chain) on
every access; ``fe_xlate_pend`` is tied 0 so every added guard constant-folds
away and the default build is byte/cycle-identical.

The flag adds one registered translation per side —
``fe_itlb_{page,phys,hit,v}`` and ``fe_dtlb_{page,phys,hit,dirty,v}``, keyed
on ``cur_lin[31:12]`` — sampled by a dedicated ``always_ff`` that also
invalidates on ``tlb_flush`` (CR3 write) and, per side, on any page-walk fill
so a fresh walk is always re-registered. When the current access's page is not
the registered page, ``fe_xlate_pend`` asserts for exactly one clock: the FSM
holds in a dedicated stall arm (no state/eip/issue/bus change that edge) and
the bus driver squashes the request so no stale physical address ever leaves
(``rtl/core/core_bus_driver.svh``); the next clock, ``xlate_miss`` and
``mem_xlate`` read the *registered* hit/frame instead of the live carry chain.

Architecturally bit-exact (``make verify`` GREEN with it on); cycle-wise it
adds one clock per 4 KiB page crossing (under ~1 % perturbation, zero in real
mode or within a page) — an Fmax-only demonstrator, cycle bands not claimed
(option B of ``docs/fe-pipeline-spec.md``). Payoff: the full SoC goes from
"not legally routed, 8 766 node overlaps" at 60 MHz to a clean route
(~50.4 MHz Fmax); the deployed 40 MHz Linux image includes it. The only
setter is ``fpga/scripts/impl_kv260_soc.tcl`` via the ``FE_PIPE=1``
environment knob.

It only matters when paging is on, and coherence couples it to ``tlb_flush``
and the page-walk fill ports — the invalidate-wins-over-register ordering at
one edge is what keeps a freshly walked or flushed page from being cached
stale. The risk profile is the gotcha: a bug here is *silent* (wrong physical
page = data corruption, not a crash), so the spec requires
architectural-bit-exact verification on the paging-heavy gates before trusting
changes to it. Small mispredict/fill cycle shifts on an FE_PIPE build are
expected, not regressions.

``VEN_IC_BRAM``
---------------

Forces the L1 I-cache line store into Block RAM (RAMB36), dissolving the
distributed-RAM read mux. The store becomes two replicated
``ram_style = "block"`` arrays (one per read port, each a single-read SDP
BRAM), reads become *synchronous* (data valid the clock after the address),
and the per-word fill becomes the canonical UltraScale byte-write-enable
template writing both copies (``rtl/mem/icache.sv``). Without it, the line
store is a single distributed-RAM array with asynchronous reads.

Because data now arrives one clock late, the spine grows a content-addressed
front end (``rtl/core/core.sv``): the read addresses are registered as tags in
lock-step with the data; ``ic_byte`` content-addresses whichever buffer holds
the needed set; ``ic_fetch_ready`` reports whether the decode window's line(s)
are currently buffered (sequential fetch is bubble-free because port B always
prefetches the next line, so a sequential line crossing finds the new line
already buffered); and a new ``S_PIPE`` bubble arm burns one no-issue clock
only on a redirect to an un-buffered line (``rtl/core/core_fastpath.svh``).
A sub-step removes even that: when a predicted-taken branch sits in a
non-straddling window, port B is repurposed to prefetch the predicted *target*
line (``pf_redir``/``pf_redir_tgt``) — literally the real P5's BTB-driven
prefetch.

Fully verified: functional 75/75 bit-exact, all 20 cycle bands pass
(``mb_accimm`` +20 % before the target prefetch, +0.39 % after; ``mb_imiss``
+3.97 %, inside the 10 % band), and a Quake 300 k-instruction lockstep run is
EQUIVALENT (``verif/m7/quake_icbram.log``). Area trade: 3 072 LUT-as-memory →
0, +5 RAMB36 in the full core. It did *not* break the OOC congestion wall by
itself — the byte-window MUXF mass lives in the spine, not the cache (the 99 %
``u_icache`` congestion attribution was a flatten-hierarchy artifact) — but it
became the required base for ``VEN_UOPCACHE`` and is in the deployable SoC
config. Set by the deployable SoC, ``apr_run.tcl`` (uopcache config),
``apr_hc_pnr.tcl``, the icbram/uopcache probes, a standalone OOC icache probe,
and ad-hoc sim builds (no checked-in verif script pins it).

Gotchas: it is band-validated, *not* cycle-identical — redirects to
un-buffered lines and the +1 buffer-fill clock after ``S_PF`` shift cycle
counts, so a strict cycle diff against the default build will differ even
though all bands pass. It supersedes ``VEN_IC_NARROWB`` (which lives in its
``else`` branch). And the replicated A/B stores mean every fill writes both
copies — forgetting that when reasoning about SMC/fill coherence is a trap.

``VEN_IC_NARROWB``
------------------

Static width-pruning of the icache's second (straddle) read port in the
*distributed-RAM* (non-BRAM) front end. ``rd_lineB`` is only ever byte-sliced
at low positions — the worst case is ``flin[4:0] = 31`` plus a 6-byte U length
plus index 5, minus 32, i.e. byte 10 — so the flag drives only the low
128 bits and ties the high 128 to zero, letting Vivado prune half of the
256-wide distributed-RAM read port (``rtl/mem/icache.sv``). Since the pruned
bytes are never read, the fetched bytes are bit-identical: verified ``make
verify`` plus ``make m3`` cycle-identical, ``mb_imiss`` +0.03 % noise. It is
the only flag in this family (besides the pure parameters at default values)
that is both bit-exact *and* cycle-identical, so it needs no gate of its own.

Measured: LUT-as-memory 4 096 → 3 072, MUXF7 16 235 → 14 457 / MUXF8
7 147 → 6 202 (−12 %), OOC synthesis WNS −1.808 → −0.587 ns (59.5 → 64.1 MHz)
— the icache left the synthesis critical path — but *placed* Fmax was
unchanged (47.6 MHz) because the irreducible ``rd_lineA`` 256:1 read and the
spine byte-window MUXF remain. It was the "narrowb production" OOC config
until P0-14 showed it does not actually route at 15 ns (42 392 overlaps),
after which the uopcache config took over as the routable base —
``fpga/scripts/impl_kv260_soc.tcl`` documents that narrowb "hits the
single-cycle byte-window MUXF congestion wall and does NOT route on the small
xck26".

Set by ``synth_paths_narrowb.tcl``, ``apr_run.tcl`` (CONFIG=narrowb), several
floorplan/strategy scripts, and the older ``bd_kv260_soc.tcl`` validate flow
(the deployable impl script switched to the uopcache config). It is mutually
dead with ``VEN_IC_BRAM`` — the narrowb code sits in the BRAM ``ifdef``'s
``else`` branch, so defining both silently behaves as BRAM-only (several
scripts list it harmlessly). The safety argument depends on the 6-byte U plus
6-byte V window geometry; if the decode window ever widens, the static bound
must be re-derived.

``VEN_CACHE_HALF``
------------------

An FPGA area/congestion experiment that halves *both* L1s to 64 sets (4 KB
I-cache + 4 KB D-cache), changing the index/tag geometry from idx 7/tag 20 to
idx 6/tag 21. It is the third-priority arm of the ``IC_SETS`` and ``DC_SETS``
precedence chains in ``rtl/core/core.sv``. Because the index/tag split
changes, the hit/miss *sequence* differs from the fixed-128-set ``p5trace``
cycle oracle, so it is explicitly **not** a verification or cycle-fidelity
configuration — the M4/M5 bands are only claimed for the default. It stays
functionally bit-exact (a cache is a hit/miss plus a data store; smaller means
more fills, same bytes): both the default and ``+VEN_CACHE_HALF`` builds pass
``make verify`` 77/77 vs QEMU, run manually via
``VL_EXTRA_DEFINES=+define+VEN_CACHE_HALF make verify``.

FPGA payoff (on the uopcache base, K26, 15 ns): ``u_icache`` placed cells
−45 %, MUXF7/F8 −29 %/−24 %, placer congestion level 6 → 5, failing endpoints
−23 %, TNS −38 % — but routed Fmax roughly flat (51.7 → 50.1 MHz), because the
worst path was the FP deferred-commit cone, not the cache. It was kept as a
free area/tail win and, combined with ``VEN_FP_PIPE2``, became the
63–65.3 MHz OOC configuration and part of the deployable SoC image. Set by
``impl_kv260_soc.tcl``, ``apr_run.tcl`` (``HALF=1`` env), and
``apr_hc_pnr.tcl``; in simulation only by manual ``VL_EXTRA_DEFINES``.

It is overridden by ``VEN_IC_SETS``/``VEN_DC_SETS`` and by ``VEN_L1_SETS``
(the ``elsif`` chain ranks them above it); the geometry flows into the icache,
uopcache and ``dcache_timing`` parameters. Under ``VEN_L1_AXI`` the D-cache
half has no effect at all (``dcache_timing`` is compiled out). Never run the
cycle bands on a half-cache build and call a mismatch a regression — the
in-source comment brands it "NOT a verification config".

``VEN_IC_SETS``
---------------

Per-I-cache set-count override (an integer-valued define), the
highest-priority arm of the ``IC_SETS`` chain
(``VEN_IC_SETS`` > ``VEN_L1_SETS`` > ``VEN_CACHE_HALF`` (64) > 128). The value
must be a power of two, since ``IC_IDXW = $clog2(IC_SETS)`` and
``IC_TAGW = 32-5-IC_IDXW`` derive directly from it; it resizes the parametric
``rtl/mem/icache.sv`` arrays and flows into the uopcache parameter as well.
Non-default values stay functionally correct (the cache is
architecture-transparent) but are *not* matched by the fixed-128-set/2-way
``p5trace`` cycle oracle — they are area/perf experiments.

Its real consumer is the L1 cache-size sweep: ``build/rerun/cache_sweep.sh``
(dhrystone, lockstep replay) and ``build/rerun/dmiss_sweep.sh`` (``mb_dmiss``,
pure ``--cycle``) — local working artifacts in the gitignored ``build/``
tree, not committed — build one testbench per geometry via
``VL_EXTRA_DEFINES="+define+VEN_IC_SETS=$SETS +define+VEN_DC_SETS=$SETS"``
into separate ``obj_dir_sweep_*`` directories and measure CPI vs size — the
sweep that produced the 32 KB-knee result (``mb_dmiss`` CPI 2.50 → 0.53).
Cache timing is cycle-mode-only and cycle mode diverges on syscall/TLS
programs, so sweeps either use flat syscall-free kernels or the PC-keyed
lockstep replay path — that constraint is baked into the scripts. Each
geometry must build into its own object directory or it clobbers the canonical
``obj_dir/tb_ventium`` used by ``make verify``.

``VEN_IC_WAYS``
---------------

Per-I-cache associativity override (chain ``VEN_IC_WAYS`` > ``VEN_L1_WAYS``
> 2; powers of two, with a guard so even 1-way elaborates). The icache was
generalized from the original 1-bit MRU 2-way scheme to a per-way age-counter
**true LRU** (rank 0 = MRU … WAYS−1 = LRU) that provably reduces to the
original behaviour at ``WAYS == 2`` — same hit test, same victim sequence,
same touch/fill recency; the reset encoding (age = way index, reproducing the
old victim = way 1) was deliberately matched, and any "cleanup" there breaks
golden identity. The replacement victim is exported per set as ``ic_victim_o``
so the spine's fill-way selection stays uniform.

No script — committed or local — sets it directly; the associativity
demonstration used the umbrella ``VEN_L1_WAYS=4`` via the local
``build/rerun/nway_4way.sh`` (gitignored), which proved a
12 KB conflict working set thrashes 2-way but fits 4-way (CPI drop) and that
4-way free-runs CoreMark with CRC output identical to qemu-native. It
conflicts with ``VEN_UOPCACHE`` at any value greater than 2 (1-bit way ports,
stores sized ``IC_SETS*2``; 1-way is safe but wastes half the slot store). The fixed-2-way oracle means there is no cycle
gate for other way counts — only functional/CRC validation.

``VEN_DC_SETS``
---------------

Set-count override for the L1 D-cache **timing model**
(``rtl/mem/dcache_timing.sv``) — crucially a timing-only structure: there is
no data array; load data always comes from the BFM/``mem_rdata``, and
``dcache_timing`` just tracks tag/valid/LRU so the spine knows *when* a load
completes (a read miss adds the ``dmiss = 8`` penalty, misalignment +3,
mirroring ``p5_mem()``/``l1_access()`` in the ``p5trace.c`` oracle). It can
therefore never change architectural results — only cycle counts, and only in
cycle mode. Like the I-side knob it is functionally safe but breaks the
fixed-128-set cycle-oracle match; it is used by the same two cache sweeps,
always set equal to ``VEN_IC_SETS``.

It is entirely moot under ``VEN_L1_AXI``: the whole ``dcache_timing`` instance
is compiled out and ``dc_lu_hit`` tied 1 (mode-2 timing is functional-only),
so SoC/board builds ignore it. The D-miss penalty is also deferred one
instruction (``pending_mem_pen``), so per-geometry cycle deltas land on the
*following* retire — relevant when eyeballing sweep traces. Because it is
timing-only, a functional-mode run returns identical data values regardless of
the setting; the sweep scripts exploit exactly this, which is what makes
fixed-``--max-insn`` CPI comparisons valid.

``VEN_DC_WAYS``
---------------

Associativity override for the D-cache timing model, the D-side twin of
``VEN_IC_WAYS`` (chain ``VEN_DC_WAYS`` > ``VEN_L1_WAYS`` > 2).
``dcache_timing`` was generalized to any power-of-two way count with a per-way
age-counter true LRU that reduces *exactly* to the original 1-bit ``dc_lru``
behaviour at 2-way — same hit test, victim sequence and recency update, the
reset encoding reproducing the old ``victim = ~dc_lru``. That exact-reduction
property is the load-bearing reason the default build needed no
re-verification after the parameterization commit. Since the block is
timing-only, changing ways only changes when loads complete in cycle mode,
never what they return.

No script — committed or local — sets it directly; the 4-way demonstration
used the umbrella ``VEN_L1_WAYS=4`` via the local ``build/rerun/nway_4way.sh``
(gitignored), which together with the I-side showed the
conflict-kernel CPI collapse at 4-way and CRC-identical CoreMark output as the
functional proof. Moot under ``VEN_L1_AXI``; usually swept together with the
I-side so the two L1s stay symmetric, mirroring the oracle's single L1
geometry parameterization. Its "differential gate" is a functional/CRC
equivalence run plus a CPI plausibility check — never the cycle bands.

Integer core and build plumbing
===============================

This family covers the integer-core implementation flag ``VEN_IDIV_ITER``
plus the housekeeping tokens (``SYNTHESIS``, ``VTM_NO_DPI``,
``VTM_HAVE_DPI_HEADER``, ``M7_PROXY_DEBUG``, ``F2_DBG``) that separate
simulation builds from FPGA synthesis builds. ``VEN_IDIV_ITER`` swaps the
default single-cycle combinational x86 DIV/IDIV — native SystemVerilog ``/``
and ``%`` inside ``rtl/core/core_exec.svh``'s ``S_EXEC`` arm, which
synthesized to the core's worst path once the FPU went iterative (post-P0-1:
87.8 ns, 667 levels, 585 of them CARRY8) — for a
multi-cycle restoring-divide engine plus a new ``S_DIV_BUSY`` wait state:
architecturally bit-exact, but only cycle-band-equivalent. The non-VEN tokens
follow the convention that the default (no-flag) Verilator build is the
golden-comparable one: ``VTM_NO_DPI`` strips the DPI-C retire-observation
channel so the RTL lints and synthesizes with no C testbench, ``SYNTHESIS``
strips sim-only ``$fatal`` guards and bound SVA, and the rest are debug or
C++-side plumbing. None of the non-VEN tokens change architectural behaviour;
``VEN_IDIV_ITER`` has its own differential gate (``make verify-idiv``) plus
full-suite, cycle-band and ``verify-sys`` #DE re-verification.

``VEN_IDIV_ITER``
-----------------

Without the flag, x86 DIV (``q_md = 6``) and IDIV (``q_md = 7``) execute with
native combinational ``/`` and ``%`` directly in the ``S_EXEC`` arm (64-bit
``{EDX,EAX}`` dividend for the 32-bit form), committing GPRs in one clock and
charging the modelled P5 occupancy as a deferred ``pending_mem_pen`` penalty
burned in ``S_PIPE`` before the next issue (occ−7: DIV 10/18/34, IDIV
15/23/39 for r/m8/16/32). ``rtl/core/ven_idiv.sv`` is always in the filelist
but uninstantiated (``rtl/ventium.f`` notes this is harmless).

With the flag, both ``K_MULDIV`` divide arms reroute: ``S_EXEC`` stops
computing anything and parks in ``S_DIV_BUSY``; a combinational driver block
pulses ``eng_int_start`` that same clock, assembling the dividend from ``gpr``
and the divisor from ``srcv`` (recomputed identically to the exec arm), and
instantiates ``ven_idiv``. The engine is a 4-state FSM doing restoring
division on magnitudes at two radix-2 steps per clock, with the x86 sign
fix-up (quotient sign = dividend ^ divisor, remainder takes the dividend sign,
truncation toward zero) and the *exact* per-width #DE predicates from
``core_exec.svh`` (zero divisor short-circuits; per-width quotient-overflow
checks) — bit-exact to the native path. ``S_DIV_BUSY`` busy-waits on done,
then either delivers #DE vector 0 (system-mode ``start_fault`` through the
IDT, user-mode loud-HALT — identical policy to the inline path) or commits
quotient/remainder into EAX/EDX with the same per-width merge, tops up
``pending_mem_pen`` with a residual (IDIV +6, DIV +1, tuned against ``make
m5`` so issue-to-next-issue equals the P5 occupancies 17/25/41 DIV,
22/30/46 IDIV), sets ``retire_valid`` and returns to ``S_PIPE``.

This removed the post-P0-1 worst path of the whole core (87.8 ns / 667
levels). With the flag, ``make verify`` stays 74/74 green and the
``verify-sys`` "pde" #DE program is EQUIVALENT, while the divide cycle kernels
move ``mb_div8`` +5.45 %, ``div16`` +0.13 %, ``div32`` +2.36 %, ``idiv32``
+2.12 % — all inside the 10 % band. The standalone gate is ``make
verify-idiv`` (``verif/idiv/run-idiv-gate.sh``, ``verif/idiv/tb_idiv.sv``: a
golden mirroring ``core_exec.svh``, directed edge cases plus 80 k random
vectors over all six forms). Set by every full-core FPGA configuration from P0-2 onward
(``bd_kv260_soc.tcl``, ``impl_kv260_soc.tcl``, the APR scripts and the
``synth_paths_*``/``probe_muxf_*``/``probe_lut_quick`` probes); the pre-P0-2
baseline probes ``synth_probe_core.tcl`` and ``synth_probe_core_iter.tcl``
deliberately omit it (they are the before/after measurement configs). The
only verif builder that sets it is the FP_PIPE2 A/B base define set.

Gotchas: cycle-mode A/B diffs against a no-flag build show line deltas on
divide-heavy traces — expected, not a bug. The fixed residual works across
widths only because the engine's run-state clock count scales exactly with the
P5 occupancy deltas; changing steps-per-clock breaks the model. The engine
driver recomputes ``srcv`` combinationally and must stay identical to the exec
arm's expression or operands diverge silently. ``tb_idiv`` deliberately
substitutes a well-defined overflow vector for the INT_MIN/−1 corner (the
testbench's native-``/`` golden would hit C++ UB in Verilator); on real x86
that corner is #DE-overflow, which the engine's predicate covers. And the
busy-wait serializes — no instruction issues until the EDX:EAX commit,
matching the native path's non-pipelined U-pipe hold.

``SYNTHESIS``
-------------

The standard simulation-versus-synthesis fence, used exclusively as
``ifndef SYNTHESIS`` around code Vivado cannot or should not synthesize. Six
sites, all in the L1/AXI/SoC-bridge files and none in the core proper:
``rtl/mem/ven_cdc_afifo.sv`` (initial ``$fatal`` guards requiring DEPTH be a
power of two and ≥ 4, plus SVA forbidding write-while-full/read-while-empty);
``rtl/mem/ven_axi_master.sv`` (``$fatal`` guards converting two
silent-corruption bugs into build failures — ``REMAP_BASE`` must be 32-byte
aligned for the INCR8 4 KiB rule, ``LINE_BEATS`` must be 8 to match the
``ven_l1d`` 32 B line — plus bound AXI protocol SVA: VALID-with-stable-payload
until handshake, 32 B-aligned read-burst base, no 4 KiB crossing, no AR while
a write is outstanding); ``rtl/mem/ven_axi_cdc.sv`` (single-outstanding CDC
invariants); and ``rtl/soc/ven_soc_axil.sv`` (``io_ack`` one-cycle-pulse and
pending-required checks, the F3 INTA seam checks, AXI-Lite BVALID/RVALID
hold). Defining it removes all of this, leaving pure synthesizable logic;
nothing architectural changes, so no gate is needed — but verification must
*not* set it, or the L1/AXI gates lose their checkers (those gates build with
``verilator --assert``).

Set by the Vivado SoC/BD flows (``bd_l1axi.tcl``, ``bd_kv260_soc.tcl``,
``impl_kv260_soc.tcl``, ``synth_cdc.tcl``), always paired with
``VTM_NO_DPI``. The guarded files are only in SoC/L1-AXI builds — none are in
the core filelist ``rtl/ventium.f`` — which is why older core-only probe
scripts set only ``VTM_NO_DPI`` and still synthesize cleanly. Vivado also
pre-defines ``SYNTHESIS`` on its own, but the project sets it explicitly
rather than relying on the tool default. In the default testbench build the
concurrent assertions are compiled but inert, because ``--assert`` is only
added by the dedicated SVA/gate targets — keeping the default build
byte-identical and unburdened by assertion machinery.

``VTM_NO_DPI``
--------------

Elides the entire DPI retire-observation contract so the RTL lints,
elaborates and synthesizes with no C testbench present. Without it, four
``import "DPI-C"`` declarations in ``rtl/ventium_pkg.sv`` — ``vtm_retire``
(integer architectural state), ``vtm_retire_x87`` (80-bit st0–st7 split
lo/hi plus fctrl/fstat/ftag), ``vtm_retire_cycle`` (U/V pipe attribution and
pairing) and ``vtm_retire_sys`` (cr0/cr2/cr3/cr4) — are called once per
retired instruction from the retire points in ``rtl/ventium_top.sv`` and
``rtl/soc/ventium_soc.sv`` (including the dual-issue ``retire2`` second
calls); this *is* the observation channel every differential gate depends on
(one ``.vtrace`` record per ``vtm_retire`` call). A small stub fence also
exists in the M0 selftest top (``verif/tb/selftest/ventium_top.sv``).

With the define, ``retire_n`` bookkeeping still ticks but nothing observes it
— the synthesized core carries zero trace overhead. It is mandatory for
synthesis (``fpga/TIMING_PROBLEMS.md`` P2-2, ``fpga/PLAN.md``). Purely an
observability token: it cannot change architectural behaviour (the calls are
pure observers), but a build with it set produces no trace and therefore
cannot be differentially gated — every golden comparison requires it *unset*.
Set by every ``fpga/scripts/*.tcl`` synthesis/impl/probe script and by the
standalone lint flow documented in ``rtl/README.md``; never by
``verif/tb/Makefile`` or any gate script.

Gotchas: the import signatures are declared verbatim from
``docs/rtl-interface.md`` §2 because the comparator parses by field name — do
not "clean up" the import inside the fence. ``ventium_top.sv`` calls
``vtm_retire_x87`` on *every* retirement, not just FP ops, because QEMU
reports live FP state on every instruction in x87-trace mode; eliding it
per-op would silently break x87 diffs. Re-enabling DPI on a previously
NO_DPI-configured build needs no other change.

``VTM_HAVE_DPI_HEADER``
-----------------------

The C++-side companion of ``VTM_NO_DPI`` in the same DPI contract — **a C++
preprocessor macro, not a Verilog define**, and never passed on any command
line. ``verif/tb/dpi_retire.cpp`` implements the bodies of the four
``vtm_retire*`` functions; it uses ``__has_include`` to detect the
Verilator-generated ``Vventium_top__Dpi.h``. When the header is present it is
included (so the definitions are type-checked against the generated extern-C
prototypes) and ``VTM_HAVE_DPI_HEADER`` is self-defined; when absent (a
standalone compile without ``-Iobj_dir``), the ``#ifndef`` branch supplies
hand-written fallback ``extern "C"`` prototypes matching the documented SV→C
type mapping (``longint unsigned`` → ``unsigned long long``, and so on). Pure
build plumbing with zero behavioural effect; it is listed here because it is
the only other ``VTM_*`` token in the tree. If the fallback prototypes ever
drift from the generated header, builds with the header present fail
type-check — the intended safety net. Grep hits land in ``.cpp`` only.

``M7_PROXY_DEBUG``
------------------

A leave-undefined simulation debug token from the M7 Win95-cosim /
syscall-proxy bring-up. Three ``ifdef``'d ``$display`` sites, tagged
``[M7DBG]``: the int-0x80 proxy fold (pc, retire count, injected EAX, gs
apply/base) in ``rtl/core/core_fetch_decode.svh``; MOV-to-Sreg selector and
hidden-base resolution (the gs-selector-0x33 seam) in
``rtl/core/core_exec.svh``; and indirect-CALL target resolution (``q_pc``,
segment base, EA, loaded target), also in ``core_exec.svh``. Purely
observational — no logic, no state, no architectural effect, no gate needed.
Nothing in the repository sets it (manual ``+define+M7_PROXY_DEBUG`` only),
and ``fpga/TIMING_PROBLEMS.md`` explicitly instructs leaving it undefined for
synthesis. The proxy-fold site lives inside the same decode path that
underlies ``VEN_PS_PROXY``'s ``S_SYSCALL_WAIT``, so it is the natural tap when
debugging PS-proxy syscall injection. Output interleaves with testbench
stdout; enabling it on long runs floods logs — intended for short directed
reproductions.

``F2_DBG``
----------

A leave-undefined debug token for the iterative F2XM1 transcendental engine
(issue #11 bring-up). One site, in ``rtl/fpu/fpu_f2xm1.sv``'s ``S_PACK``
state: a ``$display`` of the polynomial-accumulator internals (iteration,
accumulator exponent/sign/significand halves and the ``y`` exponent) just
before ``norm_round_pack_x`` produces the result. Pure observation, no
behavioural or timing effect, no gate needed; nothing sets it. It is only
meaningful when the engine is actually instantiated, i.e. under
``VEN_TRANSCENDENTAL``.

Testbench value macros and sweep hygiene
----------------------------------------

For completeness, the unit-testbench *value* macros are not core feature
flags: ``BCD_N``, ``SRT_N``, ``SQRT_N``, ``IDIV_N``, ``FBLD_N``, ``FPPIPE_N``,
``F2_NV``/``F2_RC``, ``FA_NV``/``FA_RC``, ``FY_NV``/``FY_RC``/``FY_MODE`` and
``FS_NV``/``FS_OP`` live only in the standalone gate testbenches under
``verif/bcd``, ``verif/srt``, ``verif/idiv``, ``verif/fbld``, ``verif/fppipe``
and ``verif/trsc``, and are vector-count / rounding-mode / operation-select
parameters set by their own gate scripts. A full ``ifdef``/``ifndef`` sweep
over ``rtl/`` finds no other unknown tokens beyond the flags on this page, and
the remaining ``#ifndef`` tokens in ``verif/tb`` C++ are ordinary include
guards. The ad-hoc sweep object directories under ``verif/tb`` split two ways:
``obj_dir_sweep_32`` … ``2048`` and ``obj_dir_4way`` are produced by the
local, uncommitted sweep scripts in the gitignored ``build/rerun/`` tree,
while ``obj_dir_fe`` alone is a manual ``VL_EXTRA_DEFINES`` build with no
script at all.

Memory system and SoC platform
==============================

This family is the build-time ladder that turns the verification core (BFM
memory, same-cycle ack, DPI retire tracing) into a real KV260 FPGA SoC, plus
the umbrella L1 geometry knobs and one physical-implementation switch. The
ladder is strictly layered: ``VEN_L1_AXI`` swaps the bus-functional memory
port for a real stalling L1 data array plus an AXI4 master to PS-DDR
(bus mode 2, runtime ``l1axi_en``); ``VEN_AXI_CDC`` optionally splits that
subsystem into two clock domains via async-FIFO bridges; ``VEN_KV260_SOC``
(nested inside ``VEN_L1_AXI``'s port block, so it *requires* it) adds the
PS-facing seams used by the ``ventium_kv260_core`` full-SoC top; and
``VEN_PS_PROXY`` converts the zero-latency int-0x80 lockstep proxy into a
stalling handshake for the future F4 PS syscall bridge. All of these honour
the project convention that the default build stays byte/cycle-identical,
though the protections vary: the double gate (``ifdef`` absent by default
*and* a runtime enable tied 0) holds for ``VEN_L1_AXI``
(``l1axi_en``/``real_bus``), ``VEN_PS_PROXY`` (``proxy_en``) and
``VEN_KV260_SOC``'s interrupt seam (``soc_en``), while ``VEN_AXI_CDC`` is a
compile-time-only path swap shielded by ``l1axi_en`` at the subsystem level;
per-flag differential gates prove architectural bit-exactness for
``VEN_L1_AXI``, ``VEN_AXI_CDC`` and ``VEN_PS_PROXY`` but *not* for
``VEN_KV260_SOC`` (board-level certification only); only cycle *timing* is
allowed to change (mode-2 timing is explicitly functional-only). ``VEN_L1_SETS``/``VEN_L1_WAYS`` are
valued geometry knobs for the in-core caches, and ``VEN_PBLOCK`` is not a
Verilog define at all but an environment variable read by two Vivado Tcl
scripts.

``VEN_L1_AXI``
--------------

The P1-1 "bus mode 2" build: routes the core's same-cycle-ack 32-bit memory
port through ``rtl/mem/ventium_l1_axi.sv`` — ``ven_l1d`` (an 8 KB / 2-way /
32 B-line write-through L1 data array) plus ``ven_axi_master`` (a burst
engine) — out to a full AXI4 master bundle that either the testbench's
behavioural DDR slave or the PS ``S_AXI_HPC0_FPD`` services. Without the flag
there are no AXI ports, no ``ventium_l1_axi`` instance, no
``real_bus``/``bus_err`` core ports, and the ``dcache_timing`` instance is
kept — the core's memory port wires directly (or via the bus-mode-1 BIU) to
the testbench BFM, byte/cycle-identical to all M0–M14 gates.

The flag adds the ``l1axi_en``/``flush_all``/``m_axi_*``/``bus_err`` port
group to ``rtl/ventium_top.sv`` and the ``u_l1axi`` instance with a 3-way
memory mux that holds the direct ``mem_*`` port inert when ``l1axi_en = 1``.
Inside the core it adds ``real_bus`` and ``bus_err`` inputs and arms the
fast-path miss-stall gates: the dual-issue fast path otherwise latches
``mem_rdata`` the same clock it requests (the BFM assumption), which a real L1
cannot honour on a miss — so I-side fill word-0 capture and the ``S_PF``
launch wait for ``mem_ack``, a D-side register-base load bubbles the whole
issue until the fill completes, and the modelled P5 D-miss penalty is
suppressed (real DDR latency becomes the only timing source — "mode-2 timing
is functional-only"). A fatal AXI fault (watchdog timeout or SLVERR) parks the
core in ``S_HALT`` with ``cpu_hung`` so the PS can observe and reset. As an
area side-effect the build drops the ~4.4 k-cell ``dcache_timing`` instance
(``dc_lu_hit`` tied 1 — functionally inert because the penalty it fed is
suppressed).

Architecturally bit-exact: the entire 77-program suite is re-verified against
the QEMU golden through this path (``verif/l1/run-l1axi-verify.sh``); the
byte-accurate/cross-line L1 fix took mode-2 equivalence from 34/77
(aligned-only) to 76/77, and the final program was recovered by the high
quiesce window (the default 64 falsely declared an idle core), giving
``L1AXI-VERIFY-OK`` 77/77.
All gates are doubly protected (``ifdef`` plus runtime
``l1axi_en``/``real_bus = 0``), so even the flagged build in modes 0/1 is
byte-identical. Set by the ``verif/tb/Makefile`` targets ``l1axi`` and
``l1axi_cdc`` (which append ``rtl/mem/ven_l1d.sv``,
``rtl/mem/ven_axi_master.sv`` and ``rtl/mem/ventium_l1_axi.sv`` — deliberately
absent from ``rtl/ventium.f``, so the macro alone is an elaboration error), by
``run-l1axi-verify.sh``, and by the production KV260 define lists
(``bd_kv260_soc.tcl``, ``impl_kv260_soc.tcl``, together with
``VEN_KV260_SOC``). The ``-DVEN_L1_AXI`` C flag also reaches the C++
testbench, gating the behavioural DDR slave leg in ``tb_main.cpp``.

Gotchas: the cycle oracle is not claimed in mode 2 — only the functional trace
is graded. Verification needs a high quiesce (``--quiesce 200000`` vs the
default 64) because a multi-cycle mode-2 access (an icache fill, a 27-beat
FNSAVE) goes many clocks without retiring. ``ven_l1d`` holds ``m_req``
*continuously* across back-to-back transactions, so any downstream consumer
that waits for ``!m_req`` deadlocks (documented in ``ven_axi_cdc.sv``). The
``flush_all`` input exists for cosim coherency: the syscall proxy writes the
backing memory model directly, bypassing the L1. The standalone unit gates
(``run-l1axi-gate.sh``, ``run-l1d-gate.sh``, ``run-l1axi-wd-gate.sh``) do
*not* need the define — the leaf modules are unconditional; the ``ifdef`` only
controls wiring into ``ventium_top``/``core``.

``VEN_L1_SETS``
---------------

Sets the set count for *both* in-core L1s at once: ``IC_SETS`` for the
functional I-cache and ``DC_SETS`` for the D-cache timing model. It sits in a
precedence chain — the per-cache ``VEN_IC_SETS``/``VEN_DC_SETS`` override it,
it overrides ``VEN_CACHE_HALF`` (the legacy 64-set shortcut), which overrides
the 128 default (the Pentium silicon geometry the cycle oracle is validated
against; at the default, the index/tag slices are exactly
``addr[11:5]``/``addr[31:12]``). Set-index width, tag width and all tag/valid/
data arrays derive automatically; the value must be a power of two.

Changing it changes the miss *sequence*: the build stays functionally
bit-exact — supported by the ``VEN_CACHE_HALF`` ``make verify`` run (the
64-set case, 77/77), the 4-way CoreMark CRC free-run and the functional
set-count sweeps, not by a ``make verify`` run with this define itself — but
the cycle trace no longer matches the fixed-128-set ``p5trace`` oracle, so the
M4/M5 bands are only claimed for the default. It is the documented
convenience form (see :doc:`/microarch/l1-parametric`) with no recorded user:
the cache design-space sweeps that found the 32 KB L1 knee passed the
per-cache ``VEN_IC_SETS``/``VEN_DC_SETS`` instead, and the umbrella pair's
only recorded use is the ways side (``VEN_L1_WAYS=4``). There is no
production setter — the FPGA builds use ``VEN_CACHE_HALF`` instead. An important scope limit: it does
**not** touch ``ven_l1d``, the ``VEN_L1_AXI`` data cache — that module has its
own ``L1_SETS`` module parameter left at its 128 default by
``ventium_l1_axi``, so a geometry sweep changes the in-core I-cache and
D-timing model only. Always build into a private object directory so the
canonical ``obj_dir/tb_ventium`` is never clobbered.

``VEN_L1_WAYS``
---------------

Sets the associativity for both in-core L1s at once, with the same precedence
pattern (``VEN_IC_WAYS``/``VEN_DC_WAYS`` win; default 2, the P5 silicon
associativity, at which the generalized age-rank true LRU reduces
byte-for-byte to the original 1-bit MRU scheme — victim = ``~lru`` —
confirmed by the cycle gates). Supporting arbitrary N required the per-way
age-counter LRU described under ``VEN_IC_WAYS``, exposed as ``ic_victim_o`` so
the spine's fill-way selection stays uniform. Functionally bit-exact but
cycle-oracle-divergent for non-default values — an area/CPI exploration knob,
e.g. the 4-way conflict-pattern experiment in ``build/rerun/nway_4way.sh``
(local, gitignored; a 12 KB conflict set on ``+VEN_L1_WAYS=4``). No production setter; the same
``ven_l1d`` scope limit as ``VEN_L1_SETS`` applies. The value must be a power
of two.

``VEN_AXI_CDC``
---------------

The P1-3 dual-clock option for the L1/AXI subsystem. Without it,
``ventium_l1_axi`` is the single-clock ``CDC_BYPASS`` build: ``ven_l1d``'s
word-granular backing port wires straight to ``ven_axi_master`` with plain
assigns, the raw ``core_rst_n`` is used everywhere, and ``core_clk`` and
``axi_clk`` are expected tied to the same clock — which is what the production
KV260 bitstream ships (a single ``pl_clk0``).

With the flag, the core plus ``ven_l1d`` stay in ``core_clk`` (the slow,
Fmax-limited PL domain) while ``ven_axi_master`` and the AXI4 link run in
``axi_clk``. ``ventium_l1_axi`` instantiates ``rtl/mem/ven_axi_cdc.sv``, which
bridges the single-outstanding backing port with exactly one primitive:
``rtl/mem/ven_cdc_afifo.sv``, a clean-room Cummings 2-FF Gray-pointer
asynchronous FIFO (binary plus Gray pointers, 2-flop synchronizers, FWFT read
off distributed RAM). Two FIFOs are used — a command FIFO core→axi carrying
``{we, addr, wdata, wstrb}`` and a response FIFO axi→core (depth ≥
``LINE_BEATS = 8`` for a full line fill) — with small per-domain FSMs that
preserve ``ven_l1d``'s ack semantics exactly (eight in-order acks per read
fill, one per write), so ``ven_l1d`` and ``ven_axi_master`` are textually
untouched; ``ven_axi_master`` is simply re-clocked via a compile-time static
net alias, never a runtime clock mux. Two ``ven_reset_sync``
async-assert/sync-deassert reset bridges are fed by the AND of *both* raw
resets, so a reset in either domain resets both — an asymmetric
mid-transaction reset would otherwise wipe the producer side of an in-flight
fill and create an undetectable deadlock (the watchdog lives in the just-reset
axi domain). The sticky ``bus_err`` level crosses axi→core through a 2-flop
``ASYNC_REG`` synchronizer.

Purely an implementation/Fmax option, and proven bit-exact: the multi-ratio
data-integrity gate (``verif/l1/run-l1axi-cdc-gate.sh``) runs
read-fill/write-through/evict at four core:axi clock ratios with assertions
live, and ``run-l1axi-cdc-verify.sh`` re-runs the full 77-program suite
through the bridge at the degenerate equal-clock ratio. Set by the Makefile
``l1axi_cdc`` target (together with ``VEN_L1_AXI``), the CDC gates, and
``fpga/scripts/synth_cdc.tcl`` (an OOC synthesis check with two genuinely
asynchronous clocks, 66/200 MHz).

Gotchas: the reset coupling is load-bearing — never split the resets. The
CDC's core-side FSM completes *on* the last response and must not wait for the
request to drop, because ``ven_l1d`` holds ``m_req`` continuously across
back-to-back transactions (FNSAVE's 27 sequential stores) — waiting deadlocks.
The FIFO depth must be a power of two ≥ 4 (a sim-time ``$fatal`` enforces
it). The FIFO is metastability-safe by Gray-code structure, not by simulation
— Verilator only proves the functional protocol across ratios. The CDC source
files are not in ``rtl/ventium.f``, so defining the macro without adding them
is an elaboration error; and the real dual-clock MMCM block design with its
``ven_cdc.xdc`` constraints is the pending follow-up.

``VEN_KV260_SOC``
-----------------

The full-SoC seam set for the KV260 PS-assisted architecture (the PL holds
only the core, L1 and AXI master; the PS A53 emulates every slow peripheral).
Inside ``rtl/ventium_top.sv`` it does three things. First, it adds the
``retire_count[63:0]`` output, wired to the live retire counter, so the PS can
observe forward progress without the sim-only DPI (the F2 milestone). Second,
it adds the F3 PS-driven external-interrupt injection seam — ``soc_en``,
``intr`` (an 8259-INT-analogue level), ``inta_vector[7:0]`` (the PS-staged
vector) inputs and the one-clock ``inta`` acknowledge strobe output — and
wires the core's previously tied-off interrupt divert for real (NMI stays
tied 0). Third, it overrides the L1/AXI address remap: ``L1AXI_REMAP_BASE``
becomes ``40'h0_4000_0000`` instead of identity 0, so the core's x86 physical
space lands in the reserved 256 MB DDR carveout on ``S_AXI_HPC0``. Without the
define, even a ``+VEN_L1_AXI`` build has none of these ports and the
interrupt path is tied off, so every cosim/L1AXI gate stays byte-identical.

It is the build flag for the ``rtl/soc/ventium_kv260_core.sv`` top
(``ventium_top`` plus ``rtl/soc/ven_soc_axil.sv``, the AXI4-Lite
control/status/port-I/O-bridge/interrupt slave on ``M_AXI_HPM0_FPD``), whose
header states "build with ``+VEN_L1_AXI +VEN_KV260_SOC``". At runtime it is
additive-and-inert by default: ``soc_en`` comes from the slave's
``MODE.SOCEN`` bit (default 0), so F2 boot behaviour is unchanged until the PS
opts into F3 interrupt injection, and the remap is pure address translation,
invisible to the core. There is no Verilator differential gate for this define
itself — it is certified by the BD validate/synth bars plus the on-board F2
firmware diff (the 324-record COM1 boot trace), while its constituent seams
(the AXI-Lite slave handshake, the L1/AXI wire protocol) have their own
Verilator gates.

Set by ``fpga/scripts/bd_kv260_soc.tcl`` and
``fpga/scripts/impl_kv260_soc.tcl`` (every archived production run echoes
it). It has a **hard dependency on ``VEN_L1_AXI``**: its entire port block is
nested inside that ``ifdef`` and the core connection block references the new
ports — defining ``VEN_KV260_SOC`` alone does not compile. The carveout
base/size (``0x4000_0000``/``0x1000_0000``) must agree between the RTL
localparam, the BD address segment, and the PS Linux reserved-memory node.
Note the deliberate asymmetry: cosim keeps ``REMAP_BASE = 0`` because the
testbench memory model is x86-phys-indexed — do not "fix" one side to match
the other. Among ``ventium_top``-based builds, only ``+VEN_KV260_SOC`` exposes the
``soc_en`` port the core branches its CPUID identity on (0x663 vs 0x543; the
port is tied 0 otherwise) — but the M8 ``ventium_soc`` simulation top drives
``soc_en = 1`` unconditionally with no define, and that is where the
``soc_en`` CPUID arm is actually differential-verified (the ``psoccpuid`` SoC
gate); the define itself only adds ports and the remap.

``VEN_PS_PROXY``
----------------

The F4 PS-bridge stall variant of the Quake user-mode int-0x80 proxy. Without
it, an int-0x80 in proxy mode commits with *zero latency*: the ``S_DECODE``
arm applies the testbench-driven golden EAX/gs/resume effects combinationally
on the same clock (the M7.1 lockstep contract). On real hardware the PS A53
answers a syscall thousands of core clocks later, so the same-clock assumption
breaks.

The define adds the ``syscall_resp_valid`` input through ``ventium_top`` into
the core, a new FSM state ``S_SYSCALL_WAIT``, and a 4-bit ``q_proxy_len``
register. When ``proxy_en = 1`` and ``S_DECODE`` hits ``cd 80``, instead of
committing immediately the core latches only the instruction length and parks
in ``S_SYSCALL_WAIT`` (``eip`` still at the ``cd 80``), committing nothing;
``syscall_active`` still pulses for that one ``S_DECODE`` clock, and because
no retire ticks the counter, ``syscall_n`` and the ``syscall_arg_*`` register
reads stay stable for the PS for the whole wait. On ``syscall_resp_valid`` the
wait arm performs the *identical* commit the zero-latency arm would have
(EAX, optional gs-base latch, ``eip += q_proxy_len``, the fold-pending state)
and resumes fetch — architecturally equivalent, just later. It mirrors the
``S_IO`` port-I/O stall discipline.

The stall reorders *when* effects commit, so equivalence is non-obvious and
the flag has its own differential gate:
``verif/m7/run-quake-lockstep-proxy.sh`` builds ``make proxy``
(``obj_dir_proxy``; the ``-DVEN_PS_PROXY`` C flag also makes ``tb_main.cpp``
play the PS with an 8-clock service latency) and requires the stalled RTL
trace to be bit-exact against the *same* QEMU golden the zero-latency build
matches (``QUAKE-LOCKSTEP-PROXY-OK``). It is runtime-double-gated
(``proxy_en`` must be 1 *and* an int-0x80 must decode in user mode), so even
the flagged build is byte-identical on non-proxy runs.

It is in no FPGA production list — the F4 hardware syscall bridge is future
work; ``ven_soc_axil`` only *reserves* the syscall register window
0x40–0x6C for it, and ``ventium_kv260_core`` ties the response inputs off.
The eventual hardware path composes with ``VEN_KV260_SOC`` (the reserved
window will drive ``syscall_resp_valid``) and with ``VEN_L1_AXI``'s
``flush_all`` (the PS writes kernel-memory effects to the DDR carveout,
requiring L1 invalidation before resume). Gotchas for a PS-side
implementation: ``syscall_active`` pulses on the ``S_DECODE`` clock, *not* the
commit clock, so the response must not be assumed sampled the same cycle; and
``eip`` parks at the ``cd 80``, so ``q_proxy_len`` is the only state needed to
advance on the late commit — do not re-derive the length in the wait arm.

``VEN_PBLOCK``
--------------

**Not a Verilog define.** It is an environment variable read by two Vivado Tcl
floorplanning-experiment scripts (``fpga/scripts/impl_route_relax.tcl`` and
``fpga/scripts/impl_route_fppipe.tcl``) via
``[info exists ::env(VEN_PBLOCK)] && $::env(VEN_PBLOCK) eq "1"``; it never
appears in any ``verilog_define`` list and never reaches the RTL, so it cannot
change the netlist's function — a pure physical-implementation option. When
``VEN_PBLOCK=1``, after out-of-context synthesis of the bare core the script
creates a soft Pblock ``pb_core`` containing every non-internal cell, resizes
it to ``SLICE_X0Y0:SLICE_X111Y239`` (a compact lower-left-biased region) and
sets ``IS_SOFT TRUE`` — the intent being to stop the placer from spreading the
82 %-utilization core across the whole die so hot nets (the ``eip`` fetch
self-update loop, ``f_mem80 → fpr``) stay short. The output build directory
gets a ``_pblock`` suffix so baseline and Pblock runs coexist.

The recorded outcome is a **closed negative result**
(``fpga/TIMING_PROBLEMS.md``): placed Fmax improved only 42.5 → 44.2 MHz, and
the full route did not converge at 82.85 % utilization under either route
directive — the conclusion that floorplanning alone cannot fix a
device-filling core; the real lever is lower utilization, which redirected the
Fmax work toward logic consolidation and the later half-cache/uop-cache
configurations. No Makefile or CI sets it — a manual experiment knob, and the
comparison is to the exact string ``"1"`` (``VEN_PBLOCK=true`` silently
disables it). It operates on builds using the Fmax define stack and is
orthogonal to every Verilog flag; the separate ``run_pblock_rebalance.tcl``
and ``impl_floorplan.tcl`` experiments do not read it. The production KV260
flow does not use it.

Peripheral RTL/PS split
=======================

The ``VEN_<DEV>_PS`` family is Ventium's per-peripheral RTL(PL)-versus-PS(A53)
placement selector for the SoC top ``rtl/soc/ventium_soc.sv`` (see
:doc:`/soc/peripheral-split` for the architecture). A device whose macro is
defined is *not* synthesized into the SoC: its I/O port range is added to
``io_ps_sel``, and every IN/OUT in that range is forwarded over the byte-wide
``io_ps_*`` bridge seam to a C model, with ``io_ack`` waiting on
``io_ps_ack`` and ``io_rdata`` taking the returned byte. Because the core
stalls in ``S_IO`` until ack, the C model's latency cannot perturb the
per-record instruction stream — only the returned value matters.

The flags are generated, not hand-set: ``fpga/scripts/gen_periph_split.py``
reads ``fpga/periph_split.config`` (``rtl`` or ``ps`` per device) and emits
``fpga/build/periph_split.vdefs`` (one ``+define+VEN_<DEV>_PS`` line per
ps-placed device — currently RTC, I8042, VGA, ACPIPM, UART and FDC) plus the C
dispatch table ``verif/tb/ps_periph_table.inc``. In verification the single
setter is ``verif/soc/run-soc-ps-cosim-gate.sh``, which passes one
``+define+VEN_<DEV>_PS`` into the ``verif/tb/Makefile`` ``soc`` target,
building a per-device ``obj_dir_soc_<dev>ps`` testbench whose ``ps_devs``
table (``verif/tb/tb_soc.cpp``) services the forwarded ports from
``sw/ps_periph/<model>.c``. The default build (no flags) is the all-RTL SoC
with ``io_ps_req`` tied 0 — byte-identical to the pre-split SoC.

Each enabled flag changes implementation *placement* only and is required to
stay per-record bit-exact: every settable flag has its own differential gate
(``run-soc-ps-cosim-gate.sh <dev>`` → "C model == RTL == qemu" EQUIVALENT;
aggregated by ``run-soc-ps-cosim-all.sh`` inside ``run-all-soc-gates.sh``).
Off the differential surface, each flag does delete real SoC functionality —
device IRQ lines into the PIC tie to 0, the i8042 A20 output, the VGA mode
bits feeding the chain-4 framebuffer, the UART tx console seam — which the
docs class as board-integration follow-ups needing a PS-to-PL return path.

Three of the nine flags (``VEN_PIC_PS``, ``VEN_PIT_PS``, ``VEN_PORT92_PS``)
are **forward-only latent hooks**: their decode term exists in the
``io_ps_sel`` chain, but the RTL instance is *not* ``ifndef``-gated (always
instantiated), they are declared bus-critical "keep in PL" in
``fpga/periph_split.config``, the cosim gate script rejects them, and (for
pit/port92) no C model exists — setting them today would produce a broken
dual-commit hybrid. Note also that nothing in ``fpga/scripts/*.tcl`` consumes
``periph_split.vdefs`` yet: the current KV260 board builds compile
``ventium_kv260_top``/``ventium_kv260_core`` — *all* peripherals on the PS via
``ven_soc_axil`` — and not ``ventium_soc.sv`` at all, so these flags are
presently exercised only in the Verilator SoC verification builds, standing
ready for a future full-SoC PL build.

``VEN_UART_PS``
---------------

Places the COM1 16550 UART (ports 0x3F8–0x3FF) on the PS. The ``ifndef`` in
``rtl/soc/ventium_soc.sv`` removes the ``ven_uart16550`` instance (real area
savings in a future full-SoC PL build); the ``else`` arm ties
``uart_rdata = 0``, ``uart_irq4 = 0`` (master-PIC IR4 permanently deasserted)
and kills the board-console tx seam (``uart_tx_valid = 0`` — the seam the RTL
streams THR bytes out on). ``cs_uart`` is OR-ed into ``io_ps_sel``, so every
access in the range stalls the core until the C model's byte returns.

The replacement is ``sw/ps_periph/ven_uart16550.c``, a 1:1 behavioural port of
the RTL register surface (IER/LCR/MCR/LSR/MSR/SCR/FCR/DLL/DLM/RBR, DLAB
banking) where the RTL's clocked read side-effects (the LSR/MSR read-clears)
become inline read side-effects, applied exactly once per access via the
bridge's single-call guarantee. The gate
(``run-soc-ps-cosim-gate.sh uart``, test ``psocuart``) is EQUIVALENT over 110
retired instructions. The tx-seam loss is moot on the board: when the UART is
PS-placed, the PS C model itself holds the THR bytes — it *is* the console.
IRQ4 delivery is tied off in the PL; the differential runs with interrupts
disabled so this is unobserved, but a board build needs the PS to inject IRQ4
through ``ven_soc_axil``. One documentation skew: ``sw/ps_periph/README.md``
references a ``run-soc-uart-ps-gate.sh`` wrapper that does not exist — the
real entry point is ``run-soc-ps-cosim-gate.sh uart``. The port range is
adjacent to the FDC's and to IDE alt-status 0x3F6; the decode boundaries are
exact, with no overlap.

``VEN_VGA_PS``
--------------

Places the VGA legacy register file (window 0x3B0–0x3DF) on the PS. The
``ifndef`` removes the ``ven_vgaregs`` instance (ATTR/MISC/SEQ/DAC/GFX/CRTC/
IS1 registers with qemu-matched masks); the ``else`` arm ties
``vga_rdata = 0`` and — critically — zeroes the four exported mode bytes
(``vga_seq_plane_mask``, ``vga_seq_mem_mode``, ``vga_gfx_mode``,
``vga_gfx_misc``). Those bytes feed the still-instantiated RTL chain-4
framebuffer ``ven_vga_fb``: ``chain4_en`` derives from them, so with the
registers on the PS it is stuck 0 and the 0xA0000 mode-13h memory intercept
never fires — the framebuffer is dormant.

The range forwards to ``sw/ps_periph/ven_vgaregs.c``, which ports the register
surface 1:1 including the deterministic read side-effects (DAC 3-byte palette
auto-increment, ATTR index/data flip-flop reset on an IS1 read, the IS1
dumb-retrace toggle), executed inline exactly once per access. The ``pvga``
differential (292 records, shared with the acpipm gate) proves the C model
byte-identical to qemu — ``pvga`` never touches 0xA0000, so the dormant
framebuffer is invisible to it.

This is the biggest cross-domain coupling of the family: register split and
framebuffer rendering are currently mutually exclusive — a mode-13h workload
(the F4 Quake/DOS path, the ``pvgafb`` gate) must *not* be run on a
``+VEN_VGA_PS`` build until a PS→PL mode-bit return path exists (the explicit
follow-up note in both the RTL and the peripheral-split page).

``VEN_RTC_PS``
--------------

Places the MC146818 RTC/CMOS (ports 0x70 index / 0x71 data) on the PS. The
``ifndef`` removes the ``ven_rtc`` instance; the ``else`` arm ties
``rtc_rdata = 0``, ``rtc_irq8 = 0`` (slave-PIC IR8 permanently low) and
``rtc_nmi_dis = 0`` (the NMI-disable side-band, today a lint sink). The two
ports forward to ``sw/ps_periph/ven_rtc.c``, a 1:1 port of ``ven_rtc.sv``
matched to QEMU 8.2.2's ``mc146818rtc.c``: the 128-byte CMOS array behind the
index latch with the separate non-aliasing NMI-disable bit, index-port reads
returning 0xFF, REG_A UIP read-only, REG_C read-then-clear plus IRQ8 lower (an
inline read side-effect, applied once per access), REG_C/REG_D write-ignore,
and the REG_B IRQF recompute on write.

The ``psocdev`` differential (122 records) reads only the time-invariant
registers (REG_D, REG_B, the index-read 0xFF, a scratch-CMOS round-trip), so
the un-oracled periodic tick can never perturb the compare; with the flag set
the same test passes EQUIVALENT against the C model. This is the cleanest flag
of the family — no PL-consumed output other than the (diff-quiescent) IRQ8 and
NMI-disable lines. The RTC time-byte / UIP / periodic-tick surface is a
documented oracle boundary in *both* placements (host-clock-derived); the
cosim gate only proves the synchronous register surface, and board-build IRQ8
delivery needs PS injection via ``ven_soc_axil``.

``VEN_PIT_PS``
--------------

A forward-only **latent hook — do not set**. The macro exists in the
``gen_periph_split.py`` table (ports 0x40–0x43) and in the ``io_ps_sel`` chain
of ``ventium_soc.sv``, but unlike the six slow devices the ``ven_pit``
instantiation is *not* wrapped in ``ifndef VEN_PIT_PS`` and has no tie-off
arm. Defining it therefore does not remove the RTL PIT: it only reroutes
0x40–0x43 accesses to the bridge while the RTL PIT still receives the same
``cs_pit`` pulses and still drives ``pit_out0`` into PIC IR0. Because a
PS-bridged access holds ``io_req`` (and thus ``cs_pit``) high for multiple
clocks until ``io_ps_ack`` — versus the one-clock chip select the RTL devices
were designed for — RTL-side write commits and read side-effects
(counter-latch and read-LSB/MSB flip-flop state) would double-step, and a PS
shadow copy would diverge from the live RTL PIT that actually generates IRQ0.

There is no ``sw/ps_periph/ven_pit.c`` (the generator would report
"MISSING — needs a C model"), ``run-soc-ps-cosim-gate.sh`` has no ``pit``
branch, and ``fpga/periph_split.config`` pins ``pit rtl`` as bus-critical
("8254 PIT — IRQ0 timebase"); a ``+VEN_PIT_PS`` testbench build would read
open-bus 0xFF for the range. The PIT's RTL coverage is the all-RTL ``pirqsoc``
gate. It is distinct from ``VEN_PIT_TICK_DIV``, the unrelated sim-only IRQ0
cadence knob, and the PS-side PIT for the actual KV260 board path is planned
to feed ``sw/ps_periph/ven_pic.c`` via the ``ven_soc_axil`` interrupt seam — a
different architecture that bypasses ``ventium_soc`` entirely.

``VEN_PIC_PS``
--------------

The second latent hook — **do not set**. Its only RTL appearance is the
``io_ps_sel`` term covering the master/slave/ELCR ports (0x20/0x21, 0xA0/0xA1,
0x4D0/0x4D1); the ``ven_pic`` instantiation is unconditional, hard-wired to
the core's INTR/INTA pins and to all 16 device IRQ inputs. Defining it would
forward PIC register I/O to the PS while the RTL PIC keeps full
interrupt-delivery authority but stops seeing consistent register state (reads
answered by the PS, writes seen by *both* sides, with the multi-clock
chip-select double-commit hazard on its OCW/ICW write sequencing and poll-read
side effects) — the interrupt machine state of the RTL PIC and any PS shadow
would immediately diverge.

Uniquely among the three latent hooks, a C model *does* exist —
``sw/ps_periph/ven_pic.c``, a 1:1 port matched to QEMU 8.2.2's ``i8259.c`` —
but its stated purpose is the F3 KV260 board firmware path, where all
peripherals including the PIC run on the A53 and the PS drives interrupts into
the core through ``ven_soc_axil``'s interrupt-injection seam: an architecture
that does not use ``ventium_soc`` or this macro at all. The PIC is the one
device where "register surface on PS" is architecturally insufficient —
INTR/INTA timing is the reason ``fpga/periph_split.config`` pins it in the PL.
``tb_soc.cpp`` does not even register a PIC entry in ``ps_devs``, so a
``+VEN_PIC_PS`` build would read open-bus 0xFF from 0x20/0x21.

``VEN_I8042_PS``
----------------

Places the 8042 PS/2 keyboard controller (ports 0x60 data / 0x64 cmd-status)
on the PS. The ``ifndef`` removes the ``ven_i8042`` instance; the ``else`` arm
ties ``kbd_rdata``, ``kbd_irq1``, ``mouse_irq12``, ``kbd_reset_req``,
``kbc_a20`` and ``kbd_inj_ready`` to 0. Two real functional consequences
follow. First, **A20**: the effective A20 mask is
``eff_a20 = kbc_a20 | p92_a20``, gating address bit 20 on the memory path;
with the i8042 on the PS its contribution is gone, so A20 tracks port-92 alone
— acceptable for the ``psocdev`` differential because that test drives both
A20 sources together and port-92 stays in RTL, but a board build needs the PS
to drive the i8042 A20 state back into the fabric. Second, the testbench's
``--type-at`` keyboard-injection seam (used for the F3/F4 FreeDOS typing path)
becomes unavailable (``inj_ready = 0``), so the interactive FreeDOS flows must
not be run on a ``+VEN_I8042_PS`` build.

The range forwards to ``sw/ps_periph/ven_i8042.c`` — a port of the
queue-independent controller surface (A20 enable/disable 0xDF/0xDD, output
port, mode byte, status) with the 0x60 OBF-dequeue read side-effect inline;
the asynchronous PS/2 device queues are an oracle boundary exactly as in the
RTL. The ``psocdev`` cosim (122 records, shared with the rtc gate) passes
EQUIVALENT. One cosmetic note: ``tb_soc.cpp`` registers the dispatch range as
0x060–0x064 inclusive, but only 0x60/0x64 are ever forwarded because
``cs_i8042`` decodes exactly those two ports — the wider C-side range is
harmless.

``VEN_FDC_PS``
--------------

Places the 82077/8272A floppy controller (ports 0x3F1–0x3F5 plus 0x3F7 —
deliberately *not* 0x3F0 and not 0x3F6, which is IDE alt-status) on the PS.
The ``ifndef`` removes the ``ven_i8272`` instance; the ``else`` arm ties
``fdc_rdata = 0`` and ``fdc_irq6 = 0`` (PIC IR6 dead — quiescent on the
differential anyway, which runs with interrupts disabled). The range forwards
to ``sw/ps_periph/ven_i8272.c``, a 1:1 port of the synchronous register
surface matched to QEMU 8.2.2's ``fdc.c``, with the result-FIFO advance as an
inline read side-effect. The oracle boundary matches the RTL's: actual
READ/WRITE/FORMAT/READ-ID/RECALIBRATE/SEEK execution, DIR media-change and
motor spin-up are excluded (they need disk/DMA or asynchronous timing). The
``psocfdc`` differential (116 records) passes EQUIVALENT.

The port-range carve-out is the subtle part: the generator encodes the same
two disjoint ranges, and ``tb_soc.cpp`` registers 0x3F1–0x3F7 inclusive with a
comment that 0x3F6 can never arrive because ``cs_fdc`` excludes it — so an IDE
alt-status access is never mis-forwarded even with both the UART (0x3F8 up)
and the FDC on the PS; the three decoders partition 0x3F1–0x3FF exactly
(0x3F0 itself is claimed by none of them and falls to the default open-bus
decode). One
stale comment: ``ven_i8272.c``'s header says "built with ``+VEN_I8272_PS``" —
that macro name is wrong; the actual macro is ``VEN_FDC_PS``.

``VEN_ACPIPM_PS``
-----------------

Places the ACPI PM timer (single port 0x608, PIIX4 PM base+8) on the PS. The
``ifndef`` removes the ``ven_acpipm`` instance (a free-running 24-bit counter
advanced by a fractional accumulator at the PM-timer rate); the ``else`` arm
ties ``acpipm_rdata`` and ``acpipm_rdata32`` to 0. The port forwards to
``sw/ps_periph/ven_acpipm.c``, which models the same surface: a read returns
the address-selected byte of ``{8'h00, count[23:0]}``; a write is ignored
(qemu's ``acpi_pm_tmr_write`` is a no-op). The cosim gate (the ``pvga`` test,
292 records, shared with the VGA flag) passes EQUIVALENT. The cheapest device
of the family; its PS placement is mostly about keeping the configuration
uniform.

A width nuance unique to this flag: in the RTL placement the ``io_rdata`` mux
returns the full 32-bit ``acpipm_rdata32`` so a dword IN gets the whole
counter, whereas the PS bridge is byte-wide and a PS-placed read returns one
zero-extended byte. That narrowing is invisible to every existing gate because
the timer's read *value* is a documented oracle boundary in both placements
(host-clock/clk-derived; the differential only exercises the write-inert OUT)
— but if a future test ever oracles a 32-bit IN from 0x608 it will differ
between placements. Never compare instantaneous counter values across
placements; the cadence is structural (clk-derived in RTL, no clock at all in
the C model).

``VEN_PORT92_PS``
-----------------

The third latent hook — **do not set**. Its only RTL appearance is the
``io_ps_sel`` term for port 0x92; the ``ven_port92`` instantiation is
unconditional with no tie-off. With the flag, an IN/OUT 0x92 would be answered
by the bridge while the RTL port92 still latches the same writes (the
multi-clock chip-select double-commit hazard) and still drives ``p92_a20``
into ``eff_a20`` and ``p92_reset_req``. Since there is no
``sw/ps_periph/ven_port92.c`` (the generator names the model but the file does
not exist) and ``tb_soc.cpp`` registers no port-92 entry, reads would come
back open-bus 0xFF — while the live A20 state silently tracked only the RTL
writes.

The placement rationale is physical: A20 masking sits combinationally on the
core's memory-address path (``eff_a20`` gates address bit 20), which cannot
tolerate an A53 round-trip — hence ``port92 rtl # fast A20 — gates the address
bus`` in ``fpga/periph_split.config`` and no cosim branch. The flag exists so
the ``io_ps_sel`` chain is complete and uniform for all nine non-bus-master
device rows (the generator's ide/dma/dma2 rows define
``VEN_IDE_PS``/``VEN_DMA_PS``/``VEN_DMA2_PS`` but have no ``io_ps_sel`` term
in the RTL at all), and as the seam a future PS→PL A20 return path would
build on. Note that
``VEN_I8042_PS`` implicitly depends on port-92 staying in RTL for A20 coverage
on the ``psocdev`` diff; PS-placing port-92 would orphan A20 entirely. The
device's RTL coverage is the all-RTL ``psocdev`` A20-mask differential plus
the standalone unit self-check (the ``port92`` target of
``verif/soc/Makefile`` — ``make -C verif/soc port92``, driving
``tb_ven_port92.cpp``).

Peripheral tunables and debug instrumentation
=============================================

This family is the SoC peripheral-tunable and debug-instrumentation knob set.
Every flag is ``ifndef``-defaulted in the RTL itself or ``ifdef``-guarded
around observation-only code (pure ``$display`` blocks,
``VEN_IDE_DISK_HEX``'s ``$readmemh`` load, ``VEN_DBG_WD``'s two observation
registers), so a build with no flags is byte/cycle-
identical to the golden-gated default. The tunables (``VEN_IDE_DISK_HEX``,
``VEN_IDE_DISK_SECTORS``/``CYLS``/``HEADS``/``SECS``, ``VEN_RTC_EXTMEM_KB``,
``VEN_PIT_TICK_DIV``) exist because Verilator's ``-G`` cannot reach a
submodule parameter: ``ventium_soc.sv`` threads the ``ifndef``-defaulted IDE
geometry and PIT macros into the ``ven_ide``/``ven_pit`` instance parameters,
while ``VEN_RTC_EXTMEM_KB`` is ``ifndef``-defaulted and consumed directly
inside ``rtl/soc/ven_rtc.sv`` (module-internal localparams; the ``ven_rtc``
instance takes only ``TICK_DIV``). They are
sim-only by design — set only on the ``tb_soc`` Verilator build line, never in
any ``fpga/scripts/*.tcl`` define list — though that is moot for the deployed
bitstream, whose file list omits ``ventium_soc`` and these peripherals
entirely; the one flow that does synthesize ``ven_ide`` (the full-SoC probe)
hard-errors on the ``disk[]`` array regardless (``fpga/TIMING_PROBLEMS.md``
P1-2), and P1-3 records that the sim tick divisors must be retuned for a real
fabric clock.

Only ``VEN_IDE_DISK_HEX`` has committed setters (the ``verif/tb/Makefile``
``soc`` target plus five boot/IDE gate scripts); the geometry, PIT and
extended-memory overrides were passed ad hoc via the Makefile's
``VL_EXTRA_DEFINES`` passthrough during the F3 FreeDOS / F4 Quake boot
bring-up — no committed script pins the non-default values. Architecturally,
the disk geometry and ``VEN_RTC_EXTMEM_KB`` change CPU-observable values
(IDENTIFY words, the out-of-range-abort boundary, the CMOS memory-size bytes),
so the differential gates rely on the defaults; ``VEN_PIT_TICK_DIV`` changes
only the explicitly non-differential IRQ0 cadence; and ``VEN_IDE_TRACE``,
``VEN_DBG_WD`` and ``VEN_DBG_SSBASE`` are pure ``$display`` probes with zero
state-machine effect.

``VEN_IDE_DISK_HEX``
--------------------

The disk-image backing-store path for ``ven_ide``'s behavioural hard disk — a
quoted-string macro consumed by exactly one statement in
``rtl/soc/ven_ide.sv``: ``initial if (HAS_DISK) $readmemh(`VEN_IDE_DISK_HEX,
disk);``, loading the raw byte array ``disk[0:DISK_SECTORS*512-1]`` at sim
start. The path is embedded at *build* time but the file is read at *run*
time, so the ``pide`` gate regenerates the hex before each run and the binary
picks up the fresh image. Undefined, the ``ifdef`` simply removes the
``$readmemh`` and ``disk[]`` stays uninitialized (never read by non-IDE
tests); a lint sink keeps the define-less build UNUSEDPARAM-clean, and
``HAS_DISK = 0`` (the empty ATAPI CD secondary channel) suppresses the load
even when the define is present.

The ``verif/tb/Makefile`` ``soc`` target always passes it, with double
quoting — ``-DVEN_IDE_DISK_HEX='"$(VEN_IDE_DISK_HEX)"'`` — so the macro
expands to a SystemVerilog string literal; the make variable defaults to the
absolute path of ``verif/sys/tests/pide/pide.disk.hex``, and each boot/IDE
gate overrides it with its own disk (``run-soc-ide-gate.sh``,
``run-soc-boot-gate.sh``, ``run-soc-bootrm-gate.sh``,
``run-soc-bootdma-gate.sh``, ``run-soc-seabios-boot-gate.sh``). The FPGA flow
must leave it undefined (``fpga/TIMING_PROBLEMS.md`` P2-2). The disk contents
are part of the differential surface: the same single-source image is fed to
``qemu -drive`` and to ``$readmemh``, and READ SECTORS data is graded
byte-identical per record — a "flag change" here is really test content, and
each gate regenerates its golden against the same image. The value needs the
shell-level quote nesting (``'"path"'``); a bare path breaks the preprocess.

``VEN_IDE_DISK_SECTORS``
------------------------

Sets the ``ven_ide`` ``DISK_SECTORS`` instance parameter (default 128 — the
64 KiB ``pide`` single-source image). It sizes the backing array, derives the
disk byte-address width used by both the PIO drain pointer and the DMA dword
offset, and pins ``NSECT28 = DISK_SECTORS``, the LBA28 out-of-range bound used
by the upfront READ abort, the per-sector mid-transfer abort and the
block-mode first-block check. It also feeds the CPU-visible IDENTIFY words
60/61 (LBA28 total) and 100 (LBA48 total). The F3 widening (commit
``564d4d9``) made it actually scalable: pre-F3 the byte address was a hard
``[15:0]``, so sectors above 64 KiB aliased; with the macro, the FreeDOS
multi-MB disk passes ``+define+VEN_IDE_DISK_SECTORS=20160`` (with
``+CYLS=20``) and addressing widens automatically.

No committed script sets a non-default value; overrides are ad hoc on the
``tb_soc`` build line. It is **architecturally visible** — IDENTIFY words and
the out-of-range boundary change — so any non-default value invalidates the
``pide`` per-record golden; non-default runs are boot bring-up only. It must
agree with the image supplied via ``VEN_IDE_DISK_HEX`` and with the qemu
golden geometry, and is normally changed together with the CHS triple. And it
is deliberately sim-only: the 64 KiB default ``disk[]`` (524 288 bits) is
already a hard synthesis error on the full-SoC probe (it cannot infer BRAM
due to the multi-port writes and ``$readmemh`` init, and is too large to
dissolve into FFs — ``fpga/TIMING_PROBLEMS.md`` P1-2), so raising
``DISK_SECTORS`` in a synthesis context makes that strictly worse; the
recorded path to a real disk on hardware is the DDR-backed ``ven_ide`` rework
in ``fpga/PLAN.md`` §5.5, which scales ``DISK_SECTORS``/geometry/OOR as part
of moving the backing store off-chip.

``VEN_IDE_CYLS``
----------------

Threads the ``ven_ide`` ``CYLS`` parameter (logical cylinder count, default
2). It appears in the CPU-observable IDENTIFY block — word 1 (logical
cylinders), word 54 (current cylinders) and, via
``OLDSIZE = CYLS*HEADS*SECS``, words 57/58 (current capacity) — and bounds how
much of the disk guests compute as CHS-reachable. The default 2/16/63 triple
is exactly what qemu's ``guess_chs_for_size`` produced for the 128-sector
``pide`` image, so the IDENTIFY constants grade byte-identical against a
freshly generated qemu golden each run. The F3 FreeDOS disk used ``+CYLS=20``
(20 × 16 × 63 = 20160, CHS-consistent with the sector count). No committed
setter; sim-only. Unlike HEADS/SECS it does *not* enter the CHS→LBA
arithmetic, so an inconsistent CYLS only lies to the guest's capacity math
rather than corrupting translation — but any non-default value still breaks
the ``pide`` per-record golden.

``VEN_IDE_HEADS``
-----------------

Threads the ``ven_ide`` ``HEADS`` parameter (default 16). Two CPU-observable
roles: IDENTIFY words 3/55 plus the OLDSIZE capacity product, and the **live
CHS→LBA translation** used whenever a guest issues a command with devhead
bit 6 clear — ``chs_lba = (cyl*HEADS + head)*SECS + sector − 1``, the exact
qemu ``ide_get_sector`` formula. A wrong HEADS therefore does not just
mis-report geometry; it makes CHS reads land on the wrong sectors. The
``pide`` gate exercises CHS addressing explicitly (the M8.4c surface), so the
default is gate-proven; the FreeDOS-era multi-MB overrides kept 16. No
committed setter; sim-only. A mismatch between the define used for the golden
``qemu -drive`` geometry and the RTL build corrupts CHS data compares — a much
louder failure than an IDENTIFY word diff.

``VEN_IDE_SECS``
----------------

Threads the ``ven_ide`` ``SECS`` (sectors-per-track) parameter (default 63).
CPU-observable in IDENTIFY words 4 (unformatted bytes/track = 512 × SECS),
6, 56 and the OLDSIZE product, and in the CHS→LBA translation as the track
multiplier and the 1-based sector offset. The default is the qemu
``guess_chs_for_size`` value for the 128-sector image, against which the
M8.4c CHS-addressing differential is graded; the FreeDOS bring-up kept 63. No
committed setter; sim-only. Same consistency set and same CHS-corruption
failure mode as ``VEN_IDE_HEADS`` if the RTL define and the golden geometry
diverge.

``VEN_IDE_TRACE``
-----------------

Sim-only ``$display`` instrumentation inside ``rtl/soc/ven_ide.sv``, used
during the F3 FreeDOS boot gap-walk to watch IDE traffic. Five trace points:
(1) READ SECTORS (0x20/0x21) command acceptance — opcode, LBA-vs-CHS mode bit,
resolved LBA, effective sector count and the raw task-file registers; (2)
every device-control (0x3F6) write — new/previous control byte plus live
status and transfer state, i.e. SRST and nIEN flips in context; (3) a
"ZERO-READ" diagnostic when the CPU reads the data port with DRQ clear — the
case where ``rdata = 0`` silently; (4) the first 12 data words of each
non-IDENTIFY sector drain; (5) the multi-sector block re-arm at each DRQ
window boundary. No registers, ports or FSM arms are added; on/off builds are
bit-exact, so no gate is needed. No committed setter — ad hoc
``+define+VEN_IDE_TRACE`` via ``VL_EXTRA_DEFINES`` only; must not be defined
for synthesis.

One structural note: trace point (3)'s ``ifdef`` wraps an entire ``else if``
arm of the clocked access-priority chain — safe today because the arm is
display-only, so with the define off the chain simply falls through with
identical state — but any future edit adding an *assignment* inside it would
create a define-dependent behavioural fork. The comment marks the
read-with-DRQ-clear case as "the zero-source" precisely because that silent
path once hid a bug.

``VEN_RTC_EXTMEM_KB``
---------------------

The F4 (DOS Quake prep) knob: kilobytes of RAM above 1 MiB to advertise via
CMOS (default 0 — legacy behaviour, the CMOS memory-size registers keep their
all-0x00 reset value and SeaBIOS computes RamSize = 1 MiB; every existing
gate byte-identical). Background, from the ``rtl/soc/ven_rtc.sv`` header:
this SoC has no fw_cfg (ports 0x510/0x511 read open-bus 0xFF), so SeaBIOS
sizes RAM purely from CMOS. When the macro is nonzero, ``ven_rtc``'s reset arm
seeds the qemu ``pc_cmos_init`` register set: 0x15/0x16 = 640 (base memory),
0x17/0x18 and 0x30/0x31 = min(EXTMEM_KB, 65535) (KB above 1 MiB),
0x34/0x35 = ((1 MiB + EXTMEM_KB) − 16 MiB)/64 KiB capped at 65535 (64 KB
units above 16 MiB); the >4G registers stay 0. The seed localparams implement
the exact ``hw/i386/pc.c`` formulas, and the seeding sits inside
``if (EXTMEM_KB != 0)``, which constant-folds away at the default, preserving
the legacy all-zero image bit-for-bit.

Proven effect (commit ``4f6c68b``): with 64512 the SeaBIOS e820 gains a
63 MiB RAM entry on the RTL — the prerequisite for DPMI/Quake. The PS-offload
C model ``sw/ps_periph/ven_rtc.c`` mirrors it 1:1 (same ``#ifndef`` default,
same byte math, plus a runtime ``ven_rtc_set_extmem_kb()`` override hook for
future PS firmware, with no current caller). No committed setter — ad hoc
``VL_EXTRA_DEFINES`` only.

Gotchas: this is **architectural** — CMOS bytes 0x15–0x18/0x30/0x31/0x34/0x35
are CPU-readable, so any nonzero value diverges from the qemu golden unless
qemu is launched with the matching ``-m``; the ``psocdev`` RTC differential
only stays EQUIVALENT because the default is 0. The advertised memory is a lie
unless the SoC actually backs it — the value must not exceed real RAM behind
the bus or DOS/DPMI will scribble into nothing. Values above 65535 KB saturate
the 0x30/0x31 pair by design (qemu does the same); the above-16 MiB portion is
carried only by 0x34/0x35. In a ``+VEN_RTC_PS`` cosim, the C-model copy of the
flag is the one that matters — the two must be set consistently or the RTL/PS
split changes the guest-visible memory size.

``VEN_PIT_TICK_DIV``
--------------------

Scales the i8254 PIT tick prescaler for simulation (default 1024 — one PIT
tick per 1024 core clocks). ``ventium_soc`` instantiates
``ven_pit #(.TICK_DIV(PIT_TICK_DIV), .TICK_INC(1))``; inside ``ven_pit`` a
generate block picks the implementation: ``TICK_DIV <= 1`` means a tick every
clock (the natural hardware wiring where ``clk`` *is* the 1.193182 MHz PIT
clock — what the unit testbench uses), while larger values instantiate a
24-bit fractional accumulator. The PIT's register semantics (counts, latching,
read-back, the OUT formula) are qemu-bit-exact regardless; only the wall-clock
cadence of ticks — hence the IRQ0 edges — depends on this knob, and that
cadence is explicitly structural, not oracled.

The default 1024 was chosen so the ``pirqsoc`` differential is
boundary-independent: with roughly 8 clocks per instruction and a ~12-
instruction IRQ0 handler, count 0x40 gives about 65 k clocks per IRQ0 — wide
margin for the mainline to finish handler-plus-spin between edges, making the
post-spin counter value deterministic. The F3 override exists because
SeaBIOS's ``sti``/``hlt`` disk wait spins on the timer IRQ: at divisor 1024 an
18.2 Hz-equivalent IRQ0 period is ~67 M clocks — glacial in simulation, and it
trips the testbench quiescence detector — so the FreeDOS bring-up passed a
small divisor for a fast timer. Sim-only: the FPGA flow must instead retune
``TICK_DIV``/``TICK_INC`` for the real clock so IRQ0 is genuinely
1.193182 MHz-derived (``fpga/TIMING_PROBLEMS.md``).

Gotchas: not bit-exact across values in SoC runs even though no architectural
register changes — IRQ0 edges move, so retire traces of IRQ-taking programs
differ; this is legal only because the differential checkpoints were designed
boundary-independent. The ``pirqsoc`` gate is byte-identical at the default
and would *not* survive an override. Both bounds matter: too-slow IRQ0 plus
``sti``/``hlt`` falsely trips quiescence; too-fast IRQ0 starves the mainline
and breaks the deterministic-count property. ``TICK_INC`` is fixed at 1 in the
SoC instance, so the macro is a pure integer divider here. The unit gate
(``verif/soc/run_pit.sh``) is independent — its testbench hard-pins
``TICK_DIV = 1``.

``VEN_DBG_WD``
--------------

A sim-only opt-in hang watchdog inside ``rtl/core/core.sv``, built for boot
bring-up gap-walking (finding where SeaBIOS or FreeDOS wedges without a
waveform). It adds two registers: ``dbg_stall``, a cycles-since-last-retire
counter (any retire zeroes it), and ``dbg_printed``, a one-shot latch. When
the counter hits exactly 150 000 with the latch clear, it ``$display``\ s a
single ``[VEN-WD] STUCK`` line dumping the wedged FSM state *by name*
(``state.name()``), the outstanding ``mem_addr``, ``cr0``,
sys-mode/v86/real-mode, ``eflags``, the IDT/GDT bases, the in-flight
``int_vec``, CPL, CS base and ``eip`` — exactly the registers needed to
localize a real/protected-mode delivery wedge. Pure observation: no output
ports, no FSM influence — retire streams are bit-identical with or without it.

The threshold was deliberately *raised* to 150 000 in commit ``564d4d9`` when
interruptible HLT landed, so legitimate long yield-halts between timer IRQs do
not false-fire; it is co-tuned with ``VEN_PIT_TICK_DIV`` (at divisor 1024 an
``sti``/``hlt`` wait can legally sit ~67 M clocks without retiring, which is
why the watchdog is opt-in and bring-up runs pair it with a fast PIT divisor).
No committed setter — manual ``+define+VEN_DBG_WD`` works for both the ``rtl``
and ``soc`` targets. Gotchas: it is one-shot — only the first stall per reset
is reported. It uses ``state.name()``, fine under Verilator but another reason
it must never reach synthesis. A multi-cycle iterative engine (an SRT divide,
~66 clocks) is far below threshold, but artificially lowering the constant can
false-fire on legitimate long microcoded sequences; 150 000 is the empirically
safe value. It is distinct from the testbench-level quiescence detector
(always on) and from the architectural ``cpu_hung`` F00F-erratum latch (always
built).

``VEN_DBG_SSBASE``
------------------

A sim-only F3 gap-walk probe pair compiled into the top of the ``S_DECODE``
arm (``rtl/core/core_fetch_decode.svh``). Probe 1 (``SSBASE-DESYNC``): on
every instruction decode while ``seg_real`` is set (real mode or V86), it
checks that the SS, DS and ES segment *bases* equal their selector << 4 — the
real-mode invariant — and prints ``eip`` plus all three selector/base pairs on
any mismatch. This is the probe class that root-caused the F3 FreeDOS stall: a
stale protected-mode base surviving into real-mode addressing. Probe 2
(``ESP-HIGH``): while ``seg_real``, it checks ``ESP[31:16] == 0`` — 16-bit
code never legitimately carries high ESP bits, so a hit means a 32-bit-ESP
stack op leaked past 64 K (the missing real-mode SP wrap, explicitly noted as
the audit's remaining finding). Both are pure ``$display`` statements
evaluated once per ``S_DECODE``; no state, port or timing change — bit-exact
on/off. No committed setter; F3 forensics use only, paired naturally with
``VEN_DBG_WD`` and ``VEN_IDE_TRACE``.

Read the output with care: probe 1 false-positives *by design* on unreal-mode
idioms — SeaBIOS's big-real transitions deliberately carry a protected-mode
data selector with base 0 into real mode, tripping the ``sel << 4`` check
while being exactly what the firmware intended — so its output is a
lead-generator, not an assertion. It fires per decoded instruction while the
condition persists, so a genuine desync floods the log (useful as a timeline,
expensive in throughput). And probe 2 documents a *known modelling gap* rather
than a guest bug — a hit may indict the core, not the software. User-mode
protected/flat corpora never assert ``seg_real``, so both probes are silent
there.

Deployed configurations
=======================

This section records the define sets the committed build entry points actually
use.

The default verification battery
--------------------------------

The canonical builds set **no defines at all**. The ``verif/tb/Makefile``
``rtl`` target leaves ``VL_EXTRA_DEFINES`` empty and builds into ``obj_dir``;
it is invoked define-free by ``make verify`` (``verif/verify.sh``), the
milestone runners (``run-m0-smoke.sh`` through ``run-m5.sh``), ``make
verify-sys`` (``verif/sys/run-sys-golden.sh``), the errata suite (``make
m6``), the Quake and Win95 lockstep/cosim runs (``verif/m7``), and the
benchmark sweeps (``verif/bench``). The ``emu`` and ``rtl-sva`` targets use
the same zero-define set (``rtl-sva`` adds only ``--assert`` and the
``biu_p5_sva`` bind). Everything this page calls "the default build" is this
configuration; it is the one byte/cycle-identical to the golden model.

Variant verification builds layer exactly the define under test on top:
``make rtl`` with ``+define+VEN_FP_OVERLAP`` into ``obj_dir_fpovl`` and
``+define+VEN_FXCH_FREE`` into ``obj_dir_fxch`` (the M5 gap kernels);
``+define+VEN_TRANSCENDENTAL`` into ``obj_dir_trsc`` (the in-core
transcendental gates); the ``l1axi`` target (``+define+VEN_L1_AXI``, plus the
C-side ``-DVEN_L1_AXI``) into ``obj_dir_l1axi`` and ``l1axi_cdc``
(``+define+VEN_AXI_CDC``) into ``obj_dir_l1axi_cdc``; the ``proxy`` target
(``+define+VEN_PS_PROXY``) into ``obj_dir_proxy``; and the FP_PIPE2 A/B gate,
whose base set is ``VEN_SRT_ITER VEN_IDIV_ITER VEN_BCD_ITER VEN_FP_PIPE
VEN_BTB_PIPE`` with build B adding ``VEN_FP_PIPE2`` (``obj_dir_fp1``/
``obj_dir_fp2``). The standalone unit-engine gates pass only testbench-local
value macros (``SRT_N``, ``BCD_N``, ``IDIV_N``, …), no core feature flags.
Every variant gets its own object directory precisely so the canonical
``obj_dir/tb_ventium`` is never clobbered.

The SoC gate battery
--------------------

The ``verif/tb/Makefile`` ``soc`` target (top ``ventium_soc``,
``obj_dir_soc``) always defines exactly one macro: ``VEN_IDE_DISK_HEX``,
defaulting to the ``pide`` disk image path. The ``make verify-soc`` aggregate
(``verif/soc/run-all-soc-gates.sh``) builds it that way for all the
peripheral, firmware-boot and real-mode gates; the disk-booting gates
(``run-soc-ide-gate.sh``, ``run-soc-boot-gate.sh``, ``run-soc-bootrm-gate.sh``,
``run-soc-bootdma-gate.sh``, ``run-soc-seabios-boot-gate.sh``) override only
the disk path. The PS-offload cosim gates add exactly one placement flag each:
``run-soc-ps-cosim-gate.sh <dev>`` builds
``{VEN_IDE_DISK_HEX, VEN_<DEV>_PS}`` into ``obj_dir_soc_<dev>ps`` for ``uart``,
``rtc``, ``i8042``, ``acpipm``, ``fdc`` and ``vga``; ``VEN_PIC_PS``,
``VEN_PIT_PS`` and ``VEN_PORT92_PS`` are not in the map — no gate sets them.

The shipped KV260 full-SoC bitstream
------------------------------------

The deployable image (``kv260_soc_impl_linux_40``, built by
``fpga/scripts/impl_kv260_soc.tcl`` with ``FE_PIPE=1`` at ``PL0_MHZ=40``) sets
the full production stack::

   SYNTHESIS  VTM_NO_DPI
   VEN_SRT_ITER  VEN_IDIV_ITER  VEN_BCD_ITER
   VEN_FP_PIPE  VEN_FP_PIPE2  VEN_BTB_PIPE
   VEN_IC_BRAM  VEN_UOPCACHE  VEN_CACHE_HALF
   VEN_L1_AXI  VEN_KV260_SOC
   VEN_FE_PIPE          (appended by the FE_PIPE=1 environment knob)

Reading it as layers: the two housekeeping tokens strip the DPI channel and
the sim-only assertions; the three iterative engines and the two-stage FP
commit pipeline are the bit-exact Fmax substrate; ``VEN_BTB_PIPE``,
``VEN_IC_BRAM``, ``VEN_UOPCACHE`` and ``VEN_CACHE_HALF`` are the front-end
congestion stack; ``VEN_L1_AXI`` + ``VEN_KV260_SOC`` are the platform layer
(real bus, PS seams, DDR-carveout remap); and ``VEN_FE_PIPE`` is the final cut
that lets the full SoC route. Three footnotes from the setters data:
``VEN_BCD_DIV100`` is **absent** from this list (and from
``apr_hc_pnr.tcl``) — the ÷100 step is documented in ``ven_bcd.sv`` and
``docs/fpga-synthesis.md``, but no committed Tcl carries the define; the
65.3 MHz half-cache result added it ad hoc; the older
``fpga/scripts/bd_kv260_soc.tcl`` validate-and-synth flow still carries the
pre-uopcache config (``VEN_IC_NARROWB`` instead of
``VEN_IC_BRAM``/``VEN_UOPCACHE``/``VEN_CACHE_HALF``, and no
``VEN_FP_PIPE2``); and no committed Tcl consumes
``fpga/build/periph_split.vdefs`` yet — the board path runs all peripherals on
the PS via ``ven_soc_axil``, so the ``VEN_<DEV>_PS`` flags are exercised only
in the Verilator SoC builds today.

``VEN_DBG_CORE`` — on-die debug / trace / step / breakpoint
-----------------------------------------------------------

A single opt-in flag arms a comprehensive forensic unit. It is **OFF by
default** (``make verify`` stays 77/77 byte/cycle-identical; the FPGA close is
unchanged). Turn it on for a *debug bitstream* (``DBG_CORE=1`` in
``fpga/scripts/impl_kv260_soc.tcl``) or a debug sim (``+define+VEN_DBG_CORE``;
the ``l1axi_kv_dos`` tb target carries it).

What it adds (all observers except step/breakpoint, which only act once the PS
arms them — so even a ``VEN_DBG_CORE`` build is cycle-identical until then):

* **Committed-state taps** — the EIP / CS / ESP / EFLAGS of the last retired
  instruction, the FSM micro-state (``state_e``), the last exception/IRQ vector
  and its source EIP, and live CR0 (PE/PG = real/protected/paging). Surfaced as
  ``ventium_top`` debug-bundle ports (read directly by ``tb_main``; on a stop it
  prints a one-line ``[VEN_DBG]`` dump naming *where and why* the core stopped).
* **PC ring buffer** (``ven_soc_dbg``, 32 × {state,CS,EIP}, BRAM) — the last N
  retired PCs, read back N-back via ``R_DBG_TRACE_IDX``/``_PC``/``_AUX``. On a
  board freeze this is the instruction *trail* into a derail.
* **Freeze detector** — a stall counter (reset on each retire); crossing the
  PS-set ``R_DBG_FREEZE_TH`` latches a snapshot (EIP/FSM/vector) + a sticky
  ``frozen`` bit, distinguishing a silent stall from a clean halt.
* **Performance counters** — cycles, retired, no-retire (stall) cycles, S_IO
  cycles, external IRQs (``R_DBG_PERF_*``). CPI = cyc/retired.
* **Single-step / breakpoint** — ``R_DBG_RUNCTL`` parks the core at the S_DECODE
  instruction boundary (``halt_req``), grants one instruction (``step``), or a
  PC breakpoint (``bp_en`` + ``R_DBG_BP_ADDR``) halts at the target. The park
  sits *below* SMI/NMI/INTR (no interrupt is lost) and is modeled on the
  resumable S_HLTWAIT halt; in-flight loads/fills advance untouched.

The PS reads it all through the ``ven_soc_axil`` 0x80+ window (mirrored in
``sw/ps/ven_soc_app/ven_soc_regs.h``); ``ven_soc_app`` probes ``R_DBG_CAP`` ==
``0xDB01_0020`` and ``dbg_dump_core()`` prints the full state + ring on a
``CPU_HUNG`` or a silent-stall auto-trigger. Verified: the deployed top lints +
``make verify`` 77/77 (off); in sim ``--dbg-step N`` walks the EIP stream one
instruction at a time and ``--dbg-bp <eip>`` parks at the target.
