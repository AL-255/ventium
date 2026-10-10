# Registered-state FP command payload: candidate export

This is **UNQUALIFIED**, not a deployed image. It changes only the selection of
eight command-payload fields in `core.sv`, using registered `S_PIPE` instead of
late command admission. Valid/ready logic, retirement, faults, async ownership,
memory payload, register count and pipeline stages are unchanged. Invalid-cycle
payload and ready values may differ; valid-command producer ownership is asserted.
The proposal is default-off: `VEN_FP_PIPE_PAYLOAD_SELECT`.

The measured motivation is the preceding 192-level EIP-to-SRT-enable path,
which crosses memory acknowledgement, direct-command admission and the FP
operand mux. This source change **has no measured FPGA timing gain yet**.
It is not a substitute for checking the next worst path.

## Source and directed checks

Private core `35c8cc6c546ef996deb34a692fe81c57311f14064adbee8062d1017ffd5a69b7`
is built in `external/tmp/ventium-fp-payload-core.gBHtaKyA`. The
[recipe](../verif/issue_uv/prepare_fp_payload_select.py) checks eight original
payload ports and eight producer-contract anchors before transforming a copy.
Whole-core preprocessing proves default-off identity (whitespace ignored only).
Ten host recipe/closure tests pass; their synthetic data are not RTL evidence.

The [cold paged microbench](../verif/issue_uv/run-fp-payload-ab.py) passes 384
fixtures with flat/relocated clients, all 32 line offsets, six FP/integer mixes
and AXI latencies 0/7: **1,536 full x87/system QEMU comparisons and 768 identical
whole-cycle A/B streams**, with matching early FP acceptance events and actual
V retirement. Native supervisor `d43a1c4d12ba4c809d501765d74bd67b`, 45.23 seconds,
32 workers, 1.049 GiB peak RAM, stable inputs. Initial smoke-run metadata/grader
errors remain failures; their corrected successors change no trace data/masks.

The unchanged `make verify` closes **FAIL**, native 2, supervisor
`c417b95eb1c14526a843b7d82f773fed`. Its 101 terminal-state discrepancies and
12 cycle-band failures remain. An independent audit checks all 3,458 build
pins and confirms all 20 full cycle-kernel record lists equal the parent.
This is not a green differential gate or full correctness acceptance.

Full-PC model `eda4fe87a0970fbe6cddc77845ec07a924b97a21084aa1e88dd4a16937e01cba`
builds native 0 in `external/tmp/ventium-fp-payload-soc.8uRK2vul`:
22.21 compiler seconds, matching private C++/generated-header ownership,
stable pins and the same 98 inherited platform structural warnings.
Only `rtl/core/core.sv` changes from `322bc855`; UV/system/relocated fast
loads/stores, full P5 L1s, 256 KiB L2 and posted-16 DDR remain.

Export `external/tmp/ventium-fp-payload-fpga40.JV5UdkRR` has manifest SHA
`678f8f3a748d039ebb702bf289df77a54917db0a29a85852a8817cb8f614d683`:
190 payloads, 150 hardware defines, 117 filelist units, 49 include edges.
All 170 non-wrapper native source payloads match the actual compilation;
the unchanged hardware wrapper's transport projection is checked.
**103 freezer tests and 39 real-Tcl profile tests pass**. Use canonical paths
for the freezer; its initial `~/external`-alias invocation was refused before
writing any export files. It did not weaken the no-unreviewed-symlink check.
Clock constraints remain **40 MHz core / 100 MHz PL**.

Strict frozen-hardware CPU lint closes native 0 in 3.69 seconds with all six
structural classes fatal and stable inputs; root
`ventium-fp-payload-hw-lint.IOpFXZL6`, supervisor
`6990c841d360463cb75a332bcabf5cb9`. This is not whole-platform lint.

Full synthesis starts **14:05:38 UTC** in
`ventium-fp-payload-full-synth.9YxkPGyj`, controller
`05e5e96dce0244b7bf516abf44ce33e4`, sole Vivado scope
`fc0eb0f6b2eb488ebdd9536852d90734`. Same `logic_only` mapper and clocks,
8 GiB RAM / 6 GiB swap, 30-minute native cap, 12 GiB starting disk reserve
and live host/disk reserve monitoring. It cannot launch placement, routing
or programming. Area/timing results are pending.

## Acceptance still required

Both short CoreMark seeds **pass**, independently audited under
`ventium-fp-payload-coremark-oct10`, invocation
`721ca14e57b24d419ef14222a5ab37d5`, CPU 5, 2 GiB/no swap, ten-minute cap per
native seed. Both retain exactly **4,767,218 / 4,753,406 ticks**, all original
CRCs, actual V retirement, native 0/EOF/actual reaping, 3,771 stable pins and
zero OOM. They take 106.47 / 106.72 host seconds. `coremark/audit.json` checks
the complete consoles and exact parent tick counts; these are **duration-invalid
diagnostics**, not qualified scores.
This candidate has no gameplay or qualified CoreMark score, no full Win95/
Quake closure, and no routed or physical result. Known x87 C1/value defects
are not repaired by selecting the same payload earlier.

Latest verified gameplay belongs to **`bfb867f7`**: **0.49706764** U+V
retirement-event IPC at clocks **2,400,065,237–2,500,065,237**, **0.4868801938**
over all thirteen consecutive 100M windows from 1,200,065,237. The 0.34569625
dip is retained. That older model qualifies at **2.101890118 / 2.107616105
CM/MHz**; neither result is inherited by this derivative. See the
[current target record](../docs/CACHE_BACKED_TARGETS_2026-10-10.md).

## Separate SRT operand-selector investigation

The native source also gates SRT's mode/A/B selection on `accept`, although
the engine samples those three fields only under `ST_IDLE && start`. The
separate default-off `VEN_SRT_PAYLOAD_SELECT`
[recipe](../fp_shared/tb/prepare_srt_payload_select.py) separates these operands
from the **unchanged** start predicates/priority. It preserves the live RC/PC
controls, `prem1`, arithmetic engines and response timing. TOP_TRANS cannot
accept an external command; its divide request still takes priority over the
FPTAN completion tail. No register/stage is added. This is **not in the export
or active synthesis above**, and has no measured timing benefit yet.

Five host source-contract tests pass. The actual-source selector microgate
`ventium-srt-payload-leaf.5M1l6lUR/run` passes **665,203 four-state comparisons**
(332,599 base / 332,604 stream), and all three required mutants fail: wrong
sqrt mode, wrong transcendental operand, dropped start. Ready/accept/start and
live RC/PC are compared always; mode/A/B are compared on every start, their
actual sampling boundary. Source/recipe pins stay stable, 13.36 seconds,
16,961,536-byte peak RAM, supervisor `8aa47078bb434100adf323ac47645422`.
This is selector equivalence, not full FPU/core correctness or a timing result.

The whole-FPU A/B runner is queued **behind synthesis's shared heavy-work lock**
under `ventium-srt-payload-top-oct10`. Once admitted it has a ten-minute total
cap and 32 bounded compiler jobs. It retains the existing architectural,
response, ownership and result comparisons on every cycle, with mode/A/B
checked at start. Direct/reverse divide, sqrt, FPREM/FPREM1, borrowed far-FPATAN
division and the FPTAN tail span all twelve supported RC/PC combinations.
Base/stream/stream-forwarding variants are planned; none is a pass yet.
