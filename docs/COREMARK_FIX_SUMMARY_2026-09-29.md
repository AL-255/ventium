# CoreMark fixes and gain attribution — 2026-09-29

## September 29 result and limits

The corrected FIXED32 candidate completes both standard seed datasets with
matching CRCs. At ten iterations, the measured clock-query window gives
**2.100583 CM/MHz (performance)** and **2.103951 CM/MHz (validation)**.
Whole-program CoreMark IPC is **0.758462 / 0.758529**, respectively.
These are **short-run diagnostics, not valid-duration CoreMark scores**:
the invocation does not satisfy CoreMark's ten-second requirement.
At the September 29 stop, valid-duration 2.1 CM/MHz acceptance had not been
established. The September 30 continuation below supersedes that status:
both complete 1,500-iteration seeds now pass correctness and exceed 2.1 CM/MHz.

The unchanged performance workload retires 3,660,809 instructions. Relative
to the historical raw control, clocks fall from 9,224,125 to 4,826,619:
**47.674% fewer clocks / 91.109% higher modeled throughput**. That control
is not a fully period-qualified P54 implementation. A more useful later
comparison is the real-occupancy raw candidate versus FIXED32: timed clocks
fall from 5,454,222 to 4,760,583, **12.717% fewer / 14.570% higher throughput**.
Do not compare these short direct-memory measurements to an official P54C
score, real FPGA gameplay, or the older valid-duration baseline as though
they were identical benchmark configurations.

Gameplay IPC remains **0.45746656** on frozen build
`3237b6523e8ec4c2db59ae0ef59012de45729b4852dcbdf8b3c20b7bc568d66d`,
cycles **1,150,151,638–1,400,151,638**. It predates these fixes; FIXED32 has
no gameplay measurement.

## Techniques and measured contributions

Each row is a successive, matched ten-iteration performance checkpoint.
“Step throughput gain” is `old clocks / new clocks - 1`.
“Contribution” is that row's saved clocks divided by the total 4,397,506
saved clocks. Contributions sum to 100%; throughput gains do not add.

| Fixing technique | Clocks after change | Clocks saved in step | Step throughput gain | Contribution to total saved clocks |
| --- | ---: | ---: | ---: | ---: |
| Raw-byte frontend bundle: resident tagged bytes, shared reference-decoder capture/direct handoff, short integer/byte operations, real pre-writeback execution occupancy | 5,527,385 | 3,696,740 | 66.880% | 84.064% |
| Transfer-width-correct memory penalties, encoding-extent short dispatch, CL occupancy corrections | 5,151,285 | 376,100 | 7.301% | 8.553% |
| Exact slow-dispatch base/index dependency mask instead of broad register dependence | 5,126,964 | 24,321 | 0.474% | 0.553% |
| Overlap an already-paid prefix D1 clock with the preceding AGI | 5,087,263 | 39,701 | 0.780% | 0.903% |
| Prior-clock AGI history from actual gated GPR write enables, including the documented implicit PUSH/POP ESP exception | 4,936,433 | 150,830 | 3.055% | 3.430% |
| Combined paid `66` register admission/pairing, final-ACK plain MOV retirement, and existing I-BRAM control-target port steering | 4,826,619 | 109,814 | 2.275% | 2.497% |
| **Total** | **4,826,619** | **4,397,506** | **91.109% vs historical control** | **100.000%** |

The first, second and final rows are **bundles, not isolated feature
ablations**. In particular, no independent percentage is established for
`66` admission versus MOV ACK retirement versus target steering.
Likewise, writer-history repair and implicit-ESP filtering are not separately
measured. Assigning individual gains to those subfeatures would invent evidence.

The transfer-width correction is independently reconciled: 117,932 slow
reads and 7,346 slow stores incorrectly paid three clocks, yielding exactly
**375,834 saved clocks** of the second row's 376,100. The remaining 266 clocks
are the net effect of its other changes, not an isolated SHORT or CL gain.
The direct-memory trace retains 1,196 clocks of real modeled memory debt
(133 misses × eight plus 44 transfer crossings × three). This does not
measure the SoC L1/AXI service or establish its bottleneck.

## Correctness and hardware discipline

- Use one real decoder/capture and one GPR writeback/retirement authority;
  avoid duplicated instruction semantics. Integer occupancy precedes
  writeback rather than retiring first and charging a later debt.
- Preserve paid prefix D1, true base/index AGIs, byte-parent hazards,
  explicit ESP hazards and all actual execution clocks. A 33-bit prefix
  PC token is transient ownership state, not a decoded-instruction cache.
- Correct operand-size-16 immediate `69` to consume/sign-extend two bytes,
  preserving its dword form and the following instruction.
- Separate operand width from code-IP width: `66` in CS32 must not truncate
  fallthrough EIP. Reject explicit ESP WAW and pending older owners in the
  new register-only prefix path.
- Plain MOV retires only on the final reconstructed operand ACK. CMP/TEST
  retain their additional execution clock; faults and width/high-byte merges
  remain gated through the existing paths.
- Control-target pre-reading reuses the two existing registered I-cache
  ports. It adds no SRAM ports, descriptor cache, allocation or speculative
  architectural effects. Returned tags/collisions/extent still govern use.
- All new performance switches are optional. The measured profile has no
  uop cache, out-of-order issue, same-pair load-use forwarding, experimental
  prefix/EX chaining, benchmark recognition or Quake-specific workaround.

## Verification at stop

- FIXED32 fast differential gate: **107 functional programs pass**, including
  the new word-immediate IMUL regression; **19 gated M4/M5 metric bands pass**
  and the twentieth kernel is informational, not a correctness gate.
  The former DIV-band failures are resolved without loosening tolerances.
  The canonical script separately reports 20 non-gating per-instruction cycle
  comparator divergences; this is not a claim of exact cycle-trace equivalence.
- Both short CoreMark seed runs pass all five CRC fields and reproduce the
  same complete clock/retirement/counter partitions after the corner repairs.
- Focused checks cover execution occupancy/CL forms, 32,768 memory-boundary
  cases, actual-writer history, SHORT suffix independence, prefix ownership,
  final-ACK MOV merging and target-port steering.
- Corrected prefix alignment matrix: **382/384 cases pass** full architectural
  QEMU comparisons and pairing/spacing checks. Two golden runs failed to connect
  to QEMU before RTL execution. They were not retried after the stop request;
  the matrix is **not fully green**.
