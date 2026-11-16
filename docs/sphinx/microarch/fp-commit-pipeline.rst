==================================================================
The x87 FP Execute/Commit Pipeline & Shared FPU
==================================================================

The Intel Pentium retires pipelined ``FADD``, ``FSUB``, and ``FMUL`` operations
at **1-per-clock throughput and 3-clock latency** (paired with zero-cycle
``FXCH`` register renaming). Ventium models that pipeline timing through its FP
scoreboard and implements it on hardware via the **shared pipelined 80-bit x87
FPU** (``fp_shared/ven_fp_top.sv`` under ``+define+VEN_FP_SHARED``) together
with the two-stage deferred commit flags ``VEN_FP_PIPE`` and
``VEN_FP_PIPE2``.

.. important::

   **Deployed c0e3fe43 Hardware Status (RK-XCZU15EG-F):**
   On board-qualified image ``c0e3fe43`` (``xczu15eg-ffvb1156-2-i``, Vivado
   **2025.2**, ``161`` defines including ``VEN_FP_SHARED``, ``VEN_FP_PIPE``,
   ``VEN_FP_PIPE2``, ``VEN_FP_FXCH_QUEUE``, ``VEN_SRT_ITER``, and
   ``VEN_TRANSCENDENTAL``), the entire shared 80-bit x87 FPU — stack state,
   ``FXCH`` rename queue, pipelined add/sub/mul, radix-4 SRT div/sqrt/``FPREM``,
   BCD, and polynomial transcendentals — fits in **72,204 LUTs and 38
   DSP48E2 slices** (``1.08%`` of device DSPs) and closes full-SoC slow-corner
   post-route STA at ``40.264133 MHz`` (``WNS = +0.164 ns``, ``WHS = +0.010 ns``),
   driving DOS Quake ``demo1`` at ``8.0 FPS`` and **0.515778001 total
   U+V gameplay IPC** (``0.397847833`` primary/U across cycles
   ``28,696,827,616–32,989,404,795``).

.. contents::
   :local:
   :depth: 1

Why combinational x87 commit breaks FPGA timing
===============================================

In a naive single-cycle model, issuing a fast-path ``FADD``/``FSUB``/``FMUL``
evaluates ``f_eval(op, st0, sti)`` combinationally in the issue clock — chaining
``eip → icache → decode → issue`` directly into **80-bit operand select →
exponent alignment → 64-bit mantissa add/mul → leading-zero normalization →
IEEE-754 fx_round_pack → x87 stack writeback**.

Because the Pentium scoreboard already withholds arithmetic results from
dependent consumers until ``issue + 3``, evaluating the entire 80-bit cone in
cycle ``N`` is unnecessary for architectural or cycle-level fidelity.

Stage 1: Deferred fast-arm commit (``+VEN_FP_PIPE``)
====================================================

``VEN_FP_PIPE`` decouples FP arithmetic evaluation from instruction fetch/decode
with a 1-stage input capture:

* **Cycle N (Issue):** Operands and rounding/opcode controls latch into
  ``fpp_a`` / ``fpp_b`` / ``fpp_aluop`` while the instruction retires in program
  order.
* **Cycle N+1 (Deferred Commit):** Arithmetic evaluates from registered
  operands and writes the physical destination slot before any ``issue + 3``
  dependent consumer can read it.
* **1-Cycle RAW Hazard Guard:** Non-scoreboarded stack readers (``FXCH``,
  ``FLD ST(i)``, slow ``FST``/``FCOM``) targeting the in-flight slot stall 1
  clock so they never observe pre-commit data.

Even after detaching fetch/decode, ``fpp → f_eval_s1 → f_eval_s2 (fx_round_pack)
→ fpr`` spans ~80 logic levels and 43 ``CARRY8`` primitives in a single cycle —
a pure logic-depth wall that synthesis retiming cannot split across a 1-deep
pipeline register.

Stage 2: Splitting ``f_eval_s1`` and ``f_eval_s2`` (``+VEN_FP_PIPE2``)
======================================================================

``f_eval`` factors naturally into two halves: ``f_eval_s1`` (special-operand
classification + add/sub alignment/sum or mantissa multiply front-end, emitting
an ``fx_pipe_t`` bundle) and ``f_eval_s2`` (normalization + ``fx_round_pack`` +
IEEE exception flags). ``VEN_FP_PIPE2`` inserts pipeline register ``fpp2_s1``
between them:

