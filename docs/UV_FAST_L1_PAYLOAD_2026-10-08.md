# UV-fast L1 payload simplification — Oct 8, 2026

**Experimental; not deployed or standard-suite qualified.** Candidate gameplay
IPC is unmeasured. Historical `53f129e9` measured **0.1659957781052303 primary/U
counter IPC**, not total U+V, over 127 qualified intervals with gaps within
cycles 8,721,490,845–19,169,282,165, frames 37–898, at 37.499869765 MHz. This
baseline predates the current deployed `1c8f20ac` image and both candidates here.
No new Quake gameplay or full movie was obtained in this round.

## Change and safety argument

Start with the [owner-restored combined candidate](UV_FAST_L1_OWNER_INTEGRATION_2026-10-08.md),
not the older frozen L1. The only additional RTL delta factors the primary
registered read-window byte selector. Previously, `window_reuse` selected a
live-offset barrel mux; otherwise a second mux used the captured offset.
For an acknowledged ordinary `rd_match`, **live address equals captured address**.
Both cases can use one live-offset selector. Critical response and window reuse
are mutually exclusive; bypass and the independent stream response keep their
saved owners and offsets. Shadow reuse retains its complete existing predicate.

No ACK, cacheability/permission check, tag comparison, state transition, cache
capacity, issue rule, or architectural register update changes. This does not
disable U/V pairing or add a global slow path/wait state. Unacknowledged payload
bits may differ; the interface only consumes acknowledged read data. A
simulation-only assertion checks the old repaired expression against the new
payload at **every consumed read**. A two-state SMT lemma proves equivalence
under these selector invariants; removing exact registered ownership yields the
required counterexample. Neither is a whole-cache formal proof.

Source patch, assertion, formal lemma and bounded replay:
[`verif/l1/payload-cut`](../verif/l1/payload-cut/README.md).
Production defaults/RTL are unchanged. The patch's required context rejects the
old `early_armed` mux; the runner also pins the exact reviewed repaired source.

## Closed UV-fast functional evidence

Root: `/home/yukidama/external/tmp/ventium-l1-primary-payload.rSTQAk`.
Source L1 SHA-256: `aba87b60f05c0ee5ee6d994d5d62fc8367440b11f80c419799727c35538b743e`.
SoC model: `2d26fc35aee8ed8eef0852050efbb28fa1e93af3aac5c063ab9616766c89f7e2`.
User model: `b24fb45044ff1547db50174125861d680632e9ab6eb0fa50880a6ea053684e6a`.
Exact 110 simulator defines are unchanged from the owner-restored parent; user
mode removes only `VEN_KV260_SOC`. Assertions and all six structural hard-error
classes remain enabled. Both builds use unique local harness object names and
checked matching generated headers, with pre/post source and binary pins.

- **40 complete candidate/QEMU state comparisons pass**, AXI latencies 0/7:
  original eight system fixtures (16), eleven expanded system fixtures (22),
  corrected stack fixture (2). No comparator changes or state removal.
- **48/48** U/V intermediate-retirement cases (`90fib4ex`) and **32/32**
  shift/Jcc cases (`uc33tfze`) pass, including actual same-cycle V execution.
- CPL3/dirty-task matrix **12/12** passes and preserves all **640 CMP/JNE pairs**.
  The four measured hot windows take **3,013 / 8,782 / 24,135 / 136,652 clocks**,
  exactly equal to both the owner-restored parent and the earlier no-FE control.
  The original system matrix also preserves every final clock count and V-pair
  count. This is not a whole-program zero-overhead or gameplay-IPC claim.
- Permission/stack replay `ventium-fe-permission-core.dghzt0bb` passes four
  QEMU diffs and four cycle checks, retaining eight hot load/ADD pairs in the
  read-only fixture and 70 paired V retirements in the stack fixture.
- Cache leaves: **8 builds / 10 scenarios pass**: window/two-window/store
  retention, packed/banked storage, stream backpressure, 64-bit reads, coherence
  races, and the full-profile critical-response retarget tests. No SYNTHESIS
  assertion waiver. These cache leaves alone do not prove whole-core pairing.

Repository replay `ventium-l1-payload-replay.UNzjzg` also closes all 8 builds /
10 scenarios successfully with unchanged pins. Its first attempt stopped before
any build: Python's default subprocess FD closure hid the enclosing scope's
inherited lock from the read-only ownership probe. The runner now preserves FDs
for that probe; the actual cgroup/lock checks remain mandatory. The failed
runner and explanation are retained, not counted as a DUT result.

Required `make verify` rerun `verify-r2` closes **FAIL**, exit 2. It retains the
seven functional passes / 101 terminal-exit or cap-boundary length-only failures,
plus `mb_dmiss`'s existing cycle-band failure (4,154 versus 20,524 clocks). No
slow-mode run or relaxed comparison substitutes for this gate. The first
attempt exhausted its 600-second envelope after spending most of it queued
behind the isolated Vivado scope; exit 124 and partial logs are preserved, not
counted as DUT correctness evidence. The fresh bounded rerun completed normally.

**Subsequent backend audit:** that `verify-r2` run used direct memory, not the
L1/AXI backend. A separate full AXI rerun retains 7 functional passes / 101
length-only failures and measures `mb_dmiss` at 41,037 clocks. See the
[configuration repair and native replay](UV_FAST_VERIFY_BACKEND_2026-10-08.md).

