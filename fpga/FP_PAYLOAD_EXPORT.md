# Registered-state FP command payload: candidate export

This is **UNQUALIFIED**, not a deployed image. It changes only the selection of
eight command-payload fields in `core.sv`, using registered `S_PIPE` instead of
late command admission. Valid/ready logic, retirement, faults, async ownership,
memory payload, register count and pipeline stages are unchanged. Invalid-cycle
payload and ready values may differ; valid-command producer ownership is asserted.
The proposal is default-off: `VEN_FP_PIPE_PAYLOAD_SELECT`.

The measured motivation is the preceding 192-level EIP-to-SRT-enable path,
which crosses memory acknowledgement, direct-command admission and the FP
operand mux. The closed synthesis below shows a small **unplaced** timing gain,
not routed or physical sign-off. The next worst path remains unresolved.

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

Full synthesis starts **14:05:38 UTC** and closes **14:33:23 UTC** in
`ventium-fp-payload-full-synth.9YxkPGyj`, controller
`05e5e96dce0244b7bf516abf44ce33e4`, sole Vivado scope
`fc0eb0f6b2eb488ebdd9536852d90734`. Same `logic_only` mapper and clocks,
8 GiB RAM / 6 GiB swap, 30-minute native cap, 12 GiB starting disk reserve
and live host/disk reserve monitoring. Native exit 0, 1,664.95 seconds,
4,130 stable source pins and no OOM. Peak RAM is 8 GiB, swap 145.99 MiB.
The independent `audit_closed.py` confirms the actual 150 defines, 148 native
read-verilog entries, complete DCP and matched parent mapper. Utilization is
**196,673 LUTs / 54,630 FF / 277.5 BRAM tiles / 47 DSPs**: LUTs increase by
1,431 (**0.733%**) from the immediate 195,242-LUT parent. This is not an area
win. Zero synthesis errors, one generated PS clock-constraint critical warning
and 1,569 warnings are retained. The subsequent read-only native clock audit
must check actual 40/100 MHz clocks and the new worst paths before deciding
whether the timing gain justifies that LUT cost. It runs in
`ventium-fp-payload-clock-audit.8aaSGZzG` and closes native 0 at 14:38 UTC:
222.64 seconds including the serialized wait, 4,137 stable pins, 3.97 GiB peak
RAM, zero swap/OOM, controller `c8fb49f3a5ec49a3a10884908637a4c4`.
The actual clocks are **40 / 100 MHz**, with no black boxes or structural DRC
errors. Worst setup is **−27.741 ns**, or **18.960581 MHz unplaced estimate**;
hold is −0.101 ns. This is only a 3.97% estimated frequency improvement from
18.235863 MHz, not routed sign-off or physical frequency. The worst path is
still EIP-to-SRT-result-enable, now 184 logic levels / 52.444 ns data delay.
It goes through `l1d_c_ack` and **`fp_shared_load_cmd` → `fp_shared_cmd_mem`**
instead of the removed direct-command payload dependency. Thus early-load
payload selection still unnecessarily waits for late acceptance before
conversion/SRT operand preparation; this is the next source-level investigation.
Neither controller can launch placement, routing or programming.

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

Latest verified gameplay belongs to **`bfb867f7`**: **0.50507223** U+V
retirement-event IPC at clocks **2,900,065,237–3,000,065,237**, **0.4902082417**
over all eighteen consecutive 100M windows from 1,200,065,237. The 0.34569625
and new 0.47062856 dips are retained. That older model qualifies at **2.101890118 / 2.107616105
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

The first whole-FPU runner, `ventium-srt-payload-top-oct10`, fails before
compilation: Python's default descriptor closure hides the inherited heavy-work
lock from the guard. That failed admission is retained. The corrected runner
preserves only the actual fixed-lock descriptors across the guard and nested
compiler launcher; cgroup/limit/flock checks remain mandatory. Two host negative/
positive lock-descriptor tests pass, alongside the five recipe tests.

**Whole-FPU A/B passes** in `ventium-srt-payload-top.zUM2uaki/run-r2`,
supervisor `4f69b4b023da4a82b300df51d989f1ee`, native 0, 26.02 seconds,
stable pins, ten-minute total cap and 32 bounded compiler jobs. Base, stream
and stream-forwarding each pass **12 RC/PC cases / 396 checks**. The existing
architectural, response, ownership and result comparisons remain active every
cycle; mode/A/B are checked at start. Coverage includes direct/reverse divide,
sqrt, FPREM/FPREM1, borrowed far-FPATAN division and the FPTAN tail. This is
equivalence against the unchanged parent, not independent arithmetic correction.

