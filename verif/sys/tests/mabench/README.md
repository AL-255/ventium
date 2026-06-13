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
