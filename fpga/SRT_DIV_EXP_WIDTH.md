# Bounded divide-input exponent arithmetic — October 12

**Private component-tested experiment. Not integrated, synthesized or qualified.**
The active [fetch-probe synthesis](FETCH_PROBE_PAYLOAD.md) is immutable and does
not contain this change. The immediate requirement remains at least **40 MHz
post-synthesis Fmax**; its measured parent is **30.021916 MHz**.

## Motivation and scope

The parent's worst path ends at the shared SRT divider's `ua` exponent register,
after FP operand conversion and input normalization. The final portion of that
reported path contains serial exponent logic. This identifies a relevant
source-level investigation, not proof that Vivado retained every source bit or
that narrowing arithmetic will improve Fmax.

The [recipe](../verif/srt/prepare_div_exp_width.py) changes only divide setup:
the existing six-bit normalization shift is used directly, and bias/shift
subtraction has an explicitly **signed 16-bit intermediate**, sign-extended
into the **unchanged signed 32-bit `ua`/`ub` registers**. An explicit intermediate
is necessary because the wider assignment context can widen an expression.

The effective encoded exponent is 1..32767: encoded zero uses one, preserving
denormal/pseudo-denormal semantics. Subtracting 16383 and a shift in 0..63 gives
**-16445..16384**, which fits signed 16 bits but not signed 15 bits. All-zero
mantissas retain the existing CLZ default of zero. The same normalized
significands feed S/dfx/d4. No state, register width, pipeline cycle, valid/start
guard, rounding rule, exception rule, FDIV erratum or sharing policy changes.
Square-root and remainder setup/iteration are untouched.

Exact parent SRT SHA-256:
`76cb1b6cde27b18f230286d706bf0383f7989a8848fe57ef439f024258ad0c7f`.
Private candidate:
`40b3e77b051bb674f99a30f3c9eb37566c06b32487d567a9ee78eaccbb833cbb`.
The source recipe rejects drift and reapplication and reverses byte-for-byte.
Production RTL and the running synthesis's frozen sources are not edited.

## Evidence and limitations

Three host tests pass, including symbolic comparison for **every 15-bit encoded
exponent and every six-bit shift**. Z3 returns UNSAT for a mismatch; each wrong
zero bias, zero extension and 15-bit intermediate has a SAT counterexample.
This models the arithmetic expression, not whole-engine temporal equivalence.

The [native runner](../verif/srt/run_div_exp_width.py) extracts the actual
parent exponent getter, CLZ helper and old/new setup expressions. Its Icarus
test passes **2,101,120 exponent comparisons**, including **3,968 X/Z cases**,
and **137,796 paired operand-normalization checks**. The binary exponent/shift
cross-product is exhaustive (2,097,152 cases); the operand patterns are directed,
not exhaustive over arbitrary 80-bit values. Observed range is exactly
-16445..16384. Old/new sequential RHS expressions are evaluated combinationally;
this is not a simulation of the complete engine's state machine.

All three independently compiled bad variants fail natively with the required
mismatch: lost zero-exponent correction, lost sign extension, and a too-narrow
15-bit intermediate. No oracle masks or trace filtering are introduced.

Evidence root:
`/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI/div-exp-leaf-r2`.
Owner `ventium-srt-div-exp-leaf-r2-oct12`, invocation
`4b3eb5d84339440bbbea369d9a7d6667`, closes native zero in **17.43 seconds**.
It uses Icarus/Z3, an explicit CPU12 controller and a separate 512 MiB/no-swap
service; no heavyweight compiler or second Vivado is launched. All recorded
source/generated/tool pins remain unchanged at successful closure. Receipt SHA:
`fd319bc8802e7b1fa2e8642a6bc61c88171f6b45b3e4dbe782516585e5850f0a`.

The first attempt (`div-exp-leaf-r1`, invocation
`ed471fc6b0c24fe99fe28f19d8c92771`) remains **FAIL**: Icarus rejects an unsized
testbench subtraction inside a concatenation before simulation. The corrected
testbench uses `64'd1`; candidate RTL and comparison expectations are unchanged.
Its failed generated source/logs remain; its recorded original testbench hash
predates that one-line harness correction.

Do not integrate or launch another synthesis solely on this helper result.
First inspect the active fetch-probe run's new timing. If the divider exponent
cone remains relevant, run the actual full-engine sequential A/B miter and
mutation controls, whole-core FP/fault/cycle comparisons and source-matched PC
transfer. Any selected final processor still requires the canonical differential
gate, full standard suite and physical FPGA Win95/UI and Quake validation.
No latency, area or frequency gain is claimed here.

Gameplay baseline: **0.51030715 total U+V simulated retirement-event IPC**,
older model `2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. This experiment
has no gameplay measurement; that baseline is not board IPC or a full-demo mean.
