# P54 IPC resource microbenchmarks

`run-p54-ipc-micro.py` measures fixed-work user-mode loops on an existing
`tb_ventium` L1/AXI binary. It never builds RTL or runs the full verification
suite. Each child simulation is capped at 30 seconds; the whole invocation is
capped at nine minutes internally (use `timeout 600s` as an outer guard).
Independent cases run concurrently with `--jobs` (default up to 32, limited
by the number of cases). This is simulator fanout, separate from Verilator's
generated-C++ compiler jobs.

```sh
timeout 600s python3 verif/bench/run-p54-ipc-micro.py \
  --binary /absolute/path/to/candidate/tb_ventium \
  --control /absolute/path/to/matched/control/tb_ventium --jobs 32
```

The control must be compiled from the same RTL revision with identical defines
except for the proposed optimization. `--assemble-only` validates the workload
layout without simulation. The runner measures the steady 899 iterations after
100 warmup iterations and records exact clocks, instruction callbacks, IPC and
cycles per loop in `results.json`. It checks loop and exit completion. With a
control binary, it also compares the full architectural traces for every case.
This A/B check is **not** QEMU differential verification or a gameplay IPC result.

The matched frontend ladder on the banked code-buffer/stream L1 is especially
diagnostic. With the same fast-ADD and system-fastpath base flags, raw decode
takes **2 cycles per four-instruction** line-straddling loop. Adding only
`VEN_UOPCACHE`/`VEN_IC_BRAM` makes it **23**, while the aligned loop remains
2. Adding `VEN_UOP_CROSSLINE`/`VEN_UOP_EXEC_REPAIR` brings the straddle to
**3**; adding `VEN_UOP_CROSSPAIR` brings it to **2**. Each step's 22-case
candidate/control architectural traces match. The first pair has no memory
chain flags, because that mechanism requires the uop cache. These are fixed
synthetic loops, not gameplay IPC, and the cross-line options remain
default-off pending FPGA/resource and broader fault/SMC qualification.

The September 28 combined-profile check found a necessary interaction:
`VEN_UOP_CROSSLINE` now implies exact local-tail mapping in `core.sv`. Without
that mapping, a valid instruction at byte 27 could repeatedly launch a futile
legacy-window repair, occupying the sole repair walker before a hot byte-31
crossing instruction. The pre-fix combined build matched QEMU state but never
fast-retired the crossing in the three-phase writable-code test. The implied
tail profile passes `run-crossline-smc.py` (QEMU state, descriptor hit and fast
retirement after changes to either source line) and the six exact-tail core
witnesses. No workload address is special-cased.

With the two-window L1 profile as control, the opt-in cross-line profile's
30-case fixed-work matrix keeps every architectural trace identical and changes
the four-instruction line-straddle loop from **7 to 2 cycles**; the aligned
loop stays at 2. A two-entry cross-line record and a 33-entry indexed record
both achieve **5,394 instructions in 5,394 cycles** on the separate two-seam
test. The indexed record helps a synthetic 12-seam pressure test further:
**11,821 to 8,955 cycles** for the same 3,582 warm instructions versus the
two-entry record, with QEMU-equivalent retirement groups. The indexed payload
alone is 6,720 logical bits plus metadata. A [bounded FPGA leaf
probe](../../fpga/P54_UOPCACHE_LEAF_SYNTH_2026-09-27.md) found that expressing
those bits as a packed vector array, rather than an unpacked array of structs,
is necessary for Vivado to infer distributed RAM: the mapped indexed leaf
drops from 17,019 LUTs / 10,759 FFs to 13,055 LUTs / 4,562 FFs, with 120
more LUTRAMs and unchanged BRAM count. There is still no routed whole-core
area/timing result; do not assume the 12-seam gain justifies it on silicon.
These numbers are directed microbenchmarks, not verified gameplay IPC or full
qualification.
The canonical cross-page fetch gate remains blocked by the pinned free-running
QEMU's known two-page TB-bookkeeping defect; an isolated corrected-QEMU
diagnostic matched 1,601 stepped groups and observed the expected fault/retry,
but deliberately does not count as a canonical pass.

For a full-core microbenchmark binary on a 32-core host, the separately named
`ipc_parallel32` scope permits at most 32 C++ compiler jobs with 3,000-statement
generated-C++ splitting and a fixed 16 GiB cgroup limit. The ordinary build
still defaults to one job. Example (one build at a time):

