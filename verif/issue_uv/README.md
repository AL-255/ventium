# `verif/issue_uv` — Superscalar U+V Pairing, AGI Interlocks, and x87 Issue Verification

## Scope and Architectural Invariants

`verif/issue_uv/` verifies Ventium's Intel Pentium (P5/P54C, AP-500) hardwired dual-issue
integer pipeline, AGI (Address Generation Interlock) hazard detection, memory-operand
fast-path admission, prefix-`D1` overlap, and shared-x87 command/operand issue:

- **AP-500 Dual-Issue Integer Pairing (`rtl/core/issue_uv.sv`, `u_pipe.sv`, `v_pipe.sv`,
  `uv_common.sv`, `ven_p54_dual_agu.sv`):**
  - Enforces hardwired `UV` / `PU` / `PV` / `NP` pairing classes, GPR RAW/WAW hazard checks
    (including implicit `ESP` stack-pointer dependencies and high-byte `AH..BH` parent-GPR
    aliasing), U-to-V arithmetic flag forwarding (`CMP`/`ADD`/`SUB` paired with `Jcc`), and
    dual-port memory pairing (`VEN_P54_DUAL_LOAD_PAIR`, `VEN_P54_LOAD_STORE_PAIR`,
    `VEN_P54_DUAL_STORE_PAIR`, `VEN_P54_DUAL_READ_ALU_PAIR`).
- **AGI & Prefix Turnaround (`VEN_P54_AGI_WRITE_MASK`, `VEN_P54_SDISPATCH_AGI`,
  `VEN_P54_PREFIX_AGI`, `VEN_P54_PREFIX66_REG`, `VEN_P54_PREFIX_EX_CHAIN`):**
  - Tracks exact prior-clock register writers for 1-cycle P5 AGI stalls, overlaps
    single-prefix `D1` work with multi-cycle `EX` / AGI clocks per Intel AP-500 §5.5, and
    retains a 33-bit paid-`D1` token (`{valid, owner_pc}`) for `0x66` operand-size-prefixed
    fast instructions.
- **Fast Memory ALU & Control Turnaround (`VEN_FAST_MEM_ALU`, `VEN_FAST_MEM_ADD7`,
  `VEN_FAST_BYTE_MEM_CMP`, `VEN_P54_MOV_ACK_RETIRE`, `VEN_P54_CTRL_TARGET_READ`,
  `VEN_PIPE_MEM_CHAIN`):**
  - Admits checked 6- and 7-byte memory-source integer ALU ops
    (`ADD`/`OR`/`ADC`/`SBB`/`AND`/`SUB`/`XOR`/`CMP`), retires plain `MOV` loads on source
    `ACK` (1 `EX` clock per Intel Vol. 3 while preserving 2 `EX` clocks for `CMP`/`TEST`),
    steers I-cache BRAM read ports early on slow near `RET`/`CALL`/`JMP`, and chains
    resident memory reads.
- **Shared-x87 Issue & Queuing (`VEN_FP_MEM_ADMIT`, `VEN_FP_MEM_QUEUE`, `VEN_FP_LOAD64`,
  `VEN_FP_REG_ADMIT`, `VEN_FP_ARITH_FWD`, `VEN_FP_SHARED_EARLY_CMD`,
  `VEN_FP_OPERAND_OVERLAP`):**
  - Governs direct `S_PIPE` x87 register/memory command admission, zero-cycle `FXCH` rename
    queuing (`ven_fp_fxch_queue`), single-beat resident `m64` operand transport, and
    non-cacheable debug/device ownership safety.

### Mandatory Subsystem Invariants

1. **Mandatory `U/V + Fast-Pipe` Qualification:** Performance and repair acceptance require
   `cycle_mode = 1'b1` with active U+V pairing and system fast-paths (`S_PIPE`), excluding
   `STEP` or intended-V breakpoints that suppress pairing. Because legacy `.vtrace` cycle
   rows default missing pipe tags to `U`, always verify explicit `VEN_PIPE_RETIRE_WITNESS=1`
   or hardware V-retirement counters.
