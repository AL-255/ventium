# New-request CS-extent cofactor

October 13, 2026. Private derivative of the measured PRIME-COHERENCE core;
**not production promotion, canonical correctness, timing or FPGA acceptance**.
Its parent reaches **32.955444239 MHz synthesized Fmax**, below the mandatory
40 MHz UV + fast-pipe target. The derivative's Fmax and gameplay IPC are unmeasured.

## Why this is the next timing change

The completed parent's worst path crosses the slow reference decoder's
`d_len`, shared `cs_extent_fault`, new-store admission, AXI ACK and GPR
writeback: 106 levels, −5.344 ns at 40 MHz. The earlier
[proposal and fixture history](PAYLOAD_REGION_HINT.md#pending-follow-up-new-memory-cs-extent-cofactor)
already identified the following exact consumer invariant:

- A new integer load/store request implies S_PIPE, no held packet, and every
  integer pre-issue guard.
- At that consumer the S_DECODE fault arm cannot contribute;
  `pipe_cs_issue_eligible` is true and `pipe_u_eff.len == u_d.len`.
- Therefore only those two request predicates may use a direct live-U-length
  **33-bit** CS-extent comparison. Keep the complete global fault expression
  and exception priority, and both held-request muxes, unchanged.

`prepare_pipe_mem_cs_extent.py` now accepts two explicit source hashes: its
original PAYLOAD-REGION parent and the current parent
`3d8aebbdf338a63ab86bb58a6fab2ebb43f0f280bdbd3626ff4710941a5983c6`.
An entire-file comparison shows their only differences are the qualified
FLOAD high-valid port/cofactor/assertions: 15 added / 1 removed lines.
All pre-issue, request and CS-fault expressions are identical. Drift, unknown
parents and reapplication still fail closed. The three earlier commit-cofactor
headers are retained unchanged.

No register, pipeline stage, clock, feature define, instruction whitelist or
cycle is added. Simulation asserts equality of the **complete** old/new load
and store request outputs on every non-reset edge, including blocked offers.
This is not a global replacement for `cs_extent_fault`: doing that is unsafe.

## Current-source leaf and private model

Evidence root: `/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.

`prime-cs-leaf-r1` passes **65,536 extracted-RTL comparisons** over all four
segment-enforcement/FP-pipeline profiles, detects both missing-limit and
32-bit-wrap mutants, and passes six independent SMT queries. The SMT lemma
is a manually modelled Boolean/bitvector statement, not automatic formal
translation of the full RTL. Four host tests pass on **each** accepted source.
Leaf service `ventium-prime-cs-leaf-oct13.service`, invocation
`54e7340a50e74997bf41cc0e2a5cc444`, closed native 0 in **4.069789 seconds**,
with unchanged pins, CPU12 affinity, peak 45,412,352 bytes, no swap.
Closure SHA-256:
`05c3a71f561f4e6735afd2ccc932b1f25bdb72033fbfae4ef3e7702051160bb0`.

`build_prime_cs_core.py` checks that every actual compiled leaf fixture equals
the source-extracted old/new expressions, validates the exact terminal owner,
then transfers only `rtl/core/core.sv` into the complete **195-source** parent.
All **152 UV-fast definitions**, assertions and source ordering remain.
The new model uses a unique private C++ host with its own object and verified
dependency on the matching generated `Vventium_top___024root.h`.

`prime-cs-core-r1` built with **32 compiler jobs** in **19.607281 seconds**,
native 0 / stable pins. Service `ventium-prime-cs-core-oct13.service`, invocation
`7fa276d110a548648f09f0d00fbf5c4a`, is terminal with MainPID 0 / exit 0.
Model SHA-256:
`73f6f9dbd0ca16640456304a01453a8bfd5c28a98fa0c9ec5548a9d1fdd61dca`.
Build closure SHA-256:
`8c568d4065e3145151f5fc9d2a1cbac823aff55ac3d69593c7fc20468a3f90f2`.
This is a successful build, not an execution-test pass.

The unchanged canonical gate **closed with FAIL** in **393.023473 seconds** under
`ventium-prime-cs-verify-oct13.service`, invocation
`46e6ef60528d4ffe8a500a102fa20ca4`. It uses the real AXI backend, identical
latency 7, UV-fast cycle-functional traces and all 20 complete parent/candidate
cycle streams. All 20 streams match the parent exactly, and inputs remain
unchanged. Native `make` exit is 2; the controller exits 1. The canonical result
remains **7 functional PASS / 101 FAIL**, unwaived; parent equality is not
correctness. No mask, golden or cycle band changed. Closure SHA-256:
`153fa6b5864e35cbe0e703f276a4789cc1bbd394f7c5a08e62edf144de9ab997`.

## Closed whole-core and directed qualification

`prime-cs-corpora-r1` passes all eight unchanged groups in **295.794056 seconds**:
**4,240 probes / 21,190,336 clocks**, complete architectural/cycle equality,
and all earlier coherence/request assertions enabled. Coverage: AGI 18,172;
reference prime 24,352; prime 282,808; intent 5,616; request 3,072; accept 1,872;
shape-only 1,536; retained-prime 0. Service
`ventium-prime-cs-corpora-oct13.service`, owner
`cb26c8dc6d0c44d3af40ca0bea4ce7a7`, closed exit 0 / MainPID 0. Closure:
`597f4e147d6f87bd03b0b91167a2444a94a6bf56c4e24280a2a5ed002275befa`.

`prime-cs-fp-r1` passes the **384-fixture / 1,536-measurement** full wide-FP
matrix in **67.537575 seconds**, with all **768 cycle deltas zero**. Inputs
are unchanged; service `ventium-prime-cs-fullfp-oct13.service`, owner
`e0252f29e186485fa804c56042af2f6c`, closed exit 0 / MainPID 0. Closure:
`08fc40df00b26a713e7cafc4901c8344e585c7e6903f1659e2174c6aa83f2553`.

### Why a CS overrun cannot exercise new fast-memory admission here

The original test gap has a structural explanation, not a missing warmup:
with segment enforcement active in protected non-V86 mode and CS present,
`sfetch_boundary` asserts whenever the **33-bit** `eip + 15` exceeds CS.limit.
A new request requires no held packet and `pipe_frontend_ready`, which requires
`!pipe_fetch_checked_handoff`, which excludes this boundary. Any legal nonzero
4-bit instruction length therefore fits inside the admitted 16-byte window.
Overrun tests correctly exercise checked fetch, not a reachable fast rejection.

Two QF_BV queries independently check that arithmetic implication: nonzero
length gives UNSAT; zero length at EIP 0 gives a SAT underflow counterexample.
The host test checks the current RTL guard anchors separately. This is a
mathematical lemma, **not automatically translated whole-core formal proof**.
The new cofactor retains its original 33-bit check, including zero-length
behavior; no guard or global fault logic is deleted on the strength of this
reachability argument.

`prepare_pipe_cs_interior.py` derives six additional cold guest fixtures with
CS.limit **exactly probe PC + 15**, alongside the 12 original exact-end/overrun
fixtures. The new cases retain common zero segment bases, real guest WBINVD,
2/3/6-byte load/store opcodes, independent U/V warmup and self-checking GPR/RAM
results. They return legally instead of expecting a boundary fault. No saved
state, host register injection, STEP or pairing-disabled mode is used.

`build_cs_extent_observer.py` compiles only a unique read-only C++ host against
the candidate's unchanged archive/runtime objects and matching generated
headers. It samples settled pre-edge new-request, registered owner, ACK,
commit, boundary and extent signals at the probe PC, and fails on log overflow.
The first launch rejected optimized-away bus signal names before compiling;
the corrected observer observes the retained admission/owner signals and
does not modify the model. The corrected build closes in **3.294289 seconds**;
binary SHA-256:
`ca13bafe1ea707545c83b62c15e7cbea2170357c5a60f295c57dd0ce927c04ff`.

`run_pipe_cs_coverage.py` passes **288 cold runs / 72 observed cases** in
**18.268070 seconds**, comparing every architectural/cycle record and final
clock count across the parent, candidate, observer-disabled and observer-enabled
binaries, AXI latency 0/7, and both trace modes. All six interior instructions
produce exactly one new request and one final-ACK commit. Cold loads hold the
registered owner for **4 clocks at latency 0 / 11 at latency 7**; stores post
immediately (no false claim of held-store coverage). All boundary cases show
checked-boundary routing and **zero fast admission/commit** at the probe.
Warmup V retirement is required independently. The older eight-corpus tests
continue to cover held-store behavior.

Coverage service `ventium-prime-cs-coverage-oct13.service`, owner
`087e495a6b254bde96175b963d02bd13`, closed exit 0 / MainPID 0. Closure SHA-256:
`bc952f4a5b8645f2e25c44a6d8b39a28e99a92e55c43e776d16ce477715e022f`.
Six coverage-checker tests regrade the actual witnesses and reject lost
admission, wrong held PC, missing ownership/ACK, boundary side effects and
corrupt image bytes. Four driver tests retain the exact full regression plan;
five PC/hardware-transfer tests reject unreviewed deltas and wrong model
coverage. All pass. These checks do not waive the failed canonical gate.

### Disk-safe evidence retention

Only the closed eight-corpus text was removed after every member was compared
byte-for-byte with `closed-prime-cs-corpora.tar.gz`: **38,352 files,
969,145,428 → 87,602,987 bytes**, recoverable without losing evidence. Receipts,
fixtures, models, sources and other runs remain. Archive SHA-256:
`99cb70033991245d48ad8bec7bf4b081e2be861267b32ead61f7e5f22ec5ec05`.
Restore this archive in the evidence root before rerunning raw-stream audits.

The complete closed FP matrix was independently re-compared with its QEMU
goldens and A/B partner before compaction: 384 fixtures, 208,128 candidate
architectural records. `closed-prime-cs-fp-text.tar.gz` preserves **11,916
files, 487,345,124 → 29,592,407 bytes**, all byte-verified. SHA-256:
`89be60d3efdafcd45386ec0b5effcadbf543988c7c73f02320aa84905f712958`.
This archive's paths are relative to `/home/yukidama/external/tmp`, unlike the
eight-corpus archive. Each adjacent archive receipt records its recovery path.

The closed extended regression streams were likewise byte-verified into
`closed-prime-cs-regressions.tar.gz`: **36,984 files, 887,057,206 → 82,710,789
bytes**, leaving 128 explicitly pinned artifacts in place. Sources, receipts,
images and native models are retained. SHA-256:
`844ce83aee2cd72c233b2143d4a9fd008ecef6d080642ff0b7676788bd008d68`.
Restore in the evidence root. These three compactions recover approximately
**2.14 GB of logical data**, not a claim about filesystem allocation.

## Extended qualification and PC/hardware transfer

The unchanged 12-group extended regression run **closed PASS** in
**603.587868 seconds** under
`ventium-prime-cs-regressions-oct13.service`, owner
`a73550187c864b2cad5bdd75ce90e909`. It includes FP boundaries, faults, integer,
memory, held packets, branch and all 108 same-input canonical replays
(80,800 records). Every child exits 0 and all pins remain unchanged. This is
parent/candidate equivalence, **not a canonical correctness pass**.
Closure SHA-256:
`b7ac4920b22a1f4232ccba4631b20e6b0b67d729248e34d8c7c91993a53651de`.

`build_prime_cs_soc.py` and `freeze_prime_cs_rk_candidate.py` retain the full
original admission and add direct CS-coverage admission. `prime-cs-soc-r1`
builds in **24.454970 seconds**, with unchanged pins and native exit 0;
its unique host is compiled against the matching generated class. All
**102 common RTL files / 156 definitions / posted-16 transport parameters**
match the intended core. The 98 existing structural warnings are unchanged,
not silently cleared. Service `ventium-prime-cs-pc-oct13.service`, owner
`1083a0506ee84bc3946a86eeab8f9a6a`, is closed exit 0 / MainPID 0.
PC binary SHA-256:
`95f7c9b3c6a00bcc04976305abea88560268e20c05fd996d36aa188d3b908f79`.
Build closure SHA-256:
`0860c2df65b949d45ec22d1e25570d36f845e61137fe26c0063b40af9f7fee89`.

`prime-cs-fpga-r1` freezes **190 payloads / 170 matched HDL inputs / 158
hardware definitions**, the same 40/100 MHz clocks and full P5 cache profile.
The only changed parent payload is `ventium/rtl/core/core.sv`, SHA-256
`8dc1180b154b99b7fdf586071ca53d72427f09648403cf8f0120a4f570e3ed8d`.
Manifest SHA-256:
`fd6a1b36862845a096981b2028b4df479b00a9da447c35300834eba8f720cd15`.
Strict frozen-CPU lint passes in **3.878045 seconds**, all 158 definitions,
native 0 / unchanged inputs. Owner `ventium-prime-cs-lint-oct13.service`,
invocation `8946c03c6cc44d1ebf2300e7abcaa882`, is terminal. This is CPU lint,
**not full-SoC lint, synthesis or board qualification**.

`prepare_prime_cs_synthesis.py` also retains the tested controller/watchdog
lifecycle, 8 GiB RAM/6 GiB swap bounds, conservative disk admission and original
40/100 MHz clocks. Its five controllers/auditors are source-tested and
materialized. The matched control is the actual closed
32.955444239 MHz parent DCP, not a changed clock constraint.

## Required qualification still open

Both unchanged 10-iteration CoreMark seeds **closed PASS** sequentially in
`ventium-v-carry-cm10-prime-cs-oct13.service`, invocation
`0bd322d7056f460cbe9050258dd428e6`, explicitly on CPU 11, with a 2 GiB/no-swap
limit. The independent auditor passes with unchanged input pins, native exit 0,
both children reaped and no OOM. Performance/validation take **4,767,218 /
4,753,406 guest clocks**, respectively, with all original CRCs and actual V
retirement; both exactly match the parent. Wall times are 209.873 / 207.332 s.
Closure SHA-256: `cf2976e78d6295474e57c57fcdb3e5a73c5b9f90434600e4d4e86103063e69d0`;
independent audit: `7247adcb390da1acc2a85cbaab80e8c3c94ed4df51a9df5f00e9616246cc548f`.
These are short correctness/cycle controls, **not duration-valid scores or the
standard suite**.

Synthesis launched **2026-10-13 07:41 UTC**, service
`ventium-prime-cs-synth-oct13.service`, controller invocation
`25ad8b6f9a0344549354bc522f4c3fe7`; native Vivado scope
`fc70b8a4db434463a855ffd545644f37`. It **closed native exit 0 at 08:15 UTC**,
with unchanged inputs and no OOM/resource stop, in 2,056.739 seconds.
The single-family, memory, swap, disk and 45-minute native watchdogs held.
Admission requires both >6 GiB free and twice the measured parent growth above
the 4 GiB stop floor: the effective starting requirement was **7,208,493,056
bytes**, not just 6 GiB. No reserve was weakened.

Additional closed traces/fixture and compiler products were archived losslessly
to restore that reserve. Every member was hashed before originals were removed;
current input pins, executable models, sources and receipts remain unchanged.
Two latest archives, restored relative to `external/tmp`, are:

- `pre-cs-closed-corpora.tar.gz`: 82,220 files, 473,776,648 logical bytes
  (709,066,752 allocated) to 44,907,999 bytes; SHA-256
  `322fc702ed2309b2454d50034bddf36e09ce013b08b26c249993d451256946c4`.
- `pre-cs-closed-compilers.tar.gz`: 1,434 files from six closed models,
  297,274,368 to 38,592,581 bytes; SHA-256
  `ba23622a860754ef7f5102353554adf63abab6cf15dfc5ee2c2421f5a1af8d9f`.

The adjacent `*-plan.json`, `*-verified.json` and `*-closed.json` record exact
members and recovery paths. Old raw-output audits require restoring them first.

### Closed synthesis and matched timing audit

The independent native audit in `prime-cs-clock-swap4-r1` closes exit 0 at
08:26:43 UTC, in 484.230 seconds, with unchanged inputs and no OOM. The core's
**synthesized/unplaced Fmax estimate is 33.958163543 MHz**, versus the matched
parent's **32.955444239 MHz: +3.04265%**. Setup slack improves from −5.344 to
−4.448 ns at the unchanged 25 ns constraint; core hold remains −0.101 ns.
**The required 40 MHz is NOT met. This is not routed or board timing.**

Area rises from **184,618 to 188,163 LUTs (+1.92018%)**, and 54,493 to 55,011
registers. BRAM stays 277.5 tiles and DSPs 47. The source/mapper audit confirms
only `core.sv` changed, all 158 hardware definitions and clocks remain, and
`-no_timing_driven` is unchanged. There are no unresolved black boxes or
MDRV/LUTLP structural DRC errors. The existing PS-generated XDC `create_clock`
unknown-pin critical warning is retained, not relabelled a pass; actual core
and PL clock objects are checked as 40/100 MHz.

Timing-controller invocation: `ec91abe1cc3e4dac96833df2735b06a2`;
native scope: `db7639745e7f437ab326a7bf71b7cd59`.
The reporting-only controller reduces its **swap grant** from 6 to 4 GiB,
retaining the 8 GiB RAM cap and the same 2 GiB RAM / 4 GiB swap host admission
reserves. Its Tcl is byte-identical to the originally prepared audit; original
pinned controller files remain untouched. Actual peaks are 5,173,903,360 bytes
resident and 914,599,936 bytes swap. This does not change synthesis or timing.

- DCP: `097b4be822a4d63488de234395636255f43788154e9e60482419b6b6a66f56d5`.
- Synthesis audit: `55e703c3d655a77174f259182c4cbb6d299c6f41b4065b244d711ad5b3d9c7ab`.
- Clock audit: `a7581093c283b73287e8f3b0f966ec993f4325307426486a3d885731aece127f`.

The new worst path is **EIP bit 0 → L1D LRU bit 7**, 103 logic levels,
29.237 ns data delay (6.457 logic / 22.780 estimated routing). It crosses
instruction selection/decode, integer address generation, DTLB lookup, the
memory-operand ALU/flag forwarding, `v_br_taken_eff`, `mc_pipeline_commit`,
`core_mem_next_commit` and next-read capture/LRU update. The previous slow-CS
length consumer is no longer the reported worst path.

Next structural investigation: branch-based next-read priming requires a
**non-memory U instruction**, but its shared branch decision still includes
the memory-fed U ALU cone. Prove a non-memory operand cofactor at this consumer
against the complete existing commit signal before considering it. Preserve
actual branch validation, wrong-path suppression and cache-owner semantics;
do not globally disable memory pairing, speculate a commit, add an unchecked
cycle, or duplicate an entire ALU without measuring the area cost. This is a
source/report-backed hypothesis, **not an implemented or measured fix**.

Full duration-valid performance, the complete standard suite, and physical
FPGA Win95 desktop/UI plus original FreeDOS Quake timedemo remain required.

Current derivative gameplay IPC is **unmeasured**. Older verified simulation
baseline: **0.51030715 total U+V retirement events/cycle**, build `2b4d7a48`,
cycles **1,200,065,237–1,300,065,237**. It predates the derivative and is not
FPGA or full-timedemo IPC. The measured gain above is synthesized frequency,
not a measured CPI, gameplay or board-performance improvement.
