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
The candidate has **not** been cold-booted through Quake/Win95 or completed a
timedemo acceptance run.

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
341,691 miss starts, 5,299,167 idle read-wait clocks and 8,042,322
fill-wait clocks. The fills occupy 9,052,484 L1 clocks, including
6,484,681 backing-wait clocks. Thus both the registered-hit ownership and
backing line-fill latency matter in the representative window. These are
overlapping service observations; they are not removable-cycle estimates and
must not be added to the no-retire buckets. The cache remains the specified
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
rules in `docs/ap500-pairing-table.md`. A same-cycle U-ALU-to-V bypass would
violate that cycle model even if its functional result were correct. The
short-list remains checked memory pipelining and independent integer/FP work,
not relaxing architectural dependency or pairing guards to manufacture IPC.