The combined private core build closes native 0 in
`ventium-srt-payload-core.a6EbNrAu`, model
`de44f9382e46c25ecfb27a2bfc79c2f9c691dfce6630c82dea267d7aaf7a8c24`,
with stable pins and the correct private harness/generated-header pair.
Its only source delta from `35c8cc6c` is `fp_shared/ven_fp_top.sv`.
The 384-fixture matrix passes **1,536 full x87/system QEMU comparisons and
768 identical complete cycle streams**, in 42.51 seconds, supervisor
`824048c31b5e414f8dff5723dd7d23d9`. The first attempt exhausted its 128-task
host limit before completing; that failed run is retained. The successful
32-worker rerun uses 512 tasks, with unchanged fixtures and grader.
The unchanged canonical gate still closes native 2, supervisor
`d3dd017640e94a78896f081407b9d4fa`: 7/108 functional passes and 12/19 graded
cycle-band failures. All 20 complete cycle-kernel record lists equal the parent;
3,686 build pins remain stable. This does not turn the inherited red gate green.
Hardware timing is still required; this proposal has no performance score.
Five driver checks preserve the exact prior fixture/grader and change only
the expected SRT-vs-parent define delta.

## Early-load operand selector: combined candidate

The next default-off proposal, `VEN_FP_LOAD_PAYLOAD_SELECT`, removes late
`fp_shared_load_cmd` and `fp_load64_take` from the **payload mux only**.
Registered S_FLOAD/read/size/beat ownership selects the same 80-bit operand.
Actual admission still checks the complete translated response, wide-response
eligibility, faults, fragment ownership and debug conditions. Stores and other
states retain `f_mem80`; no registers, pipeline stages or latency are added.
The [recipe](../verif/issue_uv/prepare_fp_load_payload_select.py) checks nine
producer/consumer anchors and asserts equality with the original operand on
every valid command. Active/disabled whole-core preprocessing proves default-off
identity; the SRT proposal's default-off whole-module identity is also checked.

The source-extracted [leaf test](../verif/issue_uv/run_fp_load_payload_leaf.py)
passes **742,914 sampled comparisons** across narrow/wide configurations, including
1,026 valid wide captures. Both deliberate wrong-word mutants fail. It explores
qualification, debug, fragment, acknowledgement, size, beat and page-boundary
controls plus random data; two-state stimuli are not exhaustive four-state
verification. Root `ventium-fp-load-payload-leaf.u9R75tiy/run`, supervisor
`74d24a723dff4dba9df294475d2fdefc`, native 0, 2.65 seconds, stable pins.
Nine host recipe/grader checks pass; they are not RTL evidence.

Combined directed-core model **`e2156aa1`**, root
`ventium-fp-load-payload-core.WsBqyEli`, passes the original 384-fixture matrix
and 36 additional operand-boundary fixtures: **1,680 full x87/system QEMU
comparisons and 840 identical complete cycle streams**. Operand offsets
0/1/24 exercise wide capture; 25/29/4093 prove fallback, including a mapped
page crossing. Both flat and relocated clients, AXI latencies 0/7, and actual
V retirement remain checked. Main/boundary supervisors are respectively
`138573ac749440c7ad398b3fec55fd4b` / `31237674dd0340039165bd159ad6f8b8`;
both close native 0 with stable inputs and all children reaped. No trace
trimming, masks or golden changes. The new canonical generic gate closes
**FAIL**, native 2, supervisor `ad0b7fa6f486457ba6af845c6adef968`, with the
same inherited functional/cycle-band failures. An independent audit rechecks
3,905 pins and all 20 complete cycle-kernel record lists against the SRT parent;
all lists are identical. No failures were waived.

