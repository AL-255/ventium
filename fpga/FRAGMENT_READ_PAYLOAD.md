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

The unchanged canonical gate is still running. The predecessor's canonical
gate remains **FAIL**; matching that predecessor cannot qualify this proposal.

Only after those checks should a frozen full-PC/hardware derivative be exported
and its real post-synthesis timing measured. All original standard-suite and
physical FPGA Win95/Quake acceptance remain required.

Verified gameplay baseline is **0.51030715 total U+V simulated retirement-event
IPC**, model `2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. It predates both
timing candidates. This proposal has no gameplay measurement, CM/MHz result,
measured Fmax improvement or physical-hardware pass.
