# Integrating & Operating `fp_shared` (`ven_fp_top` / `ven_fp_fxch_queue`)

Interface and integration contract for Ventium's production area-shared x87 FPU (`fp_shared/`).

## Current Integration Status (Nov 2026)

`VEN_FP_SHARED` (together with `VEN_FP_SHARED_DIRECT`, `VEN_FP_ASYNC_STREAM`, and `VEN_FP_FXCH_QUEUE`) is **deployed and board-qualified** in RK-XCZU15EG-F release **`c0e3fe43`** (`161` defines, `40.264133 MHz` STA sign-off, `72,204` LUTs / `10,596` FFs / `38` DSP48E2 / `2.5` BRAM36 in `u_fp_shared`, `0.515778001` total U+V / `0.397847833` primary/U Quake gameplay IPC across cycles `28,696,827,616–32,989,404,795`, passing CoreMark, cold Windows 95 OSR2 GUI, and cold DOS Quake `demo1`).

The legacy split x87 path (`rtl/fpu/fpu_top.sv` + `rtl/core/fpu_writeback.sv`) remains in the tree only for non-`VEN_FP_SHARED` unit/comparison builds.

---

## Filelist Order & Required Defines

Both [`../rtl_ven_core.f`](../rtl_ven_core.f) and [`../rtl/ventium.f`](../rtl/ventium.f) compile the x87 packages and leaf helpers before `fp_shared/`:

```text
rtl/core/ventium_decode_pkg.sv
rtl/fpu/fpu_x87_pkg.sv
rtl/core/ventium_x87_pkg.sv
rtl/fpu/fpu_srt_div.sv
rtl/fpu/ven_bcd.sv
rtl/fpu/ven_bcd_to_fp.sv
fp_shared/ven_fp_state.sv
fp_shared/ven_fp_alu.sv
fp_shared/ven_fp_misc.sv
fp_shared/ven_fp_widemul.sv
fp_shared/ven_fp_estdiv.sv
fp_shared/ven_fp_trans.sv
fp_shared/ven_fp_top.sv
fp_shared/ven_fp_fxch_queue.sv
```

- Keep files in `fp_shared/` (never copy them into `rtl/fpu/`, and never add `ven_fp_old_ooc.sv` or `fp_shared/tb/*` to synthesis filelists).
- `rtl/fpu/fpu_srt_div.sv` is the active SRT module in full builds (`fp_shared/fpu_srt_div.sv` is used only by standalone `fp_shared` OOC/unit scripts).
- Always define `VEN_FPREM` when compiling `fp_shared/` so unified SRT remainder logic is elaborated.

---

## Command / Response Handshake Contract

- **Reset:** `rst_n` is active-low synchronous; hold low for at least one rising `clk` edge.
- **Command Acceptance (`cmd_valid && cmd_ready`):** All `cmd_*` fields must remain stable while `cmd_valid && !cmd_ready`. After the acceptance edge, the producer may change `cmd_*` freely.
- **Immediate Commit (`cmd_accept_retire`):** Asserted on `cmd_valid && cmd_ready` only when an operation's complete architectural effect commits on the acceptance edge with no store/AX payload. When queued behind busy arithmetic in `ven_fp_fxch_queue`, `cmd_accept_retire` stays `0` and completion retires via the ordered response stream.
- **Early ALU Notification (`alu_commit_retire`):** Registered one-cycle-ahead commit indicator for ordinary shared-ALU operations; SRT, misc, store, `FNSTSW AX`, BCD, and transcendental commands always complete through `rsp_valid`.
- **Response Pulse (`rsp_valid`):** Single-cycle pulse with **no backpressure (`ready`) input**. The core adapter must sample `rsp_store_*`, `rsp_ax*`, `rsp_stack_fault`, and `rsp_unsupported` on the exact clock `rsp_valid` asserts. Track pending ownership from `cmd_valid && cmd_ready` to retirement rather than relying on `busy` alone.

### Command Signals

