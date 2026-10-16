# Parallel write admission — native-qualified timing experiment

Status, 2026-10-16: **isolated RTL derivative implemented; native cache/AXI,
directed whole-core and private-reference functional checks pass. Canonical
`make verify` remains FAIL. Matched synthesis and its independent clock audit
are closed: **35.879588 MHz unplaced**, versus 35.374438 MHz for the matched
parent (**+1.428%**). Still below 40 MHz; no timing, standard-suite or FPGA
acceptance.**
The production RTL checkout has not changed. The frozen experimental derivative
is now deployed for the user-requested clock sweep; see the physical results below.

**User-directed next step (October 16): keep this RTL unchanged and measure
the physical overclock limit.** This supersedes the earlier no-route direction
below; it does not waive correctness or claim static timing closure. A single
guarded place/route/bitstream run began at 16:43:50 UTC from the completed
synthesis checkpoint, with no resynthesis or source/define changes. Both
2,000-iteration CoreMark seeds now pass physically at measured **40.000 MHz**;
the overclock boundary remains unmeasured.

## Physical results (October 16, 21:00 UTC)

Native implementation closes successfully in **7,136.58 seconds (1h59m)**,
with all **223,765 routable nets routed**, no routing/DRC errors, peak RAM
10,648,600,576 bytes, and no OOM. The original wrapper remains **FAIL** because
of its metadata pins. `fpga/audit_parallel_write_implementation.py` independently
checks all **73,282 input pins**, admits exactly the three explicitly explained
project/cache/report-index metadata changes, and verifies native output hashes.
Its receipt is `parallel-write-implementation-r1/independent-product-audit-r1.json`.
This does not erase the wrapper failure or qualify the outstanding CPU gates.

Core constraint is 40 MHz; AXI is 100 MHz. Routed setup WNS is **−9.841 ns**,
hold WHS **+0.004 ns**, equivalent same-clock path estimate **28.701817 MHz**.
The empirical experiment is explicitly user-authorized despite failed setup
timing; it is not static sign-off. Raw programmed image SHA-256:
`1d819e7cf898f35cd55a977f6ff0e892bc7a87d0a0e2149b7b08673f85c4a341`.
Routed DCP: `c932cefb2909e0934c83d105fc8aaebc3e51beb0c2b899b43738462eb54d76a5`.

| Physical trial | Measured MHz | Raw TSC ticks | Real seconds | CM/MHz | CRC result |
|---|---:|---:|---:|---:|---|
| 40 MHz performance seed | 39.999829 | 952,327,568 | 23.80829 | **2.100118** | All five match |
| 40 MHz validation seed | 39.999819 | 949,311,372 | 23.73289 | 2.106790 | All five match |

Each starts from a newly programmed image, checks the held-reset clock for five
seconds, cold boots the unmodified benchmark, and runs normally in UV+fast mode.
There is no STEP, breakpoint, saved state or guest patch during execution.
Conservative V-retirement witnesses are **207,890,452 / 207,688,222** respectively;
these are not U-only counters. Both retain exact ROM-glyph-decoded video,
raw TSC endpoints, 211 passive counter samples, unchanged media/helper pins,
terminal native owners, and verified guest-reset/posted-DDR drain after capture.
The controller's intentional daemon SIGTERM follows captured `PORT-END`; it is
not used as the benchmark's success marker. Independent host audit re-decodes
the actual frame and matches every retained trial file to the board original.
Receipts: `coremark-clock-board-r2/new40-{performance,validation}-audit-r1.json`.
Board staging: `/dev/shm/ventium-coremark-clock-stage.O8VozfHM`.

The first 70.175 MHz bitgen preparation was stopped deliberately with native
exit 143 before any clock edit, at 11,915,931,648 bytes RAM and **zero OOM
events**. A whole-design native ROUTE-property expansion was too expensive.
The next two attempts were also stopped before any clock edit: raw route dumps
repeated very large constant-net trees, even after hierarchical aliases were
canonicalized. Their closed partial evidence is losslessly compressed; no OOM
or full-disk event occurred. The final bounded audit uses batches of at most
4,096 cells / 128 nets, retains every hierarchical name, and streams exact route
values through deterministic gzip. All 24 Tcl mock cases pass, including native
property batch bounds. The separate observer stops at a 4 GiB disk floor or
11.5 GiB resident-memory margin.

Historical, superseded at the user's direction: at 21:07 UTC the active retry was
`ventium-core-clock-70-oct16-r4.service`, invocation
`5f6c9dce75e448ebb34e104c890c22f6`. Native clocks are **70.175439 MHz core /
100 MHz AXI**. MMCM property reports differ only in `CLKOUT0_DIVIDE_F`, 25→14.25.
Full before/after-edit physical snapshots compare byte-for-byte, SHA-256
`380e7bd1906bca7ea3908ee8f60bc85be42864222820ed8e1491c68a01d838c9`.
It was stopped with native exit **143** before final qualification and was never
deployed. The user requires **one 40 MHz image with a runtime-programmable PLL**,
not separate frequency images. The cancelled variants must not be deployed.
See `fpga/PROGRAMMABLE_CLOCK.md` for the replacement procedure and current state.
About 1 GiB of closed partial/duplicate physical dumps and cancelled variant
BIT/BIN/DCP products was removed; native logs, original routed DCP, one complete
before-edit physical snapshot and all accepted 40 MHz evidence are retained.

