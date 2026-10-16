# Early backing direction — October 16

**Private experiment; synthesis running, not accepted or deployed.** This follows the
corrected wrapper's [34.6524 MHz unplaced result](../issue_uv/V_RESULT_CARRY.md).
It does not repeat the rejected address/strobe mux experiment.

The late L1 request-valid signal also selected backing-write direction, putting
request/route qualification before downstream extent/paired-credit logic.
`prepare_backing_direction.py` selects direction from idle/fill state, stream
mode and U/V write shape instead. **Only inactive `m_we` may change.** Every
active beat and every `c_req`-qualified credit query retains its old direction;
all other backing outputs are unchanged. Request, credit, cache, ordering,
latency and architectural retirement equations are untouched. The default
non-dual-store profile keeps the original producer. There is no extra stage,
global slow path, pairing disable or workload-specific behavior.

The exact-source recipe rejects drift/reapplication. Parent L1 SHA:
`62d3332d4d044efe022acce33eaa99b16e9a36da7a43e4afeda0b0265baeb3f3`.
Derivative SHA:
`558edc45ea6500949b66311c3f7727cae8a39a81337de8fac4c632b01429a9f9`.
No live Quake input, accepted image or production RTL was overwritten.

## Closed checks

Evidence root: `/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4`.

| Check | Result |
|---|---|
| `backing-direction-leaf-r1` | Three profiles × 524,520 comparisons, including 232 directed X/Z cases per profile; four deliberate mutants rejected; 9.975 s |
| `backing-direction-axi-r3` | Two complete L1s, independent real AXI masters and byte-addressable RAM; 4,781 miter observations; positive passes and fill-as-write mutant fails; 9.379 s |
| `backing-direction-core-r1` | Native whole-core build exits 0; all 195 sources audited with exactly one delta and the same 153 defines; private host object/header checked; 19.857 s |
| `backing-direction-mixed-r1` | 36 cold paged/relocated U-load/V-store fixtures × latency 0/7, 144 A/B measurements; complete QEMU state and exact parent cycles; 10.110 s |
| `backing-direction-core-r1/verify-closed.json` | Canonical `make verify` **FAIL**, native exit 2, 385.492 s; unchanged parent failure inventory and all 20 complete cycle streams parent-identical |
| `backing-direction-matched-r1` | 108/108 complete functional A/B streams identical with matched image/initial ESP: 80,800 records, no masking or normalization; 48.166 s |
| Host source/build guards | Six tests pass, including exact reversibility, independent direction, original default branch, observable-credit checks and regraded native evidence |

The AXI test checks every channel signal, consumed credit, cache data/tags and
staged ownership state against the parent; all 65,536 final RAM bytes match.
It exercises 68 U stores, three V stores, one quad-combined pair, one U-load/
V-store pair, 30 blocked-store clocks and 84 full-queue clocks. Its 2,024 idle
direction differences cause no bus or architectural effect. Stimulus uses
public requests/reset/coherence ports and initialized backing RAM, not forced
cache/credit state. It does **not** instantiate the route/SMRAM seam.

The whole-core mixed run observes **240 actual V stores**, 1,140 held-read and
312 paired-read witnesses. It uses `--cycle-func`/`--cycle`, actual `--l1-axi`,
`cycle_mode=1`, fast relocated protected-mode load/store definitions and no STEP,
breakpoints, saved state or guest patches. Stored signatures are read back
immediately. Same-bank and unaligned cases must fall back without V retirement.
This is directed correctness evidence, not gameplay IPC or standard-suite acceptance.

Successful retained owner invocations:

- Leaf: `894e68af51a84545874c1ffe38961e2b`, 19,529,728-byte peak, no OOM.
- AXI: `79baf73b7f2d4fb79a9f5d5e85b65e8d`, guarded scope peak
  2,201,169,920 bytes, no OOM; 32 compiler jobs, native CPU 12.
- Core: `143465ec9dce4500a54d23bdf06ad6fd`.
- Mixed: `5246ba1cc6fb48a3a25595a34ab742e3`, CPUs 16–19.
- Canonical: `1ca5551187134759b08de2eafe291e44`; native child affinity
  0–3 observed. The existing canonical script forces one worker despite the
  four-worker request; it was not modified.
- Matched replay: `706cc1382fa246dd903d56aa6d578ba8`, 32 workers.

AXI R1 failed before any build because the launcher omitted the guard's `--`.
R2 failed elaboration because its inherited fixture omitted the current
`c_payload_cacheable` input and referenced the old flat tag array. R3 binds the
real input and compares both actual LUTRAM tag ways. No candidate RTL, stimulus,
compiler error policy or active-output check was relaxed; failed owners/logs
remain separate. The R2 driver is preserved beside its native log.

## Canonical failure inventory

`backing-direction-canonical-inventory-r1.json` regrades the retained native
results: **7 functional passes, 101 failures** (90 length-only and 11 x87
field-mismatch failures), the same inventory as the parent. No golden, mask or
cycle band changed. The canonical reference lacks the separately tested private
pre-exit/x87 repairs; this does not authorize ignoring its failures. All 20
complete RTL cycle streams match the parent, **not** all cycle bands pass.

