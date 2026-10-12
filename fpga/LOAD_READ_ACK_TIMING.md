# Read-only load completion timing experiment — October 12

**Private candidate; not timing-, canonical-, standard-suite- or FPGA-qualified.**
The immediate requirement remains **at least 40 MHz post-synthesis Fmax** with
U/V dual issue, fast paths and full P5 caches. The measured parent is
[29.69650 MHz](SRT_REM_OPERAND_SPLIT.md); this candidate has no Fmax result yet.

## Change and rationale

The parent's worst path has 117 logic levels from EIP/decode through speculative
memory-chain/store readiness and general ACK into the far-load exception enable.
The read-only load FSM consumers do not need the write-completion portion of
that ACK network.

[`prepare_load_read_ack.py`](../verif/l1/prepare_load_read_ack.py) changes exactly
five `mem_ack` identifiers in `rtl/core/core_load.svh` to the existing
fragment-qualified `mem_read_ack`: two each in S_LOAD/S_LOAD2 and one in S_FLOAD.
No additional feature flag, state, arithmetic unit, cache port, request, data mux
or cycle is added. Other build profiles retain the existing alias fallback.
Simulation assertions require read ownership and exact ACK equality in all
three state arms. These are runtime checks, not a formal equivalence proof.

Three exact-source tests and four corpus/fixture adapter tests pass. The native
whole-core build retains 195 inputs and the same 152 feature definitions; only
the load include changes. It compiles in 19.60 s with assertions, 32 jobs and
the guarded 16 GiB/128-task profile. Its private harness object and matching
generated-header dependency are checked. Binary SHA-256:
`6d53d0934c9a3c6e7e89d632ccf0d677a0360b4dcb3caeeb917a1f131bd6e6cc`.

The first launcher attempt omitted the guard's mandatory `--` and failed before
starting a build. Its failed unit is retained. Corrected owner
`ventium-load-read-ack-core-r2-oct12`, invocation
`f336bb5be6864907aeef7929194abfbc`, closes native zero with unchanged pins.

## Whole-core verification

Runs cold-start at AXI read/write latencies 0 and 7. Complete QEMU comparisons
include paired U architectural state; complete parent/candidate comparisons
retain all cycle records. No new golden masks, trace trimming or cycle bands.

| Corpus | Fixtures | Candidate architectural records | Actual V retirements |
|---|---:|---:|---:|
| Paged memory | 72 | 31,392 | 1,500 |
| Held reads | 24 | 9,200 | 1,360 |
| FP payload/operands | 384 | 208,128 | 768 |
| Integer stores/memory | 256 | 169,472 | 512 |
| Indirect far faults + original page split | 5 | 9,306 | 122 |
| Original FP fault corpus | 16 | 23,585 | Not separately counted |

All rows above pass: **451,083 candidate architectural records** in total.
Record counts for the first five rows sum both AXI latencies; the final row
retains its original serialized fault-gate configuration. Fixture counts do
not count A/B and functional/cycle reruns as new fixtures.
These directed counts are not gameplay IPC or a full standard-suite result.

The new [targeted runner](../verif/l1/run_load_read_ack_faults.py) derives four
16/32-bit indirect far CALL/JMP cases from the original cold `pcallsel` setup.
Each requires exactly #GP(0x0f00), unchanged pre-fault ESP, the correct saved
restart EIP, and an actual new load-ACK witness at the indirect instruction.
The fifth case runs the original `pxpage` image unchanged and requires an
observed second-fragment S_LOAD2 completion for its cross-page CMPSD. All five
also pass free-running QEMU normal exit and the complete architectural oracle.

Canonical `make verify` **FAILS: 7 PASS / 101 FAIL**, native make exit 2.
It runs 412.46 s with unchanged masks/goldens/bands. All 20 original cycle
streams (66,807 records) equal the parent. The full same-input replay of all
108 functional programs also matches (80,800 records), including the
candidate's own original traces. This proves no observed A/B regression, not
canonical correctness. The FPREM mismatch remains: FSW 0x3a00 QEMU versus
0x3800 RTL at record 3, plus 300 versus 301 terminal-record counts. The inherited
failure must still be fixed and the real gate passed before acceptance.

The existing 16-case FP fault corpus closes all 32 parent/candidate runs with
full UV architectural comparisons. Native failures, timeouts or missing traces
would fail the runner; none occurred.

## Full-PC transfer and synthesis admission

The [PC builder](build_load_read_ack_soc.py) checks all closed regressions and
102 intersecting RTL/header sources. It retains all 156 PC definitions,
posted-DDR depth 16, the private-harness dependency audit and the guarded build.
The PC build closes native zero in **23.65 s** with unchanged input pins.
Its 98 inherited platform structural warnings are unchanged, **not** a clean
full-SoC lint result. Model SHA-256:
`89ebdd625be3f65e97c1ddafee6e166084ed3978c27d96f5f96b6509144f0a09`.

