# Area-Shared Pipelined x87 FPU (`fp_shared/`)

Synthesizable, area-shared IEEE-754 80-bit extended-precision (`floatx80`) x87 FPU and polynomial transcendental subsystem for Ventium (`+define+VEN_FP_SHARED`).

## Production Hardware Status (Nov 2026 — Image `c0e3fe43`)

`fp_shared/` is the **production x87 FPU** in board-qualified RK-XCZU15EG-F release **`c0e3fe43`** (`xczu15eg-ffvb1156-2-i`, Vivado 2025.2, `161` defines, `40.264133 MHz` post-route STA sign-off, `0.515778001` total U+V / `0.397847833` primary/U physical Quake gameplay IPC across cycles `28,696,827,616–32,989,404,795`, passing CoreMark, cold Windows 95 OSR2 GUI, and cold DOS Quake `demo1` at `8.0 FPS`).

In the routed `c0e3fe43` checkpoint, the complete `u_fp_shared` hierarchy (`ven_fp_top` + `ven_fp_fxch_queue` + `fpu_srt_div` + `ven_bcd` / `ven_bcd_to_fp`) occupies:
- **`72,204` CLB LUTs** (`21.16%` of XCZU15EG, vs `155,118` LUTs in the legacy split-engine bundle)
- **`10,596` Flip-Flops**
- **`38` DSP48E2 slices** (`1.08%` of XCZU15EG, vs `1,405` DSPs in the legacy split-engine bundle)
- **`2.5` Block RAM tiles** (transcendental constant ROMs)

---

## Module Hierarchy

`ven_fp_top` (paired with `ven_fp_fxch_queue` when `VEN_FP_FXCH_QUEUE` is enabled) is the public boundary instantiated by `rtl/ventium_top.sv` / `rtl/core/core.sv`; all other `ven_fp_*` modules are internal children:

| File | Role |
| --- | --- |
| `ven_fp_top.sv` | Top-level command/response shell, operand capture, non-speculative commit controller, C1/exception/status ownership, and 14/28/94/108-byte `FLDENV`/`FNSTENV`/`FRSTOR`/`FNSAVE` formatter. |
| `ven_fp_fxch_queue.sv` | Zero-cycle `FXCH` rename / single-slot ordered admission queue (`VEN_FP_FXCH_QUEUE`) enabling overlapped integer/FP execution (`VEN_FP_ASYNC_STREAM`) without speculative stack mutation. |
| `ven_fp_state.sv` | Pointer-mapped 8×80-bit physical register bank (`ST(0)..ST(7)`), `TOP`, `FCW`, `FSW`, `FTW`, and `FIP`/`FCS`/`FDP`/`FDS` pointer registers. |
| `ven_fp_alu.sv` | Pipelined `floatx80` add/subtract/multiply engine with exact round-direction (`C1`) sideband, shared by scalar arithmetic and transcendental polynomial evaluation. |
| `ven_fp_misc.sv` | Registered compare/classify (`FCOM*`, `FUCOM*`, `FTST`, `FXAM`), shared integer conversion (`FIST`/`FISTP`/`FRNDINT`/`FSCALE`), and narrowing `FST`/`FSTP` `m32`/`m64`/`m80` store service with exact `C1` and unmasked range-exception gating. |
| `ven_fp_trans.sv` | Table-driven microsequencer for all 8 x87 transcendentals (`F2XM1`, `FYL2X`, `FYL2XP1`, `FPATAN`, `FSIN`, `FCOS`, `FSINCOS`, `FPTAN`), borrowing `ven_fp_alu`, `fpu_srt_div`, `ven_fp_estdiv`, and `ven_fp_widemul`. |
| `ven_fp_widemul.sv` | Iterative 16-cycle 32×32-limb 128×128-bit wide multiplier for transcendental range reduction and reconstruction. |
| `ven_fp_estdiv.sv` | Narrowed 32-cycle restoring 128/64 quotient estimator (`z_hi_q[31:0]` + 64×32→96-bit correction, 8 DSP48E2) for `FYL2X`/`FYL2XP1` and `FPATAN`. |
| `../rtl/fpu/fpu_srt_div.sv` | Unified iterative radix-4 SRT engine (`FDIV`/`FDIVR`, `FSQRT`, `FPREM`/`FPREM1`, `FPTAN`/`FPATAN` ratio steps) with registered pre-round latch, reduced-precision floor-borrow fix, and `C1` round-up sideband (`fp_shared/fpu_srt_div.sv` is the standalone OOC copy). |
| `../rtl/fpu/ven_bcd.sv`, `ven_bcd_to_fp.sv` | Iterative packed-BCD store (`FBSTP`) and load (`FBLD`, preserving `-0.0` sign) engines. |

See [`HOW_TO_USE.md`](HOW_TO_USE.md) for the exact handshake, non-speculative memory pre-probe atomicity contract, and environment memory layouts.

---

## Architectural C1, Rounding & Exception Invariants

