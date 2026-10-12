# Bounded divide-input exponent arithmetic — October 12

**Private full-engine-tested experiment. Not synthesized or qualified.**
The completed [fetch-probe synthesis](FETCH_PROBE_PAYLOAD.md) does not contain
this change. It reaches **30.487805 MHz**, below the required **40 MHz
post-synthesis Fmax**. Its worst 30 paths still end in SRT input state.

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
Production RTL and the completed synthesis's frozen sources are not edited.

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

Do not launch another synthesis solely on helper/engine results. Whole-core
FP/fault/cycle comparisons and source-matched PC transfer remain required.
Any selected final processor still requires the canonical differential gate,
full standard suite and physical FPGA Win95/UI and Quake validation. The new
measured path already spends about 26.4 ns before reaching the divider operand,
so this local change must not be assumed sufficient for 40 MHz. No latency,
area or frequency gain is claimed here.

The [full-engine runner](../verif/srt/run_div_exp_miter.py) and
[testbench](../verif/srt/tb_div_exp_miter.sv) now **pass**.
They compare the actual engines' registered arithmetic state, control, valid
results and completion cycles, with 29,537 operations per configuration.
Coverage requirements include both remainder-port configurations, all 64
normalization positions in either divide operand, six exponent boundaries,
all RC/PC encodings, both erratum settings, special operands, interleaved
divide/sqrt/remainder, 126 reset points and ignored starts while busy. Three
separately compiled mutations must fail in the real engine. The extra PC=01
and unusual extended encodings test parent equivalence, not independently
established ISA correctness for those inputs. Compilation uses the existing
32-job, 16 GiB/128-task heavy-build scope after both Vivado owners have closed.

`div-exp-engine-r2` closes native zero in **23.60 seconds**, unit
`ventium-srt-div-exp-engine-r2-oct12`, invocation
`46908d4d62d4492285cae41655dd6432`. Its 41 pins are unchanged and independently
reread. Both native positive runs pass: **29,537 operations each**, with
1,121,223 / 1,121,586 cycle observations and 126 resets each. All nine engine
states, all RC/PC/erratum settings and exponent range -16445..16384 are required
nonvacuous witnesses. Three bad variants compile successfully then fail natively
with `DIV_EXP_STATE_MISMATCH`; compile failures cannot count as mutation success.
The actual launched children have CPU0–31 affinity; each simulator uses one
execution thread. Receipt SHA:
`05e3872dbb0623a0cdc4133fa89fbda16ddde184c0b1446a5342b4be22d2e67d`.

The first engine attempt (`div-exp-engine-r1`, invocation
`68779e42ff10484ebb1ab151f1e271c8`) remains **FAIL** before simulation: a
testbench comment starting with the compiler's name is interpreted as an unknown
directive. Only that comment changes for R2. Its exact original testbench is
retained in `tb_div_exp_miter.original.sv`, verified against its recorded SHA
`ee897c1bdaddb81b556ca6002e1464e9c09e2d18bc09246ea48feb6f2e2ba6fe` and
commit `a336b6cc`; no expected result, candidate source or oracle is modified.

The [whole-core transfer](../verif/srt/build_div_exp_core.py) prepares the
measured fetch-probe model with exactly one of 195 source payloads changed and
the same 152 definitions. It requires the exact closed timing and engine
receipts, preserves all assertions and reuses the unchanged guarded compiler
and private generated-header checks. `div-exp-core-r1` builds natively in
**20.11 seconds** under
`ventium-srt-div-exp-core-oct12`, invocation
`35c97865344c49e788261f86539737e5`, with all 680 input pins stable and the
private host object linked against its own generated header. Model SHA:
`d7d683b3e1d2ea70586b56f095a86e11fc1e37fa6889050caaa2d5541f8e5b77`.
Compilation is not a whole-core correctness pass.

The unchanged canonical `make verify` closes **FAIL** on this model under
`ventium-srt-div-exp-verify-oct12`, invocation
`6e450027a211411f8701748eafe335bd`, retaining the original masks, goldens and
cycle bands. Its native make exit is 2 after **397.14 seconds**: **7 functional
passes / 101 failures**, matching the parent's counts. All 20 complete cycle
streams match the fetch-probe parent exactly; input pins remain unchanged.
This is an acceptance blocker, not a waived pass. Receipt SHA:
`50ea2f575f95256bfbb9c1036c703d271d33b0b25a9cb63f19a6b32b45a699f0`.
The
384-fixture original FP/QEMU/state/cycle matrix runs concurrently with 32
workers under `ventium-srt-div-exp-fp-oct12`, invocation
`4f263f49bbee4e349e54ce5ee06143e7`, then **passes in 50.19 seconds**.
All 768 candidate latency-0/7 runs compare **208,128 complete architectural
records**, with 768 V retirements and zero A/B cycle differences. Inputs are
unchanged and all children are reaped; receipt SHA:
`f578ccf1607c7d60b56708c7e5cf486939062594cff413587a10bffa090d68d5`.

The follow-up same-input replay (`div-exp-replay-r1`) closes native zero in
**74.78 seconds**, unit `ventium-srt-div-exp-replay-oct12`, invocation
`56b4c812b89d4e0faa7f3e4552de40c7`. All **108 programs / 80,800 complete
architectural records** agree between parent and candidate using the candidate
gate's exact input bytes and initial stack pointer. The candidate replay also
reproduces its original gate traces. This establishes an A/B regression result,
not canonical QEMU correctness or permission to alter masks/bands. Receipt SHA:
`ed118f3db2629cc9c9323c6b0f5ef750608f988ef80cc7c217dae4f341b4ba6d`.

The original FP read-ack fault matrix (`div-exp-faults-r1`) also closes native
zero, unit `ventium-srt-div-exp-faults-oct12`, invocation
`aea4dae253314667bb1465978896f813`: **16 fixtures × two models**, including
**23,585 candidate architectural records**. Every native gate and complete
UV/QEMU comparison passes, with identical full A/B state traces and no timeout.
The original gate's slow-mode diagnostic controls are not substituted for its
required UV comparison. Receipt SHA:
`b706be4ca91848aa6bf07774b874c4dd44f8f840128c7ddaecec8a1fe2c1a63f`.
Both services have exited with empty cgroups; both sets of input pins were
independently rehashed unchanged. Real replay simulator children were sampled
on CPU0–7 and a real fault-matrix simulator on CPU24–31; configured systemd
CPU properties alone are not used as affinity evidence.

The canonical gate remains **FAIL**. Full standard suite, source-matched
PC/hardware transfer and timing remain open; no new synthesis, full-system run
or board deployment is launched. The immediate hardware target remains
**at least 40 MHz post-synthesis Fmax with UV + fast mode retained**, followed
by routed and physical-board qualification. The last measured 30.487805 MHz
belongs to the fetch-probe parent, not this unsynthesized exponent candidate.

After the engine owner closes, ten unused/unpinned compiler `.gch` files are
removed to preserve disk reserve (**822,775,360 bytes**). Source, generated
headers, all five native models and logs remain; rebuilding regenerates the
caches. Cleanup verifies no open descriptor, the exact terminal owner and
unchanged engine/new-core pins; `div-exp-pch-cleanup-{plan,closed}.json` retains
the file list and hashes.

Gameplay baseline: **0.51030715 total U+V simulated retirement-event IPC**,
older model `2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. This experiment
has no gameplay measurement; that baseline is not board IPC or a full-demo mean.
