# Read-fragment payload timing experiment — October 11, 2026

**Leaf-qualified proposal only. No whole-core, synthesis or FPGA result.**
The active bus-cancellation synthesis is unchanged. The last measured parent
is still **26.55408 MHz**, below the required 40 MHz. This proposal has not been
merged into production RTL or scheduled for another synthesis.

## Reason and exact scope

The [shift candidate's original-clock report](U_SHIFT_REGISTER_OPERANDS.md)
contains the chain from instruction length through segment faults, fragment
strobes, last-byte memory classification and cache-response payload selection
into the shared FPU. The separate V response-capture path is also below 40 MHz;
optimizing only SRT normalization cannot resolve that measured parent.

The [bus-payload candidate](BUS_CANCEL_PAYLOAD.md) removes late cancellation
from the bus driver's unused payload, but its read-fragment byte mask still
uses `fx_start`, including the late miss/permission/segment-fault conditions.
Whether this remains critical must be checked against that candidate's pending
netlist report; source structure alone does not establish a timing gain.

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

The next correction must materialize the architectural read width before
fragment masking and latching, choose the new count on replacement, preserve
write strobes and walk-detour behavior, and retain the late-fault-free payload
selection. It must be tested against exact touched bytes, not only register
results or equivalence to this defective predecessor.

First inspect the in-flight bus candidate's actual timing. If this cone remains
limiting, build the private derivative under the shared compiler guard, then
run full source-matched fragment/fault/A20/SMM/REP and FP regressions at multiple
AXI latencies, complete architectural/cycle comparisons, and unchanged canonical
gates. Include abort/replacement with different old/new page offsets, walk
detours, cancelled reads and retained responses. The predecessor's canonical
gate remains **FAIL**; matching that predecessor cannot qualify this proposal.

Only after those checks should a frozen full-PC/hardware derivative be exported
and its real post-synthesis timing measured. All original standard-suite and
physical FPGA Win95/Quake acceptance remain required.

Verified gameplay baseline is **0.51030715 total U+V simulated retirement-event
IPC**, model `2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. It predates both
timing candidates. This proposal has no gameplay measurement, CM/MHz result,
measured Fmax improvement or physical-hardware pass.
