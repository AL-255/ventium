<!-- Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
     SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1 -->

# fpu87 — thorough x87 FPU differential test suite

A randomized + corner-case x87 FPU verification gate that exercises **all the
arithmetic** on randomly-generated 80-bit operands and a hand-curated pool of
**denormal / special / unsupported-operand** corner cases, across **all four
rounding modes**, and checks the Ventium RTL against two *independent* oracles.

## Why two oracles (triangulation)

The legacy `make verify` x87 corpus diffs the RTL against a **QEMU** golden and,
by design, avoids denormals/specials (host-dependence was a concern). This suite
adds a second, independent reference so a divergence can be *adjudicated*:

```
        Berkeley SoftFloat (extF80)          <-- IEEE-754 / x87 reference
                  |  xcheck.py (st0 data result)
                  v
              QEMU golden  ───────────────►  RTL (Verilator)
                          compare.py (full st0..st7 / fstat / ftag)
```

* **compare.py** (authoritative): RTL must match the QEMU golden **exactly** on
  the whole x87 state (all of `st0..st7`, `fctrl`, `fstat`, `ftag`).
* **xcheck.py** (triangulation): the QEMU golden's `st0` must match the
  independent oracle. When the RTL diverges from QEMU *and* the oracle confirms
  QEMU is correct, the RTL is the culprit — not a flaky golden.

### The internet survey

