# AP-500 fast-path coverage gap spec

Status: **BATCHES 1-3 IMPLEMENTED + GATED (2026-06-05); batches 4-5 deferred.**
REVIEW_Jun5.md Limit #5, Action 6 ("Expand AP-500 fast-path coverage").

- **DONE — Batch 1: accumulator-immediate ALU (imm32).** The `ALU eAX, imm32`
  forms `05/0D/15/1D/25/2D/35/3D` (ADD/OR/ADC/SBB/AND/SUB/XOR/CMP) are now
  fast-pathed in `rtl/core/decode.sv` (the `8'b00??_?101` arm, mirroring the `A9`
  TEST + `83` reg-imm arms): ADC/SBB=PU, CMP writes no reg. They now PAIR (issue
  into V) where they previously fell to the slow FSM and serialized. **Func stays
  byte-identical** (65/65 goldens unchanged — the fast-path execution matches
  QEMU), every existing M4/M5 band held, and the NEW gated band `mb_accimm` (the
  `PAIR` class in `verif/m5_metrics.py`: pairing% ≥ 40 AND abs-cyc within 10% of
  the p5model golden) PASSES at **pairing 50% / abs-cyc +0.35%** (vs ~0% pairing /
  ~2× cycles before). The 16-bit (66-prefixed) accumulator op keeps `0x66` as its
  first byte so it never reaches the arm — it stays on the slow FSM.
- **DONE — Batch 2: reg-form r/m32,imm32 (`81 /r`, `C7 /0`).** The general-register
  imm32 siblings of the batch-1 accumulator forms: `81 /r` (ALU r/m32,imm32, the
  imm32 version of the existing `83` imm8 arm) and `C7 /0` (MOV r/m32,imm32, the
  ModRM sibling of `B8+r`), both **reg form only (mod11, no memory)**. ADC/SBB=PU,
  CMP writes no reg, `C7` only `/0`. **Func byte-identical** (66/66 goldens
  unchanged), every band held, NEW gated band `mb_rmimm` (PAIR class) PASSES at
  **pairing 50% / abs-cyc +0.35%**. The 16-bit (66-prefixed) forms keep `0x66`
  first so they stay on the slow FSM.
- **DONE — Batch 3: shift-by-1 (`D1 /4..7`).** SHL/SHR/SAL/SAR r/m32,1 (the x+x/halve idiom), the implicit-count-1 sibling of `C1` (same datapath, shimm=1, len 2, reg form, PU). Func byte-identical (67/67), all bands held, NEW gated band `mb_sh1` PASSES at pairing 50% / abs-cyc +0.35%.
- **DEFERRED — batches 4-5** (the byte accumulator forms `04`/`A8`; PUSH/POP `50+r`/`58+r`; near branches `E8`/`E9`/`0F 8x`;
  memory/store forms). §3 below orders them by frequency × benefit; each needs its
  own pairing microbenchmark + a re-run of all bands + the full func diff (byte
  forms add byte-width fast-path ALU; PUSH/POP + stores add real memory/stack
  functional risk). `D1` shift-by-1 (trivial mirror of `C1`) is the next safe one.

Owner doc; the Batch-1/2/3 edits are in `rtl/core/decode.sv` + the `PAIR` band in
`verif/m5_metrics.py` + `verif/tests/mb_accimm`,`mb_rmimm`,`mb_sh1`.

---

## 1. How pairing works today (verified against code)

- **Fast-path decoder** `rtl/core/decode.sv` (`fp_decode`): recognises a small
  set of forms and sets `d.simple=1` + `pairs_first`/`pairs_second`. Anything it
  does not recognise leaves `d.simple=0`, so the issue path
  (`core_fastpath.svh:144` `if (!u_d.simple || sys_mode) -> S_FETCH`) hands the
  instruction to the slow multi-cycle FSM, which retires it ALONE (no V-pipe
  pairing) — it serializes.
- **Pairing checker** `rtl/core/issue_uv.sv` (`fp_can_pair`): both `simple`,
  `u.pairs_first`, `v.pairs_second`, no `disp_imm`, no RAW/WAW on GP regs, and no
  V-slot load. This mirrors the p5model `can_pair` rules and
  `docs/ap500-pairing-table.md`.

The pairing CHECKER is faithful. The gap is COVERAGE: a pairable AP-500 form
that `fp_decode` doesn't recognise never even reaches the checker — it
serializes via the slow FSM. The observable cost is that two AP-500-pairable
instructions that *should* issue in one clock instead take ≥2 clocks (the slow
FSM is multi-state per instruction).

