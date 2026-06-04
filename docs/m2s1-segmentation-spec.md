# M2S.1 — protected-mode segmentation + real-mode boot

First RTL stage of M2S (system mode), gated against the `qemu-system-i386` golden
(M2S.0). Large: the core today is flat/user-mode (boots at a loader-supplied
entry, segments constant, no CRx, `int 0x80`=halt); M2S.1 adds the **cold-boot →
real mode → protected-mode segmentation** front half of a real x86.

## The dual-boot-mode design (the crux)

The user-mode gates (M0–M6) boot the core at the linux-user entry in flat mode;
M2S needs a cold reset at the real vector. Both are genuine Pentium states, so the
core supports **both via a `boot_mode` input** (TB-selected); they must coexist:

- **`boot_mode = user`** (default; M0–M6 unchanged): the existing behavior —
  reset to the TB-supplied `init_eip`/`init_esp`, flat 4 GB segments (the
  post-OS-loader state that matches `qemu-i386` linux-user). `make verify` stays
  GREEN — this is a HARD requirement; M2S.1 must not regress user mode.
- **`boot_mode = system`** (M2S): cold reset matching `qemu-system-i386`:
  `CS:EIP = F000:FFF0`, **real mode** (CR0.PE=0), `cr0=0x60000010`,
  `EDX=0x00000663` (P5 CPUID stepping signature QEMU seeds), `eflags=0x00000002`,
  selectors real-mode, GPRs per reset. The bare-metal test (loaded into the
  guest-physical image the TB preloads) bootstraps from there.

## Scope (M2S.1 = real mode + segmentation; paging is M2S.2)

1. **Real mode (16-bit):** linear = `(seg<<4)+offset`; the operand/address-size
   (`66`/`67`) prefixes the bootstrap uses (esp. `66 ljmp ptr16:32`); 16-bit
   decode where needed; `LGDT`/`LIDT`; `MOV` to/from `CR0` (and CR2/3/4 regs
   exist, but only CR0.PE matters here — CR3/CR4/paging = M2S.2).
2. **Real→protected transition:** setting `CR0.PE` (its retire updates `cr0`);
   the following far-jump loads `CS` from the GDT and switches to 32-bit PM — each
   its own retire record (single-step-atomic, matching the golden: PE@~n=20,
   far-jump@~n=21).
3. **Protected-mode segmentation:** on a segment-register load (`MOV sreg`, far
   `JMP`/`CALL`, `LSS`/`LDS`/…), read the 8-byte descriptor from GDT/LDT in
   memory, load the **hidden** base/limit/attr, and enforce type/limit/DPL/present
   checks → `#GP`/`#NP`/`#SS` (selector). Maintain CS/SS/DS/ES/FS/GS hidden state;
   protected-mode linear = `seg.base + offset` with limit checks. CPL from CS.RPL.

Out of scope here (later stages): paging/TLB (M2S.2), the full IDT/fault-delivery
pipeline (M2S.3 — for now a segmentation fault can halt or set `exc` if the test
doesn't fault), TSS/task switch (M2S.4), SMM (M2S.5), debug regs (M2S.6).

## Trace + comparator

- **TB (Producer C):** add `boot_mode`; in `system` mode boot the core at the
  reset vector. Extend the retire hook to emit the **sys** fields — `cr0` and the
  6 selectors (and, where the RTL is authoritative, `<seg>_base/_limit/_attr`).
  Emit a `sys:true` header (trace-format §2.4).
- **compare.py:** extend to call `func_compare_keys(x87, sys=True)` and **intersect
  keys present in both** producers. For M2S.1 the gdbstub golden supplies `cr0` +
  selectors + GPRs + eflags + eip — that is the gated compare. Segment **hidden**
  base/limit/attr aren't in the gdbstub g-packet (M2S.0 finding), so they are NOT
  directly diffed yet (they're exercised *indirectly* — wrong hidden base ⇒ wrong
  memory addressing ⇒ wrong GPR/memory ⇒ caught). Direct hidden-state diff via
  HMP `info registers` is a later refinement.

## Corpus + gate

- Add a **segmentation-only** bare-metal test `verif/sys/tests/pseg/` (real mode →
  GDT → protected mode → several segment loads + a couple of limit/type cases that
  do *not* fault → exit via `isa-debug-exit`; **no paging**), plus its
  `qemu-system-i386` system golden. (The M2S.0 `pmode` test, which enables paging,
  becomes M2S.2's gate.)
- **`make verify-sys` gate:** the `pseg` test is sys-diff-clean vs the golden
  (cr0 + selectors + GPRs + eflags + eip match across the real→PM boot and the
  segment loads). **HARD: `make verify` (user mode, `boot_mode=user`) stays GREEN.**
- Honest reporting: M2S.1 is large and may land **done-partial** (e.g. real-mode +
  the transition + flat-GDT loads working, with the gnarlier descriptor-check
  corners deferred) — never fake a green; keep the user-mode gates intact at all
  costs (revert rather than regress).
