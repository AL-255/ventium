============================================
The Radix-4 SRT Divider and the FDIV Bug
============================================

The Intel Pentium does not divide floating-point numbers with a single-cycle
combinational divider; it runs the **Sweeney–Robertson–Tocher (SRT) algorithm**
in **radix 4** (two quotient bits per step) inside a ones-complement carry-save
datapath driven by a quotient-selection PLA. Five missing ``+2`` entries in
Intel's original PLA caused the famous 1994 **Pentium FDIV bug** (Erratum 23).

Ventium implements this exact radix-4 SRT algorithm in two bit-identical forms:

1. **Synthesizable Multi-Cycle Hardware Engine (rtl/fpu/fpu_srt_div.sv,
   +define+VEN_SRT_ITER):** Used in the **deployed c0e3fe43 FPGA
   profile** inside ``fp_shared/ven_fp_top.sv`` (with
   ``+define+VEN_SRT_REM_OPERAND_SPLIT``), sharing one compact iterative engine
   across ``FDIV``/``FDIVR``, ``FIDIV``/``FIDIVR``, ``FSQRT``, ``FPREM``, and
   ``FPREM1`` at ``40.264133 MHz`` STA-closed hardware speed (``0.515778001``
   total U+V Quake gameplay IPC across cycles ``28,696,827,616–32,989,404,795``).
2. **Combinational Reference Function (fpu_x87_pkg::fx_srt_div):** The
   zero-define unit-simulation default, executing the identical 36-step
   carry-save recurrence in a single function evaluation.

With the **correct PLA** (default), both engines produce IEEE-754
correctly-rounded 80-bit ``floatx80`` quotients bit-exact against QEMU. With
``+define+VEN_SRT_FDIV_BUG``, the **buggy PLA** reproduces the 1994 FDIV flaw
**from first principles** for any operand trajectory that reaches the five
omitted PLA cells — with zero operand special-casing.

Primary references: Ken Shirriff, *"Intel's $475 million error: the silicon
behind the Pentium division bug"* (righto.com, Dec 2024), and Alan Edelman,
*"The Mathematics of the Pentium Division Bug"* (*SIAM Review* 39(1), 1997),
formalizing Tim Coe & Ping Tak Peter Tang's model.

Why radix-4 SRT, and the recurrence
===================================

Restoring division produces 1 quotient bit per step. **Radix-4 SRT** produces
*2 bits per step* by selecting from a **redundant signed digit set**
``q_k ∈ {-2, -1, 0, +1, +2}``. With dividend ``p`` and divisor ``d`` normalized
to ``[1, 2)``::

    p_0     = p
    p_{k+1} = 4 * (p_k - q_k * d)        choosing q_k so |p_{k+1}| <= (8/3) * d
    p / d   = sum_{k >= 0} q_k / 4^k

Redundancy means ``q_k`` can be chosen from a **truncated** estimate of ``p_k``
and ``d`` via a small lookup PLA rather than a full-width comparator.

.. note::

   SRT redundancy tolerates *truncation error in the PLA index*, **not** an
   invalid digit choice. Once a wrong table entry emits ``0`` where ``+2`` was
   required, ``|p_{k+1}|`` jumps outside ``(8/3)d`` and subsequent steps can
   never recover the lost weight.

The quotient-selection PLA
==========================

Each iteration indexes a two-dimensional threshold table (Edelman §4):

* **Truncated Divisor D:** Top 4 fraction bits ``1.dddd`` (16 columns,
  ``D = 16 + mb[62:59]`` in sixteenths).
* **Truncated Partial Remainder P:** Signed 7-bit ``xxxx.yyy`` (4 integer +
  3 fraction bits, units of ``1/8``).

Each column encodes four lower-bound thresholds ``(T2, T1, T0, Tm1)`` generated
deterministically by ``tools/srt/srt_model.py``::

    q = (P >= T2) ? +2 : (P >= T1) ? +1 : (P >= T0) ? 0 : (P >= Tm1) ? -1 : -2

The ones-complement carry-save datapath
=======================================

The partial remainder is maintained in **ones-complement carry-save** form
``(S, C)``:

1. **Index:** Truncate ``S`` and ``C`` independently to 7 bits (``xxxx.yyy``)
   and sum them modulo ``2^7`` to form ``P`` (introducing up to ``1/4`` downward
   truncation bias).
2. **Select:** Look up ``q ∈ {-2, -1, 0, +1, +2}`` from ``fx_srt_pla(P, D)``.
3. **CSA Update:** Add ``-q * d`` (via shift and ones-complement inversion,
   injecting the delayed ``+1`` hot-one into ``C[0]``) through a 3:2 carry-save
   adder.
4. **Shift:** Multiply ``(S, C)`` by 4 (left-shift by 2) for the next step.

Running ``NSTEP = 36`` iterations yields 72 quotient bits, which round to the
64-bit ``floatx80`` significand using the sign of the final remainder as tie-break.

The five omitted PLA cells (FDIV bug)
=====================================

Intel's original P5 PLA omitted 16 boundary cells; 11 were unreachable, while
**5 reachable cells** at the top of the ``+2`` band (``8 * P_Bad ∈ {23, 27, 31,
35, 39}``) returned **0 instead of +2**:

.. list-table::
   :header-rows: 1
   :widths: 28 24 24

   * - Divisor significand prefix
     - Column ``D``
     - ``8 * P_Bad``
   * - ``1.0001…``
     - ``17/16``
     - ``23``
   * - ``1.0100…``
     - ``20/16``
     - ``27``
   * - ``1.0111…``
     - ``23/16``
     - ``31``
   * - ``1.1010…``
     - ``26/16``
     - ``35``
   * - ``1.1101…``
     - ``29/16``
     - ``39``

Reaching a bad cell requires six consecutive ``1`` bits in divisor positions
5–10 (Coe–Tang) *and* a carry-save foothold trajectory entering from the cell
immediately below after at least nine steps (~1 in ``9 × 10^9`` random divides),
corrupting the quotient around the 13th significant bit.

Build modes & verification
==========================

.. list-table::
   :header-rows: 1
   :widths: 38 62

   * - Configuration
     - Division Datapath
   * - **FPGA / c0e3fe43** (``+define+VEN_SRT_ITER``)
     - ``fpu_srt_div.sv`` — synthesizable multi-cycle radix-4 SRT divider/sqrt/``FPREM`` engine with the **correct PLA** (bit-exact vs. QEMU).
   * - **Default Unit Sim** *(no define)*
     - ``fx_srt_div`` with the **correct PLA** — combinational reference SRT engine.
   * - ``+define+VEN_SRT_FDIV_BUG``
     - Buggy PLA — reproduces the authentic 1994 FDIV flaw from first principles (e.g. ``4195835 / 3145727 → 1.3337390689…`` and ``5505001 / 294911``, while leaving ``7654321 / 3145727`` clean).
   * - ``+define+VEN_DIV_EXACT``
     - ``fx_div_exact`` — fast behavioral wide divide for simulation speed sweeps.

``verif/srt/`` validates ``fx_srt_div`` and ``fpu_srt_div`` bit-for-bit against
``tools/srt/srt_model.py`` across both PLAs (famous FDIV pairs, negative
controls, and random ``floatx80`` vectors), while ``errata_en[ERR_FDIV]``
retains the runtime Spec-Update ``242480-022`` erratum hook in default builds.
