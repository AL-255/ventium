# Gameplay IPC: current-build full-state attribution (2026-09-26)

The measured combined wave9+VGA reference executable is SHA256
`b278c988be64f7eaae0ab56b21faafd5dfcee250984136c9dd628a332513c247`.
At clocks 1,100,000,000–1,101,000,000 its 1,000,000-cycle native state trace
records **0.564642 gameplay IPC** (564,642 edge retirements). The broader
same-build 1,050–1,100M window records **0.44577548 IPC**; the short trace is
not a substitute for that representative window. An opt-in FP-branch candidate
has since measured **0.578894 IPC** (578,894 edge retirements) on the exact
same 1,100,000,000–1,101,000,000 snapshot workload, an improvement of 14,252
retirements or 2.52%. A subsequent 50M-cycle A/B replay over
1,100,000,000–1,150,000,000 measured **0.44414178 IPC** for the reference
(22,207,089 retirements) and **0.44963946 IPC** for the opt-in branch candidate
(22,481,973 retirements), a 1.24% IPC gain. The 50M results start from the
same private copies of the cold-boot-derived checkpoint and use identical
clock, RTC, VGA, DDR and disk settings; the source bundle still verifies, and
both private disks remain byte-identical to it. They are matched-start,
fixed-clock gameplay measurements, **not** fixed-work instruction comparisons.
The candidate has **not** completed a cold-boot Quake timedemo or Win95 desktop
acceptance run.

The opt-in candidate has now completed an independent, resource-guarded cold
reset from the unchanged Quake boot disk to exactly 100,000,000 clocks. It
launched the normal FreeDOS Quake command and saved a validated same-build
checkpoint in `tmp/build-tmp/ventium-fp-branch-cold100m-sep26/`. Against the
source-matched flag-off cold run, both have exactly 32,212,074 retirements,
447 host disk reads, the same final CS:EIP (`00a7:00044d60`), byte-identical
native snapshots (SHA256 `ca0899f3bcbfea162ecc9512f094ddede948ef043dce2dc657395bad04b39a56`)
and byte-identical private disks (SHA256
`2df14ac9ae5f927cab2410e784d14c655f0e96644ca80ced3c0b012df7a36e4c`).
This is strong cold-start non-regression evidence, but the branch overlap path
apparently does not perturb this interval; it is still initialization, not a
fresh gameplay IPC or completed timedemo result. The remaining long Quake and
Win95 cold-boot acceptance is open.

The branch experiment is `+define+VEN_FP_ASYNC_BRANCH` in
`rtl/core/core_fp_async.svh`. Its full-PC generated-model manifest differs
from the reference in only that source file and define, and the generated
root, symbols and package snapshot serializers are byte-identical. A private
copy of the verified 1.100B bundle restored at the same retire count and
settings, and saved at 1.101B without modifying the source bundle. The
candidate replay log and build are in
`tmp/build-tmp/ventium-vga-wave9-fp-branch-replay-sep26/` and
`tmp/build-tmp/ventium-vga-wave9-fp-branch-sep26/obj/`. This is a
cross-build performance diagnostic, **not** the same-binary checkpoint or
full-system acceptance policy. The 50M replay logs/endpoints are under
`tmp/build-tmp/ventium-vga-wave9-50m-{control,fp-branch}-sep26/`. The opt-in
candidate passes the six-case
FDIV/FSQRT × JMP/taken-Jcc/not-taken-Jcc QEMU differential/overlap gate,
the 12-case integer/FP overlap gate, shared x87 stream/trap and delayed-#MF
gates, default `make verify`, and five-profile `make lint`.
The system-mode branch→INT3 variant now also passes the pinned-QEMU complete
state comparison: 64 trap entries, 63 edge-aligned branches retiring while
masked FP owners are busy, with the trap still draining all owners. The
source-matched flag-off control has zero busy-FP branch retirements and fails
the overlap witness as intended; the original plain and FXCH-queue stream
variants still pass. This closes that directed trap-order corner, not all
interrupt/debug/SMC cases.
An additional private A/B replay from the same 1.100B snapshot compared the
first 50,000 full-PC retirements by ordinal, PC, EFLAGS, all reported GPRs and
segment selectors (ignoring only cycle stamps): all records matched exactly.
The 50,000th retirement occurred at clock 1,100,098,997 in the reference and
1,100,096,681 in the candidate (2,316 clocks sooner). These VTM records do
not include full x87/memory state and are supporting evidence, not a substitute
for the directed x87 differential or cold-boot guest acceptance.

