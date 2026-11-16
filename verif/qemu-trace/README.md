# Producer A — Pinned QEMU Golden Trace Generator & Oracle Rules (`verif/qemu-trace/`)

`gen_trace.py` is **Producer A** of the Ventium differential-verification stack (`docs/trace-format.md`). It single-steps 32-bit i386 user ELFs (`qemu-i386 -cpu pentium`) or bare-metal system/BIOS images (`qemu-system-i386 -cpu pentium`) over the GDB Remote Serial Protocol (RSP) and emits canonical `.vtrace` records exclusively through `../diff/tracefmt.py`.

> **Oracle Requirement (`AGENTS.md`):** Differentials require the pinned QEMU 8.2.2 Pentium oracle in `ventium-refs/07-p5-emulation-harness`; distribution QEMU builds are **not** interchangeable.

---

## Usage

```sh
# User-mode ELF trace:
python3 verif/qemu-trace/gen_trace.py \
  --qemu ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386 \
  --elf verif/tests/smoke/smoke.elf --out /tmp/smoke.vtrace [--x87] [--max-insn N]

# System-mode bare-metal BIOS trace:
python3 verif/qemu-trace/gen_trace.py \
  --qemu ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386 \
  --system --image verif/sys/tests/pmode/pmode.bin --image-mode bios \
  --out /tmp/pmode.sys.vtrace --max-insn 4000
```

| Flag | Meaning |
| --- | --- |
| `--qemu <path>` | Path to pinned `qemu-i386` or `qemu-system-i386`. |
| `--elf <file>` | User-mode 32-bit i386 ELF (`--args ...` must be last if passing guest args). |
| `--system` / `--image <bin>` / `--image-mode bios` | System-mode launch (`F000:FFF0` real-mode reset, `-machine pc -m 32 -device isa-debug-exit,iobase=0xf4,iosize=0x04`), emitting `sys:true` (`cr0..cr4` + selectors). |
| `--x87` | Emit 80-bit `st0..st7` and `fctrl/fstat/ftag/fiseg/fioff/foseg/fooff/fop` (`x87:true`). |
| `--out <file>` | Output `.vtrace` path. |
| `--max-insn N` / `--stop-at 0xADDR` | Cap retired instructions or stop before stepping `ADDR`. |
| `--no-bytes` | Omit per-record instruction `bytes` readback. |
| `--port P` | Legacy compatibility flag; owned QEMU launches always use authenticated private Unix sockets (`owned_gdb.py`). |

### Record Post-State Convention & `g`-Packet Discovery

Record `n` pairs the **fetch `pc`** (`EIP` before stepping) with the **post-commit register state** immediately after stepping (`pc(n+1) == post_eip(n)` modulo control flow). Rather than hardcoding register offsets, `gen_trace.py` queries `qXfer:features:read:target.xml` (`i386-32bit.xml`) at startup and uses `anchor_tail` to align QEMU's 344-byte `i386-softmmu` `g`-packet (`cr0..cr4` at byte 76, `st0..fop` at byte 100).

---

## Enduring Transport & Oracle Rules

The helper modules and subdirectories in `verif/qemu-trace/` address specific transport and QEMU 8.2.2 oracle behaviors discovered during full-P5 / shared-FPU verification:

### 1. Authenticated Private Unix-Socket GDB Transport (`owned_gdb.py`)

TCP gdbstub ports (`-g <port>`) can silently collide with parallel workers or unrelated host processes, producing a valid `.vtrace` header from the wrong guest. `owned_gdb.py` allocates a private Unix domain socket per owned QEMU child across all four producer paths (user, system, syscall proxy, and reset-memory capture) and verifies peer `PID`/`UID`/`GID` via Linux `SO_PEERCRED` before sending any RSP command (using `/proc/<pid>/fd/<dirfd>/gdb` when `TMPDIR` exceeds `sun_path` length). Functional golden-cache keys in `verif/lib/verify_worker.sh` hash `gen_trace.py`, `owned_gdb.py`, and `tracefmt.py`.

### 2. System-Mode Hidden `CS.base` Observation (`test_system_cs_observer.py`)

