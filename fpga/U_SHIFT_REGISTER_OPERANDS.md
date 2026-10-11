# Register-only fast-shift operand isolation — October 11, 2026

**Unqualified timing candidate: 26.55408 MHz unplaced post-synthesis estimate,
versus parent 26.14379 MHz. The required 40 MHz is NOT achieved; no FPGA pass.**

The measured worst path reaches the U shifter through a memory ALU response
mux, then feeds forwarded branch flags and L1 replacement control. The decoder
admits only register shifts into the fast U path; memory shifts use the normal
sequencer. Nevertheless, the generic U ALU and shifter currently share the
memory-selected operand wire. See [the measured path breakdown](CARRY_ROTATE_TREE.md).

[The source recipe](../verif/issue_uv/prepare_u_shift_registers.py) changes only
the core's U operand block in the frozen carry-rotate derivative:

- Preserve the existing memory-selected ALU operands and all ALU flags.
- Compute fast shift result, count-minus-one result and carry from raw GPR
  operands, retaining high-byte selection, width masking, CL and zero-count
  behavior. The existing helpers are unchanged.
- Disconnect the now-unused generic `u_pipe` shift outputs in this instance;
  synthesis can remove that dead logic. Other users keep the same interface.
- Assert that any shift descriptor observed in `S_PIPE` is register-only.
  This is a simulation invariant, not a synthesis gate or new fallback rule.

No issue/retirement permit, cycle, cache configuration, clock constraint or
architectural behavior is deliberately changed. Descriptor ownership still
selects held U versus current U exactly as before. A future fast memory-shift
extension would have to change this contract explicitly.

Three exact-source recipe tests pass. The native test extracts the actual
old/new core operand blocks and `reg_read`, instantiates
the real decoder and flag-forwarding modules, sweeps primary opcodes/ModR/M
bytes and shift counts/widths/high-byte aliases, and checks held descriptors
while live decode changes. Negative controls deliberately corrupt byte
selection, zero-count state and memory ALU selection.

The first run, invocation `ca80d593047e49909cdd2ce1ed136a05`, passes its
937,216 positive comparisons but its controller fails: it expected Verilator's
negative-control assertion to abort, while this installed runtime returns 1.
The actual negative log contains the intended native mismatch; it is not a
timeout or compilation failure. That failed receipt and original runner source
are retained in `leaf-r1/`, without rewriting the result.

The corrected runner requires a compiled native assertion, its explicit
`U-SHIFT-MISMATCH` marker and no positive completion marker. `leaf-r2/` closes
successfully in **23.54 seconds**, unit
`ventium-u-shift-registers-leaf-r2-oct11.service`, invocation
`2d370b992d814bd88318427f5235eb68`. All input hashes remain stable:

| Native positive coverage | Comparisons |
| --- | ---: |
| All checks | **937,216** |
| Shift descriptors | 142,640 |
| Memory descriptors | 13,884 |
| High-byte shifts | 30,848 |
| Zero-count shifts | 17,176 |
| Held descriptor with changed live decode | 85,248 |

The three separately compiled corrupted variants each terminate with a native
assertion/exit 1. Closed-receipt SHA-256:
`d7162a9da5a536b95fafe8a16141d4f4b0864fc3cc1911f525ab2208ace85249`.
This establishes native old/new block equivalence for the stated corpus,
not whole-core correctness or all-input formal proof.

The [cold system fixtures](../verif/issue_uv/t_u_shift_registers.S) add high-byte,
word, ROR, zero-count, count-31, memory-ALU and ordinary RCR cases, across two
segment layouts and four line offsets. Their
[driver](../verif/issue_uv/run_u_shift_system.py) generates goldens sequentially,
then checks full architectural/cycle streams with parallel RTL jobs at AXI
latency 0/7. It requires actual paired shift/Jcc retirement, except for explicit
line-boundary and ISA-required slow-path controls. All **64 fixtures /256
model-latency measurements** pass on the **control model only** (both named
slots deliberately use the same model), invocation
`dc5ac5d25b3349c79d89e64cec59b28d`. This validates the fixtures, not the new RTL.

