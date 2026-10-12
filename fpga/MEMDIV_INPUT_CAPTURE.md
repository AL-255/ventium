# Memory-divide input capture — October 12

**Private timing candidate. Synthesis running; not routed or FPGA-qualified.**
The last measured full-design post-synthesis Fmax is **30.487805 MHz** for
the [fetch-probe parent](FETCH_PROBE_PAYLOAD.md), below the **40 MHz** requirement.
This experiment follows the [bounded exponent change](SRT_DIV_EXP_WIDTH.md).
Neither experiment has its own Fmax or gameplay measurement yet.

## Structural change and cost

The measured path already reaches the divider operand after about **26.396 ns
of data delay**, beyond a 25 ns clock budget before divider normalization.
Narrowing exponent arithmetic alone cannot be assumed sufficient. The new
[source recipe](../fp_shared/tb/prepare_memdiv_capture.py) puts a register
boundary **before memory format conversion**, for memory FDIV/FDIVR only:

- Capture raw memory bits, ST0, width, direction and erratum selection on the
  original accepted command edge. Reuse the existing pending destination,
  pop and operation owner. FIP/FDP still commit on acceptance.
- In one new `TOP_MEMDIV` state, convert only the captured operand and either
  launch the existing shared SRT engine or commit its original special result.
  Neither the divide operand nor divide-special cone consumes live `cmd_mem`.
- Preserve stack-fault precedence and its original immediate response. While
  the new state owns a command, backpressure prevents another command from
  changing its payload, metadata or architectural state.
- Preserve register-divide, square-root, remainder and transcendental timing;
  shared add/multiply logic, admission and live SRT rounding controls do not
  change. There is no U-only mode, globally slow fallback or workload test.

Non-stack-fault memory divides, including special operands, gain **exactly one
leaf cycle**. The capture adds 168 payload/control register bits; the state
enumeration still fits three bits, although physical FSM encoding is the
synthesizer's choice. Separating the memory-divide conversion cone can increase
logic usage: **no area reduction or frequency gain is claimed before synthesis**.
Full-gameplay performance and the original performance targets remain required.

Only `fp_shared/ven_fp_top.sv` changes from the exponent-width core. Parent SHA:
`76b259bdc51534127a7bed77f3389a5971ef6b3774e1229c0785e74474c1e5ef`.
Candidate SHA:
`de65098da526dd472b34ac0b46c664d55ef60617305cc93e7e68fafcf7a92c57`.
The recipe rejects drift/reapplication and reverses byte-for-byte. Production
RTL and previously frozen inputs remain untouched.

## Closed FPU and core evidence