Full-PC model **`107d07501457191bbaed205a30285fa9e77c45020fd4332f0fcbae3a34aa3b9d`**
builds native 0 in 20.96 seconds under `ventium-fp-load-payload-soc.RCNiEqzo`.
Only `rtl/core/core.sv` and `fp_shared/ven_fp_top.sv` change from `eda4fe87`;
the full fast-path/cache/DDR profile remains. The same 98 inherited platform
structural warnings remain. Its own two short CoreMark seeds independently
pass at **4,767,218 / 4,753,406 ticks**, all original CRCs and actual V
retirement, native 0/EOF/reaping, 4,213 stable pins and no OOM. Supervisor
`d13075441ce64e748705b6637fdc255b`; host times 99.86 / 98.81 seconds.
These ten-iteration diagnostics are **duration-invalid**, not qualified scores.
This combined candidate has **no gameplay measurement, full standard-suite
closure or physical deployment**. Its A/B equivalence does
not repair inherited arithmetic or generic-gate defects.

### Exact-source hardware export and synthesis admission

Export `ventium-fp-operand-payload-fpga40.atMUjNrL`, manifest
`ce0738ca6a8bb80071a6f4cb5eafc6a125618c5538bcb146f21459213d0625a4`,
contains 190 payloads, **152 hardware defines**, 117 filelist units and 49
include edges. All 170 non-wrapper native payloads match the actual compiler
inputs. Only the two processor sources above differ from the prior export;
the 40 MHz core / 100 MHz PL constraints and hardware transport are unchanged.
The new freezer requires the complete ordered two-flag extension; partial,
reordered or substituted bundles fail. **109 host freezer tests and 45 real-Tcl
profile checks pass**. The first attempt correctly refused an unlisted boundary
test-driver path alias before publication; the exact script/target was checked
and added explicitly. Arbitrary source aliases remain forbidden.

Strict CPU-hierarchy lint closes native 0 in **2.49 seconds**, all six
structural classes fatal and stable inputs, supervisor
`b7a1588b626d417385911bedf49a012d`. This is not whole-platform lint.
The synthesis-only run closes native 0 under
`ventium-fp-operand-payload-full-synth.LL7cOdfp`, controller
`a685ae8834594de39a333a3272bfbcba`, at 15:21:43 UTC after **1,138.93 seconds**.
It retains the same mapper,
8 GiB RAM / 6 GiB swap, 30-minute native cap, 12 GiB starting disk reserve,
live reserve monitoring and exclusive Vivado family. It cannot launch
placement, routing or programming. The independent closure audit verifies
**4,573 stable input pins, all 152 actual defines, 148 native source entries**
and the complete DCP. Utilization is **194,057 LUTs / 54,591 FF / 277.5 BRAM
tiles / 47 DSPs**, down **2,616 LUTs (1.330%)** and 39 FF from the immediate
parent. Peak RAM is 8 GiB, swap 882.68 MiB, with no OOM or resource-stop event.
Zero synthesis errors, one generated PS clock-constraint critical warning and
1,567 warnings remain. The serialized read-only clock audit is running in
`ventium-fp-operand-payload-clock-audit.GjsMDYaL`, controller
`008dc230347b44dd921e84693b59025f`. It closes native 0 in **132.01 seconds**,
4,579 stable pins, 3.94 GiB peak RAM and zero swap/OOM. The independent audit
confirms actual **40/100 MHz clocks**, zero black boxes/structural DRC errors,
and **19.837334 MHz unplaced estimate** (setup −25.410 ns, hold −0.101 ns).
This is 4.622% above the immediate parent's estimate, still not 40 MHz routed
sign-off. The worst path remains EIP-to-SRT-enable: **179 levels / 50.113 ns**.
It now crosses `l1d_c_rdata_hi_valid` into the high-word payload rather than
the earlier command mux. `ventium_l1_axi` zeros that high word using its late
valid predicate, reintroducing ACK before FP conversion despite the core's
earlier payload selection. No place/route/bitstream or board programming ran.

The previous native path also exposes an earlier serial dependency: returned
instruction bytes → U/V length/pair decision → successor PC/descriptor → AGU
and TLB → `mc_prepare_ok` → `mem_next_addr` → L1 tag lookup → paired-store
readiness/AXI alias check → current ACK. The FP tail is not the entire path.
In `core_mem_chain.svh`, the next-read **payload** selector consumes the late
`mc_prime_offer`, although that predicate also qualifies the separate request.
A possible next investigation is selecting that payload from registered owner
state while leaving every permission/request/commit check intact. This is
**not implemented or assumed safe**: invalid-cycle address changes can affect
shared-port arbitration, and all valid requests, paired-store interactions,
faults and complete cycle streams must be checked. Wait for this candidate's
new worst-path report before advancing another timing change; do not disable
priming, pairing or fast mode to hide this cone.

