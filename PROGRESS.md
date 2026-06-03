# Ventium — progress log

Living status for the P5/P54C Verilog replica. Plan: [`PLAN.md`](PLAN.md).
Newest entries at the top. Dates are ISO (YYYY-MM-DD).

## Status at a glance

| Milestone | Description | Gate | Status |
|---|---|---|---|
| **M0** | Bootstrap: repo skeleton, QEMU golden-trace plugin, trace format, Verilator TB shell, comparator | comparator runs end-to-end on trivial trace | ✅ done (infrastructure proven; RTL still a NOP stub) |
| M1 | Decoder + single-issue integer functional | integer subset diff-clean vs QEMU (decoder-exhaustive vs XED/Capstone is ongoing toward M2) | ✅ done (integer SUBSET func-equiv vs QEMU on smoke + M1 corpus; not yet decoder-exhaustive) |
| M2 | User-mode integer ISA completeness (re-scoped; system mode → M2S) | broad integer-ISA corpus diff-clean vs QEMU (user-mode) | ✅ done (28-program corpus func-equiv vs QEMU user-mode; system ops / far CALL-RET / ENTER / mem-operand bit-string + SHLD deferred & HALT; decoder-exhaustive-vs-XED still ongoing) |
| M2S | System mode: segmentation/paging/TLB/interrupts/SMM (needs system-mode oracle) | system-arch corpus diff-clean | ☐ not started (deferred from M2) |
| M3 | x87 FPU | x87 corpus diff-clean vs QEMU (`make m3` exit 0) | ✅ done (x87 functional core: stack/status/control/tag + 80-bit datapath, data movement + normal-operand arithmetic bit-exact vs QEMU; 14-program x87 corpus + 28 integer = 42/42 PASS. Transcendentals, BCD, FSAVE/FRSTOR/FLDENV, unmasked #MF, and non-default **precision** control (PC≠64-bit) are DEFERRED and HALT loudly) |
| M4 | Dual-issue U/V + pairing + branch prediction | µbench CPI/pairing/mispredict match p5model | ☐ not started (the first CYCLE milestone) |
| M5 | Cache/bus timing + x87 cycle accuracy | bus corpus + FP/branch cycle match | ☐ not started |
| M6 | Errata & stepping fidelity (stretch) | targeted errata repro | ☐ not started |

Legend: ☐ not started · ▶ in progress · ✅ done · ⚠ blocked

## What exists today (inherited)

- **`ventium-refs/` submodule** — full reference library (Intel manuals, Alpert &
  Avnon, AP-500/AP-526, Agner Fog, datasheet, spec updates, die-photo articles)
  with a cheap page-referenced index in `ventium-refs/00-index/INDEX.md`.
- **`ventium-refs/07-p5-emulation-harness/`** — a working QEMU-based functional +
  cycle **golden reference** for P54C/non-MMX:
  - plugin-enabled `qemu-i386 -cpu pentium` build scripts (#UDs on non-P5 opcodes),
  - `plugin/p5model.c` — in-order U/V cycle-estimation model (validated 6/6 on
    its microbenchmarks: dependent/independent ALU CPI, fadd chain, AGI, branch
    predictable/random),
  - `tools/isa_verify.py` — static P5-ISA checker (capstone),
  - mined timing constants + provenance in `docs/p5_timing_*.json`,
  - benchmark corpus (Dhrystone/Whetstone/LINPACK/CoreMark/STREAM + kernels).

  This is the cycle oracle for layers 3–4 and the functional oracle for layers
  1–2. **No RTL exists yet.**

## Log

### 2026-06-03 — M3 complete (x87 FPU functional core, bit-exact vs QEMU)

Added the **x87 floating-point unit** to the single-issue core and verified the
x87 architectural state **diff-clean vs QEMU** (`compare.py --mode func` exit 0).
**M3 = the x87 functional core: data movement + normal-operand arithmetic,
bit-exact vs QEMU's softfloat `floatx80`. Transcendentals and exotic corners are
deferred (and HALT loudly).** Gate: `make m3` (exit 0). `make m2` / `make m1` /
`make m0-smoke` all still pass; RTL stays lint-clean (`verilator --lint-only
-Wall -Wno-DECLFILENAME -Wno-UNUSED`, exit 0).

**The x87 FPU** (`rtl/core/intcore.sv` FSM + `rtl/fpu/fpu_x87_pkg.sv` datapath):
- **Register stack model**: 8×80-bit physical regfile with a 3-bit `TOP`; `st(i)`
  = `fpr[(TOP+i)&7]`; push = `TOP--`, pop = `TOP++`; an 8-bit per-register valid
  tag (`fptag`, 1=empty) drives FXAM's empty class and FFREE.
- **Status word** (`fstat`): condition codes C0/C2/C3 (compares/classify), the C1
  bit, and the masked exception flags IE/ZE/PE accumulated sticky; the retire
  snapshot overlays `TOP` into bits[13:11] exactly as QEMU's gdbstub reports it.
- **Control word** (`fctrl`): FLDCW/FNSTCW; reset/FNINIT = `0x037f` (RC=00
  nearest, PC=11 64-bit, all six masks set). RC (rounding control) is fully
  honored by the datapath (see below).
- **Tag word**: QEMU's user-mode gdbstub abridges `ftag` to `0x0000`, so the RTL
  reports `0x0000` (confirmed across empty/full-stack/FFREE/after-pop probes) —
  we reproduce **what QEMU reports**, not the architectural 2-bit-per-reg tag.
- **80-bit datapath** (`fpu_x87_pkg.sv`): a self-contained `floatx80` engine —
  add/sub (aligned 128-bit significand, RNE/directed round-pack), multiply
  (64×64→128), divide (long division with an exact-remainder sticky), sqrt
  (256-bit restoring integer sqrt + sticky), and float32/64↔floatx80,
  int16/32/64↔floatx80 conversions. The canonical layout (sign|exp in [79:64],
  mantissa in [63:0]) is the SAME encoding `gen_trace --x87` emits, so the st-reg
  hex strings compare directly.

**Trace infrastructure** (the second DPI hook, per `rtl-interface.md` §2 /
`trace-format.md` §2.2): the core calls `vtm_retire_x87` on the same retirement
as `vtm_retire`, carrying the post-commit x87 state (st0..st7 as packed 80-bit,
`fctrl`/`fstat`/`ftag`); the TB buffers both and emits ONE func record with the
x87 fields, and the RTL trace header declares `x87:true`. `fop`/`fiseg`/`fioff`/
`foseg`/`fooff` are reported 0 (matches QEMU user-mode, which does no FP ptr
tracking). The golden side uses the already-committed `gen_trace.py --x87`
i387/tail-anchor fix (commit c39905b). `compare.py` compares the full x87 set iff
BOTH headers say `x87:true`; the 28 integer programs keep `x87:false` and are
unaffected.

**Tier-1 / Tier-2 coverage — bit-exact vs QEMU** (the 14-program x87 corpus):
- **Tier 1** (data movement, stack, status/control, compares, classify): FLD/FST/
  FSTP (m32/m64/m80 + `st(i)`), FILD/FIST/FISTP (m16/m32/m64), FXCH, FFREE,
  FINCSTP/FDECSTP, FNOP; the seven constants FLDZ/FLD1/FLDPI/FLDL2E/FLDL2T/FLDLG2/
  FLDLN2; FABS/FCHS; FCOM/FCOMP/FCOMPP, FUCOM/FUCOMP/FUCOMPP, FTST, FXAM, FICOM/
  FICOMP; FNSTSW ax/m16, FNSTCW/FLDCW, FNINIT, FNCLEX, FWAIT.
- **Tier 2** (normal operands, default control word): FADD/FSUB/FSUBR/FMUL/FDIV/
  FDIVR (+ `p`/`ip` and memory/int FIADD… forms), FSQRT — round-to-nearest-even,
  64-bit precision, bit-exact.
- **Tier 3 pulled INTO the gate this phase**: non-default **rounding** control
  (RC = toward-zero / toward +inf / toward -inf) at 64-bit precision; masked
  special-operand arithmetic (x/0, 0/0, sqrt of a negative / of -0).

**Adversarial review — found + fixed** (each reproduced against QEMU with a tiny
program first, fixed, then locked with a new gated regression program; the FSQRT
clear-codes/C2 behavior was discovered while reproducing finding 1):
- **[high] FXAM on an Infinity** — `fxam_codes` returned the WRONG class encoding
  for Inf (C3+C0 = 0x4100; the in-code comment was self-contradictory). QEMU's
  `helper_fxam_ST0` sets **0x500 (C2+C0)** for Inf. Fixed the Inf branch.
  (Reproduced: `fxam` on +Inf → QEMU fstat=0x3d00; pre-fix RTL=0x7900.) Locked by
  `tx_fxam` (every FXAM class incl. ±Inf/QNaN/±0/normal/empty).
- **[med] FST/FIST store flags** — the store path never set PE (precision/inexact)
  on a rounding FST m32/m64 or non-integer FIST, and never set IE + integer-
  indefinite on an out-of-range FIST. QEMU's helper_fst*/fist* latch these via
  `merge_exception_flags`. Added `_ex` conversion variants returning inexact (and
  invalid+indefinite for FIST overflow), latched into `fstat` at store dispatch.
  (Reproduced: `fstps` of 1.2345678901234567 → QEMU fstat PE=0x0020; FIST of 2.5
  → PE; FIST m16 of 100000 → IE + 0x8000.) Locked by `tx_storeflags`.
- **[med] arithmetic under non-default RC/PC** — the datapath was hard-wired to
  RNE/64-bit and silently ignored `fctrl`. **Fixed RC fully** (round-pack now
  takes the RC field; toward-zero/+inf/-inf verified bit-exact for all of add/sub/
  mul/div/sqrt incl. the signed-zero cancellation cases). **PC (precision)** other
  than 64-bit is now a DEFERRED Tier-3 corner that **HALTs loudly** at the
  arithmetic op (rather than silently mis-rounding). (Reproduced: 10/3 under RC=11
  matches QEMU; PC=53-bit arithmetic correctly produces a length-mismatch FAIL,
  not a false pass.) Locked by `tx_round`.
- **[low] FDIV by zero / 0÷0 / FSQRT of a negative** — `fx_div` divided by mb=0
  (X in sim) and `fx_sqrt` of a negative returned sqrt(|x|) with a forced-positive
  sign. With masked exceptions QEMU produces: x/0 → signed Inf + ZE; 0/0 →
  real-indefinite QNaN (0xffff_c000000000000000) + IE; sqrt(−x) → real-indefinite
  QNaN + IE + C2; sqrt(−0) → −0 + C2. Implemented all four bit-exact (guarded the
  datapath against /0 and negative-sqrt as defense-in-depth). Locked by
  `tx_special`. (`helper_fsqrt` also clears 0x4700 and sets C2 whenever ST0's sign
  bit is set — reproduced and matched.)
- **[low] FCOM vs FUCOM #IA on NaN** — one shared `fcom_codes` produced correct
  C-codes but never raised IE. QEMU's signaling compares (FCOM/FCOMP/FCOMPP/FTST/
  FICOM, `floatx80_compare`) raise IE on ANY NaN; the quiet compares (FUCOM/
  FUCOMP/FUCOMPP, `floatx80_compare_quiet`) raise IE only on a SIGNALING NaN.
  Added SNaN/QNaN classifiers and a per-op signaling flag; IE latched accordingly.
  (Reproduced: FCOM vs QNaN → IE; FUCOM vs QNaN → no IE; FCOM/FUCOM vs SNaN(m80)
  → IE both.) Locked by `tx_fcomnan`.

**DEFERRED — loud HALT, never a false pass** (confirmed each retires the
preceding ops then STOPS, yielding a length-mismatch FAIL — verified for FSIN,
FRNDINT, FXTRACT, FPREM):
- **Transcendentals** FSIN/FCOS/FSINCOS/FPTAN/FPATAN/F2XM1/FYL2X/FYL2XP1 — QEMU
  computes these with its own approximation; matching it bit-exact ≠ matching a
  real Pentium, so deferred to a later ulp-tolerance oracle. HALT.
- **BCD** FBLD/FBSTP; **environment/state** FSAVE/FRSTOR/FLDENV/FNSTENV (28/108-
  byte memory images). HALT.
- **FCMOVcc / FCOMI / FUCOMI** register forms (P6+ extensions, not core P5
  user x87 in the corpus). HALT.
- **Tier-3 numeric ops** FPREM/FPREM1/FRNDINT/FSCALE/FXTRACT. HALT.
- **Non-default PRECISION control (PC ≠ 11 / 64-bit)** at an arithmetic op — the
  datapath implements full extended precision only; rather than silently
  mis-rounding to 53/24-bit, the core HALTs. (RC directed rounding IS supported.)
- **Unmasked numeric exceptions / #MF delivery** — not implemented; the corpus
  keeps exceptions masked (default cw) and avoids faulting operands. FWAIT is a
  no-op (no SE is ever set in the masked corpus).

**Harness:** `run-m3.sh` is the differential gate (per-program `x87:true` via an
optional `"x87"` manifest field; everything else identical to `run-m2.sh`).
`run-m1.sh` was also taught to build any discovered program's ELF/flat
generically from the manifest `src` (mirroring run-m2/run-m3) when the tests
Makefile didn't pre-build it — this enrolls the x87 corpus in the M1 integer gate
too (the x87 programs run as integer streams there and pass), so `make m1` is
green again (it was failing on the auto-discovered x87 dirs before, an
infrastructure gap independent of the RTL).

**How to run:** `make m3` (= `bash verif/run-m3.sh`). For each program discovered
from `verif/tests/**/manifest.json` it builds the ELF, ISA-verifies it, flattens
it, generates the QEMU golden (with `--x87` for x87 programs), runs the RTL TB
(`--x87`, init-ESP from the golden n=0), runs `compare.py --mode func`, and
asserts exit 0 for all.

**Observed result** (`make m3` from a clean TB build, exit 0):

```
    PROGRAM          MODE  RESULT DETAIL
    -------          ----  ------ ------
    smoke            int   PASS   func-equivalent (22 insns max)
    t_bit            int   PASS   func-equivalent (55 insns max)
    t_branch         int   PASS   func-equivalent (43 insns max)
    t_callret        int   PASS   func-equivalent (35 insns max)
    t_carry          int   PASS   func-equivalent (40 insns max)
    t_div            int   PASS   func-equivalent (60 insns max)
    t_ext            int   PASS   func-equivalent (50 insns max)
    t_leave16        int   PASS   func-equivalent (25 insns max)
    t_loop16         int   PASS   func-equivalent (60 insns max)
    t_loop2          int   PASS   func-equivalent (65 insns max)
    t_loop           int   PASS   func-equivalent (78 insns max)
    t_mem            int   PASS   func-equivalent (25 insns max)
    t_mixed          int   PASS   func-equivalent (200 insns max)
    t_moffs          int   PASS   func-equivalent (30 insns max)
    t_mul            int   PASS   func-equivalent (60 insns max)
    t_op16b          int   PASS   func-equivalent (60 insns max)
    t_op16           int   PASS   func-equivalent (60 insns max)
    t_op8            int   PASS   func-equivalent (64 insns max)
    t_partial        int   PASS   func-equivalent (44 insns max)
    t_prefix         int   PASS   func-equivalent (44 insns max)
    t_rep            int   PASS   func-equivalent (85 insns max)
    t_rotate         int   PASS   func-equivalent (68 insns max)
    t_setcc          int   PASS   func-equivalent (65 insns max)
    t_shift          int   PASS   func-equivalent (67 insns max)
    t_shld           int   PASS   func-equivalent (44 insns max)
    t_stack          int   PASS   func-equivalent (45 insns max)
    t_string         int   PASS   func-equivalent (50 insns max)
    t_unary          int   PASS   func-equivalent (80 insns max)
    tx_addsub        x87   PASS   func-equivalent (80 insns max)
    tx_chain         x87   PASS   func-equivalent (70 insns max)
    tx_cmp           x87   PASS   func-equivalent (45 insns max)
    tx_const         x87   PASS   func-equivalent (35 insns max)
    tx_ctl           x87   PASS   func-equivalent (30 insns max)
    tx_fcomnan       x87   PASS   func-equivalent (50 insns max)
    tx_fxam          x87   PASS   func-equivalent (40 insns max)
    tx_ldst          x87   PASS   func-equivalent (25 insns max)
    tx_muldiv        x87   PASS   func-equivalent (90 insns max)
    tx_round         x87   PASS   func-equivalent (45 insns max)
    tx_special       x87   PASS   func-equivalent (45 insns max)
    tx_sqrt          x87   PASS   func-equivalent (70 insns max)
    tx_stack         x87   PASS   func-equivalent (33 insns max)
    tx_storeflags    x87   PASS   func-equivalent (40 insns max)

    totals: 42 PASS / 0 FAIL / 42 total
M3 GATE: PASS — every program is func-diff-clean vs QEMU (exit 0).
```

**Honest coverage statement:** M3 is the x87 **functional core** — the register
stack, status/control/tag words, and a `floatx80` datapath that is **bit-exact vs
QEMU** for data movement and **normal-operand** arithmetic under the default
control word, plus directed rounding (RC) and the masked special-operand cases
above. **Transcendentals, BCD, FSAVE/FRSTOR/FLDENV/FNSTENV, unmasked exceptions
(#MF), the P6 FCMOV/FCOMI forms, the Tier-3 numeric ops (FPREM/FRNDINT/FSCALE/
FXTRACT), and non-default precision control all HALT loudly** — never silently
mis-executed. No pipeline / U-V pairing / branch prediction / cycle accuracy yet
(M4/M5); M3 is functional-only.

**Next:** M4 — dual-issue U/V pipeline + instruction pairing + branch prediction
(the first CYCLE milestone: µbench CPI/pairing/mispredict matched against
`p5model`).

### 2026-06-02 — M2 complete (user-mode integer ISA completeness, func-equiv vs QEMU)

Extended the M1 single-issue core to the **complete user-visible integer ISA**
(`docs/m2-isa-spec.md`). **Every program in the corpus (M0/M1 baseline + the M2
corpus = 28 programs) is func-diff-clean vs QEMU user-mode** (`compare.py --mode
func` exit 0, no length mismatch). Gate: `make m2` (exit 0). `make m1` and
`make m0-smoke` still pass; RTL stays lint-clean (`verilator --lint-only -Wall
-Wno-DECLFILENAME -Wno-UNUSED`, exit 0).

**Instruction groups now implemented** (on top of the M1 ALU/MOV/LEA/PUSH/POP/
INC/DEC/TEST/Jcc/JMP subset): shifts & rotates `D0/D1/D2/D3`, `C0/C1` (ROL/ROR/
RCL/RCR/SHL/SHR/SAL/SAR, count `& 0x1f`, count==0 ⇒ no flag change) and
`SHLD/SHRD` (`0F A4/A5/AC/AD`, register destination); MUL/IMUL/DIV/IDIV
(`F6/F7 /4../7`, EDX:EAX), two-/three-operand IMUL (`0F AF`, `69`, `6B`);
MOVZX/MOVSX (`0F B6/B7/BE/BF`), NEG/NOT (`F6/F7 /2,/3`), INC/DEC r/m
(`FE/FF /0,/1`), CDQ/CWDE/CBW (`99/98`, `66 98`), XCHG (`86/87`, `90+r` incl.
`90`=NOP), SETcc (`0F 90+cc`), BSWAP (`0F C8+r`); bit tests BT/BTS/BTR/BTC
(`0F A3/AB/B3/BB` reg, `0F BA /4../7` imm) and BSF/BSR (`0F BC/BD`); stack/flags
PUSH/POP imm & r/m, PUSHA/POPA (`60/61`), PUSHF/POPF (`9C/9D`, user-mode POPF
mask), LAHF/SAHF (`9F/9E`), LEAVE (`C9`); string ops MOVS/STOS/LODS/SCAS/CMPS
(`A4..A7`, `AA..AF`) with REP/REPE/REPNE (`F3/F2`) and direction from DF
(`STD/CLD` = `FD/FC`); control/loop LOOP/LOOPE/LOOPNE (`E2/E1/E0`), JCXZ/JECXZ
(`E3`), near CALL `rel32` (`E8`) + RET (`C3`, `C2 iw`), near CALL/JMP r/m
(`FF /2,/4`); and the carry-flag trio STC/CLC/CMC (`F9/F8/F5`, added this phase).

**Prefix machine + partial-register handling.** A combinational prefix scanner
consumes a run of up to four legacy prefixes (`66` operand-size, `67`
address-size, `2E/36/3E/26/64/65` segment, `F0` LOCK, `F2/F3` REP) and feeds the
correct opcode + length downstream; segment/LOCK are functional no-ops in the
flat user model. **Partial-register semantics** route through a single
`reg_read`/`reg_merge` pair: an 8-bit write updates `[7:0]` (or `[15:8]` for
AH..BH) preserving the rest; a `66`-prefixed 16-bit write updates `[15:0]` and
**preserves `[31:16]`**; flags are computed at the operand width (SF=bit7/15/31,
PF on the low byte, CF/OF at the width boundary). The decoder maps AH..BH
(encoded index 4..7) to the physical GPR so every datapath site uses
`gpr[d_*_reg]` directly.

**EFLAGS undefined-bit masking.** `verif/diff/tracefmt.py::EFLAGS_UNDEFINED`
already carried the M2 cases (MUL/IMUL SF/ZF/AF/PF; DIV/IDIV all six;
SHL/SHR/SAR/SHLD/SHRD OF+AF; ROL/ROR/RCL/RCR OF; BT* OF/SF/AF/PF; BSF/BSR
CF/OF/SF/AF/PF; AAA/AAS/AAM/AAD/DAA/DAS). **No new entries were required this
phase:** the instructions fixed/added below either touch no flags (MOVZX/MOVSX,
MOV-moffs8, LEAVE, LOOP/JCXZ) or set only deterministic, *defined* flags
(STC/CLC/CMC set CF exactly; their masking-table absence is correct so CF is
compared in full), or their undefined bits are already covered by the existing
`bt`/`bsf`/`bsr` keys (the new 16-bit BT*/BSF/BSR forms reuse them). The table is
deliberately minimal so the gate cannot hide a real RTL bug.

**New test corpus** (added this phase; discovered by the gate via
`manifest.json`). The bulk of the M2 groups above were already covered by the
inherited corpus (`t_bit`, `t_callret`, `t_div`, `t_ext`, `t_loop2`, `t_mixed`,
`t_mul`, `t_op16`, `t_op8`, `t_partial`, `t_prefix`, `t_rep`, `t_rotate`,
`t_setcc`, `t_shift`, `t_shld`, `t_stack`, `t_string`, `t_unary`). The five new
programs regression-lock the adversarial-review findings the corpus did **not**
hit:
- `t_op16b` — `66`-prefixed MOVZX/MOVSX/BSF/BSR/BT*/BTS/BTR/BTC: proves the
  destination's `[31:16]` is preserved and the bit index is mod 16 (not mod 32).
- `t_carry` — STC/CLC/CMC, with the resulting CF consumed by ADC/RCL.
- `t_moffs` — MOV AL,moffs8 (`A0`) and MOV moffs8,AL (`A2`), hand-encoded.
- `t_leave16` — `66 C9` 16-bit LEAVE (preserve EBP[31:16], ESP += 2).
- `t_loop16` — `67`-prefixed LOOP/LOOPE/JCXZ using CX (preserve ECX[31:16]).

**Adversarial review — what was found and fixed** (every finding reproduced
against QEMU with a tiny program before fixing, and each fix re-verified
diff-clean; for the high findings a negative test — reverting the fix —
confirmed the new regression program FAILS, proving the lock):
- **MOVZX/MOVSX 16-bit (`66 0F B6/B7/BE/BF`)** [high, real]: `K_EXT` committed
  the full 32-bit result, ignoring `q_w`; the `66` form must preserve `[31:16]`.
  Fixed to `reg_merge(...,q_w,...)`. (Reproduced: `66 0F B6 C3` gave RTL
  `eax=0x000000a5` vs QEMU `0xdead00a5`.)
- **BSF/BSR 16-bit (`66 0F BC/BD`)** [high, real]: scanned all 32 bits, computed
  ZF from 32 bits, wrote a full-32 index. Fixed to scan/ZF/merge at `q_w`.
- **BT/BTS/BTR/BTC 16-bit reg/imm (`66 0F A3/AB/B3/BB`, `66 0F BA /4..7`)**
  [high, real]: bit index was always masked mod 32 and modify forms wrote full
  32. Fixed: index mod 16 for `q_w==2`, modify via `reg_merge`.
- **STC/CLC/CMC (`F9/F8/F5`)** [high, real]: not decoded → `d_unknown` → HALT.
  Added decode + a CF-only update arm (no other flags change).
- **MOV AL,moffs8 / MOV moffs8,AL (`A0/A2`)** [med, real]: only the 16/32-bit
  `A1/A3` were decoded; the 8-bit absolute forms HALTed. Added both (8-bit,
  preserve `[31:8]` on load).
- **16-bit near CALL/RET/LEAVE (`66 E8/C3/C2/C9`)** [low, real]: hardcoded 32-bit
  width. Now width-aware: 16-bit CALL pushes a 2-byte next-IP, RET pops 2 bytes,
  LEAVE pops 16-bit BP — all adjust ESP by 2 and (CALL/RET) truncate EIP to 16
  bits, exactly matching QEMU. LEAVE-16 is regression-tested (`t_leave16`);
  CALL-16/RET-16 are implemented but not testable in a continuing flat program
  (the 16-bit-truncated target lands at an unmapped low address and faults in
  **both** models — confirmed against QEMU), so they are documented, not gated.
- **`67`-prefixed JECXZ/LOOP/LOOPE/LOOPNE** [low, real]: always used the full
  32-bit ECX. Now the count register is CX (low 16, preserve `[31:16]`) under
  `0x67`. Regression-tested (`t_loop16`).

**Still HALTs (deliberately deferred; loud HALT, never mis-execute)** — confirmed
the core stops cleanly (retires nothing past the unsupported opcode) rather than
corrupting state:
- **Memory-operand BT/BTS/BTR/BTC and SHLD/SHRD** (the bit-string memory addressing
  and the memory-RMW shift-double): marked `d_unknown` → HALT. Genuine ISA forms
  but uncommon (compilers rarely emit them); deferred to a later milestone.
- **ENTER (`C8`)** — spec explicitly defers it ("LEAVE at least"); HALTs.
- **System / privileged ops, far CALL/RET, segment-load, paging/TLB** — out of
  M2 scope by design (need a system-mode oracle); these are **M2S**.

**How to run:** `make m2` (= `bash verif/run-m2.sh`). It builds the RTL TB, then
for each program discovered from `verif/tests/**/manifest.json` it builds the ELF
(`gcc -m32 -nostdlib -static`), ISA-verifies it (`tools/isa_verify.py`, pure P5),
flattens it, generates the QEMU golden (gdbstub), runs the RTL TB with init-ESP
from the golden n=0, runs `compare.py --mode func`, and asserts exit 0 for all;
prints a per-program table and exits 0 only if all pass.

**Observed result** (`make m2` from a clean TB build, exit 0):

```
    PROGRAM          RESULT DETAIL
    -------          ------ ------
    smoke            PASS   func-equivalent (22 insns max)
    t_bit            PASS   func-equivalent (55 insns max)
    t_branch         PASS   func-equivalent (43 insns max)
    t_callret        PASS   func-equivalent (35 insns max)
    t_carry          PASS   func-equivalent (40 insns max)
    t_div            PASS   func-equivalent (60 insns max)
    t_ext            PASS   func-equivalent (50 insns max)
    t_leave16        PASS   func-equivalent (25 insns max)
    t_loop16         PASS   func-equivalent (60 insns max)
    t_loop2          PASS   func-equivalent (65 insns max)
    t_loop           PASS   func-equivalent (78 insns max)
    t_mem            PASS   func-equivalent (25 insns max)
    t_mixed          PASS   func-equivalent (200 insns max)
    t_moffs          PASS   func-equivalent (30 insns max)
    t_mul            PASS   func-equivalent (60 insns max)
    t_op16b          PASS   func-equivalent (60 insns max)
    t_op16           PASS   func-equivalent (60 insns max)
    t_op8            PASS   func-equivalent (64 insns max)
    t_partial        PASS   func-equivalent (44 insns max)
    t_prefix         PASS   func-equivalent (44 insns max)
    t_rep            PASS   func-equivalent (85 insns max)
    t_rotate         PASS   func-equivalent (68 insns max)
    t_setcc          PASS   func-equivalent (65 insns max)
    t_shift          PASS   func-equivalent (67 insns max)
    t_shld           PASS   func-equivalent (44 insns max)
    t_stack          PASS   func-equivalent (45 insns max)
    t_string         PASS   func-equivalent (50 insns max)
    t_unary          PASS   func-equivalent (80 insns max)

    totals: 28 PASS / 0 FAIL / 28 total
M2 GATE: PASS — every program is func-diff-clean vs QEMU (exit 0).
```

**Honest coverage statement:** M2 covers the user-mode integer ISA a flat QEMU
user-mode program can execute and reproduce bit-exactly. It is **NOT** yet
"decoder-exhaustive vs XED/Capstone" — that audit remains ongoing. Memory-operand
BT*/SHLD/SHRD and ENTER are genuine integer forms that currently HALT (deferred,
not mis-executed). System mode (segmentation/paging/TLB/interrupts/SMM), far
CALL/RET, and privileged ops are out of scope by design and move to **M2S**. No
pipeline / U-V pairing / branch prediction / caches yet (M4/M5); M2 is
functional-only (no cycle accuracy).

**Next:** M3 — x87 FPU (x87 corpus vs SoftFloat/MPFR + QEMU).

### 2026-06-02 — M1 complete (real single-issue integer core, func-equiv vs QEMU)

Replaced the M0 NOP-stub core with a **real single-issue, in-order, multi-cycle
functional integer core** (`rtl/core/intcore.sv`) that fetches IA-32 bytes over
the `mem_*` bus, decodes the M1 integer subset, executes one instruction at a
time, and reports post-commit architectural state through the single
`vtm_retire` DPI point. **Every program in the corpus (smoke + the three M1
tests) is now func-diff-clean vs QEMU** (`compare.py --mode func` exit 0, no
length mismatch).

**Core structure** (a coherent functional FSM, one instruction at a time):
`S_RESET → S_FETCH` (4 word reads → a 16-byte instruction window) `→ S_DECODE`
(combinational length + operand + ModR/M/SIB/disp decode) `→ S_LOAD` (memory
source/pop) `→ S_EXEC` (ALU + EFLAGS) `→ S_STORE` (push / mov-to-mem / RMW)
`→ S_RETIRE` (commit GPR/EFLAGS/EIP, pulse `retire_valid`) `→ S_HALT` (on
`int $0x80`, and now also on any opcode outside the M1 subset).

**Init-state handling:** the TB (playing the loader) drives `init_eip`/`init_esp`
at reset; the core latches them plus constant segment selectors (CS=0x23,
SS/DS/ES/GS=0x2b, FS=0) and EFLAGS reset 0x202 (bit1 + IF). Segments never change
in the M1 corpus — the core just reports the constants.

**Instruction subset implemented:** MOV (`B8+rd`, `89/8B /r`, `C7 /0`, and the
`A1`/`A3` EAX-moffs32 absolute forms — added this phase), LEA (`8D`), PUSH/POP
(`50+rd`/`58+rd`), the full ALU group ADD/OR/ADC/SBB/AND/SUB/XOR/CMP in all
standard forms (`/r` both directions incl. memory operands, `eAX,imm32`,
`81 /digit id`, `83 /digit ib` sign-extended), INC/DEC (`40+rd`/`48+rd`),
TEST (`85 /r`, `A9 id`), NOP (`90`), JMP `rel8`/`rel32`, the full `Jcc` `tttn`
condition set (`70+cc` and `0F 80+cc`), and `INT 0x80` (halt). EFLAGS (CF/PF/AF/
ZF/SF/OF) match QEMU exactly — the comparator compares them in full (no
undefined-flag ops in the corpus). General 32-bit ModR/M + SIB + disp8/disp32
addressing is decoded.

**New test corpus** (`verif/tests/**`, discovered by the gate via `manifest.json`):
- `t_branch` — Jcc condition-code coverage (je/jne/jl/jge/jg/jb/ja) with
  signed/unsigned operand pairs that diverge, plus never-taken sentinels.
- `t_loop` — counted loops / back-edges: dec/inc + cmp/test + jne/jl, each branch
  taken (per iteration) and finally not-taken (exit).
- `t_mem` — AGU coverage: store/reload via absolute disp32, `[reg]`, base+disp8,
  and SIB, then ALU on the reloaded values.

**Adversarial review — what was found and fixed (all reproduced before fixing):**
- **AF computed at the wrong bit position** (high; failed `t_loop` n=5, `t_branch`
  n=33). The six `flags_next` arms computed `af = a[3]^b[3]^res[3]` (carry *into*
  bit 3) instead of the architectural carry *out of* bit 3 = `a[4]^b[4]^res[4]`.
  Verified ~50% mismatch vs the true AF on random ADD/SUB operands; fixed and
  re-verified to 0 mismatches over 200k random cases each. Affects ADD/ADC/SUB/
  SBB/CMP/INC/DEC.
- **MOV moffs32 (`A1`/`A3`) decode gap** (failed `t_mem` n=4 + length mismatch).
  GAS emits `A3` for `movl %eax,<abs32>` (5 bytes); the decoder had no case and
  mis-lengthed it to 1 byte via `default`, desyncing the fetch stream. Added
  `A1` (MOV EAX,moffs32 load) and `A3` (MOV moffs32,EAX store).
- **ALU with a MEMORY SOURCE operand** (high; latent — not in corpus). The EXEC
  operand mux collapsed both ALU inputs onto `mem_load_data`, so `add (%edx),%eax`
  computed `mem OP mem` and dropped the register. Added a `d_mem_dst` decode flag
  distinguishing "memory is the source" from "memory is the RMW destination"; the
  mux now feeds `src_a=gpr[dst]`, `src_b=mem` for memory-source forms.
- **ALU with a MEMORY DESTINATION (read-modify-write)** (high; latent). Same root
  cause from the other direction: `add %eax,(%edx)` stored `mem OP mem` instead of
  `mem OP reg`. The `d_mem_dst` flag fixes `src_b` to `gpr[src]`.
- **`pop %esp`** (med; latent). Two NBAs to `gpr[ESP]` (`<= mem_load_data` then
  `<= ESP+4`) raced; the +4 won, discarding the popped value. Now the ESP bump is
  suppressed when the pop destination IS ESP, so the loaded value wins (Intel SDM).
- **Silent mis-decode of out-of-subset opcodes** (low). The `default`/`0F`-non-Jcc
  arms advanced 1–2 bytes silently. Added a `d_unknown` flag that routes to
  `S_HALT` (a LOUD stop, no retire) so an unsupported opcode can't corrupt the
  fetch stream. The implemented subset is unaffected.

All four latent datapath fixes (mem-source ALU, RMW, `pop %esp`, and the AF
exposing cases `add %eax,%eax`/`inc %eax`) were verified func-equivalent vs QEMU
with dedicated micro-tests before being declared fixed.

**False positives / out-of-scope (dispositioned, not "fixed"):**
- **Prefix consumption** (low): the decoder handles only a single `0F` for the
  two-byte Jcc; other prefixes (0x66/0x67/seg/F2/F3) are not consumed. The M1
  corpus contains no prefixes (all 32-bit default forms), so this is documented
  M1 scope, not a corpus bug. (M2 extends the decoder toward exhaustiveness.)
- **8-bit accumulator / other unimplemented opcodes** (low): out of the M1 subset
  per spec; now guarded by `d_unknown → S_HALT` rather than silently mis-decoded.

**HARNESS/SPEC fix (init ESP):** the spec-documented `--init-esp 0x40c348d0` was
**stale** — QEMU's linux-user loader places the initial stack pointer for these
static binaries at `0x40c34910` for smoke (and a slightly different value per
program, because argv[0] = the ELF path length varies). The literal `0x40c348d0`
made *every* program (incl. smoke) diverge at n=0 on ESP; the core is correct (it
latches whatever ESP it is given). The M1 gate now derives each program's init
ESP from its golden's n=0 record (environment-independent, and exactly the spec's
intent that "the testbench, playing the loader, establishes the init state");
`docs/m1-core-spec.md` and the TB default were corrected to `0x40c34910`.