Evidence root: `/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.
Three host recipe tests pass, checking source scope, unchanged non-divide
arithmetic/rounding blocks, and absence of live memory in the divider inputs.
These are structural checks, not a formal sequential-equivalence proof.

The [full-FPU runner](../fp_shared/tb/run_memdiv_capture.py) retains the original
**396 register/SRT checks** across 12 RC/PC configurations. It then adds
**8,208 memory-divide cases per profile**: 8,192 delayed commands (4,096 normal
SRT starts and 4,096 special results), 16 masked/unmasked stack-fault cases,
and four reset phases. All 32,828 additional commands include their complete
response and architectural-state comparisons. The new cases cover four operand
formats, both divide directions, all RC/PC encodings, both erratum settings,
pop/no-pop, special/denormal patterns, and changing unaccepted command inputs.
Reserved PC=01 and unusual extended operands establish parent equivalence, not
independent ISA correctness. Reset checks ensure no orphan completion survives.

Both baseline and deployed-feature profiles pass. “Deployed-feature” identifies
the core's 152 definitions plus the simulation-only profiler, **not a board run**.
The active SRT payload must match; only inactive payload values are excluded
from the old test's cycle equality. Architectural state and valid results are
never masked or filtered.

| Leaf | Owner invocation | Native result | Seconds |
| --- | --- | --- | ---: |
| `memdiv-base-r2` | `5fccc52ceac14b0e9c993c7321f65de9` | build/run 0/0 | 12.95 |
| `memdiv-deployed-r1` | `99ec34804e194769bcb6bcd16830d909` | build/run 0/0 | 12.87 |
| `memdiv-live-bits-r1` | `607b308befac49e6a7a4de5361b3a63f` | build 0; intended run failure 1 | 9.86 |
| `memdiv-reverse-r1` | `38a9cc24113545fa85f99aa9103af865` | build 0; intended run failure 1 | 10.06 |
| `memdiv-width-r1` | `d5177ade12f14dfd90b91a55fc674e06` | build 0; intended run failure 1 | 9.95 |

Every bad variant fails the actual `MEMDIV_CAPTURE` ownership check; compile
failure is not accepted as mutation success. All owners are terminal/reaped,
input hashes are unchanged, and actual launched child affinity is CPU0–31.
Builds use the existing serialized 32-job, 16 GiB/128-task scope.

The first `memdiv-base-r1` attempt remains **FAIL**: C++ compilation encounters
`posix_spawn: Resource temporarily unavailable` before simulation. The retry
sets `CCACHE_DISABLE=1` without changing sources, expectations, job count or
resource caps; it succeeds. This supports compiler-cache process overhead as
the cause, but no retained cgroup PID-event counter proves the exact exhausted
limit. Its native failure and generated inputs remain intact.

The [whole-core transfer](../fp_shared/tb/build_memdiv_core.py) requires both
positive profiles and all three actual mutation failures. It preserves the
same **195 source payloads / 152 definitions**, all assertions and the private
host-object/generated-header audit. `memdiv-core-r1` builds natively in
**20.89 seconds**, invocation `697f8dfba5684b5da381a32a6a2dbb83`, with stable
input hashes. Model SHA:
`be5375aa32db48600498fc4b2c3a610c7cd99a0fa208c5186e602c44dd9b3d10`.
This is a source-matched build, not full-system acceptance.

The **original 384-fixture FP/QEMU matrix passes unchanged**, including full
architectural and exact A/B cycle comparisons at AXI latency 0/7:
**208,128 candidate records / 768 V retirements**, no cycle differences.
`memdiv-fp-r2` closes native zero in **50.26 seconds**, invocation
`65a53e984358447db2467235c9364a4b`, with stable input hashes. Its first launch
(`memdiv-fp-r1.driver.*`, invocation `83d1c29563b9448481e88c3a7c6a7b6d`)
is a retained **FAIL**, exit 2: wrong command-line argument names prevent any
fixture execution. Only the invocation is corrected for R2.

Canonical `make verify` closes **FAIL**, native make exit 2 in **402.36 seconds**,
invocation `c4cfe097de8b4ed79bd1cb2072b4a09d`: **7 PASS / 101 FAIL**, the same
counts as the parent. All 20 complete cycle streams match the parent. Masks,
goldens and cycle bands are unchanged. This remains an acceptance blocker;
successful component or A/B checks do not turn the canonical gate green.

## Additional memory-divide core tests

The [new cold paged fixture](../verif/issue_uv/memdiv-capture-system.S) covers
all eight floating/integer memory-width/direction forms. It mixes independent
integer memory instructions, queued FXCH, status stores and result consumption.
Instruction mixing alone is **not a measured FP/integer-overlap result**.
The [runner](../verif/issue_uv/run_memdiv_capture_core.py) retains the original
complete QEMU/native grading and adds exact full A/B architectural comparison.
Only this new fixture allows a bounded cycle difference: no more than 16 clocks
for its 16 memory divides, including a per-retirement cumulative bound.
The original FP and canonical timing tests are not changed.

The first **16 fixtures** (eight forms, flat/relocated clients, instruction
offset zero), each at AXI latency 0/7, pass: **9,984 candidate architectural
records / 32 actual V retirements**. Sixteen divides add **15–16 total clocks**,
within budget. `memdiv-cold-r1` closes native zero in **2.71 seconds**,
invocation `b5974b6ebed34d8e95d681e73acadb4c`, with stable input hashes.
These are directed-test timings, not gameplay IPC.

The full **512-fixture** version across all 32 instruction-line offsets passes
in **73.96 seconds**: **319,488 candidate records / 1,024 actual V retirements**,
and the same 15–16 added clocks per 16 divides at both latencies. Owner
`ventium-memdiv-cold-full-oct12`, invocation
`39da9070c5fa4236ab9936d7d28ea429`, is closed and reaped; its input pins are
independently rehashed unchanged. Receipt SHA:
`e03ff244bc89ca598d12285c273f3e70a67d19ab95bbc0a3e3b80683f635fc33`.
The unchanged original FP fault matrix also **passes all 32 native runs**
(16 fixtures × parent/candidate), including the mandatory full UV/QEMU and
complete A/B architectural comparisons. Owner `ventium-memdiv-faults-oct12`,
invocation `eff1a1704498491b8b3d761d4df9b250`, is closed/reaped with stable
input hashes. Slow-mode controls remain diagnostic only.

Same-input canonical replay **passes all 108 programs / 80,800 records**,
reproducing the candidate's original traces in **75.81 seconds**. Owner
`ventium-memdiv-replay-oct12`, invocation
`2ae19c2111844c6f9c23e456e56d4486`, is closed/reaped; both replay and fault
input-pin sets are independently rehashed unchanged. This still does not
make the canonical QEMU gate pass.
## PC transfer and synthesis admission

The source-matched PC build passes in **23.00 seconds**, invocation
`89535e98dfdc41088f65501f533b03b3`, with stable inputs and the private C++
header/dependency check. Model SHA:
`10d875b4cf1680d50906434ee3d5572ce1ee0f8175a792c8a7554d8728c6f3fe`.
All 102 shared RTL/header inputs are checked: exactly `ven_fp_top.sv` and
`fpu_srt_div.sv` differ from the fetch-probe PC. All 156 definitions and
posted-16 transport are unchanged. The inherited 98 SoC structural warnings
remain; this is not a clean full-SoC lint result.

The hardware export has 190 payloads, 170 matched simulation units and the
unchanged 158-definition hardware profile, 40 MHz core / 100 MHz PL clocks,
full P5 L1 caches, and no mouse overlay. Source-contract checks pass. Manifest:
`0859a74cc3539b1644c90813029c02e0545d1b002184e33cd94f6ecbe6ed68cb`.
Strict frozen **CPU-hierarchy lint passes** in 3.83 seconds, invocation
`002abe56a21c4d14b299f2d870027139`; all six structural warning classes remain
errors. This does not waive the full-SoC warning debt.

Both original **10-iteration CoreMark preflight seeds pass**, including all
five reference CRCs per seed and unchanged ticks: **4,767,218 / 4,753,406**.
Actual V retirements are 1,055,307 / 1,054,254. Native child argv, CPU11
affinity, real board AXI profile, model hash and process closure are audited.
Owner invocation `f02b13865cd444cbaa57c2701f63436b` is terminal and reaped,
with no OOM and 2,121 source pins rechecked. These short runs are **not a
valid-duration score or the full standard seeds**; no performance gain is claimed.

The [synthesis preparation](prepare_memdiv_capture_synthesis.py) preserves the
closed fetch-probe controller's resource lifecycle byte-for-byte: one Vivado
family, 8 GiB RAM / 6 GiB swap limits, 13 GiB combined early stop, 2 GiB host
RAM/swap floor, 4 GiB disk stop, and initial disk reserve above 6 GiB plus
twice measured parent growth above the stop floor. The mapper and real clocks
are unchanged. Two preparation tests pass, including drift rejection.
The first controller admission, invocation
`b6970c308a2a40e1b562738159af86e4`, fails before Vivado or a native build
starts: 6.02 GiB free exceeds the simple 6 GiB floor but not the measured-growth
requirement. The matched earlier run grew by 1,456,762,880 bytes, requiring
more than **7,208,493,056 free bytes**. This failure remains in the journal;
no safeguard is weakened.

After lossless compaction, admission observes 7,335,583,744 free bytes.
Controller invocation `8a64a6aaafd04df391f2e7099068e561` is running under
`ventium-memdiv-synth-oct12.service`; its owned Vivado scope invocation is
`c32cf9f7f01942d59dcb62eea51ac435`. The first rejected admission had no
`started.json` or `once` directory; this is the first actual native synthesis.
The [timing queue](run_memdiv_capture_timing.py), invocation
`c7ff77bffc15454b8d1dffc07bb9232d`, adopts that exact owner and waits for
successful native closure before the independent synthesis and clock audits.
It cannot restart synthesis, route or program hardware. No new Fmax is known.
Synthesis/timing, full standard suite and physical FPGA Win95/UI plus full
Quake timedemo remain open. The canonical **7 PASS / 101 FAIL** gate is still
an unwaived blocker, not superseded by these checks.

## Disk reserve and receipts

Twelve unused/unpinned compiler PCH caches from the six closed leaf attempts
are removed: **1,017,443,754 bytes**. Exact owner states, no open descriptors
and unchanged source/model pins are checked before and after deletion.
`memdiv-pch-cleanup-{plan,closed}.json` lists the files and hashes. Sources,
generated headers, native models and logs remain; rebuilding regenerates PCHs.

The two closed exponent/capture FP matrices are independently re-compared
against QEMU and each other before lossless compaction: **768 fixtures /
416,256 candidate records**. Their **23,832 text files**, 974,055,076 bytes,
become the byte-verified 58,788,649-byte `closed-memdiv-fp-text.tar.gz` archive.
SHA: `8c7452c0b80bc4cadb8f9b4b4f39a4ea357efa610f0e8d2908747436a393da8a`.
Restore with `tar -xzf closed-memdiv-fp-text.tar.gz -C /home/yukidama/external/tmp`.
All protected inputs, models, receipts and active-run files stay untouched.

The full cold memory-divide matrix is independently re-compared before
archiving: 15,888 text files / 730,824,560 bytes become 42,390,909 bytes in
`closed-memdiv-cold-text.tar.gz` (SHA
`9311ee520a99d397e5291d07b455c8ea3fcb6b682e9e24a345168b5ee2e0dcab`).
Thirty unpinned reports from three closed parent clock audits are byte-verified
and compressed from 512,302,490 to 22,343,271 bytes in
`memdiv-parent-clock-reports.tar.gz` (SHA
`ce39ced9b862e19ff5e506fdd71e1d50a46fb36cb6975a992b626690d2348bd4`).
Both archives restore with `tar -xzf <archive> -C /home/yukidama/external/tmp`;
historical audit reruns require restoring their reports first.

Four unused core PCH caches reclaim 371,202,459 bytes; two closed PC-build
PCH caches reclaim another 190,888,587 bytes. Their exact owners are reaped,
no open file descriptors refer to the targets, and protected input/model
hashes remain unchanged. `memdiv-core-pch-*` and `memdiv-soc-pch-*` receipts
retain the explicit targets; rebuilding regenerates the caches.

An attempted archive of the older remainder timing reports refuses to proceed:
every selected report is still a protected input. Owner
`ventium-memdiv-reserve-archive-oct12`, invocation
`3ee0f97ec0c34385b7b0a6657fbc9e7f`, exits 1 before creating an archive or
removing any report. Those reports remain untouched.

Instead, 1,264 unpinned generated C++/object/archive files from eight closed
builds are byte-verified and compressed from 276,156,764 to 36,376,379 bytes:
`memdiv-build-intermediates.tar.gz`, SHA
`38137f4d899b9a18dc581d665ac0b351843065b6ae48a1b1724c725d4b319686`.
Native models, RTL, generated headers, dependency files and proof inputs remain.
Eight explicit closed fault-test folders contribute another 2,816 trace/log
files, 891,599,696 bytes compressed to 29,278,897 bytes:
`closed-fault-traces.tar.gz`, SHA
`3a8036180b250a2d73236c80a9ba7c082730f4537a6b51dcccd51149334d9327`.
All members are independently byte-verified before removing loose copies;
current protected hashes are checked afterward. All native test/build workers
are quiescent during compaction. This archival step is not a new test pass.
Restore either archive with the command above before rerunning historical
trace comparisons or reusing archived intermediate objects.

Gameplay baseline: **0.51030715 total U+V simulated retirement-event IPC**,
older model `2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. This candidate
has no gameplay measurement; the baseline is neither board IPC nor a full-demo mean.