## Wide-response transport: next private candidate

The new worst path identifies a more direct dependency before changing the
shared cache port: `core_rdata_hi = core_rdata_hi_valid ? data : 0` puts ACK
in front of the high-word data path. Default-off `VEN_FP_LOAD64_PAYLOAD_SELECT`
removes only that invalid-cycle blanking. Raw reset and SMRAM/route-denial
blanking remain, and the entire high-valid/request/permission expression is
unchanged. Both core consumers still sample only a checked complete operand.
No extra register, cycle, cache entry or RAM port is added.

The [source recipe](../verif/l1/prepare_fp_high_payload.py) asserts valid-response
payload ownership. Its [four-state leaf](../verif/l1/run_fp_high_payload.py)
passes **45,076 checks**, including every two-state qualification combination,
44 valid-word checks, 39,434 reset/denial checks and unknown/high-impedance
payloads. Wrong valid data and denied-data exposure each fail as required.
Root `ventium-fp-high-payload-leaf.XNepLPMd/run`, supervisor
`ce8f833a52594c65974f19badeaca41c`, native 0, 0.18 seconds, stable pins.
Ten host recipe/grader tests pass; these are not processor tests.

Private directed core `db83a397`, root `ventium-fp-high-payload-core.WO4FljgA`,
builds native 0 in 15.75 seconds. Default-off preprocessing preserves the
entire L1/AXI interface. Its own 384-case matrix plus 36 operand-boundary
fixtures pass **1,680 full x87/system QEMU comparisons and 840 identical
complete cycle streams**, with actual V retirement and unchanged wide/fallback
counts. Supervisors `c92823e7a89c48a28b9b3511e76b2396` and
`1591687c89474324aee039c8036ad6e9`; native 0, 42.33 / 11.86 seconds, stable
inputs and reaped children. The unchanged canonical gate closes **FAIL**,
native 2, supervisor `5f86edba36a046559f042d9d6188a806`, retaining its inherited
functional/cycle-band failures. Its independent audit rechecks **4,115 input
pins** and confirms all **20 complete cycle-kernel record lists** equal the
parent. Directed A/B equality does not waive these failures.

Full-PC model `03921cdaad0ffe8a58983f876f0e210a3f67d56c82fdc68c7b7e6e8f4083913d`,
root `ventium-fp-high-payload-soc.QNszcvUZ`, builds native 0 in 20.32 seconds
with stable pins and its own generated-header/harness pair. Only
`rtl/mem/ventium_l1_axi.sv` changes from `107d0750`; all performance/cache
features and the 98 inherited platform structural warnings remain. Its own two
short CoreMark diagnostics now independently pass at exactly **4,767,218 /
4,753,406 ticks**, unchanged original CRCs and actual V retirement, native
0/EOF/reaping, **4,424 stable pins** and no OOM. Supervisor
`9f903f889731415eb7ba3b9b766ead04`; these ten-iteration diagnostics are not
duration-qualified scores. This proposal has **no gameplay, qualified CoreMark,
full-suite or physical result** yet. Synthesis closes below; timing is still open.

Export `ventium-fp-high-payload-fpga40.RLIEUvhB`, manifest
`9e7b6b786752dad0c21f025d4deda2dcc197430275be4bee1205719aa540dea9`,
contains 190 payloads and **153 hardware defines**. All 170 non-wrapper native
source payloads match; only the interface source changes from the previous
export. **115 freezer tests and 49 real-Tcl profile checks pass**, retaining
the exact prior profile and forbidding partial/substituted bundles. The first
independent auditor expected both old/new boundary-driver aliases; actual pins
contain only the new runner. Inspection confirmed the old runner is ancestry,
not a new build input; the exact expected alias set was corrected, not broadened.
The first hardware-lint attempt timed out at 240 seconds while waiting for
the shared build lock, without running lint. That failure remains under
`ventium-fp-high-payload-hw-lint.FeKIS6Hd`. R2 acquires the same guard before
starting the unchanged 240-second native cap. It closes native 0 in **2.39
seconds** with all 153 defines, all six structural error classes fatal and
stable inputs: `ventium-fp-high-payload-hw-lint-r2.fWKUtiUU`, supervisor
`7d3a7784aecc487e84fbebcdb9bd5e43`. This is not whole-platform lint.

