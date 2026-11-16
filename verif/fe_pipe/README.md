# `verif/fe_pipe` — Front-End Translation Cut, Resident Fetch, and Priming Verification

## Scope and Architectural Invariants

`verif/fe_pipe/` verifies front-end translation decoupling (`VEN_FE_PIPE`), multi-page
instruction fetch authorization, resident I-cache/D-cache read priming, short-window
instruction capture, and scalar x87 front-end dispatch handoffs:

- **Registered Front-End Page Filters (`VEN_FE_PIPE`, `VEN_FE_DTLB_MULTI`,
  `VEN_FE_DTLB_PERM`):**
  - Page-keyed micro-TLB slices (`ven_fe_dtlb` / `u_fe_itlb` / `u_fe_dtlb`) break
    combinational critical paths between `S_PF` / `S_PIPE` / `S_FETCH` linear address
    generation and the 4-way parent I-TLB / D-TLB lookup cones.
  - Page-crossing or cold-page transitions pay a deterministic 1-cycle `fe_xlate_pend` hold
    while squashing bus requests cleanly on the stall clock.
- **Multi-Page Fetch & Short-Window Capture (`VEN_IFETCH_AUTH_MULTI`, `VEN_SFETCH_RESIDENT`,
  `VEN_SFETCH16_DEMAND`, `VEN_RET_SHORT_WINDOW`, `VEN_FP_SHORT_WINDOW`):**
  - Authorizes sequential fetch spans across resident I-cache ports and captures
    exact-length near-`RET`, x87, and 16-bit real/protected instructions without waiting for
    trailing unused words.
- **Resident Data-Read Priming (`VEN_RAW_AGI_PRIME`, `VEN_RAW_HELD_READ_PRIME`,
  `VEN_RAW_V_READ_PRIME`, `VEN_RAW_BRANCH_FALLTHROUGH_PRIME`, `VEN_REF_OPERAND_PRIME`,
  `VEN_PIPE_REG_LOAD_PRIME`):**
  - Launches non-mutating cache-resident D-side read lookups during paid AGI stalls, held
    read retirements, untaken branch fallthroughs, or reference-decode dispatch edges.
- **Shared-x87 Scalar Handoffs (`VEN_FP_SCALAR_DISPATCH`, `VEN_FP_SCALAR_LOAD_CMD`,
  `VEN_FP_POP_DRAIN`, `VEN_FP_MEM_QUEUE64`, `VEN_FP_ARITH_MEM_FWD`):**
  - Removes decode, operand-handoff, and popping-drain bubbles for scalar x87 register and
    `m32`/`m64` memory instructions.

### Mandatory Subsystem Invariants

1. **Strict Parent-to-Child TLB Invalidation:** Every parent D-TLB or I-TLB fill/replacement
   and every architectural TLB flush (`MOV CR3`, paging/protection-changing `MOV CR0`/`CR4`,
   `INVLPG`, task-switch `CR3` commit, `RSM`) **must** invalidate all child `ven_fe_dtlb` /
   `u_fe_itlb` entries on the same clock edge.
2. **Live Access-Policy Evaluation (`VEN_FE_DTLB_PERM`):** Child translation entries cache
   only raw PTE/PDE `{US, RW, P}`, physical PFN, hit, and dirty state — **never**
   pre-evaluated access success, `CPL`, write intent, or `CR0.WP`. Live privilege and
   segment-identity checks remain separated so the `cur_seg_rel -> acc_usr -> perm_fault ->
   bus` combinational loop is never reintroduced.
3. **Dual-Issue Read Ownership (`PRIME_PAIR_OWNER`):** A primed U-pipe read must never
   orphan or mis-acknowledge a paired V-pipe load response, and priming must never speculate
   uncacheable/MMIO reads or mask precise `#PF`/`#GP`/`#SS` exceptions.
4. **Fragment-Engine Authority:** Page-straddling accesses freeze shaping during `S_WALK`
   and are owned exclusively by the canonical fragment engine (`cur_lin_nat`), never
   bypassed by front-end page filters.

---

## Feature & Experiment Status

> **Physical Gameplay Baseline (`c0e3fe43`):** Verified physical Quake gameplay IPC on
> board-qualified image `c0e3fe43` (`main`, 161 defines, 40.000 MHz) is **`0.515778001`
> total U+V** (`0.397847833` primary/U-only; counters include `REP`-element retirement)
> across cycles **`28,696,827,616–32,989,404,795`**. Unmeasured experimental-branch builds
> do not inherit this baseline.

