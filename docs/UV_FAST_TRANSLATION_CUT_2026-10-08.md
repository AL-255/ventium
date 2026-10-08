# UV-fast registered-translation experiment — Oct 8, 2026

**Not a Quake fix or FPGA acceptance.** The deployed `1c8f20ac` image, repaired
`5a56eec6` RTL and this candidate have no qualified gameplay IPC. Historical
`53f129e9` measured **0.1659957781052303 primary/U-counter IPC**, not total U+V,
across 127 qualified intervals with gaps within cycles
8,721,490,845–19,169,282,165 (frames 37–898, 37.499869765 MHz). It predates these
candidates. The board was not reprogrammed or switched to U-only/slow mode.

## Implemented privately; production unchanged

The preceding one-entry `VEN_FE_PIPE` experiment cut the combinational
translation result path but repeatedly evicted three/five hot data pages.
Its extra latency is unacceptable to hide behind a passing functional test.
`VEN_FE_PIPE` here means a translation-register experiment; the ordinary system
fast pipeline remains enabled regardless of that experimental flag.

The replacement retains eight registered page/PFN/hit/dirty entries, with
parallel exact-page lookup, update-in-place and invalid-first/round-robin
replacement. It caches negative lookup results so the next cycle can enter the
walker. Reset, context flush, and **every parent DTLB fill** invalidate the whole
child cache before any capture. This includes dirty-bit rewalks and unrelated
fills that could evict a parent permission entry. The parent still owns
permissions, access classification, faults and architectural TLB organization.
No guest-specific address handling, extra cache capacity in the architectural
DTLB, forced pairing, unconditional memory bubble or slow-mode workaround.

Source and deterministic leaf regression are preserved under
[`verif/fe_pipe`](../verif/fe_pipe/README.md), outside production filelists.
The integration patch is a proposal, not an enabled default. Private full-core
source/builds/results: `/home/yukidama/external/tmp/ventium-fe8-uv.YM6Hw6`.
Its source is frozen repaired107 plus the proposal, with only `VEN_FE_PIPE` and
`VEN_FE_DTLB_MULTI` added to the exact 107-definition profile. Native SoC model:
`963c321e7b03bbd445b96dae0dab66e876d28ec5227a5129e00bab64d6419408`.
Build uses 32 jobs, assertions, all six hard structural classes, unique harness
object names and checked generated-header dependencies. Source pins close cleanly.

## Measured microbenchmark result

All rows use actual same-cycle U/V CMP+JNE retirement at CPL3, relocated segments,
paging and full fast memory paths. Warm interval is the second through last CMP;
these are microbenchmarks, **not gameplay IPC**.

| Fixture / AXI latency | Original no-cut clocks | One-entry cut | Eight-entry cut |
|---|---:|---:|---:|
| Three hot pages / 0 | 3,013 | 3,323 | 3,013 |
| Three hot pages / 7 | 8,782 | 8,787 | 8,782 |
| Five pages + D-cache conflicts / 0 | 24,135 | 25,406 | 24,135 |
| Five pages + D-cache conflicts / 7 | 136,652 | 136,652 | 136,652 |

Thus the prototype removes the one-entry cut's 10.29%/5.27% added warm cycles
in the zero-latency fixtures; it does **not** outperform the original no-cut
implementation in these windows. Cold fill/invalidation latency remains.
`warm-timing.json` records exact windows and 640 required U/V pairs.

Closed checks:

- Leaf: 520,844 checks; duplicate-owner, eviction, cached miss, dirty update,
  tag alias, reset and invalidation/capture collisions. Repeated against the
  committed-source copy in `ventium-fe-dtlb-leaf.dUoN1y`.
- CPL3: 8/8 cycle/state runs, AXI latency 0/7; 640 actual U/V pairs in the four
  cycle traces. Architectural-state checker also passes.
- Task-switch/dirty-page `pdtlbw`: 4/4 UV-fast runs exit 133; pinned Pentium QEMU
  independently exits 133. Not a slow-mode control.
- Shift/Jcc: 32/32 original full-core cases pass, requiring actual U/V pairing;
  evidence `ventium-uv-shift-branch.a27y2a9n`.
- Eight paging/fault images (`ppage`, `pfault`, `pxfrag`, `pxwalkd`, `pdtlbassoc`,
  `psgdtpg`, `pbytemovpg`, `ptaskpg`), both control/candidate and AXI latency 0/7:
  all 32 native runs close at expected exit 133. All 16 complete candidate-vs-
  control architectural traces match; terminal states match QEMU. **All 32 full
  QEMU differentials remain red**, as explained below. Evidence `system-r3/`.