```sh
timeout 540s env VENTIUM_BUILD_SCOPE_PROFILE=ipc_parallel32 \
  VENTIUM_BUILD_SCOPE_UNIT=ventium-ipc-parallel32 \
  make -C verif/tb l1axi VL_J=32 L1AXI_OBJDIR=obj_dir_ipc_candidate \
  VL_EXTRA_DEFINES='+define+VEN_UOPCACHE +define+VEN_IC_BRAM +define+VEN_UOP_SFETCH +define+VEN_SFETCH_RESIDENT +define+VEN_PIPE_MEM_CHAIN +define+VEN_L1D_WINDOW_REUSE +define+VEN_SYS_FASTPATH +define+VEN_PIPE_REG_LOAD_PRIME'
```

The full-PC `ao486-sim` Makefile uses the same bounded profile. Always select a
noncanonical output directory when experimenting:

```sh
timeout 540s env VENTIUM_BUILD_SCOPE_PROFILE=ipc_parallel32 \
  VENTIUM_BUILD_SCOPE_UNIT=ventium-ipc-parallel32 \
  make -C ao486-sim ven VEN_OBJDIR=ao486-sim/obj_dir_ven_ipc_candidate \
  VEN_EXE=ao486sim_ven_ipc_candidate
```

| Cases | Exact structural question from the [P54 plan](../../docs/P54_SUB1_CPI_MASTER_PLAN_2026-09-27.md) |
| --- | --- |
| `reg_load_prime` | Can an independent register packet lend its idle D-cache lookup cycle to the next load, eliminating the registered-hit capture bubble? The load alternates resident lines to defeat same-line window reuse. |
| `dual_load_{distinct,same}_bank` | Can two independent loads from different lines overlap when their physical `[4:2]` bank indices differ, and does the same-bank case correctly serialize? |
| `dual_load_after_store{,_same_bank}` | Can a fresh U capture and distinct-bank V hit pair when a preceding ordered store leaves no register/branch prime slot, while same-bank V serializes? This isolates V ownership from load priming. |
| `dual_store_{distinct,same}_bank` | Are two store admissions possible while preserving order and the two-entry write-buffer limit? Both cases cross cache lines. |
| `resident_memory_alu` / `register_alu_control` | Does a resident ALU-memory instruction retain its P54 resource occupancy instead of accidentally collapsing to register-ALU timing? |
| `fp_integer_overlap` / `integer_only_control` | Can independent integer work proceed while a real x87 arithmetic operation is outstanding? The integer control has a nonpairable leading EAX dependency so a freely-paired NOP cannot fake a larger FP penalty. |
| `frontend_{aligned,line_straddle}` | Do resident raw instruction bytes cross a 32-byte I-line without persistent decoded-cache repair stalls? |
| `resident_{same_line,two_line}_loads` | Does the registered D-cache window serve a later hit in the same physical line without a second capture, and does a different line correctly require its own lookup? |
| `register_u_memory_v` / `memory_u_register_v` | Can an independent V load issue when U has no memory operand, contrasted with the existing U-load/V-register case? |
| `memory_alu_integer_v` | Does a resident ALU-memory U retain its execution occupancy while an independent integer V follows? |
| `resident_memory_{or,adc,sbb,and,sub,xor}` | Does the checked register-destination memory-ALU admission avoid recurring slow fetch/decode/load FSM visits without changing full architectural state? ADD is the separate `resident_memory_alu` control. Carry operators retain their real CF dependency. |
| `branch_target_load` / `v_branch_target_load` | Can a predicted-taken U/V branch prime a checked resident load on its target edge, without changing the final not-taken iteration or merely moving a capture bubble to another load? |
| `branch_fallthrough_load` / `v_branch_fallthrough_load` | Can correctly predicted not-taken U/V branches prime a checked resident load on the sequential path? The V fixture crosses data lines so window reuse cannot hide its capture bubble. |
| `branch_fallthrough_mispredict` / `v_branch_fallthrough_mispredict` | Does a final not-taken→taken direction reversal skip the speculative load without creating a response owner, while all preceding warm iterations remain correct? |

These cases expose bottlenecks, not the full acceptance matrix. They do not
cover paging/TLB geometry, dirty-line coherence, precise faults, interrupts,
or SIR-dependent FP values. Add dedicated short fixtures for those mechanisms
as their replacement interfaces land. In particular, a faster distinct-bank
case is **not** by itself proof of two memory retirements per clock: inspect
the cycle trace and the accepted owner records before claiming dual issue.