A separate Win95 continuation check used the verified cold-boot-derived 300M
bundle with the same original executable and serializer. Baseline and candidate
both reached clock 301M with 46,112,625 retirements; their final native
snapshots and private disk bytes are SHA256-identical, and their first 50,000
VTM architectural records match exactly (including cycle stamps). The source
Win95 bundle still verifies. This proves no difference in that interval, but
does not demonstrate that the new branch path was exercised there, nor count
as a new Win95 cold boot. Artifacts are under
`tmp/build-tmp/ventium-win95-fp-branch-{control,candidate}-sep26/`.

Evidence: `tmp/build-tmp/ventium-state-delta.7sh8i_6b/` is a same-model,
cold-boot-derived checkpoint replay. The 1,000-cycle host-only relink pilot
matches the frozen executable's native snapshot and private disk byte-for-byte.
Recorder OFF and ON also finish with byte-identical native snapshots and disks;
the input bundle was hash-checked before and after. The frozen RTL archive
SHA256 is `b543bb6439b50c3061a146f09848daba517b9962f33993c4cf4f83eecd5c178b`
before and after relink. The trace contains every settled retained field on
every cycle (12,978 fields, 681,916 reconstructed state bytes), but not external
DDR, PS/ATA or disk state. The analyzed outputs are under
`tmp/build-tmp/ventium-vga-wave9-analysis-sep26/wave9.*`. The analyzer's phase
test and all 53 current-schema synthetic attribution cases pass. This is an
observer check, not a differential architectural oracle.

The analyzer assigns each of 558,119 edges without retirement to exactly one
priority bucket. They sum to 100%; overlapping raw signal levels do not:

| Bucket | Edges | Share of no-retire edges |
| --- | ---: | ---: |
| Outside the fast pipeline | 176,972 | 31.71% |
| Pending-FP hold | 138,037 | 24.73% |
| Memory wait, including admission | 136,780 | 24.51% |
| Ready but control-limited | 54,343 | 9.74% |
| Frontend unavailable | 51,239 | 9.18% |
| Deferred fault | 748 | 0.13% |

The broader reference 1.100–1.150B profiler gives a useful scale check:
S_PIPE occupies 33,401,346 of 50M clocks (66.80%), S_FLOAD 3,769,757,
S_LOAD 3,395,530, S_DECODE 2,311,264, S_FEXEC 1,503,903 and
S_FP_SHARED_WAIT 1,209,497. Per-state outstanding-memory observations total
14,088,563 clocks (28.18%); inside S_PIPE the first-firing profiler buckets
are memory-packet wait 7,861,566, FP descriptor/slow handoff 4,050,808 and
uop-map miss 3,694,684 clocks. State residency, memory-wait levels and bail
buckets are **different views of overlapping clocks**, not additive savings.
For the reference's 22,207,089 retirements in 50M clocks, fixed-work IPC >1
would require eliminating more than 27.79M clocks, so no single cache or branch
shortcut can be assumed to close the target. This is arithmetic on one window,
not a claimed upper bound under a changed schedule.

The reference L1D's cumulative counters at exactly 1.100B and 1.150B split
that memory pressure further: 6,935,406 registered hit captures,
341,691 increments of the **legacy** miss-start counter, 5,299,167 idle
read-wait clocks and 8,042,322
fill-wait clocks. The fills occupy 9,052,484 L1 clocks, including
6,484,681 backing-wait clocks. Thus both the registered-hit ownership and
backing line-fill latency matter in the representative window. These are
overlapping service observations; they are not removable-cycle estimates and
must not be added to the no-retire buckets. The legacy miss counter also
includes failed *unissued* read-chain next-address lookups, so 341,691 must
not be reported as actual backing fills; the 50M trace lacks the per-edge
split. The cache remains the specified
full 8 KiB, two-way, 32-byte-line P5 configuration.

