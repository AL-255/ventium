# mabench — heavy bare-metal overclock benchmark (live KV260)

A deterministic FP+BCD+integer kernel for stressing the Fmax-critical datapaths the
trivial `psocfw` smoke never touches: the x87 FADD/FMUL/FSQRT cone, the FBSTP
packed-BCD engine (`u_bcd`), and the integer multiply/divide unit. Each iteration
mixes the integer-divide + FP/BCD results into a djb2 hash (`acc = acc*33 + mix`) —
a non-cancelling accumulator, so any single corrupted bit changes the final
`CK=xxxxxxxx` printed to COM1. Build `-DNOFP` for an integer-only build (different,
also-deterministic CK — proves the FP path actually contributes).

Build (`gcc -m32`, reset stub F000:FFF0) and run via `ven_soc_app <img> 0xF0000 0x0
0x000FFFF0 --sys`; cross-build nothing (it's a guest image). Capture the golden CK at
the signed-off 40 MHz; sweep `venclk` and FAIL any clock whose CK deviates.

## Result (2026-06-13, live XCK26)

| Clock | CK | |
|---|---|---|
| 40.0–71.4 MHz (div 25→14) | `a343e000` | correct |
| **76.9 MHz** (div 13) | `969c6000` | **corrupt — datapath error** |

**Max verified-correct ≈ 71.4 MHz** (~1.79× the 40 MHz routed sign-off; the silicon
runs far faster than worst-case STA). `psocfw` is insensitive (passes to 83+ MHz) —
do not use it for Fmax.

## Hardware ISA constraints (all at 40 MHz — not overclock-induced)

- **FWAIT (0x9B) hangs** → use `FNINIT`/`FNSTSW`/`FNCLEX` (no-wait forms). Bare x87
  arithmetic works and computes correctly.
- **MOV-moffs (A0-A3) undecoded** → every memory access uses a non-EAX register so GAS
  emits ModRM `[disp16]`.
- No `CALL/RET`, no interrupts (the hex printer is inlined). `probe.S` /
  `finittest.S` are the instruction-support probes used to find the above.

## mabench2 — U/V/FP pipeline stress (dual-issue)

`mabench2.S` adds a thorough dual-issue exerciser run via `ven_bench --cycle`
(cycle_mode): Block A integer U/V pairing + cross-pipe forwarding (ALU/LEA/IMUL/DIV),
Block B the x87 FADD/FMUL/FSUB pipeline + FXCH, Block C long-latency FDIV/FSQRT
overlapped with integer work. cycle_mode is functionally correct on silicon
(single- and dual-issue give the same CK).

Boundary on the live XCK26 (corroborates mabench's 40→71.4 MHz / 76.9 MHz):
- **71.4 MHz (div 14): rock-solid** — 3/3 correct, both issue modes.
- **76.9 MHz (div 13): marginal/flaky** — non-deterministic wrong CKs, and **dual-issue
  fails where single-issue sometimes still passes** (the U/V path is the more sensitive
  stressor). Not a hard wall — a marginal-timing edge.

`ven_bench` (`sw/ps/ven_soc_app/ven_bench.c`) is the runner: stages the image, toggles
cycle_mode (`--cycle`), services COM1, reports the exit reason.
