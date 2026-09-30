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

Latest status at **21:17 UTC**: the V86-corrected candidate independently passes
both complete CoreMark seeds, with every reference CRC and cycle count unchanged.
Cold Windows 95 has not reached a verified desktop. Cold DOS Quake on the
current candidate has reached clear gameplay but has not completed its
969-frame timedemo. **Latest measured gameplay IPC is 0.45173072**, frozen
current candidate `cdcb6faa…`, cycles **1.8B–1.9B**. It is not timedemo FPS,
a measured gain from either correctness fix or full-suite PASS.

The user authorized 60 minutes per CoreMark seed. Both untouched 1,500-iteration
seed images **completed without error**, matched all five reference CRCs and
printed “Correct operation validated.” Their guest durations exceed ten seconds.
The CoreMark correctness portion of the standard suite passes; this does not
qualify Windows 95, Quake, the full standard suite or an official EEMBC submission.

| Completed seed | Whole-program clocks | Retired instructions | CoreMark IPC | Conservative CM/MHz | Clock-query window | Query-window CM/MHz | Guest seconds | Host minutes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Performance, 1,500 iterations | 713,805,640 | 542,165,430 | 0.75954209 | **2.101412** | 713,731,763 | 2.101630 | 10.888 | 38.84 |
| Validation, 1,500 iterations | 712,760,043 | 541,458,819 | 0.75966495 | **2.104495** | 712,693,215 | 2.104692 | 10.871 | 38.97 |

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
and the private executable still hashes to `2e63e532…`. This is a retained
earlier measurement, not the latest window, timedemo FPS, a code-change gain
or suite PASS.

### IDE interrupt correction and continued Win95 diagnosis

The current matched IDE leaf reproduces a generic protocol error: a data-in
descriptor already raises its IRQ when the host publishes word 5, but draining
its final buffer raises the same IRQ again after regular status acknowledged it.
Single READ and IDENTIFY therefore produced two edges instead of one; two-block
READ and READ MULTIPLE produced three instead of two. The pinned QEMU 8.2.2
`hw/ide/core.c` raises READ IRQ at data-ready publication, then stops the final
transfer without another IRQ. Backend WRITE completion remains a separate host
publication, not the CPU's last data-port write.

The minimal, opcode-independent correction removes the drain-time IRQ branch
and its unused descriptor sidecar. It retains all status, DRQ, data, backend
ownership, regular/alternate status priority and WRITE completion behavior. It
adds no delay, flush, bypass or guest workaround. The canonical platform patch's
IDE section is synchronized; unrelated preexisting PS/2 edits remain unstaged.

Matched production-device microtests: **2,623 checks / 2,560 exact data words**;
old source has exactly four extra-IRQ failures and zero control/data errors;
fixed source has **zero failures**. Eleven cases cover READ, IDENTIFY, WRITE,
nondata/error IRQ publication, alternate status, established nIEN, publication
colliding with a status read, command supersession and reset. They use actual
public ports and the existing RAM, with no forced DUT state. See
[the device gate](../verif/ide/README.md). This is not proof that the extra IRQ
caused the Win95 wait, and does not qualify pending-IRQ re-enable, ATAPI or DMA.
The repeated GREEN leaf also passes. Fourteen host-only classifier cases now
reject arbitrary missing IRQs, mismatched check totals and contradictory error
markers, including a Bash `!`/`errexit` loophole caught by independent review.

The separate corrected full-PC binary is SHA-256
`3120b065b078c2e1e2127f80c3eca65666bac8baaf0a5b688a3707260f85f670`,
with compilation record
`918ef8e9f3afefa50114a60c146e4c4722dcab2d3416ead3aa74a610cf78a52b`,
under `ao486-sim/obj_dir_ven_ide_irq_sep30.c9fbuC/`. The capped 32-job simulation
build completed normally; no Vivado or bitstream run was launched. The direct
core's active preprocessing remains byte-identical to the completed CoreMark
binary. Its fresh fast gate again passes 107 functional comparisons and 19
metric bands, with one informational kernel and 20 non-gating per-instruction
cycle divergences. This does not replace device or full-system acceptance.

Independent build audit: all 204 recorded inputs were stable before/after the
build; only production `ide.v` differs from `2e63`. All 156 Verilator source
dependencies are covered and all 107 defines match in order. The historical
host manifest omitted three actual GCC dependencies (`tools/rep_accounting.h`,
`sim_stop_request.h`, `retire_fault_ring.h`): they are currently clean with
mtimes predating the old build, but historical hashes were not captured. Thus
this is not a claim of complete historical C++ input identity. Receipt:
`obj_dir_ven_ide_irq_sep30.c9fbuC/ide-build-audit.json`, SHA-256 `77eb5ef2…`.
Removing the two IDE sidecar fields changes native serialization checksum;
old `2e63` native snapshots **must not be restored into `3120`**.