.. graphviz::

   digraph fp2 {
     rankdir=LR; node [shape=box, fontsize=10, fontname="monospace"];
     issue   [label="issue N\ncapture fpp_*"];
     s1      [label="N+1\nf_eval_s1\n(add/mul front)"];
     reg     [label="fpp2_s1\n(fx_pipe_t reg)", shape=box, style=filled, fillcolor="#cde"];
     s2      [label="N+2\nf_eval_s2\n(round_pack)\n-> stack write"];
     pub     [label="issue+3\nscoreboard\npublishes", shape=ellipse, style=filled, fillcolor="#dfd"];
     issue -> s1 -> reg -> s2 -> pub [style=dashed,label="<= in time"];
   }

Commit now completes at ``N+2 ≤ N+3``, halving single-cycle FP combinational
depth for ~273 flip-flops while keeping dependent ``FADD`` chains cycle-identical
and independent ``FADD`` streams at 1-per-clock throughput (verified by
``verif/fppipe/run-fp-pipe2-ab.sh`` and the 1M-vector
``f_eval_s2 ∘ f_eval_s1 == f_eval`` equivalence check).

Shared pipelined x87 FPU (``fp_shared/``) in ``c0e3fe43``
=========================================================

Earlier split transcendental leaf engines (``fpu_f2xm1``, ``fpu_fpatan``,
``fpu_fyl2x``, ``fpu_fsincos``) duplicated wide multipliers and adders across
four separate state machines. In the deployed ``VEN_FP_SHARED`` architecture
(``fp_shared/``), ``ven_fp_top.sv`` unifies all x87 execution behind one
architectural owner:

* **ven_fp_fxch_queue.sv & ven_fp_state.sv:** Pointer-mapped 8×80-bit
  register stack with a **zero-cycle FXCH rename queue**, overlapping ``FXCH``
  and asynchronous FP execution with integer U+V retirement (critical for DOS
  Quake's perspective-texture inner loops).
* **ven_fp_alu.sv & ven_fp_widemul.sv:** Shared pipelined 80-bit
  adder/subtractor and 38-DSP wide multiplier reused by both scalar ``FMUL`` and
  the microcoded polynomial transcendental sequencer (``ven_fp_trans.sv`` /
  ``ven_fp_estdiv.sv``), cutting FPU area by more than 2× compared with split
  leaf engines.
* **fpu_srt_div.sv & ven_bcd.sv:** Shared multi-cycle radix-4 SRT
  divider/sqrt/``FPREM``/``FPREM1`` (with ``VEN_SRT_REM_OPERAND_SPLIT``) and
  iterative ``FBSTP``/``FBLD`` converters.

Historical isolated OOC benchmark (pre-``fp_shared`` K26 study)
===============================================================

During early pre-``fp_shared`` bring-up, an isolated out-of-context (OOC) study
on an XCK26 target (using the now-retired half-cache test harness, **never used
in deployed builds**) quantified the standalone Fmax impact of adding
``VEN_FP_PIPE2`` on the legacy ``fpu_top`` datapath:

.. list-table:: Historical standalone OOC comparison (legacy ``fpu_top``, XCK26 OOC)
   :header-rows: 1
   :widths: 34 22 22 22

   * - Metric
     - 1-stage ``VEN_FP_PIPE``
     - 2-stage ``+VEN_FP_PIPE2``
     - Delta
   * - Synthesis Fmax estimate
     - 59.4 MHz
     - **78.4 MHz**
     - +32 %
   * - Routed OOC Fmax
     - 52.6 MHz
     - **63.0 MHz**
     - +20 %
   * - Worst path
     - ``fpp → fx_round_pack → fpr``
     - ``u_bcd`` (iterative BCD)
     - FP ALU off critical path

In the full deployed ``c0e3fe43`` SoC on **RK-XCZU15EG-F** (with **full 8 KiB
P5 L1 caches**, ``fp_shared/``, and ``retime_muxf_route_first``), the x87 FPU is
no longer the chip's setup bottleneck — the worst full-chip path lies in the
integer fetch-to-L1D hit-return cone (``24.522 ns`` at ``25.000 ns`` constraint,
``+0.164 ns`` positive slack). See :doc:`/microarch/l1-parametric` and
:doc:`/microarch/srt-divider`.
