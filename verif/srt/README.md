# Ventium — radix-4 SRT divider gate (the genuine Pentium division datapath)

`make verify-srt` (or `bash verif/srt/run-srt-gate.sh`) is a standalone Verilator
unit gate for **`fpu_x87_pkg::fx_srt_div`** — the real base-4 SRT divider the
Pentium implements in silicon, added as an **optional compile-time feature**. It
is independent of the core/SoC build (it touches only `rtl/fpu/fpu_x87_pkg.sv`),
so the default `make verify` / `verify-soc` tracks are unaffected.

## What it is

Plain behavioral division (`fx_div_exact`, the default) just computes a wide
integer quotient. `fx_srt_div` instead runs the **actual algorithm**, reverse-
engineered from the Pentium die photo (Ken Shirriff, *"Intel's $475 million
error: the silicon behind the Pentium division bug"*, righto.com, Dec 2024) and
formalised by Tim Coe & Ping Tak Peter Tang and Alan Edelman (*"The Mathematics
of the Pentium Division Bug"*, SIAM Rev. 39(1), 1997):

* radix-4, two quotient bits/step, digit set `{-2,-1,0,1,2}`;
* the partial remainder kept in **ones-complement carry-save** (sum word + carry
  word) exactly as the chip does, with the delayed `+1` correction injected into
  the carry LSB after a complemented (positive-digit) subtract;
* the quotient digit chosen from a **4-integer-bit truncated index** (`xxxx.yyy`)
  into the reverse-engineered selection PLA — and that truncation, with the
  ones-complement modular wraparound, is exactly what lets a divide land on a
  *missing* PLA cell;
* a remainder-sign-aware final rounding to the 64-bit floatx80 significand.

### The FDIV bug, from first principles

Five PLA cells that should hold `+2` were never programmed and read `0` — Edelman
§4: `8·P_Bad ∈ {23,27,31,35,39}` in the five divisor columns `D ∈
{17,20,23,26,29}/16` (significand prefixes `1.0001 / 1.0100 / 1.0111 / 1.1010 /
1.1101`). With the buggy PLA those cells return `0` and the flaw **emerges from
the algorithm** — no operand is special-cased:

| pair | divisor col | result |
|------|-------------|--------|
| `4195835 / 3145727` | `1.0111…` (D=23) | flawed `0x3FFF_AAB7F6392A768638` → double `0x3FF556FEC7254ED1` = `1.3337390689…` (wrong at the 13th significant bit) |
| `5505001 / 294911`  | `1.0001…` (D=17) | also flaws (bug hit at iteration 8) |
| `7654321 / 3145727` | `1.0111…` (D=23) | **clean** — a triggering *divisor* is necessary but not sufficient (Edelman §5: reaching the foothold is rare) |
| `4195835 / 3.0`     | `1.1000…`        | clean — non-triggering divisor |

The bug is hit at iteration 8 (Edelman §7, *"at least nine steps to failure"*).

## How it is enabled (compile-time, default OFF)

```
+define+VEN_SRT_DIV        # route every FDIV/FDIVR through the SRT engine
+define+VEN_SRT_FDIV_BUG   # (implies VEN_SRT_DIV) use the buggy PLA -> the flaw
```

With no defines the divider is `fx_div_exact` and the whole project stays
bit-exact vs QEMU (`make verify` 69/69, `make verify-soc` 5/5). `VEN_SRT_DIV`
alone gives the genuine SRT engine with the **correct** PLA (still bit-exact);
adding `VEN_SRT_FDIV_BUG` reproduces the FDIV flaw for all operands.

## How the gate validates it

`tools/srt/srt_model.py` is the single-source golden model (a faithful Python
implementation of the same datapath, validated to be correctly-rounded against
exact rational division over a 10 000-divide corpus). The gate:

1. regenerates golden vectors (`verif/srt/gen_vectors.py` → `build/srt/vec_*.hex`)
   — the famous FDIV pairs, the negative controls, and a random corpus;
2. builds a Verilator TB (`tb_srt.sv`) against the real `fpu_x87_pkg`;
3. asserts `fx_srt_div` is **bit-exact** vs the golden for *both* PLAs.

`SRT-GATE-OK` ⇒ every vector matches.

## Files

| file | role |
|------|------|
| `tools/srt/srt_model.py` | single-source golden model; `python3 … pla` re-emits the SV PLA case block; run directly for the self-test |
| `verif/srt/gen_vectors.py` | emit golden vectors from the model |
| `verif/srt/tb_srt.sv` | Verilator testbench driving `fx_srt_div` |
| `verif/srt/run-srt-gate.sh` | the gate (regen → build → run → assert) |

## Relationship to M6 Erratum 23

The M6 runtime FDIV erratum (`fx_div_errata`, errata bit 0) is unchanged — it
returns the **documented** flawed value for the one published vector and is the
honest fallback when there is no oracle. The SRT engine *supplies that oracle*:
it bit-reproduces the documented flaw (and a second famous pair) from first
principles, which the M6 model's own comments noted "would require bit-
reproducing Intel's exact buggy SRT iteration."