The raw L1 read-wait level is high for 215,107 clocks, of which 118,631 are
busy backing service and 92,349 are idle registered-hit capture. Those levels
overlap useful retirements and other causes; they must **not** be added to the
disjoint table or interpreted as saved cycles. Of the 215,107 clocks, 207,072
name data and 8,035 instruction requests. Current optional L1 flags have only
small exposed bounds in this short window: fill-forward 1,394 eligible clocks,
independent hit-under-fill 5,058, and preserving the read window across stores
7,032. These are eligibility observations, not end-to-end IPC predictions.

The FP hold is entirely concentrated in S_PIPE (138,037 no-retire edges). Raw
descriptor observations while held include 66,608 branch-level observations,
42,532 frontend-unavailable observations and 28,753 register-FP descriptor
observations. They are not a proven branch-overlap savings estimate: after a
branch, another FP dependency or frontend repair may become the next blocker.
The reference source blocks branch and slow/dependent issue until the older
shared-FP result is complete. The opt-in branch experiment safely establishes
the checked direct branch cases but still needs cold-boot/full-system event,
debug and SMC acceptance before it can become a production profile.

The outside-pipeline bucket includes slow decode, load, FP operand, execution
and shared-response states. In the raw state residency, S_FLOAD is 83,498 clocks,
S_FEXEC 32,350, S_FP_SHARED_WAIT 20,807, S_LOAD 24,082 and S_DECODE 33,026.
These are not all stalls: edge retirement can coincide with some of them.
`0x10f4a` (FILD dword memory source in this workload) occupies 20,366 S_FLOAD
clocks across the sampled visits; its latency must be split into cache/translation
and x87 admission before changing the converter. The previous text trace already
showed variable memory-service delays here.

The current million-cycle window has no rows in the joined VGA-service report;
an earlier build/window had a VGA write hotspot, so do not generalize this
absence to the 50M gameplay interval. The next performance candidate should
first prove a specific removable edge class with a current-build A/B replay.
Priorities are (1) eliminate provably redundant slow-path transitions, (2)
extend independent integer/FP overlap with precise event and x87-state gates,
and (3) pipeline registered cache-hit ownership without combinational BRAM
acknowledgements or speculative MMIO. Keep full-system Quake/Win95 and QEMU
differential acceptance separate from any native-checkpoint throughput result.

## Pairing and cache-pipeline scope check

In this same-build 1M trace, the existing attribution reports 30,226 settled
U-register/V-memory commit opportunities after the other pairing checks. Only
14,471 are V MOV loads (10,977 dword). Another 16,297 completed U-memory/V-memory
read-pair observations exist, but only 3,678 show a complete same-line registered
read window at U completion. These are *candidate descriptor observations*, not
permission-qualified requests, recoverable clocks, or a projected IPC gain.
`issue_uv` correctly rejects every V memory form today: the sole checked request
and its response belong to U. Removing that guard without a slot-owned V request
would commit stale data. The resident-read `VEN_L1D_HIT_STREAM` leaf is not wired
through `ventium_l1_axi` or the core and cannot alone solve precise V faults,
response cancellation or architectural retirement order. A useful integration
needs explicit request/response owners across translation, L1 and the U/V commit
packet, while retaining registered cache data and exact MMIO side effects.

The large raw U-to-V register-RAW rejection count is likewise **not** an
optimization budget: ordinary flow dependencies must not pair under the P5
rules in `docs/ap500-pairing-table.md`. This gameplay profile already opts into
the separately checked `VEN_LOAD_USE_FORWARD` load-to-V exception; that
throughput extension is not evidence that arbitrary P5 RAW pairs are legal.
A same-cycle U-ALU-to-V bypass would further diverge from the P5 cycle model
even if its functional result were correct. The short-list remains checked
memory pipelining and independent integer/FP work, not broadly relaxing
dependency or pairing guards to manufacture IPC.

## Latest candidate-only gameplay phase: 1.150–1.151B

The opt-in FP-branch build's *own* 1.150B endpoint (after its 50M A/B replay)
was repackaged with that same build's executable, ROM and private disk, and
passed `checkpoint_bundle.py`. A host-only full-state observer relink left the
compiled RTL archive and every generated model source unchanged; frozen-binary
versus relinked 1,000-cycle replay and recorder OFF versus ON 1M-cycle replay
ended with byte-identical snapshots and disks. The candidate-only trace is
`tmp/build-tmp/ventium-state-delta.y3h3nao3/on/state.delta.gz`; its complete
reconstruction and phase/attribution tests pass in
`tmp/build-tmp/ventium-fp-branch-1150m-analysis-sep26/`. It records **680,510
retirements / 1,000,000 clocks = 0.680510 IPC**. This different, favorable
1M gameplay phase is not an A/B speedup and does **not** supersede the
representative 1.100–1.150B result of **0.44963946 IPC**.