`run-p54-bank-arb.sh` is a bounded leaf test for the proposed eight-bank
admission rule: physical `[4:2]` conflicts, unaligned/64-bit extents, split-line
fallback, bank backpressure, and U-before-V priority. It exhausts all 16,384
line-offset/width pairs, then runs 32,768 randomized cases per seed. The leaf
alone cannot establish core-level V-memory retirement or any gameplay speedup.

`VEN_P54_DUAL_LOAD_PAIR` is an opt-in core consumer of the banked L1's
`VEN_P54_DUAL_HIT_LEGACY_CAPTURE` lane. It adds a separately translated,
hit-only V request only for independent dword MOV loads while U is taking a
fresh registered hit; same-bank, miss, MMIO, segment/page-fault and snoop
cases retry V as the next U. The V path adds no whole-cache async-read
replica; the pre-existing next-line bank-zero read remains a separate FPGA
mapping cost. Run
`bash verif/bench/run-p54-dual-load-issue.sh` for decode/dependency cases,
`bash verif/bench/run-p54-l1d-pair-hit.sh --legacy-capture-pair` and
`bash verif/l1/run-l1axi-pair-hit-micro.sh --legacy-capture-pair` for cache
arbitration/seam cases, then the bounded pinned-QEMU full-state microcases:

```sh
python3 verif/bench/run-p54-dual-load-pair.py --case 28 \
  --candidate verif/tb/obj_dir_p54_dual_load_r1/tb_ventium \
  --control verif/tb/obj_dir_p54_branch_prime_r1/tb_ventium
python3 verif/bench/run-p54-dual-load-pair.py --case 29 \
  --candidate verif/tb/obj_dir_p54_dual_load_r1/tb_ventium \
  --control verif/tb/obj_dir_p54_branch_prime_r1/tb_ventium
```

The post-store distinct-bank case 28 saves one clock per five-instruction
loop (**5→4**, directed IPC **1.00→1.25**), while same-bank case 29 remains
**5→5**. Both builds match pinned QEMU full state in both cases. The original
`dual_load_distinct_bank` loop remains **4→4** with the branch-prime profile:
the preceding branch primes U's capture one cycle early, so this fresh-U
sideband opportunity is absent. These are directed measurements, not gameplay
IPC or routed FPGA timing.

`VEN_P54_DUAL_LOAD_PRIME` extends that opt-in owner to the existing checked
register/branch successor lookahead. A separately computed V effective address
uses the independent V D-TLB query; the L1 reserves primed U's word bank and
captures a resident V from another bank only when U's speculative lookahead
actually commits. The decoder rejects U/V register hazards and V addresses
dependent on the predecessor. The new V path shares the existing per-bank
read mux; it does not replicate the whole-cache async read array. The
`--prime-pair` leaf
mode checks accepted/rejected lookahead, bank conflict, data, owner and mixed
window behavior. Cases 1/2 of `run-p54-dual-load-pair.py` compare both
candidate and control against pinned QEMU full architectural state. Case 1's
distinct-bank loop improves **4→2** cycles per four-instruction loop (directed
IPC **1.00→2.00**); same-bank case 2 stays **4→4**. All 30 directed cases have
matching candidate/control architectural traces, with no other cycle
regressions; same-line resident loads also improve **3→2**. Terminal
branch-direction reversal cases 26/27 match pinned QEMU full state and retain
their prior cycle counts. This still needs FPGA routed area/frequency and
gameplay verification before it can be promoted to a deployed profile.

`VEN_L1D_TWO_WINDOW_REUSE` is a separate, default-off registered-data
experiment. It retains the *previous* complete 32-byte read line alongside
the existing primary window; every reuse still requires a live L1 tag hit.
Stores, fills, snoops, flushes, non-cacheable accesses and reset invalidate
the shadow, so it adds no cache capacity or async SRAM read port. A checked
prime of the already-current primary line now re-arms the response owner
without rereading the bank or evicting the other hot line. This costs one
256-bit line register plus tag/control logic; FPGA area and timing are not yet
measured. Bounded checks are
`bash verif/l1/run-l1d-window-reuse-gate.sh --two-window`,
`bash verif/l1/run-l1d-window-reuse-gate.sh --two-window-keep-store`,
`bash verif/l1/run-l1d-load64-gate.sh --two-window` and
`bash verif/bench/run-p54-l1d-pair-hit.sh --two-window`.
Against the prior dual-load-prime core, same-bank resident two-line loads
improve from **4→3** cycles per four-instruction loop (directed IPC
**1.00→1.33**); distinct-bank loads remain **2→2**. All 30 candidate/control
directed architectural traces match, and cases 1/2/28/29 plus terminal
branch-reversal cases 26/27 match pinned QEMU full state. These are not
gameplay or routed-FPGA results.