Closed architectural verification against Intel Pentium Family Developer's Manual Vol. 3 (241430-004, Table 6-4 & §7.1) enforces:
- **Arithmetic & SRT Round-Direction `C1`:** `fx_round_pack_c1`, `ven_fp_alu`, and `fpu_srt_div` export the true post-tie-even rounding increment (`C1 = 1` iff magnitude rounded upward, including PC24/PC53/PC64, overflow-to-infinity vs finite saturation, and SRT signed-residual correction; exact results clear `C1`).
- **Reduced-Precision SRT Exponent Ownership:** `fpu_srt_div` keeps the unrounded exponent separate from the inline PC64 carry before invoking PC24/PC53 rounding, preventing double-carry factor-of-two `FSQRT` errors.
- **Narrowing & Unmasked Memory Stores (`FST`/`FSTP`):** `m32`/`m64` stores write `C1` from the narrowing rounder (`m80` clears `C1`). Unmasked overflow/underflow (`tiny_nonzero` even when exact) suppresses memory write and `FSTP` pop while committing sticky exception flags; unmasked `#PE` still stores and pops.
- **Register Copy/Pop & Zero-`C1` Ops:** `FX_FST_STI` treats `ST(i)` as write-only (copying into an empty `ST(i)` does not raise stack underflow). Non-faulting `FLD*`, `FILD`, `FBLD`, `FST`/`FSTP ST(i)`, `FXCH`, `FABS`, and `FCHS` clear `C1` prior to stack-fault override (`C1=1` on stack overflow, `C1=0` on stack underflow).
- **Packed-Decimal Negative Zero:** `FBLD` (`ven_bcd_to_fp` and `fx_bcd_to_fx`) converts the 18-digit magnitude and applies the packed sign bit afterward, preserving `-0.0`.

---

## Unit & Regression Testbenches (`fp_shared/tb/`)

Run the standalone leaf/top verification suite from `fp_shared/` (`make test`), plus targeted Python/Verilator miters in `fp_shared/tb/`:

| Testbench / Harness | Verified Property |
| --- | --- |
| `tb/tb_ven_fp_state.sv` | 5,000-step randomized cycle-by-cycle register-stack/tag/pointer equivalence vs `fpu_top`. |
| `tb/tb_ven_fp_alu.sv`, `tb/tb_ven_fp_arith_forward.sv` | Directed + random `floatx80` add/sub/mul value, exception, and registered memory-operand forwarding equivalence. |
| `tb/tb_ven_fp_widemul.sv` | 1,005 directed/random 128×128-bit product checks on the 16-cycle limb multiplier. |
| `tb/tb_ven_fp_estdiv.sv`, `tb/tb_estdiv_narrow.sv` | 5,004 A/B checks vs combinational `fpu_estdiv` + 284,883-clock cycle-exact miter for the narrowed 8-DSP estimator. |
| `tb/tb_ven_fp_srt_sqrt.sv`, `tb/tb_ven_fp_srt_controls.sv`, `tb/tb_ven_fp_srt_top_ab.sv`, `tb/tb_srt_round_floor.sv` | Unified radix-4 SRT `FDIV`/`FSQRT`/`FPREM` equivalence, control/cancellation checks, and 912-case PC24/53/64 floor-exponent regression. |
| `tb/tb_round_pack_c1.sv`, `tb/tb_fp_round_c1.sv` | 15,600 exact-rational `fx_round_pack_c1` vectors + 2,064 interleaved top-level ALU/SRT `C1` & stack-fault vectors. |
| `tb/tb_misc_shared_int.sv`, `tb/tb_ven_fp_misc_response.sv` | 73,728-case miter for shared `FIST`/`FRNDINT`/`FSCALE` integer conversion and response timing. |
| `tb/tb_rem_clz_tree.sv` | 311,428 4-state comparisons on `rem_clz64` remainder normalization. |
| `tb/tb_ven_fp_trans.sv` | 1,640 checks across all 8 transcendentals and all 4 rounding modes through shared ALU + `widemul` + `estdiv`. |
| `tb/tb_ven_fp_mem_queue.sv` | Ordered `ven_fp_fxch_queue` admission, `cmd_accept_retire` gating, reset, and scalar queue ordering. |
| `tb/tb_ven_fp_top.sv`, `tb/tb_ven_fp_arch_ab.sv` | 132 smoke checks (including 14/28/94/108-byte environments & stack faults) + 101 architectural A/B checks across all 64 `fxop_e` operations. |
| `tb/run_*_observe.py` & `tb/test_*.py` | End-to-end ISA + Python unit suites for `FLD` (`1,216` cases), `FST`/`FSTP` reg (`1,920`), masked `FST` mem (`2,352`), unmasked `FST` range (`1,920`), and zero-`C1`/`FBLD` sign (`3,906`). |

Out-of-context XCZU15EG synthesis (`make synth-ooc-shared` via `run_ooc_vivado.sh` → `fpga/run_vivado_exclusive.sh`) remains available for isolated leaf area/timing screening; always verify no active board Vivado build is running before invoking it.