### Forms `fp_decode` recognises today (exhaustive, from decode.sv)

| Opcode(s)        | Form                                  | simple | pairs |
|------------------|---------------------------------------|:------:|-------|
| `B8+r`           | MOV r32, imm32                        | yes    | UV    |
| `00/08/../38 /r` (mod11) | ALU r/m32,r32 reg form        | yes    | UV (ADC/SBB=PU) |
| `02/0A/../3A /r` (mod11) | ALU r32,r/m32 reg form        | yes    | UV (ADC/SBB=PU) |
| `83 /r` (mod11)  | ALU r/m32, imm8 sign-ext, reg form    | yes    | UV (ADC/SBB=PU) |
| `40+r / 48+r`    | INC/DEC r32                           | yes    | UV    |
| `89 /r` (mod11)  | MOV r/m32, r32 reg form               | yes    | UV    |
| `8B /r` (mod11)  | MOV r32, r/m32 reg form               | yes    | UV    |
| `8B /r` (mod00, reg base, no SIB/disp) | MOV r32,(base) load | yes  | UV    |
| `8D /r` (mod00, reg base) | LEA r32,(base)               | yes    | UV    |
| `C1 /4../7` (mod11) | SHL/SHR/SAL/SAR r/m32, imm8        | yes    | PU    |
| `A9`             | TEST eAX, imm32                       | yes    | UV    |
| `90`             | NOP                                   | yes    | UV    |
| `A2/A3` (cycle)  | MOV moffs,AL/eAX (errata only)        | yes    | UV    |
| `70..7F`         | Jcc rel8                              | yes    | PV    |
| `EB`             | JMP rel8 (short)                      | yes    | PV    |
| `D8/D9/DD` (mod11, cycle) | x87 reg-form whitelist (is_fp) | (is_fp) | NP  |

Everything else → `simple=0` → slow FSM → **serializes**.

---

## 2. Gap table — AP-500-pairable forms that currently serialize