The owned queue, invocation `fbec52f0017f403197ac54da79ff39bc`, observes the
parent's complete canonical/A-B closure before building the new model. The
parent canonical gate closes **FAIL**, native exit 2; its 20 cycle streams and
108 complete same-input functional streams match its parent.

### Whole-core results and FPGA preparation

[The private core builder](../verif/issue_uv/build_u_shift_register_core.py)
closes successfully in **25.14 seconds**, native exit 0, invocation
`bb813ca4a3214859b05dd102fe0b3c0b`. It changes only `rtl/core/core.sv`, preserves
all 150 definitions and verifies the model-local harness object/header
dependency. All pins remain stable. Model SHA-256:
`ce54833f54ad48e002ad001b0eb7223ac81e910f5aca8400a04634babf948fa0`.

The **new model** then passes all **64 cold fixtures /256 model-latency
measurements**, invocation `d5a35a75e0714ee0a16a357015307346`. Full QEMU and
parent/candidate comparisons cover **33,280 architectural records and 33,280
cycle records**, with **1,792 paired shift/Jcc observations** across both
models. No state or timing record differs between models. Stable-input result
SHA-256: `be31aee65cb742011be57bf00a43342231480eb21d940dcf12fc69ade6d15c7d`.
The unchanged canonical gate closes **FAIL**, native exit 2 after **403.77
seconds**; all 20 cycle streams remain identical to the parent. The complete
108-program same-input replay also closes successfully: **80,800 records**
match the parent without truncation. These comparisons do not turn the failing
canonical gate into a pass, and are not standard-suite or FPGA results.

[The independent auditor](../verif/issue_uv/audit_u_shift_register_core.py)
has reopened those complete traces and verified exact source scope, native
owner closures, original canonical cycles and all 108 same-input programs.
Audit SHA-256:
`d59eb7c496caeb74fac5880d60fbcb067e2db7283f77bd38ac8cd181c172c211`.
The
[PC builder](build_u_shift_register_soc.py) requires that closed audit and
reconstructs exactly the carry-rotate and register-operand transformations on
the measured branch-residency PC source, retaining 154 definitions and all 102
shared RTL files. It does not inherit a hardware pass from that source.

[The exporter](freeze_u_shift_register_rk_candidate.py) admits only the two
exact source deltas; six contract tests pass, including profile drift, lost
fast features, wrong source bytes and same-content inode replacement rejection.
The first preparation, invocation `61e6c68601cf415ba96615b44ad34a78`, completes
the independent audit and compiler recovery, then refuses the PC build at its
**5 GiB disk admission guard**, before compilation. This is not an RTL failure
or OOM; the guard remains unchanged.

After verified disk recovery, the full-PC model closes successfully, native
exit 0 after **43.20 seconds**, with unchanged inputs and the private harness
object/header verified. Model SHA-256:
`ac55dafd6687b0778a4d8285198f8e1d4d91f990a0800c09c962979b9166b32b`.
The exact two RTL deltas, all 154 native definitions, posted-16 transport and
102 shared sources are retained. The **98 inherited full-PC structural
warnings remain**; this is not a clean full-SoC lint result.

Preparation retry `c3af5cf773374dba9b17d454d6226b62` subsequently refuses
export because the proof queue's lexical `~/external/tmp` alias was absent
from the exporter's reviewed list. The original exporter and failed receipt
are retained in `prepare-r2/`. The correction admits only that exact alias;
a seventh contract test rejects both unreviewed aliases and redirected targets.
The same binary is reused, not rebuilt. Preparation continuation
`3d8cfd2d17c041bf8ab8ba25d1144cf6` **closes successfully**: export, independent
source audit and strict CPU lint all pass. The audit rechecks 307,454 input
pins and the exact two payload deltas; all 102 shared directed RTL files match.
Lint passes its six hard structural classes under all **156 hardware
definitions** in **3.60 seconds**. This CPU-hierarchy result does not erase
the separate full-PC warnings. Frozen manifest SHA-256:
`a36e00e8b30b6cfed198e8522c0baa338b528eb490d01e4d0d183f8ec053935e`.