Fresh `3120` cold acceptance jobs were launched on CPUs 2/3 under user units
`ventium-standard-win95-ide-irq-sep30` and
`ventium-standard-quake-ide-irq-sep30`. Their private disk, binary and ROM copies
are under `ao486-sim/obj_dir_standard_ide_acceptance_sep30.BkKjWt/`.
Both have 2 GiB/no-swap/32-task/one-CPU limits; Win95 has a 3B-cycle/12-hour
bound and Quake a 30B-cycle/72-hour bound. They use the original source disks,
unchanged clock/ROM settings and no restore or guest modifications. The new
Quake supervisor loaded the current acceptance checker at startup. A cap or
ordinary exit is not acceptance. They have since been gracefully stopped and
reaped after replacement by the V86-corrected candidate below; neither qualifies
desktop or timedemo completion. Logs, private disks and inputs remain preserved.

The cold `2e63` Win95 run passed 2.1B cycles without the former terminal VDD
error but has no desktop. Offline diagnosis now identifies its zero-count
semaphore wait as IOS media-check/reset fallback through RMM, not an outstanding
ATA transfer. A separate same-executable native replay confirms that the event
selector rejects the queued RMM callback because of saved VM-control bit 20h,
not merely the native snapshot's IF=0. No guest flag or semaphore is changed.

The IRQ-focused replay covers 60,000 retirements, cycles
450,533,520–450,655,248. The coherent IDT[50h] gate points to
`0028:C0001100`; that actual handler runs at cycle 450,588,062 after the
STI/NOP window. The timer, interrupt admission and scheduling therefore do
progress. VMM time advances 14 ms; the RMM timeout's remaining list delta falls
767 to 753 ms. Its timeout callback has not yet run in this short window, and
the guest's timeout path can reschedule rather than complete the request.
Neither a permanently stopped timer nor a lost ATA IRQ is established.

Both replay diagnostics are closed/reaped with exit 0 and unchanged private
disk SHA-256 `8256ceaf…`. The original closed 450M snapshot/disk and all cold
acceptance runs remain preserved. Replays accelerate diagnosis only; they do
not count as Windows desktop or cold timedemo acceptance. The standard suite
remains incomplete; the IDE-corrected binary also needs system acceptance.

The retained `2e63` gameplay window at 2.4B–2.5B has clocks
2,399,999,637–2,499,999,637; retirements 840,136,348–884,376,957.
33,816,593 U plus 10,424,016 V retirements sum to 44,240,609,
giving **0.44240609 IPC**. Raw frames 16/17 visibly advance gameplay.
This window predates the IDE-corrected binary and is not completed timedemo FPS.

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

Earlier evidence: `/tmp/ventium-standard-sep30.qUCAcQ/` (full-PC inputs and logs),
`/tmp/ventium-coremark-matrix.kpjs_mph/` (long seeds),
`/tmp/ventium-pair-size-profile-fhvp3cac/` (pair-size regression), and
`/tmp/ventium-win95-qemu-control-ablmz2cv/` (noncausal control).

### V86 bitmap correction and fresh candidate qualification

The old core incorrectly bypasses the TSS I/O bitmap in V86 when IOPL=3.
P5's V86 rule and pinned QEMU's `gen_check_io()` require the bitmap whenever
VM=1, regardless of IOPL. The one functional change is
`ioperm_needed = sys_mode && !real_mode && d_io && (v86 || (eff_cpl > iopl))`.
It reuses the existing permission FSM; protected non-V86 CPL<=IOPL still
bypasses it. No new states, global stalls, cache flush, guest patch or
benchmark-specific exception are introduced. Required V86 permission reads
are architectural work, not an invented performance delay.

[The focused gate](../verif/sys/tests/pv86iop3/README.md) has 15 cases:
12 denied V86/IOPL3 scalar IN/OUT byte/word/dword forms, DX and immediate;
allowed V86/IOPL3 OUT; protected CPL3/IOPL3 denied-map bypass; and denied
V86/IOPL0 OUT. Only the trailing port bit is denied for word/dword cases.
All 15 identical images pass QEMU self-checks. The old frozen TB produces
exactly 12 negative witnesses: illegal I/O retirement, missing #GP(0), and
the forbidden actual device transaction. The three controls pass. The new
TB passes **all 15 exact functional comparisons / 4,389 records**, with
zero I/O port/width desynchronization and no denied device transaction.
Both matrix drivers are closed/reaped; a known RED is not a correctness pass.

