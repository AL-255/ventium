# Response-kind mux factoring — private timing candidate

The target remains **at least 40 MHz synthesized Fmax and routed sign-off**,
with UV + system/relocated fast pipes, full P5 caches, single-fill and posted-16.
This candidate has **no timing, gameplay, standard-suite or hardware result**.

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
Synthesis may refactor it again: only a matched native timing run can establish
whether the structural rewrite helps. No performance gain is claimed yet.

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
single family; they are not separate competing builds. Closure, independent
netlist/clock audit and any Fmax result are still pending.

Canonical reference/observer failures and the full standard suite remain open.
No current-board reprogramming is justified by these narrow results, and no
response-kind synthesis completion, routed frequency or hardware pass is
claimed yet.

Newest verified gameplay baseline: **0.48773445 total U+V IPC**, older
`c7b95b78` simulation, cycles **2,200,065,237–2,300,065,237**. It predates this
candidate and is not Doom, physical-FPGA performance or a whole-timedemo
average. This candidate is unmeasured. Frozen controller receipts retain the
0.50430455 baseline known at launch; their inputs were not edited during the run.