- The 152-case MOV and 11-case target whole-core witnesses used the preceding
  combined binary; their source-level leaves pass, but those runs must not be
  relabelled as a complete FIXED32 matrix or an isolated performance ablation.
- Windows 95 desktop, Quake timedemo, system gates, full verification and FPGA
  synthesis/deployment were **not rerun**. Major-change standard-suite acceptance
  is incomplete; these commits are a checkpoint, not release qualification.

## Host-only acceleration and reproducibility

Skipping a same-clock settle only when every generated DUT input is unchanged
improves host throughput approximately **25–28%**, with every clock-edge eval,
guest clock, retirement and CRC retained. This is **0% guest performance gain**.
The port list is generated from the exact Verilated header; unsafe debug/device
configurations fail closed. Parallel builds and fixture stages use bounded
resource scopes; golden fanout is limited to 24 active QEMUs to leave task
headroom inside the 32-worker scope.

Two model threads, serial LTO, and frontend-O3/larger-function experiments
preserve guest results but are slower: approximately 5%, 1.9%, and 2.75–3.96%
more host wall time, respectively. They are not credited as performance fixes.
At the September 29 stop, the faster measured single-thread host still projected
a 1,500-iteration run around 40 minutes, outside the then-authorized 30-minute
cap. No long run had been used. The September 30 runs below followed explicit
60-minute-per-seed authorization; neither round used guest timer manipulation,
dataset changes or timed-loop snapshot splicing.

Measured FIXED32 binary SHA-256:
`75e3d944c98c7d498d00457b9828894cbf136d11356ee2c0e705abbbd8592736`.
It was built from the explicitly frozen worktree, which also contains older
unrelated system changes not included in this CoreMark-only checkpoint.
The pushed revision is therefore not claimed to be byte-identical to that
measured build. Full build hashes, define profile, exclusive cycle tables,
evidence paths and remaining work are in
[the detailed cycle survey](P54_COREMARK_CYCLE_SURVEY_2026-09-29.md).

## September 30: standard-suite continuation (not yet qualified)

Latest status at **15:44 UTC**: both complete CoreMark seeds pass; cold Windows
95 has not reached a verified desktop; cold DOS Quake has reached clear gameplay
but has not completed its 969-frame timedemo. **Current-candidate gameplay IPC is
0.43328503**, frozen `2e63e532…`, cycles **1.5B–1.6B**. This supersedes the
older-build-only baselines below. It is not timedemo FPS or full-suite PASS.

The user authorized 60 minutes per CoreMark seed. Both untouched 1,500-iteration
seed images **completed without error**, matched all five reference CRCs and
printed “Correct operation validated.” Their guest durations exceed ten seconds.
The CoreMark correctness portion of the standard suite passes; this does not
qualify Windows 95, Quake, the full standard suite or an official EEMBC submission.

| Completed seed | Whole-program clocks | Retired instructions | CoreMark IPC | Conservative CM/MHz | Clock-query window | Query-window CM/MHz | Guest seconds | Host minutes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Performance, 1,500 iterations | 713,805,640 | 542,165,430 | 0.75954209 | **2.101412** | 713,731,763 | 2.101630 | 10.888 | 38.77 |
| Validation, 1,500 iterations | 712,760,043 | 541,458,819 | 0.75966495 | **2.104495** | 712,693,215 | 2.104692 | 10.871 | 41.13 |

Performance CRCs are `e9f5 / e714 / 1fd7 / 8e3a / 25b5`; validation CRCs are
`18f2 / e3c1 / 0747 / 8d84 / e230` (seed/list/matrix/state/final). Both used the
unchanged 2,000-byte dataset and pinned compiler images, one CPU each (2/3),
a 3,600-second limit per seed and a 2-GiB/160-task runtime scope. The simulator
and guest returned zero, no error banner appeared, and the binary, input images,
compile records and generated headers remained unchanged. All processes were
reaped. The conservative score uses every program clock, not normalized short
runs, the guest's printed iterations/second or spliced execution windows.
The 2.1 CM/MHz target is established for both complete modeled runs; CPI below
one is **not** established (CoreMark IPC is approximately 0.760).

Fresh no-profiler binary
`3ef25add322d2b23f78a26be22c41164623c5b3e380e7de4843f5ceae5a41764`
reproduced both short seed results exactly and passed the fast gate: 107
functional comparisons, 19 gated metric bands and one informational kernel.
Its compile-record SHA-256 is
`843563e7bbb1a5fe6d0459e799f4b81f1e7847967ca96fdfb786b57a597a71f6`;
all 86 frozen compile inputs were unchanged through the build. Performance
profiling observers were omitted; no guest timing, ISA, seed or dataset was
changed. Twenty non-gating instruction-cycle comparisons remain divergent;
this is not exact cycle equivalence or system/full-suite acceptance.

`ven-standard` is the cold full-PC raw-P54 profile: no UOP cache, dependent
load forwarding, memory-chain/prime family or experimental EX chaining. It
retains full P5 caches, the existing banked memory pairing and FP overlap.
Compilation exposed a byte-pair size mux referencing disabled PRIME signals;
a conditional guard preserves the raw owner's width. Five production-extracted
profiles passed all 160 focused request/width cases. The full-PC binary is
`122d9e0f61f054af80639fd7e0edf8189663dbe6c3aa6f9bab4fc4e751c5186d`.
Existing uncommitted system fixes remain in these frozen worktree builds.

Windows 95 cold boot and FreeDOS Quake cold timedemo were launched independently
on CPUs 12/13, each under 2 GiB/32 tasks. Win95 **failed**: the full text capture
at 425,026,424 cycles shows `While initializing device VDD: Windows protection
error. You need to restart your computer.` It was stopped and reaped normally
at 437,410,973 cycles / 73,933,723 retirements, with no desktop. The old running
wrapper missed that protection-error wording; its zero exit is not a PASS.
The prospective wrapper now recognizes protection and engine errors, including
split log-read boundaries (five host tests pass). Quake subsequently **failed**
at cycle 759,711,000, before gameplay, on the AXI `quad_aw_shape` assertion.
Its simulator was reaped with return code 1; no timedemo completion qualifies.
No snapshot restore or checkpoint stop qualifies either test. Quake is the pinned
**DOS 1.06** executable with
shareware PAK0 and CWSDPMI V0.90+ r1; executable, extender, PAK, FreeDOS kernel
and COMMAND.COM match the pinned reference. The existing startup command is
`quake -nosound -nocdaudio -condebug +timedemo demo1`; no guest edits were made
at launch. The private FAT console must record a fresh complete 969-frame result,
then pass checking after the simulator is reaped and its disk closed. A generic
host-only stop file allows normal finalization; it is not an acceptance marker.
Win95 still requires a recognizable desktop and no error.

