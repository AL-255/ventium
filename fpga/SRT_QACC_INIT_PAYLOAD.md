# SRT quotient initialization enable — 2026-10-11 UTC

**Separate private proposals; source-recipe tests and native miters pass.**
No synthesis gain, processor qualification or production RTL change is claimed.
The objective remains at least **40 MHz synthesized Fmax**, preserving UV
dual issue and system/relocated fast pipeline and fast memory.

The closed write-direction netlist's 30 worst paths end at the shared SRT
quotient accumulator's clock enable. The first path is 143 logic levels and
40.796 ns, from `q_pc[0]`, through translation, FP conversion, denormal exponent
classification and remainder setup, to `qacc[0]/CE`. Its unplaced Fmax estimate
is **24.33504 MHz**. The separate balanced-CLZ candidate now reaches
**24.56339 MHz**, and its top reported endpoints move to memory/LRU/capture.
Neither quotient-initialization proposal is part of that measured netlist.

## Proposed change

[The guarded recipe](../verif/srt/prepare_qacc_init_payload.py) moves the two
`qacc <= 0` initialization assignments to the common accepted-start branch.
The parent is exactly the balanced-CLZ source, SHA
`96f615d962f864e42ce651b29fedaf419acc8215697045b0fc3b2df4368ef7d4`.

For iterative divide and remainder this writes the same zero on the same edge.
Special results and square root do not consume the quotient accumulator;
every subsequent operation which consumes it initializes it first. Thus their
inactive internal quotient value may change, but no request, state, result,
rounding or completion equation is changed. Removing operand classification
from this enable may shorten the path; it is not yet a measured improvement.

Two recipe tests check the exact source edit and reject drift. The
[actual-engine sequential miter](../verif/srt/tb_qacc_init_miter.sv) compares
results, flags, busy/done and phase cycle-for-cycle, and asserts
equal quotients in every consuming state. It includes 5,024 operations,
all operation kinds, rounding/precision controls, denormals, signed zeros,
infinities, NaNs, mixed operation sequences, ignored starts while busy and
24 reset interruptions. A deliberately broken busy-time clear fails the
live-quotient assertion. Both native results are now complete (details below).
The miter compares the two actual RTL engines; it is not an independent
numerical oracle or whole-core verification.

Evidence root: `/home/yukidama/external/tmp/ventium-srt-qacc.kLGd8tvA`.
Queue `ventium-srt-qacc-queue-oct11.service`, invocation
`5aa49f431e32477fa4535c28d05c353a`, observes the exact balanced-CLZ timing queue
before launching one guarded native test. It does not overlap a new heavy
Verilator build with Vivado, retry a failure, alter the active FPGA export or
start another synthesis. Source hashes are pinned before waiting.

## Stronger alternative: initialize throughout IDLE

The accepted-start proposal still puts the producer's `start` on the quotient
enable. [The idle-state alternative](../verif/srt/prepare_qacc_idle_payload.py)
instead initializes `qacc` in `ST_IDLE`, before the `if (start)` guard. This
removes both operand classification and producer admission from initialization.
The accepted edge into divide/remainder still sees the same zero, and no
consuming state changes. It is a separate derivative of the balanced-CLZ
parent, not a modification of the pinned accepted-start experiment.

Two exact-edit/drift tests pass. A
[source-pinned liveness proof](../verif/srt/prove_qacc_idle_liveness.py) checks
inductively that both 128-bit quotients agree whenever a consuming state can
observe them. Common arithmetic contributions and state-transition guards
are unconstrained. The positive query is UNSAT; missing remainder initialization
and busy-time clearing both produce SAT counterexamples. This is an abstraction,
**not whole-RTL formal equivalence**. The complementary actual-engine sequential
miter now passes as described below.

Idle candidate source SHA:
`f9ce70532446bbc7b991180a030bb319d50ba88a93deead1030ba3a73296461f`.
Evidence root: `/home/yukidama/external/tmp/ventium-srt-qacc-idle.Yw8Knb3X`.
Proof SHA: `600523d147376858c3a3c338df39b739fe42f6f23fe2685341173f89236b9cab`.
Queue `ventium-srt-qacc-idle-queue-oct11.service`, invocation
`67954c8d9c7145329976dc7c14ef4093`, waits for the accepted-start test before
running the same 5,024-operation actual-engine miter and deliberate busy-clear
defect against this alternative. The
[whole-core builder](../verif/srt/build_qacc_idle_core.py) requires both the
native miter and liveness proof before changing the single SRT source in a
separately compiled model. That model now builds successfully (below).

## Closed native unit evidence

Both real-engine miters pass **5,024 operations /167,864 cycle checks**, including
1,654 divides, 1,653 square roots, 1,717 remainders and 24 reset interruptions.
Each observes 95,608 consuming-state quotient checks. The accepted-start and
idle variants respectively observe 64,568 and 69,058 inactive quotient
differences, demonstrating that the test actually exercises the changed
initialization. Both independently compiled busy-clear defects fail with
`SRT_QACC_LIVE_MISMATCH`, native exit 1. No numerical-oracle or whole-core
qualification is inferred from these A/B checks.

| Variant | Native service invocation | Time | Receipt SHA |
| --- | --- | ---: | --- |
| Accepted start | `5cb0a26375c5409ebeebf3859ffe2298` | 3.78 s | `baa4b8e1d56fd8233e61fe35f4fcb0bfa1398e1ec5cce4ee9fcbaa2b2723cb23` |
| Idle initialization | `15fde2ff68bd4b5c9993a04202ce433f` | 2.43 s | `a62445c3c87131802da8a454e0aa3415a07b3902d94680200d17509d5095f208` |

