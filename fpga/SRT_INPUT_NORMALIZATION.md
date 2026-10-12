# Balanced SRT input normalization — October 11, 2026

**Private, component-tested experiment; not a 40 MHz or FPGA qualification.**
The latest measured [register-shift candidate](U_SHIFT_REGISTER_OPERANDS.md)
reaches **26.55408 MHz**, below the required **40 MHz**. Its worst path now
ends at the shared divider's input exponent register. This experiment has
no synthesized frequency, area or gameplay measurement.

## Exact change

The [source recipe](../verif/srt/prepare_input_norm_tree.py) replaces only the
three descending, first-one searches in `fpu_srt_div.sv`: square-root radicand
normalization and divide A/B normalization. A six-decision binary search
returns the same shift. All exponent arithmetic, significand shifts, state
transitions, cycles, rounding controls and FDIV-bug behavior stay unchanged.
The existing remainder CLZ, quotient initialization and shared rounder are
untouched. No register, timing exception or slow-path fallback is added.

Parent SHA-256:
`f9ce70532446bbc7b991180a030bb319d50ba88a93deead1030ba3a73296461f`.
Candidate SHA-256:
`b53e94fbcb0f02cf1a90a110cca9144b2266808d9a8480c509e7364d50f69661`.
The recipe rejects source drift and reapplication, and reverses exactly to
the original whole file. Importantly, **no known-one returns shift zero**, not
64: this preserves the original loop defaults. Procedural `if` decisions
also retain the original handling of X/Z bits rather than merging ternary arms.

## Closed checks

Evidence root: `/home/yukidama/external/tmp/ventium-srt-input-norm.vLVgcXzS/`.

- Three host tests pass, including a Z3 equivalence query over all binary
  64-bit helper inputs (UNSAT) and two deliberate defects (SAT). This is a
  mathematical helper proof, not whole-RTL formal equivalence.
- `helper-r1/`: **378,852 native comparisons**, including **16,514 X/Z cases**,
  pass in **17.74 seconds**. Exhaustive 16-bit patterns at each quarter,
  every leading-one position and deterministic random words are included.
  Two independently compiled zero/half-selection defects exit 1 with the
  required mismatch. Invocation `21eede542fe64c2e8e601ba86d989476` exits 0.
- `engine-r1/`: the **actual parent and candidate RTL engines** pass
  **4,544 operations /162,282 cycle checks**, including **1,494 divides,
  1,493 square roots, 1,557 remainders and 24 reset interruptions**. Inputs
  change and starts are injected while busy. Tests cover denormal operands,
  every leading-one position in both divide operands, ordinary unnormalized
  inputs, precision/rounding controls and both FDIV modes. Exponents,
  significands, recurrence state, phase, completion and outputs are compared.
  A separately compiled wrong square-root shift fails the internal-state
  assertion at sample 1. Invocation `22ef0ebdb518454c88ad0a040ffc21e5`
  exits 0 in **6.83 seconds**, after waiting for the sole Vivado family to exit.

Helper receipt SHA-256:
`93d332c68bbdfe47863df12f2dcc824f188678f201d378c94b32692c604437b4`.
Engine receipt SHA-256:
`037c9dc208c1e7d6d21538d16393f0a31c74e9e0b2bdfbee726a9469e952a868`.
All recorded source/tool/binary pins remain unchanged. The sequential miter
is parent/candidate equivalence, **not an independent numerical oracle**.

## Whole-core continuation and limits

[The private builder](../verif/srt/build_input_norm_core.py) preserves all
195 source files except this single SRT file, all 150 UV-fast definitions,
and a private C++ harness/object/generated-header dependency. Preparation
records 481 direct input pins and requires both closed native tests plus the
independent shift-core audit. Four host admission tests pass. The guarded-32
core build closes native 0 in **20.28 seconds**, invocation
`12f44e6494c34e5db4f56bdc82f398cf`, with unchanged pins and verified private
harness/header dependency. Model SHA-256:
`18798ad41c1282562b51f610a2b2fd43d3157317b0ef59cb827d313b4e254b9a`.

