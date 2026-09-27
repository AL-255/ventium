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

| Cases | Exact structural question from the [P54 plan](../../docs/P54_SUB1_CPI_MASTER_PLAN_2026-09-27.md) |
| --- | --- |
| `reg_load_prime` | Can an independent register packet lend its idle D-cache lookup cycle to the next load, eliminating the registered-hit capture bubble? The load alternates resident lines to defeat same-line window reuse. |
| `dual_load_{distinct,same}_bank` | Can two independent loads from different lines overlap when their physical `[4:2]` bank indices differ, and does the same-bank case correctly serialize? |
| `dual_store_{distinct,same}_bank` | Are two store admissions possible while preserving order and the two-entry write-buffer limit? Both cases cross cache lines. |
| `resident_memory_alu` / `register_alu_control` | Does a resident ALU-memory instruction retain its P54 resource occupancy instead of accidentally collapsing to register-ALU timing? |
| `fp_integer_overlap` / `integer_only_control` | Can independent integer work proceed while a real x87 arithmetic operation is outstanding? The integer control has a nonpairable leading EAX dependency so a freely-paired NOP cannot fake a larger FP penalty. |
| `frontend_{aligned,line_straddle}` | Do resident raw instruction bytes cross a 32-byte I-line without persistent decoded-cache repair stalls? |

These cases expose bottlenecks, not the full acceptance matrix. They do not
cover paging/TLB geometry, dirty-line coherence, precise faults, interrupts,
or SIR-dependent FP values. Add dedicated short fixtures for those mechanisms
as their replacement interfaces land. In particular, a faster distinct-bank
case is **not** by itself proof of two memory retirements per clock: inspect
the cycle trace and the accepted owner records before claiming dual issue.

`run-p54-bank-arb.sh` is a bounded leaf test for the proposed eight-bank
admission rule: physical `[4:2]` conflicts, unaligned/64-bit extents, split-line
fallback, bank backpressure, and U-before-V priority. It runs directed cases
plus 32,768 independent randomized cases per seed. The leaf is not connected
to the current single-port core; passing it cannot claim V-memory pairing or
any gameplay speedup.

`run-p54-hit-return.sh` tests a two-slot owner-tagged hit-return prototype. It
accepts two distinct-bank hits per clock, holds each owner/data pair under
independent response backpressure, permits consume-and-replace, blocks V behind
an unaccepted U, and cancels both slots on flush. This is still a leaf contract,
not an integrated cache or an architectural correctness gate.