The same-edge exclusive no-retirement partition sums to 467,609 edges:

| Cause | Edges | Share |
| --- | ---: | ---: |
| Memory wait, including admission | 217,967 | 46.61% |
| Outside fast pipeline | 120,155 | 25.70% |
| Frontend unavailable | 54,065 | 11.56% |
| Pending-FP hold | 44,583 | 9.53% |
| Ready but control-limited | 30,628 | 6.55% |
| Deferred fault | 211 | 0.05% |

Raw L1 read-wait levels total 260,994 clocks: 146,891 busy backing service,
108,650 idle registered-hit capture and 5,453 idle miss detection; 251,456
are data-side and 9,538 instruction-side. These levels overlap the exclusive
causes above, so they are **not** additional saved clocks. On the 146,891 busy
read-wait levels, the joined transport state finds 126,698
with the AXI master in read-data, 109,757 with the AXI-to-Avalon bridge in
read-data, and 76,141 with the **ao486 platform's** L2 cache in stream-fill;
these three subsets overlap, and 71,553 levels satisfy all three predicates.
The model's L2 stream-fill is not the FPGA's direct PS-AXI route, so this does
not isolate hardware AXI latency or imply that bypassing the bridge would save
71,553 core clocks. Registered-hit capture (108,650 levels) has no backing
transaction at all. The existing optional
fill-forward, hit-under-fill and store-window policies expose only 1,612,
9,138 and 8,416 eligible clocks respectively in this phase; each is an
opportunity level, not a predicted gain. V-memory attribution still sees
30,205 U-register/V-memory commit levels, only 11,889 V MOV loads, while
only 2,272 read/read observations have a complete matching same-line window.
An exact lookup-address histogram reconciles the legacy L1 counter's 5,912
increments into **5,453 actual demand misses** (335 instruction, 5,118 data)
and **459 rejected, unissued read-chain next lookups**. The earlier apparent
236-miss hot physical line `0x15f560` was almost entirely a *next-query*
artifact misattributed to the old request address; it was not evidence of
236 backing refills. The histogram is at
`tmp/build-tmp/ventium-fp-branch-1150m-misses5-sep26/`; its sum is checked
against the recorded L1 counter and synthetic old-address/next-address cases.
`VEN_L1D_PERF` now excludes such lookahead rejects from future `miss-start`
reports, with a failing-before/passing-after chain-leaf witness. This only
repairs a simulation counter; the cache's request, data and ACK paths did not
change. The old 50M build's published counter value above remains labeled
legacy rather than retroactively reinterpreted. The corrected counter has no
new gameplay IPC measurement; the 0.44963946 IPC representative result still
predates it. Validation: `make verify` passed its 105 functional programs and
cycle bands, `make l1` passed all 46 memory-subsystem gates, `make lint` passed
all five configurations, and the state-focus analyzer passed synthetic legacy
and corrected-counter fixtures plus lossless reconstruction of the 1M-cycle
recording. This is measurement hygiene, not an IPC improvement claim.

This phase makes the next investigation concrete: measured memory-service
ownership, especially registered data-hit turnover and backing latency, is
larger than remaining FP holds. Do not extrapolate the phase's 0.680510 IPC
to the 50M window or optimize the ao486/Avalon simulation bridge alone as if
it were the FPGA's direct AXI path. Any L1/core pipeline change must keep its
checked physical request identity, page/segment faults, snoop/SMC cancellation
and exact MMIO behavior, then pass a same-work gameplay A/B and hardware
timing/area qualification.

## September 27: same-edge PC and uop-map localization

The extended analyzer reconstructs the same candidate-only 1.150–1.151B
recording exactly and emits `wave7.pc_edge_causes.tsv` under
`tmp/build-tmp/ventium-fp-branch-1150m-pccauses2-sep27/`. Every row uses the
**pre-edge EIP** and a mutually exclusive no-retirement cause; each row and
column sum is checked against the global partition by synthetic legacy- and
corrected-counter fixtures. EIP need not be the owning `q_pc` in a slow FSM
state, so an `outside_pipe` EIP hotspot is not by itself a decoded slow-op
hotspot or a recoverable-cycle estimate.

