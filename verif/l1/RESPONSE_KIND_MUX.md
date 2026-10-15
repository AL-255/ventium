# Response-kind mux factoring — rejected timing candidate

The target remains **at least 40 MHz synthesized Fmax and routed sign-off**,
with UV + system/relocated fast pipes, full P5 caches, single-fill and posted-16.
Synthesis and independent clock audit are closed: **34.616449737 MHz
synthesized/unplaced**, **5.40% slower** than the 36.591166892 MHz parent.
**Do not promote this rewrite.** The faster prefix-payload parent remains the
timing baseline. Neither meets 40 MHz; neither result is routed sign-off.
This derivative has **no gameplay, standard-suite or hardware result**.

## Measured motivation and exact change

The [prefix-payload parent](../fe_pipe/PREFIX_MEM_PAYLOAD.md) closes at
**36.591166892 MHz synthesized/unplaced**. Its worst path has 93 logic levels:
fetch alignment/decoding → fragment strobes → response ownership/shadow selection
→ U/V operands and flags → writeback/multiplier input. Other endpoints include
queued LOCK, EFLAGS and state enables. The unplaced net-delay estimate is not
proof of actual routed congestion.

[The one-file recipe](prepare_response_kind_mux.py) changes only private
`rtl/mem/ven_l1d.sv`, parent SHA-256
`62d3332d4d044efe022acce33eaa99b16e9a36da7a43e4afeda0b0265baeb3f3`.
It precomputes both code/data response-mux branches, then selects once using
the **unchanged** `code_payload_access`. Previously that late classification
fed owner equality, shadow/code select qualification and mux priority in series.

Both branches retain critical-word priority and their exact primary-owner class.
The data branch retains shadow tag/valid/bounds checks. Bypass still wins;
hit-stream still overrides. Narrow instruction reads still use the data-class
arm. Early address **and strobe** matching remain mandatory. No request, ACK,
cache state, permission, offset, latency, register or mode is changed.

This is exact two-state mux factoring, **not** an assumption that independent
cached copies agree. The old assignment remains as the fallback for profiles
without both existing payload flags; existing consumed-response assertions stay.
Synthesis can refactor it again. The matched native measurement below rejects
the optimization: exact functional factoring did not produce a timing gain.

## Closed leaf and build evidence

Scratch root: `/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X`.

- Six host recipe/adapter tests pass. They retain comparison policy, complete
  system fixtures, drift/reapplication rejection and no extra control authority.
- An unconstrained 32-bit SMT contract is **UNSAT** for old/new inequality;
  two intentionally wrong contracts are **SAT**. This is an abstract contract,
  not automatic sequential RTL formal verification.
- `response-kind-leaf-r2`: source-extracted RTL passes **262,144 vectors** with
  arbitrary disagreeing saved data, no ACK/reachability/coherence assumptions.
  Coverage: 131,072 stream, 32,768 bypass, 6,146 early, 5,206 code, 17,963 shadow
  and 68,989 primary selections; 114,143 raw-code/non-code-access cases.
  All four compiled RTL mutants fail on data mismatch: reversed kind, lost
  primary owner, lost early strobes, and lost stream override.
- Native leaf closure: **30.706 s**, owner
  `ventium-response-kind-leaf-oct14-r2.service`, invocation
  `6911175809284315b7b5e42982be588f`, exit 0, children reaped, actual CPU12
  observed, 35,708,928-byte peak, no swap. Closure SHA-256:
  `0fe4f4fbcad383c4017cf5cc003e08358c539e7b1939f847d0297d7db88b41f0`.
  Its extracted profile explicitly
  includes the optional stream override; the current full-core profile does not.
- R1 failed during extraction because that optional stream branch was not
  enabled. Its original failure receipt is retained; it ran no native miter.
- `response-kind-core-r1`: all **195 sources** audited, exactly one changed;
  all **152 definitions**, `--assert`, real L1 AXI backend configuration and
  `AXI_LINE_REPLAY=0` retained. Guarded 32-job build closed exit 0 in **20.224 s**,
  under 10 GiB RAM / 2 GiB swap caps. The unique host object was rebuilt against
  this model's generated header. Model SHA-256:
  `da6744ec11615ca7900a6ed132bc9e64471dd567e363d33985864e50719be6dd`.

## Closed processor regression and source-matched transfer

The unchanged private-oracle functional corpus closes natively in **118.34 s**:
108 cases, 105 without masks and three with their existing historical x87
stack masks (`tx_regform`, `tx_regform2`, `tx_stack`). The canonical `make verify`
closes **FAIL** in **405.38 s**, still **7 functional PASS / 101 FAIL**; its 20
cycle traces remain exactly parent-identical, while the old bands still fail.
No mask, golden, band or expected result was changed.

