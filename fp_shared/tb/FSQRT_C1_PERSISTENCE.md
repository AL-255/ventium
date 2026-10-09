# Exact FSQRT retains stale C1 — open correctness defect

Current verified Quake gameplay is **0.49083588 U+V IPC**, model `86731249`,
cycles1.2B–1.3B. This diagnostic is not another gameplay result or a fix.
It changes neither the frozen FPGA export nor any differential comparison rule.

[`fsqrt_c1_persistence.S`](fsqrt_c1_persistence.S) runs `FNINIT`, loads3 and16,
computes `FPREM1`, then `FSQRT` and two register pops. Four `FNSTSW` stores
capture status after each operation. Quotient5 seeds C1=1; the remainder and
its square root are both exactly1. For FSQRT, C1 records rounding upward and
must clear for an exact result. C0/C2/C3 are undefined and are **not** asserted
against hardware. See [Intel's FSQRT instruction entry, PDF page487](https://www.intel.com/content/dam/www/public/us/en/documents/manuals/64-ia-32-architectures-software-developer-vol-2a-manual.pdf#page=487).

| Observer | After FPREM1 | After FSQRT | After first pop | After second pop |
| --- | --- | --- | --- | --- |
| Native host x87 | `3300` | `3100` | `3900` | `0100` |
| Pinned QEMU, `-cpu pentium` | `3000` | `3000` | `3800` | `0000` |
| Current shared-FP RTL, `b5453f16` | `3300` | **`3300`** | `3b00` | `0300` |

This proves a defined **C1** error, separate from QEMU's missing FPREM1
quotient flags. It is not sufficient to describe every `tx_fprem` status
difference as an oracle gap or blindly extend its terminal mask. It does not
identify this as the cause of Quake's performance limit.

Evidence: `external/tmp/ventium-fp-c1-observation.lWKLSGKN/complete-r4/result.json`,
model`b5453f16119f8b59d744cd2bb26eef38b683cbddf20bf3f215d259d5baa577f9`.
The unchanged model runs with `--cycle-func`, real V retirement, no STEP,
an ordinary QEMU ELF-entry image (zero guest instructions executed before
capture), native/guest exit0, zero actual fault deliveries and the exact8-byte
output. All11 pre-syscall FP retirement PCs are checked. The legacy syscall
proxy coalesces the following MOV and terminates at exit; this is **not** a
complete differential instruction trace. Initial flat-loader/syscall and
whole-trace-count assumptions failed; those attempts and scripts remain.
R4 observes actual status; it does not fabricate or normalize registers.

## Proposed repair and verification

`f_arith_fstat()` preserves C1, and the shared top uses it for SRT completion.
The SRT/round-pack result currently exports only OE/UE/PE plus the80-bit value.
Carry the actual final rounding-increment decision as a one-bit result sideband,
and commit C1 with the owning operation. Reuse the existing rounder; do not
recompute square roots, add a duplicate datapath or serialize the fast pipeline.
Do not simply copy PE or clear C1 unconditionally: an inexact result can round
up or down, and nearest-even tie correction can cancel the tentative increment.

Before promotion, cover PC24/53/64, all four rounding modes, exact/inexact/tie
cases, zero/negative/NaN and masked/unmasked faults, reset/cancellation and
adjacent SRT/arithmetic/FXCH owners. Preserve value/exception outputs and cycle
counts in an old/new miter, then run the differential and standard suites.
The exact-result witness is currently **failing RTL correctness**, not an
accepted expected-failure waiver. No mask or timing band was changed.