The full-state `pp_bail[3]` delta is **67,013** uop-map fallback observations:
66,422 unavailable instruction boundaries and only 591 invalid predecode
lines. The unavailable-boundary offset histogram has 15,554 observations at
byte offset 31 and 8,954 at offset 5. These are repeated first-priority
pipeline observations, not 67,013 independent cache misses or guaranteed
saved clocks. In particular, the existing `VEN_UOP_CROSSLINE` and
`VEN_UOP_CROSS_INDEX` features were enabled in this measured build; simply
enabling them again cannot address the residual holes. The source-bundle
checksum gate passes. Read-only page-table translation of its saved CR3
`0x3d000` and CS base `0x10000000` shows hot pre-edge PCs `0x110ff` and
`0x112ff` at byte offset 31; they decode as `FXCH ST(1)` and
`MOV AL,[ESI]`, respectively. Their repeated fallback needs a boundary-owner
diagnosis before changing the uop cache or live decoder. Even eliminating
every observed uop fallback would be less than 7% of this 1M-cycle window,
so it is a contributing target, not a route to >1 IPC by itself.

A pre-edge `wave7.uop_holes.tsv` event dump under
`tmp/build-tmp/ventium-fp-branch-1150m-uoprepair2-sep27/` narrows the
offset-31 case without guessing from aggregate counters. For EIP `0x110ff`
(`FXCH ST(1)`), all 7,690 first-priority fallback observations have a valid
predecode line, both returned code sources available, no boundary entry and
no published cross-line match. Exactly 1,538 show a repair-start pulse;
6,385 see the repair walker in `W_SEEK`, commonly at another anchor. The
same-edge `wave7.uop_repair_transitions.tsv` resolves acceptance and
preemption: only 260 of those 1,538 pulses find `repair_ready`, and **all 260**
accepted offset-31 seeks are yielded at walker offset 8 to an earlier-anchor
repair (source set 7/anchor 31 to set 8/anchor 5). None had a pending fill,
poison or invalidation at that transition. In this observed phase the hot
cross-line descriptor never reaches publication: the existing policy can
starve optional late-anchor repairs under recurring earlier-anchor traffic.
Across all source sets in the same phase, there are 2,133 clean late-seek
(`anchor > 25`) preemptions to earlier anchors, all with the suffix source
available and no pending real fill; this is not confined to one Quake address.
This is a repair-scheduling opportunity, not missing instruction bytes or an
I-cache refill. A general fairness change must still preserve source
identities, invalidation, mode-change cancellation and real-fill priority;
a PC-specific cache entry is not a general processor fix.

An experimental, default-off `VEN_UOP_REPAIR_FAIR` policy now allows one
late-anchor seek to yield to an earlier map repair, then protects the next
late-anchor seek until publication or cancellation. It adds one scheduling bit
and does not bypass source checks, mode/invalidation fences or real-fill
priority. The cross-line leaf gate passes with 1, 2 and 33 descriptor entries;
the 33-entry run additionally passes decode-tail invariance. The fair leaf
also checks that a foreground fill can preempt a protected seek and that the
fairness credit survives to its next attempt. The feature-off 33-entry
control, full-top opt-in structural lint and the default `make verify` gate
(105 functional programs plus cycle bands) pass. The cold-run measurement below
is **not** a same-state causal A/B; a matched-work comparison and full-system
boot checks are required before enabling this policy by default.

## September 27: fairness candidate cold-run gameplay

The one-define `VEN_UOP_REPAIR_FAIR` full-PC build has SHA256
`9609e4429d6f9ded038db64e167bd2c358b845a9af863ce548df05a3f3519990`.
Its generated manifest differs from the earlier FP-branch profile by only
that define. It cold-booted the same immutable Quake disk and ROM with the
same 45 MHz core/RTC, 90 MHz VGA and FPGA_DDR=2 settings, and saved a
five-file verified bundle at exactly 1.150B cycles:
`tmp/build-tmp/ventium-fair-cold1150m-sep27/`. The 100M-cycle retire count
was exactly 32,212,074, matching the prior flag-off/FP-branch cold checks;
the guest then launched Quake v1.06. Lossless frame inspection shows a moving
3D scene: 1.00B→1.05B changes 42,433 of 64,000 pixels, and
1.05B→1.10B changes 42,228.