Same-input replay closes **174.03 s**, 108 cases / 216 native executions:
**80,800 complete architectural records**, cycle counts and **30,132 V
retirements** match the parent, with no A/B field masks. This is **0% sampled
cycle gain**, as intended for a combinational timing rewrite.

The five unchanged cold system/fault fixtures run both models at AXI delays
0/7/31: **30 native executions**, 30,141 candidate records and 5,487 V
retirements, complete in **27.31 s**. All full architectural/cycle comparisons
pass, including bounded/relocated accesses and precise store/SS fault controls.

The independent regression audit regrades all records, native gate owners and
**19,859 input pins**. Audit SHA-256:
`4648943aee67781f71aef0813a860aae478c0c2aad1b12fc4eea7f7a8c0075e7`.
The audit passing does **not** turn the canonical failure into acceptance.

The full-PC transfer now compiles in **24.71 s**, native exit 0. All **102 shared
core/PC sources** match; 156 simulation defines and the original transport are
unchanged. The unique host object uses the new model's own generated header.
The existing **98 platform structural warnings** remain unchanged, not waived.
Model SHA-256:
`cebca505c43333e40092fd5e2de78ab6adaa589fdaeb1d7e002c54860329f304`.

The FPGA freeze has **190 payloads / 170 matched HDL inputs / 158 hardware
defines**, unchanged 40 MHz core/100 MHz PL target and full caches/single-fill/
posted-16. Exactly one source changed. Its native Tcl source contract passes;
manifest SHA-256:
`a904bc49994af1079b1ae68b35e8aad00578e68eb7a3f9886f7515e60eaf4240`.
It remains **UNQUALIFIED** and has no DCP, routed result or bitstream.

Both unchanged ten-iteration CoreMark CRC controls now close successfully on CPU12:
`ventium-data-size-cm10-response-kind-oct14-r1.service`, invocation
`2aca270e97664ff587dcaa708c503e63`. Actual native child affinity is checked by
the owner; the independent audit rechecks 21,935 source pins and the original
media. Both standard CRC sets match. Performance/validation ticks are
**4,767,218 / 4,753,406**, exactly the parent's counts: **0% sampled cycle gain**.
Native durations are 215.12 / 218.98 s, all children reaped, no OOM. These are
bounded cold controls, **not** duration-valid performance scores or the complete
correctness suite. Strict frozen CPU-hierarchy lint now
closes native 0 in **3.98 s** with all 158 hardware defines and all six hard
structural warning classes enabled. This is not full-SoC lint; the 98 inherited
platform warnings remain open.

## Additional unchanged fault and fetch regressions

The original 22-case fetch corpus closes native 0 in **25.37 s**:
176 RTL executions, 88 complete QEMU comparisons, **21,832 candidate records,
4,968 V retirements and 44 probe witnesses**. Its independent audit checks
18,594 input pins and complete parent/candidate state and cycles. Per-child
affinity was not observed in this driver and is not claimed.

The 44-case x87 environment-store fault corpus closes native 0 in **12.27 s**
on the unchanged R2 retry: **88 full comparisons, 35,124 records and 4,580 V
retirements** at AXI delays 0/7, with actual child CPU13–16 affinity recorded.
The first attempt remains **FAIL**: QEMU's golden producer timed out connecting
to its GDB stub on `full0-env160-head1-present0-inject0`. All 88 RTL self-checks
passed even then, but that does not repair the missing golden. Its root cause
is unproved; no port collision is assumed. R1/R2 input pins and fixture bytes
are identical, and neither failed evidence nor comparisons were filtered.

The original 30-case prefix-boundary gate remains **FAIL**: eight finite-CS
QEMU free-runs exit 135 rather than 133, before RTL execution. The other 22
cases, including four previously repaired upstream-QEMU cross-page SMC cases,
complete **176 RTL executions / 88 full comparisons**, with 5,540 candidate
functional records and 428 V retirements in cycle mode. Full parent/candidate
state and cycles match. This is not a 30-case pass or a canonical-QEMU repair.

[`audit_response_kind_faults.py`](audit_response_kind_faults.py) independently
regrades these complete fault/boundary records and native terminal owners.
Audit SHA-256:
`5b93774bd78cfe4f0b0401be42f22a0600d5fb9d7a164878345a1e7eec8f97bd`.
The evidence audit passing does not waive either failed gate/run.

### Finite-CS RTL coverage that the reference gate never reached