Subsequent runner-only validation rejects duplicate case IDs and a RED matrix
containing no negative case. All 23 bounded host-only checks pass. Those checks
run before scope/artifact creation and change no assembly or DUT behavior;
the historical RED/GREEN receipts correctly retain their earlier runner hash.

Evidence is `verif/sys/tests/pv86iop3/obj_dir_artifacts/`:
RED `pv86iop3.RnGPxU/receipt.json`, SHA-256 `63861ea1…`;
GREEN `pv86iop3.U7a53q/receipt.json`, SHA-256 `944d70a8…`.
All ELF/image hashes match between RED and GREEN. Tests check fault EIP,
error code, saved VM/IOPL/flags, GPRs, V86 segment frame and SS:SP; final
HLT checks state preservation again. No DUT state is forced.

Fresh direct TB SHA-256:
`8c3b6954ff139b8e8b535e57e6401798ccbd09170d2444f7cf2184c618292e35`.
Fresh full-PC SHA-256:
`cdcb6faa8599124f9e1c6b663d04cd23206a31a7a88bc325f49381fbb5479c56`.
The fresh fast gate passes **107 functional comparisons / 19 gated metric
bands**; one kernel is informational and 20 instruction-cycle comparisons
remain non-gating divergences. This is not a full `verify-all` claim.
Existing `pv86`, `piopermwrap` and `pcpl` controls also pass exact system-state
comparisons (949/292/304 records). The canonical `ppriv` runner still skips its
RTL half; a separate bounded invocation using its supported `--cosim` decode
interface passes **353 exact records**, including all three expected #GPs.
No RTL or golden masking was changed for that invocation. All four controls
are reaped with stable build inputs; artifacts are
`verif/tb/obj_dir_system_controls_v86_sep30.BS7xJV/`.
Both models were built sequentially under one 32-job/16-GiB/no-swap scope.
The canonical five-profile structural lint matrix passes. Separately, the
actual candidate's 107 defines pass strict core lint with all six structural
classes fatal (`raw-profile-lint.retry.log` in the direct build directory).
The first scratch lint driver timed out before frontend launch because Python
closed the inherited lock FD. That attempt was reaped; retaining the FD fixes
the driver without changing the resource guard or RTL. The retry frontend
completed in 2.129 seconds, allocating 214.762 MB. No synthesis was launched.
The new manifest captures **340 path entries / 227 distinct files**, including
the previously omitted C++ headers, and all checks before/after both builds
pass. Reversing only the predicate and three comment blocks reproduces both
old full-file hashes while retaining unrelated dirty-worktree code. Direct
and full-PC Verilator profiles match their predecessors except output paths;
the full-PC profile retains all 107 defines. Audit:
`verif/tb/obj_dir_v86_iop3_sep30.nhltiM/v86-iop3-build-audit.json`
(SHA-256 `c142d71a…`). The committed checkpoint is still not claimed to include
all older unrelated source changes present in the measured worktree builds.

Fresh standard-suite runs use original source disks/ROM settings and no native
restore, save-state shortcut or guest modification:

- CoreMark: user unit `ventium-standard-coremark-v86-iop3-sep30`, CPUs 4/5,
  two untouched 1,500-iteration seeds, **3,600 seconds per seed**, 2 GiB/no swap.
  Both now pass; results belong to `verif/tb/obj_dir_v86_iop3_sep30.nhltiM/`.
- Win95: `ventium-standard-win95-v86-iop3-sep30`, CPU 6, 2 GiB/no swap/32 tasks,
  9B cycles/24 hours. The old 3B cap represents only 66.7 seconds at the fixed
  45-MHz guest clock; raising the cap does not change guest time or qualify boot.
- Quake: `ventium-standard-quake-v86-iop3-sep30`, CPU 7, the same resource
  limits, 30B cycles/72 hours. Its fresh supervisor loads the current checker.

The full-PC pair's private inputs/logs are
`ao486-sim/obj_dir_standard_v86_iop3_sep30.W6RkaF/`. The superseded IDE-only
pair closed after normal stop requests; neither is an acceptance result.
Its 268 sampled Win95 states at 400M–540M match old `2e63` exactly, so the
IDE fix is **not** established as the remaining wait cause. The original
`2e63` Win95 run naturally closed at 3B cycles with zero host exit but no
desktop capture: explicitly `clean_exit_unqualified`, not PASS.

Offline Win95 evidence identifies virtual IRQ0 in service and VPICD ownership
of the private VM bit excluding the queued RMM callback. Real timer IRQ entry,
V86 return and VMM time advancement are observed. The saved 450M bitmap permits
PIC ports 20h/21h/A0h/A1h; therefore the V86 permission defect is **not a causal
witness for this Win95 wait**. No semaphore, virtual-IRQ bit or EOI is forced.
The evidence remains in the closed diagnostic's `analysis.md` and
`virtual-irq-receipt.json` under `obj_dir_win95_policy_wait_sep30.yUIBxo/`.