The actual new model passes **72 cold paged/relocated FP fixtures /288
model-latency measurements**, covering **78,048 full architectural records**
and identical parent/candidate cycle streams at AXI latency 0/7. Actual V
retirement and early FP command acceptance are required by the unchanged
checks. `fp-r2/matrix/closed.json` SHA-256:
`1c8d5420158cf8f41830f87e5626c4c2972246d002a4b532e3fdbe3de5436570`.
Native interval **22.70 seconds**, invocation
`fb351b1b673c4b88848541e26ae789be`, stable inputs and all children reaped.

The first FP matrix (`fp-r1/`) remains **FAIL**: QEMU failed to bind port 59953
with `Address already in use`, followed by a GDB connection reset. That case
never reached its RTL comparison. The
[corrected scheduling adapter](../verif/issue_uv/run_fp_same_profile_serial_golden.py)
serializes this matrix's port-selection/golden-generation critical section;
RTL comparisons retain 32 workers. Three host adaptation tests pass. No
fixture, model, comparison, instruction limit or expected result changes.
This lock coordinates this matrix's threads, not arbitrary external software.
The first continuation also stays failed because it correctly rejected R1.

The separate #NM/architectural-debug corpus passes **8 model-latency runs /
14,488 complete records**, native exit 0, invocation
`8f4c8148f1d04c01b7c87f091ad047e3`, with identical control/candidate clocks.
This covers the original TS/EM and architectural-debug images, not every FP
fault scenario. Receipt SHA-256:
`0b9108fff3cc94f3ba3e0a1674bf12aa9f95962965f0df661de24da5db45b833`.

One fresh continuation, `ventium-srt-input-continuation-r2-oct11.service`,
invocation `e419e15b835b47699c0877ed047d36a0`, observes these exact closed
owners and waits for the existing ALU comparison queue to finish. It then
runs the unchanged canonical gate and all 108 complete same-input programs.
A canonical failure remains a failure; no automatic synthesis or implementation
follows this queue. The unchanged canonical gate now closes **FAIL**, native
exit 2 in **401.52 seconds**, invocation
`ce6c3de07ed8461f803a3be121f4673a`. All **20** complete cycle streams remain
identical to the shift parent, with stable pins and unchanged masks/goldens/
cycle bands. Receipt SHA-256:
`92578339c6c4ae097878b9d7fbcb7e43b56802778ab031f0a1d02b17045597ae`.
The subsequent same-input replay closes **PASS: 108 complete programs /
80,800 architectural records**, invocation `67ac10182e5b4280b5a9fe22d201febf`.
All input pins remain stable. Its receipt SHA-256 is
`5ba87d316710c1a9d2ca9206c9dd934b9d0bbe13bd2f064f40093d27b2bc18e1`.
The complete continuation terminates with no controller errors and correctly
reports **FAIL** because the canonical gate failed. Continuation receipt:
`b47b2a7c45afa7cfeb9d67ba32d351203df55dc47e06cce80fc3b2e36031fc31`.

The remaining original differential/cycle checks must close, followed by actual
mapped timing, the full standard suite and physical FPGA
Win95/Quake validation. The canonical gate is still **FAIL**; component
equivalence does not turn it green. The separate memory-capture timing path
already limits the measured parent to approximately **28.09 MHz**, so this
SRT change alone cannot be assumed to reach 40 MHz.

Verified gameplay baseline: **0.51030715 total U+V IPC**, simulated model
`2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. It predates this experiment,
which has no gameplay measurement. No production RTL, bitstream or board state
has been replaced by these tests.

The later read-hint hardware image still contains this experiment's exact
unbalanced parent SRT source. Its completed clock audit again identifies SRT
input normalization as the worst path (29.58405 MHz). The
[combined timing follow-on](MC_PAIR_SRT_TIMING.md) now integrates this exact
tested replacement with the independently tested paired-response read cofactor.
That actual combined core passes the cold memory/store/FP and #NM/debug matrices;
its new timing, full standard suite and board validation remain open. This does
not retroactively give the standalone normalization experiment an Fmax result.