The [hardware exporter](freeze_load_read_ack_rk_candidate.py) retains 190
payloads, 170 simulation-matched RTL/header files and the exact ordered 158
hardware definitions. Only `ventium/rtl/core/core_load.svh` changes; no wrapper,
transport, constraint or tool-flow delta. Manifest SHA-256:
`09805c9c641b7b741fdf70c4547f0d4a8adbfa448d47be31c27a176d4d02c341`.
The native strict frozen-core lint passes in **3.78 s**. The existing mouse
overlay remains outside this frozen export; no board/UI pass is implied.

Both unchanged 10-iteration cold CoreMark disks pass all five reference CRCs,
at **4,767,218 / 4,753,406 ticks**, exactly equal to their parent (**0% cycle
gain**). They observe 1,055,307 / 1,054,254 V retirements. Each run exits natively
and is reaped; the independent audit rechecks 4,166 pins and no OOM. These are
short correctness smoke checks, not duration-valid scores or full standard
seeds. Audit SHA-256:
`1413b4cc2a139c75ec9d96a217eee6654ab06a608edb54d08c935c10811c7479`.

The [synthesis preparation](prepare_load_read_ack_synthesis.py) passes two
tests of exact input identities and unchanged resource-monitor/stop/reap logic.
`ventium-load-read-ack-synth-oct12` is launched with invocation
`5e52860a696445cdb29ea1d18291a2cf`. Evidence is `synthesis-r1` beside the tests.
The original admission rule remains: more than 6 GiB free and twice observed
parent growth above a 4 GiB stop floor (7,208,493,056 bytes minimum here).
RAM/swap caps remain **8/6 GiB**, combined early stop 13 GiB and host free
RAM/swap floors 2 GiB. No limit was increased. No route or deployment is queued.
Fmax remains unmeasured for this new candidate until native synthesis and the
independent clock audit both close. Full standard-suite and physical FPGA
Win95/UI and complete Quake timedemo acceptance remain outstanding.

The [timing queue](run_load_read_ack_timing.py) adopts that exact synthesis
invocation; it cannot start or restart synthesis. Queue owner
`ventium-load-read-ack-timing-queue-oct12`, invocation
`964cc5c2972342d5b7939740e4c44957`, waits for authoritative native closure,
rehashes the inputs and requires the independent synthesis audit to pass.
Only then may it launch the prepared clock/netlist audit. Audit-process success
is distinct from its `synthesized_40mhz_requirement_met` field. No route or
deployment is queued, and no resource limit is raised.

While this frozen synthesis runs, a separate
[query-payload selector candidate](PRIME_QUERY_PAYLOAD.md) is prepared and
microtested. It is **not included** in this synthesis. Full-core compilation
and regression of that separate candidate wait for the timing queue to close.

## Evidence and storage

Evidence root: `/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.
Subdirectories: `core-r1`, `memory-r1`, `held-r1`, `fp-r1`, `integer-r1`,
`far-r1`, `faults-r1`, `canonical-r1`. Closed receipts preserve native exits,
source/model hashes, invocations and full comparisons. Native matrices use
explicit CPU affinity and separate 2,048-task scopes, not the compiler scope.

Closed FP/integer/memory streams are retained in `closed-directed-text.tar.gz`:
22,104 nonempty files, 764,581,244 original bytes, 54,584,581 archived bytes.
Every member is byte-verified before removing its unpacked copy; sources,
binaries, fixtures and all pinned dependencies remain. Archive SHA-256:
`843f3a727589039278cb82eb3fa62a84b9d2fca56713df449fd206ea86b62e9a`.
Restore from the evidence root with
`tar -xzf closed-directed-text.tar.gz -C /home/yukidama/external/tmp`.

Additional recoverable archives in the same evidence directory:

- `older-fp64-text.tar.gz`: 8,544 closed diagnostic streams from seven explicitly
  checked older FP64 test folders, 1,094,703,396 bytes to 47,157,153 bytes;
  SHA-256 `9817c7aaea1a6410ccf32e5f65b6f3868a18b421d011ce4bde59a619db2f43ee`.
  The first attempt stops on an unrecognized eighth receipt schema before any
  deletion; that folder is left untouched. No old runs, media or models are deleted.
- `canonical-replay-text.tar.gz`: 432 closed replay-copy streams, 56,517,198 bytes
  to 1,967,535 bytes; SHA-256
  `cda45cf3d4ad5d0a3c24c05a235c2bf3c52327ad76dfb2b80ff7d18ae6dcde52`.
  Original canonical inputs/traces pinned by the current candidate remain unpacked.

Both archives are byte-verified before unlinking unpacked copies and restore
with the same `tar -xzf ARCHIVE -C /home/yukidama/external/tmp` procedure.
Four unpinned, unused precompiled headers from the closed candidate builds are
also removed (376,161,309 bytes); they are regenerable, with sources, headers,
native binaries and all current pinned dependencies retained.

Latest verified gameplay baseline: **0.51030715 total U+V simulated
retirement-event IPC**, older model `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. This candidate is gameplay-unmeasured; the
baseline is neither board IPC nor a complete-timedemo mean.