### Subsequent generic correctness fixes (not yet full-suite qualified)

The actual AXI-master leaf now reproduces both the Quake assertion and an
aligned-address variant that silently emits an extra stale word. A write-buffer
slot previously owned by a fused quadword retains its fusion sidecar when reused
as the second member of a non-fused pair. Initialize that member's `wq_fused`
and `wq_hi_data` on allocation, just like every other slot field. This adds no
queue entries, memory ports or cycles and does not disable write combining.
Red evidence: `/tmp/ventium-axi-quad-reuse.AFGSyS/` (unaligned V address) and
`/tmp/ventium-axi-quad-reuse.3hFhJ6/` (aligned V address).

Both red leaves instantiate the actual production `ven_axi_master`, not a
copied queue model: fuse stores at `0x20/0x24`, drain their B response, then
reuse the retired slot as V of the non-fused `0x30/0x44` or `0x30/0x48` pair.
The stale V packet has `AWLEN=1` and first-beat `WLAST=0`, rather than the
required single-word `AWLEN=0`, `WLAST=1`. `0x44` reproduces the production
alignment assertion; `0x48` passes that alignment predicate but fails the
exact packet scoreboard, exposing the additional-word corruption risk.
Red source SHA-256:
`7ed8d00bea8008667e54d914b2867ffb5692f20228792f88beb4dc6de348e1b5`.

After the guarded two-sidecar allocation fix, **all 32 reuse configurations
pass**: quad combining on/off × both physical queue slots × V address
`0x44/0x48` × independent AW/W backpressure on/off × piped dispatch on/off.
The slave delays B, and the scoreboard checks address, length, size, burst,
data, strobes, WLAST and exact AW/W/B totals. Four existing quad-pair modes
(ordinary, split admission, BRESP error and piped dispatch) and eight existing
write-buffer capacity/order/pair/alias/error/final-B/two-B/piped-dispatch modes
also pass. The serialized, resource-bounded matrix was reaped with exit zero;
its aggregate log is `/tmp/ventium-axi-quad-matrix.m7on5W/matrix.log` and all
32 reuse cases retain their individual source-hashed receipts. Fixed AXI-master
SHA-256:
`3c1574fec0d7c24e66fad9467526ca77fd5da61f2fb99bee114831929ff36313`.
Regression sources are `verif/l1/tb_axi_quad_reuse.sv` and
`verif/l1/run-axi-quad-reuse-gate.sh`. These leaves do not establish Quake
completion, Win95 desktop, a new gameplay IPC or full-standard-suite PASS.

Separately, three IRET defects have independent QEMU witnesses: dword frame
addresses did not wrap through SP when SS.B=0; word IRET over-read four bytes
and could fault on an unused next page; restoring the full V86 ESP was incorrectly
merged with the old monitor stack's high half. Address every slot through the
existing stack-address helper, use the true word/dword read width throughout,
and exempt only the validated final V86 ESP restore from the implicit-SP merge.
No new FSM cycles or guest-specific special cases are introduced. All five
`pv86iretstack` cases are exact QEMU matches (727/734/707/647/727 records), with
actual debug exit 133. Candidate TB SHA-256:
`12851ddf6d2110b6d68acd2c317eaf3fa96e3c83c528f51cda5c3f64f1366a80`;
evidence `/tmp/ventium-pv86iretstack.Fph7M6/`. The fast differential gate also
passes on this TB. Its default plugin was checked byte-identical to the pinned
fresh plugin (`9adf7ca3…`). These fixes have **not** proven the live Win95 VDD
cause or completed either full-system standard. The earlier CoreMark results
above predate them; independent final-candidate results are recorded below.

A passive host fault ring is available for the next cold Win95 run: 256 recent
retirements, 64 significant pre-edge bus/frame events, maximum 16 fault dumps
and 4 MiB. It records actual acknowledged operands, precommit source selectors
and ESP write inputs; it does not read guest RAM, write guest state or add model
evaluations. All 13 host tests pass; the new full-PC build accepts and enables
it on the cold Win95 run. Historical traces with postcommit CS or DDR-only stack reads are
not substituted for this witness.

The corrected full-PC binary is
`b7cfbec7ee31c7ff7f81abf994995431f3c660b913ae2a9d3176c6d22a2db0ae`,
with compile-record SHA-256
`d4abefdaa05f390d073c4cf52ee6602083dc1d6bba8c622a0321dc5e63e1ae2b`.
The resource-guarded 32-job build completed in 37.085 seconds. The refreshed
fast gate passes all 107 functional programs and 19 metric bands, retaining
the 20 non-gating cycle-trace divergences. All five structural lint profiles
pass. The exact 106-macro raw-standard core profile also passes strict structural
lint with the complete `rtl_ven_core.f` filelist; receipt:
`/tmp/ventium-raw-standard-strict-lint-complete-sep30.log`.
Ten additional existing system-mode QEMU controls, including protected
outer IRET/RETF, SS.B=0 stacks, and interrupt word frames, pass; exact counts
and fault qualifications are in `WIN95_ABLATION_2026-09-28.md`.