Unqualified I/O issues remain: OUTS has a separate permission-dispatch bypass;
the bitmap FSM's four-byte read versus two-byte reference extent, TSS validity
and page-fault priority require separate witnesses. This scalar fix does not
claim to close those cases or qualify strings/REP/VME. No speculative repair
or guest-specific bypass has been folded into the current candidate.

Latest verified gameplay window: old `2e63`, profile clocks
3,299,999,637–3,399,999,637, retirements 1,207,857,190–1,249,674,243.
31,933,105 U plus 9,883,948 V sum to 41,817,053 retirements:
**0.41817053 IPC**. Raw frames 25/26 visibly advance gameplay and the private
binary hash matches. The current `cdcb` candidate remains unmeasured;
**Win95 desktop and completed Quake timedemo are still not qualified**.

### Closed V86-candidate CoreMark result

Both fresh `8c3b6954…` seeds completed, matched all five reference CRCs and
reported correct operation. Performance: **713,805,640 clocks / 542,165,430
retirements / 2.101412 CM/MHz**, 10.888 guest seconds, 38.81 host minutes.
Validation: **712,760,043 / 541,458,819 / 2.104495 CM/MHz**, 10.871 guest
seconds, 39.34 host minutes. These exactly reproduce the prior candidate's
whole-clock counts, retirements and CRCs: **0% measured CoreMark gain or
regression** from the V86 permission fix. Supplementary query windows remain
713,731,763 / 712,693,215 clocks. CoreMark IPC is 0.75954209 / 0.75966495,
not gameplay IPC and not CPI<1. The conservative whole-program score remains
authoritative; neither guest timer startup bias nor host wall speed is credited.

Artifacts: `ventium-coremark-matrix.6_ao0gm2/` in the direct build directory;
summary SHA-256 `13805d8d065061c3dc9570fc7c52a803eac28b438ba584c4e40d4a8535234daf`.
Both child wait returncodes and guest exits are zero; both logs are closed,
all three actual supervisor/simulator PIDs are absent, and binary, images,
compile record, generated headers and 86 source inputs remain hash-stable.
Every mandatory edge evaluation is retained and settle counts reconcile.
Runtime `resources.json` records the actual 2-GiB/32-task cgroup envelope.
The live invocation ID was `b4a6d83394c941b5875832a4eb011f23`.
Its user journal records startup at 18:03:31 UTC and normal terminal resource
accounting at 18:42:52 UTC, 39m20.737s wall / 17.2 MB peak. The transient unit
has since been collected: its default inactive/dead/zero-status object is
**not** a retained exit-status or resource-cap witness. Qualification rests
on the actual completed child results, integrity proofs and process closure.

Current Win95 passed the former 383M corruption and 425M terminal VDD points,
but its 450M/491M samples still show the VMM polling region, with no graphics
capture or desktop. Counters differ from old `2e63`; identical control flow is
not claimed. The early sixteen-event fault ring is exhausted and cannot prove
absence of later #GPs. The CoreMark suite member passes independently; the
**full standard suite remains incomplete**, and cold Win95/Quake continue.

### Same-model Win95 transition recorder preparation

The cold `cdcb6faa…` Win95 and Quake acceptance runs are unchanged. A separate
one-CPU, 2-GiB/no-swap diagnostic cold boot requests a native v4 snapshot at
393.8M cycles, before the observed first persistent VMM polling region. It uses
the same original Win95 disk, ROM pair, mouse and 45/45/90-MHz settings. Its
closed checkpoint plus paired private disk will support a 1M-cycle transition
trace; neither a saved checkpoint nor a diagnostic replay counts as desktop
acceptance. No semaphore, virtual-IRQ bit, timer or EOI is patched.

The host-only recorder was relinked in private copy
`ao486-sim/obj_dir_ven_state_v86_sep30.sLMWqy/`, without Verilator or an FPGA
build. Its actual compile/link log is `state-relink.retry.log`; the new profiler
SHA-256 is `b4e835f8b04c0b5be9fdcd9dd3caf25510dd8c8b084af9ee4d7808d0d3538669`.
All **120 generated model-file/archive hashes** match both this copy and the
original frozen model. The original `cdcb` executable, host object and sources
remain unchanged. The generated field audit covers **12,767 retained numeric
fields**, including all **12,762 serializer fields**. Scheduler queue effects
are retained in destination arrays; external DDR/host/disk state is not in the
internal delta file. This is not a standalone full-machine checkpoint.

