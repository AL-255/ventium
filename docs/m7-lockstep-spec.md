# M7 — macro-workload lock-step (Quake + Windows 95)

Run real macro-workloads on the Ventium RTL in **lock-step against QEMU**: Quake
(the TyrQuake P5 build) and a Windows 95 boot. This is a step-change in scale from
the bare-metal sys tests (hundreds of records) to real programs (10⁸–10⁹+
instructions) and, for Win95, a full PC platform. Scoped per the user's choices:
Quake via **QEMU-proxied syscalls**, Win95 via a **system co-simulation built now**
(V86 + co-sim bus), and **run each as far as is feasible**, reporting bit-exactness
over the achieved prefix + where (if anywhere) the RTL diverges.

## The core problem: environment inputs the RTL cannot compute

The RTL is a CPU core. Both workloads feed the CPU values it cannot produce on its
own:

- **Quake (linux-user):** a 614 KB static i386 ELF with 8 `int 0x80` sites (musl).
  At each syscall the *kernel* mutates state — result in `eax`, and memory the CPU
  never wrote (e.g. `read()` buffers, `mmap()`'d pages, `gettimeofday` structs).
- **Win95 (system):** every `in`/`out` (PIC/PIT/IDE/VGA/DMA), every MMIO read, and
  every asynchronous device interrupt delivers values from *devices*, not the CPU.

So a standalone RTL can't run either past the first such event. The standard
solution and the project's principle (differential vs QEMU) converge on:

## The unified model: input-replay lock-step

**QEMU is the golden reference AND the environment; the RTL is the checked CPU.**
QEMU runs the workload to completion-or-prefix and emits a trace that carries, per
retired instruction, **(a) the architectural state** (the existing `.vtrace`
contract: GPRs/EFLAGS/EIP/segs/CRx) **and (b) any environment input that
instruction consumed** that the RTL cannot compute:

- a **syscall effect** (Quake): the post-syscall `eax` + the list of `(addr, bytes)`
  memory regions the kernel wrote, captured by diffing guest memory across the
  `int 0x80`.
- a **device input** (Win95): the value returned by each `in`/MMIO-read, and the
  **vector + frame** of each delivered interrupt (with its instruction boundary).

The RTL then **replays the same instruction stream**; the TB **injects** the
environment inputs at the right boundaries (it does NOT execute the kernel/devices),
and the comparator verifies the RTL's architectural delta matches QEMU **bit-for-bit
on every instruction the CPU is actually responsible for**. A mismatch there is a
genuine Ventium CPU bug. This isolates the CPU-under-test exactly, reuses the whole
existing oracle (gen_trace gdbstub + compare.py), and never fabricates a result.

### Trace-contract extension (trace-format.md §new)

Add optional per-record fields (absent ⇒ a normal CPU instruction):
- `sys_call`: `{nr, ret, writes:[{addr,hex}]}` — present on the record of an
  `int 0x80` (Quake). The TB applies `eax=ret` + each memory write, then resumes.
- `dev_in`: `[{port|mmio, val}]` — the device-read value(s) the instruction consumed
  (Win95). The TB returns these for the matching `in`/MMIO read.
- `intr`: `{vec, err?}` — an external interrupt delivered at this boundary (Win95).
  The TB raises it into the RTL’s IDT path at the same retire boundary QEMU did.

## Stages (each gated; runs as far as feasible)

- **M7.0 — oracle + contract + de-risk (gating).** Prove QEMU can EMIT the
  environment inputs over its gdbstub (QEMU 8.2.2 — recall plugins can't read regs,
  so everything is gdbstub-based). Specifically de-risk, empirically, BEFORE building:
  - **Quake:** can gen_trace single-step `tyr-quake-p5`, detect each `int 0x80`,
    capture `eax` + the kernel's memory writes (memory diff across the step), and is
    the run deterministic? (Disable ASLR; pin argv/env; the static binary helps.)
  - **Win95:** the HARD one. Can `qemu-system-i386` gdbstub single-step a Win95 boot
    AND expose, per step, the device-read values + the delivered-interrupt boundary,
    **deterministically** (under `-icount`, which the install already uses)? If the
    gdbstub can't surface device inputs/interrupts, find the path that can (an I/O
    `exec`-trace, a memory watch, or a small qemu trace hook) — or honestly bound the
    Win95 scope to the largest deterministic prefix that IS replayable. **Never fake.**
  - **Throughput:** measure RTL insns/s (Verilator) + gdbstub golden insns/s →
    project the achievable prefix length for "longest feasible run."
- **M7.1 — Quake user-mode lock-step.** TB additions: an **ELF/process-image loader**
  (load `tyr-quake-p5`'s PT_LOAD segments at their vaddrs; set entry/`esp`/argv/env
  exactly as qemu linux-user does) and an **`int 0x80` proxy** (apply `sys_call`
  effects from the trace, resume — no halt). Run the longest feasible prefix; report
  bit-exactness + the first divergence (if any) with the failing instruction.
- **M7.2 — V86 mode (Win95 prerequisite).** Add virtual-8086 mode to the core
  (V86 segmentation, IOPL-sensitive instruction faults to the monitor, interrupt
  redirection / `IF` virtualization, `#GP` on protected ops). Win95 runs DOS-compat
  and real-mode-driver code in V86 constantly. Gated by a focused V86 bare-metal test
  vs `qemu-system-i386` (the M2S pattern) before any Win95 run.
- **M7.3 — Win95 system co-sim run.** Wire the **co-sim bus** (RTL `in`/`out`/MMIO →
  `dev_in` replay; `intr` injection at the golden boundary) into the system TB, boot
  from the qcow2 under input-replay, and run the longest feasible boot prefix. Report
  how far it gets (e.g. BIOS → real-mode → PM → paging → V86 → driver init → …) and
  the first CPU-state divergence vs the golden.

## Honest feasibility (stated up front)

A *complete* Win95 boot (and a full Quake timedemo) in cycle-accurate Verilator,
oracled by gdbstub single-step, is almost certainly **wall-clock-prohibitive** here
(both the RTL sim and the single-step oracle are ~10³–10⁶ insns/s vs 10⁸–10⁹+ needed).
So "longest feasible run" means: the harness is architecturally complete, and we run
the longest deterministic prefix that fits the time budget, reporting bit-exactness
over it + honest throughput projections. The win is a real, end-to-end CPU stress
test on actual P5 game/OS code — far beyond the bare-metal corpus — and any
divergence found is a real bug. Win95 in particular may land as: V86 done + the
co-sim harness done + a bounded boot-prefix lock-step, with the full boot deferred on
throughput grounds (documented, never faked).

## Non-negotiables

- Never fabricate a golden or a pass; bound honestly where the oracle/throughput
  can't reach. - Reuse the differential oracle (gen_trace + compare.py); the CPU is
  the only thing under test (environment inputs are replayed, not graded).
- Keep `make verify` (user) + all sys gates GREEN — M7 is additive (new TB modes +
  V86 gated behind `sys_mode`/`vm86`), never a regression. - `ventium-refs/` is
  read-only (the Quake/Win95 artifacts live there; copy/snapshot, don't modify).
