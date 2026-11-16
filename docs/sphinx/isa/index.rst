===================
Instruction Catalog
===================

This is the per-instruction reference for the Ventium P5/P54C replica. Every
instruction the integer and x87 cores decode is listed under its category,
together with how it drives the pipeline datapath and which pipe (U or V) it
may issue to.

Read the **Primer** and **Legend** first: they define the five-stage dual-issue
datapath and the U/V pairing classes (``UV`` / ``PU`` / ``PV`` / ``NP``) that
every table column below refers to. Each category then has a *list-table*
giving, per instruction, the mnemonic, encoding, U/V class, a one-line datapath
usage summary, and an honest status; prose under each table fills in what the
instruction computes and the full datapath story where it does not fit in a
cell.


.. _primer:

Primer: the five-stage dual-issue datapath
==========================================

Ventium models the Pentium's classic **in-order, dual-issue, five-stage**
integer pipeline:

================  ============================================================
Stage             What happens
================  ============================================================
**PF** Prefetch   Instruction bytes are fetched from the L1 I-cache into the
                  prefetch/instruction buffer; prefixes are consumed by the
                  prefix machine.
**D1** Decode-1   The opcode is decoded. The *fast-path* decoder
                  (``decode.sv``) recognises the simple, single-cycle forms
                  and sets ``simple=1`` plus the pairing hints
                  ``pairs_first`` / ``pairs_second``. The pairing checker
                  (``issue_uv``) decides whether two adjacent instructions may
                  dual-issue. The BTB is looked up here for branches.
**D2** Decode-2   Operands are read from the GPR file; the AGU forms effective
                  addresses for memory operands (and is the source of AGI
                  interlocks).
**EX** Execute    The shared single-cycle ALU / shifter / branch-resolve
                  logic runs in whichever pipe hosts the instruction. Memory
                  loads issue to the L1 D-cache here.
**WB** Writeback  Results are committed to the register file and EFLAGS;
                  EFLAGS / register results are forwarded by the full
                  ``EX→EX`` and ``WB→EX`` bypass network so a dependent chain
                  of simple ops runs at 1/clock.
================  ============================================================

Two parallel execution slots run this pipeline: the **U pipe** (the primary
slot, which may lead a pair) and the **V pipe** (the secondary slot, which
fills behind a U-pipe instruction). When two adjacent instructions satisfy the
pairing rules they *dual-issue* and retire together (up to 2/clock); otherwise
the instruction issues alone in U with the V slot idle.

Not every instruction takes this **fast path** in the zero-define unit-test
baseline. In that baseline, byte-operand forms, memory read-modify-write forms,
immediate+ModR/M forms, ``0F``-prefixed (two-byte) opcodes, string primitives,
x87 escapes, and system/microcoded ops decode on the **slow multi-cycle FSM**
in ``core.sv`` / ``decode_stages.sv`` (``S_DECODE → S_LOAD → S_EXEC → S_STORE``
plus ``S_USEQ``). In the **deployed c0e3fe43 P54C hardware profile**
(``161`` defines on RK-XCZU15EG-F; :doc:`/build-flags`, ``0.515778001`` total
U+V Quake gameplay IPC across cycles ``28,696,827,616–32,989,404,795``),
``decode.sv`` and ``S_PIPE`` additionally fast-path protected-mode flat,
relocated, and bounded memory loads/stores (``VEN_SYS_FASTPATH*``), 8-bit
register ALU/shifts (``VEN_FAST_BYTE_ALU`` / ``_SHIFT``), ``PUSH``/``POP``,
``0x66`` operand-size prefixes, ``REP STOS``/``REP MOVS`` cacheable streaming
(``VEN_REP_STOS_STREAM``), and asynchronous shared x87 execution with a
zero-cycle ``FXCH`` rename queue (``fp_shared/``), while ``VEN_FAST_MEM_EXT``
(on ``experimental/uv-fast-ipc-apr``) admits 32-bit ``MOVZX``/``MOVSX`` memory
loads directly into ``S_PIPE``. Where baseline and ``c0e3fe43`` fast-path
coverage differ, the tables below note both clearly.


.. _legend:

Legend: the U/V pairing classes
===============================

The Pentium optimization reference (informally "AP-500") classifies each
instruction by *how* it may participate in a U/V pair. Ventium uses the same
four classes. The class is a property of the instruction's datapath needs:

``UV`` — pairable in **either** pipe
    A simple, single-cycle ALU/MOV op with no carry-chain input, no shifter,
    and no microcode. It can **lead** a pair (as the U member) or **fill** the
    V slot, subject only to the ordinary RAW/WAW/displacement-plus-immediate
    pairing checks. *Datapath rationale:* both the U and V ALUs implement the
    same one-cycle ``alu_result`` / ``flags_next`` logic, so either can host
    it.

``PU`` — pairable **U-pipe only**
    The op may **lead** a pair (U member) but can **never** fill the V slot.
    *Datapath rationale:* it needs a resource only the U pipe provides — the
    forwarded/latched carry (``ADC`` / ``SBB`` / ``RCL`` / ``RCR``) or the
    shifter and its CF/OF latch (``SHL`` / ``SHR`` / ``SAR``). The V ALU has
    no carry forwarding and no shift unit, so an op placed there would read the
    *stale* architectural ``EFLAGS[0]`` (carry) and corrupt state, or have no
    shifter at all. A prefixed instruction is also U-only per AP-500 §5.6.2.3
    (the prefix-decode slot is a U-pipe resource).

``PV`` — pairable **V-pipe only**
    The op may **fill** the V slot (behind a leading U op) but can **never**
    lead a pair. *Datapath rationale:* branches. A taken branch redirects the
    fetch stream, so nothing can issue *after* it in the same clock — it must
    be the *trailing* member. This is exactly the ``cmp;jcc`` / ``dec;jnz``
    special pair: a flags-writing U op forwards its result flags to the V-slot
    branch, which resolves against the new flags.

``NP`` — **not pairable**
    The op always issues alone in U with V idle. *Datapath rationale:* it is
    microcoded / multi-cycle (``MUL`` / ``DIV``, string ops, ``PUSHA``), a
    unary or two-source op outside the simple template (``NEG`` / ``NOT`` /
    ``SHLD``), a memory read-modify-write or two-access op, a system /
    privileged op, or simply not whitelisted by the fast-path decoder so it
    falls to the serializing slow FSM.

.. note::

   Two distinct facts are tracked throughout. **AP-500 class** is the
   *architectural* pairing class the real Pentium assigns. **Realized pairing**
   is whether *this* Ventium RTL actually dual-issues the instruction on its
   fast path. They often agree, but where the fast-path decoder does not
   whitelist an otherwise-pairable form (so it runs on the slow FSM and
   serializes), the U/V-class cell states the AP-500 class and the prose /
   status notes the divergence. A status of *"slow FSM"* means *functionally
   correct but serialized*; *"deferred / HALTs"* means the opcode is not
   decoded and traps to a loud ``S_HALT`` rather than mis-execute.


.. _int-alu:

INT-ALU — integer arithmetic and logic
======================================

The integer ALU group is the core of the fast path. The simple register-form
``01/03``-style ops are single-cycle and pairable in either pipe; the
carry-chain ops (``ADC`` / ``SBB``) are pinned to U; the unary ops (``NEG`` /
``NOT``) and most byte / memory / accumulator-immediate forms run on the slow
multi-cycle FSM. All share the same combinational ``alu_result`` /
``flags_next`` logic, so the slow forms are bit-identical to the fast ones —
they simply do not pair.

.. list-table::
   :header-rows: 1
   :widths: 22 22 12 30 14

   * - Mnemonic
     - Encoding
     - U/V class
     - Datapath usage
     - Status
   * - ``ADD r/m, r``
     - ``00 /r`` (8-bit); ``01 /r`` (16/32)
     - UV
     - Single-cycle U/V ALU_ADD; reg-form ``01`` fast-pathed, byte/mem on slow FSM.
     - implemented
   * - ``ADD r, r/m``
     - ``02 /r``; ``03 /r``
     - UV
     - Same ALU, dst = reg field; ``03`` reg-form fast-path, reg←mem on slow FSM.
     - implemented
   * - ``ADD AL/eAX, imm``
     - ``04 ib``; ``05 iz``
     - UV (AP-500)
     - Slow FSM only — no fast-path arm, so unpaired in practice.
     - implemented (slow FSM)
   * - ``ADD r/m, imm``
     - ``80 /0 ib``; ``81 /0 iz``
     - UV (AP-500)
     - Slow FSM group1; reg write or mem load→ALU→store RMW.
     - implemented (slow FSM)
   * - ``ADD r/m, imm8`` (sign-ext)
     - ``83 /0 ib``
     - UV
     - Canonical pairable imm form: imm-only (no disp), single-cycle U/V; mem on slow FSM.
     - implemented
   * - ``ADC r/m, r`` · ``ADC r, r/m``
     - ``10`` / ``11`` / ``12`` / ``13 /r``
     - **PU**
     - Carry-chain ALU_ADC; reg-form fast-pathed **U-only** (V has no CF forwarding).
     - implemented (PU)
   * - ``ADC AL/eAX, imm`` · ``r/m, imm`` · ``r/m, imm8``
     - ``14 ib`` ``15 iz``; ``80 /2`` ``81 /2`` ``83 /2``
     - **PU**
     - ``83 /2`` reg-form fast-pathed PU; acc/group1-imm on slow FSM.
     - implemented
   * - ``SUB r/m, r`` · ``SUB r, r/m``
     - ``28`` / ``29`` / ``2A`` / ``2B /r``
     - UV
     - Single-cycle ALU_SUB, no CF input; reg-form fast-path, byte/mem slow FSM.
     - implemented
   * - ``SUB AL/eAX, imm`` · ``r/m, imm`` · ``r/m, imm8``
     - ``2C ib`` ``2D iz``; ``80 /5`` ``81 /5`` ``83 /5``
     - UV
     - ``83 /5`` reg-form fast-pathed UV; acc/group1-imm on slow FSM.
     - implemented
   * - ``SBB r/m, r`` · ``SBB r, r/m``
     - ``18`` / ``19`` / ``1A`` / ``1B /r``
     - **PU**
     - Borrow-chain ALU_SBB; reg-form fast-pathed **U-only** (the ADC twin).
     - implemented (PU)
   * - ``SBB AL/eAX, imm`` · ``r/m, imm`` · ``r/m, imm8``
     - ``1C ib`` ``1D iz``; ``80 /3`` ``81 /3`` ``83 /3``
     - **PU**
     - ``83 /3`` reg-form fast-pathed PU; acc/group1-imm on slow FSM.
     - implemented
   * - ``AND r/m, r`` · ``AND r, r/m``
     - ``20`` / ``21`` / ``22`` / ``23 /r``
     - UV
     - Single-cycle ALU_AND (CF/OF/AF cleared); reg-form fast-path.
     - implemented
   * - ``AND AL/eAX, imm`` · ``r/m, imm`` · ``r/m, imm8``
     - ``24 ib`` ``25 iz``; ``80 /4`` ``81 /4`` ``83 /4``
     - UV
     - ``83 /4`` reg-form fast-pathed UV; acc/group1-imm on slow FSM.
     - implemented
   * - ``OR r/m, r`` · ``OR r, r/m``
     - ``08`` / ``09`` / ``0A`` / ``0B /r``
     - UV
     - Single-cycle ALU_OR; reg-form fast-path, byte/mem slow FSM.
     - implemented
   * - ``OR AL/eAX, imm`` · ``r/m, imm`` · ``r/m, imm8``
     - ``0C ib`` ``0D iz``; ``80 /1`` ``81 /1`` ``83 /1``
     - UV
     - ``83 /1`` reg-form fast-pathed UV; acc/group1-imm on slow FSM.
     - implemented
   * - ``XOR r/m, r`` · ``XOR r, r/m``
     - ``30`` / ``31`` / ``32`` / ``33 /r``
     - UV
     - Single-cycle ALU_XOR; the ``xor reg,reg`` zero idiom pairs.
     - implemented
   * - ``XOR AL/eAX, imm`` · ``r/m, imm`` · ``r/m, imm8``
     - ``34 ib`` ``35 iz``; ``80 /6`` ``81 /6`` ``83 /6``
     - UV
     - ``83 /6`` reg-form fast-pathed UV; acc/group1-imm on slow FSM.
     - implemented
   * - ``CMP r/m, r`` · ``CMP r, r/m``
     - ``38`` / ``39`` / ``3A`` / ``3B /r``
     - UV
     - ALU_SUB, EFLAGS only (no reg write); forwards flags U→V to a paired Jcc.
     - implemented
   * - ``CMP AL/eAX, imm`` · ``r/m, imm`` · ``r/m, imm8``
     - ``3C ib`` ``3D iz``; ``80 /7`` ``81 /7`` ``83 /7``
     - UV
     - ``83 /7`` reg-form fast-pathed UV (flags-forward to Jcc); others slow FSM.
     - implemented
   * - ``TEST r/m, r``
     - ``84 /r``; ``85 /r``
     - UV (AP-500)
     - ALU_TEST, EFLAGS only; slow FSM only — unpaired in practice.
     - implemented (slow FSM)
   * - ``TEST eAX, imm``
     - ``A8 ib``; ``A9 iz``
     - UV
     - ``A9`` (eAX,imm32) fast-pathed UV, EFLAGS only; ``A8`` byte on slow FSM.
     - implemented
   * - ``TEST r/m, imm``
     - ``F6 /0,/1 ib``; ``F7 /0,/1 iz``
     - **NP**
     - group3 slow FSM (``/0`` + ``/1`` alias); reg or mem load → ALU_TEST (EFLAGS only).
     - implemented (slow FSM, NP)
   * - ``INC r``
     - ``40+r`` (40..47)
     - UV
     - ALU_INC (CF preserved), ``b_op`` forced to 1; 1-byte op, fast-pathed.
     - implemented
   * - ``DEC r``
     - ``48+r`` (48..4F)
     - UV
     - ALU_DEC (CF preserved); ``dec;jnz`` forwards flags U→V (loop idiom).
     - implemented
   * - ``INC/DEC r/m``
     - ``FE /0,/1``; ``FF /0,/1``
     - UV (AP-500)
     - group4/5 slow FSM; reg write or mem RMW — unpaired in practice.
     - implemented (slow FSM)
   * - ``NEG r/m``
     - ``F6 /3``; ``F7 /3``
     - **NP**
     - Unary ALU_NEG on the slow FSM; never paired (matches AP-500 NP).
     - implemented (slow FSM, NP)
   * - ``NOT r/m``
     - ``F6 /2``; ``F7 /2``
     - **NP**
     - Unary ALU_NOT, no flags, on the slow FSM; never paired.
     - implemented (slow FSM, NP)