The first private relink attempt incorrectly treated an up-to-date Make target
as success. It was rejected, and its log/receipt are retained as
`state-relink.log` / `ven_state_relink.first-no-rebuild.json`. The helper now
keeps the real relative dependency spelling, requires actual object rebuild and
link evidence, accepts only the exact generated legacy/standard target shapes,
and forwards the real inherited build-lock descriptors. Seventeen host tests
pass, including actual GNU Make negative/positive reproduction. The successful
receipt SHA-256 is
`941b0399cc89034436a6819a890d8e7e06545bd8a096ed5fa4d20441fa320f5d`.
This proves model identity and host compilation, **not yet recorder
noninterference**: frozen-executable pilot, OFF/ON native-state/disk comparisons
and complete trace reconstruction remain required before using trace evidence.

The diagnostic cold run closed normally at **393,800,000 clocks / 71,933,995
retires**, with actual child exit/wait zero and supervisor/child PIDs absent.
Its journal records completion at 19:49:20 UTC, 36m50.352s wall, no OOM kill;
the 2-GiB peak includes charged file cache and generated reclaim events. It is
`clean_exit_unqualified`, not desktop PASS. Snapshot SHA-256:
`feaf09d900a763fd6d83edfa9b73669edae7cd2a15f6d609dec0369143241cde`;
closed paired disk SHA-256:
`0dbb5b8d2f893a14df3201e3d7d98d52331e950742003f3554378f9e1517c50b`.
The native v4 envelope independently checks the current root checksum
`0x7d41468ce8a23b50`, 424,182 serialized bytes, 12,762 fields, ATA extent 18,760,
matching 56-byte contexts and trailer. The ATA host ABI is unchanged; the
earlier IDE sidecar removal changed retained RTL serialization. Older `2e63`
native snapshots remain incompatible and are not used.

The verified pair is preserved as `before-wait.bundle/` under that diagnostic
directory; its canonical `gameplay.snap` filename does **not** imply gameplay.
The unchanged `cdcb` reference is compared with the host-only `b4e835f8…`
profiler. The capture wrapper now validates target/receipt/executable and every
model hash before staging, supports standard-only targets without stale legacy
aliases, forwards v4/mouse settings to all four passes, and reconstructs both
pilot and full trace with exact requested start/count/footer before success.
All **29 host tests** pass, including real miniature corrupt/truncated streams.
Tooling commits `8c82650` and `1232bb9` are pushed; no RTL change is included.
The bounded transition capture completed cycles **393.9M–394.9M**, on one CPU
with private disk copies under the 4-GiB serialized guard. Its frozen-source
pilot, full trace and noninterference checks all pass. The window diagnoses the
first wait transition, not the whole preceding boot history.

The verified gameplay baseline at recorder preparation was old `2e63`, profile clocks
3,699,999,637–3,799,999,637, retirements 1,380,266,095–1,423,284,136:
**0.43018041 IPC**. U and V contribute 32,750,980 and 10,267,061 retirements,
which sum exactly. Raw endpoint frames 29/30 advance gameplay. The current
`cdcb` candidate is still unmeasured; this is not a fix gain or timedemo FPS.

The latest completed older-build window is **3.8B–3.9B**: profile clocks
3,799,999,637–3,899,999,637 and retirements
1,423,284,136–1,466,412,425, **0.43128289 IPC**. U contributes 32,212,142
and V 10,916,147 retirements, summing exactly to 43,128,289. Raw frames 30/31
advance into the Nails pickup. The private executable remains full SHA-256
`2e63e532a8866e101cecbcdf56ebf66c186a0c0d88ffd91e0f4f554ab24c9b83`.
Its counters also match the older b7 control at these windows; both logs and
binary identities were independently checked, not substituted. Current `cdcb`
gameplay, Win95 desktop and timedemo completion remain unqualified.

### Qualified million-cycle Win95 transition capture

Artifacts: `capture-tmp/ventium-state-delta.cb8zyvwg/` below the current Win95
diagnostic directory. The guard/driver was reaped with actual exit zero. The
pilot independently reconstructs all 1,000 cycles and matches the original
`cdcb` executable's terminal native state and disk byte-for-byte. The full OFF
and ON passes end at **394,900,000 clocks / 72,080,758 retires**, in the VMM
polling region, and likewise match both native terminal state and disk.
The original cold-derived input bundle was reverified after completion.

Full trace: **1,000,000 consecutive cycles, 12,768 fields / 426,746 packed bytes**
(12,767 retained model fields plus the host retirement counter). The independent
streaming reader reconstructs every field/cycle, verifies the exact requested
window, complete footer, independent terminal image and no trailing data before
success. Compressed size is **368,354,018 bytes (351.3 MiB)**; caches and arrays
are recorded differentially. The original model/executable/guest state is not
patched. Internal state still excludes external host DDR/PS/ATA/disk state.