| Cold-run gameplay clock window | Retirements | IPC |
| --- | ---: | ---: |
| 1.00–1.05B | 22,778,737 | 0.45557474 |
| 1.05–1.10B | 22,769,257 | 0.45538514 |
| 1.10–1.15B | 22,661,159 | **0.45322318** |

The last row is the latest verified gameplay IPC. The older FP-branch build
measured 0.44963946 IPC over the same clock numbers, but it replayed from
its own 1.10B checkpoint, whereas this candidate ran cold from reset.
Even clock-aligned windows can execute different scene/instruction mixes;
the approximate 0.8% difference is **not a proven fairness speedup**. The
older 1.150–1.151B 0.680510 IPC favorable phase likewise cannot be compared
with this candidate's different 1.150–1.151B scene, which retired 275,738
instructions (0.275738 IPC). Two independent same-build restores from the
new 1.15B bundle, one with periodic perf/frame observation and one without,
ended after 1M cycles with byte-identical native snapshots
(`01faa7f89f935d53a5eded265f0287c2a9daa17f7f23532062891f3baf9b0164`)
and private disks (`48f07a4bb1102dbc4389ecaf8602035af888842168beef73af74b08d3090a88a`).
The source bundle still verifies. This proves deterministic same-build replay,
not cross-build state equivalence, a completed timedemo, Win95 boot, or IPC >1.

## September 27: current-build full-state string-service attribution

The current fairness build's deterministic 1.150–1.151B replay produced a
lossless 1,000,000-cycle full-state trace at
`tmp/build-tmp/ventium-fair-1150m-delta-sep27/state.delta.gz`. Its endpoint
snapshot and disk are byte-identical to two frozen-binary replays without the
recorder. The verified **gameplay** result remains **0.45322318 IPC** over the
larger 1.100–1.150B window; this differently composed 1M window is only
**0.275738 IPC** and must not be used as a matched A/B comparison.

The same-edge, mutually exclusive no-retirement partition of this 1M phase
has 419,252 outside-pipeline, 118,553 memory-admission/wait, 93,065 frontend,
61,543 ready-control and 49,499 asynchronous-FP-hold edges. These sum to
741,912 no-retirement edges. The L1 counted 8,647 actual demand misses
(7,729 data and 918 code), with 589 rejected next-lookups excluded; 99,871
waiting reads reached an idle registered-hit capture edge. None of these
overlapping service levels is a guaranteed saving.

The guest bytes at EIP `0x10574` are `F3 A5` (REP MOVSD). New
`wave7.string_service.tsv` groups the **pre-edge** string controls by decoded
PC/subtype and checks their load/store clocks and ACKs against the independent
slow-memory table. The complete reconstruction and synthetic phase tests pass
at `tmp/build-tmp/ventium-fair-1150m-string3-sep27/` (`STATE-FOCUS-PASS`).

| REP MOVSD PC | Elements (load/store ACKs) | Source-load clocks | Destination-store clocks | Fused source ACKs | Streamed store ACKs |
| --- | ---: | ---: | ---: | ---: | ---: |
| `0x10574` | 16,000 | 70,026 | 31,028 | 16,000 | 15,800 |
| `0x55efd` | 16,668 | 35,987 | 17,636 | 16,668 | 15,600 |

The `0x10574` decoded string instruction occupies 101,472 clocks overall.
Its 70,026 source-load clocks contain 38,012 waiting for a busy L1, 13,999
idle resident-hit capture clocks, 2,001 idle miss-detection clocks, and
16,000 ACK clocks (14 other clocks). There are 2,006 actual data-line miss
events recorded at this EIP, close to the roughly 2,000 lines in 16,000
sequential dword reads; the event count and miss-detection levels have
different predicates and need not be identical. The destination-store state
has 15,012 request-without-ACK clocks and 16,000 ACK clocks. The 200
non-streamed terminal ACKs correspond to next-element ineligibility; no
unsupported claim about their individual causes is needed here. By contrast,
`0x55efd` has only 148 source miss-detection clocks and 2,580 busy-wait
clocks, so conflating these two REP sites would hide the cold-stream cost.