- Required `make verify`, same full-address profile/production harness as the
  previous repaired control: **108/108 functional PASS**, but **gate FAIL** on
  the existing `mb_dmiss` band (4,154 vs 20,524 clocks). No tolerance/golden
  changes. Its default functional runs are controls, not UV-fast acceptance.
  Evidence `verify-r2/`, `verify-r2.log`; binary
  `e6d5f15d1dbfb258ece39b4c7a2bb0692921ad33b27f9d0c62ba3cd009ebf13a`.

Failed setup attempts remain distinct: initial full-address build included a
SoC-only observer and failed compilation; R2 uses the existing production
harness with a unique basename. First `make verify` omitted the established
200,000-clock quiescence allowance and prematurely stopped BCD/FPREM engines;
R2 restores that allowance. Paging prep failures were missing relative linker/
assembly-include paths; no failed invocation was counted as a native test pass.

## Confirmed U/V retirement-trace defect — do not mask it

**Follow-up:** the integer-pair observation defect below is repaired in the
no-translation-cut control, where all 16 paging QEMU comparisons now pass with
unchanged cycle/pair records; see
[the repair evidence](UV_FAST_RETIRE_STATE_2026-10-08.md). The translation-cut
prototype itself remains unqualified and outside production filelists.

Before that repair, `core.sv` assigned **both** `retire_state` and
`retire2_state` to the live `snap`.
After a pair commits, that state includes V's writes. Consequently the primary
U record can contain changes belonging to the following V instruction. The
comments explicitly restrict state-checked use to non-paired mode, but
`--cycle-func` exposes the defect while keeping `cycle_mode=1`.

Concrete example in `ppage`: U at `0xf007e` is `MOV ESP,0x90000`; V at `0xf0083`
is `MOV EAX,0x11111111`. Both control and candidate report `EAX=0x11111111` in
the U record, while QEMU correctly retains `0x60000010` until V. The native
paths/exits agree, but this is a real violation of the per-instruction trace
contract—not permission to bless the failed differential. Later U stores also
inherit a following V ADD's EAX/flags. No comparator masks or pairing switches
were changed to conceal it.

The resulting next step was to capture genuine intermediate U state before V writes,
keeping final V state and actual retirement cycles unchanged. Add directed
register/flags/narrow-write/memory-pair tests, then rerun the unmodified full
QEMU comparator in UV-fast mode. Do not fix the checker by inventing states
from QEMU or rerunning the workload U-only.

## Still required

The prototype has no placed/routed frequency or area result. Eight retained
translations do not prove a 40 MHz fix; parent permission and V-side translation
paths remain combinational. Memory-chain/prime variants are wired but untested
and are absent from this exact profile. Larger working sets and repeated parent
fills can still pay registration stalls. Full timing/area assessment, the
remaining system-mode gates, both CoreMark seeds, Win95 desktop, and the original
cold Quake timedemo at 40 MHz plus full raw-color movie remain open. No new
bitstream build or reduced-clock acceptance run was launched in this round.

Final read-only board check measured 39.999862020 MHz, guest held in reset,
zero retirement delta over five seconds. Four closed generated full-model PCH
files (350.88 MiB) were removed to reclaim scratch space; binaries, object/archive
files, sources, failed attempts and all native evidence remain. PCHs are
rebuildable. External scratch has about 907 MiB free; no Vivado is running.

## Combined candidate: genuine UV architectural checks now pass

After the observer repair (`09ca5a64`), the eight-entry prototype was rebuilt
in a **fresh private tree**, leaving the closed earlier evidence unchanged:
`/home/yukidama/external/tmp/ventium-fe8-uv-snapshot.oZVtMZ`.
The SoC binary is
`bdadc0c87f4ad73650f351e6103dbe82842b179e7d7e62b880845367bf684d65`.
The full-address user binary is
`7377871fa6dc0a38b6f2d6e4f646a5fac5fa5fdfce707c0f95a3151370dfdf8a`.
Definitions remain the frozen 107-profile plus only `VEN_FE_PIPE` and
`VEN_FE_DTLB_MULTI`; user-mode removes only `VEN_KV260_SOC`. Both native
models use unique harness objects, 32-job bounded builds, assertions and hard
structural errors. Inputs and native hashes close unchanged.