The two original short CoreMark seed disks run on this PC model, invocation
`60e15ca2e908497e8cfddb564f3c1da9`. Both now close with native exit 0, stable
inputs, matching reference CRCs and unchanged cycles: **4,767,218** for the
performance seed and **4,753,406** for validation. The independent audit passes;
actual V retirements are 1,055,307 and 1,054,254 respectively, and no OOM event
is recorded. Their unchanged CRC and cycle checks are
admission checks, **not duration-valid scores or the full standard suite**.
After both preparation and seed closure, the owned queue launches one guarded
45-minute synthesis and queues its independent original-clock reports. The
native launcher starts at **08:43:53 UTC**, and its single Vivado family is
observed live at **08:43:56 UTC**, with **8 GiB RAM /6 GiB swap /48 tasks**.
The 4 GiB disk floor, 2 GiB host reserve and 13 GiB combined-memory early stop
are unchanged. The starting disk check still requires more than twice the
matched parent's measured growth above the stop floor. Original **40 MHz
core /100 MHz PL** constraints and the matched diagnostic `logic_only`
mapper remain unchanged.

Synthesis controller invocation: `5dca43f5622d4f3a988423fbc556b54d`;
Vivado scope: `908e5981dd364b6095834f847af0d5b9`;
original-clock queue: `490247bb20b74c5497766c041e810334`.
Synthesis now closes with **native exit 0**, stable inputs, in **1,877.67
seconds** (31 min 17.67 s), at **09:15:10 UTC**. Its independent closure audit
passes: all **307,671 input pins**, **148 native Verilog inputs**, the exact
two payload deltas, the generated mapper command and all 156 definitions are
checked. There is no resource-stop or OOM event. Peak bounded usage is
**8 GiB RAM /530,145,280 bytes swap**.

| Post-synthesis utilization | Branch-residency parent | Register-shift/carry-rotate candidate |
| --- | ---: | ---: |
| CLB LUTs | 189,799 | **184,962** |
| Registers | 54,606 | 54,646 |
| Block RAM tiles | 277.5 | 277.5 |
| DSPs | 47 | 47 |

The combined change removes **4,837 LUTs (2.55%)**; the two transformations
are not individually attributed. Native synthesis reports **0 errors, 1
critical warning and 1,567 warnings**. The critical warning is the same
generated PS8 `create_clock` unknown-pin warning present in the matched
parent. It is retained, not described as a clean-warning run; actual core/PL
clock checks remain the separate timing audit's responsibility.

Closure-audit SHA-256:
`e20b9f6b72e89396fce6794bbf83dac28c8f6eb239c82ca51ce3036ff10bdd9c`.
Synthesized checkpoint SHA-256:
`190d758a5817c8c9727553035a62dd4075281762545444feed346e67454134f2`.

The independent original-clock audit starts at **09:15:48 UTC**, invocation
`4f59ed2d666b43ceafb094626336b5c0`, after the synthesis family exits. Its
15-minute native cap and 8 GiB/6 GiB RAM/swap limits are unchanged. No
placement, routing or deployment is authorized by these controllers. This
audit now closes native 0 at **09:24:54 UTC**, in **512.54 seconds**, with
unchanged inputs, zero black boxes/structural DRC errors and no OOM or resource
stop. Peak memory is **5,157,478,400 bytes**, with no swap. The exact retained
controller and queue both exit 0. Clock-audit SHA-256:
`2787445a5751ff2a41565f521e48910b3dc06fea3b658f0835ab5fb8317d1eb9`.