## Isolated routed-cache result

Root: `/home/yukidama/external/tmp/ventium-l1-payload-physical.vhwuN4`.
One exclusive Vivado 2025.2 family, `xczu15eg-ffvb1156-2-i`, identical full cache
option profiles, 25 ns clock, zero external input/output delays. Real `ven_l1d`
and its pair helpers are synthesized and routed, not a hand-written mux proxy.
Native exit 0, input pins unchanged, zero routing errors, peak sampled cgroup
memory **5,869,088,768 bytes (5.47 GiB)** under an 8 GiB/no-swap cap. Closed; no
orphan Vivado, full-system implementation or bitstream was launched.

| Routed leaf quantity | Owner-restored control | Payload candidate |
|---|---:|---:|
| Total LUTs | 21,400 | 20,009 |
| Logic LUTs | 19,352 | 17,961 |
| LUTRAMs | 2,048 | 2,048 |
| FFs | 6,876 | 6,878 |
| Address port → data port | 7.421 ns | 6.237 ns |
| Address port → ACK port | 6.091 ns | 5.165 ns |
| Worst setup budget equivalent, **not CPU Fmax** | 64.9 MHz | 66.7 MHz |

Observed routed LUT reduction: **6.5%**; queried data-path delay reduction:
**16.0%**. The source has no new pipeline register; the two mapped FF difference
comes from synthesis/mapping. Changes in unrelated mapping/placement contribute
to these leaf measurements; the ACK expression itself did not change. Hierarchy
LUT attribution is not a reliable isolated-module cost after optimization.

Both leaves report WHS **−0.080 ns** with these artificial zero-delay IO
constraints. Their external arrival times, full-core paths and whole-chip
congestion are not modeled. The MHz equivalents are derived from this local
setup budget only; they do **not** qualify either leaf's IO interface or prove
the complete CPU operates at 40 MHz. The board remains at its previously probed
40.000339 MHz with the prior failed run stopped.

## Remaining work

Resolve the generic UV-fast trace-boundary gate without hiding architectural
divergences. Inspect the combined whole-core critical paths before another full
implementation. Then qualify both CoreMark seeds, Win95 boot-to-desktop, and
the original cold 40 MHz UV-fast Quake timedemo with the complete raw-color
movie. The original FPGA invalid-next-PC cause is not yet proven; this local
optimization and its microbenchmarks are not a completed Quake repair.

## Captured CMP/JP regression, still UV-fast — Oct 8, 10:54 UTC

Evidence: `/home/yukidama/external/tmp/ventium-uvfast-jp-replay.8pPmfM`.
The unchanged SoC model above replays the exact private cold ROM that failed
on the board, SHA-256
`e6b20263852628770d3d9de0e8834681a7da844cd2f88ece2a7bd8ec95195f8a`.
This is the diagnostic JP variant with its synthetic caller and exception
logger, **not the original Quake timedemo**. It does not modify production media.
Both `--cycle` and `--cycle-func` drive `cycle_mode=1`; `--l1-axi` is explicit,
assertions stay enabled, and no STEP, breakpoint or pairing-disable is used.

The passive-observer matrix uses reset seeds 1/2/14/15, AXI latencies 0/3/7/13,
and response gaps at latencies 3/7. All eight native runs finish normally.
Seven original consumer checks pass. The latency-7 cycle case remains **exit 3**:
it lacks the required retained predicted-taken/actual-not-taken coverage for both
owners. It still observes all 64 target CMP/JP pairs and all 64 preceding
cross-line CMP/JNE pairs, correct addresses/data/flags, and no exception. The
whole observer matrix remains **FAIL**, not 8/8 or a waived coverage pass.
The initial driver preflight's relative-manifest-path error occurred before
launching any model; its failure record is retained separately.

A separate `full-state/` run enables the ordinary system co-simulation I/O
backend and reaches natural `OUT F4` termination, **native exit 133**, in all
eight RTL runs. Pinned Pentium QEMU independently exits 133. The four complete
cycle-functional traces, **15,555 instructions each**, match the fresh QEMU
golden through the unchanged full architectural comparator. No truncation,
new flag mask or fabricated exit state. Each cycle trace follows that same
complete PC sequence and contains all **64 target + 64 preceding U/V pairs**.
The source, executable and consumer pins are unchanged before/after. These
four full-state passes do not erase the observer matrix's separate coverage gap.

The retained historical consumer prints its original ALU source hash; that is
**not this model's provenance**. This model's ALU hash is
`3001ae4833b49f9b14d31c6685add9a81c0949443c25681b76fa15afdf9e3058`;
the decode/package bytes and 211-bit packet layout remain identical. Actual
model/source pins are in `inputs.json`, not the old consumer's descriptive text.

Only two native tests run at once in a separate 3 GiB/no-swap scope while the
existing synthesis continues. Both replay scopes are closed, not orphan jobs.
There is no simulator rebuild, board programming, clock change or new RTL
change in this replay. It adds regression coverage for the integrated repairs;
it does **not** establish the cause or repair of the board-only bad-PC failure.
Candidate gameplay IPC remains unmeasured; the historical baseline at the top
of this document still predates this candidate.
