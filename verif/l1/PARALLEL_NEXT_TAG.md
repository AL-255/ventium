# Parallel next-line tag lookup

October 13, 2026. **Private one-file timing proposal; not promoted RTL, a
timing improvement, or accepted hardware.** Full-cache and cold paged-core
checks pass; broader checks have closed with the canonical gate still red.
No new synthesis or FPGA programming
has started.

## Measured reason

The [current-tag composition](WINDOW_CURRENT_REUSE.md) synthesized at
**33.028371371 MHz unplaced**, worse than its **35.830735605 MHz** parent.
One of its worst paths is EIP → paired branch lookahead → address/DTLB →
`core_mem_next_req` → selected next-line tag RAM → compare → valid/LRU update.
The worst such reported endpoint has 105 logic levels and −5.199 ns setup
slack. This is separate from its still-worse 109-level FP-status path.

First-line tag queries already read current and next owners independently,
then select hit bits. Next-line queries instead select the address first,
add 32, read tags and compare. `prepare_parallel_next_tag.py` applies the same
parallel-query organization to those next-line tags. It selects **two Boolean
hit results after the array reads**, keeping late admission out of their
addresses. Explicit 32-bit additions preserve set/tag carries and physical
address wrap.

Only `hit_n0`/`hit_n1` generation changes under the existing
`VEN_PIPE_MEM_CHAIN` configuration. Other configurations retain the old code.
`addr_n`, `set_n`, `tag_n`, data RAM addressing, hit-way selection, permissions,
acknowledgments and every sequential update are unchanged. There is no new
feature flag, state, register, interface, cycle, stall or guest-specific rule.
The identity holds for arbitrary binary tag/valid contents and addresses;
it does not assume a legal/accepted next request or exclude crossing requests.

The extra asynchronous tag read ports may cost replicated LUTRAM/comparators.
No area or Fmax gain is claimed before measurement. This change cannot by
itself eliminate the independent FP-status path, and the 40 MHz requirement
remains unmet. The separate V-load payload selector is deferred, not included.

## Exact sources and native checks

Parent L1 SHA-256:
`a0d3ed6f8fc725975a6833facd4c87adb5ee8f8114d6dd0ea9fbb6b3982d44bf`.
Candidate:
`9b888b991ffc38034899f3c9e98bc1e04f9d37268aaba57cf13e1c0495428311`.
The guarded recipe rejects drift/reapplication; reversal restores the exact
parent. Three source/geometry tests and one fixture-insertion test pass.

Evidence root: `/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X`.

- `parallel-next-tag-leaf-r1`: **262,144 source-extracted native comparisons**
  across 16 profiles: 2/64/128/256 sets, both tag-array layouts, chain on/off.
  These diagnostic geometries do not change the full-P5 hardware configuration.
  Writable arrays cover invalid/matching tags, both ways, differing owners,
  set-to-tag carries and 32-bit wrap. Six compiled negative variants
  (reversed owner, wrong way, wrong stride; both layouts) fail as required.
  Duration **4.92 s**; scope journal records 17.2 MiB peak memory. CPU12 is
  recorded on the controller, not separately observed on every native child.
  This is a binary combinational leaf test, not cache-FSM or X/Z proof.
- `parallel-next-tag-cache-r1`: **747,037 both-edge full-cache comparisons**,
  retaining all earlier public reset/read/store/coherence stimuli and every
  data-bank/tag/valid/LRU/owner comparison. Additional passive checks compare
  next-line hits and address identity directly. Coverage includes **361,977
  next-line-hit samples, 463 next-owner samples and 6,984 crossing samples**;
  these are overlapping clock-edge counts, not unique requests. Existing
  fresh-pair coverage remains 51 cases / 41 pairs / 123 held responses.
  Wrong-stride mutation fails natively at simulation time 276,000. Duration
  **17.17 s**, peak RAM **2,673,704,960 bytes**, no swap/OOM; unchanged 152
  definitions, all six hard structural lint classes and 32 compiler jobs.
  No hierarchical writes force cache state. This is not whole-core acceptance.

| Closed evidence | SHA-256 |
| --- | --- |
| Leaf `closed.json` | `4b8146a8fb914de0d5fc3314d28e5c613a31907b00010d2cfe534f18df5e95b8` |
| Cache `closed.json` | `3ffb3031b78800e507b71b6b2894dafc617ff963c7e666c2894bb40b41739516` |

Outer leaf owner `ventium-next-tag-leaf-oct13-r1.service`, invocation
`ea6f8b069eef44e5b861396194a53293`, and outer cache owner
`ventium-next-tag-cache-oct13-r1.service`, invocation
`640c23fe562c408d9151b34c64f1d9ef`, are terminal, MainPID 0 / exit 0.
The cache's **inner** scope invocation is `2c5d648825544e2cabfe2ed1ded4c9e5`.
An initial core-preparation check incorrectly compared that inner ID to the
outer service ID and stopped before creating output or compiling. The checker
now verifies the exact outer terminal owner and independently matches the
inner journal's published result to the closed receipt. RTL and tests did
not change in response to this bookkeeping failure.

## Whole-core qualification

