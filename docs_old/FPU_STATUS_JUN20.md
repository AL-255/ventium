# Ventium x87 FPU — Status (2026-06-20)

Snapshot of the FPU after the Jun-19/20 area-shrink + correctness work, the
KV260 board-fit situation, and what's left. Companion to the long-form notes in
the auto-memory `fp-area-shrink.md`.

---

## TL;DR

- **Unified FDIV engine** (`fpu_srt_div`): divide + square-root + remainder now
  run on **one shared radix-4 carry-save datapath** (Pentium FDIV model).
  `fpu_sqrt_iter` removed. Committed `55d7133`.
- **Transcendentals** (`fpatan`/`fyl2x`/`f2xm1`/`fsincos`): multiplies forced to
  **DSP48** + a **shared `mul128` engine** (bit-exact, not CORDIC). Committed `bc4ea28`.
- **`fx_sqrt` pruned** under `VEN_SRT_ITER` (dead — engine handles all real sqrt).
  Committed `71b7824`.
- **Verification GREEN**: `make verify` 97/0; fpu87 thorough **47/47** gated under
  `VEN_SRT_ITER`; all 4 `verif/trsc` core gates bit-exact vs qemu-i386.
- **Board still doesn't fit** at `TRANSCENDENTAL=0` (~126%). Root cause is **FP-
  correctness bloat**, not transcendentals — see §4. The `fx_sqrt` prune is the
  first reclaim; more remains (the spine `fx_round_pack_f` dedup, task #3).
- **One uncommitted WIP hack**: `fx_div_exact` is locally **stubbed** (`q=num>>7`)
  to fit the board — *functionally wrong for extreme-magnitude quotients*. Not a
  real fix; the proper dedup is pending. See §5.

---

## 1. Architecture (current)

| Block | Where | Notes |
|---|---|---|
| FP add/sub/mul | `f_eval` / `f_eval_s1`+`f_eval_s2` (`ventium_x87_pkg.sv`) | `+VEN_FP_PIPE`/`PIPE2`: split front/round, shared rounder on the deferred path |
| FP divide | `fpu_srt_div` (`+VEN_SRT_ITER`) | radix-4 SRT carry-save; `fx_div_exact` is the extreme-quotient combinational fallback |
| FP sqrt | `fpu_srt_div` sqrt mode | radix-4 SRT on the **shared** carry-save datapath; `fx_sqrt` is now dead under `VEN_SRT_ITER` |
| FPREM/FPREM1 | `fpu_srt_div` rem mode (`+VEN_FPREM`) | radix-4 SRT integer-divide on the shared datapath; `fpu_fprem` kept for the `!VEN_SRT_ITER` combinational config |
| FBSTP (→BCD) | `ven_bcd` (`+VEN_BCD_ITER`) | double-dabble (no /10 reciprocal-multiplies) |
| Transcendentals | `fpu_{fpatan,fyl2x,f2xm1,fsincos}` (`+VEN_TRANSCENDENTAL`) | qref/QEMU bit-exact **polynomial** (not CORDIC); now DSP-mapped + shared mul |
| Rounder | `fx_round_pack_f` | inlined at several sites; the denormal/gradual-under/overflow logic (Jun-19) is the area bloat |

Golden reference models: `tools/srt/{srt_model,sqrt_model,rem_model}.py`
(divide / sqrt / rem, each 200k–300k vectors bit-exact vs IEEE/Python `//`,`%`).

---

## 2. The unified FDIV engine (`55d7133`)

One `fpu_srt_div` does div + sqrt + rem on the same radix-4 carry-save adder +
ladder PLA (`fx_srt_pla`) + remainder-sign rounder. `mode` selects:

- **divide** — unchanged radix-4 SRT (preserves the FDIV-bug when `buggy=1`).
- **sqrt** — radix-4 SRT replacing the 208-bit binary-restoring array.
  Normalize radicand to `X∈[1/4,1)` (so `sqrt(X)∈[1/2,1)` fits the SRT range),
  on-the-fly `2R` as the "divisor", **two's-complement** negative initial
  remainder (ones-comp −0 mis-signs the result — the key carry-save gotcha).
  Denormals: `fx_man` doesn't normalize, so the setup `clz`-shifts the radicand.
- **rem (FPREM/FPREM1)** — radix-4 SRT **integer**-divide `D = ma<<expdiff`
  streamed MSB-first 2 bits/clock (dividend injection) + a final sign-correction.
  Replaces the radix-2 restoring reduction.

`fpu_sqrt_iter` dropped from `rtl/ventium.f` + `ventium_soc.f` (uninstantiated).

**Verified:** fpu87 thorough 47/47 gated under `VEN_SRT_ITER`; rem ==
folded-`fpu_fprem` baseline **byte-identical** (same pre-existing denormal/flag
corners — *not* regressions); `make verify` 97/0.

---

## 3. Transcendentals → DSP + shared mul (`bc4ea28`)

The four engines are verbatim qemu-8.2.2 polynomial transcriptions (chosen for
**bit-exactness vs QEMU**, which the `verif/trsc` gates enforce) — *not* CORDIC.
They were multiplier-heavy and defaulting to LUTs. Two changes, both bit-exact:

1. `(* use_dsp = "yes" *)` on all 4 modules → the ~40–50 inlined 64×64 multiplies
   (`mul128_192/256` + `fx_mul` Horner) map to DSP48 (~1216 free).
2. **Shared `mul128_256`** time-multiplexed across mutually-exclusive states via
   an `always_comb` operand mux (one 256-bit mul covers 128×64 via `b1=0`):
   `fyl2x` `S_CT2`/`S_CRECON`/`S_POST` (3→1), `fpatan` `S_Z2`/`S_ATANZ` (2→1).
   The complex rational-division sites stay inline.

All 4 core gates PASS. **Note:** CORDIC would be DSP-light/shared but would *fail*
the bit-exact gates (it diverges from QEMU); switching needs a ULP re-baseline.

---

## 4. Why the board still doesn't fit (the real blocker)

With the canonical `impl_kv260_soc.tcl` DEFS applied and `TRANSCENDENTAL=0`
**confirmed gating the transcendentals out**, core synth was still ~**126%**
(147,677 LUT-as-logic vs 117,120). The Jun-16 `hpc40ft` fit at 82% with the *same*
config — so the ~+54K is **FP-correctness bloat**, not transcendentals:

- `4890eae` — NaN-complete denormal + gradual under/overflow (the big one;
  ~545-line `fx_round_pack_f` rewrite)
- `cac19c4` — x87 overflow rounding + denormal-dividend FDIV
- `1bc6765` — SRT divider rounding

`TRANSCENDENTAL=0` can't touch this — it lives in the **shared rounder
`fx_round_pack_f`, inlined across the FP commit path** (`f_eval` add/mul cones,
`fx_div_exact`, and formerly `fx_sqrt`). The fix is to **deduplicate** those
copies, which keeps the correctness *and* reclaims the area (task #3).

### Config gotchas (for the impl runner)
- `impl_kv260_soc.tcl` **defaults `TRANSCENDENTAL=1` and `FPREM=1`** (`envor X 1`).
  The shipped bitstream used `TRANSCENDENTAL=0`. At default the 4 engines add ~50K LUT.
- Sanity check: with the full DEFS, **`fpu_top` should be ~3K LUT, not ~77K**.
  77K means `VEN_FP_PIPE`/iterative defines aren't actually applied.
- Build: `cd fpga && TRANSCENDENTAL=0 FE_PIPE=1 FPTRAP=1 PL0_MHZ=40 vivado -mode batch -source scripts/impl_kv260_soc.tcl`

---

## 5. Spine `fx_*` dedup (task #3) — IN PROGRESS

The plan: reclaim the duplicated `fx_round_pack_f` cones **without losing
correctness or reverting** the Jun-19 commits.

- ✅ **`fx_sqrt` prune** (`71b7824`): under `VEN_SRT_ITER` the engine handles every
  real sqrt, so `fx_sqrt` only saw `+0/-0/+Inf` (== input). Returning the input
  directly makes the 256-bit combinational `fx_sqrt` + its round_pack cone
  **dead → DCE'd**. Bit-exact (fpu87 sqrt 5/5; `make verify` 97/0). *Awaiting the
  impl runner's post-`71b7824` LUT number to size the rest.*
- ⏳ **`f_eval` round_pack dedup** (next): the full `f_eval` builds `fx_add`+`fx_mul`
  round_pack cones twice (comment at `fpu_writeback.sv:505` — "synth built FOUR").
  Route the remaining full-`f_eval` site through the split `f_eval_s1`/`s2` (one
  shared rounder), as the deferred path already does. Bit-identical.
- ⏳ **`fx_div_exact`** (the last full round_pack copy + the 192-bit divide):
  share the rounder and/or DSP-map/trim the divide. This is what's currently
  **STUBBED** locally — see below.

### ⚠️ Uncommitted WIP that is NOT a real fix
`rtl/fpu/fpu_x87_pkg.sv` (local, uncommitted) **stubs `fx_div_exact`**:
```
- q   = num / {128'd0, mb};   rem = num - q*{128'd0, mb};
+ q   = num >> 7;  /* STUB area (lean board build) */   rem = 192'd0;
```
This cuts the 192-bit divide to reclaim LUTs, but `fx_div_exact` then returns
**garbage for extreme-magnitude quotients** (`|exp-diff|>16000`). DOS-Quake never
hits that path, so it's *board-runnable*, but it would FAIL the fpu87 div suite.
**Treat as a temporary board hack, not a commit-to-main fix** — the proper move
is to share/DSP-map the divide, not stub it.

---

## 6. Open items / next steps

1. Finish task #3 dedup (`f_eval` rounder share + `fx_div_exact` proper trim)
   sized to the impl runner's post-`71b7824` LUT number → fit `TRANSCENDENTAL=0`
   (and ideally `TRANSCENDENTAL=1`, now DSP-mapped).
2. FPREM denormal-divisor *partial-reduction* corner: both the SRT and the folded
   `fpu_fprem` produce (different) garbage vs QEMU's 0 — pre-existing, needs
   significand `clz`-normalization to truly fix. Rare; not board-relevant.
3. Optional further sharing: the inline rational-division mul sites in
   `fyl2x`/`fpatan`, and a cross-module shared `mul128` engine (all 4 are blocking).

## 7. Verification quick-ref

- `make verify` — 97/0 (default `!VEN_SRT_ITER` combinational build).
- `VL_EXTRA_DEFINES="+define+VEN_SRT_ITER" bash verif/fpu87/run-fpu87-gate.sh thorough` — 47/47 gated.
- `bash verif/trsc/run-{f2xm1,fyl2x,fpatan,fsincos}-core-gate.sh` — bit-exact vs qemu-i386.
- Golden models: `python3 tools/srt/{sqrt,rem}_model.py`.

---

*Not yet committed: the `fx_div_exact` stub (§5) and the DOS-Quake fetch-capture
debug (`core_fetch_decode.svh`, `run.sh`, + commits `29a79cf`/`a59331e`) are
separate WIP, not part of the FPU area-shrink track.*