| Qualified evidence | SHA-256 |
| --- | --- |
| Full `on/state.delta.gz` | `ae61491877e4857226378b005c132b47d46f17353c33006798e46837355a93d3` |
| Full OFF/ON `end.snap`, identical | `32eaa576492d6f43b3c1d36d6395f48ef03152a034515bb78421d904b8bdf2e6` |
| Full OFF/ON `guest.vhd`, identical | `8256ceafdc21f4b1fa15dc3a0386fd6dfd7f8615e4009bfbe2d28ed157fbf7c2` |
| Frozen-reference/observer pilot `end.snap`, identical | `3ac17bcf60f496462a959fe6d2b4ed7bf4d3aa064a557a599b3353d62c813c7a` |
| Capture driver log | `ad6966495bf1deeb9b6ba7a2426e44a952f2f428a1e8169f6e86e1c3e30fcb92` |
| Current native-layout/preflight receipt | `04cd301c69ab7c47a7dd2966f04e5959d0f11ecb8b8cd3a3ab0191c61bcf73ec` |

The live capture scope showed 4-GiB/64-task caps and zero OOM/kill events.
Near its cap, a sampled memory breakdown was about 14 MiB anonymous versus
3.75 GiB charged file cache, with reclaim; the cap peak is not a 4-GiB DUT RSS.
Root-volume disk copies have sufficient checked space. Independent full-trace
I/O/PIC/interrupt analyses are now underway; no remaining wait cause is claimed
from a correlated settled level alone. A record at cycle c is post-edge state:
its ACK level must be confirmed by the appropriate transition on c→c+1. The
actual physical PIC byte strobe is distinct from later aggregate core I/O ACK.

Latest verified gameplay baseline is older `2e63`, **4.0B–4.1B**: profile clocks
3,999,999,637–4,099,999,637, retirements 1,508,193,850–1,548,999,708,
**0.40805858 IPC**. U contributes 31,949,492 and V 8,856,366 retirements,
summing exactly to 40,805,858. Unprocessed frames 32/33 visibly advance through
the corridor, and the private executable retains its verified `2e63` hash.
Current `cdcb` remains unmeasured. **CoreMark passes; Win95 desktop and completed
Quake timedemo remain unqualified**, so the goal and cold acceptance runs continue.

### Independent transition analyses and first current-candidate gameplay

Two independent readers consume the complete Win95 delta, with no event cap:
the strict C++ inspector and the actual Python `Reader` both reconstruct every
cycle, validate footer/terminal/EOF, and reconcile **138,967 fresh retirements**
against the host counter. Their results match. The inspector's synthetic tests
use the production delta writer and cover pair retirement, packed-snapshot
ownership, ACK edge phase, wrong windows, missing fields, corrupt/truncated
streams, trailing data and output-overwrite rejection. These are host-only
analysis tests, not additional RTL or guest runs.

Observed I/O and interrupt facts in **393.9M–394.9M**, not the preceding boot:

- **726 bitmap consultations / 1,452 memory beats**, all permitted: 640 dword
  INS from 1F0h and 86 scalar IDE accesses. No denied consultation or PIC-port
  consultation appears. 220 scalar completions plus 640 INS elements exactly
  reconcile with **860 shim/I/O-bus requests**.
- Scalar completions include 128 dword OUTS elements. OUTS's separate string
  dispatch still bypasses the bitmap check; the consulted 1F0h–1F3h bits here
  are allowed, so this is **not a causal witness for this wait**. The separate
  four-byte bitmap-read extent and descriptor-validation ordering concerns
  remain open; do not label them fixed by the V86 predicate repair.
- At edge **394,358,063**, the core accepts hardware vector 50h once, from
  V86 F000:141Bh. PIC ISR changes 0→1 and the delivery counter increments once.
  `intr_take` remains high for one further settled record because the pending
  register samples the previous PIC level. State-qualified INTA is already low
  in the gate-delivery state: there is **no second admission or frame**.
- The protected VPICD path writes 21h=B9h at 394,358,572, **20h=60h at
  394,358,659**, then 21h=B8h at 394,359,017. The specific physical EOI clears
  hardware ISR 1→0; its instruction retires at C002AC9Ah. This proves physical
  acknowledgement, not a virtual EOI or the earlier virtual-ISR origin.
- The 41 delivery-counter changes comprise 40 ROM #UD callback transitions
  and that one hardware interrupt. They are not 41 unexpected faults or #GPs.