**Decision:** do not add another REP MOVSD loop shortcut. Source-load fusion
is used on every sampled element and next-source streaming on nearly all
eligible elements. The remaining `0x10574` cost is predominantly registered
cache-hit capture, fill occupancy and store admission. The existing optional
`VEN_L1D_FILL_FORWARD` / `VEN_L1D_HIT_UNDER_FILL` and
`VEN_L1D_WINDOW_KEEP_STORE` policies need precise same-work full-PC A/B before
promotion, but their current-phase eligibility counts (5,076 / 20,848 /
26,541 clocks across **all** PCs) are not additive or remotely sufficient
alone to reach >1 IPC. The general fix path is independently owned, registered
core-to-L1 requests/responses with exact physical identity, ordered stores,
fault/SMC/snoop cancellation, and byte-exact MMIO; then quantify matched-work
gameplay and hardware timing/area. Do not substitute a timing-unsafe
combinational L1 ACK or a Quake-address-specific special case.

## September 27: fairness build continued through 1.400B

The frozen fairness executable (`9609e4429d6f9ded038db64e167bd2c358b845a9af863ce548df05a3f3519990`)
restored its verified 1.150B native bundle, using a private disk, and ran
without error to a save/stop at exactly 1.400B clocks. The new five-file
bundle passes `CHECKPOINT-BUNDLE-OK` at
`tmp/build-tmp/ventium-fair-1400m-bundle-sep27/`; snapshot SHA256 is
`5f49c7aa8d3f902a9257d422b25ee0f3bcfb7f2c5a19906067e329d4510e0788`.
The simulator stayed near 141 MB RSS. No Vivado run or RTL change was involved.

Compare equal-phase profiler endpoints after restore, starting at clock
1,150,000,001: the snapshot already held two registered retirements, so
subtracting its save-time retirement count from the later profiler endpoint
would incorrectly add those two to the first interval.

| Clock interval | Retirements | IPC |
| --- | ---: | ---: |
| 1,150,000,001–1,200,000,001 | 21,278,958 / 50,000,000 | 0.42557916 |
| 1,200,000,001–1,250,000,001 | 20,600,752 / 50,000,000 | 0.41201504 |
| 1,250,000,001–1,300,000,001 | 21,772,634 / 50,000,000 | 0.43545268 |
| 1,300,000,001–1,350,000,001 | 20,639,353 / 50,000,000 | 0.41278706 |
| 1,350,000,001–1,400,000,000 | 20,517,424 / 49,999,999 | **0.41034849** |

Across the whole 249,999,999-clock suffix, 104,809,121 instructions retired:
**0.41923649 IPC**. Four successive 320×200 capture pairs differ by 115,850,
112,302, 97,799 and 115,299 color bytes, respectively. The stopped private
disk's `QUAKE/ID1/QCONSOLE.LOG` progressed from “You got the shells” to
“You got the Grenade Launcher”; it has **no timedemo result line**. Thus the
replay verifies continuing gameplay and checkpoint safety, not a completed
timedemo or FPS. The final save occurs before the 1.400B periodic frame
capture, so the final near-50M window has no new endpoint image.

Two independent same-build restores from the 1.400B bundle to 1.401B ended
with byte-identical native snapshots
(`eff0d5f91b8396746e01d483667c3c2f97f4336659490a4f05ed66a1cdafd1ab`)
and disks
(`9e65fccb940025994a50167a6864407972d0c5e53ce44ca01c5c88a4fe8b7ad0`),
each at 542,129,368 cumulative retirements. Their 1M-clock diagnostic suffix
retired 629,115 instructions (**0.629115 IPC**), a different short gameplay
phase; it does not replace the longer-window figure or establish an RTL gain.

The completed 1.200–1.250B profiler interval puts the general bottleneck in
view: S_PIPE memory-wait first-bail 8,049,780 clocks, x87 issue/occupancy
5,859,380, and uop-map fallback 4,073,702. Outside S_PIPE, FLOAD alone
occupies 4,725,826 clocks and integer LOAD 2,562,452. These first-bail and
FSM-state categories are not additive savings. Slow-decode residency is
2,311,967 clocks, with D8/D9/DB/DF x87 opcodes collectively about 38%.
Even an idealized single-cache-flag fix cannot close the >1 IPC gap: the next
candidate must address memory response ownership, FP admission/operand overlap,
and frontend fallback together while preserving the differential gate.

