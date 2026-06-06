# M3 — x87 FPU spec

M3 (PLAN §7) adds the **x87 floating-point unit** to the core and verifies it
**diff-clean vs QEMU** on the x87 architectural state. Builds on M1/M2 (the
integer core is unchanged). This is the hardest functional milestone: 80-bit
extended precision, the FP stack, and the status/control/tag words.

## Verified prerequisites (already in place)

- **Golden x87 trace works.** `gen_trace.py --x87` now reads the i387 g-packet
  block correctly (the tail-anchor fix, commit c39905b): `fld1` → st0 =
  `0x3fff8000000000000000` (1.0), `fldpi` → π, `fstat` TOP field tracks the
  stack. Validated.
- **QEMU user-mode reports `fop`/`fiseg`/`fioff`/`foseg`/`fooff` = 0** (no FP
  instruction/data-pointer tracking in linux-user). So the RTL just reports 0 for
  those — no fip/fdp bookkeeping needed.
- **`fctrl` resets to `0x037f`** (RC=00 round-nearest, PC=11 64-bit precision,
  all six exception masks set). The core initializes the control word to this.
- The comparator compares the full x87 set when both traces declare `x87:true`
  (`tracefmt.func_compare_keys(x87=True)` = st0..st7, fctrl, fstat, ftag, fop,
  fioff, fooff, fiseg, foseg). Since the pointer fields are 0, the live state to
  match is **st0..st7, fctrl, fstat, ftag**.

## Scope (tiers — be honest about what's gated vs deferred)

The arithmetic must match **QEMU's softfloat `floatx80`** bit-exactly. That is
very achievable for data movement and for normal-operand arithmetic with the
default control word; it is genuinely hard for some edge/rounding corners and
effectively impossible (against QEMU) for transcendentals. So M3 is tiered:

- **Tier 1 — HARD GATE (must pass, bit-exact):** the x87 register stack model
  (8×80-bit + TOP), status word (TOP, condition codes C0–C3, the C1 stack-fault
  bit), control word (FLDCW/FNSTCW), tag word (match QEMU's reported convention —
  see below), and these ops:
  - Load/store/move: `FLD`/`FST`/`FSTP` (m32/m64/m80 + `st(i)`), `FILD`/`FIST`/
    `FISTP` (m16/m32/m64), `FXCH`, `FFREE`, `FINCSTP`/`FDECSTP`, `FNOP`.
  - Constants: `FLDZ FLD1 FLDPI FLDL2E FLDL2T FLDLG2 FLDLN2`.
  - Sign/abs: `FABS`, `FCHS`.
  - Compare (set C0/C2/C3): `FCOM`/`FCOMP`/`FCOMPP`, `FUCOM`/`FUCOMP`/`FUCOMPP`,
    `FTST`, `FXAM`, `FICOM`/`FICOMP`.
  - Status/control: `FNSTSW ax`/`m16`, `FNSTCW`/`FLDCW`, `FNINIT`/`FINIT`,
    `FNCLEX`/`FCLEX`, `FWAIT`.
- **Tier 2 — TARGET (gated on normal operands, default control word):** core
  arithmetic `FADD/FSUB/FSUBR/FMUL/FDIV/FDIVR` (+ `p`/`ip` and memory/int forms
  `FIADD…`), `FSQRT`. Round-to-nearest-even, 64-bit precision. Must be bit-exact
  vs QEMU on **normal, non-exceptional** operands (the gated corpus uses these).
- **Tier 3 — best-effort, documented:** non-default rounding (RC) and precision
  (PC) control, signed zeros / infinities / NaN propagation, denormals, `FPREM`/
  `FPREM1`, `FRNDINT`, `FSCALE`, `FXTRACT`. Cover what passes; document divergences.