2. **Compile-Time Option Compatibility:** `VEN_P54_PREFIX66_REG` requires raw live decode
   and `$fatal`s at elaboration if combined with `VEN_UOPCACHE`. `VEN_FP_OPERAND_OVERLAP`
   requires `VEN_FP_MEM_ADMIT`.
3. **Precise Faults & MMIO Ownership:** Memory-ALU, paired-store, and asynchronous x87 paths
   must preserve probe-before-write `#PF`/`#GP`/`#SS` restart semantics, clean bus
   cancellation across `SMI#`/faults (`tb_bus_cancel_payload.sv`), and single-read MMIO
   ownership under debugger park (`tb_fp_operand_debug_owner.sv`).

---

## Feature & Experiment Status

> **Physical Gameplay Baseline (`c0e3fe43`):** Verified physical Quake gameplay IPC on
> board-qualified image `c0e3fe43` (`main`, 161 defines, 40.000 MHz) is **`0.515778001`
> total U+V** (`0.397847833` primary/U-only; counters include `REP`-element retirement)
> across cycles **`28,696,827,616–32,989,404,795`** (`506,223,958` paired V retirements).
> Experimental-branch candidates remain unmeasured relative to this baseline until verified
> on hardware.

| Sub-Area | Deployed in `c0e3fe43` (`main`) | Experimental / Opt-In (`experimental/uv-fast-ipc-apr`) | Rejected / Removed |
| --- | --- | --- | --- |
| **Integer U+V Pairing & Fast ALU** | `issue_uv` AP-500 pairer + `ven_p54_dual_agu`, `VEN_FAST_MEM_ADD` / `ADD7` / `ALU` / `ADC`, `VEN_FAST_BYTE_MEM_CMP`, `VEN_FAST_ROR_IMM`, `VEN_FAST_XCHG_R`, `VEN_FAST_UNARY_R`, `VEN_REP_STOS_STREAM` | Opt-in `+define+VEN_FAST_BYTE_MEM_CMP` / `VEN_FAST_MEM_ALU` in non-FPGA user-mode builds | Standalone `V_LOAD_PAYLOAD` unplaced-timing cut |
| **Memory Pairing, AGI & Prefix Overlap** | `VEN_P54_DUAL_LOAD_PAIR`, `VEN_P54_DUAL_BYTE_LOAD_PAIR`, `VEN_P54_DUAL_READ_ALU_PAIR`, `VEN_P54_LOAD_STORE_PAIR`, `VEN_P54_DUAL_STORE_PAIR`, `VEN_P54_INT_EXEC_OCC`, `VEN_P54_SDISPATCH_AGI`, `VEN_P54_PREFIX_AGI`, `VEN_P54_AGI_WRITE_MASK`, `VEN_P54_PREFIX66_REG` / `SYSTEM`, `VEN_P54_PREFIX_EX_CHAIN` / `SYSTEM`, `VEN_P54_MOV_ACK_RETIRE`, `VEN_P54_CTRL_TARGET_READ` / `SYSTEM`, `VEN_PIPE_MEM_CHAIN`, `VEN_PIPE_SDISPATCH` / `SHORT`, `VEN_STORE_DISPATCH` | Unapplied `proposals/` held-store-to-resident-read handoff drafts; `proposals/tb_p54_prior_write_mask.sv` | — |
| **Shared-x87 Issue & Overlap** | `VEN_FP_SHARED`, `VEN_FP_FXCH_QUEUE`, `VEN_FP_MEM_ADMIT`, `VEN_FP_MEM_LOADS`, `VEN_FP_MEM_QUEUE`, `VEN_FP_LOAD64`, `VEN_FP_REG_ADMIT`, `VEN_FP_ARITH_FWD`, `VEN_FP_SHARED_EARLY_CMD`, `VEN_FP_LOAD_EARLY_CMD`, `VEN_FP_STORE_EARLY_CMD`, `VEN_FP_OPERAND_OVERLAP`, `VEN_FP_*_PAYLOAD_SELECT` | `make verify-fp-integer-overlap` & `make verify-fp-trace-pending` (explicit multi-cycle FP/integer overlap diagnostics; red on serialized shared-FPU completion seam) | `VEN_FP_INT_OVERLAP` (co-retiring one integer op on the FP completion edge — broke natural next-cycle U+V pairs with zero cycle gain; removed from RTL) |