The corrected candidate's **cold Win95 run failed again**, showing the same
VDD protection error at `VGATEXT @425026424`. The updated wrapper recognized
the terminal error and terminated/reaped its simulator (actual exit -15;
`status=terminal_error`), rather than misclassifying a clean cap as success.
The service is inactive/dead with MainPID 0. Its passive vector-6 ring is
`win95/faults.log`; all sixteen captured traps target the expected ROM callback.
The separate cold Quake service remains active on CPU 13, capped at 2 GiB
and 32 tasks. Both used untouched original source images, not the previous
runs' writable guests. Receipts are under
`/tmp/ventium-standard-iret-axi-sep30.dTKJW7/`. Neither full-PC test is qualified;
a cycle cap or clean host exit is not a desktop/timedemo PASS.
A separate same-binary cold diagnostic on CPU 12 **saved and stopped cleanly**
at exactly 350,000,000 cycles / 64,048,077 retirements. Its version-4
mouse/ATA/RTL checkpoint and stopped private disk passed read-only extent,
layout-checksum, repeated-context and unchanged-hash checks. The service is
inactive/dead with MainPID 0. CPU state is `0028:C001223B`, `S_STORE`,
CR3 `00306000`; zero backing-memory VDD hook globals are consistent with
capture before hook installation, but are not live cache-coherent operands.
This permits bounded same-build VDD
replays; it is **not** a boot acceptance run, and no restored state will
qualify the standard suite. Artifacts: `/tmp/ventium-win95-vdd-checkpoint-sep30/`.
The existing walker observer hard-codes another profile's numeric FSM state;
do not treat it as a valid page-walk probe on this candidate without checking
the elaborated enumeration. The subsequently approved, bounded
`pv86movrestart` regression now passes all four pinned-QEMU cases in functional
and cycle mode (1188/1773/1773/1804 exact records). It checks nonidentity ES
mapping, a precise single-byte page fault, repaired-PTE IRETD retry without
reloading ES, AH/BX/CX/high-half preservation, and three software-gate event
placements. Separate timing traces establish no paired issue before full-state
`--cycle-func` comparison. The first runner exposed a timing-vs-system trace
format mismatch; correcting that harness required no RTL or oracle relaxation.
Artifacts: `/tmp/ventium-pv86movrestart.JLymRE/`. This does not cover external
IRQ injection or establish VDD causality. An unrelated RF fixture remains unrun.

A single same-build native V4 diagnostic replay completed under its 600-second,
one-CPU/2-GiB bound, using private snapshot/disk copies and the checkpoint's
exact clock, RTC, mouse and VGA configuration. Its 80,000 consecutive retirement
records are 70,250,000–70,329,999; the exact stop was retirement 70,330,000 at
cycle 386,304,015, overshoot zero, process exit zero. This clean diagnostic exit
is not a cold boot or a performance qualification. Artifacts:
`/tmp/ventium-win95-vdd-window-sep30.zJYMIp/`; closed log SHA-256
`4fbf26269c286478d6e70ef2bfba9a240fbbd5698cf5812542c958f260f4cc6b`.

The first in-window contradiction with the stock VGA-ROM instruction stream is
retirement 70,279,256 / cycle 385,465,306 at `C000:0631`: expected `8A C4`
(`MOV AL,AH`), but the observed SP increment and ES=`0111` match popping the
preceding CALL's return address into ES. Addresses `0635` (`JMP`), `0639`
(`RET`) and `063F` (`CALL 0626`) exhibit the same POP-ES-like state change.
The actual loop subsequently retires `063C,063F,0640,0642,0644,0645`, with no
`0626` helper execution in the entire captured window. LOOP correctly decrements
low CX; the corrupted fallthrough bypasses count-setting callers. This is an
instruction-stream mismatch against the original ROM, not proof that the live
translated/shadowed executable bytes equal that ROM.

A second bounded replay now captures actual **pre-edge fetch ACKs** with a
default-off, host-only observer: all 205 observed read requests have
CS=`C000`, base=`000C0000` and the correct physical request address. At cycle
385,465,282, physical `000C0631` returns `20072007`; `C0635` and `C0639`
return the same word. `C063D` returns `E4072007` and the crossing `C063F`
request returns `FEFFE407`, isolating bad bytes in line `C0620–C063F` while
the following line remains consistent with the stock ROM. The installed decode
buffer contains those returned bytes and correctly selects one-byte POP ES.
This establishes incorrect memory-path data **before decoding**, not a decoder
or LOOP-counter failure. Static address routing does not alias this BIOS line
to VGA. The exact cache array/window/fill or accepted-store provenance is still
required before a root-cause fix; no address-specific bypass or blanket flush
has been introduced.

The observer changes neither the generated RTL model nor guest state: its
cached model archive is byte-identical to the original (`157a4fe9…`), all
80,000 retirement records match the first replay byte-for-byte (concatenated
SHA-256 `d51e116f3807441e62b524614d29dcaa46045932c42967293e096f8059d4539d`),
both runs stop at the identical cycle/retirement endpoint, and both final private
disks hash `0dbb5b8d2f893a14df3201e3d7d98d52331e950742003f3554378f9e1517c50b`.
The diagnostic host executable is `3f60b62b…`, not a new RTL-performance build.
Artifacts: `/tmp/ventium-win95-vdd-fetch-sep30.HDNdFR/`; closed log SHA-256
`9942ce3d82ac11bb48f7cf521e38cfac40fc3962d710cd3c9bff0e54cb0f7f4e`.
Neither replay qualifies a cold Win95 boot or the standard suite.

The next cache-source replay distinguishes the actual data array from saved
windows. Its first D-array fill at cycles **383,610,666–383,610,675** is
correct: critical-word order 4,5,6,7,0,1,2,3, stock ROM payloads, set `31`,
way 0, bank row `62`. At the bad fetch, cycle **385,465,282**, that still-valid
tag `C0` contains eight `07200720` words in the actual bank arrays;
`rd_line_raw` and the saved window agree. Thus this is a resident-line data
mutation, not merely a mislabeled response window. Neither L1D nor upstream
ao486 L2 held the target ROM line at the validated 350M checkpoint; DDR backing
was stock. In this third replay the first corrupting transaction was **not yet captured**: the
256-event budget expired at cycle 383,628,987 on repeated code-buffer fills.
Absence of later store records could not reject a ROM-write or other mutation
hypothesis. The subsequent mutation-only diagnostic below supersedes that limit.

This third replay also matches all 80,000 retirements, exact endpoint, all five
L1 profiler summary rows and final private-disk hash of both controls.
The generated RTL archive remains `157a4fe9…`; only the passive host executable
changed, to `6746af9f…`. Host observer tests pass 82 assertions and 19 static
integration checks. An optimized-away flush alias now prints unavailable `-1`
instead of silently disabling the entire existing L1 probe. No RTL or guest
state was changed. Artifacts: `/tmp/ventium-win95-vdd-cache-sep30.3GiRyk/`;
closed log SHA-256
`e21e31db8b303c18575683cdef44cb250d7019a09b5f310d37073e82afdbc94c`.
Its exit-zero diagnostic stop is not a Win95 desktop or standard-suite pass.