ADD (``ADD r/m,r`` ``00/01``; ``ADD r,r/m`` ``02/03``)
    Computes ``dst <- dst + src`` and sets all six status flags
    (CF/PF/AF/ZF/SF/OF). ``alu_op = ALU_ADD``; the result is ``a+b``, CF is the
    carry-out at the operand width, OF is signed overflow. **Datapath:** the
    register-form 32-bit op (``01`` / ``03`` with ``mod==11``) is the
    canonical fast-path case — D1 decodes it ``simple``, the pairing checker
    admits it (simple, no displacement+immediate, no RAW/WAW), D2 reads both
    GPRs, EX runs the shared single-cycle ``alu_result``/``flags_next`` in
    whichever pipe hosts it, and WB commits the register and EFLAGS. Full
    ``EX→EX`` and ``WB→EX`` bypass lets a dependent ``ADD`` chain run at
    1/clock; **UV** because it needs no carry input, so either ALU can host
    it. The byte forms (``00`` / ``02``) and *all* memory-operand forms drop to
    the slow FSM (load+ALU, or load→ALU→store RMW): functionally identical, but
    serialized.

ADD with immediate (``04/05`` acc; ``80/81 /0``; ``83 /0``)
    ``dst <- dst + imm``, same flags. Only the ``83 /0`` sign-extended-imm8
    *register* form is fast-pathed and pairable: it is imm-only (no
    displacement), so the ``disp_imm`` pairing veto does not fire, and it runs
    single-cycle in U or V. The accumulator forms (``04``/``05``) and the
    full-width group1 immediate forms (``80``/``81``) have *no* fast-path arm —
    they decode only on the slow FSM and therefore issue alone, even though
    AP-500 rates them UV.

ADC / SBB — the carry-chain ops (``10–13``, ``18–1B``, group1 ``/2`` ``/3``)
    ``ADC: dst <- dst + src + CF``; ``SBB: dst <- dst - src - CF``. These are
    the multi-word add/subtract primitives, and they are **PU — U-pipe only**.
    This is the central AP-500 finding the project grounds on: the carry input
    ``cfin`` comes from ``EFLAGS[0]``, and **only the U pipe forwards/latches
    the carry**. The decoder makes this explicit — for ``ADC``/``SBB`` it sets
    ``pairs_first=1`` but ``pairs_second=0`` (via
    ``pairs_second = !(b0[5:3]==010 || ==011)``), with the RTL comment stating
    that "the V ALU path has no CF forwarding, so an ``adc``/``sbb`` in V would
    consume the STALE architectural carry and corrupt arch state." So an
    ``ADC`` may *lead* a pair (U member) provided the V slot holds a non-ADC/SBB
    op, but can never *fill* V. The ``83 /2`` and ``83 /3`` reg forms are
    fast-pathed PU; the accumulator (``14``/``15``, ``1C``/``1D``) and group1
    immediate forms run on the slow FSM with the same stale-carry rationale.

SUB / AND / OR / XOR (``28–2B`` etc.)
    Simple ALU ops with **no carry input**, so all **UV**. ``SUB`` is
    ``a-b`` with borrow → CF and signed-subtract overflow → OF, setting all six
    flags. ``AND``/``OR``/``XOR`` force CF=OF=AF=0 and set ZF/SF/PF from the
    result. Reg-reg forms (``29``/``2B``, ``21``/``23``, ``09``/``0B``,
    ``31``/``33``) are fast-pathed; byte and memory forms run on the slow FSM.
    Note ``xor eax,eax`` still reads and writes ``eax``, so it will not fill V
    behind a U op that writes ``eax`` (RAW/WAW masks), but is otherwise UV.

CMP / TEST (``38–3B``, ``3C/3D``, ``83 /7``; ``84/85``, ``A8/A9``, ``F6/F7 /0,/1``)
    ``CMP`` computes ``a-b`` like ``SUB`` but discards the result and writes
    only EFLAGS (the register write mask is 0). It is **UV**, and is the U
    member of the ``cmp;jcc`` special pair: when ``CMP`` leads and a ``Jcc``
    fills V, the core computes ``u_flags_eff`` and *forwards* the new result
    flags so the paired branch resolves against them. The ``39``/``3B`` and
    ``83 /7`` reg forms are fast-pathed with this U→V flags forwarding; other
    forms run on the slow FSM. ``TEST`` is a non-storing ``AND`` (ALU_TEST,
    reusing the AND result), EFLAGS only. Only the ``A9 eAX,imm32`` form is
    fast-pathed UV; ``84``/``85`` and ``A8`` run on the slow FSM. ``TEST
    r/m,imm`` (``F6/F7 /0,/1``) is **NP** per AP-500 (only the
    reg,reg/mem,reg/imm,acc forms are UV); both its register and memory forms
    run on the slow FSM.

INC / DEC (``40+r``, ``48+r``; ``FE/FF /0,/1``)
    ``dst <- dst ± 1`` with **CF preserved** — distinct from the unary
    ``NEG``/``NOT`` below, ``INC``/``DEC`` *are* **UV**. The ALU reuses ``a+b``
    with the second operand forced to 1; the ``ALU_INC``/``ALU_DEC`` flag arms
    keep CF unchanged and set OF/AF/ZF/SF/PF. The 32-bit ``40+r``/``48+r``
    encodings are 1-byte and fast-pathed (a 1-byte first member is always
    allowed to pair per the I-cache-split exception). ``dec;jnz`` forwards its
    flags U→V exactly like ``CMP`` — the loop idiom. The ``FE``/``FF`` r/m
    forms (including the byte ``INC``/``DEC``) decode only on the slow FSM (reg
    write or mem RMW) and so issue alone here.