**How to run:** `make m1` (= `bash verif/run-m1.sh`). It builds the corpus + RTL
TB, discovers every program from `verif/tests/**/manifest.json`, generates each
QEMU golden, runs the RTL TB (init ESP from the golden n=0), runs
`compare.py --mode func`, asserts exit 0 for all, and prints a per-program table.
Exits 0 only if all pass. RTL stays lint-clean (`verilator --lint-only -Wall
-Wno-DECLFILENAME -Wno-UNUSED`, exit 0).

**Observed result** (`make m1` from a clean TB build, exit 0):

```
    PROGRAM      RESULT DETAIL
    -------      ------ ------
    smoke        PASS   func-equivalent (22 insns max)
    t_branch     PASS   func-equivalent (43 insns max)
    t_loop       PASS   func-equivalent (78 insns max)
    t_mem        PASS   func-equivalent (25 insns max)
M1 GATE: PASS — every program is func-diff-clean vs QEMU (exit 0).
```

`make m0-smoke` still exits 0 (the M0 infrastructure gate is met; with a real
core the smoke func compare now reports EQUIVALENT, which the M0 script treats as
a benign WARN and still passes).

**Honest coverage statement:** M1 implements an integer **SUBSET** sufficient for
the corpus and built to extend cleanly. It is **NOT** yet "decoder-exhaustive vs
XED/Capstone" (that remains ongoing, toward M2). There is **no** pipeline, U/V
pairing, branch prediction, or caches/TLB yet — those are M4/M5; cycle accuracy
is out of M1 scope (func-mode only). Correct architectural state on the integer
subset is the only M1 claim, and it is met.