The fourth, mutation-only replay captures the **first corrupting store** and
all 32 byte writes to physical `C0620–C063F`. At cycle **383,982,139**, retirement
70,148,481, a real `STOSB` at protected-mode PC `C0256BBA` writes byte `20`
through linear `C129B620` to physical `C0620`; its acknowledged L1 bank write
selects set `0x31`, way 0, row `0x62` (98 decimal), byte mask 1. The next store
at cycle 383,982,146 writes byte `07`, and the sequence alternates `20/07`
through cycle 383,982,416. These accepted writes produce exactly the later
eight `07200720` bank words. All 40 watched events fit the bounded budget.

A separate unchanged-model native V4 replay stopped immediately before that
first edge, at cycle **383,982,139**, with retirement count 70,148,481. Passive
inspection proves the translation is correct: CR3 `00306000`, PDE at `00306C10`
equal to `00168267`, and PTE at `00168A6C` equal to `000C0A67`, independently
identical in DDR, resident ao486 L2 and L1D. The valid DTLB entry maps VPN
`C129B` to PFN `C0`, permission 7, dirty bit 1; the actual bus address is
`C0620`. The original 350M checkpoint already has the same mapping. No posted
write, pending L2 write or DDR read overlaps this inspection, and all three
memory layers still hold stock ROM bytes immediately before the first store.

This identifies a **generic cache/platform write-effect contract defect**, not
bad paging or decoding: ao486's `rom_rgn && !shr_rgn` predicate discards the
write while acknowledging the transaction, but the upstream cache treats the
ROM window as ordinary writable cached memory and modifies its resident bytes.
The proposed repair qualifies cached byte updates separately from bus write
permission, preserving all original write strobes, ordering and acknowledgements.
Stores requiring backend-authoritative handling invalidate only their touched
resident physical tags; the next read drains older writes and refills. Ordinary
RAM remains on the existing in-place update path. This also handles writable
UMA/shared windows without sampling their deferred policy at local posted ACK.
The repair is now implemented and leaf-qualified; the new cold standard-suite
round remains running and is not yet qualified.

The mutation observer is host-only and default off. It matches all 80,000
control retirements byte-for-byte, the exact endpoint, five L1 profiler rows and
closed guest-disk hash; generated RTL archive `157a4fe9…` is unchanged.
Its executable is `10b0b57c…`, not a new RTL-performance candidate. Host tests
pass 93 assertions and 20 static integration checks. Mutation log SHA-256:
`ae329f344e9b29a649b32552e51a499a7b5cfeb31780cc36c66c81a22bced5ed`;
artifacts `/tmp/ventium-win95-vdd-mutations-sep30.erfQPU/`.
Pre-store snapshot SHA-256:
`1095df712643322ee48a1c9abb72a7f16eb74f4b3b4f3389de84ed39f366e7e9`;
coherent inspection receipt is
`/tmp/ventium-win95-prestore-checkpoint-sep30.q2aVcz/translation_validation.json`.
Neither replay is a cold Win95 acceptance run.

`/tmp` exhausted its per-user quota despite available global space. The failed
first pre-store preparation did not launch the simulator; a fresh private
retry completed cleanly after reclaiming about 740 MiB. Only an obsolete,
byte-identical generated-model clone and four duplicate closed-replay snapshots
were removed. Their original model and snapshot, frozen executables, diagnostic
logs and guest disks remain; recreate the removed snapshot copies from the
authoritative `ventium-win95-vdd-checkpoint-sep30/before_vdd.snap` if replaying.
Live Quake logging had a quota-truncated interval near 2.365B cycles. Logging
and guest-disk writes recovered after cleanup, but absence of errors inside
that unlogged interval is not established. Completion still requires closed-disk
qualification and must not be inferred from continued CPU activity.

The final post-IRET CoreMark candidate independently **passes both complete
1,500-iteration seeds**, not merely the earlier build's results. Performance
retires 542,165,430 instructions in 713,805,640 clocks: IPC 0.75954209,
conservative **2.101412 CM/MHz**. Validation retires 541,458,819 instructions
in 712,760,043 clocks: IPC 0.75966495, **2.104495 CM/MHz**. Each reproduces
the corresponding earlier build's exact clocks, retirements, all five reference
CRCs and byte-identical guest output. Both report “Correct operation validated,”
guest exit zero, no error and 10.888/10.871 guest seconds. Their independently
verified two-query windows are 713,731,763/712,693,215 clocks, yielding
2.101630/2.104692 CM/MHz; whole-program scores remain the conservative authority.
Neither printed guest score nor the finite startup-clock bias is substituted
for these measured cycle denominators. This confirms the CoreMark portion and
the modeled 2.1 CM/MHz target, not full-system acceptance or CPI below one.

The new frozen TB SHA-256 is
`12851ddf6d2110b6d68acd2c317eaf3fa96e3c83c528f51cda5c3f64f1366a80`,
with compile-record SHA-256
`7ea9be11d60612f9936d67aeff808f6aaf7747ffed716fdd4b0c8c44f2db1711`.
Both unchanged reference images ran on CPUs 2/3 under a separate 2 GiB,
no-swap, 160-task scope with the approved **3,600-second limit per seed**;
actual host times were 38.20/38.53 minutes. Both simulator processes were
reaped, the driver returned zero, binary/image/compile/header hashes were
unchanged, all 86 captured source inputs still match, and mandatory/optional
settle-evaluation counts reconcile exactly. The direct-memory TB has no AXI
module in its filelist; the queue repair's full-PC acceptance is separate.
Final artifacts are `/tmp/ventium-coremark-matrix.u5110qg8/`, distinct from
the earlier `3ef25add…` run. Performance/validation result SHA-256 values are
`04bc192c7298e1a00e22f48d401389824af171ef9ba0cbc5dd29a7fcd8d78672`
and `4888d0aa30f5038492e375fd3f222920ddf9c25093312a174c594aaae83f59dc`.

