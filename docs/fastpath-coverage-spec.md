# AP-500 Fast-Path (`S_PIPE`) Coverage Spec

> **Current Status (Nov 2026 — IMPLEMENTED & EXPANDED in `c0e3fe43`):** Beyond the initial June 2026 register-only decode batches (Batches 1–4 below), Ventium's `S_PIPE` fast path (`rtl/core/decode.sv`, `rtl/core/issue_uv.sv`, `rtl/core/core_fastpath.svh`, `rtl/core/ven_p54_dual_agu.sv`) now executes **protected-mode flat, relocated, and segment-bounded fast loads/stores** (`VEN_SYS_FASTPATH*`), **`PUSH`/`POP`**, **general ModR/M + SIB memory `MOV`/`ALU`/`LEA`/`CMP`/`TEST`**, **byte and `0x66` 16-bit register forms**, **1-cycle fast-path `MOVZX`/`MOVSX` loads** (kept `NP` per AP-500), **pipelined `REP STOS` cacheable store streaming** (`VEN_REP_STOS_STREAM`), and **overlapped x87 + zero-cycle `FXCH` queueing** (`VEN_FP_ASYNC_STREAM` + `VEN_FP_FXCH_QUEUE`).
>
> **Verified Physical Result (`c0e3fe43`):** **`0.515778001` total U+V IPC** (`0.397847833` primary/U-only IPC, including `REP`-element retirement; `506,223,958` paired V retirements) across interior DOS Quake gameplay cycles `28,696,827,616–32,989,404,795` at `40.000 MHz` (`40.264133 MHz` STA sign-off).

---

## 1. Architecture of Fast-Path Decode & Dual Issue

1. **Dual-Slot Fast Decoder (`rtl/core/decode.sv`):** Decodes up to two sequential x86 instructions per cycle into `fpd_t` descriptors (`FK_*` fast-path kinds) with AP-500 pairing classes (`pairs_first` for U-lead `UV`/`PU`, `pairs_second` for V-eligible `UV`/`PV`, or `NP` single-issue fast execution). Instructions outside `decode.sv`'s fast surface set `simple = 0` and dispatch cleanly through `decode_stages.sv` and the multi-cycle `core.sv` FSM.
2. **AP-500 Pairing Checker (`rtl/core/issue_uv.sv`):** Enforces canonical Intel AP-500 §5.6 rules (see [`ap500-pairing-table.md`](ap500-pairing-table.md)):
   - U-pipe compatibility (`UV` or `PU`) + V-pipe compatibility (`UV` or `PV`);
   - Full-GPR RAW and WAW hazard blocking (byte/word sub-registers contend on their containing 32-bit GPR; WAR anti-dependence permitted; dual EFLAGS writers permitted with V-pipe flags winning);
   - AP-500 §5.6.4 special pairs: implicit `ESP` contention exempted for `PUSH`/`PUSH`, `PUSH`/`CALL`, and `POP`/`POP`; `CMP`/`ALU` + `Jcc` flag forwarding via `uv_common.sv`;
   - Displacement + immediate exclusion and dual-AGU / 8-bank L1D (`ven_p54_dual_agu.sv` + `ven_p54_bank_arb.sv`) address generation.
3. **System & Paging Fast-Path Safety (`core_fastpath.svh`):** Under `VEN_SYS_FASTPATH`, `VEN_SYS_FASTPATH_RELOC`, `VEN_SYS_FASTLOAD_FLAT`, and `VEN_SYS_FASTSTORE_FLAT`, `S_PIPE` executes directly in 32-bit protected/paged mode (including non-zero segment bases and limit checks), diverting to the fragment/page-walk/fault engine whenever an access crosses a 4 KiB page boundary, misses `fe_dtlb_q`/`fe_itlb_q`, hits a debug watchpoint, or faults.

---

## 2. Implemented Fast-Path Instruction Surface

