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
| `dual_store_{distinct,same}_bank` | Are two store admissions possible while preserving order and the two-entry write-buffer limit? Both cases cross cache lines. |
| `resident_memory_alu` / `register_alu_control` | Does a resident ALU-memory instruction retain its P54 resource occupancy instead of accidentally collapsing to register-ALU timing? |
| `fp_integer_overlap` / `integer_only_control` | Can independent integer work proceed while a real x87 arithmetic operation is outstanding? The integer control has a nonpairable leading EAX dependency so a freely-paired NOP cannot fake a larger FP penalty. |
| `frontend_{aligned,line_straddle}` | Do resident raw instruction bytes cross a 32-byte I-line without persistent decoded-cache repair stalls? |
| `resident_{same_line,two_line}_loads` | Does the registered D-cache window serve a later hit in the same physical line without a second capture, and does a different line correctly require its own lookup? |
| `register_u_memory_v` / `memory_u_register_v` | Can an independent V load issue when U has no memory operand, contrasted with the existing U-load/V-register case? |
| `memory_alu_integer_v` | Does a resident ALU-memory U retain its execution occupancy while an independent integer V follows? |
| `resident_memory_{or,adc,sbb,and,sub,xor}` | Does the checked register-destination memory-ALU admission avoid recurring slow fetch/decode/load FSM visits without changing full architectural state? ADD is the separate `resident_memory_alu` control. Carry operators retain their real CF dependency. |

These cases expose bottlenecks, not the full acceptance matrix. They do not
cover paging/TLB geometry, dirty-line coherence, precise faults, interrupts,
or SIR-dependent FP values. Add dedicated short fixtures for those mechanisms
as their replacement interfaces land. In particular, a faster distinct-bank
case is **not** by itself proof of two memory retirements per clock: inspect
the cycle trace and the accepted owner records before claiming dual issue.

`run-p54-bank-arb.sh` is a bounded leaf test for the proposed eight-bank
admission rule: physical `[4:2]` conflicts, unaligned/64-bit extents, split-line
fallback, bank backpressure, and U-before-V priority. It exhausts all 16,384
line-offset/width pairs, then runs 32,768 randomized cases per seed. The leaf is not connected
to the current single-port core; passing it cannot claim V-memory pairing or
any gameplay speedup.

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

`run-p54-l1d-pair-hit.sh` exercises the default-off `VEN_P54_DUAL_HIT` cache
interface atop `VEN_L1D_BANKED_DATA`. It checks simultaneous distinct-bank
read hits, serialized same-bank hits, width/offset assembly, split-line and
uncached rejection, independent held owner responses, consume/replace, and
flush/snoop cancellation. A legacy write hit must be visible to a subsequent
pair read. The interface is not connected to the core's EA/DTLB/issue path,
so these results establish cache-local behavior only—not paired retirements,
architectural correctness, area, timing, or gameplay throughput.

`run-p54-l1d-code-buffer.sh` tests `VEN_L1D_CODE_BUFFER` in four cache
configurations, including banked/window/forward variants. Code reads with the
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
The matched [FPGA decoder leaf probe](../../fpga/P54_DECODE_LEAF_SYNTH_2026-09-27.md)
measures a five-LUT cost for `VEN_FAST_MEM_ALU` and no material isolated
synthesis timing loss; it does not establish full-core routed timing.

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