A separate five-minute pinned-QEMU Win95 control, on a read-only source plus
private qcow2 overlay, remained at startup text. Audit found it omitted the
reference's mandatory `-icount shift=4,sleep=off`; that result is inconclusive.
After correcting the control runner, the **same** `cc68b005...` disk on pinned
8.2.2 / Pentium / 32 MiB / standard VGA reached a graphical display-configuration
dialog in 180 seconds, not the RTL's VDD protection error. The image was inspected
at `/tmp/ventium-win95-qemu-control-3ieaz1iu/screen_180.png`; CPL0 HLT at BIOS
linear `F6A0A` was GUI idle, not a terminal failure. A separate ordinary-key
control reached the date-setting dialog and task list, not yet an independently
qualified Explorer desktop. Source hashes remained unchanged; both controls
were reaped. SeaBIOS/VGA differences still prevent a causal CPU comparison.
The historical Win95 trace diagnosis was also corrected: VTM retired PCs use
post-commit CS, and DDR-only debugger stack reads may be stale relative to dirty
L1D/write-buffer contents. The new cold run's vector-6 ring records sixteen
traps at linear `000FFB17`, including actual word and dword IRET operands
installing the corresponding CS:IP aliases correctly. This is consistent with
Windows' documented ROM-ARPL V86 callback mechanism, not evidence of a bad
transfer into font data. No callback-handler defect or VDD cause has yet been
proved; see the corrected forensic evidence in `WIN95_ABLATION_2026-09-28.md`.

The short CoreMark guest's printed 1-ms interval is explained by the existing
host clock's one-second startup floor and one-ms syscall increment, not an
identified FP/ABI defect. Keep the unchanged timer and use actual clock-query
cycles for performance attribution; the printed guest score has startup-offset
bias. Both long seeds now meet the guest's duration requirement and error-free
reference-CRC checks. Their printed elapsed time still includes that finite
startup-offset bias; the actual-cycle denominators above remain authoritative
for modeled CM/MHz. Neither timer values nor guest code were modified.

An earlier verified cold raw-P54 full-PC gameplay window measured **0.45078423** over cycles
2,700,000,000–2,800,000,000 on binary
`b7cfbec7ee31c7ff7f81abf994995431f3c660b913ae2a9d3176c6d22a2db0ae`.
The actual private executable's SHA-256 was rechecked at the end of this window.
The retained earlier same-build interval below measured **0.42750217** over
1.4B–1.5B; it is historical evidence, not the current reported window.
Retained older binary
`3237b652…` baseline is **0.45746656**, cycles
1,150,151,638–1,400,151,638; it predates these builds and is not a matched-scene
A/B comparison.

The earlier measured-window receipt is the existing cold run's `quake/run.log` under
`/tmp/ventium-standard-iret-axi-sep30.dTKJW7/`:

| Simulated cycle | Profile clocks | Retirements | U retirements | V retirements |
| ---: | ---: | ---: | ---: | ---: |
| 1,400,000,000 | 1,399,999,637 | 407,258,224 | 320,677,922 | 86,580,302 |
| 1,500,000,000 | 1,499,999,637 | 450,008,441 | 352,529,208 | 97,479,233 |

Thus 42,750,217 actual retirements / 100,000,000 clocks = 0.42750217 IPC;
31,851,286 U + 10,898,931 V retirements independently reconcile the total.
Both raw captures, `quake/frame_00006.ppm` and `quake/frame_00007.ppm`, were
visually inspected using lossless PNG copies: clear advancing Necropolis
gameplay, weapon/HUD, shell pickup then grenade-launcher pickup. The earlier
1.3B scene still had the descending startup console and is excluded. The guest
console also contains fresh demo1/Necropolis/pickup output after its unchanged
pre-run prefix. No fatal simulator/engine error was found through this window.
This is a gameplay-window measurement, **not FPS, a completed 969-frame timedemo
or standard-suite PASS**. The cold run continues unchanged; capture cadence
does not count rendered frames.

The intervening receipt is `quake/gameplay_ipc_1800M_1900M.json` in that same run.
Its profile-clock endpoints are 1,799,999,637 and 1,899,999,637; retirements
578,364,995 and 623,538,067. The 45,173,072-retirement difference equals
33,960,715 U plus 11,212,357 V retirements, over exactly 100,000,000 clocks.
Raw captures `frame_00010.ppm`/`frame_00011.ppm` show active grenade combat
and advancing world/weapon/HUD without the loading console. This newer
scene-dependent IPC is not evidence of a code-change gain or timedemo FPS.

The intervening 1.9B–2.0B window has clocks 1,899,999,637–1,999,999,637
and retirements 623,538,067–668,418,001. Its 44,879,934 retirements equal
33,930,910 U plus 10,949,024 V retirements, over 100,000,000 clocks, hence
**0.44879934 IPC**. Raw endpoint captures 11/12 show advancing gameplay without
the loading console. The frozen private binary remains `b7cfbec7…`; this is
another scene-dependent gameplay measurement, not timedemo completion or FPS.

The prior verified 2.1B–2.2B window has clocks 2,099,999,637–2,199,999,637
and retirements 711,661,379–752,971,385: **41,310,006 / 100,000,000 =
0.41310006 IPC**. Its 31,533,079 U plus 9,776,927 V retirements reconcile
exactly. Raw captures 13/14 show combat followed by an advancing corpse/health/
rocket scene, with world, weapon and HUD and no startup console. This measurement
precedes the quota logging gap and any proposed cache-policy change; it is
not an isolated performance improvement, timedemo completion or FPS.

The prior verified 2.7B–2.8B window has clocks 2,699,999,637–2,799,999,637
and retirements 970,383,698–1,015,462,121: **45,078,423 / 100,000,000 =
0.45078423 IPC**. The 33,872,781 U plus 11,205,642 V retirements reconcile
exactly, and raw endpoint captures 19/20 show advancing gameplay. It is fully
after quota logging recovered and still predates the cache-policy candidate.

The prior verified gameplay window is **3.0B–3.1B**, on the same immutable b7
binary: clocks 2,999,999,637–3,099,999,637 and retirements
1,080,413,113–1,122,502,626. Thus **42,089,513 / 100,000,000 = 0.42089513 IPC**;
31,510,842 U plus 10,578,671 V retirements reconcile exactly. Raw captures
22/23 show advancing gameplay, including the nailgun pickup. This is another
scene-dependent measurement, not an isolated code-change gain, FPS or completed
timedemo. The cache-policy candidate remains unmeasured.

The prior verified gameplay window is **3.3B–3.4B**, still on immutable b7:
clocks 3,299,999,637–3,399,999,637 and retirements
1,207,857,190–1,249,674,243. **41,817,053 / 100,000,000 = 0.41817053 IPC**;
31,933,105 U plus 9,883,948 V retirements reconcile exactly. Unprocessed
captures 25/26 show advancing world/weapon/HUD. This still predates candidate
`2e63e532…`, which remains unmeasured; it is not timedemo completion or FPS.