[`run_finite_cs_rtl.py`](../fe_pipe/run_finite_cs_rtl.py) ran the original eight
finite-CS images directly, without assembling or editing them: relocated and
flat clients, offsets 4080/4093/4094/4095, AXI delay 0/7, parent and candidate,
both functional-state and cycle traces. **All 64 native executions exited
133**, in 3.42 seconds total, with actual CPU13–15 affinity and reaped children;
no OOM occurred. No guest patch, STEP, snapshot or U-only mode was used.

The first **host grade remains FAIL**, invocation
`f0fbabddb762423e8341001b7201ea27`: my checker incorrectly prohibited any
record at the faulting instruction's PC. The unchanged core deliberately
emits an exception-**delivery** record at that PC, with handler CS and the
pushed frame; it does not mean the truncated ADD executed. A second incorrect
assumption expected the `pair_v` label specifically in V. In these images,
alignment's preceding NOP pairs with the first MOV, and the second MOV pairs
with the following MOV AL. Both intended witnesses actually participate in
same-cycle U/V pairs. These are checker errors, not new RTL defects.

[`audit_finite_cs_rtl.py`](../fe_pipe/audit_finite_cs_rtl.py) preserves that
failed receipt and regrades the **complete unchanged records**, checking the
existing delivery contract: exactly one #GP(0) at HOT, unchanged GPR/control
state and arithmetic flags, CS 0x28→0x18, ESP 0x8fff0→0x8ffe0, then the actual
GP-handler entry. The guest also verifies error code, saved fault IP and no
partial EAX/EBX commit. Both MOV witnesses must have real same-cycle U/V
partners, not merely labels. Nine host tests include mutated fault, state,
frame and pairing failures. No trace row is removed, masked or rewritten.

The independent audit passes **64 self-check executions / 32 complete
parent-versus-candidate record comparisons**, with **2,032 candidate functional
records and 176 candidate V retirements**. State and clocks are identical to
the parent. This is explicitly **non-differential**: the original eight QEMU
failures and the overall boundary gate remain red. No standard-suite or
hardware acceptance follows.

Receipt: `response-kind-finite-cs-audit.json`, SHA-256
`b1885c85c9c2cd2779e21fce07ed0b07042e9e0f46e3a24e47ecbb5708b08ac5`.
The frozen R1 runner is retained to reproduce its failed host grade; use the
separate audit to inspect the contract-correct interpretation of those records.

## Guarded timing measurement

[`prepare_response_kind_synthesis.py`](../../fpga/prepare_response_kind_synthesis.py)
preserves the closed parent's entire native process lifecycle, memory/disk
admission, 40/100 MHz clocks and diagnostic synthesis mapper. Host tests reject
clock reduction and disk-floor relaxation. It also binds every proof above,
the exact one-file source delta, and the original failed outcomes.

R1 admission, owner `ventium-response-kind-synth-oct14-r1.service`, invocation
`cad6b0cfb13246cb8b3506180951844d`, closed native 1 **before launching Vivado**.
Although cleanup raised free space above 6 GiB, the unchanged stricter guard
requires **4 GiB plus twice 1,456,762,880 bytes** of measured prior disk growth.
The failed invocation is retained. The separately named R2 controller changes
only output/owner identities; source, tests, mapper and guards are unchanged.

The first exact compiler-product prune removed **612,588,120 bytes / 1,821
files**, preserving all 41,864 protected hashes. Only generated objects,
archives, precompiled headers and selected generated C++ were removed;
models, sources, guest media, dependency headers, logs and checkpoints remain.
These products are regenerable but not byte-for-byte backed up.

The second exact prune removed **924,001,693 bytes / 3,755 generated C++ and
object/archive files**, with all **64,368 protected hashes** unchanged. The
combined removal is 1,536,589,813 bytes; no retained model or evidence was lost.
Its separate plan and closure are `response-kind-generated-cpp-prune-*.json`
under the scratch root. Source and model-specific dependency headers remain;
rebuilding these closed models requires regenerating their removed C++/objects.

R2 passed the unchanged admission and started native synthesis at
**2026-10-14 06:48 UTC**. Controller
`ventium-response-kind-synth-oct14-r2.service`, invocation
`62ab5441fdc544f98e56744060bf8e41`; sole Vivado family scope invocation
`44ff1873708640deaecae1d877f135f6`. The actual scope enforces **8 GiB RAM /
6 GiB swap / 48 tasks**, with one synthesis worker, a 13 GiB combined early
stop, 2 GiB host RAM/swap floors and a 4 GiB disk floor. Synthesis has a
45-minute limit. The native parent and its synthesis child belong to this
single family; they are not separate competing builds.

