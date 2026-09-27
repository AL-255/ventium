# Complete retained-RTL cycle recorder

Implemented September 14, 2026. Results: [million-cycle gameplay analysis](IPC_STATE_TRACE_Sep14.md).

## Scope and sampling

This is a **complete named dump of retained numeric RTL model state**, not a
selected-signal performance trace. The generator enumerates the compiled root
header, including ports, registers, combinational fields, generated scalar
temporaries, packed/unpacked arrays, cache contents/tags/valid/LRU state, TLBs,
FPU state, peripherals, VGA RAM and constant tables. It checks that every root
save-state serializer field is covered. Unknown declarations or additional
stateful child cells fail generation instead of silently narrowing coverage.

The existing optimized model cannot expose eliminated nets or C++ function-local
evaluation temporaries after `eval()` returns. Scheduler queue allocation objects,
host pointers and Verilator runtime metadata are not RTL state and are excluded.
The generator writes the exact exclusions and header hash to
`ven_state_fields.audit.json`. Settled NBA effects are recorded in their destination
arrays. External host DDR, PS/ATA state and disk contents are **not in this internal
RTL trace**; the native checkpoint and disk bundle remain the replay authority.
Do not describe the delta file as a standalone full-machine checkpoint.

One full baseline is sampled immediately before the first recorded tick. Each
following record is taken after the rising-edge evaluations, DDR service and
final settling evaluation, with `main_time` incremented. Every tick counts,
including ticks nested in PS bus operations. There is no subsampling. The baseline
at cycle N plus a count of 1,000,000 produces records N+1 through N+1,000,000.
There are no extra DUT evaluations, clock changes, guest patches or register writes.

Registered/DPI retirement reporting and live combinational predicates can refer
to different edges. The analyzer labels settled-level correlations explicitly;
they are not an edge-aligned overlap acceptance test. Per-cycle changes to the
actual cumulative counters are also retained and analyzed independently.

## Build without recompiling RTL

Requires an **already compiled, savable** full-PC model, Python 3.11+, g++, and
zlib development headers/library. The model used for a native restore must match
the checkpoint; a different RTL elaboration is not interchangeable.

```sh
make -C ao486-sim ven-state-profiler \
  VEN_OBJDIR=ao486-sim/obj_dir_ven_sep14_fp_waitfetch
```

This uses `tools/build_scope.sh` (one job, 4 GiB limit), regenerates the exhaustive
field include, enables the host-only `VEN_STATE_DELTA_HOST` macro, and recompiles
`sim_ven.cpp`/relinks with zlib. `tools/build_state_delta.py` hashes generated model
headers/sources and `Vsystem__ALL.a` before/after and requires them unchanged.
The receipt is `ven_state_relink.json`. Never reuse an old field include for a
changed model; use this target again. No FPGA build is involved.

## Capture

New simulator arguments:

| Argument | Meaning |
|---|---|
| `--ven-delta-out PATH.gz` | New output file; refuses overwrite |
| `--ven-delta-start N` | Earliest absolute cycle; capture arms after init/restore |
| `--ven-delta-cycles N` | Consecutive cycles, 1–1,000,000; default 1,000,000 |

Stopping the simulator before all requested records are written fails the run.
The recorder closes itself after the requested count; normal simulation may
continue. Both the trace completion footer and `STATE-DELTA-OK` are required.

The reproducible gameplay driver below validates the input bundle, copies private
disks, freezes the profiler executable and invocation, checks a 1,000-cycle pilot,
then runs recorder OFF and ON and requires byte-identical final native snapshots
and disks. **This driver's timing profile is explicitly 45 MHz core/RTC, 90 MHz
VGA, 32 MiB configured RAM, DDR model 2, RTC epoch 1789257600.** Do not apply it
to checkpoints with a different saved configuration.

The driver also runs the frozen source executable for the same 1,000-cycle
pilot and requires its final native snapshot and disk to match the host-only
profiler (`host_relink_check.json`). This catches host behavior drift that
comparing only recorder OFF/ON in the relinked binary would miss. A failed
pilot comparison prevents the million-cycle run. The input bundle is
reverified after completion as well. Earlier capture receipts may not contain
this additional check.

`python3 tools/test_state_delta_capture.py` passes seven host-only orchestration
tests: success, frozen-executable snapshot/disk drift, observer snapshot/disk
drift, and failed source-bundle revalidation. Frozen-executable drift prevents
both full-length runs; every failure suppresses the final success marker. These
tests mock simulator subprocesses and are not RTL or guest equivalence evidence.

```sh
tools/build_scope.sh -- python3 tools/run_state_delta_capture.py \
  tmp/build-tmp/ventium-fp-waitfetch-quake-cold.an73kj5o \
  ao486-sim/obj_dir_ven_sep14_fp_waitfetch --start 1300000000
```