`build_parallel_next_core.py` prepares `parallel-next-tag-core-r1` from the
current-tag parent `737c5a8254d7d59db0558657c8c293c8e6f7e4bc255f451073c6c94776ec23d7`.
Exactly **one of 195 source files** changes; all 152 definitions, assertions,
UV/system/relocated fast paths and board single-fill policy remain. The
unique host basename is compiled against its own generated header/object.
The guarded 32-job build closes in **25.88 s**, all pins unchanged, model:
`97b11f3b4ebc54524dfe3da08fa49e42ea829d90c68481c1e029b3a5d32fcc0e`.
Outer owner `ventium-next-tag-core-oct13-r1.service`, invocation
`bbc1c3a603f84d7da3153d86d42dc936`, is terminal, MainPID 0 / exit 0.

`run_v_load_payload_system.py` replays the existing 32 cold paged
immediate/held-byte/dword fixtures against the parent and pinned system QEMU,
with AXI latencies 0/7. It passes in **40.97 s**, 256 native simulator
executions, **128 complete QEMU comparisons / 30,208 records**, with identical
parent/candidate state and cycle traces. This is a real candidate/control
comparison, not the earlier same-model fixture qualification. The independent
auditor rechecks native child identity, CPU12 affinity, terminal exit and
reaping, fault counts, image hashes and all comparisons. Peak memory is
99,160,064 bytes, no OOM, under the 1 GiB/no-swap bound. Native owner
`ventium-next-tag-system-oct13-r1.service`, invocation
`14d411a62f13478d8a7df9c74a1cae40`, is terminal, MainPID 0 / exit 0.

Candidate coverage is unchanged: 128 paired V retirements per immediate
dword/low-byte/high-byte shape (120 immediate witnesses each), 128 per held
dword/high-byte shape (zero immediate), and zero for same-bank/split/word
controls. The total 640 paired V retirements is not a gameplay IPC sample.

| Core evidence | SHA-256 |
| --- | --- |
| `parallel-next-tag-core-r1/build-closed.json` | `89e9e77874ca96e2932a1a21124663e095f9bd7310db6b3fb2e91f79f2723aa9` |
| `parallel-next-tag-system-r1/matrix/closed.json` | `c80dcf2634c2c27abd6df9d29bae7d0b2078cfef226db5a7da57575bd8cac340` |
| `parallel-next-tag-system-r1/audit.json` | `fb1fecb882be4cb5ff6ce8533ea6d82bd151842c12bb9bbe5cfd49540e18beb5` |

`run_parallel_next_checks.py` binds the unchanged canonical and qualified
private-oracle corpus to this model. Both have closed:

- Qualified private QEMU: **108/108 PASS**, 80,800 complete records, **115.89 s**.
  Independent regrading gives 105 unmasked passes plus the same three
  pre-existing stack/condition-code-mask cases (`tx_regform`, `tx_regform2`,
  `tx_stack`). No masks, goldens or comparison logic changed.
- Identical-input parent/candidate replay: **108/108 PASS**, 216 native
  executions, **80,800 fully unmasked records**, **172.46 s**. Initial ESP and
  image bytes are identical; every architectural record, clock count and
  paired-retirement count agrees, including reproduction of the original
  candidate trace. Both models retire 30,132 V instructions in this corpus;
  this is not gameplay IPC.
- Canonical `make verify`: **FAIL**, native make exit 2, **443.17 s**.
  Functional verdicts remain **7 PASS / 101 FAIL**; its cycle-band failures
  also remain failures. All **20 complete cycle traces** match the parent.
  Neither matching a failing parent nor the qualified private oracle waives
  this acceptance blocker.

`audit_parallel_next_checks.py` independently reopens traces, regrades QEMU
comparisons, checks 18,443 input pins and confirms exact terminal owners:
functional `b6499b3bf2d6480db1562a9f09acf7b4`, same-input
`91679aefcb894a09888d413d7930d07e`, canonical
`d0290785e5694f0ba5886fd6612582c0`. All have MainPID 0; the first two exit 0,
and the canonical wrapper exits 1 as required. No run was relabelled or retried
to obtain a pass.

| Additional closed evidence | SHA-256 |
| --- | --- |
| `parallel-next-tag-func-r1/closed.json` | `ecdcdf459639e58286cbbb4bb96dcc034cf51bc5434c31a0b7cd4a1affd336d4` |
| `parallel-next-tag-same-input-r1/closed.json` | `d9c72baebccafd707bcb347e13fdf9ab6f094f572e5339ca396f30ea5374b879` |
| `parallel-next-tag-core-r1/verify-closed.json` | `9537389e7060f6910b4a036514fafeff7b78fa71f2c08854b6a62415289d93ac` |
| `parallel-next-tag-regression-audit.json` | `ca4029585453809ea30a123c8b5b35b684a44e69b3badd0109fd8e12f63a3b8d` |

Remaining: green canonical gates, precise faults and full standard suite;
address the independent
FP timing path before another hardware candidate. Physical Win95/Quake
acceptance remains mandatory. The existing FPGA's Doom startup failure and
absence of Doom FPS are unchanged.

Candidate gameplay IPC is **unmeasured**. The newest verified simulation
counter window is **0.5048994 total U+V**, FP-repair model `c7b95b78`, cycles
**800,065,237–900,065,237**; [evidence](../../fpga/FP_REPAIR_EXPORT.md).
It predates this candidate, its timedemo remains active, and it is not an
FPGA or Doom measurement.
