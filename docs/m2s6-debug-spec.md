# M2S.6 — debug registers / `#DB` (the last system-mode stage)

Sixth and final system-mode RTL stage. Adds the **debug-register file (DR0–DR7)**,
the `MOV` to/from `DRn` instructions, and the **`#DB` debug exception (vector 1)** —
delivered through the M2S.3 IDT pipeline. Closing this stage makes the M6 debug
errata (e.g. Err 79, debug-exception-on-`POPF`/`IRET`) reachable.

**Partial-oracle (like M2S.5) — de-risk the oracle FIRST.** Some of M2S.6 is
differentially verifiable against `qemu-system-i386`, some is not. The corpus phase
must establish empirically which is which before any RTL, and the gate must diff
ONLY the feasible parts and structurally self-check the rest. **Never fake a
sys-diff.**

## Oracle survey (de-risk, gating — do this before RTL)

The system oracle is the `qemu-system-i386` gdbstub **single-step** path
(`gen_trace.py --system`). Debug features interact with it three ways; the corpus
phase must confirm each empirically and scope honestly:

1. **`MOV DRn ↔ GPR` round-trip — EXPECTED DIFFERENTIAL.** The DR register *values*
   are NOT in the gdbstub `g`-packet (debug regs are HMP-only, per M2S.0), so a
   `dr6`/`dr7` trace field cannot be diffed directly. BUT `MOV r32, DRn` deposits
   the value into a **GPR**, which IS in the `g`-packet — so a round-trip
   `MOV DRn, eax; MOV ebx, DRn` is fully observable in EBX (exactly the M2S.1
   hidden-base trick: observe the unexposed state *through* a GPR). qemu implements
   `MOV DRn`, so this round-trip should diff clean. **No trace-format change** — the
   DR state is observed through GPRs, not new fields.

