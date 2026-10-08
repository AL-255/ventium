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

Next: capture the genuine intermediate U architectural state before V writes,
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
