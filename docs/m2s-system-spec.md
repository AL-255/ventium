# M2S — system mode (scoping plan; NOT yet started)

This is a **scoped de-risk plan**, not an implementation. M2S is the one
substantial piece of REF.md §9 left after the M0–M6 + M5B + R1 roadmap completed:
the **system/privileged processor** — protected-mode segmentation, paging + TLBs +
MMU, the interrupt/exception pipeline, TSS/task-switch, SMM/`RSM`, and debug
registers. Everything to date is **user-mode, flat** (segments constant, no
paging, `int 0x80` = halt), so M2S is effectively a **second project** of size
comparable to the whole M1–M5 ladder. Greenlight + staging is a user decision.

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
