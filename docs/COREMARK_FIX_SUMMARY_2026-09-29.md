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
was stock. The first corrupting transaction is **not yet captured**: the
256-event budget expired at cycle 383,628,987 on repeated code-buffer fills.
Absence of later store records cannot reject a ROM-write or other mutation
hypothesis. A mutation-only watch is the next bounded diagnostic, not a fix.

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

Current cold raw-P54 full-PC gameplay IPC is **0.44879934** over cycles
1,900,000,000–2,000,000,000 on binary
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

The latest fully captured 1.9B–2.0B window has clocks 1,899,999,637–1,999,999,637
and retirements 623,538,067–668,418,001. Its 44,879,934 retirements equal
33,930,910 U plus 10,949,024 V retirements, over 100,000,000 clocks, hence
**0.44879934 IPC**. Raw endpoint captures 11/12 show advancing gameplay without
the loading console. The frozen private binary remains `b7cfbec7…`; this is
another scene-dependent gameplay measurement, not timedemo completion or FPS.

Evidence: `/tmp/ventium-standard-sep30.qUCAcQ/` (full-PC inputs and logs),
`/tmp/ventium-coremark-matrix.kpjs_mph/` (long seeds),
`/tmp/ventium-pair-size-profile-fhvp3cac/` (pair-size regression), and
`/tmp/ventium-win95-qemu-control-ablmz2cv/` (noncausal control).