| Category | Fast-Path Coverage (`decode.sv` & `core_fastpath.svh`) | Pairing Class |
| --- | --- | --- |
| **Register & Immediate `MOV` / `ALU`** | `MOV r,r/imm` (`88`–`8B`, `B0`–`BF`, `C6`/`C7 /0`), `ADD`/`OR`/`ADC`/`SBB`/`AND`/`SUB`/`XOR`/`CMP` reg/imm8/imm32/accum (`00`–`3D`, `80`/`81`/`83`), `INC`/`DEC r` (`40`–`4F`), `TEST` reg & accum (`84`/`85`, `A8`/`A9`), `NOP` (`90`), including byte and `0x66` 16-bit reg forms (`VEN_P54_PREFIX66_REG`). | `UV` (`ADC`/`SBB` = `PU`) |
| **Memory Loads, Stores & `LEA`** | General ModR/M + SIB + disp8/disp32 `MOV` loads/stores, `LEA`, and memory-source/dest `ALU`/`CMP`/`TEST` (`VEN_SYS_FASTLOAD_FLAT` / `VEN_SYS_FASTSTORE_FLAT`). | `UV` (`ADC`/`SBB` = `PU`) |
| **Zero/Sign-Extending Loads** | `MOVZX` (`0F B6`/`0F B7`) and `MOVSX` (`0F BE`/`0F BF`) reg/memory loads execute in `S_PIPE` without slow-FSM overhead (`c0e3fe43` Tier-1 IPC addition). | **`NP`** (fast U-only per AP-500) |
| **Unary & Non-Accum `TEST imm`** | Fast U-pipe `NEG`/`NOT` (`F6`/`F7 /2,/3`) and `TEST r/m, imm` (`F6`/`F7 /0`) hand off in 1 clock without slow-FSM bailout while strictly forbidding pairing (`verif/issue_uv/run_u_alu_system.py`). | **`NP`** (never pairs) |
| **Shifts & Rotates** | `SHL`/`SHR`/`SAR`/`ROR`/`ROL` by `1` (`D0`/`D1`) and by `imm8` (`C0`/`C1`) (`VEN_FAST_BYTE_SHIFT`, `VEN_FAST_ROR_IMM`). Shifts by `CL` (`D2`/`D3`) remain `NP`. | `PU` |
| **Stack Operations** | `PUSH r32`/`imm8`/`imm32` (`50+r`, `6A`, `68`) and `POP r32` (`58+r`) with implicit `ESP` folding. | `UV` (ESP-exempt pairs) |
| **Near Control Transfers** | `Jcc rel8`/`rel32` (`70`–`7F`, `0F 80`–`8F`), `JMP rel8`/`rel32` (`EB`, `E9`), `CALL rel32` (`E8`), plus 4-entry RAS return prediction. | `PV` |
| **Cacheable String Store Streaming** | `REP STOSB`/`STOSW`/`STOSD` (`VEN_REP_STOS_STREAM`) streams 1 element/clock on cacheable present writable pages with precise page-boundary, limit, and interrupt boundaries. | **`NP`** (streamed U-only) |
| **x87 Dispatch & `FXCH` Overlap** | Scalar `D8`–`DF` admission into `fp_shared` (`VEN_FP_SHARED_DIRECT` + `VEN_FP_ASYNC_STREAM`) with zero-cycle `FXCH` queueing (`ven_fp_fxch_queue`). | `FX` / `FXCH` queue |

---

## 3. Verification & Pairing Invariants

- **Initial Decode Batches (M5 Cycle Gate):** `mb_accimm`, `mb_rmimm`, `mb_sh1`, and `mb_nearbr` in `verif/m5_metrics.py` verify ≥40% pairing and ≤10% cycle-band agreement with `p5model`.
- **Protected-Mode Paired-State & NP Controls:**
  - `UV_FAST_RETIRE_STATE_2026-10-08.md`: DPI U-pipe pre-V snapshot verifies exact per-instruction architectural state across paired U+V commits under `--cycle-func`.
  - `verif/issue_uv/run_u_alu_system.py`: 128-case cold paged matrix (flat & relocated segments, intra-line & cross-line offsets, AXI latencies 0 & 7) verifying 100% U+V pairing on `UV` ALU+`Jcc` pairs and 0% pairing (with 1-cycle warm U handoff) on AP-500 `NP` `NEG`/`NOT`/`TEST imm`.
  - **Mandatory Rule:** Never force unsafe pairing on AP-500 `NP` instructions or weaken serialization/fault boundaries to inflate IPC.