2. **`TF` single-step `#DB` delivery — LIKELY DIFFERENTIAL (confirm).** A guest that
   sets `EFLAGS.TF` takes a `#DB` **trap** after the next instruction, vectoring
   through `IDT[1]` to its handler — exactly like the `pintr` software-`INT`
   delivery the M2S.3 gate already diffs. The `#DB` is a *synchronous* exception
   (not in `interrupt_request`), so `SSTEP_NOIRQ` should NOT mask it (unlike SMI).
   The handler entry `CS:EIP`, the pushed frame (observed via handler reads), the
   `DR6.BS` bit (read into a GPR), and the `IRET` resume are all observable.
   **Corpus must confirm** the gdbstub single-step actually lands on the guest `#DB`
   handler (and that qemu's own single-step does not swallow the guest `TF` `#DB`).

3. **DR0–3 hardware breakpoints `#DB` — RISKY, possibly STRUCTURAL.** Guest hardware
   breakpoints (DR0–3 + DR7 enables) are implemented in qemu via the SAME internal
   breakpoint/watchpoint mechanism gdb uses for *its* breakpoints. Under gdbstub
   single-step the guest's hw-breakpoint `#DB` may be suppressed or collide with
   gdb's stepping. **Corpus must probe** whether a guest instruction/data breakpoint
   fires + vectors under single-step. If it does → differential. If not → implement
   the mechanism, self-check it STRUCTURALLY (RTL trace + qemu free-run with QMP/HMP
   `info registers` DR read-back), and DEFER the differential honestly (the M2S.5
   precedent: structural, never faked).

## Scope (RTL, gated behind `sys_mode`)

1. **DR0–DR7 register file** + `MOV r32, DRn` (`0F 21 /r`) and `MOV DRn, r32`
   (`0F 23 /r`). DR0–3 = linear breakpoint addresses; **DR6** = debug status
   (`B0–B3`, `BD`, `BS`, `BT`; the documented `0xFFFF0FF0` reserved-1 pattern on
   read); **DR7** = control (`L0/G0..L3/G3` enables, `LE/GE`, `GD`, the `R/Wn`
   2-bit type + `LENn` 2-bit length per breakpoint). DR4/DR5 alias DR6/DR7 when
   `CR4.DE=0`; `#UD` when `CR4.DE=1` (P5 debug-extensions). Reserved-bit handling on
   write per Vol.3.
2. **`#DB` (vector 1, NO error code)** delivered through the M2S.3 `start_fault` →
   `S_INT_GATE` path. `#DB` is a **trap** (push NEXT EIP) for `TF` single-step, data
   breakpoints, and the task-switch (`T`) bit; a **fault** (push FAULTING EIP) for
   instruction breakpoints and the `GD` general-detect. Set the matching **DR6**
   status bits before delivery (sticky — DR6 bits are not auto-cleared by the CPU).
3. **`TF` single-step.** After an instruction retires with `EFLAGS.TF=1` (and no
   higher-priority exception), deliver a `#DB` trap with `DR6.BS=1`. Gate entry
   already clears `TF` (M2S.3 mask). **`RF` (resume flag):** set in the pushed
   EFLAGS so the handler's `IRET` does not immediately re-trigger an instruction
   breakpoint at the restarted EIP; the CPU clears `RF` after the next instruction
   successfully retires.
4. **Hardware breakpoints (DR0–3 + DR7).** On a fetch/data access whose linear
   address matches an enabled DRn (`Ln`/`Gn` set), of the matching type (`R/Wn`:
   `00`=execute/fault, `01`=write/trap, `11`=read-or-write/trap; `10`=I/O when
   `CR4.DE`) and aligned to `LENn`, set `DR6.Bn` and deliver `#DB`. Instruction
   breakpoints fire BEFORE the instruction (fault); data breakpoints fire AFTER
   (trap). Honor `RF` (suppress instruction breakpoints for one instruction).
5. **`GD` general-detect** (DR7.GD=1): any `MOV` to/from a DR register raises `#DB`
   with `DR6.BD=1` *before* the access — protects ICE/debug hardware. (Implement the
   decision; corpus exercises it if the oracle supports it, else structural.)

Out of scope (documented deferrals): the `BT` task-switch debug trap (needs a HW
task switch, deferred at M2S.4); I/O breakpoints beyond decode (`CR4.DE` + `R/W=10`)
unless trivially gated; exact P5 stepping corners of reserved DR bits.

## Corpus + gate

Add `verif/sys/tests/pdebug/` (real mode → PM → IDT with a `#DB` interrupt/trap gate
at vector 1 → the debug exercises → `isa-debug-exit`):

- **(differential, expected)** `MOV DRn ↔ GPR` round-trips: write known patterns to
  DR0–3/DR6/DR7, read them back into GPRs (with the documented reserved-bit
  masking), prove the values in the GPRs match the golden.
- **(differential, confirm in de-risk)** `TF` single-step: set `TF`, execute one
  instruction, land in the `#DB` handler (`db_handler`), have it read `DR6` (expect
  `BS`) into a GPR + count, `IRET`, prove resume — diffed like `pintr`.
- **(differential if oracle supports, else structural)** a DR0 instruction
  breakpoint and a DR1 data-write breakpoint: arm via DR7, trigger, land in
  `db_handler`, read `DR6.Bn`, clear DR6, `IRET`/resume.

**Gate:** `pdebug` RTL `--system` EQUIVALENT to the `qemu-system-i386` golden across
the feasible parts (cr0..cr4 + selectors + GPRs + eflags + eip — the DR state
observed *through* the GPRs the handlers read). The non-feasible parts (whatever the
de-risk shows the gdbstub single-step cannot trace) → RTL + qemu-free-run structural
self-check, documented + deferred (the M2S.5 precedent). **HARD:** `make verify`
(user) GREEN + bit-identical (all M2S.6 logic gated behind `sys_mode`; `MOV DRn` /
`#DB` never fire in `boot_mode=user`); all prior sys tests (pseg/pmode/ppage/pintr/
pfault/pcpl + ptask self-diff + psmm structural) stay green; lint clean.

Honest done-partial expected (DR file + `MOV DRn` round-trip + `TF` single-step `#DB`
working differentially; hardware-breakpoint firing + `GD` differential vs structural
per the de-risk; `BT`/exotic-reserved-bit corners deferred). Never fake a sys-diff;
never regress user mode or prior stages. This is the **last** system-mode stage —
after it, the deferred M6 debug errata become reachable.