Both services and their queues close with exit 0. All pinned source/binary
hashes are independently rechecked after closure. Only closed, generated
compiler products are then losslessly archived and removed from loose storage,
recovering **579,430,811 bytes**; verified archives, recovery commands, sources,
headers, executables and all evidence remain. No further FPU synthesis is
launched: the newer measured netlist makes the memory path the current priority.

## SRT is not the only limiting path

The retained write-direction capture report contains another near-critical
path, omitted from the top-30 list because all 30 endpoints there are quotient
bits:

| Endpoint | Setup slack at 25 ns | Logic levels |
| --- | ---: | ---: |
| SRT `qacc[0]/CE` | -16.093 ns | 143 |
| `pipe_mem_v_hit_q/D` | -16.057 ns | 140 |

The latter begins at EIP and traverses instruction-byte selection, U/V decode,
branch-prime ownership/validation, address/translation and cache-map checks,
L1 tag lookup, store credit/ACK, commit and response capture. In this netlist
it is only **0.036 ns** behind the SRT path. Holding other paths fixed, even
eliminating the SRT delay leaves the capture constraint at about **24.36 MHz**;
this is a diagnostic bound, not a measured optimization gain. Both paths need
attention to reach 40 MHz. The
[MC address-preparation change](MC_ADDRESS_PAYLOAD.md) now closes at
**26.01118 MHz**, improving memory-capture slack by 4.022 ns. Its worst
endpoint is again SRT quotient enable. That netlist does not include either
SRT change, so their combined effect still requires actual synthesis.

## Private whole-core build and directed tests

The idle-state variant's full-core build closes with native exit 0 in
**12.29 seconds**, retaining all 150 UV-fast defines and the private C++
harness/header dependency. Unit `ventium-srt-qacc-idle-core-oct11.service`,
invocation `1356d8a7925444c18b311802d6a9aeed`. Model SHA:
`33fb210acc14e9f880f493767cfb9fbf0cd4304038a925a521856384680631c7`.
The balanced-CLZ core is its sole parent; only `fpu_srt_div.sv` changes.

The unchanged cold paged/relocated matrices pass **72 memory +72 FP +12 AGI
fixtures**, including divide/sqrt, with complete QEMU architectural comparisons
and identical full A/B cycle streams. Native times are 12.20 /6.38 /1.99 s;
units `ventium-qacc-idle-{memory,fp,agi}-oct11.service` respectively retain
invocations `6c085c1aaa5e43f6b0c6d01b9fe27876`,
`f762db9ca6b14996aa787436b34c0332`, `b44f1ead5ecb46c5b5dc109d93c649dc`.

All **16 focused FP fault cases on both models (32 runs, 47,170 full UV
architectural records)** pass, including #NM/#PF ordering, source faults,
pending FP ownership and segment relocation. Unit
`ventium-qacc-idle-faults-oct11.service`, invocation
`7f262d1896854b308fa51dd787612415`, exits 0. These are focused checks, not the
full permission/fault sweep or standard suite.

Canonical verification closes with native gate exit 2 (**FAIL**), unchanged
inputs and all 20 full cycle streams identical to the parent. The 338.62-second
controller interval includes waiting for the fault gate's shared lock; it is
not a pure execution-time benchmark. Unit `ventium-qacc-idle-verify-oct11.service`,
invocation `46d4814dbf7c49f0b7d9b35a9494afcc`, exits 1 as expected for that
failed gate. No masks, goldens, terminal records or cycle bands change.

[Independent full-core auditing](../verif/srt/audit_qacc_idle_core.py) now
reopens the directed records, fixtures, native exits, profiles, source closure
and canonical cycles: **75,192 candidate architectural records**, 1,500
targeted memory-V retirements and 350 AGI acceptance events. Receipt
`audit.json`, SHA:
`c8047ea72183b751b4eee55bcbd1bf795618966bc0cadb3fa97f289a53d278dd`.
This does not turn the canonical gate green.

An additional direct comparison of all 108 historical functional RTL traces
fails at initial ESP: independent QEMU loader invocations initialized different
stack addresses. That comparison is retained in `canonical-ab.json` and is not
treated as either a processor failure or equivalence. The
[same-input driver](../verif/l1/run_canonical_same_input_ab.py) instead reruns
both binaries on the candidate's exact original image and golden-derived ESP,
requiring full A/B equality and exact reproduction of the candidate's original
trace. It does not normalize ESP, mask C1 or drop terminal records.

That same-input run now passes **all 108 programs /80,800 complete candidate
records** (216 native model runs), in 98.09 seconds, with input pins unchanged.
Every fresh candidate trace reproduces its original trace exactly, and every
parent trace matches the same-input candidate. Unit
`ventium-qacc-idle-canonical-ab-oct11.service`, invocation
`21a2a50f3d8946ddbc1a4774864d483c`, exits 0. Receipt SHA:
`cbe27a0a91f97aee1b55fddc5207b6532e655775e54d3c17ddbcdbda46899377`.
This establishes no new full-corpus A/B architectural difference; it **does
not fix the still-failing QEMU gate**.

Gameplay baseline: **0.51030715 total U+V IPC**, model `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**, predating both proposals. Both timing
candidates are gameplay-unmeasured. Canonical verification remains FAIL and
physical Win95/Quake acceptance remains outstanding.