---

## Active Testbenches and Gate Scripts

| Gate Family | Representative Scripts | Primary Testbenches |
| --- | --- | --- |
| **Canonical U+V Pairer (`make issue-uv`)** | `run-issue-uv-gate.sh` (invoked automatically by `make verify`), `run-uv-shift-flags.sh`, `run-ror-fast-gate.sh`, `run-cl-execution-latency.sh`, `run_carry_rotate_tree.py`, `run_u_alu_shared.py`, `run_u_shift_registers.py`, `run_v_result_carry_leaf.py` | `tb_issue_uv.sv`, `tb_uv_shift_flags.sv`, `tb_ror_fast.sv`, `tb_cl_shift_decode.sv`, `tb_carry_rotate_tree.sv`, `tb_u_alu_shared.sv`, `tb_u_shift_registers.sv`, `tb_v_result_carry.sv` |
| **Memory Pairing, AGI & Prefix66** | `run-alu-memory-decode-gate.sh`, `run-byte-memory-cmp-leaf.py`, `run-dual-read-alu-core-gate.sh`, `run-dual-store-core-gate.sh`, `run-issue-store-pair-gate.sh`, `run-regmem-prime-pair-gate.sh`, `run-mem-chain-policy-gate.sh`, `run-p54-agi-write-mask.sh`, `run-p54-ctrl-target-read.sh`, `run-p54-prefix66-reg.sh`, `run-prefix-ex-chain.sh`, `run-mov-ack-retire.sh`, `run-int-exec-occupancy.sh`, `run-load-issue-ipc.sh` | `tb_alu_memory_decode.sv`, `tb_byte_memory_cmp.sv`, `tb_issue_store_pair.sv`, `tb_regmem_prime_pair.sv`, `tb_mem_chain_policy.sv`, `tb_p54_agi_write_mask.sv`, `tb_p54_ctrl_target_read.sv`, `tb_p54_mov_ack_retire.sv`, `tb_int_exec_occupancy.sv` |
| **x87 Issue, Debug & Fragment Cancel** | `run-fp-memory-decode-gate.sh`, `run-fp-memory-fault-gate.sh`, `run-fp-load-regressions.sh`, `run-fp-load-command-regressions.sh`, `run-fp-misc-response.sh`, `run-fp-operand-debug-owner-gate.sh`, `run-fp-reg-admit-unit.py`, `run_fp_load_payload_leaf.py`, `run_bus_cancel_payload.py`, `run_fragment_exact_reads.py` | `tb_fp_memory_decode.sv`, `tb_fp_operand_debug_owner.sv`, `tb_fp_reg_admit.sv`, `tb_fp_load_payload.sv`, `tb_bus_cancel_payload.sv`, `tb_fragment_exact_reads.sv`, `tb_fragment_read_payload.sv` |

---

## Safe Execution Guidelines

- Always set `TMPDIR=/home/yukidama/external/tmp` and build inside private object
  directories (`-Mdir` / `*_OBJDIR`) under `tools/build_scope.sh`; never overwrite canonical
  `verif/tb/obj_dir`.
- Pass `--l1-axi` explicitly whenever executing a `+define+VEN_L1_AXI` full-core binary.

```bash
# Run the canonical U+V decoder/pairer gate:
TMPDIR=/home/yukidama/external/tmp VERILATOR=/tools/verilator/v5.046/bin/verilator make issue-uv

# Run focused AGI write-mask, MOV-ACK retirement, and x87 NC debug-ownership gates:
TMPDIR=/home/yukidama/external/tmp VERILATOR=/tools/verilator/v5.046/bin/verilator \
  bash verif/issue_uv/run-p54-agi-write-mask.sh
TMPDIR=/home/yukidama/external/tmp VERILATOR=/tools/verilator/v5.046/bin/verilator \
  bash verif/issue_uv/run-mov-ack-retire.sh
TMPDIR=/home/yukidama/external/tmp VERILATOR=/tools/verilator/v5.046/bin/verilator \
  bash verif/issue_uv/run-fp-operand-debug-owner-gate.sh
```
