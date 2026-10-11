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

Gameplay baseline: **0.51030715 total U+V IPC**, model `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**, predating both proposals. Both timing
candidates are gameplay-unmeasured. Canonical verification remains FAIL and
physical Win95/Quake acceptance remains outstanding.
