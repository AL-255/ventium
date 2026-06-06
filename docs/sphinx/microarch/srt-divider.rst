============================================
The radix-4 SRT divider and the FDIV bug
============================================

The Pentium does not divide floating-point numbers with a one-shot wide divide;
it runs the **SRT algorithm** (Sweeney–Robertson–Tocher) in **base 4**, two
quotient bits per iteration, in a small carry-save datapath driven by a
hard-wired quotient-selection table. That table is the famous **PLA** Ken
Shirriff photographed and reverse-engineered from the die, and five missing
entries in it are the **FDIV bug** of 1994.

Ventium ships the *real* algorithm as an **optional, compile-time** division
engine (``fpu_x87_pkg::fx_srt_div``). With its **correct** PLA it produces the
correctly-rounded ``floatx80`` quotient — bit-identical to QEMU and to the
default fast divider. With its **buggy** PLA it reproduces the FDIV flaw **from
first principles**: no operand is special-cased, the famous wrong answer simply
*emerges* from the missing table cells.

This page documents the algorithm, the datapath, the bug, and how Ventium models
and verifies all of it. The primary references are Ken Shirriff, *"Intel's $475
million error: the silicon behind the Pentium division bug"* (righto.com, Dec
2024), and Alan Edelman, *"The Mathematics of the Pentium Division Bug"* (SIAM
Review 39(1), 1997), which formalises Tim Coe & Ping Tak Peter Tang's model.


Why SRT, and the recurrence
===========================

Restoring/non-restoring division yields one quotient bit per step. **Radix-4
SRT** yields *two* — twice as fast — by allowing a **redundant**, signed digit
set ``q ∈ {-2, -1, 0, 1, 2}``. With both operands normalised to ``[1, 2)`` and
``p`` the dividend, ``d`` the divisor, the iteration is::

    p_0   = p
    p_k+1 = 4 * (p_k - q_k * d)          choosing q_k so that |p_k+1| <= (8/3)*d
    p / d = sum_{k>=0} q_k / 4^k

The redundancy is what makes it cheap: ``q_k`` need not be computed exactly, only
*selected* from a coarse, truncated view of the partial remainder and the
divisor — that selection is the lookup table. The slack ``|p| <= (8/3)d`` (the
"8/3" is ``base 4 minus 1``, scaled) is exactly the headroom that lets a coarse
choice still converge.

.. note::

   A popular misconception is that SRT's redundant digits let it *correct*
   mistakes. They do not. If an out-of-set ``q_k`` is ever chosen, the partial
   remainder leaves the representable interval and the algorithm **cannot
   recover** — which is precisely how five wrong table cells corrupt the result.


The quotient-selection PLA
==========================

The digit is chosen from a **two-dimensional table** indexed by a *truncated*
divisor and a *truncated* partial remainder (Edelman §4):

* **Divisor** ``D`` — the top four fraction bits, ``1.dddd`` (16 columns,
  ``D = 16 + mb[62:59]`` in sixteenths, i.e. ``D/16 ∈ [1, 2)``).
* **Partial remainder** ``P`` — a **4-integer-bit, 3-fraction-bit** field
  (``xxxx.yyy``), i.e. an index in units of ``1/8``.

Within a column the five quotient digits occupy five bands (``+2`` at the top
down to ``-2``), separated by three-cell **overlap** regions where either
adjacent digit is a valid choice (the redundancy). Ventium encodes each column
as four lower-bound thresholds and selects with a ladder — *exactly* the
behaviour of ``fx_srt_pla``::

    q = (P >= T2) ? +2 : (P >= T1) ? +1 : (P >= T0) ? 0 : (P >= Tm1) ? -1 : -2

The 16-column threshold table is generated from Edelman's formal table by
``tools/srt/srt_model.py`` (``python3 tools/srt/srt_model.py pla`` re-emits the
SystemVerilog ``case`` block), so the RTL table is never hand-transcribed.


The carry-save datapath
=======================

The subtle part — and the reason the bug exists at all — is **how** ``P`` is
formed. The partial remainder is kept in **ones-complement carry-save**: a sum
word ``S`` and a carry word ``C`` whose value is ``S + C``. Each step
(``fx_srt_div``):

#. **Index.** Take the 4-int/3-frac field of ``S`` and of ``C`` and add them
   (7-bit, modular) to form ``P``. Because each word is truncated *independently*
   and then summed, the index can read up to ``1/4`` low — "one cell lower than
   the correct cell" — and the ones-complement modular wraparound is what makes a
   post-error excursion land deterministically.
#. **Select** ``q`` from the PLA at ``(P, D)``.
#. **Subtract.** Form ``-q*d`` by shifting and, for positive ``q``, ones-
   complementing ``d`` (or ``2d``); add it to ``(S, C)`` with a 3:2 carry-save
   adder. The ``+1`` ones-complement correction is *delayed* and injected into
   the carry word's least-significant bit on this step.
#. **Shift.** Multiply the new ``(S, C)`` by 4 (left-shift two) for the next
   iteration.