The software chronology is now instruction-qualified: IOS issues request 3
through C026212Ah; `SendCommand` retires at C001184Ch / cycle 394,824,329,
with IOP C13BDE54h. RMM schedules callback C0FFC4BCh at 394,830,045 and returns
record C0FDA28Ch. VMM enters its semaphore wait at 394,832,519; its first
selector call is at 394,832,917. The predicate at 394,838,004 uses VM
C15200E8h, semaphore C10D9758h and IOP C13BDE54h. The queued RMM callback,
known virtual-IRQ mask setter and virtual-EOI entry points do not retire within
this complete window. That is an interval fact, not proof they never ran.

Independent passive, layered native readers qualify both the closed **393.8M**
input and **394.9M** terminal state against the current serializer and memory
layers. VM+1Eh is already 20h and virtual IRR/ISR are already 1 **before** the
capture. The semaphore already has count zero and signature 4553h. The current
RMM node changes from callback C0003ACEh / flags 80000000h to C0FFC4BCh /
IOP C13BDE54h / flags 131h, consistent with its observed reuse. The restriction's
origin is therefore outside the captured interval; no semaphore, private flag,
EOI or timer is forced. A suspected AL result mismatch is rejected by qualified
current code: C00031F2h contains **0C DF (OR AL,DFh)**, not NOT AL. AL 20h→FFh
is correct. Canonical endpoint code alone is not an actual fetched-byte witness.

Evidence below `ao486-sim/obj_dir_win95_ioperm_native_sep30.ePtDku/`:
`io-transition.{summary,events,commits}.tsv`, `python-delta-receipt.json`,
`current-virtual-context.json` and its independently pinned before-state
counterpart. The inspector source/binary hashes are respectively
`c84d9a2220053ac22290ac4a2e1d63bfda61c1a6c27bd98d2611a0c73f35be1c` /
`2e53c24c712fc4827ba7ddb83fb7f81f5a7772cf302d03edd60f63af2483d432`;
the Python analyzer is
`e5f041abe8262cfafde9bd526ac9bc89cd9456bc9e0a3dd905552c06f19096b7`.

The first qualified **current `cdcb` gameplay window** supersedes the older
baseline: clocks **1,399,999,637–1,499,999,637**, harness retirements
**407,258,224–450,008,441**, hence **0.42750217 IPC**. U contributes 31,851,286
and V 10,898,931 retirements, summing exactly to 42,750,217. Raw frames 6/7
advance from the shells corridor to the grenade-launcher/monster view with no
startup overlay or post-processing. Their SHA-256 values are
`eaca570d8ddfc97cc40b72fbded880fdf650a3934764c2fec0486e415fd35cc6` /
`503a664724c84e6bb525f5ca40e21c999ece5bb90ec45f06471580dafa3b26b9`.
Log: `ao486-sim/obj_dir_standard_v86_iop3_sep30.W6RkaF/quake/run.log`,
profile rows at cycles 1.4B and 1.5B. Its private executable retains full SHA-256
`cdcb6faa8599124f9e1c6b663d04cd23206a31a7a88bc325f49381fbb5479c56`.
These different-scene windows do not measure a fix gain. Cold Win95 is still
polling at approximately 1.45B; Quake has no fresh 969-frame completion yet.
**CoreMark correctness PASS; Win95 desktop and Quake timedemo incomplete.**

### Later current gameplay and passive checkpoint qualification

The latest verified **current `cdcb` gameplay** window is clocks
**1,799,999,637–1,899,999,637**, harness retirements
**578,364,995–623,538,067**: **0.45173072 IPC**. U contributes 33,960,715
and V 11,212,357, summing exactly to 45,173,072. Raw frames 10/11 advance
from close-monster combat to an explosion/firing corridor. Their SHA-256 values
are `b4172271f12eaf0dc49d40096281c99f518ca84913a337338275033c7e42deae` /
`2184e43859b1c7a966bd2f26a909f9536efd759c141616bdc3d5e4125d822fc3`.
The same private executable still hashes to `cdcb6faa…`; log rows are 5500/5773
in `obj_dir_standard_v86_iop3_sep30.W6RkaF/quake/run.log`. Across all five
contiguous clear windows **1.4B–1.9B**, 216,279,843 retirements / 500M clocks
give **0.432559686 IPC**. Neither scene-dependent measurement establishes a
fix gain, FPS or timedemo completion. Win95 remains polling without a desktop.

Two more passive current-native findings narrow the Win95 investigation:

- Both represented active nested execution frames are **INT 21h**, not an
  inferred INT 1Ch timer handler. The qualified saved kernel frames contain
  EAX=21h and actual returns C0232CF2h / C0259190h, with independently decoded
  VMM restore/POP/RET layout and Exec_Int callers. An earlier unrepresented
  hardware-interrupt ancestor is not ruled out. Receipt:
  `kernel-return-classification.json`, SHA-256
  `4bd02f754273f4fa6975e1d910e48a8eb86cb408370d5e780183f1d30103fba1`.
