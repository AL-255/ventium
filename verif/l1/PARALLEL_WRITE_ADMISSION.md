# Parallel write admission — native-qualified timing experiment

Status, 2026-10-16: **isolated RTL derivative implemented; native cache/AXI,
directed whole-core and private-reference functional checks pass. Canonical
`make verify` remains FAIL. No timing, standard-suite or FPGA acceptance.**
The production checkout and deployed bitstream have not changed.

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
a proposed **frequency improvement, not a measured IPC gain**. Whether the
kept cuts improve timing or expose another critical path is unmeasured.

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

## Remaining gates

1. Resolve the outstanding differential/reference and cycle-band qualification
   issues without weakening comparisons. Passing directed A/B and the private
   reference does not make canonical `make verify` green.
2. Measure matched synthesis timing and verify that the kept cuts remove late
   request controls from admission arithmetic. Do not infer fmax from source
   structure or route another below-target result.
3. Complete CoreMark correctness and duration-valid scoring, full Quake timedemo
   and Win95 desktop/UI acceptance, including physical FPGA evidence on the
   exact candidate bitstream.

The candidate has no gameplay measurement. Verified **simulation** baseline:
**0.497040387 total U+V IPC**, binary
`b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e`,
cycles **1,100,065,247–2,100,065,247**; U=384,240,079, V=112,800,308.
It predates this derivative and is not FPGA or full-timedemo acceptance.