| Sub-Area | Deployed in `c0e3fe43` (`main`) | Experimental / Harness (`experimental/uv-fast-ipc-apr`) | Rejected Timing / Priming Cuts |
| --- | --- | --- | --- |
| **Front-End Translation Cut** | `VEN_FE_PIPE`, `VEN_FE_DTLB_MULTI`, `VEN_FE_DTLB_PERM`, 32-entry 4-way `u_fe_itlb` (`VEN_ITLB_ASSOC_4WAY`) + multi-entry `u_fe_dtlb` | `prototype/ven_fe_dtlb.sv`, `banked/`, `permission/`, `physical/` isolated harnesses; explicit `+define+VEN_FE_PIPE` + `-DVEN_XOVER_FE_PIPE` in `verif/tb/Makefile` | Single-entry unbanked D-side cut (32–33% warm-loop cliff above 1–8 hot pages) |
| **Fetch, Prefix & Control Turnaround** | `VEN_IFETCH_AUTH_MULTI`, `VEN_SFETCH_RESIDENT`, `VEN_SFETCH16_DEMAND`, `VEN_RET_SHORT_WINDOW`, `VEN_P54_PREFIX66_SYSTEM`, `VEN_P54_PREFIX_EX_SYSTEM`, `VEN_P54_CTRL_TARGET_SYSTEM`, `u_ibuf_decode_stages` split | `system-dispatch.patch` (`run-system-dispatch.py`) | `FETCH_FRAGMENT_EXTENT` (34.18 MHz unplaced), `FETCH_METADATA_OWNER` (36.03 MHz), `PREFIX_OPCODE` (35.14 MHz, +2,566 LUTs), `PREFIX_MEM_PAYLOAD` (failed prefix-boundary gate), `SFETCH_BOUNDARY_STAGE`, `SFETCH_INTERIOR_COFACTOR` |
| **Resident Read Priming** | `VEN_RAW_AGI_PRIME`, `VEN_RAW_HELD_READ_PRIME`, `VEN_RAW_V_READ_PRIME` (with pair-owner fix), `VEN_RAW_BRANCH_FALLTHROUGH_PRIME`, `VEN_REF_OPERAND_PRIME`, `VEN_PIPE_REG_LOAD_PRIME` | Isolated leaf/fault/event drivers (`run-agi-prime-*.py`, `run-raw-branch-*.py`) | Pre-repair `RAW_V_READ_PRIME` without paired-V ownership tracking |
| **x87 Front-End / Scalar Handoffs** | `VEN_FP_SHORT_WINDOW`, `VEN_FP_SCALAR_DISPATCH`, `VEN_FP_SCALAR_LOAD_CMD`, `VEN_FP_POP_DRAIN`, `VEN_FP_MEM_QUEUE64`, `VEN_FP_ARITH_MEM_FWD`, `VEN_FP_RESIDENT_PRIME` | Standalone unit/event harnesses (`run-fp-scalar-*.py`, `run-fp-short-*.py`) | Standalone `FP_RESIDENT_PRIME` without `FP_ARITH_MEM_FWD` (zero steady-state gain alone) |

---

## Active Testbenches and Gate Scripts

| Verification Area | Runner Scripts | Testbenches / Fixtures |
| --- | --- | --- |
| **Front-End Micro-TLB & Permissions** | `run-leaf.sh`, `permission/run-leaf.sh`, `permission/run-core.py`, `banked/run-leaf.sh`, `run-capacity.py` | `tb_fe_dtlb.sv`, `permission/tb_fe_dtlb_perm.sv`, `permission/tb_fe_parent_perm.sv`, `banked/tb_fe_banked.sv`, `capacity.S` |
| **Multi-Page Fetch & Prefix/Target Guards** | `run-ifetch-auth-leaf.py`, `run-ifetch-auth-fault.py`, `run-prefix66-system-token.py`, `run-prefix-ex-regonly.py`, `run-prefix-ex-system-guards.py`, `run-system-target-leaf.py`, `run-ret-short-window.py`, `run-sfetch16-demand.py` | `tb_ifetch_auth_multi.sv`, `tb_prefix66_system_token.sv`, `tb_prefix_ex_regonly.sv`, `tb_prefix_ex_system_guards.sv`, `tb_system_target_read.sv`, `tb_ret_short_window.sv` |
| **Resident Data Priming** | `run-held-read-prime-leaf.py`, `run-raw-branch-guards.py`, `run-raw-branch-mov.py`, `run-agi-resident-prime.py`, `run-prime-pair-owner.py`, `run-prime-under-fill-leaf.py`, `run-ref-operand-prime.py` | `tb_held_read_prime.sv`, `tb_raw_branch_guards.sv`, `tb_raw_branch_mov.sv` |
| **Shared-x87 Scalar & Short-Window** | `run-fp-pop-drain-unit.py`, `run-fp-scalar-dispatch-leaf.py`, `run-fp-scalar-load-leaf.py`, `run-fp-short-window-unit.py`, `run-fp-mem64-queue.py`, `run-fp-memory-forward.py` | `tb_fp_pop_drain.sv`, `tb_fp_scalar_dispatch.sv`, `tb_fp_scalar_load_cmd.sv`, `tb_fp_short_window.sv` |

---

## Safe Execution Guidelines

- Always export `TMPDIR=/home/yukidama/external/tmp` and compile into private scratch/object
  directories; never overwrite canonical `verif/tb/obj_dir` or replace
  `experimental/uv-fast-ipc-apr` working RTL with release snapshots.
- Any out-of-context Vivado timing probe (`physical/run_synth.py`,
  `permission/physical/run_synth.py`, `banked/physical/run.py`) must check process ownership
  first and run exclusively via `fpga/run_vivado_exclusive.sh`.

```bash
# Run deterministic front-end D-TLB, permission, and banked-slice leaf gates:
TMPDIR=/home/yukidama/external/tmp VERILATOR=/tools/verilator/v5.046/bin/verilator \
  bash verif/fe_pipe/run-leaf.sh
TMPDIR=/home/yukidama/external/tmp VERILATOR=/tools/verilator/v5.046/bin/verilator \
  bash verif/fe_pipe/permission/run-leaf.sh
TMPDIR=/home/yukidama/external/tmp VERILATOR=/tools/verilator/v5.046/bin/verilator \
  bash verif/fe_pipe/banked/run-leaf.sh
```