The subsequent older-build gameplay window is **3.7B–3.8B**, on immutable b7:
clocks 3,699,999,637–3,799,999,637 and retirements
1,380,266,095–1,423,284,136. **43,018,041 / 100,000,000 = 0.43018041 IPC**;
32,750,980 U plus 10,267,061 V retirements reconcile exactly. Raw endpoint
captures 29/30 show advancing world/weapon/HUD, and the private binary's hash
remains `b7cfbec7…`. This older build predates `2e63e532…`, which had no verified
gameplay measurement at that observation. This is not timedemo completion or FPS.

### Cache-policy implementation and new cold acceptance round

The generic, optional `VEN_L1D_STORE_POLICY` interface separates cached-byte
updates from actual write permission. Disabled active bytes suppress local data
updates and invalidate only their accepted resident physical tags. Both arrays,
crossing writes and independent U/V store owners are covered. The ao486 shim
classifies each effective backend byte after the existing address fold and A20
gate; all `C0000–FFFFF` stores use backend-authoritative refill. No write strobe,
posted ordering, acknowledgement, read cacheability or ordinary RAM fast path
is changed. No application-specific address/opcode recognition, snapshot repair, global flush or
pairing disable is introduced. See [the interface contract](rtl-interface.md).

The actual L1/AXI/bridge/ao486-L2 composition has a clean negative witness in both
packed and banked modes: **907 ROM-value mismatches each, zero ordinary-RAM
errors**. After the fix, packed and banked modes each pass **20,948 checks**;
the paired-store profile passes **21,216**, all with zero errors. Coverage
includes all strobes, crossing and RAM/ROM boundary accesses, code/data reads,
both saved windows, independent channel backpressure, UMA and older queued
shared-window enable ordering, 18 atomic U/V cases, inactive/zero-strobe policy,
128 zero-extra-RAM-read checks and same-set unrelated-way preservation.
The source-extracted real shim helper/calls pass **186,880 strobe checks** over
5,840 address/A20/fold cases. These are directed regressions, not OS acceptance.
An additional actual-bank-array `VEN_P54_LOAD_STORE_PAIR` leaf checks an owned
U load consuming its correct value while a younger V store is accepted,
stalled/withdrawn or rejected. Two fixed profiles pass **539 checks**; the
policy-off control produces **six actual wrong ROM reads**, with zero control
or RAM errors. Its saved-window profile witnesses 12 primary U owners, eight
shadow V owners and 12 primed code owners. See
[the paired-load/store regression](../verif/l1/LOAD_STORE_POLICY.md); it is not
a replacement for the real delayed-AXI/ao486 composition or OS acceptance.
Clean negative evidence remains `/tmp/ventium-l1axi-ao486-romwrite.Vxr4Q9/`;
green evidence is
`verif/l1/obj_dir_store_policy_scratch/ventium-l1axi-ao486-romwrite.vhhQql/`.
Disposable precompiled-header caches were removed from closed negative builds;
their frozen source, executable and logs remain and the caches are regenerable.

Exact **107-macro shim** strict structural lint passes. Sixteen pre-existing
omitted pins were made explicit: unused debug/reset outputs remain open, and
the inactive debug hook input is tied to zero; reset behavior is unchanged.
The direct-memory raw-standard TB passes 107 functional QEMU comparisons and
19 hard timing bands after an active-source equivalence proof: 85 other compiled
inputs are unchanged, and the sole changed top preprocesses identically under
its exact 25 macros (neither L1/AXI nor the store-policy define is enabled).
All 20 non-gating exact cycle comparisons still diverge. This fast result does
not provide cache-path coverage or qualify the complete standard suite.

New full-PC candidate SHA-256:
`2e63e532a8866e101cecbcdf56ebf66c186a0c0d88ffd91e0f4f554ab24c9b83`;
compile record:
`13900362ff9cee6e2d850c8c5afef29e8e9296a47c8e4ef83e4157de544a84a5`.
All **204** captured inputs stayed unchanged through the 37.067-second,
32-job finely split build in the serialized 16-GiB/128-task scope. Generated
output and compiler scratch use the root filesystem, not the full external
scratch volume or quota-limited `/tmp`. The build is a frozen dirty-worktree
artifact, not a claim that unrelated pending changes are all committed.

Cold Win95 and DOS Quake runs now use that candidate, private fresh disk copies,
the unchanged pinned ROM pair and guest clock configuration. They run on CPUs
12/14, each with 2 GiB, no swap and 32 tasks; the older Quake baseline on CPU 13
is retained unchanged for now. Win95 has a 3B-cycle/12-hour safety bound; Quake
has a 30B-cycle/72-hour bound so a short cap cannot substitute for completing
969 frames. Both runs remain **unqualified**: no desktop or completed timedemo
has been established. Their artifacts are under
`ao486-sim/obj_dir_standard_acceptance_sep30.Au6tZL/`. Candidate `2e63e532…`
had no verified gameplay IPC at launch. The two unchanged 1,500-iteration CoreMark
seed images completed their new runs on CPUs 2/3 within the approved 60-minute
cap: **38.84 / 38.97 minutes**, simulator and guest exit zero, all five CRCs
matching reference, and guest durations **10.888 / 10.871 seconds**. The
performance seed used **713,805,640 clocks / 542,165,430 retirements**, scoring
**2.1014123677 CM/MHz**; validation used **712,760,043 / 541,458,819**, scoring
**2.1044950748 CM/MHz**. Every clock/retirement/clock-query/CRC/guest-time field
matches the prior same-binary run exactly. Binary, images, compile record and
generated headers stayed unchanged. These are the source-equivalent
direct-memory core tests, not L1/AXI policy acceptance. Closed receipts:
`verif/tb/obj_dir_coremark_standard_store_policy_sep30/ventium-coremark-matrix.n6rkp_jg/`.
At the 13:47 UTC observation, cold Win95 had passed 442M cycles without the
control's 425M VDD/protection error, but had not emitted an inspectable desktop
capture. Both CoreMark seeds had passed 603M clocks without a terminal error;
those intermediate counters were not completed correctness results or scores.
The subsequently closed CoreMark results above supersede that pending status;
Windows desktop and Quake timedemo are still unqualified.