## September 27: measured instruction/data contention in the shared L1 array

The same fairness-build 1.150–1.151B full-state trace has **0.275738 IPC** in
that particular 1M-cycle phase. It predates, and must not replace, the
1.350–1.400B **0.41034849 IPC** verified gameplay window or the 250M-cycle
**0.41923649 IPC** suffix above. A lossless replay of the array's tag, valid,
fill-owner and request-source fields (`STATE-FOCUS-PASS` in
`tmp/build-tmp/ventium-fair-1150m-provenance2-sep27/`) identifies 918
instruction-origin fills and 7,729 data-origin misses. Although the core has
an I-cache, its refill traffic also allocates in the shared `ven_l1d` array.

Of the 918 instruction fills, 649 evicted a valid line whose data-fill origin
was observed **within this trace**; 51 evicted valid lines of unknown pre-trace
origin. Only 315 subsequent data misses (4.08% of 7,729) targeted a line
previously witnessed being evicted by an instruction fill, with intervening
global flushes and writes to that line excluded. A later snoop or changed
request schedule could still alter that attribution; these are observed trace
relationships, **not** a counterfactual saved-cycle or IPC estimate. The other
data misses dominate numerically in this phase. Splitting I/D allocation may
be a valid architectural improvement, but this evidence does not support
making it the first high-risk performance rewrite or claiming it can close the
>1 IPC target. The analyzer adds only offline provenance counters; no RTL or
FPGA image changed.

The later 1.400–1.401B **same-build** phase was independently recaptured from
the verified 1.400B bundle with the host-only state observer. Its 1,000-cycle
pilot matches the frozen executable, and recorder OFF/ON at 1M clocks end with
byte-identical native snapshots and private disks. All fields reconstruct
exactly and the phase/attribution tests pass at
`tmp/build-tmp/ventium-fair-1400m-analysis-sep27/`. This trace confirms the
previously reported **0.629115 IPC** for this short phase; the longer
1.350–1.400B window remains **0.41034849 IPC**. It has 553 code-origin fills,
4,517 data misses, 411 observed code fills evicting a witnessed data-origin
line, and only 105 data misses (2.32%) after such an eviction with an
intervening flush/write excluded. The result is phase-dependent but again
does not identify code/data contention as the main lost-IPC source.

For this later trace the same-edge *exclusive* no-retirement accounting is
182,624 memory-admission/wait edges, 151,493 outside-pipeline edges, 68,381
frontend-unavailable edges, 48,627 pending-FP-hold edges, 49,121 ready but
control-limited edges, and 1,846 deferred-fault edges (502,092 total).
These are priority buckets, not independent potential savings. The first two
alone are 66.55% of no-retirement edges; a code-fill-only policy cannot
plausibly solve both. A next RTL candidate should target checked memory
response latency or slow x87 operand/admission transitions and then measure
the exact same work, retaining full Quake/Win95 and differential gates.

The added pre-edge `wave7.fp_load_service.tsv` splits every S_FLOAD clock by
its captured x87 command and request-service phase, and checks that each row
and all rows together conserve the FSM's 49,794 S_FLOAD clocks in this later
trace. At `0x10f4a` (FILD m32), 339 operand ACKs require 10,890 S_FLOAD
clocks: 338 new L1 line misses and 10,195 clocks while the array is busy
filling. The miss event addresses move largely down through distinct physical
lines, rather than repeatedly thrashing one line. The nearby `0x10f4d`
(another FILD m32) has 339 operand ACKs, **zero** new misses, but still 4,017
busy-fill clocks and 338 registered-hit capture clocks. Its waits can overlap
the earlier fill tail; these two PC totals are not independent DDR latency
savings. This is direct evidence that line-fill occupancy and serialized x87
operand acquisition matter more at this hotspot than code-fill eviction or a
missing FILD converter. It does not justify a Quake-address prefetch rule: a
general solution must preserve exact translation, cacheability, coherence,
fault and MMIO behavior and be checked with a matched-work A/B run.