Artifacts go to a new `ventium-state-delta.*` directory under the guarded TMPDIR.
The source checkpoint/disk are never modified. Snapshots skip boot only; they are
not processor fixes or substitutes for cold-boot compatibility tests.

## Preserve a stopped checkpoint before long validation windows

`run-gameplay-capture.sh` accepts `SAVE_CYCLE` for an earlier cold stop. Despite
the bundle's fixed `gameplay.snap` filename, an early stop is not proof that the
guest has reached gameplay. Resume that verified bundle without changing its
executable or guest state:

```sh
RESUME_BUNDLE=tmp/build-tmp/my-stopped-bundle \
OUTDIR=tmp/build-tmp/my-new-continuation SAVE_CYCLE=1300000000 \
bash ao486-sim/ven/resume-gameplay-capture.sh
```

The destination must not exist. This wrapper copies/validates the source bundle,
uses the same fixed 45/45/90 MHz v3 profile as the capture driver, and stops before
hashing the new disk/snapshot pair. It retains `initial.snap` and source provenance
locally and verifies the source again after completion. It never substitutes a
new RTL model or patches a saved register. `--save-every` alone is not equivalent:
the mutable disk is not frozen alongside each periodic state file.

The wrapper's 1,000-cycle FP-stream replay matches the previously captured native
terminal state and disk byte-for-byte; evidence is
`tmp/build-tmp/ventium-resume-wrapper-check-sep14` and
`/tmp/ventium-resume-wrapper-check.log`. Other clock profiles are not supported
by this wrapper. Rendered gameplay still requires inspection, and full-machine
checkpoint replay is not an independent architectural oracle.

## Read and analyze

`tools/state_delta_read.py TRACE.gz --schema` prints all field names, types,
offsets and sizes. Without `--schema` it reconstructs/validates every cycle.
Its `Reader.records()` API yields the complete mutable state at each cycle;
copy it only when retaining a particular sample. This is not `.vtrace`.

For fast million-cycle analysis, compile `tools/state_delta_analyze.cpp` with
`g++ -std=c++17 -O2 -Wall -Wextra -Werror ... -lz`, under `tools/build_scope.sh`,
then run the resulting executable as `analyze TRACE.gz OUTPUT_PREFIX`.
This analyzer currently requires the measured async/performance field set and
full P5 D-cache geometry; missing fields fail loudly. Its numeric state IDs are
specific to that elaboration (S_PIPE=28), not a portable ISA contract.

Outputs: summary, joint state/hold/memory/frontend/retirement counts, per-field
change activity, PC hotspots, per-cycle bailout-counter correlations, representative
nonmatching store victims, full initial/final images, and their named schema.
The analyzer reconstructs **all** fields on **all** cycles, not just these reports.

`.cache_backend.tsv` is the joint distribution during L1 FILL: AXI read state,
Avalon-bridge state, platform-cache state, backing ACK, write-buffer busy, and
current read waiting. Decode numeric states using the recorded model's RTL.
It separates full downstream-fill waits from bridge/control phases; it does
not treat correlated residency as independent saved cycles. See
[the cache diagnosis](CACHE_DIAGNOSIS_Sep14.md).

Read-wait reports also partition by the retained `cur_is_d` translation selector
(`l1_read_wait_source_instruction` / `data`) and by source plus core state and
cache-service category. This separates first-word instruction fills from data
requests in S_PIPE. The labels describe the current request, not the owner of
an independently progressing fill; data includes physical/system accesses.
The synthetic L1 cases alternate the selector and test the disjoint counts and
ACK/no-request exclusions. See the latest analysis for the measured source split.

Optional fourth argument: an `fpd_layout.tsv` emitted by
`python3 tools/fpd_layout.py rtl/core/ventium_decode_pkg.sv`. Use the package
belonging to the recorded model. The parser rejects unsupported declarations;
the analyzer checks a complete, nonoverlapping 210-bit layout against both
retained descriptors. This enables U-register/V-memory, V-MOV-load and V-MOV32
opportunity counters. They require actual settled U commit, frontend/V boundary
availability and the pairing leaf's V-memory-only rejection, excluding U memory,
stack, branch and FP operations. They are not saved-cycle estimates or proof of
V segment/page/debug/event eligibility. No V request is issued by this observer.
Parser tests: `python3 tools/test_fpd_layout.py` (three tests pass). The compiled
analyzer also passes 17 synthetic attribution cases via
`tools/test_vload_attribution.py SCHEMA.tsv --analyzer EXECUTABLE`, and the full
million-cycle candidate reconstruction. Evidence:
`tmp/build-tmp/ventium-vload-opportunities.a86qd7vo/`. This small host-only job
ran in a separate 512 MiB, one-CPU scope (222,994,432 bytes peak, no swap/OOM),
without starting another RTL build or full simulation. The earlier waiting
analysis wrapper was explicitly canceled; the cold simulation was untouched.