The subsequent cold Win95 run passed 875M cycles without the old terminal VDD
error but still had no graphical desktop capture. Coherent historical 350M
and pre-store snapshots identify the repeated `C00031xx/32xx` and `C0008Exx/8Fxx`
routines as event/callback polling. Their bytes agree across DDR/L2/L1 and the
two checkpoints. The exact candidate's source audit finds no missing STI-shadow
clear or fast-path IRQ divert; the live log also records vector `0x50` at
`C0008FC2`, inside its `STI; NOP; NOP; CLI` window. Neither static code nor
ongoing retirement identifies the current wait predicate or proves a desktop.
Evidence remains in
`verif/tb/obj_dir_store_policy_verify_sep30/kernel_loops/`. No live attach,
guest-state mutation or snapshot restoration was performed for that analysis.
The address-shape tests hold A20 fixed; older posted stores versus a younger
dynamic A20 change are not qualified by those checks.

At 14:46 UTC, a separate **cold diagnostic** launched from the same original
Win95 disk, pinned ROMs and frozen `2e63e532…` executable. It requests one native
V4 checkpoint at 450M cycles and stops immediately afterward, with no restore,
on CPU 2 under 2 GiB/no swap/32 tasks and a 3,600-second host limit. Its output
is `ao486-sim/obj_dir_win95_policy_wait_sep30.yUIBxo/`; the acceptance runs remain
untouched. The purpose is to identify the current stack predicate and event
state, not qualify desktop boot. Native snapshots are not drained memory
images: active fill victims and registered/queued writes must be qualified
before reporting coherent stack or paging values. No live debugger attach
or privileged guest-memory read has been performed.

That cold diagnostic subsequently **closed cleanly at exactly 450,000,000
cycles / 99,654,751 retirements**, after about 42 minutes 29 seconds. The
simulator was reaped with exit zero; no restore or terminal error was recorded,
and the original disk/ROM/binary hashes remain pinned. This diagnostic stop is
not a desktop pass. Snapshot SHA-256 is
`9bd97a823180b2b060293d2fc0e19ac24aa06afeeef7f930e4e1fee0af4e14ba`, paired
closed-disk SHA-256
`8256ceafdc21f4b1fa15dc3a0386fd6dfd7f8615e4009bfbe2d28ed157fbf7c2`;
`closed_pair.json` preserves the lifecycle/configuration proof. The exact
serialized-layout reader passes 22 host-only checks. Its first offline parse
finds `S_PIPE`, `CS=0028`, `EIP=C000324F`, `EAX=0`, `ZF=1`, with L1/L2 and
write queues idle. All 30 queried stack/global/context words have qualified
canonical evidence, without resident-layer disagreement or pending writes.
This is a null-list return sample, not the predicate-call phase; canonical
bytes are not automatically proof of the CPU's previously served operand.
Supplemental current-byte inspection confirms the selector's resident I-cache,
ITLB and canonical memory evidence agree: `C000324F` is `RET`. Its current
linked record at `C0FDA944` has null next link, callback candidate `C0FFC4BC`,
argument `C13BDE54`, and flags `00000131`. Those flags intersect current
`ECX=800000E2` at `20`; the inspected instructions therefore exclude that entry
and reach the null-list return. This is not a cyclic-list witness or proof the
exclusion is wrong. Current caller/predicate investigation remains diagnostic
work, and raw stack return candidates are not a validated unwind.

The current candidate now has a **verified gameplay measurement**:
`2e63e532…`, cycles **1.4B–1.5B**, clocks
1,399,999,637–1,499,999,637, retirements 407,258,224–450,008,441.
**42,750,217 / 100,000,000 = 0.42750217 IPC**; 31,851,286 U plus 10,898,931 V
retirements reconcile exactly. Raw captures 6/7 show clear advancing
world/weapon/HUD without the startup console; the private executable hash
matches the frozen candidate. The receipt is
`ao486-sim/obj_dir_standard_acceptance_sep30.Au6tZL/gameplay-ipc-1400m-1500m.json`.
This matches the older b7 build's same cold interval exactly, rather than
establishing a cache-policy performance gain. Another 598 sampled startup
states from 900M–1.2B and the 1.2B raw capture also match between builds.
Win95 later passed 1.5B cycles without the old terminal VDD error but still
had no desktop capture. Neither desktop nor closed 969-frame timedemo is
qualified; reaching gameplay does not complete the standard suite.

The next verified current-candidate gameplay window is **1.5B–1.6B**:
clocks 1,499,999,637–1,599,999,637 and retirements 450,008,441–493,336,944.
**43,328,503 / 100,000,000 = 0.43328503 IPC**; 33,082,465 U plus 10,246,038 V
retirements reconcile exactly. Raw frames 7/8 show advancing clear gameplay,
and the private executable still hashes to `2e63e532…`. This is the current
measured build/window, not timedemo FPS, a code-change gain or suite PASS.

### Quake acceptance checker hardening

`tools/run_quake_standard.py` freezes private binary/ROM/disk inputs, records a
clean pre-run console baseline, and requests graceful host closure only after a
fresh 969-frame result. `tools/check_quake_timedemo.py` rejects restored state,
stale results, caps, abnormal exits and terminal errors. The actual DOS fatal
banner is `Error:`, not just `Sys_Error:`; anchored console and VGA-row variants
now fail acceptance even after a valid result. Read-only `mtype` collection is
bounded while reading: 16 MiB stdout, 64 KiB stderr and 15 seconds. Overflow or
timeout kills/reaps only the reader without unbounded pipe draining. All **23
checker + seven runner host tests pass**; no guest simulation is launched by
these tests. The currently running supervisors loaded the earlier checker, so
their eventual `result.json` cannot alone qualify a run: final acceptance must
invoke the updated checker afresh against the reaped simulator's closed disk.
The updated checker hash is
`adc60d3350874627fb78d0cad13d4421f430060820e6461d3d19ffa1122f802d`.

```sh
PYTHONPATH=tools python3 -B -m unittest \
  tools/test_check_quake_timedemo.py tools/test_run_quake_standard.py
```

Evidence: `/tmp/ventium-standard-sep30.qUCAcQ/` (full-PC inputs and logs),
`/tmp/ventium-coremark-matrix.kpjs_mph/` (long seeds),
`/tmp/ventium-pair-size-profile-fhvp3cac/` (pair-size regression), and
`/tmp/ventium-win95-qemu-control-ablmz2cv/` (noncausal control).
