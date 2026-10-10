# Shared estimator: remove an invariant-zero quotient word

Implemented in `fp_shared/ven_fp_estdiv.sv`; **not yet deployed or qualified by
the full standard suite**. Current verified gameplay is **0.48007471 total U+V
IPC**, `86731249`, 2.4B–2.5B clocks, predating this change. All thirteen windows
from 1.2B–2.5B average **0.47084103**, below the sustained target. The new
width-only full-core model `dd094313` has no gameplay measurement.

## Change and invariant

The existing shared 128/64 quotient estimator retains `z_q[31:0]` even though
it is always zero. Reset clears it; E_D1 and the first E_DIV completion assign
`{high_word,32'd0}`; E_CORR subtracts `2^32`; no other state changes `z_q`.
The second quotient word is only ORed into the final output, never `z_q`.
Induction therefore preserves the zero low word on every clock after reset.

Retain only `z_hi_q[31:0]`, calculate the exact **64×32→96-bit** product, and
append 32 zero bits before the existing 128-bit remainder subtraction.
Correction becomes a modulo-32 decrement. Final output concatenates the high
word and second quotient. This is equivalent to the old modulo-64 decrement
and OR; it adds **no state, stage, queue, recurrence or cycle**, including
saturation, correction and busy-request behavior. It is workload-independent.

Before SHA256: `8b6260df1025996cbbbb4e819d66c2cadcd52f8fc8da4f4890bfdf3179bff69a`.
After: `b9650dc7c6288301757e8e52aca665405ecc701fc6580613f88c52cf2087c271`.
The checkout update is byte-identical to the privately tested candidate.

## Verification and actual hardware-resource result

[`tb_estdiv_narrow.sv`](tb_estdiv_narrow.sv) compares every output and internal
recurrence state on **284,883 clocks**: **10,153 completed operations**, 7,098
correction cycles, all six states, normalized/unnormalized inputs, saturation,
busy input mutation, continuous requests and cancellation at 80 recurrence ages.
The old source is literal, apart from its module name. Strict structural errors
and assertions remain enabled. The independent existing `test-estdiv` also
passes **5,004** comparisons against the legacy estimator.

Reproduce the same-cycle miter in a fresh output subdirectory:

```sh
TMPDIR=/home/yukidama/external/tmp \
VENTIUM_VERILATOR_BIN=/tools/verilator/v5.046/bin/verilator \
tools/build_scope.sh -- timeout --kill-after=20s 600s \
  python3 -B fp_shared/tb/run_estdiv_narrow.py \
  --out /home/yukidama/external/tmp/<fresh-estimator-miter>
```

Matched Vivado 2025.2 out-of-context synthesis uses the actual XCZU15EG part,
same 25 ns constraint, Default directive and rebuilt hierarchy for both
variants. One guarded family, one worker, 4 GiB RAM/1 GiB swap caps; native
completion in 90.16 seconds. Both checkpoints and reports are retained.

| Resource | Original | Narrowed | Reduction |
| --- | ---: | ---: | ---: |
| LUT | 846 | 710 | 16.08% |
| FF | 532 | 501 | 5.83% |
| CARRY8 | 65 | 56 | 13.85% |
| DSP48E2 | 16 | 8 | 50.00% |

Worst **register-to-register post-synthesis estimate** improves from about
**169.8 MHz to 199.0 MHz** (`1000/(25−slack)`, slack 19.111/19.976 ns).
This is only the estimator leaf, with estimated interconnect and no physical
clock skew; **not a core frequency, routed timing result or silicon sign-off**.
The intended core clock remains 40 MHz. No CoreMark/IPC gain is claimed.

Evidence roots:

- `external/tmp/ventium-estdiv-narrow.cmgQ6Qgc`: private miter, original/candidate
  source, `ooc-closed.json`, native synthesis log, both DCPs/utilization/timing.
- `external/tmp/ventium-estdiv-legacy.08oT0nKF`: legacy 5,004-case pass and
  repeat miter against the actual updated checkout.
- `external/tmp/ventium-estdiv-core.WTmkYNQl`: strict full-core build
  `dd094313195ef43aa0cafa6fca7c3d82ee3920e940154e4008d07d6b32cdf9e5`.
  Exactly this one file changes from the compiled `b5453f16` parent; definitions
  and unique model-specific harness are preserved.

`make verify` on `dd094313` closes **FAIL**, invocation
`6c1db165186844cc8e9d6c5c84560f7d`: 7 functional passes, 101 terminal-length
failures, **no earlier field differences**, and the same four hard cycle-band
failures (depadd, indepadd, dmiss, imiss). Actual AXI and UV-fast flags are set
for both functional and cycle jobs. Native gate exit is 2; no mask, shortened
trace or relaxed timing band turns this into a pass. Full standard-suite and
new FPGA export/implementation acceptance remain open.

The full FPGA synthesis had already stopped safely during technology mapping.
Its log grew from 6,436 MB peak after constraints to 18,805 MB after timing
optimization, with thrashing warnings. This leaf reduction is measured, but
does **not** prove it solves that full-chip working-set problem. No identical
full synthesis is relaunched, no guard is weakened and no browser is killed.
