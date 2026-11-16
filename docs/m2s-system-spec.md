# M2S — System-Mode Architecture Spec (M2S.0–M2S.6)

> **Current Status (Nov 2026 — COMPLETED & BOARD-QUALIFIED):** All seven M2S stages (`M2S.0` system oracle + `M2S.1` real/PM segmentation + `M2S.2` 2-level paging & TLBs + `M2S.3` IDT fault/interrupt delivery + `M2S.4` 32-bit TSS/cross-privilege/gates + `M2S.5` SMM/`RSM` + `M2S.6` `DR0`–`DR7`/`#DB`, plus `M7.2` V86 mode and `VEN_SYS_FASTPATH*` protected-mode U+V fast paths) are **implemented**, gated in `make verify-sys`, and physically qualified booting **cold Windows 95 OSR2 GUI** and **cold DOS Quake `demo1`** on **RK-XCZU15EG-F** image **`c0e3fe43`** (`40.264133 MHz` STA sign-off, `0.515778001` total U+V gameplay IPC across cycles `28,696,827,616–32,989,404,795`). The original scoping notes below record how the `qemu-system-i386` differential harness was structured.

## Historical Scoping Notes (M2S.0–M2S.6 Roadmap)

M2S added the **system/privileged processor** — protected-mode segmentation, paging + TLBs +
MMU, the interrupt/exception pipeline, TSS/task-switch, SMM/`RSM`, and debug
registers — atop the earlier user-mode flat M1–M5 core.

## Oracle — FEASIBLE (surveyed)

The whole project's strength is differential verification vs QEMU; M2S can keep
that, with new infrastructure:

1. **Build `qemu-system-i386`.** The harness built only `qemu-i386` (linux-user).
   The QEMU 8.2.2 source tree is present (`…/build/qemu/target/i386`), so re-run
   configure with `--target-list=i386-softmmu` and rebuild (~10 min; adapt
   `scripts/10-build-emulator.sh`). One-time.
2. **System-state golden trace via gdbstub.** Run `qemu-system-i386 -S -gdb
   tcp::PORT -kernel <test>` and single-step over RSP, reading the system register
   block. `gdb-xml/i386-32bit.xml` already advertises `cr0/cr2/cr3/cr4/efer` and
   the segment bases — and `gen_trace.py`'s RSP client + the **tail-anchor layout
   fix** (commit c39905b) already handle that register block (in user mode they
   read 0; in system mode they carry real values). Extend the `.vtrace` func
   record (trace-format.md) with the system fields: `cr0/cr2/cr3/cr4`, the segment
   **hidden** descriptor state (base/limit/attr) where the stub exposes it, and
   the fault/exception vector + error code. (Segment-hidden + TSS internals may
   need a small QMP/HMP `info registers`/`info tlb` cross-check where gdbstub is
   thin.)
3. **Bare-metal test harness.** Freestanding images (no OS) that set up their own
   GDT/IDT/page tables, switch real→protected mode, enable paging, run the test,
   and exit via `-device isa-debug-exit` (out to 0x501) or a HLT sentinel. The RTL
   must boot from the real reset state (real mode, `CS:EIP = F000:FFF0`) and model
   the mode transition — a front-end change vs today's linux-user entry.

**Verifiable vs not.** Differentially verifiable against qemu-system: page-table
walks + TLB fill/translation, #PF/#GP/#UD/#DF fault delivery + error codes +
priority + restartability, descriptor loads + segment limit/type checks, `CALL`/
`JMP` through gates, task switches (TSS), `CPUID`/MSR/`RDTSC`. Harder / partial:
SMM corner cases (SMRAM save-map layout is stepping-specific), APIC/IO-APIC + MP
(needs the MP-spec model), and the system errata deferred from M6 (BTB-flush/SMM/
STPCLK# timing) — some still need real silicon.

## RTL scope (staged sub-milestones — each gated vs qemu-system)

The core today has no system layer. Suggested stages, each with its own bare-metal
corpus + differential gate (reuse the R1 fast-gate machinery):

- **M2S.0 — oracle + harness:** build qemu-system-i386, extend gen_trace + the
  trace format for system state, a bare-metal build flow + `make verify-sys`.
- **M2S.1 — real→protected mode + segmentation:** reset vector, real mode, the
  mode switch, GDT/LDT descriptor loading, segment hidden state, limit/type/priv
  checks, `#GP`. (Touches the front end + a new `rtl/sys/segment.sv`.)
- **M2S.2 — paging + TLBs + MMU:** CR0.PG/CR3, 2-level page walk, `rtl/mem/tlb.sv`
  (I/D TLBs), `#PF` + error code + CR2, A/D bits.
- **M2S.3 — interrupts/exceptions:** IDT, fault priority + restartability, the
  interrupt pipeline, `INT n`/`INTO`/`BOUND`, real `int 0x80` semantics (replacing
  the halt), `IRET`. (`rtl/sys/sys_state.sv` + the microcode engine.)
- **M2S.4 — TSS / task switch:** `rtl/sys/`, hardware task gates, busy bit, NT.
- **M2S.5 — SMM / RSM:** SMI#, SMRAM save/restore map, `RSM` (stepping-specific;
  partial-oracle — verify the documented save-map).
- **M2S.6 — debug registers / single-step / breakpoints**; then the deferred M6
  system errata (BTB-flush, SMM/STPCLK#) become reachable.

## Effort + recommendation

**Large** — comparable to M1–M5 combined (the system architecture is most of a CPU).
Honest recommendation: treat M2S as a **separate, explicitly-staged project**, not
an autonomous burst. Start with **M2S.0** (oracle + harness) as a bounded,
verifiable first step — once a system-mode golden trace round-trips and a trivial
protected-mode test diffs clean, the per-stage RTL build can proceed on the
proven fast-gate pattern. Awaiting user greenlight before building.

(Also note **M5B-int** stays deferred: wiring the real bus FSM in would change the
memory timing the core sees → break the verified M5 cycle bands, and there is no
bus oracle to re-verify against. The bus unit remains a verified standalone block.)
