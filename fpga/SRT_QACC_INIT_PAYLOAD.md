# SRT quotient initialization enable — 2026-10-11 UTC

**Separate private proposal; source-recipe tests pass, native miter pending.**
No synthesis gain, processor qualification or production RTL change is claimed.
The objective remains at least **40 MHz synthesized Fmax**, preserving UV
dual issue and system/relocated fast pipeline and fast memory.

The closed write-direction netlist's 30 worst paths end at the shared SRT
quotient accumulator's clock enable. The first path is 143 logic levels and
40.796 ns, from `q_pc[0]`, through translation, FP conversion, denormal exponent
classification and remainder setup, to `qacc[0]/CE`. Its unplaced Fmax estimate
is **24.33504 MHz**. The separate balanced-CLZ candidate is being synthesized;
its gain is not yet measured.

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

Two recipe tests check the exact source edit and reject drift. The new
[actual-engine sequential miter](../verif/srt/tb_qacc_init_miter.sv) is prepared
to compare results, flags, busy/done and phase cycle-for-cycle, and to assert
equal quotients in every consuming state. It includes 5,024 operations,
all operation kinds, rounding/precision controls, denormals, signed zeros,
infinities, NaNs, mixed operation sequences, ignored starts while busy and
24 reset interruptions. A deliberately broken busy-time clear must fail the
live-quotient assertion. These are test requirements, **not completed results**.
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
**not whole-RTL formal equivalence**. The actual-engine sequential miter remains
required and pending.

Idle candidate source SHA:
`f9ce70532446bbc7b991180a030bb319d50ba88a93deead1030ba3a73296461f`.
Evidence root: `/home/yukidama/external/tmp/ventium-srt-qacc-idle.Yw8Knb3X`.
Proof SHA: `600523d147376858c3a3c338df39b739fe42f6f23fe2685341173f89236b9cab`.
Queue `ventium-srt-qacc-idle-queue-oct11.service`, invocation
`67954c8d9c7145329976dc7c14ef4093`, waits for the accepted-start test before
running the same 5,024-operation actual-engine miter and deliberate busy-clear
defect against this alternative. The
[whole-core builder](../verif/srt/build_qacc_idle_core.py) is prepared but has
not run; it requires both the native miter and liveness proof before changing
the single SRT source in a separately compiled model.

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
attention to reach 40 MHz. The already leaf-tested
[MC address-preparation change](MC_ADDRESS_PAYLOAD.md) is therefore advancing
to full-core verification, rather than waiting for SRT changes alone to solve
timing. Actual mapped results must still be measured.

Gameplay baseline: **0.51030715 total U+V IPC**, model `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**, predating both proposals. Both timing
candidates are gameplay-unmeasured. Canonical verification remains FAIL and
physical Win95/Quake acceptance remains outstanding.