- **DEFERRED — loud HALT, never fake:**
  - **Transcendentals** `FSIN FCOS FSINCOS FPTAN FPATAN F2XM1 FYL2X FYL2XP1`:
    QEMU computes these with its own approximation; matching it bit-exact ≠
    matching a real Pentium, so deferred to a later milestone with an
    ulp-tolerance oracle (REF.md §8). HALT for now.
  - Environment/state `FSAVE/FRSTOR/FLDENV/FNSTENV` (28/108-byte memory images)
    — deferred; HALT. (BCD `FBLD`/`FBSTP` were deferred here but are now
    IMPLEMENTED in M10 — see below — and are NO LONGER in the loud-HALT set.)
  - x87 numeric exceptions actually *raised* (unmasked → #MF): the corpus keeps
    exceptions masked (default cw) and avoids faulting operands.

## RTL ↔ TB x87 trace hook (infrastructure to build)

`rtl-interface.md` §2 reserved a second DPI import for FP. Define and wire it:

```systemverilog
import "DPI-C" context function void vtm_retire_x87(
    input longint unsigned n,          // SAME retire seq as the matching vtm_retire
    input int      unsigned fctrl, input int unsigned fstat, input int unsigned ftag,
    input longint unsigned st0_lo, input shortint unsigned st0_hi,  // 80-bit = 64 lo + 16 hi
    ... st1..st7 ...);
```
- The core calls `vtm_retire` (integer state, unchanged) **and**, on the same
  retirement, `vtm_retire_x87` with the post-commit x87 state. The TB
  (`dpi_retire.cpp`) buffers both and emits ONE func record carrying the x87
  fields; the RTL trace header must then declare `x87:true`. Use the 80-bit
  canonical `floatx80` layout (sign|exp in [79:64], mantissa in [63:0]) — the
  SAME encoding `gen_trace` now produces, so hex strings compare directly.
- Pass each 80-bit st reg as a 64-bit mantissa + 16-bit sign/exp pair (or a packed
  vector) — pick one and keep TB+pkg consistent.
- fop/fiseg/fioff/foseg/fooff: emit 0 (matches QEMU user-mode).

**ftag convention:** QEMU's user-mode gdbstub reported `ftag = 0x0000` in probes.
The infra/harness phase MUST confirm QEMU's exact ftag behavior across cases
(empty/full stack, FFREE, after pops) and the RTL reproduces *whatever QEMU
reports* — do not assume the architectural 2-bit-per-reg tag if QEMU abridges it.

## Verification (the M3 gate)

Same multi-program differential mechanism; goldens generated with `--x87`, RTL
trace declares `x87:true`, `compare.py --mode func` compares the x87 fields too.
Integer programs (no x87) keep `x87:false` and are unaffected.
```
gen_trace.py --x87 --elf <p>.elf --out build/m3/<p>_qemu.vtrace --max-insn <N>
tb_ventium --image <p>.flat ... --out build/m3/<p>_rtl.vtrace   # header x87:true
compare.py --mode func build/m3/<p>_qemu.vtrace build/m3/<p>_rtl.vtrace   # exit 0
```
**Gate (`make m3` / `verif/run-m3.sh`):** all Tier-1 + Tier-2 x87 programs are
func-diff-clean (exit 0), AND the M0/M1/M2 integer suites stay green (`make m2`
exit 0). Tier-3 coverage and every deferred/HALT item are listed honestly in
PROGRESS. Anything unimplemented HALTs the core — never silently mis-executes.
```

## Deferred x87 — machine-checkable boundary

The "DEFERRED — loud HALT" set above (transcendentals and the FP
environment/state ops; **BCD load/store is now IMPLEMENTED in M10**, see the
note below) was previously asserted only in prose. Per `REVIEW_Jun5.md`
Recommended Step 4 + Limit #2, that coverage boundary is now **machine-checkable**
so it cannot silently rot if a future change accidentally decodes one of those ops.

> **M10 update — BCD `FBLD`/`FBSTP` implemented (no longer deferred).** `DF /4`
> (FBLD) and `DF /6` (FBSTP) now decode to `FX_FBLD`/`FX_FBSTP` and are
> per-record EQUIVALENT vs QEMU (`verif/tests/tx_bcd_ld`, `tx_bcd_st`, both
> `x87:true` in `make verify`): FBLD packed-BCD→floatx80 (exact), FBSTP
> round-to-int→18-digit packed-BCD + sign byte, with PE on inexact rounding and
> the BCD-indefinite image + IE on `|val| >= 1e18` overflow (oracle-pinned to
> QEMU's `helper_fbst_ST0`). The boundary test below uses **FSIN** (still
> deferred), so it is unaffected.

### Verified deferred decode set (against `rtl/core/core.sv`)

Each deferred family reaches a `d_unknown=1'b1` arm in the D8..DF escape decoder
(core.sv ~1840–2007); `d_unknown` then takes the `S_DECODE` default to `S_HALT`
(core.sv ~3139), and the core stops retiring (it never executes or retires the
deferred op, nor anything after it). Confirmed encodings and the arm each hits:

| Family (deferred) | Mnemonics | Encoding | `d_unknown` arm |
|---|---|---|---|
| Transcendentals | `FSIN FCOS FPTAN FPATAN F2XM1 FYL2X FSINCOS FYL2XP1` | `D9 F0..FF` (reg, mod==11) | core.sv:1889 (D9 reg `default`) |
| FP environment | `FLDENV` / `FNSTENV` | `D9 /4` / `D9 /6` (mem) | core.sv:1868 (D9 mem `default`) |
| FP state save/restore | `FRSTOR` / `FNSAVE`/`FSAVE` | `DD /4` / `DD /6` (mem) | core.sv:1955 (DD mem `default`) |

### `tx_deferred_halt` — the loud-HALT pin

`verif/tests/tx_deferred_halt/tx_deferred_halt.s` executes a representative
deferred op (**FSIN**, `D9 FE` — a transcendental; the canonical
"QEMU-computes-an-approximation, real-P54C-microcode-differs" case) bracketed by
sentinels:

```
mov $0xdead0001,%eax   ; PRE  sentinel — MUST retire (boundary reached)
fldpi                  ; normal operand — MUST retire
fsin                   ; DEFERRED — the RTL MUST HALT here (d_unknown -> S_HALT)
mov $0xdead0002,%ebx   ; POST sentinel — MUST NOT retire
mov $1,%eax; xor %ebx,%ebx; int $0x80   ; clean exit — MUST NOT be reached
```

The machine-checkable expectation is that the RTL **HALTs at FSIN** and does not
retire it or anything after it. This is deliberately **not** a differential-vs-
QEMU func test: QEMU has a full x87 and *does* execute FSIN (`helper_fsin`,
`target/i386/fpu_helper.c`), so a `compare.py` run would see a length mismatch —
which is exactly the correct boundary (RTL halts where QEMU continues). The
manifest therefore lives at `tx_deferred_halt/halt/manifest.json` (one level
deeper than the depth-2 path `verify.sh` scans) so the differential corpus does
**not** pull it in, and it is gated instead by the dedicated harness:

```
bash verif/tests/run_x87_boundary.sh   # builds + runs on the RTL, asserts HALT
```

`run_x87_boundary.sh` builds the ELF/flat, runs `tb_ventium --x87`, and asserts
on the RTL trace: (1) the PRE sentinel + `fldpi` retired (boundary reached),
(2) no record at/after the FSIN pc exists (FSIN itself never retired), (3) the
POST sentinel (`ebx=0xdead0002`) never appears, and (4) `tb_ventium` stopped via
quiescence/hang — **not** by hitting `--max-insn` (which would mean the deferred
op was wrongly executed). Any single failure aborts the gate with a precise
diagnostic. FSIN stands in for the whole deferred set at the decode boundary; to
re-pin a different family, swap the deferred op (e.g. `fbld (%eax)` / `fnsave
(%eax)`) and update the manifest `deferred_op` note.

### `tx_fchs_fabs_special` — in-scope sign ops on Inf/NaN (differential)

`FCHS`/`FABS` are **in scope** (Tier-1) and must work on `+inf`/`-inf`/`NaN`,
because the RTL implements them as pure operations on the **sign bit only**:

```
FX_FABS (core.sv:4011):  fp_top_data = {1'b0,    st0[78:0]}   ; clear  bit 79
FX_FCHS (core.sv:4012):  fp_top_data = {~st0[79], st0[78:0]}  ; toggle bit 79
```

Bits 78:0 (exponent + mantissa) pass through verbatim and the `D9 E0`/`D9 E1`
decode (core.sv:1875–1876) does not gate on operand class, so they execute (do
not HALT) for inf/NaN and match QEMU's `helper_fchs`/`helper_fabs` (which also
touch only the sign). `FLD m80` (`FLDT`) pushes the operand verbatim
(core.sv:3985) — an SNaN is loaded **without** being quieted — so the test also
proves FCHS/FABS preserve the SNaN payload. `verif/tests/tx_fchs_fabs_special/`
is a normal differential-vs-QEMU func test (manifest at depth 2, `x87:true`,
joined to the central `make verify` corpus): it loads `+inf`/`-inf`/`+QNaN`/
`-QNaN`/`+SNaN` as m80 and checks the post-op `st0` (full 80-bit floatx80) bit-
exact vs QEMU after each `FABS`/`FCHS`. No RTL change is required for it to pass.
```