Synthesis closed at **2026-10-14 07:20 UTC**, native 0 / MainPID 0, in
**1,917.94 seconds**, with no OOM or resource stop. Its independent audit
rechecks 32,536 input pins, 148 native Verilog inputs, all 158 hardware defines,
the exact one-file change, fixed clocks and matched mapper. Resources are
**186,272 LUTs (+227), 54,985 registers, 277.5 BRAM tiles and 47 DSPs**.
Peak scoped RAM was 8 GiB and peak swap 1,284,714,496 bytes. Synthesis reports
zero errors, one inherited critical warning and 1,564 warnings; these are not
waived. Synthesis-audit SHA-256:
`565294ebbb3c351da751990494e5687c84a96eb475246d478a63491a258e27f8`.

The separately guarded read-only clock audit closed under
`ventium-response-kind-clock-oct14-r2.service`, invocation
`8c79cd999f084b1caa9c251d7170f648`, at **2026-10-15 04:54 UTC**, native 0 /
MainPID 0, in **477.99 seconds**. Its independent closure checks 22,336 input
pins, actual core/PL clocks, original parent checkpoint, complete reports and
terminal ownership. Peak scoped RAM was 5,424,234,496 bytes and peak swap
237,752,320 bytes, with no OOM or resource stop. Structural checks report zero
black boxes, multiple drivers or combinational-loop errors; that does not
make timing or functional acceptance pass.

| Metric | Prefix-payload parent | Response-kind derivative |
| --- | ---: | ---: |
| Synthesized/unplaced frequency estimate | 36.591166892 MHz | **34.616449737 MHz** |
| Setup slack at 40 MHz | -2.329 ns | -3.888 ns |
| Hold slack (unplaced) | -0.101 ns | -0.101 ns |
| Worst setup logic levels | 93 | 96 |
| CLB LUTs | 186,045 | 186,272 |

The audit result is successful **measurement**, not a successful optimization:
frequency regresses **5.3967%**, with +227 LUTs and no register/BRAM/DSP saving.
The worst path now ends at `q_lock_reg/D`; it still begins at `q_pc_reg[0]`
and traverses the same frontend/length and fragment-control chain. Data delay
is 28.677 ns (5.705 ns logic, 22.972 ns estimated net delay). Do not interpret
the unplaced net estimate as measured route congestion. No placement, routing,
bitstream or board programming followed.

Checkpoint SHA-256:
`5b0d9f38c90de43e2df01c181e46f80022983049b60bdcf1f3901272f8801ba4`.
Clock-closure audit SHA-256:
`2868007692e5187439661aa4a98db0986d0c32873a40f313c1e3ae871463690c`.
All native limits, source/DCP checks, mapper and clocks were unchanged.

### What to optimize next

Resume from the **prefix-payload parent**, not this slower derivative. Its
first critical-path report partitions the 26.821 ns data path as follows:

| Consecutive report markers | Incremental path delay |
| --- | ---: |
| Launch clock arrival → `d_len[3]` | 12.112 ns (45.16%) |
| `d_len[3]` → fragment/class marker | 5.752 ns (21.45%) |
| Fragment/class marker → `l1_c_rdata[8]` | 1.778 ns (6.63%) |
| L1 payload → V input flags | 3.462 ns (12.91%) |
| V input flags → V ALU | 2.122 ns (7.91%) |
| V ALU → DSP input register | 1.595 ns (5.95%) |

These are partitions of **one reported path**, not independently measured
module delays. The endpoint is a DSP **input register**, not a path through
multiply arithmetic: adding a multiplier stage would not directly repair
this path. Even deleting the entire 1.778 ns local response interval while
holding everything else fixed gives only **39.14 MHz**. This is budget
arithmetic, not a bound on how synthesis might remap a different design.
The early fetch/length/segment dependencies deserve the next proof-driven
structural cut; preserve precise byte-span faults, owner classification and
same-cycle paired execution. Do not add a global bubble, slow-mode fallback,
false path or a lower clock constraint to claim 40 MHz.

Canonical reference/observer failures and the full standard suite remain open.
No current-board reprogramming is justified by these narrow results, and no
response-kind routed frequency or hardware pass is claimed.

Newest verified gameplay baseline: **0.50520554 total U+V IPC**, older
`c7b95b78` simulation, cycles **5,600,065,237–5,700,065,237**. It predates this
candidate and is not Doom, physical-FPGA performance or a whole-timedemo
average. The older cold run now completes demo1 in simulation: **969 frames,
125.4 guest seconds, 7.7 FPS at 40 MHz**; see the [closed audit](../../fpga/FP_REPAIR_EXPORT.md).
This candidate is unmeasured. Frozen controller receipts retain the historical
0.50430455 baseline; their inputs were not edited during either native run.
