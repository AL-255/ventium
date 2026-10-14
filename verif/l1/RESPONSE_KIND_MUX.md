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

Both unchanged ten-iteration CoreMark CRC controls are now running on CPU12:
`ventium-data-size-cm10-response-kind-oct14-r1.service`, invocation
`2aca270e97664ff587dcaa708c503e63`. Actual native child affinity is checked by
the owner. These are bounded cold controls, **not** duration-valid performance
scores or the complete correctness suite. Strict frozen CPU-hierarchy lint now
closes native 0 in **3.98 s** with all 158 hardware defines and all six hard
structural warning classes enabled. This is not full-SoC lint; the 98 inherited
platform warnings remain open.

Next: close/regrade the pending controls, run original cache/fetch/fault checks,
and measure synthesis/timing under the existing single-Vivado resource guards.
Canonical reference/observer failures and the full standard suite remain open;
no current-board reprogramming is justified by this leaf/core result.

Verified gameplay baseline: **0.50430455 total U+V IPC**, older `c7b95b78`
simulation, cycles **1,800,065,237–1,900,065,237**. It predates this candidate
and is not Doom or physical-FPGA performance. This candidate is unmeasured.