## Physical clock experiment preparation

`fpga/prepare_parallel_write_implementation.py` clones the 224-file completed
project byte-for-byte, preserving the original synthesis and clock-audit
evidence. Checkpoint SHA-256:
`db7f4cbfb804e8d93871cf8ccb8951d24de78d32aa8cc0d9bf2ccaf91b5bea03`.
Evidence: `parallel-write-implementation-r1` under the root below;
owner `ventium-parallel-write-implementation-oct16-r1.service`, invocation
`5520853d3c3d402995c4828400de51e0`. The successful prior bank64 controller's
single-family, 20 GiB RAM / 8 GiB swap and six-hour bounds are retained.
Disk admission remains 8 GiB; the live disk-stop floor is tightened to 4 GiB.
Three preparation tests and 84 existing Tcl launcher tests pass. This paragraph
records the original preparation; closure and deployment are documented above.

The **superseded** sweep kept PS/AXI at 100 MHz and the MMCM VCO at 1 GHz, varying
only the core-output divider in copies of the routed design. No DRP interface
was exposed. Post-route property editing and unchanged placement/routing must
be verified before using bitgen-only frequency variants. The existing PS PL0
runtime selector changes AXI and MMCM input together; it is not a core-only
frequency control. Start at 40 MHz, increase toward 70 MHz and beyond only
while checks pass, then refine/repeat the passing boundary and return to 40 MHz
after failures. No voltage change is planned. A highest observed repeated pass
is empirical CoreMark evidence, not STA or general-processor acceptance.

`fpga/prepare_coremark_clock_media.py` builds unchanged, BIOS-bootable
2,000-iteration media and same-count private-QEMU CRC references. The first
attempt (`coremark-clock-media-r1`) failed because QEMU rejects read-only IDE;
its failed logs remain. The second uses fresh private disks with before/after
hash equality. Both seeds finish with native exit 33 and matching standard
algorithm CRCs; final CRCs are **4983 performance / 0cac validation**.
Owner `ventium-coremark-clock-media-oct16-r2.service`, invocation
`b1e7427c4dd843d0a07313d2f89b97c6`, closes exit 0 / MainPID 0. QEMU ticks are
not FPGA performance. Require both hardware seeds, no errors, consistent raw
TSC endpoints, at least ten seconds using the **measured** core frequency,
fresh boot per trial, exact image/source identity, and unperturbed UV+fast
execution. The port's printed seconds remain calibrated to 40 MHz and cannot
validate duration at higher clocks. No workload/RTL patch or saved state is
used. Three host parser tests pass.

Additional sweep tooling (prepared, not silicon-qualified):