[Berkeley TestFloat / SoftFloat-3e](http://www.jhauser.us/arithmetic/TestFloat.html)
(John R. Hauser, UC Berkeley) is the canonical open FP test framework. Critically
SoftFloat-3e implements the **`extF80`** 80-bit extended type — exactly the x87
internal format — with `extF80_add/sub/mul/div/sqrt/rem/roundToInt` and
conversions, and TestFloat's `testfloat_gen` produces input vectors with dense
subnormal/NaN/Inf/overflow coverage. Both are vendored as submodules under
[`extern/`](extern/) and reused:

* **SoftFloat** is the arithmetic oracle (`oracle/ven_fpu_oracle.c` links it).
* **TestFloat**'s `testfloat_gen` optionally feeds its corner-case **input
  operands** into the generator (its computed result is discarded; we re-derive
  the expected value with our own oracle so the x87 flag/encoding conventions are
  ours).

> **SoftFloat specialization.** x87 needs the `8086` NaN-propagation rules, but
> the stock build's object list omits two `bf16` helpers from that spec. We build
> the clean-compiling `8086-SSE` spec instead: `s_propagateNaNExtF80UI.c` is
> **byte-identical** between the two specs and conversions go through the shared
> `commonNaN` path, so `extF80` behaviour is identical (the specs differ only in
> f16/f32/f64/f128 binary NaN propagation, which we never call). See the Makefile.

Transcendentals (`F2XM1`/`FPATAN`/`FYL2X`/`FYL2XP1`) have no SoftFloat reference;
they are triangulated against **qref** (`tools/p5xtrans/qref.c`, the
qemu-bit-exact port) at round-to-nearest.

## Running

```bash
bash verif/fpu87/run-fpu87-gate.sh [profile] [seed]
#   profile : smoke | default | thorough     (default: default)
```

The gate builds the oracle(s), generates the corpus, builds the RTL testbench
once, then runs every program in parallel: QEMU golden `--x87`, RTL `--x87`,
`compare.py` (RTL↔QEMU) and `xcheck.py` (oracle↔QEMU). Profiles scale vector
counts (smoke ≈ a few k vectors, default ≈ 40 k in ~5 s, thorough ≈ 150 k+).

Useful env: `FPU87_OPS=add,div` (restrict ops), `NO_TRANS=1` (skip
transcendentals), `NO_TESTFLOAT=1` (skip TestFloat inputs), `TF_LEVEL=2`
(exhaustive TestFloat corner cases), `FPU87_JOBS=N`.

Build pieces directly: `make -C verif/fpu87` (oracle), `… testfloat`, `… qref`.

## Coverage

| op group | ops | oracle | gated? |
|----------|-----|--------|--------|
| arithmetic | `add sub mul div sqrt` | SoftFloat | **yes** |
| sign | `abs chs` | SoftFloat | **yes** |
| Tier-3 (best-effort) | `rndint rem rem1 scale` | SoftFloat / QEMU-only | info |
| compare | `fucom` | QEMU-only | info |
| transcendental | `f2xm1 fyl2x fyl2xp1 fpatan` | qref (RNE) | info (RTL → `verif/trsc`) |

Gating mirrors `docs/m3-fpu-spec.md` tiers: the **GATE fails** only on Tier-2
arithmetic + sign ops diverging on the **core** tier. Everything else is
**informational** (reported, never fails the gate).

**Operand pools** (`gen_fpu87.py`):
* *core* (gated): ±0, ±1/2/8/π, just-above/below 1, smallest/largest normal,
  smallest/largest/mid denormal, ±Inf, ±QNaN(+payload), ±SNaN(+payload), real
  indefinite — crossed with each other (all RC) and with thousands of random
  operands spanning denormal / tiny / mid / large / huge exponent bands.
* *unsup* (informational): the x87 "unsupported" encodings — pseudo-denormal,
  unnormal, pseudo-Inf, pseudo-NaN — where QEMU and the RTL may legitimately
  differ. Isolated into their own programs so they never mask the core suite.
* *TestFloat*: `testfloat_gen` corner-case inputs (optional, on by default).

Operands are injected as raw `fldt` (tbyte) loads, so SNaNs / denormals /
pseudo-denormals reach the FPU with no load-time conversion masking them.

## Findings (initial run, default profile)

The suite immediately surfaced **triangulation-confirmed RTL divergences**
(oracle == QEMU, RTL differs) — all in the denormal/overflow corners the legacy
corpus avoided:

1. **Overflow rounding under directed rounding modes** (dominant; `add` `sub`
   `mul` `div`). At RC = toward −∞ / +∞ / truncate the RTL chooses `±Inf` vs
   `±max_norm` incorrectly — e.g. a positive overflow under round-toward-+∞ that
   should give `+Inf` yields `+max_norm`, and the sign-mirrored cases invert.
   IEEE/x87 rule: truncate → `±max_norm`; toward −∞ → `+ovf`=`+max_norm`,
   `−ovf`=`−Inf`; toward +∞ → `+ovf`=`+Inf`, `−ovf`=`−max_norm`; nearest → `±Inf`.
2. **`FDIV` by a tiny denormal overflows to 0 instead of ∞** — `1.0 / 2⁻¹⁶⁴⁴⁵`
   gives `0` in the RTL; SoftFloat and QEMU both give `+Inf`.
3. **A few `FDIV` mantissa discrepancies** on specific normal/denormal operands
   (e.g. `fp_div_core_04`) worth a closer look.
4. **Tier-3 (informational):** `FRNDINT(2⁻¹⁶³⁸²)` → `1.0` instead of `0`;
   `FPREM`/`FPREM1` halt the RTL (consistent with the known-failing `tx_fprem`).

These are deltas in corners *outside* the documented Tier-2 "normal operands"
scope, so they are newly-surfaced rather than regressions. To use this as a green
regression gate, fix the RTL or scope the gate (`FPU87_OPS=…`) until the
overflow-rounding path is corrected.

## Files

| file | role |
|------|------|
| `oracle/ven_fpu_oracle.c` | SoftFloat extF80 oracle (batch/single, x87 flags) |
| `gen_fpu87.py` | generator: random + corner + TestFloat vectors → `.s` + manifests + baked oracle results |
| `xcheck.py` | oracle↔QEMU st0 triangulation for one program |
| `run-fpu87-gate.sh` | end-to-end parallel gate |
| `fpu87_worker.sh` | per-program worker (build / golden / RTL / compare / xcheck) |
| `Makefile` | builds SoftFloat (8086-SSE) + oracle (+ optional testfloat) |
| `extern/` | Berkeley SoftFloat-3e + TestFloat-3e submodules |

All build artifacts and generated corpora live under `build/` (git-ignored).
