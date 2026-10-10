# Balanced SRT remainder leading-zero search — private candidate

Current verified gameplay: **0.50705320 total U+V retirement-event IPC**,
`bfb867f7`, clocks **1,300,065,237–1,400,065,237**; both consecutive windows
from 1,200,065,237 average **0.508680175**. That exact cache-backed
model also scores **2.101890118 / 2.107616105 CM/MHz** on its two duration-valid
CoreMark seeds. This new helper is not in that model or the active FPGA
synthesis, and has **no gameplay or processor-frequency measurement**.

## Reason for the change

The preceding full-design native timing report has an unplaced EIP-to-SRT
result-enable path of 194 logic levels, through frontend decode, FPU operand
selection and remainder setup. Its 18.09 MHz estimate is **not routed Fmax**.
The actual SRT source's `rem_clz64` carries a found/not-found dependency through
64 iterations. This is one source-level candidate for reducing the setup cone,
not proof that it alone determines the reported path or will fix core timing.

`prepare_rem_clz_tree.py` replaces only this function under the default-off
`VEN_SRT_REM_CLZ_TREE` flag. Six binary-half decisions build the count bits;
all-zero input still returns 64. Existing three callers remain unchanged:
both remainder operand exponent adjustments and final remainder normalization.
No recurrence, arithmetic result, flag, register, pipeline stage or latency is
changed. Divide/square-root normalizers are not replaced.

The original procedural loop ignores X/Z bits unless they are a known one.
Procedural `if (|half)` has the same behavior: a half containing a known one
has reduction 1; a half containing only zero/X/Z is not selected. Repeating
this finds the highest known one, or returns 64 if none exists. A ternary is
not equivalent because it merges branches for an unknown condition.

## Closed microtests

Six source-recipe tests pass. The miter extracts the actual original function
and its transformed replacement from frozen `751139e1` source; it does not
substitute a separate mathematical DUT. **311,428 four-state comparisons pass**:

- zero, all-one, all-X/Z; every one-hot/complement position;
- every pair of bit positions with X/Z mixtures;
- every 16-bit pattern in each of the four quadrants;
- deterministic full-width binary and mixed-X/Z patterns.

Three required mutants each exit 1 with an actual mismatch: wrong zero result,
wrong half shift, and X-merging ternary. The correct candidate exits 0, all
12 source/tool/generated-input pins remain stable, and the service closes
successfully with MainPID 0. Elapsed 8.674 seconds; memory peak 14,036,992 bytes.
Root: `/home/yukidama/external/tmp/ventium-rem-clz-leaf.daf5nzN7/result-r2`;
service `ventium-rem-clz-leaf-oct10-r2`, invocation
`26cbc25132604a0f8345b2038d6fa412`.

The initial preflight refused an incorrect two-caller expectation before
compilation. Inspection identified the final-normalization third caller; R2
requires all three. The failed service/journal and explanation remain retained.

## Native area/timing result: do not advance as a timing repair

After the preceding full synthesis closed, the guarded helper comparison ran
alone in `ventium-rem-clz-area.4rtTKVCb`. Native 0, 58.23 seconds, stable pins,
3,274,551,296-byte peak RAM, zero swap/OOM; independently audited retained
supervisor `3f56c963d0ed483aa262637ee788d034`.

| Identical registered helper shells | Original | Balanced |
| --- | ---: | ---: |
| LUTs | 87 | 85 |
| FFs | 71 | 71 |
| Logic levels | 7 | 7 |
| Unplaced estimated period | 2.085 ns | 2.081 ns |
| Unplaced estimated frequency | 479.62 MHz | 480.54 MHz |

These are **isolated, unplaced shell estimates**, not processor Fmax or
physical measurements. Both have zero black boxes/CARRY8/MUXF cells. Vivado
already balances the original helper: the source's serial appearance does
not imply a 64-level mapped chain. Two LUTs and 0.004 ns estimated difference
are insufficient evidence for a useful core timing repair. Do **not** advance
this proposal into the measured full-PC/FPGA candidate on that premise.
The negative finding and microtests are retained; no production RTL, running
simulator, guest or FPGA input changed.

Promotion requires whole-engine/core equivalence, strict structural lint,
differential gates, the complete standard suite and actual FPGA verification.
The existing stale-C1 and generic-gate failures remain separate obligations;
this function-equivalence microtest neither repairs nor waives them.
