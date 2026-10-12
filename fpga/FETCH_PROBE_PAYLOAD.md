# Early fetch-probe payload — October 12

**Private RTL candidate; no measured Fmax, gameplay or FPGA acceptance yet.**
The immediate requirement remains **at least 40 MHz post-synthesis Fmax** in
UV + fast-pipe mode with full P5 caches. The measured
[load-ACK parent](LOAD_READ_ACK_TIMING.md) reaches **30.02192 MHz**.

## Measured reason and exact change

The parent's worst 119-level path runs through `fetch_overlength_probe` at
16.840 ns, the shared current-address/DTLB network, L1 response selection and
FP conversion into SRT input normalization. Qualifying an otherwise inactive
probe payload puts the long instruction/event predicate ahead of that network.

The [source recipe](../verif/fetchguard/prepare_probe_payload.py) changes only
two S_DECODE payload assignments in `rtl/core/core.sv`:

- Select instruction-side access kind directly. This state has no data beat.
- Present the next page base and one-byte extent before the late probe guard.

The decoder's first-overrun endpoint is always 16..31 bytes from `flin`. If
its page differs, it must name the next page, including 32-bit address wrap.
**The original first-field crossing test still decides whether a probe exists.**
In particular, a later unused immediate crossing cannot authorize a probe when
the first overrun field stays on-page. All debugger/event, #NM and privilege
precedence and `fe_translatable` qualification are unchanged. No bus request,
state, feature flag, register, added cycle or arithmetic engine is introduced.

Inactive address/type/extent values intentionally differ. Runtime assertions
require exact active probe payload, valid endpoint range, no S_DECODE bus/data
owner, and no translation/miss/permission side effect when no probe is offered.
This is not an all-internal-signals equivalence claim.

Parent core source SHA-256:
`552ad08f48da2833f7d299c37c9f73455f5cd08eafdbbc1fa129ccc10906c985`.
Candidate:
`70cc3e386aaa7c359b09021cd6c3e38803bfd6ab93533ede73611a74f9694837`.
The recipe rejects drift/reapplication; three host tests verify exact scope and
unchanged fetch/extent predicates. Production checkout RTL is not overwritten.

## Closed component and core checks