`VEN_PIPE_BRANCH_LOAD_PRIME` is an opt-in extension of the registered
`VEN_PIPE_REG_LOAD_PRIME`/`VEN_PIPE_MEM_CHAIN` path. It may probe a
predicted-taken target or predicted-not-taken fall-through, but
`c_next_commit` requires the actual direction to match the prediction and
the normal checked resident-load gates. The bounded
`run-p54-branch-target-prime.py --case 22..27` checks U and paired V branches
against pinned-QEMU full-state traces. Cases 26/27 reverse direction only on
the terminal iteration; the script checks that QEMU skips the load and the
candidate does not retire or capture a wrong owner. The 256-iteration
directed cycles per six-instruction warm loop are: 22 **5→4**, 23 **6→5**,
24 **6→4**, 25 **6→5**, 26 **5→5**, and 27 **6→4**. All 28-case architectural
A/B traces match; the other 23 cases are cycle-identical. This is a
core-consumed microbenchmark gain, not gameplay IPC or routed FPGA timing.

The branch prime shares the existing D-cache lookup slot on a branch edge;
it adds no cache-data read port. For the FPGA target, wider simultaneous
access should use banked or true-dual-port Xilinx BRAM where it wins timing,
not replicated combinational multi-read arrays. This branch path still needs
routed timing evaluation before enabling it in a hardware build.

`run-p54-hit-return.sh` tests a two-slot owner-tagged hit-return prototype. It
accepts two distinct-bank hits per clock, holds each owner/data pair under
independent response backpressure, permits consume-and-replace, blocks V behind
an unaccepted U, and cancels both slots on flush. This is still a leaf contract,
not an integrated cache or an architectural correctness gate. Hit/data are
supplied by the testbench; a timing-qualified bank SRAM/tag implementation and
its FPGA area/frequency evidence remain required.

The intended physical cache is eight 32-bit data banks, each holding the
128-set × 2-way word for its line position (8 KiB total data), not two copies
of the present 256-bit-line array. The 128 × 2 tag/valid structure is small
enough to examine for replicated read lookup or dual-read RAM. A line fill
writes its addressed bank per backing beat; a hit sharing that bank must wait
unless the RAM's read-during-write behavior is proved. These are implementation
constraints, not permission to enable V-memory pairing.

`run-p54-banked-l1d-micro.sh` exercises the default-off physical striping of
the existing L1 data array at 128/64 sets, plus coherence, registered-window
reuse, and hit-stream leaf cases. It preserves the original single-port
interface and therefore has no direct IPC gain. In particular, equivalent
logical data capacity is not evidence of equal LUT/BRAM area. The ordinary
32-bit cross-line window now reads only next-line bank zero, not all eight
banks, but that bank still needs an extra read port; synthesis must qualify
its physical mapping before promoting it. A synchronous true-dual-port BRAM
variant is worth measuring, but its read latency and read-during-write result
must be reflected in the core handshake rather than assumed invisible.
The bounded [Vivado leaf probe](../../fpga/P54_L1D_LEAF_SYNTH_2026-09-27.md)
confirms eight separate banks infer `RAM256X1D` and save 1,187 leaf LUTs
versus packed data; this does not establish full-core timing or gameplay IPC.

`run-p54-bram-bank.sh` separately checks a 256×32 FPGA BRAM bank with two
registered read ports and byte writes. Vivado infers one `RAMB36E2` for that
isolated bank (zero LUTRAMs/FFs). This is a possible FPGA storage organization,
not an integrated L1D: synchronous row-address timing and same-row write/read
arbitration remain explicit design obligations.

`run-p54-bram-data.sh` checks the eight-bank dual-read composition with 62
directed admission/response/collision/cancel witnesses, including all 56
ordered distinct-bank pairs. Vivado maps its isolated storage to eight
`RAMB36` tiles (212 LUTs outside the RAMs). This leaf has no tags or core
connection and cannot yet claim a gameplay IPC gain; see the same
[synthesis record](../../fpga/P54_L1D_LEAF_SYNTH_2026-09-27.md).