| Original-clock timing estimate | Parent | Candidate |
| --- | ---: | ---: |
| Unplaced core Fmax | 26.14379 MHz | **26.55408 MHz** |
| Setup slack at 25 ns | -13.250 ns | -12.659 ns |
| Core hold slack | -0.101 ns | -0.101 ns |
| Worst-path logic levels | 135 | 134 |
| V-response capture setup slack | -12.419 ns | -10.595 ns |

The combined change improves estimated frequency **1.56935%** and reduces
LUT count 2.55%. Neither is individually attributed to its two transformations.
This is still **not 40 MHz**, routed sign-off, or a measured physical frequency.

The new worst path begins at `eip[1]` and ends at shared SRT `ua[14]/D`:
**37.448 ns** of data delay, comprising **8.483 ns logic /28.965 ns estimated
routing**. It traverses instruction-byte selection, overlength-fetch probe
address generation, segment/access checks, fragment/request shaping, saved L1
response selection, FP conversion and SRT input normalization. The old
memory-selected U shift is no longer the limiting endpoint.

The separately requested V-response capture path remains **35.384 ns /125
levels**, corresponding to **28.09383 MHz** from its -10.595 ns slack. Thus,
even eliminating the SRT tail cannot establish 40 MHz with the memory path
unchanged. This bound is diagnostic, not a measured optimization result.
The [input-normalization experiment](SRT_INPUT_NORMALIZATION.md) addresses
three remaining linear leading-bit searches; the common request/response
control path also requires work. Request cancellation, permission checks,
fragment ownership and denied-read zero data cannot be dropped as a timing fix.

A concrete upstream source-audit lead is the two cancellation blocks in
`core_bus_driver.svh`: translation/permission and synchronous-access faults
both clear request **and** direction/address/data/strobes. A20 payload masking
also depends on the already-qualified request. These shared payload wires then
select cache response bytes and code/data ownership, putting cancellation
conditions before arithmetic even where no transaction can be accepted.
The next experiment should separate request cancellation from unused payload
selection, while proving identical issued requests, consumed responses and
architectural/cycle traces. This is **not yet an implemented or measured fix**.
In particular, retained responses, stream mode, fragment start/abort, A20,
SMM/route-denied reads and faulting writes need explicit checks; merely leaving
`mem_req` low is not by itself whole-system equivalence evidence.

**880,645,526 bytes** of explicitly selected inactive compiler products are
losslessly archived, with verified member hashes and recovery commands in
`compiler-recovery*/`. Sources, binaries, headers, logs and traces are retained.
The corrected leaf runner archives only its two closed PCH caches after each
variant, preventing four small tests from retaining ~640 MiB of compiler cache.

The later `compiler-reserve-recovery/` inventory archives exact generated
compiler members from **720 inactive build directories**, recovering
**2,404,822,169 bytes**. Each archive is compared to the loose originals and
hashed before their removal; binaries, headers, source snapshots, harness
objects, traces and logs stay in place. Per-directory recovery commands and
retained-file hashes are recorded. The new PC model's two closed PCH caches
are also archived in `compiler-recovery-r5/`, recovering **165,769,266 bytes**
without removing the model or its build evidence. No resource guard is reduced.

Evidence root:
`/home/yukidama/external/tmp/ventium-u-shift-registers.XRngKRoW/`.
The focused whole-core comparisons and synthesis timing measurement are closed,
but canonical gate repair, reaching 40 MHz, the original standard suite and physical FPGA acceptance
remain open. In particular, no
syntactic depth estimate is substituted for synthesis or routed sign-off.

Gameplay baseline: **0.51030715 total U+V IPC**, simulated build `2b4d7a48`,
cycles **1,200,065,237–1,300,065,237**. It predates this proposal, which has no
gameplay measurement.