- **16/16 full paging/fault comparisons against QEMU pass**, without changing
  the comparator or suppressing V. The no-cut snapshot-repaired control also
  passes all 16. All 64 cycle/state × control/candidate × latency native runs
  close at expected exit 133. Entire instruction sequences and paired-V counts
  are preserved in all 16 cycle comparisons.
- **48/48** directed U/V retirement cases pass
  (`ventium-uv-retire-pairs.bxz2_ey9`), including genuine same-clock pairing and
  individual post-U/post-V states. Shift/Jcc stays **32/32**
  (`ventium-uv-shift-branch.badki10x`).
- CPL3/task-switch matrix passes **12/12**. All 640 CMP/JNE pairs remain real
  same-clock U/V retirements. The four warm-loop deltas versus the no-cut
  baseline are all **zero clocks**. Whole cold paging fixtures incur **6–242
  extra clocks (0.049–1.288%)**, rather than silently claiming zero cost for
  registration/invalidation. These figures are not gameplay measurements.
- Required `make verify` on the combined candidate's actual UV-fast state
  mode remains **red: 7 functional passes / 101 length-only failures**, plus
  the existing `mb_dmiss` band. All 108 comparator outputs were inspected;
  the terminal-record limitation described in the observer report remains.
  No comparator, golden, timing tolerance or execution mode was changed.

`summary.json`, `system/`, `micro-r2/`, `warm-timing.json`, `verify/` and
`final-pins.log` retain the detailed closure. The initial no-argument invocation
of the separate source-profile checker was a preparation error, not a test
pass; the runtime guard's seven tests passed. No board register was changed.
The candidate is still private, not a standard-suite pass or FPGA repair.

## Isolated routed physical probe — useful but not whole-core timing

Three source-pinned leaves completed synthesis, placement and routing on
`xczu15eg-ffvb1156-2-i`, Vivado 2025.2, with the actual P54-large four-way
parent TLB and its independent V lookup retained. The identical registered
input/output boundaries make the local path comparison meaningful; they omit
decode, segment/address generation, L1, forwarded flags and CPU next-PC logic.
Source and replay procedure: [`physical/`](../verif/fe_pipe/physical/README.md).
Evidence: `/home/yukidama/external/tmp/ventium-fe8-physical-leaf.jiyQLe`.

| Routed local metric | No cut | One entry | Eight entries |
|---|---:|---:|---:|
| U query register → physical-address result (ns) | 6.165 | 2.943 | 4.300 |
| Any register → physical-address result (ns) | 6.165 | 3.346 | 4.300 |
| U query → parent permission result (ns) | 5.543 | 4.420 | 5.524 |
| V query → V physical-address result (ns) | 3.844 | 4.530 | 4.856 |
| Total leaf LUTs, including parent + wrapper | 2,883 | 2,693 | 2,863 |
| Total leaf FFs, including parent + wrapper | 3,403 | 3,461 | 3,762 |
| Local internal setup-equivalent MHz, **not CPU Fmax** | 130.6 | 143.9 | 132.8 |

The last row is `1000/(25 ns − worst internal setup slack)` under the leaf's
ideal external clock. Its limiting path is parent fill/victim logic, not CPU
execution. Ports deliberately lack I/O delays/partition locations, so the
tool's OOC port warnings remain visible; unconstrained **internal** endpoints
and routing errors are zero. External clock/I/O routing and real core congestion
are not qualified. There is **no new CPU Fmax**; the unchanged board is 40 MHz.

The eight-entry child itself costs **201 LUTs / 347 FFs**. Parent remapping
changes the combined area, so the net leaf LUT difference is not a promised
CPU-area saving. Its U address path improves **1.865 ns (30.25%)**, but the
parent permission path barely changes and the V path worsens in this placement.
Thus this is evidence for a limited data-path cut, **not** evidence that the
~49.7 ns measured full-core live-PC path has become a 25 ns path. The one-entry
variant is still rejected for the measured hot-page thrashing despite its
smaller/faster local circuit.

All three native flows close successfully, source pins hold, and the exclusive
Vivado scope is inactive. Peak sampled cgroup use was **4,367,261,696 bytes**
(8 GiB cap, no swap), with no resource-stop/OOM event. No production DCP,
bitstream or board state changed. Next structural investigation is the retained
permission/fault-admission dependency; any additional cut must preserve live
CPL/WP checks, parent-fill invalidation, fault priority, task switches and
fragment probes, and must be verified in UV-fast mode before integration.