`run-p54-dual-agu.sh` checks both independently computed ModR/M/SIB effective
addresses over 1,024 base/index/scale/enable/overflow combinations. The U/V
At the dual-AGU extraction stage, the AGUs connected to U memory and V LEA;
V-memory issue was still disabled pending a second checked request/translation
and precise response owner. A same-flag full-core candidate (binary SHA-256
`ce372ee06de445ad3c1ef951e74b7a73d8f8a2ef9efeeecd1c48f6e6c62ff05f`)
matches its pre-AGU control in all 22 fixed-work architectural traces and
cycle counts (`/tmp/p54-dualagu-core-micro-r1/`). The 14-case pinned-QEMU
memory-ALU full-state check also matches every control cycle count using
`run-alu-memory-ab.py --expect-equal-cycles` (log
`/tmp/p54-dualagu-alu-memory-equal-r1.log`). This stage does not improve IPC by
itself; it removes the shared-EA assumption before admitting a V memory lane.

`run-p54-l1d-pair-hit.sh` exercises the default-off `VEN_P54_DUAL_HIT` cache
interface atop `VEN_L1D_BANKED_DATA`. It checks simultaneous distinct-bank
read hits, serialized same-bank hits, width/offset assembly, split-line and
uncached rejection, independent held owner responses, consume/replace, and
flush/snoop cancellation. A legacy write hit must be visible to a subsequent
pair read, plus 32 consecutive two-bank pairs with consume/replace on every
edge and no backing reads. The registered-ACK variant also checks a distinct-bank pair on the
same edge that an older legacy read consumes its captured response; the
`--comb-ack` variant confirms that the live-bank response retains exclusive
ownership until its request leaves. `verif/l1/run-l1axi-pair-hit-micro.sh`
checks six end-to-end wrapper cases, including per-lane memory-type rejection,
U-before-V ordering, and flush cancellation. The sideband is wired through the
top and L1/AXI wrapper. The default core drives request-valid low; the
opt-in checked dual-load configurations below consume lane 1. These leaf
checks alone establish cache/protocol behavior—not paired retirements,
architectural correctness, area, timing, or gameplay throughput. The active
cache banks remain asynchronous distributed RAM; the separate synchronous
eight-bank BRAM leaf is an FPGA organization experiment, not an integrated
latency or area win.

The opt-in `VEN_P54_DUAL_HIT_LEGACY_CAPTURE` lets a fresh, aligned legacy U
hit reserve its word bank while one younger V hit uses a distinct bank on the
same capture edge. A rejected V leaves U unchanged. The captured full-line
window is marked nonreusable when V borrows a bank, so later U reads cannot
see a mixed U/V line. `run-p54-l1d-pair-hit.sh --legacy-capture-pair` and
`verif/l1/run-l1axi-pair-hit-micro.sh --legacy-capture-pair` cover accepted
data/owner, same-bank rejection, window-reuse safety, and no extra AXI read;
default and combinational-ACK controls remain unchanged. This removes a
cache-port obstacle to core U/V memory issue. The fresh-capture core consumer
and its directed IPC/full-state evidence are described above.

The initial, pre-consumer full-core sideband build also matched the preceding dual-AGU build
in 14 pinned-QEMU memory-ALU full-state/cycle cases. Because the core does not
yet issue sideband requests, that historical equality was a no-regression check, not an
IPC improvement or proof of V-memory retirement.
The rebuilt post-overlap binary (`977ad608b74b12efcbe4108ed79f80fc04fc4499533e1257ffb150df9a135eb2`)
also matched all 22 directed fixed-work candidate/control architectural traces
and exact cycle counts at 32 concurrent micro jobs; results are under
`/tmp/p54-dualhit-overlap-core-micro-r1/`.
`run-p54-pair-dtlb.sh` checks the independent V translation lookup on both
direct-mapped and four-way D-TLBs with the existing lookahead port enabled:
pre-fill visibility, three independently addressed query payloads, same-set
way selection, large-page offset, and flush. This is only a side-effect-free
read port; it does not yet authorize V issue, suppress faults, or implement a
second page walker.
The corresponding opt-in full-core build also matched all 22 fixed-work
candidate/control traces and exact cycle counts (`/tmp/p54-pair-dtlb-core-micro-r1/`),
as expected while V sideband admission remains disabled.