In `--system` mode when `--no-bytes` is off, instruction bytes must be fetched from `CS.base + EIP` rather than assuming `CS << 4` (which breaks unreal mode, relocated protected-mode descriptors, and the `0xFFFF0000` reset `CS.base`). When the `g`-packet omits `CS.base`, `gen_trace.py` issues a read-only `monitor info registers` query and fails closed on missing or selector-inconsistent replies.

### 3. Opt-In Hash-Pinned Qualified User Reference (`qualified_profile.py`)

Stock QEMU 8.2.2 (`11aa0b1f...`) stays unmodified by default. For full-P5 `VEN_L1_AXI` + `VEN_FP_SHARED` user-mode verification (`VTM_QEMU_PROFILE_BUILD` / `run_qualified_profile_gate.py`, profile `i386-defined-x87-preexit-20261016`), `qualified_profile.py` verifies the 11,132-file source closure and binary hash of a privately built QEMU 8.2.2 incorporating five audited oracle repairs (`108/108` functional corpus PASS without relaxing comparator masks or cycle bands):

1. **Pre-Exit Terminal Observation (`prepare_preexit_observer.py`, `VTM_QEMU_GDB_PREEXIT=1`):** Exposes the live CPU via `gdb_handlesig` at `exit`/`exit_group` before `linux-user` tears down the task, matching UV-fast RTL's retired `int $0x80` record (`verify_worker.sh` isolates `.preexit0` and `.preexit1` cache keys).
2. **SoftFloat Round-Increment & Instruction `C1` (`prepare_round_increment.py`, `c1_reference/`):** Tracks true post-subnormal/tie carry-into-LSB magnitude increments (`inc > round_mask - (frac_lo & round_mask)`) in `float_status` and wires Pentium Vol. 3 Table 6-4 `C1` rules across arithmetic, `FSQRT`, narrowing `FST`, `FLD`/`FILD`/`FCHS`/`FABS`/`FXCH` clears, while preserving `FXAM`/`FWAIT` state.
3. **`FPREM` / `FPREM1` Quotient, Precision, Exceptions & Underflow (`prepare_remainder_quotient.py`, `remainder_sequence/`):** Separates nearest-even vs truncating modulus from quotient-pointer presence so `FPREM1` populates `C0/C3/C1` (`Q2/Q1/Q0`), fixes multi-step `q << exp_diff` low-64-bit accumulation, forces internal `PC64` during `helper_fprem_common` (restoring caller `PC` afterward), enforces `IE > DE` / empty-stack operand preservation, and scales nonzero tiny remainders by `2^24576` with `UE` when `UM=0`.
4. **`FRNDINT` Precision & Denormal Handling (`frndint/`):** Evaluates `FRNDINT` at full extended precision regardless of `PC24`/`PC53` (restoring `PC` afterward), sets roundup `C1`, and enforces masked/unmasked `IE`/`DE` operand preservation.
5. **x87 Environment Pointer Layouts (`fp_env/`):** Implements all four 14/28-byte protected and real/V86 (`env->eflags & VM_MASK`) FIP/FDP pointer formats in `do_fstenv`/`do_fldenv` per Pentium Vol. 3 Figs. 6-6..6-9.

### 4. System-Mode QEMU Cross-Page TB Invalidation (`tb_page/`) & SDM Gaps

- **Cross-page SMC invalidation (`tb_page/`):** QEMU 8.2.2 `accel/tcg/tb-maint.c` computes `pindex1` from `paddr0` instead of `paddr1` in `tb_record`/`tb_remove`, failing to invalidate cross-page translated blocks after self-modifying stores (fixed upstream in QEMU commit `3b279f73`; isolated backport harness in `verif/qemu-trace/tb_page/`).
- **QEMU softmmu architectural omissions:** Stock QEMU 8.2.2 omits per-access segment-limit checks, null data-selector `#GP(0)` faults, `FNSTENV` exception masking, x87 stack faults, and gdbstub `SMI#` stepping (plus uses P6 SMRAM offsets). Those contracts are verified by dedicated Intel SDM witness gates in `verif/sys/`.

## Host Unit Tests

```sh
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
  python3 -B -m unittest discover -s verif/qemu-trace -p 'test_*.py'
```
