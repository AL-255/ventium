# Immediate paired-load completion cut — October 12

**Synthesis and independent audit closed: 29.953572 MHz, a regression from
30.676729 MHz. Directed checks, frozen CPU lint and short CoreMark preflights
pass; canonical remains FAIL. No gameplay, standard-suite or physical
acceptance.** The
immediate target remains **at least 40 MHz synthesized Fmax**, UV+fast mode and
full P5 caches. The measured parent is now **30.676729 MHz**, not a timing pass.

## Measured path and exact change

The [query-selector parent](PRIME_QUERY_PAYLOAD.md) has a 110-level worst path
from EIP/raw decode through next-read eligibility and paired-store readiness,
backing-write admission/ACK, then immediate V-load acceptance and GPR writeback.
Its cumulative data delays (launch-clock contribution removed) include:

| Point | Data delay |
| --- | ---: |
| `core_mem_next_req` | 23.148 ns |
| `core_store_pair_req` | 25.433 ns |
| Backing `m_ack` | 27.603 ns |
| `pipe_v_pair_now_accept` | 29.264 ns |
| GPR register D | 32.387 ns |

These are unplaced netlist estimates, not board measurements. The authoritative
report is `memdiv-query-clock-r1/core_setup_unplaced_estimate.rpt` under
`/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.

[`prepare_pair_now_read_ack.py`](../verif/l1/prepare_pair_now_read_ack.py)
changes **one identifier in one assignment**: the `mem_ack` used by
`pipe_v_pair_now_accept` becomes `mem_read_ack`. The existing read-only ACK
already includes final-fragment suppression, memory response ownership and
route/denial behavior; other profiles alias it to the original ACK. No request,
architectural ACK, feature define, register, pipeline cycle or permission check
changes. In particular, stores continue using their original completion path.

Simulation assertions retain the full original acceptance equation and require
bit-exact equality on every live edge. Whenever this consumer is eligible, they
also require `!mem_we` and exact read/general ACK equality. An opt-in
`+ven_pair_now_read_ack_witness` logs actual immediate V-load acceptance. Source
inspection and the existing global read-ACK invariant motivate the change;
whole-core behavioral checks must still establish the consumer's ownership.

## Preparation and build

Three [exact-source tests](../verif/l1/test_pair_now_read_ack.py) pass: exact
single-consumer scope, drift/reapplication rejection, and full equality/read
ownership assertions. These are not execution tests.

The [private builder](../verif/l1/build_pair_now_read_ack_core.py) preserves the
exact query-selector parent model
`e65a06e1e3c26d48723bdeb0d9d97061879f15b1ff916e493d4fe94ae336a525`.
All **195 payload files and 152 feature definitions** remain; only `core.sv`
changes. It reuses the unchanged guarded 32-job lifecycle, actual fd9 lock,
explicit compiler, no-live-Vivado check, and unique C++ basename/local generated
header dependency audit. No frozen FPGA export is edited.

Build owner `ventium-pair-now-read-core-oct12`, invocation
`e3aac9cbb6a647c982455467ae482ad7`, closes native zero in **20.71 seconds** with
stable pins. Strict structural classes remain errors. Model SHA-256:
`66cfd2e6365d0093d395e807e07bcd5148ae76a3701e64d5d1a58ae18e800750`.
Evidence is `pair-now-read-core-r1` under the root above.

## Whole-core verification

After Vivado and its timing audit close, the unchanged native runners launch
against the exact query-selector parent and this candidate:

| Run | CPU allocation | Owner invocation |
| --- | --- | --- |
| Canonical `make verify`, unchanged oracle/masks/bands | 0–3 | `194813653fe44352b4b3d97c5b54b8e8` |
| Held-read ownership, complete QEMU + A/B state/cycles | 4–11 | `d833b29187b74c188d1c37906a0ddced` |
| Paged memory/pairing, complete QEMU + A/B state/cycles | 12–15 | `31486c72a8fa47edb9ba582104eb6748` |
| Full FP operand matrix, complete x87 QEMU + A/B clocks | 16–31 | `04c520e779e74a2ea96f40680fdfebf6` |

Each run has explicit CPU affinity and bounded RAM/no-swap/runtime settings.
The held-read, memory and full FP matrices **pass** with complete QEMU state
and exact parent/candidate cycles. They contain respectively **9,200 / 31,392 /
208,128 candidate architectural records**, and **1,360 / 1,500 / 768 actual
V retirements**. Their outputs are `pair-now-read-{held,memory,fp}-r1`.

Canonical `make verify` closes native make exit 2 in **404.57 seconds**:
**7 PASS / 101 FAIL**, not a pass or waiver. All 20 full cycle streams match
the parent. The separate same-input replay closes **108 programs / 80,800
records** in **105.82 seconds**, invocation
`d6e53484782e40e5a90731f80ca12642`. It reproduces complete parent/candidate
state and the candidate's original traces, without ESP normalization.

### Coverage failure, diagnosis and actual immediate-path witness

The original different-line matrix, and a new same-line byte/dword matrix,
retire V loads but **do not exercise immediate completion**. Their explicit
witnesses fail, and remain retained as `pair-now-read-witness-r1` and `-r2`.
The same-line matrix itself passes 48 cases / **20,928 candidate records**;
that alone does not validate the changed consumer.

The [read-only C++ observer](../verif/l1/build_pair_now_observer.py) is compiled
against the exact existing model archive/headers, with a unique harness basename
and dependency audit. No RTL is rebuilt and no internal state is written.
Its [four full replays](../verif/l1/run_pair_now_observer.py) reproduce every
original architectural/cycle record (218 each, both latency and trace modes).
On all 16 pair requests the cache hits, but primary/shadow window validity is
zero. Registered paired-bank captures intentionally do not preserve a complete
line; repeating that pair never seeds the immediate-window path.

The [cold warm-window fixtures](../verif/l1/run_pair_now_warm_system.py) perform
an ordinary dependent load before each pair, naturally seeding a complete line
through the real interface. They do not force cache contents, use a saved state,
disable pairing/fast mode, or alter comparison rules. All **48 cases** pass:
byte/dword pairs and same-bank/split-line rejections, six instruction offsets,
flat/relocated paged clients and AXI latency 0/7; **25,536 candidate records /
768 V retirements**, **14.36 seconds**. Owner invocation:
`9496d875078648d697fa5fff9bfa524b`.

The separate [immediate-accept witness](../verif/l1/run_pair_now_read_witness.py)
then passes **16 native runs** of the offset-zero flat fixtures in both trace
modes and latencies: **15 immediate accepts in each positive run**, **120
observed events total**, and zero in all same-bank/split controls. The first
cold iteration is not counted as an immediate hit. Complete records remain
identical to the QEMU-checked matrix. Owner invocation:
`e691bda4d28d4ea5ac9aaefaea48999c`. Coverage is explicitly limited to those
witnessed fixtures; the full 48-case matrix supplies additional state/cycle
regression evidence, not additional counted immediate-path events.

Evidence directories: `pair-now-observer-r1`, `pair-now-observe-wide-r1`,
`pair-now-read-sameline-r1`, `pair-now-read-warm-r1/matrix`, and
`pair-now-read-witness-warm-r1`. No timing gain is inferred from these passes.

The full branch/priming and FP fault regressions close **PASS** as
`ventium-pair-now-read-branch-oct12` / `ventium-pair-now-read-faults-oct12`,
invocations `033d4ea1092a4d8db87e116220b55b4a` /
`35608ca9a3d6454185ee506128628dcc`. Branch testing covers all **640 fixtures /
353,920 candidate records**, with full QEMU state and exact A/B clocks/hints,
in **239.48 seconds**. The original FP fault matrix passes all **32 native runs /
23,585 candidate records**, including complete UV architectural comparisons.
Every source pin is rechecked before PC preparation.

All closed FP streams are independently re-compared in full before lossless
archiving to `closed-pair-now-fp-text.tar.gz`: 486,844,052 original bytes become
29,349,568 bytes, with all 11,916 members hash-verified. Restore with
`tar -xzf closed-pair-now-fp-text.tar.gz -C /home/yukidama/external/tmp`.
No failed run, source, model binary, receipt or input pin is removed.

PC/CoreMark transfer and strict frozen lint remain required before another
synthesis. The new
[PC transfer admission](build_pair_now_read_soc.py) checks the closed matrices,
source identities and real immediate-path witness; it does not waive canonical
failure or claim full-system compatibility.

## PC and hardware transfer

The PC build closes native zero in **22.64 seconds**, invocation
`bca8cb6577774ff194224b2733a69867`, with unchanged inputs and the unique
generated-header dependency checked. All **102 shared RTL inputs** match the
directed model; only `core.sv` differs from the query-selector parent. The
156 PC definitions, posted-16 transport and inherited **98 full-SoC structural
warnings** are unchanged. This is not clean full-SoC lint. PC model SHA-256:
`45dc4daf68980bba3ca36f9b8d2c6c4ec4464a07657f70669f00e085478893f5`.

The [hardware export](freeze_pair_now_read_rk_candidate.py) retains 190 payloads,
170 source-matched units and the same 158 hardware definitions, 40 MHz core /
100 MHz PL constraints and full P5 caches. Manifest SHA-256:
`b47ea1b537c4ea1fd763f81ee23c506b39838218a0969c0ed94baf82ab46eb6b`.
Strict CPU-hierarchy lint passes in **3.73 seconds**, invocation
`b94fd8585cef400fbf96884b7e16aee3`; all six structural classes remain errors.

Both original 10-iteration CoreMark preflight seeds close **PASS** under
`ventium-fp-exec-cm10-pair-now-read-oct12`, invocation
`df1b6dc082a6471ba377ea7557fcf9f9`, using the real posted-16 board AXI model.
Both have all five correct CRCs, exactly **4,767,218 / 4,753,406 ticks** and
**1,055,307 / 1,054,254 actual V retirements**, respectively. The independent
audit rechecks **2,697 source pins**, actual CPU-11 affinity/native commands,
native owner closure and zero OOM events. These are not duration-valid scores,
full standard-suite seeds or FPGA results; no IPC/CPI improvement is claimed.

The [synthesis preparation](prepare_pair_now_read_synthesis.py) passes two
scope/safety tests and generates the exact-parent experiment without launching
Vivado. Single-instance ownership, 8 GiB RAM / 6 GiB swap, 13 GiB combined early
stop, host reserves, 6 GiB initial disk admission and 4 GiB live disk stop remain
unchanged. Actual clocks and the mapper are unchanged. The independent audit
must reproduce the parent DCP's **30.676729 MHz / −7.598 ns** before reporting
the new result. The [timing queue](run_pair_now_read_timing.py) cannot start or
restart synthesis, route or deploy, and separately records whether 40 MHz was
actually reached.

For disk reserve, the complete memory/branch traces are re-compared and
losslessly retained in `closed-pair-now-memory-text.tar.gz` (551,005,896 to
52,395,432 bytes). The two closed parent timing-report sets are retained in
`pair-now-parent-timing-reports.tar.gz` (514,330,194 to 22,460,447 bytes), and
four closed-build PCH caches in `pair-now-build-pch.tar.gz` (376,608,812 to
62,137,366 bytes). Every archive member is hash-verified before removing its
unpacked copy; all live input pins, sources, binaries and checkpoints remain.
Restore any archive with `tar -xzf ARCHIVE -C /home/yukidama/external/tmp`;
historical timing-audit reruns require restoring their reports first.

The additional five terminal historical report sets in
`pair-now-extra-timing-reports.tar.gz` retain 895,802,007 bytes in a
39,697,775-byte hash-verified archive. This raises free external storage to
about **7.0 GiB**, satisfying both the 6 GiB minimum and twice historical
measured growth above the 4 GiB stop floor. The reserve was recovered without
loosening the admission checks or deleting models/media/checkpoints.

### Synthesis launch

The exact frozen candidate launches October 12 at **14:05:39 UTC** under
`ventium-pair-now-read-synth-oct12`, invocation
`78de398ad2dc40049b6abb74b2f3734e`. The single active Vivado family is confirmed
owned by scope invocation `8acb698dfc4d43c783dc9d191d2d8d50`, with 8 GiB RAM,
6 GiB swap and 48-task limits. Evidence: `pair-now-read-synthesis-r1`.

The independent audit queue adopts that exact owner as
`ventium-pair-now-read-timing-queue-oct12`, invocation
`33ed67c8cca54f5593b609e736078146`. It cannot restart synthesis and only starts
the read-only timing comparison after verified native synthesis closure.
Both owners have now closed successfully and their native processes are reaped.
Synthesis takes **2,006.13 seconds**, with no OOM or input drift; its audit
checks 3,088 input pins. The independent comparison takes **490.06 seconds**,
checks 3,101 pins and reproduces the exact parent's **30.676729 MHz / −7.598 ns**.
Candidate setup is **−8.385 ns**, hold **−0.101 ns**, giving an unplaced
post-synthesis estimate of **29.953572 MHz** (−2.36%). The audit's successful
exit means evidence collection succeeded, **not** that 40 MHz was met.

All 30 reported worst paths now run from EIP to shared-FPU bank clock enables:
**113 logic levels**, 33.088 ns data delay, of which 26.729 ns is estimated
routing. They traverse next-read lookup, code/read ACK qualification,
`c_rdata_hi_valid`, and `fp_load64_take`. This motivates checking redundant
ACK qualification and next-lookup dependencies on the wide saved response.
It does not demonstrate a benefit from this isolated paired-load change.
The best query-parent checkpoint remains retained for comparison.

Candidate utilization is **186,749 CLB LUTs / 54,773 registers / 277.5 BRAM /
47 DSPs**, versus 186,766 LUTs / 54,831 registers in the parent. Neither the
small area reduction nor passing directed tests offsets the timing regression.
Evidence: `pair-now-read-clock-r1/audit.json` and
`pair-now-read-timing-queue-r1/closed.json` under the root above. No route,
new bitstream or deployment has been performed.

The inherited canonical **7 PASS / 101 FAIL** remains an acceptance blocker,
not an expected-failure waiver. Full original standard-suite and physical FPGA
Win95/UI and FreeDOS Quake timedemo completion remain outstanding.

Gameplay baseline: **0.51030715 total U+V simulated retirement-event IPC**,
older `2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. This new candidate
has no gameplay measurement; its synthesis estimate remains below 40 MHz.
