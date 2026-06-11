==================================================================
The FP execute/commit pipeline and the K26 60 MHz close
==================================================================

The Pentium retires a pipelined ``FADD``/``FSUB``/``FMUL`` at **throughput 1,
latency 3**: a new arithmetic op can issue every clock, and its result becomes
available to a dependent op three clocks later. Ventium reproduces that timing
with an **emergent FP scoreboard** (``core.sv``) — the result of an arithmetic op
is *published* at ``issue + latency`` (``fadd`` = 3), and any dependent (role ≥ 2)
consumer is stalled until that cycle.

That scoreboard is also the seam that lets the FPGA build run fast. This page
documents how the FP *execute/commit* path is pipelined behind compile-time flags
without disturbing a single observable cycle — and how the second stage
(``+VEN_FP_PIPE2``) takes the half-cache KV260 (XCK26 / **K26**) build across the
**60 MHz** line.

.. contents::
   :local:
   :depth: 1

The deferred fast-arm commit (``+VEN_FP_PIPE``)
===============================================

In cycle mode the fast arm issues an arithmetic op and would, naively, compute its
whole value combinationally in the issue clock — ``f_eval(op, st0, sti)`` — and
write the x87 register file the same edge. On the FPGA that ties the **entire FADD
datapath** (operand select → align → add → normalize → round → pack) onto the
``eip → icache → decode → issue`` front-end path: one enormous cone in one clock.

``+VEN_FP_PIPE`` breaks it with a **1-deep defer**. The op's operands are *captured*
at issue (cycle N) into pipeline registers ``fpp_a/fpp_b/fpp_aluop/…`` and the
instruction retires normally; one clock later (N+1) the value is evaluated from the
**registered** operands and written to the absolute target via a dedicated
``we_wabs`` port on ``fpu_top``. The trick that makes this free:

   The scoreboard already publishes the result at ``issue + 3``. The deferred
   commit lands at ``N+1`` — well before any dependent can read it — so the
   architectural state at every retire is unchanged. The defer is **invisible to
   correctness**; it only moves where the combinational cone sits in time.

A 1-clock read-after-write *hazard* guards the one window the defer exposes: an FP
op that reads the in-flight target the same clock the deferred result is being
written would see the pre-edge stale value, so it is stalled one clock. Role ≥ 2
consumers are already scoreboard-stalled past that window, so the hazard only bites
``FXCH``/``FLDSTI``/slow ``FST``/``FCOM`` — none of which appear in the throughput
microbenchmarks, so the FP cycle bands (``mb_faddchain`` CPI ≈ 3, ``mb_fpindep`` at
throughput 1) are preserved.

The wall: a latency-1 cone P&R cannot shorten
=============================================

On the half-cache K26 build the deferred commit *itself* becomes the critical path:
``fpp → f_eval_s1 → f_eval_s2 (fx_round_pack) → fpr`` — about **80 logic levels and
43 CARRY8 in series**, ~58 % of it routing. A full timing-driven place-and-route
sweep (one synthesis, many directives, all over-constrained) lifts the routed Fmax
from the production congestion directives' 50.1 MHz to **52.6 MHz**
(``ExtraNetDelay_high`` placement) — and then stops:

* **Placement** can only redistribute the route delay on the cone; a Pblock that
  clusters the FP datapath pushes the FADD cone off the critical path but merely
  exposes the next one (the µop-cache ``store_bmap → eip`` fill path at ~51 MHz).
* **Retiming** cannot help: the deferred commit is a **latency-1** path — one
  register layer between ``fpp`` and ``fpr`` — so there is nothing to balance.
  Retiming *slides* a register along a cone; it does not *add* pipeline depth.
* **Synthesis** itself caps at 59.4 MHz on this cone.

The binder is **logic depth**, not routing — so the fix has to shorten the cone.

The 2-stage split (``+VEN_FP_PIPE2``)
=====================================

``f_eval`` is already factored into two functions: ``f_eval_s1`` (special-operand
detection + the add/sub/mul *front*, ``fx_add_s1``/``fx_mul_s1``) returning an
``fx_pipe_t`` carrier, and ``f_eval_s2`` (``fx_round_pack`` + flag assembly). The
1-stage defer composes them in **one** clock. ``+VEN_FP_PIPE2`` inserts **one
register** at that boundary:

.. graphviz::

   digraph fp2 {
     rankdir=LR; node [shape=box, fontsize=10, fontname="monospace"];
     issue   [label="issue N\ncapture fpp_*"];
     s1      [label="N+1\nf_eval_s1\n(front)"];
     reg     [label="fpp2_s1\n(fx_pipe_t reg)", shape=box, style=filled, fillcolor="#cde"];
     s2      [label="N+2\nf_eval_s2\n(round_pack)\n-> we_wabs -> fpr"];
     pub     [label="issue+3\nscoreboard\npublishes", shape=ellipse, style=filled, fillcolor="#dfd"];
     issue -> s1 -> reg -> s2 -> pub [style=dashed,label="<= in time"];
   }

The commit now lands at **N+2** instead of N+1. Because the scoreboard still
publishes at ``issue + 3``, ``N+2 ≤ N+3`` — the value is in ``fpr`` before any
dependent reads it. The cone halves: the add/mul front in one clock, the
round-pack + write in the next. The read-hazard simply widens to the now-2-deep
in-flight window (stall a reader of either the stage-0 or stage-1 target).

Cycle-safety: verified, not asserted
=====================================

The change is gated entirely under ``ifdef VEN_FP_PIPE2`` and the **default build
is byte/cycle-identical**. The split itself is proven equivalent to the validated
1-stage by ``make verify-fppipe2`` (``verif/fppipe/run-fp-pipe2-ab.sh``), which
builds two cycle testbenches differing only by the flag and runs both on the FP
cycle kernels:

* ``mb_faddchain`` (dependent FADD chain): the ``--cycle`` traces are
  **byte-identical** — the 2-stage is cycle-for-cycle the 1-stage.
* ``mb_fpindep`` (independent FADDs at throughput 1): **identical final
  architectural state** (no stale read slipped through) and **+0.09 %** total
  cycles from the one-clock-wider hazard — comfortably inside the M5 FP band.
* Both meet the M5 FP CPI bands (``mb_faddchain`` ≈ 3.0, ``mb_fpindep`` below it);
  ``make verify`` stays GREEN on the default build; the 1M-vector
  ``f_eval_s2 ∘ f_eval_s1 == f_eval`` composition gate is bit-exact.

The Fmax result (K26 half-cache)
================================

.. list-table::
   :header-rows: 1
   :widths: 30 18 18 14

   * - Metric (routed OOC, XCK26, 15 ns)
     - 1-stage ``VEN_FP_PIPE``
     - ``+VEN_FP_PIPE2``
     - Δ
   * - Fmax — synthesis (WNS @ 15 ns)
     - 59.4 MHz
     - **78.4 MHz**
     - +32 %
   * - Fmax — routed (best directive)
     - 52.6 MHz
     - **63.0 MHz**
     - +20 %
   * - CLB LUTs (synth)
     - 77,975
     - 76,700
     - −1.6 %
   * - CLB Registers
     - 25,565
     - 25,838
     - +273 FF
   * - Worst path
     - ``fpp → fx_round_pack → fpr``
     - ``u_bcd`` (FBLD/FBSTP)
     - cone gone

Splitting the cone moves the FADD datapath off the critical path entirely
(synthesis 59 → 78 MHz) and routes the half-cache build to **63.0 MHz** — clearing
the 60 MHz target on the K26 — for the price of **one ``fx_pipe_t`` stage register**
(~273 flip-flops), LUT-neutral. The worst path is now the rare iterative **BCD
engine** (``ven_bcd``, the FBLD/FBSTP packed-decimal conversion), with the
µop-cache fill-to-PC path just below it — both well above 60 MHz.

A follow-up cycle-neutral fix takes the next worst path too: ``ven_bcd``'s per-clock
step ran **two chained divide-by-10**; computing **one divide-by-100** and extracting
the two low digits from ``q % 100`` (a 0..99 value) halves that cone, bit-exact
(``make verify-bcd``). Synthesis rises to **80.6 MHz** and the routed half-cache build
to **65.3 MHz** (``ExtraNetDelay_high`` placement). The remaining wall is the
**route-bound µop-cache fill → front-end cluster** (``store_bmap → eip``/``ic_age``),
which is placement-variable — the diffuse front-end congestion that in-context
floorplanning, not a single-cone fix, addresses.

See :doc:`/microarch/l1-parametric` for the ``+VEN_CACHE_HALF`` geometry knob this
build sits on, and ``docs/fpga-synthesis.md`` for the full place-and-route sweep,
device views, and reproduction commands.
