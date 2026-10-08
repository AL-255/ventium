# Genuine U/V architectural snapshots — Oct 8, 2026

**Verification repair, not a fix for the FPGA's bad next-PC or a performance
claim.** Deployed `1c8f20ac`, repaired RTL and this candidate have no qualified
gameplay IPC. Historical `53f129e9`: **0.1659957781052303 primary/U-counter IPC**,
not total U+V, over 127 qualified intervals with gaps within cycles
8,721,490,845–19,169,282,165, frames 37–898 at 37.499869765 MHz. It predates
the current changes. UV + system fast pipeline remains the acceptance mode.

## Repair

Previously `retire_state` and `retire2_state` both exposed live post-pair `snap`.
For `MOV ESP,imm` (U) / `MOV EAX,imm` (V), U's record already contained V's EAX.
This prevented genuine instruction-by-instruction comparisons in `--cycle-func`
even when the CPU executed correctly. Disabling V hid the observation defect.

The GPR writeback driver now samples **its actual U write values before V
overwrites them**, including ordinary width/high-byte merges and checked memory
responses. At the real paired integer commit, the observer latches that U state
and U's selected flags. V retains the actual live final state. Reset and every
non-pair clock clear the observer-valid bit. Neither the recorded state nor
its valid bit feeds any execution, request, fault, admission or control signal.

The new observer is excluded under `SYNTHESIS` or `VTM_NO_DPI`. Hardware ABI,
FF/LUT demand and architectural execution are not changed by this repair.
Preprocessed full-core token streams match the control for both exclusions
(only the explicitly identified existing assertion-message text is normalized).
This is a source-exclusion check, **not a fresh synthesis/timing result**.
The legacy `VEN_FXCH_FREE` folded x87-pair snapshot is not repaired or newly
qualified; that option is absent from the exact tested 107-definition profile.

## Evidence

Frozen full-core build/evidence root:
`/home/yukidama/external/tmp/ventium-uv-retire-state.bMk6tx`.
Native model SHA256:
`f1722209acdb29282adc35789fb8f4557b46b2e41dbc19533ad544586bde0c98`.
Same exact UV-fast 107-definition profile as the repaired control, no FE-cut
flags, assertions and hard structural errors enabled, 32 compile jobs. Unique
C++ harness basename/object and generated-header dependency are verified.

| Check | Original control | Snapshot repair |
|---|---|---|
| 12 real U/V pairs × 2 AXI latencies, cycle traces | 24/24 pair | 24/24 pair |
| Same 24 cases, complete per-instruction states | 24/24 fail, including subject pair | 24/24 pass |
| 8 paging/fault images × 2 AXI latencies, unmodified full QEMU comparator | 16/16 fail | 16/16 pass |
| Complete paging cycle/PC/pipe/pair records | Reference | 16/16 exactly identical |

The new pair corpus covers GPR writes, flag overwrites, AH/BL and 16-bit merges,
loads, stores with readback, LEA, CMP, shift and rotate. It requires U and V to
retire together; an unpaired fallback fails. The architectural checker compares
every GPR, selector and EFLAGS at every reference record, without a pair mask.
It explicitly checks the sole extra terminal INT80 record used by this directed
fixture before comparing the reference-covered records; this does not alter
the general comparator or make-verify gate.

Reproduce with a source-pinned prebuilt model:

```sh
python3 -B verif/issue_uv/run-uv-retire-state.py --tb /absolute/path/to/tb_ventium
```

Committed-source runs: repaired `ventium-uv-retire-pairs.26kv97o7` (48/48),
negative control `ventium-uv-retire-pairs.tj7vyfpc` (24 cycle passes, 24 state
failures; every subject pair exposes the defect). Native inputs remain pinned.
The previous shift/Jcc gate also passes 32/32 unchanged cases with required
same-cycle pairs (`ventium-uv-shift-branch.i9v42ls6`).
System matrix is `system/` under the evidence root: `ppage`, `pfault`, `pxfrag`,
`pxwalkd`, `pdtlbassoc`, `psgdtpg`, `pbytemovpg`, `ptaskpg`. All 64 native
control/candidate × cycle/state × latency runs exit 133, including the red
control comparisons. Golden producer is pinned Pentium QEMU; no state is
invented from QEMU or substituted into RTL.

## Remaining gates — explicitly not waived

`make verify` was also run with `TB_EXTRA_FLAGS="--cycle-func --quiesce 200000"`
on the full-address 106-definition counterpart (only the SoC address aperture
is removed). Binary
`3c14748c5529e4e9fa92f26c6548fcfb17b9387152043c7cada303b6bc7d828b`.
It is **red: 7 functional passes, 101 length-only failures**. Every compared
architectural field agrees, but most cycle-mode traces include the terminal
user INT80 that QEMU's GDB functional producer cannot observe after process
exit. One instruction-capped pair case also overruns the reference count by
one. The comparator and gate have not been relaxed; matching prefixes do not
turn those failures into passes. The existing `mb_dmiss` band also remains red
(4,154 vs 20,524 clocks). Evidence: `verify/`, `verify.log`, `verify.exit=2`.

The ordinary legacy functional control was rerun separately: 108/108 functional
passes, same `mb_dmiss` failure (`verify-legacy/`, `verify-legacy.log`). That
control is explicitly **not** the acceptance evidence for paired execution;
the paired-state and full-system comparisons above are.

This removes the confirmed integer-pair observation defect without reverting
to U-only execution. It does **not** complete the standard suite, qualify the
eight-entry translation prototype, fix the FPGA failure, establish 40 MHz
timing, provide a new gameplay IPC, or deliver the required full timedemo movie.

## Scratch-space preservation

Before another model build, 21 closed, unreferenced large `.owner.jsonl` logs
from the earlier memory-OR, reverse-CMP and odd-target micro runs were compressed
in place, saving **2,539,862,225 bytes**. Each gzip was decompressed and checked
against the raw input's SHA256 and byte count before removing that exact raw
file. All evidence remains recoverable with `gzip -dk <file>.gz`.
Targets, per-file durable receipts and results are retained under
`/home/yukidama/external/tmp/ventium-owner-log-compression.yaYbnB`.
No source, native binary, workload image or active run was removed.