Authority: `docs/ap500-pairing-table.md` (AP-500 / 241799-001). "AP-500 pair?"
is from that table; "fast-pathed today?" is from §1; "observable cost" is the
serialization penalty (cannot pair → ≥2 clocks where 1 would do, plus the slow
FSM's per-instruction multi-state overhead).

| Form                                   | AP-500 class | Fast-pathed today? | Observable cost |
|----------------------------------------|:------------:|:------------------:|-----------------|
| `MOV r32, imm8/imm16` via `C7 /0` (mod11) | UV       | NO                 | serializes; very common (init/const) |
| `ALU r/m32, imm32` (`81 /r`, mod11)    | UV           | NO (only `83` imm8) | serializes; common (mask/add const) |
| `ALU r/m32, imm8` other than `83`? — `83` IS covered | UV | partial | only imm8-sign-ext covered |
| `TEST r32, r32` / `TEST mem, r32` (`85 /r`) | UV      | NO                 | serializes; common before Jcc |
| `TEST AL, imm8` (`A8`)                 | UV (accum)   | NO (only `A9`)     | serializes; byte test idiom |
| `ALU/MOV with memory operand` (mod00 disp, mod01/10, SIB) | UV (load form is U-lead) | NO (only `8B` reg-base load) | serializes; the dominant real-code form |
| `MOV r/m32, r32` store (mod!=11)       | UV           | NO                 | serializes; every store |
| `PUSH reg` (`50+r`)                    | UV           | NO                 | serializes; ubiquitous in prologues/calls |
| `PUSH imm` (`68`/`6A`)                 | UV           | NO                 | serializes; arg setup |
| `POP reg` (`58+r`)                     | UV           | NO                 | serializes; epilogues |
| `CALL rel32` (`E8`) direct near        | PV           | NO                 | serializes; cannot fill V after a UV op |
| `JMP rel32` (`E9`) direct near         | PV           | NO (only `EB` short) | serializes; long jumps/tail calls |
| `Jcc rel32` (`0F 8x`) near             | PV           | NO (only rel8 `7x`) | serializes; far-branch idiom |
| `SHL/SHR/SAL/SAR by 1` (`D1 /4../7`)   | PU           | NO (only `C1` imm) | serializes; the `x+x`/halve idiom |
| `ADC/SBB` reg/imm forms                | PU           | partial (reg/`83` only) | mem/`81`-imm ADC/SBB serialize |
| `ALU AL/eAX, imm` (`04/0C/.../2C`, `05/.../2D`) | UV (accum) | NO            | serializes; accumulator-immediate (Action 6 names this first) |

Note: the AGI/eflags/special-pairs rules are already correct in the checker —
this gap is purely about which forms reach the checker at all.

---

## 3. Recommended first batch (Action 6 priority)

Action 6 explicitly prioritises "accumulator-immediate forms, common
memory/register forms, push/pop variants, and simple branch patterns." Order by
frequency × pairing benefit, lowest functional risk first:

1. **Accumulator-immediate ALU/TEST** — `04/0C/14/1C/24/2C/34/3C` (AL,imm8),
   `05/0D/.../3D` (eAX,imm32), `A8` (TEST AL,imm8). UV-pairable accumulator
   forms; pure-register semantics (no memory), so lowest risk. Mirror the
   existing `A9` arm.
2. **ALU/MOV r/m, imm reg-forms** — `81 /r` (imm32, mod11), `C7 /0` (MOV
   r/m,imm, mod11). UV. The `disp_imm` field already exists in the checker so a
   reg-form (no displacement) imm op pairs cleanly.
3. **PUSH/POP reg** — `50+r` / `58+r`. UV. Needs the ESP micro-update; AP-500
   special-pairs already exempt ESP from contention (the checker masks ESP out
   of reads/writes), so `push;push` / `pop;pop` can pair. Higher risk (stack
   pointer + memory), so gate carefully.
4. **`D1` shift-by-1** — `D1 /4../7`. PU. Trivial extension of the existing `C1`
   arm (shift count = 1 instead of imm8).
5. **Near branches** — `E8` CALL rel32, `E9` JMP rel32, `0F 8x` Jcc rel32, all
   PV. Extends the existing `7x`/`EB` branch arms; benefits real call-heavy code.

Batch 1 (item 1) is the recommended FIRST landing: highest frequency, zero
memory/stack interaction, directly mirrors an existing arm.

---

## 4. Pairing microbenchmark (Action 7)

Place under `verif/tests/` (`.s` + `.elf`), mirroring `mb_jmppair`/`mb_depadd`:

| Microbench    | Kernel content                                          | Tests |
|---------------|---------------------------------------------------------|-------|
| `mb_accimm`   | interleaved accumulator-imm ALU/TEST + a pairable partner | pairing% rises; CPI drops vs serialized baseline |
| `mb_pushpop`  | `push reg; push reg` / `pop reg; pop reg` sequences      | special-pair (ESP-exempt) pairing |
| `mb_callpair` | `<UV op>; call rel32` groups                            | PV branch fills V slot |

The microbench must show, via the RTL `--cycle` trace, that the converted forms
now PAIR (the trace's `paired` flag set, `m5_metrics._basic` pairing% > 0 for
that kernel) where the slow-FSM baseline showed 0% pairing, and that total
cycles drop accordingly. Cross-check the pairing decision against
`docs/ap500-pairing-table.md` for each added form.

---

## 5. p5model band + RISK

- **New band required.** `verif/m5_metrics.py` has no pairing-coverage band for
  these kernels; an unknown kernel returns `INFO` (`m5_metrics.py:219`) with no
  PASS/FAIL. A new band must assert (a) pairing% > 0 for the converted kernel
  and (b) abs-cyc within `DEFAULT_ABS_TOL_PCT` (10%) of the p5model golden, which
  DOES pair these forms (so the RTL converges to the oracle as coverage grows).
- **RISK — band perturbation.** Newly-pairing forms change cycle counts for ANY
  existing kernel that contains them (e.g. `mb_imiss`'s p2align filler uses
  `mov;jmp`). Each batch must re-run ALL M4/M5 bands (`make verify` cycle gates)
  and re-baseline goldens where a previously-serialized form now pairs. This is
  why the work is incremental and gated per batch (Action 10).
- **RISK — functional.** Adding memory/store/stack forms to the fast path means
  the fast path now executes them (instead of deferring to the proven slow FSM).
  The functional diff vs QEMU MUST stay clean; the safest batches (1, 4) touch
  only register/accumulator semantics. PUSH/POP (batch 3) and memory forms
  (batch 2 stores) carry real functional risk and need the full diff corpus
  green before the cycle band is trusted.
- **RISK — the checker, not coverage, owns correctness.** Expanding coverage
  must not weaken `issue_uv.sv`: the `disp_imm`, RAW/WAW, ESP/flags-mask, and
  V-slot-load rules must continue to gate every newly-recognised form, or a
  wrongly-paired form would diverge from QEMU.