NEG / NOT (``F6/F7 /3``, ``F6/F7 /2``)
    Unary ops, both **NP** — AP-500 explicitly classes them not-pairable
    despite looking ALU-like, and Ventium has no fast-path arm for them, so
    they always serialize on the group3 slow FSM. ``NEG`` is ``0 - dst``
    (two's-complement) and sets CF=(dst≠0) plus OF/AF/ZF/SF/PF. ``NOT`` is
    ``~dst`` (one's-complement) and affects **no flags** (``d_writes_flags``
    stays 0). Both have a reg form (writes the GPR) and a mem form
    (load→modify→store RMW).


.. _data-mov:

DATA-MOV — data movement
========================

Data movement spans the simplest pairable op in the machine (``NOP``) and the
most microcoded (segment-register descriptor loads). Plain register ``MOV`` and
load-immediate forms are fast-pathed UV; register-base/displaced loads and
``LEA`` interact with the dual AGU (and the AGI interlock); ``MOVZX`` /
``MOVSX`` / ``XCHG`` / ``LAHF`` / ``CBW`` / ``XLAT`` are NP ops (with
``VEN_FAST_MEM_EXT`` admitting 32-bit ``MOVZX``/``MOVSX`` loads into ``S_PIPE``
and ``VEN_FAST_XCHG_R`` fast-pathing register ``XCHG``); and segment-register
``MOV`` runs through the system descriptor-validation path.

.. list-table::
   :header-rows: 1
   :widths: 26 20 12 28 14

   * - Mnemonic
     - Encoding
     - U/V class
     - Datapath usage
     - Status
   * - ``MOV r/m, r``
     - ``88 /r``; ``89 /r``
     - UV
     - Reg & flat/reloc ``S_PIPE`` store fast-pathed in ``c0e3fe43``; cross-page on ``S_STORE``.
     - implemented
   * - ``MOV r, r/m``
     - ``8A /r``; ``8B /r``
     - UV
     - Reg & flat/bounded/reloc ``S_PIPE`` loads fast-pathed (dual-load pairable in ``c0e3fe43``).
     - implemented
   * - ``MOV r, imm``
     - ``B0+rb``; ``B8+rd``
     - UV
     - ``B8+r`` imm32 single-cycle (no operand read → never an AGI source); ``B0-B7`` byte fast-pathed under ``VEN_FAST_BYTE_ALU``.
     - implemented
   * - ``MOV r/m, imm``
     - ``C6 /0 ib``; ``C7 /0 iz``
     - UV (AP-500)
     - Slow FSM group11 (disp+imm excluded from pairing); reg write or mem store.
     - implemented (slow FSM)
   * - ``MOV AL/eAX, moffs`` / ``moffs, AL/eAX``
     - ``A0`` ``A1`` (load); ``A2`` ``A3`` (store)
     - UV (+ erratum)
     - 16/32-bit effective-address ``moffs``; ``A2``/``A3`` modeled for pairing + Erratum 59 (``VEN_FAST_MOFFS_STORE``).
     - implemented
   * - ``MOV r/m16, Sreg``
     - ``8C /r``
     - **NP**
     - System path (``SYS_MOVSREG_FROM``); zero-extends selector to reg (32b) or writes 16b mem.
     - implemented
   * - ``MOV Sreg, r/m16``
     - ``8E /r``
     - **NP**
     - System path (``SYS_MOVSREG_TO`` / ``S_SEGLD``); real/V86 ``sel<<4`` or full PM GDT/LDT descriptor load.
     - implemented
   * - ``MOVZX`` / ``MOVSX``
     - ``0F B6/B7`` (zx); ``0F BE/BF`` (sx)
     - **NP**
     - ``K_EXT`` zero/sign-extend (32b mem loads fast-pathed in ``S_PIPE`` under ``VEN_FAST_MEM_EXT``; always NP).
     - implemented (NP)
   * - ``XCHG``
     - ``86 /r``; ``87 /r``; ``90+rd``
     - **NP**
     - Swap (``K_XCHG``; reg forms fast-pathed NP under ``VEN_FAST_XCHG_R``, mem forms locked RMW).
     - implemented (NP)
   * - ``NOP``
     - ``90`` (no 66h)
     - UV
     - Zero side-effect 1-byte op; fast-pathed, pairs in either slot with anything.
     - implemented
   * - ``LEA r, m``
     - ``8D /r``
     - UV
     - AGU writes effective address to dst with no memory access or flags; AGI-aware.
     - implemented
   * - ``LAHF`` / ``SAHF``
     - ``9F``; ``9E``
     - **NP**
     - Dedicated flags↔AH transfer (``K_STKMISC``); slow FSM, no memory.
     - implemented (slow FSM, NP)
   * - ``CBW/CWDE`` · ``CWD/CDQ``
     - ``98``; ``99``
     - **NP**
     - Accumulator sign-extend convert (``K_CONV``); slow FSM; no memory.
     - implemented (slow FSM, NP)
   * - ``XLAT`` / ``XLATB``
     - ``D7``
     - **NP**
     - Table-lookup byte load ``AL <- [seg:(E)BX + zero_ext(AL)]`` (``d_xlat``); slow FSM.
     - implemented (slow FSM, NP)
   * - Segment-override prefixes
     - ``2E 36 3E 26 64 65``
     - PU/NP
     - Prefix machine redirects the next memory ref's segment; prefixed op stays on slow FSM.
     - implemented (prefix)
   * - Operand/address-size prefixes
     - ``66``; ``67``
     - PU/NP
     - Prefix machine folds size into ``eff_opsize``/``eff_addr`` + length; prefixed op on slow FSM.
     - implemented (prefix)

MOV register and immediate forms (``88/89``, ``8A/8B``, ``B0-BF``)
    Copies a value with no flag effect: ``alu_op = ALU_MOV`` returns the source
    operand straight through the ALU. The **register-form** ``89`` (store
    reg→reg, ``mod==11``) and ``8B`` (load reg←reg) are fast-pathed **UV** —
    D2 reads the source GPR, EX passes it through the U or V ALU, WB writes the
    destination, single-cycle with full bypass and no flags. ``B8+r`` (imm32)
    is the only fast-pathed *load-immediate*: it takes the literal straight to
    WB and, reading no operand, is never an AGI source. Sub-32-bit destinations
    use ``reg_merge`` to preserve the unwritten bytes (high-8 ``AH..BH`` via
    ``d_dst_high8``/``d_src_high8``). All byte (``88``/``8A``/``B0-B7``),
    16-bit, and memory-destination forms decode only on the slow FSM (``K_ALU``
    / ``S_STORE``) and serialize. ``MOV r/m,imm`` (``C6``/``C7``) has no
    fast-path arm at all — its (often disp+imm) encoding is exactly what the
    pairing checker excludes — so it is slow-FSM-only.

MOV r, r/m as a load (``8B``, ``mod==00``)
    The register-base **load** sub-form is a real L1 D-cache access. ``decode.sv``
    sets ``is_load=1``, ``base=rm``, ``addr_mask=onehot(rm)``; D2's AGU forms the
    address from ``gpr[base]``, EX issues the load, WB writes the destination,
    and the 2-way LRU hit/miss state machine *defers* a miss penalty
    (``P5_DMISS``, plus ``P5_MISALIGN`` for a split) to the next instruction.
    Because a V-slot load is forbidden by the conservative ``issue_uv`` checker
    (``v.is_load`` ⇒ no pair), this load is **UV only when leading** a pair (a
    U-member load); it cannot fill V. **AGI:** if ``base`` was written the
    immediately-preceding clock, ``pipe_agi`` fires a 1-cycle stall. Any disp /
    SIB load (and the byte ``8A``) goes to the slow FSM.

MOV moffs (``A0-A3``) and the Erratum-59 model
    Absolute-displacement ``MOV`` between ``(e)AX`` and the memory at a 32-bit
    moffs (no ModR/M — the 4-byte displacement *is* the EA). Functional
    execution is **slow-FSM only** (``A0``/``A1`` load ``AL``/``eAX``;
    ``A2``/``A3`` store them). The fast-path decoder recognises ``A2``/``A3``
    *only in cycle mode* (``is_moffs``, reads ``EAX``) purely to **model** the
    retire/pairing and **Erratum 59**: with ``errata_en[ERR_MOFFS]`` set, a
    moffs store fails to pair when the following (V) instruction references
    ``EAX`` — a false ``EAX`` dependency the modeled P5 instruction unit injects
    (the ``moffs_falsedep`` check suppresses pairing). With errata off the core
    pairs them normally.

MOV to/from segment registers (``8C``, ``8E``)
    **NP** — AP-500 excludes seg-register ``MOV`` from the UV data-MOV class. A
    selector access is a microcoded **system** datapath, not the simple ALU.
    ``8C`` (``SYS_MOVSREG_FROM``) writes the 16-bit selector of ``Sreg`` (zero-
    extended for a 32-bit register destination, or 16-bit for memory); ``8E``
    (``SYS_MOVSREG_TO`` / ``S_SEGLD``) loads ``Sreg`` from register or memory
    (real/V86 mode: ``base = sel << 4``; protected mode: full GDT/LDT descriptor
    fetch, type/DPL/presence validation, ``#GP``/``#SS``/``#NP`` fault delivery,
    and ``MOV SS`` interrupt-shadow arming; ``MOV CS`` raises ``#UD``).

MOVZX / MOVSX (``0F B6/B7/BE/BF``)
    **NP** — AP-500 lists these as not-pairable (``0F``-prefixed). They load
    ``r/m8`` or ``r/m16`` into a 16/32-bit register, zero-extended (``B6``/``B7``)
    or sign-extended (``BE``/``BF``), with no flag changes. On the zero-define
    baseline they run on the slow FSM (``K_EXT``); under ``VEN_FAST_MEM_EXT``
    (``experimental/uv-fast-ipc-apr``), unprefixed 32-bit memory forms up to 7
    bytes execute directly in ``S_PIPE`` as single-issue ``NP`` loads.

XCHG / NOP (``86/87``, ``90+r``, ``90``)
    ``XCHG`` is **NP**: a read-modify-write *swap* (two register/memory writes,
    an implicit ``LOCK`` on memory forms), not a simple single-write ALU op, so
    it runs on the slow FSM (``K_XCHG``) — reg-form cross-writes both GPRs, mem-
    form does a locked load+store. ``NOP`` (``90`` with no ``0x66``) is the
    exception: it is **UV**, ``is_nop=1``, fast-pathed, and writes *nothing* (no
    register, memory, or flag), so it pairs trivially in either slot; being
    1-byte it also satisfies the I-cache-split pairing exception.

LEA (``8D``)
    **UV** — ``LEA`` computes an effective address in the AGU and writes it to a
    register *without* a memory access or flag write, so it slots cleanly into
    U or V. Only the simplest ``[base]`` form (``mod==00``, ``rm`` not
    ``100``/``101``) is fast-pathed: ``is_lea``, ``base=rm``,
    ``addr_mask=onehot(rm)``, and the U/V commit writes ``gpr[dst] <= gpr[base]``
    directly (EA == base value), single-cycle with no memory port used.
    **AGI:** ``addr_mask`` drives ``pipe_agi``, so an ``LEA`` whose base was
    written the prior clock takes the 1-cycle AGI stall (it consumes the AGU).
    Full SIB/disp/index ``LEA`` runs on the slow FSM (``gpr[dst] <= q_ea``).

LAHF / SAHF and CBW/CWDE / CWD/CDQ (``9F/9E``, ``98/99``)
    All **NP**. ``LAHF`` copies ``EFLAGS[7:0]`` into ``AH``; ``SAHF`` writes the
    five status flags back from ``AH`` (``K_STKMISC``, no memory). ``98``
    sign-extends ``AL→AX`` or ``AX→EAX`` (CWDE); ``99`` sign-extends ``AX→DX:AX``
    (CWD) or ``EAX→EDX:EAX`` (CDQ) (``K_CONV``). All are microcoded converts /
    flag transfers on the slow FSM, serializing.

XLAT (``D7``)
    **NP** — table-lookup byte load ``AL <- [seg:(E)BX + zero_ext(AL)]``
    (honoring ``eff_addr`` for ``BX`` vs. ``EBX`` and optional segment override
    prefixes, defaulting to ``DS``), executed as a single-byte load on the slow
    FSM (``d_xlat``) with ``EAX[31:8]`` and flags preserved.

Prefixes (segment-override ``2E/36/3E/26/64/65``; ``66``/``67``)
    A prefix is **PU** on the slow path (AP-500 §5.6.2.3 makes a prefixed
    instruction U-only-pairable) but **effectively NP** in *this* RTL, because
    the fast-path decoder only recognises *unprefixed* opcodes — so any
    prefixed instruction misses the fast path and serializes. The segment
    overrides record ``d_pfx_seg_en``/``d_pfx_seg_idx`` and redirect the next
    memory reference's segment in the AGU. ``0x66``/``0x67`` toggle operand /
    address size (with the real-mode ``def16`` inversion, so ``0x66`` selects
    32-bit there), feeding ``d_w`` and the length functions across every decode
    arm; they compute nothing themselves but the instruction they prefix then
    executes on the slow FSM at the chosen width.


.. _stack:

STACK — push, pop, and frame management
=======================================

The stack group exercises the store/load AGU with the implicit ``ESP``
register. A subtlety threads the whole group: the decoder *masks* ``ESP`` *out*
of the reads/writes bitmasks (``_onehot`` returns 0 for ``R_ESP``), so a
``push/push`` or ``push/call`` sequence never trips a false ``ESP`` RAW/WAW —
the AP-500 §5.6.4 special-pair rule. Consequently ``PUSH``/``POP`` of a register
or immediate are **UV by class** (executed on the slow FSM in the zero-define
baseline and fast-pathed in ``S_PIPE`` in the deployed ``c0e3fe43`` profile).
The memory-form, multi-register, frame, and flags/segment forms are genuinely
**NP** / microcoded.

.. list-table::
   :header-rows: 1
   :widths: 24 22 14 28 12

   * - Mnemonic
     - Encoding
     - U/V class
     - Datapath usage
     - Status
   * - ``PUSH r16/r32``
     - ``50+rd`` (66h → r16)
     - UV
     - Pre-decrement ESP store; SS-based AGU (``S_PIPE`` fast-path in ``c0e3fe43``, slow FSM baseline).
     - implemented
   * - ``POP r16/r32``
     - ``58+rd`` (66h → r16)
     - UV
     - Load from [SS:ESP] then ESP += w (``S_PIPE`` fast-path in ``c0e3fe43``, slow FSM baseline).
     - implemented
   * - ``PUSH imm``
     - ``68 id``; ``6A ib`` (sign-ext)
     - UV
     - Pre-decrement ESP store of immediate (``S_PIPE`` fast-path in ``c0e3fe43``, slow FSM baseline).
     - implemented
   * - ``PUSH r/m32``
     - ``FF /6``
     - **NP**
     - Two-access op (operand load + stack store); slow FSM, issues alone.
     - implemented (slow FSM, NP)
   * - ``POP r/m32``
     - ``8F /0``
     - **NP**
     - Stack load + store-to-EA (two memory accesses); slow FSM, issues alone.
     - implemented (slow FSM, NP)
   * - ``PUSHA / PUSHAD``
     - ``60``
     - **NP**
     - 8-beat micro-sequence (``S_USEQ``) off the latched original ESP; serializes.
     - implemented (microcoded)
   * - ``POPA / POPAD``
     - ``61``
     - **NP**
     - 8-beat ascending load micro-sequence (``S_USEQ``), ESP slot skipped; serializes.
     - implemented (microcoded)
   * - ``PUSHF / PUSHFD``
     - ``9C``
     - **NP**
     - Stores EFLAGS as the datum (serializing implicit source); slow-FSM single store.
     - implemented (slow FSM, NP)
   * - ``POPF / POPFD``
     - ``9D``
     - **NP**
     - Masked EFLAGS rewrite (may set TF/IF/DF); slow-FSM load + flag write.
     - implemented (slow FSM, NP)
   * - ``LEAVE``
     - ``C9`` (66h → 16-bit)
     - **NP**
     - Fused ESP←EBP then POP EBP (EBP-based load); slow FSM, issues alone.
     - implemented (slow FSM, NP)
   * - ``ENTER imm16, imm8``
     - ``C8 iw ib``
     - **NP**
     - Frame build (push (E)BP, frame-ptr display copy, ``(E)SP -= imm16``); slow FSM.
     - implemented (slow FSM, NP)
   * - ``PUSH sreg`` (ES/CS/SS/DS/FS/GS)
     - ``06 0E 16 1E``; ``0F A0/A8``
     - **NP**
     - Segment-selector stack push (16/32-bit slot); slow FSM.
     - implemented (slow FSM, NP)
   * - ``POP sreg`` (ES/SS/DS/FS/GS)
     - ``07 17 1F``; ``0F A1/A9``
     - **NP**
     - Stack pop + real/PM segment descriptor reload (``S_SEGLD``; ``POP SS`` arms IRQ shadow).
     - implemented (slow FSM, NP)

PUSH / POP register and immediate (``50+r``, ``58+r``, ``68``/``6A``)
    ``PUSH`` pre-decrements ``ESP`` by the operand width then stores the source
    to ``[SS:ESP]``; ``POP`` loads from ``[SS:ESP]`` into the destination then
    post-increments ``ESP`` (a ``POP`` into ``ESP`` itself suppresses the
    ``+w``). ``PUSH imm`` stores the decode-latched immediate (``6A`` sign-
    extends its imm8). **Datapath:** the AGU forms the descending store address
    ``gpr[ESP] - w`` or the ascending load address ``gpr[ESP]`` with the ``SS``
    base applied, and ``ESP`` updates at WB. In the zero-define baseline they
    run on the slow FSM; in the deployed ``c0e3fe43`` P54C profile they execute
    on ``S_PIPE`` with ``ESP`` masked out of RAW/WAW contention per AP-500 §5.6.4.

PUSH / POP r/m (``FF /6``, ``8F /0``)
    Both **NP**. ``PUSH r/m32`` for a *memory* operand needs *two* memory
    accesses — load ``[EA]`` then store to ``[SS:ESP]`` — which exceeds the
    single-cycle template, so it serializes alone in U (the register form
    routes through the same NP slow path). ``POP r/m32`` likewise pops the
    stack word *and* stores it to a memory destination (load-from-stack +
    store-to-EA), a two-memory-access op. Both run multi-cycle on the slow FSM.

PUSHA / POPA (``60``, ``61``)
    **NP / microcoded.** ``PUSHA`` pushes all eight GPRs in order
    (``EAX,ECX,EDX,EBX,`` original ``ESP,EBP,ESI,EDI``) as 8 sequential stores
    over the ``S_USEQ`` micro-sequencer; the *original* ``ESP`` is latched into
    ``pusha_esp`` on entry so every descending address (and the pushed ``ESP``
    slot) is computed off the fixed value, and at step 7 it commits
    ``ESP <= original - 32``. ``POPA`` is the inverse: 8 ascending loads into
    ``EDI,ESI,EBP`` (skip ``ESP``), ``EBX,EDX,ECX,EAX``, then ``ESP += 32``. Each
    is ~8+ cycles gated on ``mem_ack`` and holds the in-order pipe for the whole
    run.

PUSHF / POPF (``9C``, ``9D``)
    Both **NP**. ``PUSHF`` reads the architectural ``EFLAGS`` as its store datum
    (a serializing implicit source — the V pipe has no ``EFLAGS`` forwarding for
    this) and writes it to ``[SS:ESP]-w``. ``POPF`` loads a word and writes it
    into ``EFLAGS`` under the user-mode writability mask
    (``0x00244DD5`` — ``CF|PF|AF|ZF|SF|TF|DF|OF|NT|AC|ID``; ``IF``/``IOPL``/
    ``VM``/``RF`` preserved, bit 1 forced 1), then ``ESP += w``. Because
    ``POPF`` can set ``TF``, the pipe carries the issue-time flags for the
    step-trap decision.

LEAVE / ENTER (``C9``, ``C8``)
    Both **NP**. ``LEAVE`` performs fused frame teardown — ``(E)SP <- (E)BP``
    then ``POP (E)BP`` (``SM_LEAVE``, 16- and 32-bit stack/operand-size aware).
    ``ENTER imm16, imm8`` builds a stack frame (pushes ``(E)BP``, handles
    nesting-level display copies when ``imm8 & 31 != 0``, sets ``(E)BP`` to the
    frame pointer, and subtracts ``imm16`` from ``(E)SP``) on the slow FSM.

PUSH / POP segment registers (``06/0E/16/1E``, ``07/17/1F``, ``0F A0/A1/A8/A9``)
    **NP** — ``PUSH ES/CS/SS/DS/FS/GS`` pushes the selector onto the stack at the
    effective operand width; ``POP ES/SS/DS/FS/GS`` pops a 16-bit selector and
    executes the full real/V86 or protected-mode ``S_SEGLD`` descriptor-reload
    and privilege/presence validation path (``POP SS`` also arms the 1-instruction
    interrupt shadow).

.. note::

   ``LAHF`` / ``SAHF`` (``9F``/``9E``) share the ``K_STKMISC`` micro-op group
   and decode path with the stack ops, but touch **no** memory and do **not**
   move ``ESP``. They are **NP** flag↔AH transfers (``LAHF: AH <- EFLAGS[7:0]``;
   ``SAHF`` rebuilds the five status flags from ``AH``), implemented on the slow
   FSM. They are documented in full under :ref:`data-mov`.


.. _shift-bit:

SHIFT-BIT — shifts, rotates, and bit operations
===============================================

The shift group is the home of the **PU** class. The immediate-count
``SHL``/``SHR``/``SAR`` *register* forms (``C1 /4-/7``) are fast-pathed but
**U-pipe only**: the shifter and its CF/OF latch live on the U-pipe EX datapath,
and the V ALU has neither, so a shift may *lead* a pair but never *fill* V. The
by-1 (``D0``/``D1``) and by-CL (``D2``/``D3``) forms, the rotates, the
double-precision ``SHLD``/``SHRD``, the bit-test family, ``BSF``/``BSR``,
``BSWAP``, and ``SETcc`` are all slow-FSM-only (and the 0F-prefixed ones are NP
by class), so they serialize.

.. list-table::
   :header-rows: 1
   :widths: 24 24 14 26 12

   * - Mnemonic
     - Encoding
     - U/V class
     - Datapath usage
     - Status
   * - ``SHL/SAL r/m, imm8``
     - ``C1 /4`` (``/6`` alias)
     - **PU**
     - Reg-form fast-pathed **U-only** single-cycle shifter; mem-form slow ``K_SHIFT`` RMW.
     - implemented
   * - ``SHR r/m, imm8``
     - ``C1 /5``
     - **PU**
     - Reg-form fast-pathed U-only; mem-form slow RMW.
     - implemented
   * - ``SAR r/m, imm8``
     - ``C1 /7``
     - **PU**
     - Reg-form fast-pathed U-only (sign-replicating ``>>>``); mem-form slow RMW.
     - implemented
   * - ``SHL/SHR/SAR/SAL r/m, 1``
     - ``D0 /4-/7``; ``D1 /4-/7``
     - PU (AP-500)
     - *Not* fast-pathed → slow ``K_SHIFT`` (``shift_one``); serializes (NP-effective).
     - implemented (slow FSM)
   * - ``SHL/SHR/SAR/SAL r/m, CL``
     - ``D2 /4-/7``; ``D3 /4-/7``
     - **NP**
     - Implicit CL read + variable latency; slow ``K_SHIFT``, issues alone.
     - implemented (slow FSM, NP)
   * - ``ROL / ROR r/m, count``
     - ``C0/C1 /0,/1``; ``D0-D3 /0,/1``
     - PU/NP (AP-500)
     - Intentionally **not** fast-pathed (richer OF); all forms slow ``K_SHIFT``.
     - implemented (slow FSM)
   * - ``RCL / RCR r/m, count``
     - ``C0/C1 /2,/3``; ``D0-D3 /2,/3``
     - PU/NP (AP-500)
     - Carry-through rotate; slow ``K_SHIFT``, seeds ``cfin=EFLAGS[0]``; serializes.
     - implemented (slow FSM)
   * - ``SHLD r/m, r, imm8/CL``
     - ``0F A4 /r ib``; ``0F A5 /r``
     - **NP**
     - Double-precision two-source shift; slow ``K_SHLDRD``; reg dst & mem RMW implemented.
     - implemented (NP)
   * - ``SHRD r/m, r, imm8/CL``
     - ``0F AC /r ib``; ``0F AD /r``
     - **NP**
     - Double-precision right; slow ``K_SHLDRD``; reg dst & mem RMW implemented.
     - implemented (NP)
   * - ``BT r/m, r/imm8``
     - ``0F A3 /r``; ``0F BA /4 ib``
     - **NP**
     - Bit test → CF, no write; slow ``K_BITTEST``; reg & signed bit-string mem load.
     - implemented (NP)
   * - ``BTS r/m, r/imm8``
     - ``0F AB /r``; ``0F BA /5 ib``
     - **NP**
     - Test-and-set; slow ``K_BITTEST`` (``cur | 1<<idx``); reg & signed bit-string mem RMW.
     - implemented (NP)
   * - ``BTR r/m, r/imm8``
     - ``0F B3 /r``; ``0F BA /6 ib``
     - **NP**
     - Test-and-reset; slow ``K_BITTEST`` (``cur & ~(1<<idx)``); reg & signed bit-string mem RMW.
     - implemented (NP)
   * - ``BTC r/m, r/imm8``
     - ``0F BB /r``; ``0F BA /7 ib``
     - **NP**
     - Test-and-complement; slow ``K_BITTEST`` (``cur ^ 1<<idx``); reg & signed bit-string mem RMW.
     - implemented (NP)
   * - ``BSF r, r/m``
     - ``0F BC /r``
     - **NP**
     - Forward bit-scan (priority encoder); slow ``K_BITSCAN``; reg/mem source.
     - implemented (slow FSM, NP)
   * - ``BSR r, r/m``
     - ``0F BD /r``
     - **NP**
     - Reverse bit-scan; slow ``K_BITSCAN``; reg/mem source.
     - implemented (slow FSM, NP)
   * - ``BSWAP r32``
     - ``0F C8+r``
     - **NP**
     - Byte-reverse permute, no flags; slow ``K_BSWAP``; issues alone.
     - implemented (slow FSM, NP)
   * - ``SETcc r/m8``
     - ``0F 90+cc``
     - **NP**
     - Condition → byte (``cond_true``); slow ``K_SETCC``; reg or mem dst, 16 conditions.
     - implemented (slow FSM, NP)

SHL / SHR / SAR by immediate (``C1 /4-/7``)
    Shift the operand by an immediate count (masked to 5 bits): ``SHL/SAL``
    zero-fills from the right, ``SHR`` zero-fills from the left, ``SAR``
    sign-replicates. CF is the last bit shifted out; SF/ZF/PF come from the
    result, AF=0, and OF (defined for the cnt==1 case) is
    ``MSB(shifted-by-cnt-1) XOR MSB(result)``. **Datapath / why PU:** the
    *register* form (``mod==11``) is fast-pathed — ``is_shift``,
    ``shrot=reg_f``, ``shimm=b2[4:0]`` — and flows ``PF→D1→D2(read dst)→EX→WB``
    in the **U pipe** in a single cycle, with ``shrot_result``/``shrot_cf``
    computing the value and CF and ``sbit`` giving OF, full bypass. It is
    **PU** because ``decode.sv`` sets ``pairs_first=1, pairs_second=0``: only the
    U pipe has the shifter and the CF/OF latch, so a shift can *lead* a pair but
    never *fill* V. ``count==0`` changes nothing. The memory form drops to the
    slow ``K_SHIFT`` load-modify-store RMW and serializes.

Shift by 1 and by CL (``D0/D1``, ``D2/D3``)
    AP-500 rates by-1 shifts the same **PU** as by-imm, but in this RTL the
    by-1 forms have **no fast-path arm** — they decode only on the slow
    ``K_SHIFT`` FSM (``shift_one`` → ``sh_cnt=1``), so they serialize
    (NP-effective) even though architecturally PU. The by-CL forms are genuinely
    **NP**: the count is an implicit ``CL`` read with variable latency, so
    AP-500 excludes them from PU; ``sh_cnt={0, gpr[ECX][4:0]}`` is read in EX and
    the op runs on the slow FSM, issuing alone (``cnt==0`` is a no-op).

ROL / ROR / RCL / RCR (``C0/C1``, ``D0-D3`` ``/0-/3``)
    Rotates affect **only CF and OF**. ``ROL``/``ROR`` rotate without fill bits;
    ``RCL``/``RCR`` rotate *through* the carry, seeding the per-bit loop with
    ``cfin=EFLAGS[0]`` (the architectural carry — the same reason a pairable
    rotate-through-carry would be U-only). Architecturally by-1/by-imm rotates
    are PU and by-CL rotates NP, but ``decode.sv`` **deliberately does not
    fast-path any rotate** (a comment notes the SHL/SHR/SAL/SAR group is
    fast-pathed but the rotates keep their richer OF semantics on the slow
    path). So *all* rotate forms here run on the slow ``K_SHIFT`` FSM and
    serialize.

SHLD / SHRD (``0F A4/A5``, ``0F AC/AD``)
    **NP** — double-precision shifts read *two* source registers plus a count
    and drive a wide multi-bit shifter. ``SHLD`` shifts ``dst`` left by ``cnt``
    filling from the top of ``src``; ``SHRD`` shifts right filling from the
    bottom. CF is the last bit shifted out of ``dst``; SF/ZF/PF from the result,
    AF=0. Implemented on the slow ``K_SHLDRD`` FSM for both **register
    destinations** and **memory read-modify-write** operands (``imm8`` and ``CL``
    counts).

BT / BTS / BTR / BTC (``0F A3``, ``0F AB/B3/BB``, ``0F BA /4-/7``)
    **NP** — ``0F``-prefixed bit test and bit read-modify-write. All copy the
    selected bit into CF and leave SF/ZF/PF/OF/AF unchanged; ``BTS``/``BTR``/
    ``BTC`` also set / reset / complement the selected bit. Both **register**
    and **memory** forms are implemented on ``K_BITTEST``: for register-indexed
    memory operands, ``decode_stages.sv`` adds the **signed word/dword bit-string
    byte displacement** (with 16-bit ``eff_addr`` wrap applied prior to segment
    relocation) so both ``S_LOAD`` and ``S_STORE`` translate and permission-check
    the exact target word/dword (essential for Windows 95 kernel bitmaps).

BSF / BSR / BSWAP (``0F BC``, ``0F BD``, ``0F C8+r``)
    All **NP**. ``BSF``/``BSR`` scan for the lowest / highest set bit of the
    source, writing its index to the destination and setting ZF iff the source
    is zero (destination unchanged then); this RTL also fills CF=OF=AF=0 and
    SF/PF from the source even though those are architecturally undefined. They
    run on the slow ``K_BITSCAN`` FSM (reg or mem source, 16/32-bit).
    ``BSWAP`` reverses the 4 bytes of a 32-bit register (endianness flip), no
    flags, on the slow ``K_BSWAP`` FSM.

SETcc (``0F 90+cc``)
    **NP** — a 0F-prefixed op that evaluates an EFLAGS condition into a byte.
    It writes 1 to the ``r/m8`` destination if the condition (``cc`` nibble vs.
    EFLAGS via the shared ``cond_true`` helper) holds, else 0; no flags
    affected. All 16 conditions are handled on the slow ``K_SETCC`` FSM, for
    both register (high-8-aware) and memory destinations.


.. _muldiv-bcd:

MULDIV-BCD — multiply / divide and BCD/ASCII adjust
===================================================

Every instruction in this group is **NP**. The multiplies and divides produce or
consume the implicit ``EDX:EAX`` double-width pair (no V-pipe writeback path)
and execute on the slow FSM — using ``ven_idiv.sv`` (multi-cycle restoring
radix-2 integer divider under ``+define+VEN_IDIV_ITER`` in ``c0e3fe43``, or
native ``/`` / ``%`` in the zero-define simulation baseline) with architectural
``#DE`` divide-error delivery. All six BCD and ASCII adjust instructions
(``AAA``, ``AAS``, ``AAM``, ``AAD``, ``DAA``, ``DAS``) are implemented in
``uv_common.sv`` / ``decode_stages.sv``.

.. list-table::
   :header-rows: 1
   :widths: 26 24 10 28 12

   * - Mnemonic
     - Encoding
     - U/V class
     - Datapath usage
     - Status
   * - ``MUL r/m8|16|32``
     - ``F6 /4``; ``F7 /4``
     - **NP**
     - Unsigned ``EDX:EAX = EAX * r/m``; native ``*`` in one ``S_EXEC`` arm; CF/OF from high half.
     - implemented (slow FSM)
   * - ``IMUL r/m8|16|32`` (1-op)
     - ``F6 /5``; ``F7 /5``
     - **NP**
     - Signed one-operand into ``EDX:EAX``; ``$signed*$signed``; CF/OF on significant high bits.
     - implemented (slow FSM)
   * - ``IMUL r, r/m`` (2-op)
     - ``0F AF /r``
     - **NP**
     - Signed, truncated to width into a single dest reg (``K_IMUL2``); high half discarded.
     - implemented (slow FSM)
   * - ``IMUL r, r/m, imm32`` (3-op)
     - ``69 /r id``
     - **NP**
     - Signed ``r/m * imm32``, low width to dest (``K_IMUL2``, ``imul_3op``).
     - implemented (slow FSM)
   * - ``IMUL r, r/m, imm8`` (3-op)
     - ``6B /r ib``
     - **NP**
     - Signed ``r/m * sign-ext(imm8)``, low width to dest (``K_IMUL2``).
     - implemented (slow FSM)
   * - ``DIV r/m8|16|32``
     - ``F6 /6``; ``F7 /6``
     - **NP**
     - Unsigned ``EDX:EAX / r/m`` → quotient EAX/AL, remainder EDX/AH (``ven_idiv.sv`` under ``VEN_IDIV_ITER``; ``#DE`` on 0/overflow).
     - implemented (NP)
   * - ``IDIV r/m8|16|32``
     - ``F6 /7``; ``F7 /7``
     - **NP**
     - Signed divide (``ven_idiv.sv`` under ``VEN_IDIV_ITER``; remainder takes dividend sign; ``#DE`` on 0/overflow).
     - implemented (NP)
   * - ``AAA``
     - ``37``
     - **NP**
     - Unpacked BCD adjust after add (``ALU_AAA`` on ``AL``/``AH``); slow FSM.
     - implemented (slow FSM)
   * - ``AAS``
     - ``3F``
     - **NP**
     - Unpacked BCD adjust after subtract (``ALU_AAS`` on ``AL``/``AH``); slow FSM.
     - implemented (slow FSM)
   * - ``AAM``
     - ``D4 ib``
     - **NP**
     - Unpacked BCD adjust after multiply by base ``imm8`` (``ALU_AAM``; ``#DE`` on base 0 in sys mode).
     - implemented (slow FSM)
   * - ``AAD``
     - ``D5 ib``
     - **NP**
     - Unpacked BCD pack before divide by base ``imm8`` (``ALU_AAD``); slow FSM.
     - implemented (slow FSM)
   * - ``DAA``
     - ``27``
     - **NP**
     - Packed decimal adjust after add on ``AL`` (``ALU_DAA``); slow FSM.
     - implemented (slow FSM)
   * - ``DAS``
     - ``2F``
     - **NP**
     - Packed decimal adjust after subtract on ``AL`` (``ALU_DAS``); slow FSM.
     - implemented (slow FSM)

MUL / IMUL one-operand (``F6/F7 /4``, ``F6/F7 /5``)
    Multiply the accumulator by ``r/m`` into the implicit double-width result:
    8-bit ``AX = AL * r/m8``, 16-bit ``DX:AX = AX * r/m16``, 32-bit
    ``EDX:EAX = EAX * r/m32``. ``MUL`` is unsigned, ``IMUL`` (one-operand)
    signed. CF=OF=1 iff the upper half of the product is significant (for
    ``IMUL``, iff the full product is not the sign-extension of its low half),
    else 0; SF/ZF/AF/PF are architecturally undefined but Ventium computes
    ZF/SF/PF from the low half and AF=0 (matching QEMU). **Datapath:** slow
    path, one combinational ``S_EXEC`` arm — the product is the native
    ``{32'd0,EAX}*{32'd0,src}`` (or ``$signed*$signed``), split into ``EDX``
    (high) and ``EAX`` (low) with partial-width upper bits preserved. The AGU /
    D2 forms a load address only for a memory operand. ``EDX:EAX`` is the
    implicit dest/source pair — no V-pipe path, no forwarding.

IMUL two- and three-operand (``0F AF``, ``69``, ``6B``)
    These write a **single destination register** (not ``EDX:EAX``) — the high
    half of the signed product is discarded. The two-operand form is
    ``dst = dst * r/m``; the three-operand forms are ``dst = r/m * imm32``
    (``69``) or ``dst = r/m * sign-ext(imm8)`` (``6B``). CF=OF=1 iff truncating
    to the operand width lost significant bits; SF/ZF/PF filled from the low
    result, AF=0. All decode as ``K_IMUL2`` on the slow FSM (the three-operand
    forms set ``imul_3op`` and latch the immediate at decode); ``$signed *
    $signed`` with the low half written back through ``reg_merge``. They are
    **NP** — ``0F AF`` is a two-byte op and ``69``/``6B`` are absent from the
    fast-path casez, so ``d.simple=0``.

DIV / IDIV (``F6/F7 /6``, ``F6/F7 /7``)
    Divide the implicit double-width dividend by ``r/m``: quotient → ``EAX``/
    ``AL`` (or ``AX``), remainder → ``EDX``/``AH`` (or ``DX``). ``DIV`` is
    unsigned, ``IDIV`` signed (remainder takes the dividend's sign), raising
    ``#DE`` (vector 0) in system mode on divide-by-zero or quotient overflow and
    leaving ``EFLAGS`` unchanged. **Datapath:** in the deployed ``c0e3fe43``
    hardware build (``+define+VEN_IDIV_ITER``), ``ven_idiv.sv`` executes an
    iterative restoring radix-2 divide; the zero-define unit-TB baseline uses
    behavioral ``/`` and ``%``. (The Pentium **radix-4 SRT divider** and FDIV
    erratum belong strictly to x87 ``FDIV``; see :doc:`../microarch/srt-divider`.)

BCD / ASCII adjusts (``AAA`` ``37``, ``AAS`` ``3F``, ``AAM`` ``D4``, ``AAD`` ``D5``, ``DAA`` ``27``, ``DAS`` ``2F``)
    All **NP** and implemented on the slow ``K_ALU`` FSM via ``uv_common.sv`` /
    ``ventium_alu_pkg.sv``: ``AAA``/``AAS`` adjust unpacked BCD in ``AL``/``AH``
    setting ``AF``/``CF``; ``DAA``/``DAS`` adjust packed BCD in ``AL``; and
    ``AAM``/``AAD`` unpack/pack ``AX`` using the ``imm8`` base byte (default
    ``0x0A``).


.. _control-flow:

CONTROL-FLOW — branches, calls, returns, loops, interrupts
==========================================================

This is the home of the **PV** class. The short conditional ``Jcc rel8``
(``70-7F``) and short unconditional ``JMP rel8`` (``EB``) are fast-pathed
**V-only**: a branch resolves and redirects in the V slot, so it can *fill* V
behind a leading flags-writer (the ``cmp;jcc`` / ``dec;jnz`` special pair) but
can never *lead* (a taken branch ends the issue window). Everything else — the
``rel32`` branches, indirect and far transfers, calls and returns, the loop
family, and the interrupt/return ops — runs on the slow FSM (or is undecoded),
so it is NP or NP-effective in this RTL.

.. list-table::
   :header-rows: 1
   :widths: 26 22 12 28 12

   * - Mnemonic
     - Encoding
     - U/V class
     - Datapath usage
     - Status
   * - ``Jcc rel8``
     - ``70..7F cb``
     - **PV**
     - Fast-path V-member; D1 BTB lookup + 2-bit predict; re-evaluates under forwarded U flags.
     - implemented
   * - ``Jcc rel32``
     - ``0F 80..8F cd``
     - NP (this RTL)
     - No fast-path 0F arm → slow FSM; functional taken/target, no BTB; serializes.
     - implemented (slow FSM)
   * - ``JMP rel8``
     - ``EB cb``
     - **PV**
     - Fast-path V-member, unconditionally taken; BTB-tracked; uncond mispredict = 3 bubbles.
     - implemented
   * - ``JMP rel32``
     - ``E9 cd``
     - NP (this RTL)
     - No fast-path E9 arm → slow FSM; functional, no BTB.
     - implemented (slow FSM)
   * - ``JMP r/m`` (indirect)
     - ``FF /4``
     - **NP**
     - Data-dependent target from reg/load (``CT_JMPIND``); slow FSM, V idle.
     - implemented (slow FSM)
   * - ``JMP ptr16:16/32`` (far)
     - ``EA cp``
     - **NP**
     - CS reload + GDT-descriptor microsequence (``SYS_LJMP``); system-mode only.
     - implemented (system mode)
   * - ``CALL rel32``
     - ``E8 cd``
     - NP (this RTL)
     - Pushes return addr (store) then redirects (``CT_CALLREL``); slow FSM.
     - implemented (slow FSM)
   * - ``CALL r/m`` (indirect)
     - ``FF /2``
     - **NP**
     - Push + data-dependent target (store + load) (``CT_CALLIND``); slow FSM.
     - implemented (slow FSM)
   * - ``CALL ptr16:16/32`` (far)
     - ``9A cp``; ``FF /3``
     - **NP**
     - Far call (real/V86 CS:IP push, PM code segment, 16/32b call gates & 32b TSS switch).
     - implemented (system mode)
   * - ``RET``
     - ``C3``
     - **NP**
     - Pops return IP (load) then redirects (``CT_RETN``, 4-entry RAS); slow/fast-retire.
     - implemented
   * - ``RET imm16``
     - ``C2 iw``
     - **NP**
     - RET plus ``ESP += imm16`` arg release (``CT_RETN_IMM``); slow FSM.
     - implemented (slow FSM)
   * - ``RETF`` / ``RETF imm16`` (far)
     - ``CB``; ``CA iw``
     - **NP**
     - Far return (``SYS_RETF``; real/V86 & same/cross-privilege PM return + stack switch).
     - implemented (system mode)
   * - ``LOOP rel8``
     - ``E2 cb``
     - **NP**
     - Dec (E)CX + conditional branch RMW; slow FSM; no flags written.
     - implemented (slow FSM)
   * - ``LOOPE/LOOPZ rel8``
     - ``E1 cb``
     - **NP**
     - ``LOOP`` ANDed with ZF==1; slow FSM.
     - implemented (slow FSM)
   * - ``LOOPNE/LOOPNZ rel8``
     - ``E0 cb``
     - **NP**
     - ``LOOP`` ANDed with ZF==0; slow FSM.
     - implemented (slow FSM)
   * - ``JCXZ / JECXZ rel8``
     - ``E3 cb``
     - **NP**
     - Tests the count register (GPR read, not flags) (``CT_JECXZ``); slow FSM.
     - implemented (slow FSM)
   * - ``INT3``
     - ``CC``
     - **NP**
     - IDT[3] trap microsequence (system mode); user mode HALTs.
     - implemented (system mode)
   * - ``INT n``
     - ``CD ib``
     - **NP**
     - IDT[n] trap with DPL≥CPL check (system); user mode INT 0x80 → HALT, others HALT.
     - implemented (system mode)
   * - ``INTO``
     - ``CE``
     - **NP**
     - Conditional #OF trap through IDT[4] (system); user mode HALTs.
     - implemented (system mode)
   * - ``IRET / IRETD``
     - ``CF``
     - **NP**
     - Pops EIP/CS/EFLAGS (``S_IRET``, system); user mode HALTs.
     - implemented (system mode)
   * - ``BOUND r, m``
     - ``62 /r``
     - **NP**
     - Signed two-word ``[lower, upper]`` bounds check; raises ``#BR`` (vector 5) out of range.
     - implemented (system mode)

Jcc rel8 — the PV branch (``70-7F``)
    Tests EFLAGS per the condition nibble (``cond_true`` against
    CF/PF/ZF/SF/OF) and, if true, sets ``EIP = next_eip + sign-ext(rel8)``;
    otherwise falls through. It reads no GPR, writes no register, consumes flags
    only. **Datapath / why PV:** the ``70-7F`` arm is fast-pathed and
    single-cycle — D1 decodes it as a conditional branch with the BTB looked up
    (predict-taken iff the 2-bit counter ≥ 2), and EX needs no ALU/AGU (the
    taken bit is just ``cond_true(cc, flags)``). When **paired into V** behind a
    flags-writer (``cmp``/``test``/``dec``/``sub``), it re-evaluates under U's
    *forwarded* result flags (``u_flags_eff → v_br_taken_eff``) — this is the P5
    ``cmp;jcc`` / ``add;jnz`` special pair. It is **PV** (``pairs_first=0,
    pairs_second=1``) because a taken branch redirects the fetch stream, so it
    must be the trailing member. On resolve, ``btb_update_taken`` saturates the
    counter; a conditional mispredict costs ``P5_MISPREDICT_V = 4`` V-pipe
    bubbles, a correct prediction 0.

Jcc rel32 (``0F 80-8F``) and JMP rel32 (``E9``)
    AP-500 classes the near ``rel32`` branch / direct JMP as PV like the short
    forms, but the Ventium fast path only whitelists the 1-byte ``70-7F`` / ``EB``
    encodings. The ``0F``-prefixed ``Jcc rel32`` and the 5-byte ``E9 JMP rel32``
    have no fast-path arm, so they fall to the slow FSM and **issue alone** — NP
    in *this* implementation. They are functionally correct (the taken decision
    is computed at decode from the live EFLAGS, and retire commits
    ``next_eip + rel``), but they do not update the BTB and are not part of the
    dual-issue cycle model.

JMP rel8 (``EB``) and indirect / far JMP (``FF /4``, ``EA``)
    ``JMP rel8`` is **PV** — like a ``Jcc`` but unconditionally taken
    (``br_cond=0, br_taken=1``); the BTB is warmed strongly-taken on first
    allocation, and an *unconditional* mispredict costs
    ``P5_MISPREDICT_UNCOND = 3`` bubbles regardless of pipe (distinct from the
    conditional V penalty of 4). ``JMP r/m`` (``FF /4``) is **NP**
    (``CT_JMPIND``): the target comes from a register read or a load, is
    data-dependent (so the BTB cannot usefully predict it), and runs on the slow
    FSM (memory form: ``S_LOAD`` the pointer, ``S_EXEC`` sets the new EIP).
    ``JMP ptr16:16/32`` (``EA``, ``SYS_LJMP``) is **NP** and *system-mode only*:
    it reloads CS, which in protected mode means fetching and validating an
    8-byte GDT descriptor — a long microcoded segment-load sequence used by the
    real→protected bootstrap.

CALL (``E8`` near direct, ``FF /2`` indirect, ``9A`` far)
    AP-500 makes near-direct ``CALL`` PV (it can fill V, the ``push;call``
    special pair), but Ventium implements ``CALL`` only on the slow FSM because
    it must **push the return address** (a memory store) before redirecting — so
    ``E8`` issues alone here (NP-effective): ``S_EXEC`` (store the ``next_eip``)
    → ``S_STORE`` (write ``[ESP-w]``, ``ESP -= w``, ``EIP <= next_eip + rel``).
    The 0x66 form truncates the target to 16 bits. ``CALL r/m`` (``FF /2``,
    ``CT_CALLIND``) is genuinely **NP** — it both pushes (store) *and* takes a
    data-dependent target (register read or load), two serialized memory
    micro-ops, with the AGU used twice. ``CALL ptr16:16/32`` (``9A`` and ``FF /3``)
    is **NP** and implemented in ``core_seg_ljmp.svh`` across real/V86 mode,
    protected-mode conforming/non-conforming code segments, 16/32-bit call gates
    (same- and cross-privilege with parameter copy ``S_CG_PRD``), and 32-bit TSS
    task switches (task gates and 16-bit TSS halt loudly; see ``docs/unsupported-isa.md``).

RET / RET imm16 / RETF (``C3``, ``C2``, ``CB``/``CA``)
    ``RET`` is **NP**: it pops the return IP from ``[ESP]`` and redirects
    (predicted by the 4-entry return-address stack in ``c0e3fe43``). ``RET imm16``
    adds ``imm16`` to ``ESP`` to release caller arguments. ``RETF``/``RETF imm16``
    (``CB``/``CA``, ``SYS_RETF``) pops ``CS:EIP`` and executes real/V86 or
    same-/outer-privilege protected-mode descriptor validation and stack
    restoration.

LOOP / LOOPE / LOOPNE / JCXZ (``E0-E3``)
    All **NP** — microcoded read-modify-write on ``(E)CX`` plus a conditional
    branch, not a simple ALU op, and not BTB-tracked. ``LOOP`` decrements the
    count register (writeback via NBA), zero-tests it to gate the redirect, and
    writes **no flags**. ``LOOPE``/``LOOPZ`` additionally requires ``ZF==1``,
    ``LOOPNE``/``LOOPNZ`` requires ``ZF==0`` (gated from EFLAGS in ``S_EXEC``).
    ``JCXZ``/``JECXZ`` (``E3``, ``CT_JECXZ``) is distinct — it tests the **count
    register** (a GPR read) for zero rather than EFLAGS, so unlike ``Jcc`` it is
    NP (not a simple flag-branch); it writes no flags and uses no ALU result.
    The ``0x67`` address-size prefix selects the 16-bit ``CX`` count path.

INT3 / INT n / INTO / IRET (``CC``, ``CD``, ``CE``, ``CF``)
    All **NP** / privileged. In **system mode** they vector through the IDT (gate
    fetch + exception-frame push), a long microsequence: ``INT3`` →
    ``S_INT_GATE`` (read the 8-byte IDT[3] gate) → ``S_INT_PUSH`` (push EFLAGS,
    CS, the *next* EIP for a TRAP) → redirect; ``INT n`` adds the gate
    ``DPL≥CPL`` check; ``INTO`` traps through IDT[4] only if ``OF`` is set (else a
    plain EIP advance); ``IRET`` is the inverse (``S_IRET`` pops EIP/CS/EFLAGS).
    In **user mode** there is no IDT, so ``INT3``/``INTO``/``IRET`` and most
    ``INT n`` HALT, with ``INT 0x80`` treated as the syscall-exit HALT — all
    preserving the M0-M6 user-gate bit-identity.

BOUND (``62 /r``)
    **NP** — reads a signed ``(lower, upper)`` pair from memory (16- or 32-bit)
    and compares the index register against ``lower <= reg <= upper``, raising
    ``#BR`` (vector 5) through the IDT in system mode on an out-of-bounds value
    (register ModR/M forms raise ``#UD``).


.. _string:

STRING — string primitives and REP prefixes
===========================================

Every string primitive is **NP** (never paired across U+V). Each ``REP``
element produces its own retirement event (hardware retirement counters on
``c0e3fe43`` likewise count ``REP`` elements). Direction follows ``DF``
(``EFLAGS[10]``): ``str_step = DF ? -w : +w``. In the **deployed c0e3fe43
P54C profile**, ``VEN_REP_STOS_STREAM`` and ``VEN_REP_MOVS_STREAM`` /
``_LOAD_FUSE`` / ``_CONT`` stream cacheable ``REP STOS`` (1 element/clock
steady state) and ``REP MOVS`` iterations without re-entering full decode,
while preserving exact page-crossing, segment-limit, and interrupt boundaries.
Port-I/O instructions (``IN``, ``OUT``, ``INS``, ``OUTS``) execute through the
``S_IO`` bus seam in system/SoC mode (with ``CPL <= IOPL`` and TSS I/O
permission bitmap checks).

.. list-table::
   :header-rows: 1
   :widths: 24 16 12 34 12

   * - Mnemonic
     - Encoding
     - U/V class
     - Datapath usage
     - Status
   * - ``MOVS`` (MOVSB)
     - ``A4``
     - **NP**
     - Copy DS:[ESI]→ES:[EDI], advance both per DF; ``S_LOAD → S_STORE``; REP via ECX.
     - implemented (slow FSM)
   * - ``MOVS`` (MOVSW/MOVSD)
     - ``A5``
     - **NP**
     - Word/dword MOVS (``w=2``/``4``); same microsequence, full-width bus beats.
     - implemented (slow FSM)
   * - ``STOS`` (STOSB)
     - ``AA``
     - **NP**
     - Store AL→ES:[EDI], advance EDI; 1-cyc/elem cacheable ``REP`` stream under ``VEN_REP_STOS_STREAM``.
     - implemented
   * - ``STOS`` (STOSW/STOSD)
     - ``AB``
     - **NP**
     - Store AX/EAX→ES:[EDI]; 1-cyc/elem cacheable ``REP`` stream under ``VEN_REP_STOS_STREAM``.
     - implemented
   * - ``LODS`` (LODSB)
     - ``AC``
     - **NP**
     - Load DS:[ESI]→AL (``reg_merge``, low byte), advance ESI; load-only.
     - implemented (slow FSM)
   * - ``LODS`` (LODSW/LODSD)
     - ``AD``
     - **NP**
     - Load DS:[ESI]→AX/EAX (width-correct merge); load-only.
     - implemented (slow FSM)
   * - ``SCAS`` (SCASB)
     - ``AE``
     - **NP**
     - ``AL - ES:[EDI]`` CMP (sets flags), advance EDI; REPE/REPNE ZF early-out.
     - implemented (slow FSM)
   * - ``SCAS`` (SCASW/SCASD)
     - ``AF``
     - **NP**
     - Width-correct CMP vs ES:[EDI]; REPE/REPNE early-out.
     - implemented (slow FSM)
   * - ``CMPS`` (CMPSB)
     - ``A6``
     - **NP**
     - ``DS:[ESI] - ES:[EDI]`` CMP; **two** loads (``S_LOAD`` + ``S_LOAD2``); REPE/REPNE.
     - implemented (slow FSM)
   * - ``CMPS`` (CMPSW/CMPSD)
     - ``A7``
     - **NP**
     - Width-correct two-load compare; REPE/REPNE early-out.
     - implemented (slow FSM)
   * - ``REP`` prefix
     - ``F3``
     - **NP**
     - Repeat MOVS/STOS/LODS ECX times (no ZF early-out); prefixed ``K_STR``.
     - implemented
   * - ``REPE / REPZ`` prefix
     - ``F3``
     - **NP**
     - Repeat SCAS/CMPS while ZF==1; stop on first non-equal element.
     - implemented
   * - ``REPNE / REPNZ`` prefix
     - ``F2``
     - **NP**
     - Repeat SCAS/CMPS while ZF==0; stop on first matching element.
     - implemented
   * - ``INS`` (INSB/W/D)
     - ``6C`` / ``6D``
     - **NP**
     - Port-I/O string read DX → ES:[(E)DI] (``S_INS`` + IOPL/TSS bitmap check in sys/SoC mode).
     - implemented (sys/SoC)
   * - ``OUTS`` (OUTSB/W/D)
     - ``6E`` / ``6F``
     - **NP**
     - Port-I/O string write DS:[(E)SI] → DX (``S_OUTS`` + IOPL/TSS bitmap check in sys/SoC mode).
     - implemented (sys/SoC)
   * - ``IN`` / ``OUT`` (port)
     - ``E4-E7`` ``EC-EF``
     - **NP**
     - Register port-I/O via ``S_IO`` (``imm8`` or ``DX`` port, IOPL/TSS bitmap check in sys/SoC mode).
     - implemented (sys/SoC)

MOVS (``A4``/``A5``)
    Copies one element from ``DS:[ESI]`` to ``ES:[EDI]`` then advances both
    pointers by ``±w`` per ``DF``; flags are unaffected. **Datapath:** per
    element the slow FSM runs ``S_DECODE → S_LOAD`` (read ``DS:[ESI]`` into
    ``mem_load_data``) ``→ S_EXEC`` (``str_wdata = mem_load_data``, ``ESI +=
    str_step``, ``EDI += str_step``; the pre-increment ``[EDI]`` is latched into
    ``str_store_addr`` because ``EDI`` updates via NBA the same cycle) ``→
    S_STORE`` (write ``ES:[EDI]``). With ``REP``, ``ECX`` is decremented and the
    run terminates at ``ECX==0`` (no ZF test for ``MOVS``); a leading ``REP``
    with ``ECX==0`` retires a single no-op advancing ``EIP``.

STOS / LODS (``AA``/``AB``, ``AC``/``AD``)
    ``STOS`` stores ``AL``/``AX``/``EAX`` to ``ES:[EDI]`` (no load — ``S_DECODE``
    goes straight to ``S_EXEC`` since ``d_mem_read=0``), advances ``EDI``, and
    with ``REP`` fills memory. ``LODS`` loads ``DS:[ESI]`` into ``AL``/``AX``/
    ``EAX`` via ``reg_merge`` (partial-register-correct — the low byte / word is
    merged, upper bytes preserved) and advances ``ESI`` (no store stage); ``REP
    LODS`` is legal but pointless (only the final element survives), and Ventium
    still iterates ``ECX`` times. Neither has a ZF early-out.

SCAS / CMPS (``AE``/``AF``, ``A6``/``A7``)
    Both are non-storing compares that set all six status flags via
    ``flags_next(ALU_CMP, ...)``. ``SCAS`` computes ``(AL/AX/EAX) - [ES:EDI]``
    (one load from ``ES:[EDI]``) and advances ``EDI``. ``CMPS`` computes
    ``[DS:ESI] - [ES:EDI]`` and is the only string op needing **two** loads —
    ``S_LOAD`` reads ``DS:[ESI]`` into ``mem_load_data``, then the CMPS-only
    ``S_LOAD2`` reads ``ES:[EDI]`` into ``mem_load_data2`` — before the compare,
    advancing **both** ``ESI`` and ``EDI``. With a ``REPE``/``REPNE`` prefix,
    after each compare ``last_iter = (ECX-1==0) || cmp_term`` where ``cmp_term``
    is ``REPE ? (ZF==0) : REPNE ? (ZF==1)`` — the ZF early-out is taken from this
    element's freshly computed flags before deciding to re-enter ``q_pc``. Two
    D-cache accesses per ``CMPS`` element (each can take a miss/misalign penalty
    in cycle mode).

REP / REPE / REPNE (``F3``, ``F3``, ``F2``)
    The prefix machine decodes ``F3 → pfx_rep=3`` (``q_rep``) and ``F2 →
    pfx_rep=2`` (``q_repne``). On the non-comparing primitives
    (``MOVS``/``STOS``/``LODS``) there is no early-out — the run terminates only
    when ``ECX`` reaches 0. On the comparing primitives (``SCAS``/``CMPS``),
    ``REPE`` stops when ``ZF==0`` and ``REPNE`` stops when ``ZF==1`` (in addition
    to ``ECX==0``). All are **NP** prefixed ``K_STR`` ops: ``ECX`` is decremented
    each element, a non-final element sets ``new_eip = q_pc`` to re-enter the
    same instruction, and the op holds the in-order pipe (issues alone) for the
    whole run.

INS / OUTS and IN / OUT (``6C-6F``, ``E4-E7``, ``EC-EF``)
    All **NP** I/O instructions. In system/SoC mode (``soc_en || cosim_en``),
    ``IN``/``OUT`` (``imm8`` and ``DX`` forms) and ``INS``/``OUTS`` (including
    ``REP`` string transfers) enforce protected/V86 ``CPL <= IOPL`` and 32-bit
    TSS I/O permission bitmap checks before driving the ``io_*`` port seam in
    ``S_IO`` (after draining any posted DDR4 writes on hardware). In bare
    user-mode unit tests without an I/O bus, non-exit ports halt cleanly.


.. _system:

SYSTEM — control/debug registers, descriptor tables, and serializing ops
========================================================================

The system group is almost entirely **NP**: control- and debug-register
moves, descriptor-table loads, flag-bit mutators, ``HLT``, and the serializing
``CPUID``/``RDTSC``/MSR ops are all microcoded or privileged, never whitelisted
by the fast-path decoder, and serialize on the slow FSM. The lone exception is
``NOP`` (``90``), the canonical zero-side-effect **UV** op. Many forms are
gated on ``sys_mode`` (in user mode they stay ``d_unknown`` → HALT, preserving
the pre-system bit-identity), and several are deferred (undecoded → HALT).

.. list-table::
   :header-rows: 1
   :widths: 24 18 12 32 12

   * - Mnemonic
     - Encoding
     - U/V class
     - Datapath usage
     - Status
   * - ``MOV r32, CRn``
     - ``0F 20 /r``
     - **NP**
     - Control-register read (``SYS_MOVCR_FROM``); one ``S_EXEC`` mux, no flags.
     - implemented
   * - ``MOV CRn, r32``
     - ``0F 22 /r``
     - **NP**
     - CR write (``SYS_MOVCR_TO``); CR3 write flushes all I/D TLBs; serializing.
     - implemented
   * - ``MOV r32, DRn``
     - ``0F 21 /r``
     - **NP**
     - Debug-register read (``SYS_MOVDR_FROM``); pre-execute CR4.DE #UD gating; sys-mode.
     - implemented (sys mode)
   * - ``MOV DRn, r32``
     - ``0F 23 /r``
     - **NP**
     - DR write (``SYS_MOVDR_TO``); reserved-1 forcing on DR6/DR7; sys-mode.
     - implemented (sys mode)
   * - ``LGDT`` / ``LIDT``
     - ``0F 01 /2``; ``0F 01 /3``
     - **NP**
     - 6-byte pseudo-descriptor read (``S_LGDT``, two beats); loads GDTR/IDTR.
     - implemented
   * - ``SGDT`` / ``SIDT``
     - ``0F 01 /0``; ``0F 01 /1``
     - **NP**
     - 6-byte pseudo-descriptor store (``S_SGDT``, two translated/fragmented beats).
     - implemented
   * - ``SMSW`` / ``INVLPG`` / ``LMSW``
     - ``0F 01 /4``; ``/7``; ``/6``
     - **NP**
     - ``SMSW r16/32`` & ``INVLPG m`` (full TLB flush) implemented; ``LMSW`` / ``SMSW m16`` partial/deferred.
     - partial
   * - ``LTR r/m16``
     - ``0F 00 /3``
     - **NP**
     - TSS-descriptor read microsequence (``S_LTR``); reg-form, sys-mode.
     - implemented (sys mode, reg)
   * - ``STR r/m16``
     - ``0F 00 /1``
     - **NP**
     - TR-selector store (``SYS_STR``); reg-form, sys-mode.
     - implemented (sys mode, reg)
   * - ``LLDT`` / ``SLDT``
     - ``0F 00 /2``; ``0F 00 /0``
     - **NP**
     - LDTR load (``SYS_LLDT``) & selector store (``SYS_SLDT``); reg-form, sys-mode.
     - implemented (sys mode, reg)
   * - ``CLTS``
     - ``0F 06``
     - **NP**
     - CPL0 clear of ``CR0.TS`` via ``SYS_MOVCR_TO`` (for ``#NM`` lazy-FPU handlers); sys-mode.
     - implemented (sys mode)
   * - ``LAR`` / ``LSL``
     - ``0F 02``; ``0F 03``
     - **NP**
     - Descriptor access-rights / segment-limit query setting ZF on valid visible selector; sys-mode.
     - implemented (sys mode)
   * - ``VERR`` / ``VERW``
     - ``0F 00 /4``; ``0F 00 /5``
     - **NP**
     - Segment read/write accessibility verify → ZF (reg & mem forms); sys-mode.
     - implemented (sys mode)
   * - ``ARPL r/m16, r16``
     - ``63 /r``
     - **NP**
     - RPL adjust — unimplemented; ``d_unknown`` → loud HALT.
     - unimplemented (HALTs)
   * - ``LDS`` / ``LES``
     - ``C5 /r``; ``C4 /r``
     - **NP**
     - Far-pointer load into DS/ES; m16:16 and m16:32 memory forms. Protected
       loads share the validated, atomic descriptor-load transaction.
     - implemented
   * - ``LSS`` / ``LFS`` / ``LGS``
     - ``0F B2/B4/B5``
     - **NP**
     - Far-pointer load into SS/FS/GS; m16:16 and m16:32 memory forms in
       real/V86/protected modes. Register encodings remain invalid.
     - implemented
   * - ``CLI`` / ``STI``
     - ``FA``; ``FB``
     - **NP**
     - Direct EFLAGS.IF clear/set (``flags_we=0``); one ``S_EXEC``; serializes.
     - implemented
   * - ``CLD`` / ``STD``
     - ``FC``; ``FD``
     - **NP**
     - Direct EFLAGS.DF clear/set; one ``S_EXEC``; serializes.
     - implemented
   * - ``CLC`` / ``STC`` / ``CMC``
     - ``F8`` ``F9`` ``F5``
     - **NP**
     - Direct EFLAGS.CF clear/set/complement (V has no CF forwarding); serializes.
     - implemented
   * - ``HLT``
     - ``F4``
     - **NP**
     - Clean stop → ``S_HALT`` (one cycle-mode retire); ends retirement.
     - implemented
   * - ``NOP``
     - ``90``
     - UV
     - Zero-side-effect 1-byte op; fast-pathed; pairs in either slot.
     - implemented
   * - ``WAIT / FWAIT``
     - ``9B``
     - **NP**
     - x87 synchronization & pending-``#MF`` exception check barrier.
     - implemented
   * - ``CPUID``
     - ``0F A2``
     - **NP**
     - Pentium Family 5 leaf dispatch into ``EAX/EBX/ECX/EDX`` (``K_CPUID`` in sys/SoC mode).
     - implemented (sys/SoC)
   * - ``RDTSC``
     - ``0F 31``
     - **NP**
     - Reads 64-bit cycle counter ``tsc`` into ``EDX:EAX`` (``K_RDTSC`` in sys/SoC mode).
     - implemented (sys/SoC)
   * - ``INVD`` / ``WBINVD``
     - ``0F 08``; ``0F 09``
     - **NP**
     - CPL0 cache invalidation / write-back flush (``d_cacheinv`` in sys/SoC mode).
     - implemented (sys/SoC)
   * - ``CMPXCHG`` / ``CMPXCHG8B``
     - ``0F B0/B1``; ``0F C7 /1``
     - **NP**
     - Atomic compare-and-swap (8/16/32b & 64b ``K_CX8B``; locked reg ``0F C7 /1`` models F00F Erratum 81).
     - implemented
   * - ``RDMSR`` / ``WRMSR``
     - ``0F 32``; ``0F 30``
     - **NP**
     - MSR read/write — unimplemented (no MSR file); ``d_unknown`` → loud HALT.
     - unimplemented (HALTs)
   * - ``RSM``
     - ``0F AA``
     - **NP**
     - SMRAM state restore microsequence (``S_RSM``); sys-mode + SMM only.
     - implemented (SMM)
   * - ``UD2``
     - ``0F 0B``
     - **NP**
     - Guaranteed #UD via IDT (system); user mode ``d_unknown`` → HALT.
     - implemented (system mode)
   * - ``LOCK`` prefix
     - ``F0``
     - PU/NP
     - Atomic-RMW prefix (``pfx_lock``); F00F Erratum-81 hang on locked CMPXCHG8B.
     - implemented (prefix)

MOV to/from CRn (``0F 20``, ``0F 22``)
    **NP** — a control-register access is a microcoded slow-FSM op outside the
    U/V ALU datapath, with no fast-path uop, so it can never pair. ``0F 20``
    reads ``CRn`` (``CR0``/``CR2``/``CR3``/``CR4`` selected by ModR/M.reg) into a
    GPR via a single ``S_EXEC`` mux; ``0F 22`` writes ``CRn`` from a GPR. A CR3
    write additionally **invalidates all ITLB/DTLB entries** (per MOV-CR3
    semantics). Neither writes flags (``flags_we=0``). Architecturally a CR0.PE /
    CR0.PG write is a serializing mode-change event.

MOV to/from DRn (``0F 21``, ``0F 23``)
    **NP**, ``sys_mode``-gated (in user mode ``0F 21``/``0F 23`` stay
    ``d_unknown`` → HALT, byte-identical to pre-M2S). ``0F 21`` reads debug
    register ``DRn`` (``DR0-DR3`` breakpoint addresses, ``DR6`` status, ``DR7``
    control; ``DR4``/``DR5`` alias ``DR6``/``DR7`` when ``CR4.DE=0``) into a GPR;
    ``0F 23`` writes them (forcing the reserved-1 masks
    ``DR6_FIXED_1=0xFFFF0FF0`` and ``DR7_FIXED_1=0x400`` so read-back is
    deterministic). Both carry a pre-execute fault path: with ``CR4.DE=1`` an
    access to ``DR4``/``DR5`` diverts to ``#UD`` delivery before any access; the
    ``DR7.GD`` ``#DB`` is decoded but gated off (``DBG_GD_ENABLE=0``) to match the
    QEMU golden.

LGDT / LIDT / SGDT / SIDT / SMSW / INVLPG (``0F 01`` group)
    ``LGDT`` (``/2``) and ``LIDT`` (``/3``) read a 6-byte pseudo-descriptor
    across two beats in ``S_LGDT`` (masking the base to 24 bits under 16-bit
    operand size). ``SGDT`` (``/0``) and ``SIDT`` (``/1``) store the 6-byte
    pseudo-descriptor through preflighted/fragmented stores in ``S_SGDT``.
    ``SMSW r16/r32`` (``/4`` reg) reads ``CR0`` via ``SYS_MOVCR_FROM``, and
    ``INVLPG m`` (``/7``) flushes I/D TLBs alongside ``MOV CR3``.

LTR / STR / LLDT / SLDT / VERR / VERW (``0F 00`` group)
    All ``sys_mode`` protected-mode operations: ``LTR`` (``/3``) and ``LLDT``
    (``/2``) read GDT TSS/LDT descriptors; ``STR`` (``/1``) and ``SLDT`` (``/0``)
    store the zero-extended ``TR``/``LDTR`` selector to a register; and ``VERR``
    (``/4``) / ``VERW`` (``/5``) test segment read/write accessibility (register
    or memory selector) into ``EFLAGS.ZF``.

Protection ops and far-pointer segment loads
    ``CLTS`` (``0F 06``) clears ``CR0.TS`` at CPL0; ``LAR`` (``0F 02``) and
    ``LSL`` (``0F 03``) query GDT/LDT descriptor access rights and scaled byte
    limits into the destination GPR while setting ``ZF=1`` on valid visible
    selectors (``ARPL`` ``63`` remains unimplemented and halts loudly). The
    **NP** far-pointer loads ``LDS``/``LES``/``LSS``/``LFS``/``LGS`` are
    implemented for every legal m16:16/m16:32 form, committing GPR + descriptor
    atomically after ``S_SEGLD`` validation (register forms raise ``#UD``).

Flag-bit mutators (``CLI``/``STI`` ``FA/FB``, ``CLD``/``STD`` ``FC/FD``, ``CLC``/``STC``/``CMC`` ``F8/F9/F5``)
    All **NP** single-byte ops decoded by the slow FSM (never ``simple``, so
    ``fp_can_pair`` fails on ``!u.simple``). Each directly mutates one EFLAGS bit
    in a single ``S_EXEC`` retire with ``flags_we=0`` (a direct write, not via
    the ALU flag path) and no AGU/ALU/register write: ``CLI``/``STI`` clear/set
    ``IF`` (``±0x200``), ``CLD``/``STD`` clear/set ``DF`` (``±0x400``),
    ``CLC``/``STC``/``CMC`` clear/set/complement ``CF`` (``±1``/``^1``). The CF
    ops are U-only for the same datapath reason as ``ADC``/``SBB`` — the V ALU
    path has no CF forwarding.

HLT and NOP (``F4``, ``90``)
    ``HLT`` is **NP**: it stops instruction retirement entirely — it cannot pair
    because no following instruction issues. ``S_DECODE`` routes ``d_halt`` to
    ``S_HALT``; in cycle mode it first emits **one** retire record (so the trace
    matches the oracle's terminating-instruction record) then halts. This is a
    *clean* stop, distinct from the loud no-retire ``d_unknown`` HALT.
    ``NOP`` (``90`` with no ``0x66``) is the one **UV** op in this category:
    fast-pathed with empty reads/writes masks, it flows through PF/D1/D2/EX/WB as
    a 1-cycle uop, pairs in U *or* V with any partner (no possible
    RAW/WAW/disp+imm conflict), and retires at up to 2/clock. It is implemented
    in both the fast path and the slow FSM.

Serializing / privileged ops (``WAIT`` ``9B``, ``CPUID`` ``0F A2``, ``RDTSC`` ``0F 31``, ``INVD``/``WBINVD`` ``0F 08/09``, ``RDMSR``/``WRMSR`` ``0F 32/30``)
    All **NP**. Standalone ``WAIT``/``FWAIT`` (``0x9B``) drains asynchronous x87
    work and checks pending unmasked ``#MF`` exceptions (enabling wait-prefixed
    ``FINIT``, ``FCLEX``, ``FSTCW``, ``FSTSW``, ``FSTENV``, and ``FSAVE``). In
    system/SoC mode, ``CPUID`` (``0F A2``) returns Pentium Family 5 feature
    leaves, ``RDTSC`` (``0F 31``) reads the 64-bit cycle counter into
    ``EDX:EAX``, and CPL0 ``INVD``/``WBINVD`` flush caches; ``RDMSR``/``WRMSR``
    (``0F 32``/``0F 30``) remain unimplemented and halt loudly.

RSM / UD2 (``0F AA``, ``0F 0B``)
    ``RSM`` is **NP** and heavily microcoded: it leaves SMM and restores the
    *entire* CPU state (CR0/CR3/CR4/CR2, EFLAGS, EIP, all GPRs, all segment
    selectors and hidden descriptors, GDTR/IDTR, SMBASE) from the SMRAM
    save-state map in the long ``S_RSM`` microsequence (many bus beats into
    holding registers, then a single-clock commit), gated on
    ``sys_mode && smm_active`` (outside SMM → ``d_unknown`` → HALT). ``UD2``
    (``0F 0B``) is the guaranteed-invalid opcode delivering ``#UD`` (vector 6, a
    fault) through the IDT in system mode; in user mode there is no IDT, so it is
    a HALT (byte-identical to pre-M2S).

LOCK prefix (``F0``)
    AP-500 §5.6.2.3 makes a prefixed instruction U-only (**PU**: may lead a
    pair, never fill V), but in Ventium the fast path decodes only *unprefixed*
    forms, so any ``LOCK``-prefixed instruction has ``simple=0`` and serializes
    outright (NP-effective). A locked atomic RMW must hold the U pipe through its
    memory access. As a prefix it only adjusts ``pfx_len``/``m_idx``; the
    instruction it guards runs on the slow FSM. The one special architectural
    model is **Erratum 81 (F00F)**: while valid memory-form ``CMPXCHG8B m64``
    (``0F C7 /1``, ``mod != 11``) executes normally on ``K_CX8B`` (64-bit
    ``EDX:EAX`` compare / ``ECX:EBX`` conditional store), an invalid
    register-destination ``LOCK CMPXCHG8B`` (``mod == 11``) sets ``d_f00f`` and,
    with ``errata_en[ERR_F00F]`` and ``pfx_lock``, enters the documented bus-lock
    hang ``S_F00F_HANG``.


.. _x87-fpu:

X87-FPU — floating-point stack
==============================

In the **deployed c0e3fe43 hardware profile** (``+define+VEN_FP_SHARED``;
see :doc:`/microarch/fp-commit-pipeline` and :doc:`/microarch/srt-divider`), the
**shared pipelined 80-bit x87 FPU** (``fp_shared/ven_fp_top.sv``, ``72,204``
LUTs, ``38`` DSP48E2 slices) owns the pointer-mapped ``8 × 80-bit`` ``floatx80``
register stack (``ven_fp_state.sv``) with a **zero-cycle FXCH rename queue**
(``ven_fp_fxch_queue.sv``), 2-stage pipelined ``FADD``/``FSUB``/``FMUL``
(``VEN_FP_PIPE`` + ``VEN_FP_PIPE2``), asynchronous integer/FP execution overlap
(``VEN_FP_ASYNC*``), unified multi-cycle radix-4 SRT ``FDIV``/``FSQRT``/
``FPREM``/``FPREM1`` (``fpu_srt_div.sv``), iterative packed-BCD
``FBLD``/``FBSTP`` (``ven_bcd_to_fp.sv`` / ``ven_bcd.sv``), full 14/28-byte
environment and 94/108-byte state save/restore, and all 8 polynomial
transcendental instructions (``ven_fp_trans.sv``). In the zero-define unit-test
baseline, x87 instructions run sequentially through ``S_FLOAD → S_FEXEC →
S_FSTORE`` using ``fpu_x87_pkg`` (where ``VEN_FP_PC_RELAX`` is off by default;
``c0e3fe43`` enables ``VEN_FP_PC_RELAX`` for single/double/extended precision
control). P6-era conditional FP moves/compares (``FCMOVcc``, ``FCOMI``/
``FUCOMI``) are intentionally unimplemented on this non-MMX P54C core and raise
architectural ``#UD``.

.. list-table::
   :header-rows: 1
   :widths: 26 24 12 26 12

   * - Mnemonic
     - Encoding
     - U/V class
     - Datapath usage
     - Status
   * - ``FLD m32/m64/m80/ST(i)``
     - ``D9 /0``; ``DD /0``; ``DB /5``; ``D9 C0+i``
     - **NP**
     - Push ``floatx80`` (queued 32/64b loads under ``VEN_FP_MEM_LOADS`` in ``c0e3fe43``).
     - implemented
   * - ``FST/FSTP m32/m64/m80/ST(i)``
     - ``D9 /2,/3``; ``DD /2,/3``; ``DB /7``; ``DD D0+i/D8+i``
     - **NP**
     - Store ``ST(0)`` rounded per RC/PC, ``FSTP`` pops; 1–3 memory beats.
     - implemented
   * - ``FILD`` / ``FIST/FISTP``
     - ``DF/DB /0``; ``DF/DB /2,/3``; ``DF /5,/7``
     - **NP**
     - Signed 16/32/64b int ↔ ``floatx80`` load/store + optional FIST overflow erratum hook.
     - implemented
   * - ``FBLD`` / ``FBSTP m80``
     - ``DF /4``; ``DF /6``
     - **NP**
     - 18-digit packed-BCD load/store via iterative ``ven_bcd_to_fp`` / ``ven_bcd`` (``VEN_BCD_ITER``).
     - implemented
   * - ``FXCH ST(i)``
     - ``D9 C8+i``
     - **FX / PV**
     - Zero-cycle pointer rename queue in ``c0e3fe43`` (``ven_fp_fxch_queue.sv``); 1-cyc swap in baseline.
     - implemented
   * - ``FFREE`` · ``FINCSTP`` · ``FDECSTP`` · ``FNOP``
     - ``DD C0+i``; ``D9 F7``; ``D9 F6``; ``D9 D0``
     - **NP**
     - Stack-management (tag/TOP) ops, no data move.
     - implemented
   * - ``FADD/FSUB/FSUBR/FMUL/FDIV/FDIVR``
     - ``D8/DC C0+i``; ``D8 /r``; ``DC /r``; ``DA/DE`` (int); ``DE C0+i`` (pop)
     - **NP**
     - 2-stage pipelined ``ven_fp_alu`` (add/sub/mul) + radix-4 SRT ``fpu_srt_div`` (div + FDIV bug opt-in).
     - implemented
   * - ``FSQRT``
     - ``D9 FA``
     - **NP**
     - IEEE-exact ``sqrt(ST0)`` via iterative ``fpu_srt_div`` (``VEN_SRT_ITER``); negative → QNaN+IE.
     - implemented
   * - ``FABS`` · ``FCHS``
     - ``D9 E1``; ``D9 E0``
     - **NP**
     - Exact sign-bit clear / toggle on ``ST(0)``, no IE.
     - implemented
   * - ``FPREM/FPREM1`` · ``FRNDINT`` · ``FSCALE`` · ``FXTRACT``
     - ``D9 F8/F5/FC/FD/F4``
     - **NP**
     - Exact IEEE/x87 partial remainder (``VEN_FPREM`` / ``fpu_srt_div``), round-to-int, ``2^n`` scale, & exponent/significand split.
     - implemented
   * - ``FCOM/FCOMP/FCOMPP``
     - ``D8 /2,/3``; ``DC /2,/3``; ``D8 D0+i/D8+i``; ``DE D9``
     - **NP**
     - Ordered (signaling) compare → C3/C2/C0, IE on any NaN.
     - implemented
   * - ``FUCOM/FUCOMP/FUCOMPP``
     - ``DD E0+i``; ``DD E8+i``; ``DA E9``
     - **NP**
     - Unordered (quiet) compare → C3/C2/C0, IE only on SNaN.
     - implemented
   * - ``FTST``
     - ``D9 E4``
     - **NP**
     - Signaling compare of ``ST(0)`` vs ``+0.0`` → C3/C2/C0.
     - implemented
   * - ``FXAM``
     - ``D9 E5``
     - **NP**
     - Classify ``ST(0)`` (sign + tag/value class) into C3/C2/C1/C0.
     - implemented
   * - ``FICOM/FICOMP``
     - ``DA /2,/3``; ``DE /2,/3``
     - **NP**
     - Integer-mem signaling compare → C3/C2/C0.
     - implemented
   * - ``FLD1/FLDL2T/FLDL2E/FLDPI/FLDLG2/FLDLN2/FLDZ``
     - ``D9 E8..EE``
     - **NP**
     - Push 80-bit ROM constant onto x87 stack.
     - implemented
   * - ``FINIT / FNINIT``
     - ``9B DB E3`` / ``DB E3``
     - **NP**
     - Reset FPU state (``TOP=0``, ``FCW=0x037F``, ``FSW=0``, tags empty); both wait & no-wait forms.
     - implemented
   * - ``FCLEX / FNCLEX``
     - ``9B DB E2`` / ``DB E2``
     - **NP**
     - Clear exception/busy bits preserving C0–C3 + TOP; both wait & no-wait forms.
     - implemented
   * - ``FLDCW m16``
     - ``D9 /5``
     - **NP**
     - Load 16-bit control word (RC/PC/exception masks).
     - implemented
   * - ``FNSTCW / FSTCW m16``
     - ``D9 /7`` / ``9B D9 /7``
     - **NP**
     - Store 16-bit control word (wait & no-wait forms).
     - implemented
   * - ``FNSTSW / FSTSW AX/m16``
     - ``DF E0`` / ``DD /7`` / ``9B``-prefixed
     - **NP**
     - Store status word (with live ``TOP``) to ``AX`` or ``m16`` (wait & no-wait forms).
     - implemented
   * - ``FWAIT / WAIT``
     - ``9B``
     - **NP**
     - Drain in-flight async x87 operations & check unmasked pending ``#MF``.
     - implemented
   * - ``FLDENV / FNSTENV / FSTENV``
     - ``D9 /4``; ``D9 /6``; ``9B D9 /6``
     - **NP**
     - Load/store 14-byte (16-bit) or 28-byte (32-bit) x87 environment image (``S_FENV_*``).
     - implemented
   * - ``FSAVE / FNSAVE / FRSTOR``
     - ``9B DD /6``; ``DD /6``; ``DD /4``
     - **NP**
     - Save/restore full 94-byte (16-bit) or 108-byte (32-bit) x87 environment + 8×80b stack image.
     - implemented
   * - Transcendentals (``F2XM1``, ``FYL2X``, ``FYL2XP1``, ``FSIN``, ``FCOS``, ``FSINCOS``, ``FPTAN``, ``FPATAN``)
     - ``D9 F0/F1/F9/FE/FF/FB/F2/F3``
     - **NP**
     - Shared polynomial/ROM transcendental engine (``ven_fp_trans.sv``, ``+define+VEN_TRANSCENDENTAL``).
     - implemented

FLD / FST / FSTP (``D9/DD /0``, ``DB /5``, ``D9 C0+i``; ``D9/DD /2,/3``, ``DB /7``, ``DD D0+i/D8+i``)
    ``FLD`` **pushes** a value: ``TOP`` is pre-decremented and the new ``ST(0)``
    loaded. ``m32``/``m64`` are converted to ``floatx80`` (via ``fx_from_f32``/
    ``fx_from_f64``), ``m80`` is loaded canonically, and ``FLD ST(i)`` pushes a
    copy of the *old* ``ST(i)``. **Datapath:** memory forms set
    ``d_f_mem_read`` + ``d_f_mbytes`` (4/8/10), the AGU computes the address on
    the same ModR/M/SIB path as integer loads, ``S_FLOAD`` reads 1-3 bus beats
    into ``f_mem80``, and ``S_FEXEC`` decrements ``TOP``, clears the new tag, and
    writes the converted value. ``FST``/``FSTP`` store ``ST(0)`` (``FSTP`` then
    pops): ``m32``/``m64`` round per RC (setting PE on inexact, IE on overflow),
    ``m80`` is exact; ``S_FEXEC`` latches the store value and sticky flags, and
    ``S_FSTORE`` drives 1-3 beats, applying the pop on the last. **NP** in the
    functional FSM; AP-500 rates ``FLD m32/m64/ST(i)`` and ``FST``/``FSTP`` as
    FX, but the parallel-pairing case is not implemented.

FILD / FIST / FISTP and FBLD / FBSTP (``DF/DB /0,/2,/3``, ``DF /4,/5,/6,/7``)
    ``FILD`` pushes a signed 16/32/64-bit integer converted **exactly** to
    ``floatx80`` (``fx_from_int``); ``FIST``/``FISTP`` convert ``ST(0)`` to a
    signed integer (rounded per RC), store it, and (``FISTP``) pop, with the
    documented **Pentium FIST overflow erratum** hook
    (``fist_errata_overflow``/``fx_to_int_errata``) gated behind ``errata_en``.
    Under ``VEN_BCD_ITER`` (enabled in ``c0e3fe43``), ``FBLD m80`` (``DF /4``)
    and ``FBSTP m80`` (``DF /6``) convert 18-digit packed decimal values
    iteratively via ``ven_bcd_to_fp.sv`` and ``ven_bcd.sv``. All **NP**.

FXCH (``D9 C8+i``)
    Exchanges ``ST(0)`` with ``ST(i)`` (default ``ST(1)``) — no flags or
    arithmetic. In the **deployed c0e3fe43 profile** (``VEN_FP_SHARED`` +
    ``VEN_FP_FXCH_QUEUE``), ``fp_shared/ven_fp_fxch_queue.sv`` renames the
    pointer-mapped stack entries with **zero execution latency** behind in-flight
    x87 arithmetic — reproducing the overlapped ``FXCH`` throughput DOS Quake
    relies upon. In the zero-define unit-TB baseline, ``FXCH`` executes a plain
    1-cycle ``fpr`` swap.

FFREE / FINCSTP / FDECSTP / FNOP (``DD C0+i``, ``D9 F7/F6/D0``)
    All **NP** stack-management ops with no data move and no memory: ``FFREE``
    marks ``ST(i)``'s tag empty; ``FINCSTP``/``FDECSTP`` rotate ``TOP`` ±1
    *without* touching tags or data (and clear C1/C2/C3); ``FNOP`` is a true
    no-op. Each is one ``S_FEXEC`` step.

FADD / FSUB / FSUBR / FMUL / FDIV / FDIVR (``D8/DC``, ``D8 /r``, ``DC /r``, ``DA/DE``, pop forms)
    ``ST(dst) op= operand``. ST0-dest forms compute ``ST0 = ST0 op src``;
    ST(i)-dest forms compute ``ST(i) = ST(i) op ST0`` with the classic x87
    ``SUBR``/``SUB`` and ``DIVR``/``DIV`` sense-swap (decode flips the aluop bit
    for reg = 4..7). The ``FIADD``/``FISUB``/... forms take a 16/32-bit integer
    memory operand converted to ``floatx80``; the ``p``/``ip`` encodings pop
    after the op. **Datapath:** memory/int forms ``S_FLOAD`` the operand, then
    ``S_FEXEC`` calls ``f_eval`` → ``{ie, ze, inexact, result}``
    (``fx_add``/``fx_mul``/``fx_div``, round-to-nearest, 64-bit extended),
    writing the dest slot and latching sticky PE/IE/ZE; ``f_eval`` models QEMU
    specials bit-exactly (``x/0 → ±Inf+ZE``, ``0/0 → QNaN indefinite+IE``). The
    **Pentium FDIV SRT erratum** is reproduced two ways: the runtime
    ``fx_div_errata`` anchor for the one published bit-exact operand pair (gated
    by ``errata_en[ERR_FDIV]``), and — optionally, at compile time
    (``+define+VEN_SRT_FDIV_BUG``) — the buggy PLA of the genuine radix-4 SRT
    divider ``fx_srt_div`` (the default datapath), which reproduces the flaw
    from first principles for *all* operands. See
    :doc:`../microarch/srt-divider`. All
    **NP** functionally (AP-500 FX, not modeled); in cycle-mode the ``D8``
    reg-form models result latency (3 add/sub, 3 mul, 39 div) and occupancy so a
    dependent ``fadd`` chain emerges at CPI ~3. **Precision control:** any arith
    with ``PC != 11`` sets ``f_pc_bad`` → ``S_HALT`` (the datapath only
    implements 64-bit extended).

FSQRT / FABS / FCHS (``D9 FA``, ``D9 E1``, ``D9 E0``)
    ``FSQRT`` computes ``sqrt(ST0)`` (``fx_isqrt`` fixed-point + round per RC):
    ``sqrt(±0) = ±0`` (C2 set), ``sqrt(negative finite) =`` real-indefinite
    ``QNaN + IE``, positive operands take the normal path (PE on inexact); the
    same ``PC != 11 → HALT`` gate applies. ``FABS`` clears ``ST(0)``'s sign bit
    and ``FCHS`` toggles it — exact bit twiddles with no flag/IE update. All
    **NP** (AP-500 lists ``FABS``/``FCHS`` as FX; not modeled).

FCOM / FUCOM / FTST / FXAM / FICOM families (``D8/DC /2,/3``, ``DD E0+i/E8+i``, ``D9 E4/E5``, ``DA/DE /2,/3``, ``DE D9``, ``DA E9``)
    All compares set the condition codes ``C3:C2:C0`` (``000`` >, ``001`` <,
    ``100`` =, ``111`` unordered) via ``apply_cmp`` (which preserves C1).
    ``FCOM``/``FCOMP``/``FCOMPP`` are **ordered (signaling)** — IE on *any* NaN
    operand (``FCOMP`` pops once, ``FCOMPP`` twice). ``FUCOM``/``FUCOMP``/
    ``FUCOMPP`` are **unordered (quiet)** — IE only on a *signaling* NaN (QNaN
    allowed). ``FTST`` compares ``ST(0)`` against ``+0.0`` (signaling). ``FXAM``
    *classifies* ``ST(0)`` (reading the TOP tag for empty), reporting sign + class
    in C3/C2/C1/C0. ``FICOM``/``FICOMP`` compare against a signed integer memory
    operand (signaling). All **NP** (AP-500 rates the compares as FX).

FLD-constants (``D9 E8..EE``)
    Push an 80-bit ROM constant: ``FLD1=1.0``, ``FLDL2T=log2(10)``,
    ``FLDL2E=log2(e)``, ``FLDPI=π``, ``FLDLG2=log10(2)``, ``FLDLN2=ln(2)``,
    ``FLDZ=0.0``. ``S_FEXEC`` pre-decrements ``TOP`` and writes ``fconst(sel)``
    (a hard-coded ``floatx80`` ROM). All **NP**; the cycle model gives them
    occ/lat 2 (vs 1 for ``FLD ST(i)``/mem) to match the oracle.

FPU control, environment & transcendental ops
    ``FNINIT``/``FINIT`` reset the FPU (``TOP=0``, ``FCW=0x037F``, ``FSW=0``,
    tags all-empty); ``FNCLEX``/``FCLEX`` clear sticky exception/busy bits while
    preserving ``C0–C3`` and ``TOP``; ``FLDCW`` and ``FNSTCW``/``FSTCW`` load
    and store the 16-bit control word (in ``c0e3fe43``, ``VEN_FP_PC_RELAX``
    supports single/double/extended ``FCW.PC`` precision); and ``FNSTSW``/``FSTSW``
    store the status word (with live ``TOP``) to ``AX`` or ``m16``. Standalone
    ``FWAIT`` (``0x9B``) synchronizes in-flight async x87 execution and checks
    unmasked ``#MF`` exceptions before both barriers and wait-prefixed forms.
    ``FLDENV``/``FNSTENV``/``FSTENV`` (``D9 /4,/6``) and ``FRSTOR``/``FNSAVE``/
    ``FSAVE`` (``DD /4,/6``) transfer full 16-bit and 32-bit x87 environment and
    8×80-bit register-stack images via ``core_fenv.svh``. ``FRNDINT``,
    ``FSCALE``, ``FXTRACT``, ``FPREM``/``FPREM1`` (``VEN_FPREM`` /
    ``fpu_srt_div.sv``), and all eight x87 transcendentals (``F2XM1``,
    ``FYL2X``, ``FYL2XP1``, ``FSIN``, ``FCOS``, ``FSINCOS``, ``FPTAN``,
    ``FPATAN`` via ``ven_fp_trans.sv`` under ``VEN_TRANSCENDENTAL``) are
    implemented in ``c0e3fe43``.