One new synthesis-only run starts at **15:38 UTC** in
`ventium-fp-high-payload-full-synth.84VF0WGn`, controller
`9376eccefc6d4500a830de70f86b9b4a`. The exclusive Vivado family retains
8 GiB RAM / 6 GiB swap, a 30-minute native cap, 12 GiB starting disk reserve
and live reserve checks. A pinned waiter requests only the independent
read-only clock/DCP audit after successful native closure; no placement,
routing or board operation is authorized by these controllers. This candidate
was awaiting synthesis at launch. Old closed compiler intermediates were archived,
compared and hash-checked before removal; all sources, executables, private
harness objects and evidence remain. Those four recoverable archives reclaimed
703,103,000 bytes without lowering the disk reserve.

At **15:57:47 UTC**, this synthesis closes native 0 in **1,176.18 seconds**.
The independent source/DCP audit verifies all **4,784 pins**, 153 actual defines,
148 native Verilog inputs and the unchanged `logic_only` mapper. Utilization
is **194,062 LUTs / 54,591 registers / 277.5 BRAM tiles / 47 DSPs**, versus
194,057 / 54,591 / 277.5 / 47 in the immediate parent. The five-LUT increase
is retained; this is not an area saving. Zero errors, one inherited generated
PS-clock critical warning and 1,567 warnings remain. No OOM or resource stop;
peak family RAM 8,468,733,952 bytes, swap 1,617,715,200 bytes.
DCP SHA256: `a3680a2b0ef931b067ade3ea7e7a2c525d2e4da6bcda4f9904cf5eb4cf9f2f11`.

The sole read-only timing controller is
`ventium-fp-high-payload-clock-audit-oct10.service`, invocation
`e56889b573c747ba89c7292ae829a749`, root
`ventium-fp-high-payload-clock-audit.u2dXxOpG`. It reads the actual clocks and
compares parent/candidate primitive maps; no placement or route is requested.
The queued [numeric FSQRT backport](../fp_shared/tb/SRT_ROUND_FLOOR.md) owns its
independent closure auditor before building a separate processor derivative;
do not run that auditor concurrently or mutate these frozen sources.

It closes at **16:00:05 UTC**, native 0, **132.14 seconds**, 4,790 stable input
pins, 4,256,899,072 bytes peak RAM and no swap/OOM. Independent audit passes
actual **40/100 MHz constraints**, zero black boxes and zero structural DRC
errors. The new **unplaced estimate is 20.962163 MHz**, up **5.670%** from
19.837334 MHz. Setup slack is −22.705 ns and hold −0.101 ns. This is neither
routed timing nor a measured board frequency; 40 MHz sign-off remains open.

The worst reported path has moved **out of the SRT/FPU**. It now runs from
`eip_reg[0]` to `pipe_mem_v_hit_q`: **165 levels / 47.494 ns** data delay
(10.711 ns logic, 36.783 ns estimated routing). Its serial chain is instruction
bytes → U/V decode/pair lookahead → successor descriptor/AGU/TLB →
`mc_prime_offer`/next address → shared L1 tag port → `shadow_reuse`/current
load data → integer flags/branch decision → `core_mem_next_commit` → paired
return readiness/V-hit capture. The other 29 reported worst paths end at the
paired-return data registers. These are native netlist observations, not an
AXI-latency or cache-miss attribution.

The next structural investigation should separate the **current response's
tag/data ownership from the successor lookahead's tag selection**. A dedicated
FPGA tag-read port or a proven ownership-only response selector may remove
this serial feedback. Do not remove tag-valid/coherence/fault checks, mask paths,
or disable priming/pairing. This remains a design hypothesis, not an implemented
or measured fix. No fresh placement/route is started in this round.

Current measured gameplay baseline is **0.49980509 IPC**, `bfb867f7`,
3,000,065,237–3,100,065,237; nineteen consecutive windows average **0.4907133389**.
Neither `03921cda` nor the queued numeric backport inherits that measurement.
An additional six closed builds' generated compiler objects were archived,
tar-compared and hash-checked before removal, recovering **1,053,150,824 bytes**.
Each affected root has `generated-objects.tar.zst` and a recovery receipt;
all executable, source, private harness object, trace and report pins remain.
The first FST-memory cleanup attempt refused its older `plan.json` receipt
layout before touching its objects; the reviewed exact-layout retry checks
the actual closed native build status and all 854 source pins. Disk reserve
policy remains unchanged. No active run's data was removed.