`run-p54-l1d-code-buffer.sh` tests `VEN_L1D_CODE_BUFFER` in six cache
configurations, including banked/window/forward/stream variants. Its generated
builds default to `/tmp`; set `P54_CODE_BUFFER_OUTBASE` to an existing directory
on a larger filesystem if the tmpfs quota cannot hold the precompiled headers.
Code reads with the
core's zero-strobe convention stage a separate physical line without touching
the two D ways; it checks data residency, same-address response ownership,
store/snoop/flush invalidation (including mid-fill and terminal-beat snoops),
and golden/noncacheable fallback. The bounded
`run-p54-code-data-collision.py` runs candidate and control full-core binaries
against a synthetic loop with three instruction lines and two data lines in
the same set, then compares their architectural traces. With the banked cache
and historical AXI replay enabled, the code-buffer candidate took **138 vs
150 cycles per 8-instruction loop** and **6 vs 10 AXI ARs per loop**. This is
a directed collision result, not gameplay performance or a general speedup.
The residual two ARs per cache-line read are the platform's default-on replay
policy; do not disable it on the HP/HPC backend solely to improve the number.
`VEN_AXI_READ_TRACE=N` on the simulator prints at most N accepted AXI AR
addresses for a short diagnostic run without changing RTL timing.

`VEN_L1D_CODE_STREAM` (requires the code buffer) allows a later aligned code
word to use the already-landed beat through the registered hit-return window
while the line fill continues. It excludes the original critical-word owner
from a second ACK and honors fill poison, same-edge snoops, and response
identity. The two extra leaf variants test it alone and alongside data
fill-forwarding. Against the non-streaming code-buffer build, the collision
loop improves from **138 to 120 cycles per 8 instructions** with the same six
ARs per loop and equal architectural traces. With deterministic AXI read
latency/gaps (`AXI_RLAT=3 AXI_RGAP=1`), the same A/B is **344.669 versus
308.669 cycles/loop**, also trace-equal. Neither number is gameplay IPC.

The six `resident_memory_{or,adc,sbb,and,sub,xor}` cases specifically compare
the optional checked `VEN_FAST_MEM_ALU` admission against a control that
already has `VEN_FAST_MEM_ADD`/`VEN_FAST_MEM_ADD7`. This matters because the
full-PC default **already enables fast ADD**; a fast-ADD-versus-slow-ADD
microbenchmark is not a new production improvement. All six additional
families improve from **11 to 3 cycles per four-instruction loop** in this
directed L1/AXI profile, while ADD stays at 3 and all 22 candidate/control
architectural traces agree. The separate 14-case pinned-QEMU fixed-work check
(`run-alu-memory-ab.py`, both carry inputs) also passed: each newly admitted
family took 9,570 control versus 8,525 candidate cycles for 2,090
instructions, with full-state equality at 2,441 compared QEMU groups. These
are **not** gameplay IPC or a reason to promote the flag without full-system
and FPGA-timing qualification.
An exhaustive decoder-leaf gate (`verif/issue_uv/run-alu-memory-decode-gate.sh`)
also passes 1,835,008 descriptor comparisons across opcode, ModR/M, SIB,
default-size and cycle-mode combinations; 602,112 are admitted memory forms,
including 28,224 seven-byte forms. It checks operand/address metadata against
the ADD packet and rejects unsafe admitted descriptors. This optional
ADD7/MOV7 leaf profile is broader than the production flag set, not a whole-core
correctness or timing claim.
The same 14-case QEMU A/B also passes with the **raw-byte decoder** (no
uop cache, no seven-byte ADD extension) and banked code-buffer/stream L1:
2,090 fixed-work instructions take 24,530 control versus 18,425 candidate
clocks for each newly admitted operator, while ADD stays at 18,425. All
candidate/control traces match pinned QEMU at complete retirement groups.
The raw profile must omit `VEN_PIPE_MEM_CHAIN` and
`VEN_PIPE_REG_LOAD_PRIME`: the former requires `VEN_UOPCACHE`, and the latter
requires the former. This is independent directed evidence, not gameplay IPC.