**Next:** M2 — full integer ISA + memory + paging/segmentation (ISA arch corpus
diff-clean), extending the decoder toward exhaustive XED/Capstone coverage.

### 2026-06-02 — M0 bootstrap complete (infrastructure proven end-to-end)

Built the full M0 differential-testing skeleton — six components plus an
end-to-end integration runner — and ran the smoke pipeline cleanly from a
clean tree. **M0 proves the *infrastructure*, not functional correctness:** the
RTL is still a NOP stub, so the functional comparator is *expected* to diverge.

**Components landed** (all build/run in isolation, then wired together):
- **Producer A — golden FUNC trace** (`verif/qemu-trace/gen_trace.py`): drives
  `qemu-i386 -g <port>` over the GDB RSP, single-steps, and emits post-commit
  architectural state as a `mode:"func"` `.vtrace` (pure python3 stdlib; imports
  the shared `verif/diff/tracefmt.py`).
- **Producer B — golden CYCLE trace** (`verif/qemu-plugins/p5trace.c`): a TCG
  plugin (same U/V cycle model as the harness `p5model.c`) emitting retire-order
  PC + cumulative `cyc` + pipe/pairing. Builds to `build/p5trace.so`.
- **RTL skeleton** (`rtl/`): `ventium_top` + all PLAN §6 block stubs; the M0
  NOP-stub core boots reset and retires a fixed canned sequence via the
  `vtm_retire` DPI callback (`rtl-interface.md` §2).
