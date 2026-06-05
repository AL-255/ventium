# test386.asm — external x86 CPU differential testbench

[`test386.asm`](https://github.com/barotto/test386.asm) is a comprehensive,
independently-authored x86 CPU tester for emulators (used by PCem/86Box/etc.). It
boots as a **64 KiB freestanding BIOS image** (reset `0xfffffff0` → `f000:0045`)
and exercises 80386+ behaviour: conditional jumps, all addressing modes, protected
mode, virtual-8086 mode, bit operations, string instructions, and more — reporting
progress via POST codes. **License: GPL-3.0** (a standalone test tool, not linked
into the Ventium RTL; an aggregate). The full source is vendored at
`ventium-refs/09-external-cpu-tests/test386.asm/` (with its `COPYING`).

## Why it fits Ventium

It is exactly the system-mode image model the Ventium harness already runs:
`qemu-system-i386 -bios` for the golden (`gen_trace.py --system` single-step) vs
the Ventium RTL for the checked CPU, compared per-record under the EFLAGS-undefined
mask. It is a much broader, externally-authored instruction stream than the
hand-written `verif/sys/tests` corpus — a genuine independent oracle and gap-finder
(like the M7 Quake/Win95 lock-step found `LOCK CMPXCHG`/`IN`/`OUT`/`CPUID`/… gaps).

## How it's run (prefix differential)

- **Golden:** `qemu-system-i386` single-stepped over the BIOS image.
- **Checked CPU:** `ventium_soc` (`tb_soc`, `soc_en=1`). The **SoC** is the correct
  vehicle, not the bare core: test386 writes POST codes via `OUT DX,AL` very early,
  and the bare `ventium_top --system` HALTs on port I/O (no PC platform), whereas
  the SoC's PMIO decoder acks the (undecoded) POST port so the run proceeds.
- **Compare:** `compare.py --mode func` per record (pc/eflags/GPRs/segs/CRx).

```bash
bash verif/external/test386/run-test386-gate.sh [MAXI]   # MAXI default 1500
```

The committed `test386.bin` is the `nasm`-built image (so the gate needs no
`nasm`); rebuild with `nasm -i./src/ -f bin src/test386.asm -w-all -o test386.bin`
in the vendored source dir. `test386.sys.vtrace.golden` is the committed 1,500-insn
reference golden (drift-checked by the gate).

## Status (2026-06-05)

**EQUIVALENT to 30,000 instructions** — `ventium_soc` matches `qemu-system-i386`
byte-for-byte across the first 30k instructions of test386's prefix (verified;
the committed reference golden is the fast 1,500-insn prefix). Raise `MAXI` for a
deeper run. The eventual frontier is expected where test386 reaches an instruction
or platform device the Ventium RTL/SoC does not yet model — an honest gap to triage
incrementally (the SoC's free-running PIT, or an unimplemented opcode), exactly the
kind of finding this external corpus is here to surface.