Evidence root: `/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.

The [native extracted-payload test](../verif/fetchguard/run_probe_payload.py)
passes **278,528 checks**: every page offset and endpoint length 16..31 at four
page bases (including wrap), plus all 16,384 Boolean qualification combinations.
It observes 1,459 active probes, 379 wrapped probes, 16,365 suppressed crossings
and 277,069 intentionally different idle payloads. Those counts overlap and
are not processor instructions. Four independently compiled mutations fail
with an actual mismatch: wrong page, wrong extent, data classification and
saturating instead of wrapping the page address.

The Z3 page-arithmetic query has no counterexample over all 32-bit addresses
and endpoint lengths 16..31 when a crossing exists. Wrong-page and lost-wrap
queries have counterexamples. The endpoint range is tied to the decoder's
actual four assignments and their guards. This arithmetic proof is not a
whole-core temporal/translation proof or a synthesized timing result.

`probe-payload-leaf-r1` closes native zero in **2.50 seconds**, unit
`ventium-fetch-probe-payload-leaf-oct12`, invocation
`288c788ed58647989276175d922ce627`; stable pins, controller affinity CPU12.
Receipt SHA-256:
`b0cf3c64d69eb6d9dddd4d5ce2682502727d03681e08100bae3b1790e81a6f5f`.
The unchanged source-linked fetch-guard testbench also passes **1,596 checks**
with Icarus against the candidate predicates in `probe-fetchguard-r1`; native
log, source link, executable and hashes remain there. This is not a Verilator
structural-lint claim.

The [private core builder](../verif/fetchguard/build_probe_payload_core.py)
retains all 195 inputs, the same 152 definitions and all assertions; only
`core.sv` changes. It reuses the established guarded build/closure checks,
including the private host basename and model-local generated-header dependency.
Native compilation closes zero in **19.63 seconds**, unit
`ventium-fetch-probe-core-oct12`, invocation
`ef8e180876d1496196aca97303acbaa6`. Model SHA-256:
`9097e2ae0c56e26a66f7dabeb631820bdb196ebeda7da1c132a9ea10f7758265`.
The build uses 32 jobs in the existing 16 GiB/128-task scope, with no Vivado
family running. Its source/command pins remain unchanged.

The [whole-core boundary runner](../verif/fetchguard/run_probe_boundary_ab.py)
passes **all 22 original pfetchbound cases** at AXI latency 0 and 7. It retains
the original fixture validation, exact fault frames, unchanged IRET retries,
free-running QEMU exit, complete architectural comparison and complete A/B
cycle streams. **21,832 candidate records / 4,968 actual V retirements / 44
probe witnesses** pass; cycle counts are unchanged. No mask, instruction skip,
snapshot, exception substitution or narrowed oracle is used.

`probe-boundary-r1` closes native zero in **24.48 seconds**, unit
`ventium-fetch-probe-boundary-oct12`, invocation
`5977193e3dcd4871bfbf2e13de481c2b`. Its separate native service has 22 workers,
4 GiB/no swap and 2,048 tasks; sampled live model PIDs 2949598–2949619 have
actual CPU affinity 0–31. No compiler build overlaps this matrix.

## Broader regression status

The cold memory matrix passes **72 fixtures / 31,392 candidate records** in
28.12 seconds. The integer/store matrix passes **256 fixtures / 169,472
candidate records**, with 512 V retirements, in 64.62 seconds. Both use the
unchanged original QEMU oracle and full A/B cycle comparison at AXI latency
0/7. Evidence: `probe-memory-r1` and `probe-integer-r1`; invocations
`d95b844026d9489aa05dccb29171d9c6` and `621bc10c118942ff9348efbc4f6da0ba`.

The first 384-case FP matrix **FAILS**, not passes: three golden-generation
jobs cannot connect to QEMU's GDB stub at ports 47066/47080/47116 within the
existing 20-second limit. Those cases have no RTL comparison. QEMU's retained
stderr reports termination by the generator, not a demonstrated address-bind
error; the precise cause is not established. All test inputs remain pinned.
The [scheduling adapter](../verif/fetchguard/run_probe_core_corpus.py) assigns
distinct ports per case but those ports lie inside the host ephemeral range;
that fact alone does not prove it caused these failures. `probe-fp-r1` and its
failed owner `3a24df3a623c48c791f60b21e561e865` remain intact. A separate serial
six-fixture reproduction (`dcb47b9508be45f2aaf693d6b5b37a59`) also fails on
47066; the other five fixtures pass. A read-only socket check finds an existing
outbound IPv4 connection using local port 47066. A five-second controlled QEMU
startup on the same port exposes only an IPv6 `[::]:47066` listener, while the
collector connects to `127.0.0.1`. This explains the reproducible connection
failure; it does not prove the now-closed failures on the other two ports had
the same cause. The diagnostic exits by its explicit timeout (124), not guest
completion, and does not touch the unrelated outbound connection. Move future
case ports outside the host's 32768–60999 ephemeral range before a full rerun.

The unchanged canonical gate closes **FAIL**, native make exit 2 in **413.38
seconds**, under
`ventium-fetch-probe-verify-oct12`, invocation
`0231455e6780425e9fe9584c8d6bbaf8`: **7 PASS / 101 FAIL**. All 20 complete cycle
streams equal the parent, and input pins remain stable. The inherited failures remain
an acceptance blocker; successful A/B comparisons do not turn that gate green.

The corrected full FP rerun uses ports **24000–24383**, outside the host's
ephemeral range, with a runtime range check. All **384 fixtures / 208,128
candidate records / 768 V retirements** pass the original QEMU/state and exact
A/B cycle comparisons at latency 0/7. No test, expectation or timeout changes.
`probe-fp-r2` closes native zero in **65.54 seconds**, 32 workers, invocation
`972a1a7f188a4bf884019afaeb8688a0`. Receipt SHA-256:
`c44f6b2886b95d443c17a762ad66fad315c7d4dde61762e8099d4c75a6bce700`.
The failed R1 and serial reproduction remain failed historical runs; their
original scheduling adapter is preserved in commit `55fcdac5`. Neither an
unrelated connection nor the host networking configuration is modified.

The identical-input replay also passes **108 complete programs / 80,800
architectural records**, reproducing the candidate's original traces without
normalization or trimming. `probe-canonical-replay-r1` closes zero in **92.60
seconds**, invocation `ad9eaf3eb222462982ba743e209f4499`, receipt SHA-256:
`2aba342d03ee6e27c69b9d8897c4cfa025db0e4bbeb4ea7aa25f557555271b8a`.
Sampled live child affinity is CPU0–7. The held-read regression additionally
passes **24 fixtures at two latencies / 9,200 candidate records** in
`probe-held-r1`, invocation `b37a3524495847bba08d618715fadce2`.
The original **16-case FP fault matrix passes all 32 parent/candidate runs**,
including complete UV architectural comparisons and **23,585 candidate
records**. Its slow functional controls remain diagnostic, not acceptance.
`probe-faults-r1` closes native zero with stable pins, invocation
`7d3101ed3cc04f4bb4bf8eef178e7e06`; receipt SHA-256:
`71fee060de04c5c1ba086cae0a4891726801710df58ac5011061d6d7b7912d85`.
The six directed corpora above total **463,609 candidate architectural
records**, excluding the separately counted 80,800-record canonical replay.

The [PC transfer helper](build_fetch_probe_soc.py) closes its native build
successfully in **23.32 seconds**, with unchanged pins. It requires these
complete directed results, the fault matrix, the real
canonical closure and replay, unchanged profiles, and all 102 overlapping
RTL/header sources to match the directed core. The parent PC model is
`89ebdd625be3f65e97c1ddafee6e166084ed3978c27d96f5f96b6509144f0a09`.
The new PC model is
`b598f07768e3e04483a3c11dca8d97ff35acd134d2b3f94a54fb56d3e1f21b71`.
Owner `ventium-fetch-probe-soc-oct12`, invocation
`7af31eaf47384958b940f024e31d8f4f`, is closed and reaped. Its native build
preserves the guarded 32-job resource profile, 156 feature definitions,
posted depth 16 and private harness/generated-header audit. The **98 inherited
platform structural warnings remain unchanged**, not a clean SoC lint result.
Measured synthesis and full original standard-suite plus physical Win95/UI
and Quake timedemo acceptance remain open.

## Hardware export and timing admission

The [hardware exporter](freeze_fetch_probe_rk_candidate.py) freezes **190
payloads**, including **170 simulation-matched RTL/header files** and exactly
the parent's ordered **158 hardware definitions**. Only
`ventium/rtl/core/core.sv` changes. Clocks, wrappers, flow, posted depth 16 and
cache configuration remain unchanged; the separate mouse overlay is not added.
Manifest SHA-256:
`6e8db80a61959c273141140c77d7c7351d38b19616557c12e19b9d9dc40c0ee0`.
The Tcl source contract passes. Strict frozen-core lint closes native zero in
**3.78 seconds**, with stable pins; owner `ventium-fetch-probe-lint-oct12`,
invocation `de6a0512f1af496da4d7228957df88b7`. This is CPU-hierarchy lint,
not a claim that the inherited full-SoC warnings are fixed.

Both original cold **10-iteration CoreMark disks pass all five reference CRCs**
in 200.53 / 197.78 seconds. Their 4,767,218 / 4,753,406 ticks and
1,055,307 / 1,054,254 V retirements equal the parent: **0% cycle gain**.
These short checks are not duration-valid scores or the full standard seeds.
Owner `ventium-v-carry-cm10-fetch-probe-oct12`, invocation
`5e1187da97324b6a9ea967d8fc32dc36`, is closed and reaped. The existing runner's
historical `v-carry` name does not identify this candidate's RTL change; its
receipt pins the new `b598f077` model. Independent audit rechecks **4,450 input
pins**, actual CPU11 child affinity, complete CRCs, unmodified disks and no OOM.
Audit SHA-256:
`329ce7035634fc4ec6ca7ded46450d3c4d0a74b8b23225be37c5d31603636c95`.

The [timing preparation](prepare_fetch_probe_synthesis.py) passes two tests
of exact source identities, unchanged profiles and identical resource
monitor/stop/reap code. It preserves the existing **8 GiB RAM / 6 GiB swap**
caps, 13 GiB combined early stop, 2 GiB host RAM/swap floors and **4 GiB disk
stop floor**. Synthesis admission still needs more than 6 GiB free and twice
measured parent growth above that floor; no limit is relaxed. Its paired
[queue](run_fetch_probe_timing.py) can only adopt the exact requested synthesis
invocation, independently audit its native closure, then run the read-only
clock audit. Audit success and the **at-least-40-MHz requirement** are separate
fields. The actual Fmax remains unmeasured; no route or deployment is queued.

## Recoverable evidence compaction

Disk reserve is preserved without deleting sources, fixtures, native models or
pinned inputs. These archives live in the evidence root and are byte-verified
before their unpacked copies are removed:

- `failed-probe-fp-traces.tar.gz`: 3,429 terminal failed-run `.vtrace` files,
  **424,206,803 to 16,008,763 bytes**; SHA-256
  `af00e9b20a4a0fe19430b23becab5bb1f6ef74813039be9bd26e8ced6bc859ba`.
  Failed-run diagnostics remain unpacked.
- `closed-probe-corpora-text.tar.gz`: 22,104 closed FP/integer/memory text files,
  **764,658,404 to 54,603,307 bytes**; SHA-256
  `d2d8974cd3c066282f87df04278cc003402cb62875dc1fc34b0967701315cf4d`.
  Before archiving, an independent reread rechecks full QEMU comparisons,
  complete A/B state/cycle equality, native exits and pins for all 712 fixtures
  and **408,992 candidate records**. This excludes the separately counted
  boundary/held-read/canonical corpora.

Restore either with `tar -xzf ARCHIVE -C /home/yukidama/external/tmp`.
Member/hash manifests, protected-input lists and closure receipts remain beside
the archives. No active run's streams are removed.

For the next synthesis reserve, seven explicitly closed older clock-audit
folders have **105 report/TSV files** losslessly archived as
`old-clock-reports.tar.gz`: **1,871,831,675 to 82,182,379 bytes**, SHA-256
`a68ba01d6a1f1faba5b0c87479c482d0f93a851e796989e34e5617f5f1d24257`.
All members are byte-verified before unlinking, owners are checked closed, and
current/export/parent-timing pins remain intact. Historical audit reruns need
the same `tar -xzf ... -C /home/yukidama/external/tmp` restoration first.
Four unused, unpinned `.gch` compiler caches from this candidate's closed core
and PC builds are also removed (**376,165,725 bytes**); rebuilding regenerates
them. Models, source trees, generated headers and all current pins remain.
Together these recover about **2.02 GiB**; no input archive or checkpoint is
discarded.

Gameplay baseline: **0.51030715 total U+V simulated retirement-event IPC**,
older model `2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. This candidate
is gameplay-unmeasured; the baseline is not board IPC or a full-timedemo mean.
