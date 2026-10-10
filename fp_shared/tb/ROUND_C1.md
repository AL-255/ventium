# Compact round-direction sideband proposal — October 10

**Private, unpromoted RTL proposal.** It has not yet compiled or repaired the
complete FPU. The original package, active FPGA synthesis and live full-PC
models remain unchanged. Verified gameplay is **0.49083588 total U+V IPC**,
`86731249`, clocks1.2B–1.3B; this proposal has no gameplay measurement.

The [912-case observation](SRT_ROUND_FLOOR.md) proves that simply preserving
C1 is wrong for both FDIV and FSQRT. The proposed
[`round_pack_c1.patch`](round_pack_c1.patch) exposes the actual round direction
without recomputing arithmetic:

- Capture the retained significand LSB before the existing rounding add.
- XOR it with that bit **after** the existing tie-even mask and normalization.
  A real increment toggles it; a tentative tie increment cancelled back to an
  even result does not. At PC24/53 the retained bit is40/11; at PC64 it is0.
- The existing overflow decision explicitly distinguishes infinity (magnitude
  rounded upward) from finite saturation (downward). The underflow branch
  captures the bit after its existing shift/jam, not before it.
- Return `{rounded_up, OE, UE, PE, value80}` from `fx_round_pack_c1`. Preserve
  every original `fx_round_pack_f` caller's83-bit value/exception ABI with a
  wrapper. There is no second add, multiplier, divider, recurrence or pipeline
  stage in the proposal. Hardware cost/timing still require measurement.

`git apply --check` passes against package SHA256
`e7f1e126809559a80e29e6122433d2af27a63d75208056b62ff98ced729ba884`.

## Independent leaf test, queued

[`round_c1_vectors.py`](round_c1_vectors.py) uses exact integer division and
remainders to round the input to the requested precision/exponent grid.
No RTL function, host floating-point arithmetic or existing rounder computes
the expected value/C1. The sticky input is below the **normalized**128-bit
window, matching the function's interface. The first emitted vector file used
the unnormalized LSB for this tail; this was caught before any RTL run and
corrected. Both files remain in the scratch directory; only`vectors-r2.txt`
is admitted to the queued test.

Six host tests pass: exact values, both nearest-even tie directions, sticky
above a tie, negative directed rounding, zero/gradual underflow, exponent
carry/overflow and normalization. There are15,600 deterministic vectors over
all three defined precisions/four rounding modes/both signs, fifteen boundary
exponents, both sticky values and3,000 additional varied alignments.

[`tb_round_pack_c1.sv`](tb_round_pack_c1.sv) checks actual84-bit RTL results
against these expected80-bit values and C1. Separately, it compares all83
legacy value/exception bits and the compatibility wrapper against a literal
copy of the original round-pack function. This proves exception-bit
**preservation**, not independent correctness of every old exception rule.
No full-core comparator mask or golden is changed.

Private package, original reference, vectors and bounded `run_leaf.py`:
`external/tmp/ventium-round-c1-leaf.s1KdMbTu`.
The test-only package adds the untouched original function renamed to
`fx_round_pack_reference`; that reference is not proposed for hardware.
Test package SHA256
`6974c9fb3b181e0f34c5b28787fa2e2cf0b97735aae8838d2208ad6c42bff7f3`;
vector SHA256
`f48c9f9bf393e4c401b4c43c2792d0bf2d6755f57dcd1738fea284bfa6145ed2`.

Queued service`ventium-round-c1-queued-oct10.service`, invocation
`a05ef0002b184c68b2c1b78451539eb0`, waits on the same shared build lock as
Vivado and the exponent-repair leaf. Compilation/run has a600-second bound
after acquiring the normal4GiB/one-job scope. Check actual`closed.json`, native
output and supervisor closure; queue admission and host tests are not an RTL
pass. No concurrent Vivado or Verilator build is launched.

## Integration still required

After the leaf passes, carry the bit in the existing `ven_fp_alu` result
register and `fpu_srt_div` completion register. The SRT inline PC64 path must
account for its signed residual: a retained over-estimate can round upward
without executing its `up` increment. Its intended expression is
`up || (resid_neg && !down)`; do not substitute PE or only`up`.

At `ven_fp_top`, commit C1 only with that operation's existing arithmetic or
SRT owner. Keep FPREM/FPREM1 quotient C1 separate and do not leak borrowed
transcendental micro-operation flags into architectural state. Ordinary
non-rounding special results clear C1; the existing stack-fault override must
retain its distinct overflow/underflow C1 semantics.

Qualify value/flag/latency preservation, both seeded C1 values, alternating
arithmetic/SRT/FXCH owners, reset/cancellation and masked/unmasked faults.
Update every active instantiation explicitly and preserve strict pin/latch
lint. The reference SRT copy, legacy core path and old/new tests need deliberate
interface handling, not missing-port waivers. Combine with the independently
verified exponent repair before full-core differential/standard-suite runs.
Neither leaf alone closes C1, the generic gate or FPGA acceptance.