The split-page protected-mode fault/retry gate (`run-alu-memory-fault.py`)
also passed all 14 operator/carry cases for both matched binaries in two
profiles. Without `VEN_SYS_FASTLOAD_FLAT`, the gate requires **no** fast memory
owner for the faulting instruction, and each run had one precise #PF, a
successful retry, and full-state equality with 213 QEMU groups. With the
production-like guarded `VEN_SYS_FASTPATH_RELOC`, `VEN_SYS_FASTLOAD_FLAT`,
`VEN_SYS_FASTLOAD_BOUNDED`, and `VEN_SYS_FASTSTORE_FLAT` flags, use
`--fast-system-memory`: the gate requires pre-fault fast ownership for
candidate ALU operations and for control ADD, then checks the same precise
fault/retry and full-state equality with 211 QEMU groups. That second profile
proves this checked fast-path packet survives the split-page #PF; it is **not**
the complete full-PC production configuration or a substitute for the full
system gate. Both diagnostic pairs additionally used `VEN_UOP_CROSSLINE` and
`--public-flat-rw` so the read-only `MEMOWNER` probe survives optimization.
The same guarded fast-system profile also passes `--memory-chain`: an older
independently owned warm load precedes the faulting ALU read in all 14
operator/carry cases. Both binaries have one precise #PF/retry, pre-fault
ownership where admitted, and full-state equality with 218 QEMU groups per
case. This checks one overlapping-memory fault ordering corner, not all
backpressure or interrupt schedules.
The `--fp-overlap` variant additionally passes all 14 cases on a matched
`VEN_FP_ASYNC_STREAM` + `VEN_FP_ASYNC_MEM` profile: the candidate emits a
pending-FP drain at the fault/walk boundary, both models preserve the x87 and
integer state against 221 QEMU groups per case, and the ALU read still has
pre-fault fast ownership. With `VEN_FP_ASYNC_MEM` disabled, the same fixture
matches QEMU but intentionally serializes before the memory access, so it
cannot satisfy the overlap witness. Neither profile is the current full-PC
default, and this is not a broad FP/event qualification.
The matched [FPGA decoder leaf probe](../../fpga/P54_DECODE_LEAF_SYNTH_2026-09-27.md)
measures a five-LUT cost for `VEN_FAST_MEM_ALU` and no material isolated
synthesis timing loss; it does not establish full-core routed timing.
The separate [uop-cache leaf probe](../../fpga/P54_UOPCACHE_LEAF_SYNTH_2026-09-27.md)
measures the much larger cross-line repair cost at the same 45 MHz synthesis
constraint. It excludes core-side cross-pair logic and routed timing.
The [resident slow-decode handoff A/B](P54_SDECODE_DIRECTED_2026-09-27.md)
also passes QEMU-aligned directed windows at all 32 instruction-line offsets
and a separate boundary/snoop guard; it remains default-off and has no
gameplay or routed-FPGA timing result.

The cross-line memory-ALU self-modifying-code fixture
(`verif/issue_uv/t_alu_memory_smc.s`) passes the existing
`run-crossline-smc.py --fast-retire-only` differential runner on the combined
`VEN_FAST_MEM_ALU` + banked code-buffer/stream + executable-repair candidate:
1,221 complete QEMU-equivalent groups and fast retirement in all three
100-iteration phases (original SUB, patched displacement, patched XOR opcode).
The default runner still requires its stronger final descriptor-hit counter;
the alternate-fixture option checks fast retirement without claiming that
specific counter was emitted. Without executable repair the fixture also
matched QEMU, but its crossing instruction stayed on the slow path and did
not qualify the fast-path SMC corner. This remains directed evidence, not
gameplay or full-system acceptance.

`resident_xline_return` (case 30 in `run-p54-ipc-micro.py`) checks the FPGA
bank-zero read-port-sharing experiment against its matched control. The loop
reads an unaligned crossing dword, then word zero of each resident line. The
31-case A/B had full architectural trace equality and exact cycle equality;
this case took 5.000 cycles per five-instruction iteration in both builds.
The isolated L1D and paired-owner suites additionally cover crossing data,
first-line reuse rejection and U/V ownership. See the matched
[L1D synthesis report](../../fpga/P54_L1D_LEAF_SYNTH_2026-09-27.md) for FPGA
resource/timing evidence and the remaining gameplay qualification caveat.

The next two cases isolate L1 fill overlap without changing cache size or
instruction work. `resident_hit_under_fill` (31) thrashes three same-set
lines, then reads a resident different-set line while the last fill drains.
`landed_word_forward` (32) reads the next word of a newly filling line before
starting the other misses. Use `--iterations 400 --jobs 32` with a matched
`--control` binary for the bounded cycle A/B. Passing `--qemu` with the pinned
QEMU binary and `--qemu-cases resident_hit_under_fill landed_word_forward`
additionally emits functional
RTL traces and checks their complete architectural state against QEMU; the
driver seeds RTL's initial ESP from the QEMU trace, rather than incorrectly
comparing two different process stacks.