Ventium runs ``NSTEP = 36`` iterations (72 quotient bits), accumulates the signed
digits into a quotient register, and rounds to the 64-bit ``floatx80``
significand using the **sign of the final partial remainder** as the
round-to-nearest tiebreaker (the hardware-realistic final rounding). With the
*correct* PLA this is provably correctly-rounded; validated bit-exact against
exact rational division over a 10 000-divide corpus.


The FDIV bug
============

Intel's table had **16 omitted entries**; five of them are reachable and cause
the bug, eleven are unreachable and harmless. The five bad cells are the *top*
of the ``+2`` region (``8 * P_Bad ∈ {23, 27, 31, 35, 39}`` in ``1/8`` units) in
the five divisor columns whose significand begins

.. list-table::
   :header-rows: 1
   :widths: 18 14 14

   * - significand prefix
     - column ``D``
     - ``8 * P_Bad``
   * - ``1.0001…``
     - 17/16
     - 23
   * - ``1.0100…``
     - 20/16
     - 27
   * - ``1.0111…``
     - 23/16
     - 31
   * - ``1.1010…``
     - 26/16
     - 35
   * - ``1.1101…``
     - 29/16
     - 39

(Edelman further proves these columns are exactly the divisors with six
consecutive ``1`` bits in positions 5–10 — the Coe–Tang result.) In those cells
the silicon's PLA returns **0 instead of +2**. When a divide's partial remainder
lands there, it picks ``0``, the remainder jumps to roughly ``10*d`` — far
outside ``[-8/3 d, 8/3 d]`` — and, per the no-recovery property above, the final
quotient is wrong, typically at the **13th significant bit** (≈ ``5e-5`` relative
worst case for operands in ``[1, 2)``).

The bug is rare (Intel quoted ~1 in 9 billion random divides) because *reaching*
a bad cell needs an unlucky carry-save trajectory: Edelman shows it can only be
entered from the cell just below it (the "foothold"), via a run of ``+2`` digits,
and never before the ninth iteration. A triggering **divisor** is therefore
*necessary but not sufficient* — most divides by such a divisor are still
correct.


How Ventium models it
=====================

``fx_div`` is a compile-time dispatcher. The defaults leave the project
bit-exact vs QEMU; the SRT engine is opt-in:

.. list-table::
   :header-rows: 1
   :widths: 34 66

   * - Build
     - Division datapath
   * - *(no define)* — **default**
     - ``fx_div_exact`` — fast behavioural wide divide (correctly rounded).
   * - ``+define+VEN_SRT_DIV``
     - ``fx_srt_div`` with the **correct** PLA — the genuine SRT engine; still
       correctly-rounded / bit-exact vs QEMU.
   * - ``+define+VEN_SRT_DIV`` ``+define+VEN_SRT_FDIV_BUG``
     - ``fx_srt_div`` with the **buggy** PLA — the FDIV flaw, reproduced for
       *all* operands from first principles.

With the buggy PLA the canonical pairs flaw exactly as documented, while a
triggering divisor alone does not:

.. list-table::
   :header-rows: 1
   :widths: 26 18 56

   * - operands
     - column
     - result (buggy PLA)
   * - ``4195835 / 3145727``
     - ``1.0111…``
     - flawed ``floatx80 0x3FFF_AAB7F6392A768638`` → double
       ``0x3FF556FEC7254ED1`` = ``1.3337390689…`` (wrong at the 13th bit); bug
       hit at iteration 8.
   * - ``5505001 / 294911``
     - ``1.0001…``
     - also flaws (the second widely-quoted pair).
   * - ``7654321 / 3145727``
     - ``1.0111…``
     - **clean** — triggering divisor, but the trajectory never hits a bad cell.
   * - ``4195835 / 3.0``
     - ``1.1000…``
     - clean — non-triggering divisor.


Verification
============

``make verify-srt`` (``verif/srt/``) is a standalone Verilator gate, independent
of the core/SoC build. It regenerates golden vectors from the single-source model
``tools/srt/srt_model.py`` — a faithful Python implementation of the same
datapath, validated correctly-rounded against exact rational division — and
asserts ``fx_srt_div`` is **bit-exact for both PLAs** over the famous FDIV pairs,
the negative controls, and a random corpus (**609 vectors × 2 PLAs**,
``SRT-GATE-OK``). The default tracks are unaffected: ``make verify`` 69/69 and
``make verify-soc`` 5/5 stay green.


Relationship to Erratum 23
==========================

The **runtime** FDIV erratum (``fx_div_errata``, gated by
``errata_en[ERR_FDIV]`` — see the :doc:`Instruction Catalog <../isa/index>` and
``docs/m6-errata-spec.md``) is unchanged. It returns the *documented* flawed
value for the one published bit-exact operand pair and is the honest fallback for
a model that has **no oracle** for the general flaw. The SRT engine *is* that
oracle: it bit-reproduces the documented flaw (and a second published pair) with
no operand special-cased — the very thing the erratum model's own comments noted
"would require bit-reproducing Intel's exact buggy SRT iteration." The two
coexist: ``fx_div_errata`` remains the default-build, self-checking anchor;
``fx_srt_div`` is the opt-in, first-principles reproduction.