The fixture has since expanded to **41 passing synthetic cases** for streaming-FP
schemas: the 31 V-load/held-packet/L1 cases plus ten FP cases. The FP additions
check owner-count histograms 0..4, all eight hold-priority categories, descriptor
kind/ALU-op counts, and exclusion of unavailable/stale descriptors and unasserted
holds. They do not turn these settled-level counters into causal saved-cycle
estimates. The earlier single-owner schemas omit these ten cases because they
have no `fp_async_count` field. The new cases were checked using the frozen
analyzer in `ventium-singlefill-fpkind-analysis.Xd542k` under a 512 MiB host-only
scope alongside the unchanged cold simulation. An initial synthetic kind value
exceeded the actual three-bit field; the fixture's range check rejected it,
and the corrected values pass exact reconstruction and counter checks.

It also exports interrupt signal transitions and `.commit_observations.bin`.
For this elaboration, the generated DPI callback reads the previous settled
`core_retire_valid`, `q_pc`/`q_pc2` and `snap`. The analyzer checks the predicted
retirement count against the actual host counter on every recorded cycle before
emitting observations. Each little-endian record is `<QQIII48s`: ending retire
count, absolute cycle, U PC, V PC, group size (1/2), raw integer/segment snapshot.
This is a derived diagnostic, not `.vtrace` or an x87 correctness oracle.
`tools/compare_state_delta_commits.py BASE CAND --start-cycle N` compares PC order
and only common commit-group integer-state boundaries, without resync or flag
masking. Interrupt timing can legitimately split the streams; a divergence is
reported, not silently removed. Deferred x87 and full memory are not compared.

Tests: `ao486-sim/ven/test_state_delta.cpp` plus `tools/test_state_delta.py` cover
changed bytes, unchanged cycles, array tails, exact reconstruction and corrupt /
truncated files. Compile the C++ fixture with `-Iao486-sim/ven -lz`; pass it a new
filename, then pass that file to the Python test. ASan/UBSan are supported.

## Lossless on-disk format, version 1

Gzip level 1 wraps a little-endian binary stream:

1. `VENDLT01`, u32 field count, u64 baseline cycle, u64 record count, u32 state size.
2. For each field: u32 name length + UTF-8 name, u32 type length + UTF-8 type,
   u32 byte size. Packed offsets are cumulative; no C++ object padding is dumped
   between fields. Numeric array storage follows the recorded Verilator type.
3. Full initial packed state.
4. Each cycle: u64 absolute cycle, u32 changed-block count; each changed block:
   u32 aligned byte offset, u16 changed-byte mask, then replacement bytes in bit
   order. Blocks are 16 bytes and strictly increasing. Unchanged cache contents
   produce no updates. Even a completely unchanged cycle has a record.
5. `ENDDLT01`, u64 completed count, independently gathered full terminal state.

Readers reject missing cycles, malformed masks/offsets, truncation, trailing data,
gzip corruption and terminal reconstruction mismatch. RAM use is bounded by
model size, not capture duration. The million-cycle file was 499.18 MiB versus
627.05 GB for repeatedly writing the packed full state (~1,198× smaller).

### Storage audit of the single-fill million-cycle capture

`ventium-state-delta.omyvu80w/on/state.delta.gz` occupies **480,939,507 bytes
(458.7 MiB)**. Summing the per-field activity report in
`ventium-singlefill-fpkind-analysis.Xd542k/analysis.fields.tsv` confirms that
large arrays are not repeatedly dumped:

- The 50 fields of at least 1 KiB occupy 573,440 of the 627,104 baseline bytes
  (91.4%), but contribute only **897,390 changed payload bytes** over all 1M
  clocks, 0.28% of the total 316,757,284 changed payload bytes.
- The 8 KiB L1 D-cache data array contributes 271,423 changed bytes; each
  retained 8 KiB instruction-cache data copy contributes 34,870 changed bytes.
- 7,216 fields, occupying 349,467 baseline bytes, never change in this window.
  They remain recoverable from the baseline and independent terminal image.

Most delta payload therefore comes from frequently changing small fields,
including retained decode temporaries, counters and cache output windows—not
from repeatedly serializing cache storage. The 109,826,441 changed blocks also
carry six bytes each of offset/mask metadata before gzip, plus cycle headers.
These are **uncompressed format/activity counts**, not per-field contributions
to compressed file size. No alias or temporary was dropped to improve the ratio;
doing so would weaken the retained-state coverage contract. This audit reuses
the existing exact reconstruction and requires no new simulation.