- `fpga/core_clock_variant.tcl` changes only `CLKOUT0_DIVIDE_F` in a completed
  40 MHz routed checkpoint. It requires unchanged 100 MHz AXI / 1 GHz VCO,
  native generated-clock agreement, legal routing and exact full-design
  cell-placement/net-route comparisons before and after bitgen. It preserves
  timing/DRC reports and does not weaken DRCs, add timing exceptions or rerun
  synthesis/place/route. **24 real-Tcl mock cases pass**; native MMCM editing
  has not yet run. Fractional divider steps follow
  [AMD UG572](https://docs.amd.com/r/en-US/ug572-ultrascale-clocking/MMCM-Attributes).
- `fpga/board-tools/ven_cold_clock.py --expected-mhz N` retains the original
  40 MHz default and adds an explicit bounded experimental target; nine host
  tests pass. It remains a held-reset clock observation, never a CPU pass.
- `ven_coremark_clock_trial.py` bounds a cold board trial, retains raw TSC
  console, passive video, U-only and total-U+V counters and native daemon
  identity, and holds reset after evidence collection. Three posted-drain
  helper tests pass. It never grades a stopped daemon as benchmark success.
- `fpga/decode_coremark_screen.py` checks capture CRC/extent and matches exact
  VGA ROM glyphs (including its 9-dot replacement table), with five host tests.
  Unknown glyphs are rejected, not repaired heuristically. The ordinary DDR
  B8000 aperture is not used as the live display. An old-image passive capture
  decodes exactly except the blinking cursor; it is not a CoreMark result.

Initial board preparation on boot `2861e4e8-cd4c-48cd-9f44-7f7d8a991ebb` rechecks the
two-cell DT tuple and non-reusable `no-map` 256 MiB reservation at 0x60000000;
unmasked root IOMEM excludes it from System RAM. Daemon/ROM hashes match the
documented posted-safe inputs. Staging is
`/dev/shm/ventium-coremark-clock-stage.o3iXxQgW`; host board evidence is
`coremark-clock-board-r1`. At that point installed firmware was **fe9f539d**,
not this candidate (subsequently replaced as documented above). A proposed
older-image 40 MHz harness control is **NOT RUN**:
quiesce observes zero at posted-DDR capability selector 79 and refuses before
programming or daemon launch. The old guest was held in reset by that attempt;
no clock change or CoreMark execution occurred. Do not relax the posted-drain
guard or count that older image as the new candidate. Use the matching new
posted-DDR image after implementation closes, first at 40 MHz.

Implementation audit note at 17:07 UTC: the native worker is still active in
post-placement timing optimization. The original launch controller pins two
additional copied **metadata** files byte-for-byte, so its closing stability
assertion is expected to reject Vivado's normal project relocation updates:
`cache/wt/project.wpc` increments the batch-open counter from two to three;
`runs/synth_1/gen_run.xml` rebases paths and changes report-index entries.
A read-only comparison resolves all **176 source paths and their attributes
identically**; the completed synthesis DCP and other cloned files remain
unchanged, except the expected `.xpr` project metadata. The live controller and
its original pins have not been edited. After native closure, retain its exact
verdict and independently audit these explicit metadata changes, route/DRC,
clock and output hashes before deployment; do not infer a native route failure
or a pass solely from that wrapper exit code.

This follows the rejected [qualified-credit experiment](QUALIFIED_PAIR_CREDIT.md):
35.295779 MHz synthesized/unplaced versus its RAW/input parent's 35.374438 MHz.
Neither result qualifies 40 MHz, and neither is routed fmax.

## Change and intended benefit

`prepare_parallel_write_admission.py` changes exactly two pinned RAW/input
files: `ven_axi_master.sv` and `ventium_l1_axi.sv`. The cache is byte-identical.
`PARALLEL_WRITE_ADMISSION` defaults off; the private wrapper enables it only
with dual-store pairing, without CDC or L2.

The old late request enters alias/extent and queue-admission logic before ACK.
The new branch computes single-store and paired-store admission **in parallel
from payload and existing state**, independently of `m_req`, `m_we` and
`m_pair_req`; the actual request then selects and gates the result. Two kept
combinational nets preserve that synthesis boundary. They are not registers,
extra credits, ACKs, architectural storage or false-path constraints.

Unlike qualified-credit, this does not assume a requested pair already has
credit. Held non-quad pairs still need two slots. Same-edge release, quad
combining, independent U/V address envelopes, strobe spill, BIOS shadow,
fatal containment and shutdown retain the original rules. Queue updates,
AXI packets, ordering, reset and read-response logic are unchanged. An active
nonsynthesis assertion compares enqueue against the full original equation.

No extra buffer, stall, latency or pairing restriction is introduced. This is
a measured **unplaced frequency-estimate improvement, not an IPC gain**.
The new worst path ends in FP status; the common fetch/length dependency and
several other failing endpoint classes remain, as quantified below.

## Native evidence

Root: `/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4`.
Receipts: `parallel-write-{leaf,cache,wrapper,corners,faults}-r1/closed.json`.

| Check | Observed result |
|---|---|
| Host recipe/scope tests | 8 pass: exact parent, default-off, untouched cache/state, independent predicates and wrapper scope |
| Native control enumeration | 16,384 combinations each with quad off/on; **zero exclusions** |
| Native extent vectors | 1,228,800 U/V address/strobe cases; six masks, offsets, boundary crossings and BIOS shadow |
| Negative controls | Six required failures: remove U alias, V alias, fatal, single credit, request or pair credit |
| Full L1/AXI A/B | 2,387 clocks / 4,781 half-edge checks; 68 U stores, 3 V stores, including one load/store pair and one quad enqueue |
| Backpressure and state | 30 blocked / 84 full-queue clocks; cache data/tag/valid/LRU, observed queue state, AXI packets and final 64 KiB RAM agree |
| Real wrapper A/B, each | U=65, V=2, quad=1, blocked=30, full=53, AXI-only reset/retry=1, denials=4, AW=100 |
| Same-edge corners A/B, each | Quad release, split release, SMRAM denial+release, bad BRESP+release and shutdown exercised; U=10, V=4, AW=11 |
| AXI regressions | 18 passes: parent/candidate ID, post-AR RID, orphan B, RRESP, BRESP, narrow replay, quad, quad error and held split pair |

The held split-pair candidate uses the **new branch**, not the generic-default
control used by qualified-credit. No internal ACK, cache or queue state is
forced. Equation enumeration uses Icarus's four-state engine with binary
stimulus; it is not exhaustive X-propagation or sequential formal proof.
Finite address vectors do not exhaust the 32-bit address space.

Native builds use all 158 nonsynthesis hardware definitions (only `SYNTHESIS`
removed from the 159-definition manifest), assertions and hard structural
warning errors. Tests add only explicit BFM/fault-injection definitions.
The shared guard serializes 32-job compilation; native simulator affinity is
observed at CPU 8. All five owners closed successfully; no CAD was launched.

`audit_parallel_write_admission.py` independently reconstructs fixtures and
checks hashes, exact cases and terminal owner identities. Receipt:
`parallel-write-native-audit-r1.json`, SHA-256
`28284dbe29e76fdc130140e752055719256d9a990cae64ccc40131671f8bb5fe`.
It confirms **32 native executions: 26 passes and six required-failing mutants**.
Two initial auditor drafts confused inner/outer invocation IDs and expected an
absent success-log phrase. The final auditor checks distinct IDs, bounded journal
timestamps, native completion and terminal outer exit. No native verdict changed.

| Owner suffix (`ventium-parallel-write-…-oct16-r1.service`) | Invocation | Stage seconds |
|---|---|---:|
| leaf | `1a667e2fc9f74322a1dcec9d54734fcc` | 6.736 |
| cache | `e7f1df58e68448cc9e42a12d75523fcc` | 6.000 |
| wrapper | `f0415d385ca34c7cb052f0b8b5c3511f` | 11.499 |
| corners | `2d17b211e68544799fe7dc24e99744b5` | 11.602 |
| faults | `27b873eabf0b48f7bd72abace62d1784` | 96.633 |

Candidate master SHA-256:
`3a910d67790368c28856bf9ec9e906da35fd2bf2955386bd2408d146f1cbb067`.
Candidate wrapper SHA-256:
`f1c73668e97cf3f80654fbd7365db6559dcc14c506c3b9e3bf3885e833795be5`.

### Additional all-address binary model check

[`prove_parallel_write_admission.py`](prove_parallel_write_admission.py) adds
a hand-encoded bit-vector model of old/new enqueue, ACK and paired ACK.
Both quad profiles return **UNSAT for any output difference**, with arbitrary
32-bit U/V addresses and address masks, independent four-bit strobes, all
two-bit queue counts and binary request/error/release controls. There is no
live-credit or reachable-address assumption. Enqueue non-vacuity is SAT in
both profiles.

Three intentionally broken address checks—omit write spill, broaden the BIOS
shadow by one byte, and omit V alias protection—each produce SAT witnesses in
both profiles. All **six witnesses** are then replayed through the actual
source-extracted expressions: the unchanged candidate agrees with the parent,
and the corresponding mutant disagrees. Thus **12 native witness checks**
pass. Complete parent/candidate files must reproduce the pinned two-file
recipe; the frozen synthesis input is not edited.

This is an **explicit mathematical-model proof plus native source witnesses**,
not a compiled-RTL formal proof, sequential cache proof or unrestricted X/Z
equivalence claim. The complete-cache, system and functional tests above remain
necessary. Four host tests cover unconstrained scope, source drift, mutant
construction and incomplete/duplicate counterexample rejection.

Owner `ventium-parallel-write-symbolic-oct16-r1.service`, invocation
`ef44df6f4846459baedf046f1482fd90`, closes exit 0 / MainPID 0 in **0.189 seconds**,
42,946,560-byte memory peak, no OOM. This small Z3/Icarus job uses inherited
CPU18–19 affinity and does not launch Vivado or Verilator. Evidence:
`parallel-write-symbolic-r1/closed.json`, SHA-256
`fe9db905a9a9713f21a8716c116b79e9efad19d13c659f5daca4783f69ae8a68`.

## Whole-core evidence

The guarded, 32-job build completed in **20.358 seconds**, after
[closed-cache cleanup](../../docs/SCRATCH_CACHE_RETENTION_2026-10-16.md)
recovered **4.56 GiB** and restored the **10 GiB admission reserve**. The
resource floor was not reduced. No Chrome process was running when checked;
none was killed. No Vivado job was launched for this experiment.

`build_parallel_write_core.py` preserves all **195 source files / 153 defines**
from the frozen RAW/input parent except the two specified memory files. The
private C++ harness has its own basename, local object and a dependency file
pointing to this model's generated root header; it does not reuse a foreign
model-dependent object. This is not a build of the dirty production checkout.

| Identity | SHA-256 |
|---|---|
| RAW/input parent executable | `41f99bcff8125a2caa7fe768f03f242bed1a43323e4d3a190109167248a34e9b` |
| Parallel-admission executable | `6cacb95c1f32fb83b87bb99b6ac7a9dec72a8b8a228035d1234f1cfd76f51b22` |
| Core audit receipt | `4924403b3528e8f88c790d1d29eaebf7cb3db824c02e074b27e9f061b079760f` |
| Private-reference functional audit receipt | `22575d565a5bfc975ce24a3242f4a4d4617bec464bda2e5353a33f6cd9f47751` |

Artifacts under the same evidence root: `parallel-write-core-r1`,
`parallel-write-system-r1`, `parallel-write-func-r1`, and
`parallel-write-core-audit-r1.json`. The functional audit is
`parallel-write-func-r1/audit.json`.

| Check | Result and limits |
|---|---|
| Cold system execution | **180 executions / 90 complete parent-candidate trace matches**, 24.628 seconds; AXI latencies 0/7/31, functional and cycle modes |
| System differential | Fresh pinned system-QEMU comparisons pass for all 15 fixtures; 47,886 candidate records, **5,349 V retirements** in cycle-mode runs |
| Private user-mode reference | **108/108 functional PASS**, 105.520 seconds; 80,800 complete records, **30,132 V retirements** |
| Fully unmasked private comparisons | 105 pass; `tx_regform`, `tx_regform2`, `tx_stack` still need their existing manifest-scoped x87 stack masks |
| Canonical `make verify` | **FAIL**, native make exit 2 / controller exit 1, 384.748 seconds; **7 functional PASS / 101 FAIL; 10 cycle PASS / 9 FAIL / 1 INFO** |
| Canonical cycle regression check | All **20 complete parsed cycle streams exactly match** the RAW/input parent; no changed clocks, pipe or pair fields |
| Host recipe/build tests | **10 pass** (eight recipe and two build checks); an initial invocation omitted the required parent-source environment variable and failed setup, then the correctly configured invocation passed |

The system fixtures are `pseg`, `ppage`, `pfault`, `pintr`, `pcpl`, `ptask`,
`pv86`, `pxc04`, `pxfrag`, `pxwalkd`, `pcgparam`, `pretfoutpg`, `piopermwrap`,
`pjmpgate`, and `pxfer`. They are directed cold tests, not Win95 or Quake.
Native execution uses UV + fast-pipe, `cycle_mode=1`, the actual AXI backend,
observed CPU affinity, and no STEP, snapshot, guest patch or pairing-disabled
control. All model/source pins remain unchanged and the system/private-reference
owners report no OOM events. The independent auditors recheck terminal owners,
native child exits, complete traces, private harness dependencies and input pins.

The private reference is the separately qualified executable `998b4f5d…`;
see [its qualification and limits](../qemu-trace/QUALIFIED_PROFILE.md). It does
not silently replace the default QEMU or turn the canonical failure into a
pass. Default-reference failures include missing terminal post-state and x87
status differences; the cycle bands remain unchanged. The same pass/fail
counts were previously observed on the qualified-credit model. This alone is
not a proof that every failed functional record is identical: separately
generated user-mode runs import different initial stack addresses from QEMU.
No trace normalization, comparison-mask change or timing-band relaxation was
used to establish the results above.

| Owner suffix (`ventium-parallel-write-…-oct16-r1.service`) | Invocation | Native terminal result |
|---|---|---|
| core | `1535db71879742e28860c8c54a2f2103` | exit 0 |
| system | `b969fac24eeb4fc6b7da63dc8be20bf3` | exit 0 |
| func | `6815d4757c9a4c6c91dd10af97ee7689` | exit 0 |
| verify | `0e7208d17c37412a86fd165d87e01e33` | exit 1; underlying make exit 2 |

## Identical-input replay and full-PC transfer

`parallel-write-replay-r1` closes in **47.444 seconds**: the parent executes
each candidate canonical image with that candidate's golden-established
initial ESP. **All 108 complete streams / 80,800 records match exactly.**
The replay has 32 bounded workers, retains native waits/reaping, and changes
neither records nor masks. Owner `ventium-parallel-write-replay-oct16-r1.service`,
invocation `58632488831146139af0771a1121e410`, closes exit 0 / MainPID 0.
This resolves the incomparable initial-stack inputs noted above; it does not
waive the canonical reference failures.

`parallel-write-soc-r1` copies the exact two-file change into the RAW/input PC,
preserving **102 common processor sources**, **157 full-PC definitions**, the
full P5 caches, posted-16 transport, retained 8042, keyboard retry and mouse
repairs. Its native 32-job build closes in **25.844 seconds**, private harness
object/header binding verified, with no new structural warning: the inherited
**98 full-PC warnings remain debt**, not clean lint. Executable SHA-256:
`b9b2ab1921b95418a161516a945e951184b367f3d627987b0e05ba0b248d5123`.
Build owner `ventium-parallel-write-soc-oct16-r1.service`, invocation
`e5f8d21f3326475e8afb75063c34f24f`, is closed exit 0 / MainPID 0.

Initial preparation correctly rejected the parent's old `verif/verify.sh`
hash after the documented reference-profile integration. Only that exact
historical hash (`7c65a13d…`) is now resolved to the preserved
`qualified-reference-profile-r1/prior-verify.sh`; its bytes and the current
script are both pinned. Old receipts are unchanged. Unknown hashes still
fail. `parallel_write_parent_evidence.py` also rechecks the pinned original
RAW source audit, all 192 payloads, its exact three-file composition and
**68,324 ancestry/source pins**. This is provenance, not an acceptance waiver.

| Full-PC integration control | Result |
|---|---|
| Cold keyboard, translated and raw modes | Both pass, normal wire timing and CPU I/O; actual V retirement; independent audit rechecks **71,403 pins** |
| CoreMark performance seed, 10 iterations | CRCs `e9f5/e714/1fd7/8e3a/fcaf`; **4,771,298 ticks**, exactly parent-identical |
| CoreMark validation seed, 10 iterations | CRCs `18f2/e3c1/0747/8d84/c64e`; **4,755,366 ticks**, exactly parent-identical |
| CoreMark independent audit | **71,440 pins**, native exits 0, all children reaped, no OOM; V retirements 1,055,307 / 1,054,254 |

The short CoreMark controls show **0% cycle-throughput change**, as intended
for a combinational timing cut. They are **not duration-valid scores** and do
not fulfill standard-suite performance/correctness acceptance. Keyboard tests
are cold transport probes, **not Win95 UI interaction**. Both control owners
close exit 0 / MainPID 0: `ventium-parallel-write-input-oct16-r1.service`
(`fe088ee4b80c4df797b8c733a5ee1929`) and
`ventium-parallel-write-cm10-oct16-r1.service`
(`fd468c82012043c69e2fca2145425e3e`). Evidence:
`parallel-write-input-r1/audit.json` and
`parallel-write-soc-r1/coremark-ui-disabled-r1/audit.json`.

## Sealed FPGA source and matched timing preparation

`parallel-write-fpga-r1` is an **UNQUALIFIED** export, not a bitstream or
hardware acceptance. Its manifest SHA-256 is
`e745cf4cffcf5143298293e021b678803204fa18dbd32328b2079c481743143f`:
**192 payloads, 170 common HDL sources and 159 hardware definitions**. Only
the intended master and wrapper differ from the RAW/input parent. The source
audit independently rechecks **72,935 pins**, including retained PC input
logic, exact changes, full cache geometry and no new definitions.

Strict CPU-hierarchy hardware lint closes in **3.729 seconds** without new
structural errors. This does not resolve the full-PC warning debt or establish
full-wrapper elaboration. Closed successful owners:

| Owner suffix (`ventium-parallel-write-…-oct16-r1.service`) | Invocation |
|---|---|
| freeze | `06cff0bd384e4f03b5de6134cdf0eea9` |
| source-audit | `49bdb6ce526e4cb08556cd3182a6685d` |
| lint | `31869f4d0a034b2d912e2dbd079acf42` |

`fpga/prepare_parallel_write_timing.py` prepares, but does not launch, the
matched controllers in `parallel-write-synthesis-r1` and
`parallel-write-clock-r1`. They preserve the parent's mapper, **40 MHz core /
100 MHz AXI** clocks and complete resource/termination checks. Synthesis has
8 GiB RAM / 6 GiB swap caps, a 13 GiB combined early stop, 4 GiB free-disk stop
floor, 2 GiB host-memory reserve and a 45-minute native cap. There is only one
guarded Vivado family. Admission also requires twice measured parent disk
growth above the disk stop floor; the existing thresholds are unchanged.

The full-PC/export/controller host tests total **14 PASS**. A test-setup
Path/string mismatch was corrected before that pass; it did not launch CAD.
All preparation evidence explicitly retains the failed canonical gate and
unmeasured gameplay status. No placement, routing or deployment is authorized
by these timing-only controllers.

### Measurement lifecycle

The synthesis controller starts **2026-10-16 16:05:03 UTC**, owner
`ventium-parallel-write-synth-oct16-r1.service`, invocation
`c4c6454beb5c45f0b4e816565c63cf7e`. Native CAD is admitted at **16:05:36 UTC**
to the sole `ventium-vivado.scope`, invocation
`f1c726e7f0544b01a381506c93c0d711`; the observed caps are 8/6 GiB and 48 tasks.
No Chrome process was present. Native closure is recorded below.

The [one-shot observer](../../fpga/run_parallel_write_timing_sequence.py), owner
`ventium-parallel-write-timing-chain-oct16-r1.service`, invocation
`aea3ac6347584238b664eae986cf0737`, watches only that synthesis invocation.
After successful native closure and the independent source/DCP audit, it may
run the already prepared read-only clock audit. It cannot retry synthesis,
place, route or deploy. Four additional host tests pass. The only observation
adaptation is recognizing this synthesis's systemd `Type=oneshot` phase
(`activating/start`); native PID, exact invocation and successful terminal exit
remain mandatory. The clock controller retains `Type=exec`.

The parent path still includes the interior fetch-size mux. The exact size
cofactor has **already been tested and rejected as a standalone timing
improvement**: see [the prior result](../fe_pipe/SFETCH_INTERIOR_COFACTOR.md).
It exposed a different prime/descriptor/LRU path and regressed unplaced
frequency. Do not repeat that experiment or infer that removing a source-level
dependency guarantees 40 MHz. Inspect this run's mapped path before choosing
any further change.

### Closed synthesis and matched clock audit

Synthesis closes native exit 0 in **1,102.922 seconds (18m 23s)**, with all
input pins unchanged. The independent audit rechecks **72,970 pins**, the two
intended source changes, 159 definitions and unchanged mapper/clocks. There
is no OOM, resource stop or controller failure; peak scope RAM/swap is
7,991,189,504 / 1,887,752,192 bytes. The original critical warning and 1,537
warnings are retained, not represented as clean full-SoC lint.

| Synthesized resource | RAW/input parent | Candidate | Change |
|---|---:|---:|---:|
| CLB LUTs | 187,185 | 187,252 | +67 (+0.036%) |
| Registers | 54,760 | 54,741 | −19 |
| BRAM tiles | 277.5 | 277.5 | 0 |
| DSPs | 47 | 47 | 0 |

Checkpoint SHA-256:
`db7f4cbfb804e8d93871cf8ccb8951d24de78d32aa8cc0d9bf2ccaf91b5bea03`.
Area alone does not establish timing improvement. The read-only clock owner
`ventium-parallel-write-clock-oct16-r1.service`, invocation
`dda9b7b2080449e08433e288ef668496`, starts at **16:24:09 UTC**, after the synthesis
audit passes. Its native scope invocation is
`055f12d6621b42e8aba274119bd7065d`; observed limits are 8 GiB RAM / 4 GiB swap /
48 tasks. It closes native exit 0 at **16:31:03 UTC**, in **404.738 seconds**.
The independent audit checks **73,018 input pins**, exact terminal ownership,
unchanged inputs, original 40/100 MHz constraints and the parent checkpoint.
Peak scope RAM is **4,586,319,872 bytes**, with no swap, OOM, resource stop or
controller failure. The sequencing owner also closes exit 0 / MainPID 0.
The native Vivado family is gone; no placement, routing or deployment starts.

| Timing metric | RAW/input parent | Parallel admission |
|---|---:|---:|
| Synthesized/unplaced frequency estimate | 35.374438 MHz | **35.879588 MHz** |
| Setup slack at 40 MHz | −3.269 ns | −2.871 ns |
| Worst-path logic levels | 94 | 101 |
| Worst endpoint | `int_err_reg[0]/CE` | FP `status_reg[8]/D` |

The frequency estimate improves **1.428%** while the limiting path changes;
the increased level count is therefore not a comparison of the same path.
The candidate's interrupt-error path improves to **−2.487 ns / 91 levels**.
Unplaced hold slack remains **−0.101 ns**. Both use the same diagnostic
`Default -no_timing_driven` mapper. These estimates are not routed sign-off,
board frequency, evidence of measured congestion or permission to overclock.
This is also **not a new best historical estimate**: the earlier boundary-stage
ancestor measured 36.968577 MHz before the RAW-storage removal. Do not present
this local gain as recovering that gap or satisfying the 40 MHz requirement.

Clock audit: `parallel-write-clock-r1/audit.json`, SHA-256
`7090d98b1112d377c679f1295c26c2a31ffe9e460a58ed7ba20878a9637740a2`.
Its 24 retained artifact hashes were separately rechecked after closure.
`parallel-write-sequence-closed.json` records successful terminal synthesis
and clock owners. The captured netlist contains both kept `single_admit` and
`pair_admit` nets; their presence alone is not a proof of their entire fan-in.

### Remaining critical path: shared frontend, not only FP

All **30 reported worst setup paths** still traverse `d_len[3]`. Endpoints
are three FP-status bits, 17 interrupt-error enables, eight EFLAGS enables and
two stack-pointer data bits. Therefore optimizing only the three FP endpoints
would still leave the observed **−2.487 ns** integer path (about **36.38 MHz**
under the same estimate), even if all other paths stayed unchanged.

The worst path's **27.660 ns** data delay partitions at these consecutive
native report markers; the values include estimated net delay:

| Consecutive markers on the same path | Delay | Share |
|---|---:|---:|
| Launch clock arrival → `d_len[3]` | 12.131 ns | 43.86% |
| `d_len[3]` → `fx_cross` | 4.768 ns | 17.24% |
| `fx_cross` → FP input payload marker `saved_mem_reg[19]_0` | 3.925 ns | 14.19% |
| That payload marker → FP status D pin | 6.836 ns | 24.71% |
| **Total** | **27.660 ns** | **100.00%** |

These are path-marker intervals, not independently measured module delays.
Logic is 6.173 ns; the remaining 21.487 ns is **unplaced estimated** routing.
The common frontend/fragment portion accounts for 61.10% of this path and
appears in every sampled endpoint class. A fix must address that shared
dependency without losing exact boundary fetch faults or UV-fast execution;
adding a blanket FP bubble would not address it.

Two seemingly obvious rewrites have already failed matched timing and must
not be rerun unchanged: the [interior-size cofactor](../fe_pipe/SFETCH_INTERIOR_COFACTOR.md)
exposes the prime/descriptor/LRU path, and the
[response-kind mux rewrite](RESPONSE_KIND_MUX.md) regresses to 34.616450 MHz
on its own parent. Neither is included here. A further composition needs a
specific mapped-path rationale and new native evidence; source-level algebra
alone is insufficient. No additional RTL or CAD run is introduced by this
post-closure analysis.

## All nine failed cycle kernels: complete clock accounting

While CAD runs, the unchanged [loop-budget analyzer](../fe_pipe/analyze_loop_cycle_budget.py)
regrades all nine failed kernels from this candidate's existing canonical run.
Each explicit loop-entry address was checked against its actual ELF. Complete
PC streams, all retirement records and all clocks remain in the comparison;
independent native FSM totals must match. Seven analyzer tests pass. No new
simulation, reference, band, mask or trace normalization is used.
Evidence: `parallel-write-all-nine-cycle-budget-oct16-r1.json`.

| Kernel | Total excess clocks | Before loop | First traversal | Repeated traversals | Final traversal + exit |
|---|---:|---:|---:|---:|---:|
| `mb_depadd` | 1,226 | 65 | 1,160 | 0 | 1 |
| `mb_indepadd` | 1,226 | 65 | 1,160 | 0 | 1 |
| `mb_faddchain` | 1,105 | 64 | 1,035 | 4 | 2 |
| `mb_dmiss` | 116,843 | 76 | 53 | 116,611 | 103 |
| `mb_imiss` | 122,615 | 65 | 24,522 | 73,566 | 24,462 |
| `mb_mul` | 536 | 65 | 1 | 398 | 72 |
| `mb_imul2` | 607 | 65 | 1 | 398 | 143 |
| `mb_rmimm` | 268 | 65 | 62 | 0 | 141 |
| `mb_nearbr` | 442 | 65 | 306 | 0 | 71 |

This distinguishes two persistent differences from cold-only costs:

- Every measured D-miss loop interval takes **67 clocks**; 2,045 corresponding
  golden intervals take 10. The I-miss loop's four complete traversal deltas
  are each **24,522 clocks**. The native harness applies `AXI_RLAT=7` before
  **every** R beat, while the legacy oracle charges eight clocks per line miss.
  These are different transport contracts, not evidence of a new admission
  regression. They still fail the unchanged gate; full-PC/board latency cannot
  be inferred from this stress backend.
- Both multiply kernels have **399 one-clock-longer loop intervals**, including
  398 warm intervals of **13 clocks versus 12**. `mb_mul` records 4,000 S_EXEC
  clocks for 400 multiplies plus 400 non-simple S_PIPE handoffs; actual paired
  issue remains present. This is consistent with an additional dispatch clock,
  not solely a cold-cache explanation. The execution hold explicitly requires
  ten EX clocks and excludes frontend work. Do not reduce that hold or change
  the oracle merely to pass a band: qualify any decode/EX overlap with its
  operand, event, exception and retirement ownership first.

The independent-add, dependent-add, near-branch and immediate-ALU repeated
intervals match the oracle exactly; the FP chain retains one extra four-clock
interval. These directed observations are not gameplay IPC and do not waive
any of the nine failures.

## Remaining gates

1. Resolve the outstanding differential/reference and cycle-band qualification
   issues without weakening comparisons. Passing directed A/B and the private
   reference does not make canonical `make verify` green.
2. Static 40 MHz closure remains unproved. Per the subsequent explicit user
   request, keep this design unchanged and perform the physical clock sweep
   described above instead of further structural optimization. Preserve the
   below-target timing evidence; empirical overclock success cannot replace it.
3. Complete CoreMark correctness and duration-valid scoring, full Quake timedemo
   and Win95 desktop/UI acceptance, including physical FPGA evidence on the
   exact candidate bitstream.

The candidate has no gameplay measurement. Latest verified **simulation** baseline:
**0.490014174 total U+V IPC**, binary
`b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e`,
cycles **1,100,065,247–3,100,065,247**; U=757,186,160, V=222,842,188;
U-only IPC is **0.378593080**. The wider two-billion-clock observation includes
all intermediate intervals; it does not indicate a source change from the
previous shorter-window 0.497040387 result. The independent observation audit
checks 18,622 source/runtime pins, live native identity/CPU14 affinity, actual
UV-fast configuration, complete counter consistency and raw-pixel equality.
Endpoint captures show distinct gameplay views with weapon/HUD, visually
reviewed by the agent. Evidence:
`v-result-carry-gameplay-window-1100-3100M-oct16-r1.json`. This is a post-hoc
observation, not a predeclared candidate/control experiment.
It predates this derivative and is not FPGA or full-timedemo acceptance.