- A second strict full-trace parser sees **zero accepted U/V guest stores**
  to physical 172106h, 17312Ch or 17312Eh during the entire recorded million
  clocks (36,675 U / 133 V stores elsewhere). All nine apparent bank intents
  involve replacement fills for unrelated new line addresses, not target
  writes. Initial pending store queues also do not overlap those bytes.
  This establishes neither the preceding origin nor absence of all backend
  writes. Parser source SHA-256:
  `f38833e2c513138e3cf78ef66481dd79e4678727730b760a8ba883b8cb38602a`;
  qualification receipt `store-origin.qualification.json` in the same ePtDku
  diagnostic directory.

Commit **4be941d** preserves the existing connected mouse protocol/queue in
native **V4** snapshots; older versions remain explicitly separate. Five
bounded tests exercise the actual production save/load functions: 12 protocol
and queue round trips, disabled/presence mismatch, all scalar bounds, every
payload truncation and queue capacity. These host tests supplement the earlier
actual frozen-model pilot/full-capture noninterference proof; they are not
Win95 desktop acceptance or a CPU/peripheral workaround.

A new **optional host-only retired-PC checkpoint** is being qualified to
capture the earlier origin rather than guess another clock window. It observes
each real U/V DPI callback, retains 256 prior retirements and requests a native
save only at the existing settled loop checkpoint point. It adds no model eval,
guest state write or RTL breakpoint. The report labels post-commit CS/fetch
offset and any PS-polling cycle/retirement overshoot; it is not a pre-instruction
snapshot or an architectural `.vtrace`. Cold-only, strict callback continuity,
fresh output reservation and held-inode serialization fail closed. The held
`/proc/self/fd` writer prevents a replaced pathname from truncating a foreign
symlink/hardlink target.

The helper passes **19 host methods**, independently rerun by the parent;
**four more tests compile the actual production DPI callback** and verify U
matching, V matching, simultaneous fault/PC observers and disabled neutrality.
Production compilation retains its existing unused-variable warning waiver
for historical probes; the synthetic fixture remains strict. A private
**host-only relink** actually recompiles both host objects and links executable
`eddafd22fbcd1759398644772ff5e6898bd1017d6086531890adf2158a4bc082`, while
all **120 generated model/header/archive hashes remain unchanged**. Original
`cdcb` executable and host object remain unchanged. Actual native/disk
noninterference pilots now pass, and the scoped feature is committed as
**5481618**; this feature has **not** fixed or qualified Win95. The first
planned diagnostic trigger is ordinary retired
`0028:C002A7BC`; canonical bytes encode `OR WORD [EBX+ESI],2020h`, so its
captured dynamic EBX/ESI and coherent memory must identify the VM flag rather
than assuming a hardcoded operand address.

The native pilot ran six actual waited/reaped children in a 4 GiB / 64-task
scope. Disabled-observer restore reproduces the earlier **393.8M→393.901M**
endpoint exactly (101,000 clocks, not 1,000): native `3ac17bcf…` and closed
paired disk `0dbb5b8d…`. A short ordinary BIOS trigger F000:E061 at retirement
11 / clock 1,305 saves at clock **1,306**, with **one-clock / zero-retirement
overshoot**. Its native image is byte-identical to the original control saving
at that cycle (`0c68febfa5cb7e29c620fcf64f22cc1cc5f495cc31b01b1118a08a15078c3916`);
both paired disks retain source `cc68b005…`. The unreached target exits 2 with
only an empty reservation, and an existing sentinel is rejected before guest
start without modification. Receipt:
`pc-snapshot-native-pilot.1tza98n7/qualification.json`, SHA-256
`cb9bf4daab2baf4ed1ac4c156274f45e2fdc1b227d081faeba4f237453213963`.
The parent independently rechecks all 120 original and 120 relinked model
hashes after the pilot, plus the prior pilot's paired disk hash; all match.

Additional passive current-native code extraction qualifies 15 × 64 bytes
around the earlier VPICD path. A773h first updates virtual ISR via
`OR WORD [EDI+12h],CX`; A7B6h loads ESI=1Eh before A7BCh updates the VM flag.
This is a scheduled event callback, not automatically a hardware-IRQ handler.
At the trigger, the canonical balanced stack convention puts the original
callback return at ESP+8; native-save overshoot must be checked before using
that convention. Receipt `before-vpicd-trigger-code.json`, SHA-256
`25459d719ddc218b93be3d698f88cb111dbce227b45b5092af7c04e67d2325ec`.
