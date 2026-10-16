# Early backing direction — October 16

**Private experiment; not accepted, synthesized or deployed.** This follows the
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

AXI R1 failed before any build because the launcher omitted the guard's `--`.
R2 failed elaboration because its inherited fixture omitted the current
`c_payload_cacheable` input and referenced the old flat tag array. R3 binds the
real input and compares both actual LUTRAM tag ways. No candidate RTL, stimulus,
compiler error policy or active-output check was relaxed; failed owners/logs
remain separate. The R2 driver is preserved beside its native log.

## Still open

New directed CPU model:
`e6194aa6b3f98cb7ef4cdb955377989ac45c441bde843021b535358c61e16993`.
The unchanged canonical gate has started under
`ventium-backing-direction-verify-oct16-r1`, invocation
`1ca5551187134759b08de2eafe291e44`, with a 600-second native timeout. Its parent
gate is red; neither directed passes nor parent-identical cycles waive it.
Fresh functional, broader faults/ordering, full-PC/source-transfer and timing
qualification remain required. No new Vivado process has been launched.

There is **no measured fmax or IPC gain** for this experiment. Its gameplay IPC
is unmeasured, as is the separately running V-result cold-Quake model
`b6b92dbf…`. Latest verified older gameplay baseline remains **0.48146083 total
U+V IPC**, model `7e877b3b…`, cycles **1,100,065,247–1,200,065,247**. Full standard
suite and matching physical FPGA Win95/UI plus completed Quake timedemo remain open.