| Signal | Source / Semantics |
| --- | --- |
| `cmd_op` | Decoded `ventium_decode_pkg::fxop_e` (`FX_NONE` raises `rsp_unsupported=1`). |
| `cmd_aluop` | `0` add, `1` mul, `4` sub, `5` subr, `6` div, `7` divr. |
| `cmd_sti`, `cmd_pop`, `cmd_constant` | Stack index `ST(i)`, pop flag (`FCOMPP`/`FUCOMPP`/`FBSTP` implicit), and `FX_FLDCONST` selector. |
| `cmd_mem`, `cmd_mem_bytes` | Little-endian memory source operand (`2`, `4`, `8`, or `10` bytes). |
| `cmd_env16`, `cmd_real_mode`, `cmd_env_image` | `1` for 14/94-byte (`o16`), `0` for 28/108-byte (`o32`); real-mode vs protected-mode header format; assembled `FLDENV`/`FRSTOR` image. |
| `cmd_update_fip`, `cmd_fip`, `cmd_fcs` | Non-administrative FIP/FCS update (`FNINIT`, `FNCLEX`, `FLDCW`, `FNSTCW`, `FNSTSW m16`, `FWAIT`, `FLDENV`, `FNSTENV`, `FRSTOR`, `FNSAVE` are administrative; `FNSTSW AX` and `FNOP` update FIP). |
| `cmd_update_fdp`, `cmd_fdp`, `cmd_fds` | Asserted when `cmd_update_fip` and the instruction accesses memory. |
| `cmd_fdiv_bug`, `cmd_fist_bug` | Selectable M6 Pentium errata enables (`errata_en[ERR_FDIV]`, `errata_en[ERR_FIST]`). |

---

## Mandatory Memory Atomicity & Non-Speculative Rule

`ven_fp_top` has **no cancel/kill/abort pin**. Once accepted, an instruction mutates architectural x87 state (`TOP`, `FSW`, `FTW`, registers, or `FNSAVE` reset) before external bus writes finish. Therefore:

1. **Never issue speculatively:** Only submit commands once all older instructions, branch redirects, debug traps, pending `#MF` checks, and interrupts are resolved.
2. **Memory Loads:** Translate and read all source bytes via the core fragment engine *before* asserting `cmd_valid`. Any `#PF`/`#GP`/`#SS` aborts prior to FPU acceptance.
3. **Memory Stores (`FST`/`FSTP`/`FIST`/`FISTP`/`FBSTP`/`FNSTCW`/`FNSTSW`/`FNSTENV`/`FNSAVE`):** Pre-probe translation, segment limits, and write permissions across **every touched page** (`2`..`108` bytes) *before* asserting `cmd_valid`, without prematurely setting `PTE.D`, and block interrupts/context switches until the final store beat acknowledges (`make fpstore` verifies read-only `#PF` `P|W=3` before `FISTP` pops `ST(0)`). Unmasked `FST`/`FSTP` overflow/underflow suppresses `rsp_store_valid` and stack pop inside `ven_fp_top`.

---

## Environment & Save-State Payload Layouts

Little-endian flat vectors matching the IA-32 SDM and pinned QEMU oracle:

- **32-bit (`cmd_env16 = 0`, 28 B `FLDENV`/`FNSTENV`, 108 B `FRSTOR`/`FNSAVE`):**
  `+0` `FCW` (16b padded to 32b), `+4` `FSW`, `+8` `FTW`, `+12` `FIP`, `+16` `FCS` (`[15:0]`), `+20` `FDP`, `+24` `FDS` (`[15:0]`), plus `+28..+107` logical `ST(0)..ST(7)` (`8 × 10` B) for `FNSAVE`/`FRSTOR`.
- **16-bit (`cmd_env16 = 1`, 14 B `FLDENV`/`FNSTENV`, 94 B `FRSTOR`/`FNSAVE`):**
  `+0` `FCW`, `+2` `FSW`, `+4` `FTW`, `+6` `FIP[15:0]`, `+8` `FCS` (protected) or `{FIP[19:16], 12'b0}` (real), `+10` `FDP[15:0]`, `+12` `FDS` (protected) or `{FDP[19:16], 12'b0}` (real), plus `+14..+93` logical `ST(0)..ST(7)` for `FNSAVE`/`FRSTOR`.

---

## Verification Commands

 Always use private object directories and explicit `TMPDIR=/home/yukidama/external/tmp`:

```sh
# 1. Leaf & architectural A/B unit suite in fp_shared/
make -C fp_shared test

# 2. Integrated CPU write-fault atomicity, lint & differential gates (repo root)
make lint
make verify
make verify-sys
make fpstore
```

For isolated XCZU15EG OOC synthesis screening (`make -C fp_shared synth-ooc-shared`), `run_ooc_vivado.sh` invokes `fpga/run_vivado_exclusive.sh`, which terminates any same-user Vivado instance—verify no board implementation run is active first.
