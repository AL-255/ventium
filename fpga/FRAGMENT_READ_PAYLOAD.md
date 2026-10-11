# Read-fragment payload timing experiment — October 11, 2026

**Private correction with directed whole-core and actual AXI-byte checks.**
The completed bus-payload parent measures **28.10410 MHz** (unplaced synthesis
estimate), below the required 40 MHz. This follow-on correction has no measured
timing or FPGA result and has not been merged into production RTL.

## Reason and exact scope

The [shift candidate's original-clock report](U_SHIFT_REGISTER_OPERANDS.md)
contains the chain from instruction length through segment faults, fragment
strobes, last-byte memory classification and cache-response payload selection
into the shared FPU. The separate V response-capture path is also below 40 MHz;
optimizing only SRT normalization cannot resolve that measured parent.

The [bus-payload candidate](BUS_CANCEL_PAYLOAD.md) removes late cancellation
from the bus driver's unused payload, but its read-fragment byte mask still
uses `fx_start`, including the late miss/permission/segment-fault conditions.
The completed parent report confirms this remains in its 127-level critical
path; source structure alone does not establish the follow-on timing gain.

[`prepare_fragment_read_payload.py`](../verif/issue_uv/prepare_fragment_read_payload.py)
changes exactly one assignment in a **private derivative of that bus candidate**:
read-fragment payload shaping uses the page-crossing/state cofactor without
the late admission guards. The original `fx_start`, engine sequencer, request
suppression, write probe, walk/abort controls and ACK suppression are unchanged.
No register, extra cycle, clock exception, cache reduction or slow-mode fallback
is introduced. The recipe rejects source drift, another consumer of the changed
selector, or a missing bus-payload predecessor.

On an issued read, the unchanged bus driver already establishes the removed
admission conditions. Therefore the byte strobes must match the predecessor.
Inactive strobes may differ. That algebraic implication does **not** establish
whole-system equivalence: retained responses and their consumers still need
the complete fragment, cache and system checks.

Parent core SHA-256:
`43161919331feafca3ac1472d45b162ae54271a3be5a2d41237dc6220aec2174`.
Required bus-header SHA-256:
`e892403371c601c2e2c2660565fb8d4bf8ed7408efe3c0bf271015da63bf7ba1`.
Generated candidate core SHA-256:
`8b1eaa291011ce6f11e5572c1c1cd8e82e9ca3d55065badc7d0500b2fc79efbf`.

## Closed microchecks

Four host tests pass: reversible/exact scope, source/predecessor drift rejection,
unambiguous source extraction, and a binary SMT cofactor proof. The proof ranges
over arbitrary original requests, fault controls, fragment phases, addresses,
sizes, strobes and saved fragment state. Three deliberately broken variants
(paging, abort replacement, crossing) each produce a counterexample. A separate
query proves that inactive-payload differences are actually possible.

[`run_fragment_read_payload.py`](../verif/issue_uv/run_fragment_read_payload.py)
uses the actual source-extracted bus tail and fragment-output expressions in
Icarus. The original request producer, translation function and sequential
engine are abstracted; this is explicitly **not the whole core**.

| Native leaf evidence | Result |
|---|---:|
| Compared samples | 204,800 |
| Issued requests, exact strobes | 7,944 |
| Inactive payload differences | 3,727 |
| Fragment-start witnesses | 212 |
| X/Z payload/address/size samples | 8,192 |
| Deliberately broken variants rejected | 3/3 |

Admission controls remain binary in the X/Z tests; unknown fault controls are
**not qualified**. No assertion, comparator mask or RTL fallback hides that
scope. Unconditionally observed request/ACK/start/hold controls and all other
observed payload fields remain identical in the native matrix.

The bounded leaf service closes native zero in **12.82 seconds**, with stable
source pins and **46.6 MiB** reported peak memory. Invocation:
`e89b570e867d48ae88065d13ced83201`.
Evidence root:
`/home/yukidama/external/tmp/ventium-fragment-read-payload.etYN56fg/leaf-r1/`.
Closed receipt SHA-256:
`c444dcba6bd46381142ae520418395d0d7c220a5418dec80924dfa8f91ea9f2c`.
The compiler's constant-select sensitivity warnings are retained in its native
logs. No second Vivado or heavy simulator build was started.

Host checks can be repeated without compiling a simulator:

```sh
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
  FRAGMENT_PAYLOAD_PARENT=/path/to/the/exact/bus-candidate/rtl/core \
  python3 -B -m unittest discover -s verif/issue_uv \
  -p test_fragment_read_payload.py -v
```

## Remaining acceptance

### Newly reproduced predecessor bug: generic read strobes

The leaf miter above establishes equivalence to its predecessor, **not that the
predecessor's read widths are correct**. A further real-ISA diagnostic finds a
byte-exactness defect that must be repaired before this proposal is qualified.

[`run_fragment_abort_replacement.py`](../verif/issue_uv/run_fragment_abort_replacement.py)
derives twelve private `pxfrag` BIOS fixtures: the IDT #PF gate crosses with
1/2/3 bytes on its first page, cold/warm translations, and CR0.CD=0/1. All state
changes are normal guest instructions; no snapshot, guest STEP or injected
register state is used. All twelve complete under QEMU Pentium and the existing
bus-candidate model, at AXI latency 0/7, with full architectural comparisons.
There are 11,124 architectural records, 11,124 cycle records and 1,860 paired V
retirements. These passing traces alone do **not** establish bus correctness.

Evidence is under the same experiment root, `abort-replacement-r1/`; native
service invocation `0807d3138187445b8f38abc728389f62`, exit zero, 9.00 driver
seconds. Receipt SHA-256:
`90533f2071d9bfe95a11d66f9f519f5d70015af6aa4593b1241b5c3ed954cc2e`.

[`observe_fragment_abort_bus.py`](../verif/issue_uv/observe_fragment_abort_bus.py)
observes the existing, unchanged model before its native NBA evaluation, using
offsets compiled against that model's exact generated header. It does not write
guest or DUT state and requires the entire resulting architectural trace to
remain byte-identical. The first3/warm/CD=1 case proves:

- A real page fault leaves `fx_act=1`, `fx_abort_q=1`, `fx_first=2`, while a new
  crossing IDT read starts at `0x8ffd`, with size 4 and `fx_start=1`.
- That read has `bd_wstrb=0` and `mem_wstrb=0`. The L1 explicitly interprets zero
  as its legacy whole-word read, so ANDing zero with a fragment mask cannot
  narrow it.
- While **fragment 1 is still active**, AXI accepts an aligned four-byte read
  at `0x9000` (`ARVALID=ARREADY=1`, `ARSIZE=2`, `ARLEN=0`, `fbase=0x8ffd`,
  `fx_ph=0`). The first fragment should touch only `0x8ffd–0x8fff`.
  The later legitimate second fragment reads `0x9000` again. All observed
  boundaries have native NBA trigger bit 0 set, which the generated evaluator
  defines as the real rising clock edge.
- A second, hidden issue is the first-fragment selector's use of raw `fx_act`:
  on abort/replacement it selects the **old** count, not the new natural count.
  Correcting zero strobes without correcting ownership would expose an
  incorrect first mask. The zero-strobe predecessor hides that distinction.

The bus observer closes in 3.84 seconds, invocation
`8668008349c440ac85d0a13e0cf72f14`, natural guest exit 133, stable input hashes,
and an identical complete 467-record trace. Its output is `abort-bus-r1/`.
Receipt SHA-256:
`f1410effeda5e318e849ff9a9bf302987213918aacef4628280ef7d84ce11b23`.
This is a **reproduced predecessor bug**, not a repaired-model pass; ordinary
flat RAM and final read merging explain why architectural comparison misses it.
It demonstrates excess read transactions, not an observed device side effect.

Earlier exploratory host observations are retained: `gdb-r1` recorded startup
instead of the target and its separate witness audit rejects it; R2 failed
path-alias preflight before observation. `gdb-r3` correctly proves the overlap;
`abort-bus-r1` additionally proves the accepted bus transfer. None of the failed
observation attempts is counted as an RTL test or silently overwritten.

### Byte-exact correction (private)

[`prepare_fragment_exact_reads.py`](../verif/issue_uv/prepare_fragment_exact_reads.py)
now implements that correction on the exact BUS predecessor, retaining the
payload-only timing cofactor:

1. Convert a zero **read** mask to the architectural beat width before first
   fragment masking; preserve explicit read masks.
2. Capture that materialized read mask for fragment 2. Writes still capture
   their original strobes, including genuine zero-strobe writes.
3. Use the registered count only while `fx_eng` identifies a live, non-aborted
   owner. A replacement uses its natural page offset on the start clock.

No additional register, pipeline stage, stall, request permission or clock
exception is introduced. Ordinary unfragmented legacy reads are unchanged;
this is not a claim that all legacy producers have byte-exact read interfaces.
The resulting private core SHA-256 is
`a6c2c5aabddc268ae2be5b1896d1a9bc6f8780d17eb4e45c62c2f651c48a5cae`.

[`run_fragment_exact_reads.py`](../verif/issue_uv/run_fragment_exact_reads.py)
extracts the **actual sequential engine**, bus tail, output masks and L1 narrow
piece planner. The producer FSM and translation are abstracted; physical pages
are deliberately discontiguous. An independent oracle checks every touched
byte, alignment, no duplicates/excess bytes, final merge and ACK visibility.
The [testbench](../verif/issue_uv/tb_fragment_exact_reads.sv) covers:

| Sequential leaf cases | Count |
| --- | ---: |
| Crossing reads, 2/3/4-byte widths and every split | 216 |
| Replacement of old read or write/probe phases | 144 |
| Walk detours with unrelated ACK/data, frozen engine | 180 |
| Write masks, all 16 masks at four page offsets | 64 |
| Byte-piece plans checked, including stalled requests | 872 |

Read tests include legacy/explicit masks, immediate and 1/7-clock-delayed first
ACKs, different old/new offsets, and a pending-translation stall before the
second fragment. These are binary-control tests, not X-state qualification.
The unchanged predecessor fails as expected. Three mutations separately
restoring the bad first mask, bad saved mask or aborted-owner count each fail
the independent oracle. Four host source-scope/drift tests also pass.

`exact-leaf-r1/` closes native zero in 0.31 seconds, service invocation
`dfeb7683f25342fbbc5ab5f0a48488c6`, with stable pins. The Icarus sensitivity and
ignored-`unique` warnings remain in the logs. Receipt SHA-256:
`6ab35f760f0873503e1d5de5de366ce5d0ec3785560f788e8f899c18d20f5a48`.

[`build_fragment_exact_core.py`](../verif/issue_uv/build_fragment_exact_core.py)
prepares `exact-core-r1/`: all 195 predecessor files retained, exactly one RTL
delta (`core.sv`), the same 150 UV-fast definitions, a private harness and
generated-header dependency, and 470 checked input hashes. The guarded-32 build
runs after the **entire** BUS synthesis/timing sequence and closes native zero
in 20.54 seconds, invocation `693da5d25265405385508024fd1772ac`.
All input hashes remain unchanged. Model SHA-256:
`e4ed9c0c01f53b96fc7da451695feea84b9eabf0891589107711300f042f65c8`.
Build receipt SHA-256:
`50860c763f31b31ea899d825a3e00420df5f740dcb789471c0541e18aa481e57`.

[`run_fragment_exact_core.py`](../verif/issue_uv/run_fragment_exact_core.py)
reuses the twelve exact archived fixtures, regenerates all QEMU goldens, and
checks complete architectural and cycle streams at AXI latency 0/7. All
**12 cases /24 measurements** pass: **11,124 architectural records**, the same
number of cycle records, and **1,860 candidate V retirements**. Architectural
state matches QEMU and the predecessor exactly. All 24 runs use fewer clocks
than their predecessor (12–1,693 fewer); cycle differences are retained,
not represented as cycle equivalence or a canonical-cycle pass. This is a
directed overread correction, not a gameplay performance measurement.
`exact-system-r1/` closes in 9.30 seconds, invocation
`86c7d0ca61da423ab148db038ed28aaf`; receipt SHA-256:
`10ce3269fc6439efce1c051edb2c10c40a50e40b3abdefc41898e01d090b7af0`.

[`observe_fragment_exact_core.py`](../verif/issue_uv/observe_fragment_exact_core.py)
then passively observes the new native model. All **six** first1/2/3 × latency0/7
replacement cases cover exactly their four intended bytes, without extra,
duplicated or missing AXI reads. The first/second-fragment byte decompositions
are respectively `1 / 2+1`, `2 / 2`, and `1+2 / 1`. Every observation is a real
rising-edge handshake; each complete architectural trace remains byte-identical
to its unobserved run. This is host GDB observation, not guest single-stepping,
state injection or a memory-model patch. Three host checker tests reject excess,
missing, duplicate, stale-owner and non-handshake observations.
`exact-bus-r1/` closes in 26.61 seconds, invocation
`cc00703851694d41b2aa96a3260fa986`; receipt SHA-256:
`44baa669c50b6d735a65b553663f055a4c5c94f12cc75d251f50ab01d7380aca`.

### Broader core checks

The unchanged nine-fixture bus/system equivalence driver closes **FAIL** in
9.24 seconds because `pxfrag`, `pxc04`, and `pxc04e` no longer have identical
cycles to their overreading predecessor. Its full QEMU architectural checks
all pass where applicable; `pfetchlim` retains its original precise-fault
witness contract. Independent re-reading of every complete parent/candidate
architectural trace confirms exact equality in all 18 fixture/latency pairs.
No failure is deleted from the original receipt or relabelled as a gate pass.

| Changed fixture | Clock change, AXI latency 0 | Clock change, AXI latency 7 |
| --- | ---: | ---: |
| `pxfrag` | -12 | -40 |
| `pxc04` | -6 | -20 |
| `pxc04e` | -6 | -20 |

The other six fixtures have unchanged clocks. The 72-case FP matrix completes
all 288 model/latency measurements with identical full state/cycle streams;
both SMM fixtures complete all 8 measurements with identical save maps and
streams; the original REP/SMI source-cancellation checker completes all 4
measurements with identical state/cycles. These remain directed checks, not
the original standard suite or FPGA acceptance.

Evidence roots and closed SHA-256 receipts:

- `exact-system-broad-r1/`:
  `78d1e586145828c411da5a4003636cfaf07650acb1e46aecf9532c14c970c7d9`
- `exact-fp-r1/matrix/`:
  `eae588de29a9f7ba16302f6f9020d6035af4284bcc1a012e80272eb345cc6491`
- `exact-smm-r1/`:
  `e0dae399d7390db2bdc4409da5bd1e00750b1802f1df5265e0cbf51d940e3343`
- `exact-rep-smi-r1/`:
  `b5a7c112a4a3c58aa4c75c3ff7f488271950b599851e7fc9e8a553c26749efc5`

The unchanged canonical gate closes **FAIL**, native exit 2, after 392.64
seconds, invocation `d6bdd568afd142f085985339b72b277a`. All 20 complete cycle
streams remain identical to the predecessor; inputs are unchanged and no
golden masks, terminal trimming or cycle bands were modified. Receipt SHA-256:
`6bfc1d3eebbf5894177c5b0dbfd5ca5f840415d67c8073c0a9121b70d34e8fcc`.
The additional same-input replay completes all **108 programs /80,800 records**
with identical full architectural state, including the original candidate
trace, in 143.91 seconds. Receipt SHA-256:
`bbc46fb11665c302702122228522a96bc96fa80f67e0597d582d7a11ff71b5d9`.
Matching a failing predecessor does not qualify the canonical gate.

### Full-PC and frozen hardware successor

[`build_fragment_exact_soc.py`](build_fragment_exact_soc.py) independently
reopens the broad architectural streams and byte-observer evidence, retains
the original failed-equivalence/canonical results, and changes only `core.sv`
in the posted-16 PC model. All 102 shared directed RTL sources match; all 154
native definitions remain unchanged. The private-harness build closes native
zero in **23.97 seconds**, invocation `bb1b654d9b774b0eb1712dcea385dbb4`.
The 98 inherited full-PC structural warnings are unchanged, not waived.
Model SHA-256:
`c52a221ecdc0ada4671c8f8d9e27bfd1be441a85b11cabcc610999f33ed75d75`.
Build receipt SHA-256:
`0013737df3314d799793504bcbb4136dfb2366c71f760a13184244971c68e1be`.

[`freeze_fragment_exact_rk_candidate.py`](freeze_fragment_exact_rk_candidate.py)
exports all 190 hardware inputs, retaining the original 156 definitions,
40 MHz core /100 MHz PL clocks, full P5 caches and identical filelist/include
closure. Exactly one hardware payload changes: `ventium/rtl/core/core.sv`.
The source contract passes; manifest SHA-256:
`76b5cf6b0796ed944533430b065208d5b6988adbfc1859efc0bda51abe628855`.
The [frozen CPU-hierarchy lint](lint_frozen_rk_core.py) passes all six hard
structural classes in 4.13 seconds; receipt SHA-256:
`5c0b6aea396de0ff1e44b0ef621362abac4ccd0be7bb4c40072c3cc9c21a2fcc`.
This is not full-SoC lint or a new synthesized timing result.

Both original short CoreMark disks have closed successfully under
`ventium-v-carry-cm10-fragment-exact-oct11.service`, invocation
`41d29ff820a74e8a87ffbb197c439456`. The independent auditor reopens the native
commands, exits, logs, reference CRCs, source pins and actual CPU affinity.
Performance matches the predecessor's **4,767,218 ticks**, with 1,055,307 V
retirements; validation matches **4,753,406 ticks**, with 1,054,254 V retirements.
Both models exit zero with no OOM event. Audit SHA-256:
`eb54e34cd2c61c78a725f3b4f6281d63875bceb8fafbca6f76446787159340c0`.
Ten iterations are not a duration-valid CM/MHz score or the full standard suite.
There is no measured benchmark-cycle gain from this timing correction.

Disk reserve recovery consolidates twenty closed guest-recovery archives into
one lossless archive, retaining the exact original archive bytes and all
recovery receipts (**1,137,102,848 bytes recovered**). R1 first stops after
successful archive comparison on a Python Path-subscript typo, before deleting
anything; the separate completion script rechecks all members, hashes and open
handles before removing the originals. Four disposable PCH caches from the two
closed candidate builds are separately archived and member-compared
(**327,233,536 bytes recovered**). Binaries, source, ordinary headers, current
guest disks and evidence logs remain present. Restore commands and member
hashes are under `archive-consolidation-r1/completion-closed.json` and
`closed-pch-recovery-r1/closed.json`. Total recovery: **1,464,336,384 bytes**.
All removals are reversible; the shared build guard and resource floors stay
unchanged.

### Bounded timing measurement launched

[`prepare_fragment_exact_timing.py`](prepare_fragment_exact_timing.py) derives
the measurement controllers from the pinned, completed BUS experiment. Their
entire monitored process lifecycle is unchanged: one exclusive Vivado family,
8 GiB RAM /6 GiB swap caps, 13 GiB combined early stop, 2 GiB host RAM/swap
floors and 4 GiB disk stop floor. Disk admission retains twice the measured
parent growth above that floor. The synthesis timeout is 45 minutes; the
subsequent read-only original-clock timing report is capped at 15 minutes.
There is no placement, route, bitstream generation or deployment in this queue.

The queue is now live, invocation `cf4377d3fed4460986c93dc44072d514`;
the synthesis controller is `ventium-fragment-exact-synth-oct11.service`,
invocation `545d309bc1eb454faaeb68530514f97b`. The native Vivado executable
has been observed in scope invocation `cb5e0a83d1094bd09579dc323c42e900`.
The final audit must reopen the native source list and resulting checkpoint,
compare the one-core delta, and report Fmax from the unchanged 25 ns core clock.
A completed process alone does not satisfy the **at least 40 MHz synthesized
Fmax** requirement. The canonical gate remains failed, not waived.

A subsequent real-ISA diagnostic reproduces an independent
[LGDT/LIDT producer-width bug](DESCRIPTOR_READ_EXTENT.md) in this candidate
and its predecessor. Its two-arm correction is a separate private derivative;
the running synthesis inputs have not changed. This is an additional release
blocker, not evidence that the payload timing cofactor introduced the bug.

Actual post-synthesis timing, all original standard-suite components, and
physical FPGA Win95/Quake acceptance remain required. No new placement, route,
bitstream or board deployment has started for this successor.

Verified gameplay baseline is **0.51030715 total U+V simulated retirement-event
IPC**, model `2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. It predates both
timing candidates. This proposal has no gameplay measurement, CM/MHz result,
measured Fmax improvement or physical-hardware pass.