In the September 28 banked and packed storage A/B runs, fill-forward alone
reduced case 32 from **62 to 60 cycles per six-instruction iteration**;
case 31 stayed at 63. Enabling hit-under-fill as well reduced case 31 from
**63 to 60**, with case 32 still at 60. All 33 candidate/control traces
matched architecturally, and the other 31 cases had identical cycles. Both
new cases matched **2,409** pinned-QEMU records each in functional mode for
the FF-only builds. Artifacts are in
`/home/yukidama/ventium-background-sep28.B3cxzoKA/p54_{huf_ff,ff_only,packed_ff}_ab/`.
These loops deliberately overrepresent cache misses; their IPC is directed
performance evidence, **not measured gameplay IPC**. The matched
[FPGA leaf report](../../fpga/P54_L1D_LEAF_SYNTH_2026-09-27.md) finds FF
area-favorable in both storage layouts, but hit-under-fill expensive. Neither
option has yet passed full-PC cold boot, Win95, Quake or routed timing on the
exact candidate, so neither was added to a release define set.

## Measured-profile-matched IPC development (September 28)

`make -C ao486-sim ven-gameplay-base` now rebuilds the **exact 85 effective
defines** of the measured `229c4cd5` Quake binary, against current sources.
`make -C ao486-sim ven-ipc` adds only 11 cache/dual-load/branch-prime defines
in a separate object directory. The inventory comparison with
`obj_dir_p54_structural_sep27/model/Vsystem__verFiles.dat` has zero missing or
extra defines for the matched base. In particular both builds retain ao486
single-fill, downstream critical-word streaming, x87 overlap, REP acceleration,
and the original 8 KiB P5 L1 geometry. The experimental binary cannot restore
native snapshots made by the historical binary; it must cold-boot a private
disk. Neither target changes the conservative `ven` or the FPGA release set.

The matched-source full-P5 `l1axi_kv_full` A/B, built with these exact base and
candidate define inventories, passed all 33 cases at 400 iterations and 32
simulator jobs: **12 faster, 21 unchanged, 0 slower**, with full
candidate/control architectural trace equality. Ten selected cases matched
**21,288** pinned-QEMU architectural groups, including dual loads, post-store
loads, FP/integer overlap, terminal branch reversals, cross-line return and
fill overlap. Directed examples: distinct-bank loads **4→2**, same-bank loads
**4→3**, target branch plus load **6→4** clocks/iteration. Artifacts are under
`/home/yukidama/ventium-background-sep28.B3cxzoKA/p54_ipc_matched_ab/`.
The separate matched-source code/data set-collision witness took **135→113**
cycles per fixed eight-instruction loop, with identical architectural traces
(`/tmp/p54-code-data-collision-qx_p4r2w/`). This synthetic collision workload
is not representative gameplay IPC.
The current-source matched control binary SHA-256 is
`5fb608a1cf8ca51a9d8cd80c57110f2f2c1fc7fee9d64585b0d639c1310d20d8`;
the corrected candidate is
`1c042ed92c62198cbb44b2e290e46839095be59180f3b2d246cd557174ed83f4`.
Cold Win95 and Quake runs on the corrected candidate are in
`win95_ipc_matched/` and `quake_ipc_matched/`, one CPU each. Their outcomes
and gameplay IPC are **not yet known**. This is not full verification or
routed-FPGA timing evidence.

The earlier `c415fcee...` preliminary build and its
`p54_ipc_combined_{ab,qemu}/`, `p54_ipc_fp_ab/`, and `fp_overlap_combined.log`
artifacts used the conservative `ven` define base. It omitted **54** defines
present in the measured gameplay build, including single-fill and the FP
queue. Its 22 faster directed loops and the separate FP loop's 8→6 result
remain local diagnostics, **not a gameplay-comparable A/B**. Its two cold jobs
were stopped at approximately 123M/124M clocks after the mismatch was found;
they are not boot or gameplay evidence. The preliminary 12-case FP overlap
gate also failed its existing FADD/FMUL-memory savings requirements, despite
architectural equality and observed concurrent integer retirement. Retain
that failure; do not reinterpret the single faster loop as a gate pass.