- **Producer C — Verilator C++ TB** (`verif/tb/`): implements `vtm_retire`,
  preloads the flat image, services the M0 bus, and emits the RTL `mode:"func"`
  `.vtrace`.
- **Consumer — comparator** (`verif/diff/compare.py`): diffs A-vs-C (func) and
  B-vs-C (cycle); exit `0`=equivalent, `1`=divergence, `2`=malformed.
- **Test corpus** (`verif/tests/`): the `smoke` program (24 static / 22 retired
  i586-base instructions, no undefined-EFLAGS ops) + `elf2flat.py` loader and a
  manifest (`load_addr`/`entry`=`0x08048000`, `max_insn`=22).
- **Integration runner** (`verif/run-m0-smoke.sh`, invoked by `make m0-smoke`):
  builds corpus + plugin + TB, generates both golden traces, runs the TB,
  validates every `.vtrace` with `tracefmt.read_trace`, and runs the comparator
  in both modes — capturing (not aborting on) the comparator's exit code.

**How to run:** `make m0-smoke` (from the repo root). Artifacts land in
`build/m0/{qemu_func,qemu_cycle,rtl_func}.vtrace`.

**Observed end-to-end result** (`make m0-smoke` from a clean tree, exit 0):
- `qemu_func`: well-formed FUNC trace, 21 records (n=0..20, first pc=0x08048000).
  *(22 retired; the final `int $0x80` exit isn't emitted as a post-state row.)*
- `qemu_cycle`: well-formed CYCLE trace, 22 records (cyc 0..46, pairs=8, CPI≈2.09).
- `rtl_func`: well-formed FUNC trace, 16 records (NOP stub, n=0..15).
- FUNC compare (A vs C) — the EXPECTED coherent divergence:
  `RESULT: DIVERGENT` → `n=0 pc=0x08048000 field=eax: expected(A)=0x11111111
  got(C)=0x00000000` (golden `movl $0x11111111,%eax` vs stub's zeroed eax);
  `func exit=1`. The smoke program is longer than the stub's canned sequence, so
  the comparator also notes the length mismatch (A=21 vs C=16).
- CYCLE path is exercised by self-diffing the golden cycle trace (no RTL cycle
  DUT exists until M4): `RESULT: EQUIVALENT`, `cycle exit=0`.

This confirms the clock/reset/DPI/trace path, the three producers' formats, the
manifest→loader→TB seam, and the comparator all line up. **No integration bugs
required fixing** — the pinned `trace-format.md`/`rtl-interface.md` contracts and
the single-source-of-truth `tracefmt.py` held: DPI signature
(`ventium_pkg.sv` ↔ `dpi_retire.cpp`), field names/hex formatting, and the
register layout all matched on the first wired run.

**Next:** M1 — replace the NOP stub with a real decoder + single-issue integer
core, and turn the func comparator green on the smoke corpus (decoder matches
Capstone; integer ISA diff-clean vs QEMU). For a full match M1 must also align
the TB's reset ESP with QEMU's linux-user initial ESP (`esp=0x40c34900` in the
current golden trace) — see the corpus notes on push/pop.

### 2026-06-02 — Planning complete
- Read the reference library (`REF.md`, `MANIFEST.md`, `00-index/`) and the
  existing QEMU golden-model harness (`07-p5-emulation-harness/`).
- Locked target: **P54C, non-MMX, single core, L1-only, no FRC** (per REF.md
  practical recommendation; matches the existing harness).
- Wrote [`PLAN.md`](PLAN.md): scope & honest-fidelity statement, target µarch
  parameters (5-stage U/V integer pipe, 256-entry/4-way BTB, 8-stage FPU, 8 KB
  2-way split L1, 64-bit bus), reference map, Verilator+QEMU differential
  verification strategy, repo layout, 10-block RTL decomposition, and milestones
  M0–M6 gated on REF.md's five success layers.
- **Next:** start M0 — create `rtl/`, `verif/`, `tools/`, `docs/` skeleton; define
  the golden-trace record format; write the QEMU golden-trace plugin (sibling to
  `p5model.c`); stand up the Verilator testbench shell + trace comparator.