Independent canonical invocations produced different initial ESP values in six
programs. The separate matched replay reran the parent with the candidate's
exact images and initial ESP; **all 108 complete streams then matched** without
normalizing records. This is a regression comparison, not a fresh QEMU run or
a canonical pass. Both models and all pinned inputs remained unchanged.

## Still open

New directed CPU model:
`e6194aa6b3f98cb7ef4cdb955377989ac45c441bde843021b535358c61e16993`.
The unchanged canonical gate completed within its 600-second native timeout
and remains red; neither directed passes nor parent-identical cycles waive it.
Fresh functional, broader faults/ordering and timing qualification remain
required. The new synthesis is diagnostic, not acceptance (owner below).

## Full-PC and FPGA transfer

`fpga/build_backing_direction_soc.py` built `backing-direction-soc-r1` in
**22.944 s**, native exit 0, owner `d6448d56645a4ca5b4366bc8a69b9b3e`.
Its **102 common processor sources** exactly match directed model `e6194aa6…`;
only `rtl/mem/ven_l1d.sv` differs from V-result/AUX PC `b6b92dbf…`. All 157
definitions, peripherals and posted-16 backend remain unchanged. The private
host object was compiled locally against its own generated header. The build
retains **98 inherited structural warnings**, not a full-SoC lint pass.
Guarded compilation used 32 jobs; its journal reports a 3.1 GiB peak.

New PC binary:
`810840218013b9e8ec8f3fbc1f0f39da8dbdcbd8b9c09021ba03ea27036014bd`.
`backing-direction-fpga-r1` audits **170 common compiled HDL inputs**, retaining
all 192 payloads and the corrected posted-DDR mouse wrapper. Exactly one FPGA
payload changes; no clock, define, geometry or flow changes. Export manifest:
`a241b7f819886adc58ca2fb1e2b3697222f0232754911a814e66a4c061af28a5`.
Posted and non-posted preprocessing both retain the mouse devices; this is not
full-wrapper simulation or physical UI acceptance.

Strict CPU-hierarchy lint passed under all **159 hardware defines** in 3.879 s,
owner `615624b59e564afc87ab18c297cff5f8`, with the original structural-error
policy. Twelve transfer/export/controller tests pass, including negative source,
profile, pairing-evidence and resource-guard tests. The prepared CAD controllers
preserve the exclusive owner, 8 GiB RAM cap, admission/stop reserves, timeouts
and termination/reaping logic. Comparison is against the **corrected-wrapper
34.652436 MHz unplaced parent**, isolating this one RTL delta. They do not route
or deploy a bitstream.

Both short cold CoreMark controls closed successfully under owner
`b63f748ce1a941d9850007336e657d18`. The independent audit rechecked **19,760 pins**,
actual native CPU 12, posted-16 AXI activity, exact startup arguments, seed CRCs
and all child closures, with no OOM events. Performance/validation counts are
**4,767,218 / 4,753,406 cycles**, identical to the immediate V-result parent:
**0% cycle-performance gain**. Actual V retirements are **1,055,307 / 1,054,254**;
native run times are 215.260 / 217.307 s. These 10-iteration controls are **not
duration-valid scores or full standard-suite seeds**.

Synthesis started at **2026-10-16 02:20:55 UTC**, retained controller
`ventium-backing-direction-synth-oct16-r1`, invocation
`a30dff0226e74df2a2c042cb872a7c2b`. The single native Vivado family was observed
inside `ventium-vivado.scope`, invocation `166f281a472643559661e1ec2c9d1432`,
with enforced 8 GiB RAM / 6 GiB swap / 48-task limits. `watch.jsonl` retains
resource samples and 4 GiB disk / 2 GiB host reserve stops. Native synthesis
closure, independent DCP/source audit and read-only timing reports are pending;
there is **no new measured frequency result yet**.

Cleanup recovered 1.08 GiB without removing a native binary or pinned input:
eight unreferenced closed-build PCH caches are rebuildable; eight closed raw
timing reports are losslessly retained in `latest-clock-cones-oct16.tar.zst`.
Every archived member was SHA-256 verified by readback before removing the raw
copy. Exact paths/hashes and restoration instructions are in the adjacent
`latest-clock-cones-oct16-closed.json`; cache removals are recorded in
`backing-direction-pch-prune-oct16.json` and
`backing-direction-pc-pch-prune-oct16.json`. No live Quake source or media changed.

There is **no measured fmax or IPC gain** for this experiment. Its gameplay IPC
is unmeasured, as is the separately running V-result cold-Quake model
`b6b92dbf…`. Latest verified older gameplay baseline remains **0.48146083 total
U+V IPC**, model `7e877b3b…`, cycles **1,100,065,247–1,200,065,247**. Full standard
suite and matching physical FPGA Win95/UI plus completed Quake timedemo remain open.
