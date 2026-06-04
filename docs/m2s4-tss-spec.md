# M2S.4 — TSS / task switch / cross-privilege

Fourth system-mode RTL stage. M2S.3 delivers faults/interrupts to **same-privilege
(CPL0)** handlers; M2S.4 adds the **privilege machinery**: cross-privilege delivery
(stack switch via the TSS), the inter-privilege `IRET`, the gate/CS protection
checks deferred from M2S.3, and hardware **task switches**. Gated vs `qemu-system-i386`.

## Scope

1. **TR / TSS (32-bit):** `LTR`/`STR`; the TSS descriptor (busy bit); the TSS
   fields used here — `SS0:ESP0`/`SS1:ESP1`/`SS2:ESP2` (privilege stacks) and (for
   a full task switch) the saved task state (`EIP/EFLAGS/GPRs/segs/CR3/LDTR`).
2. **Cross-privilege interrupt/fault delivery:** when the gate's target CS has DPL
   < CPL (handler more privileged), load `SS:ESP` from `TSS.ssN:espN` (N = target
   DPL), and push the **larger frame**: old `SS`, old `ESP`, `EFLAGS`, `CS`, `EIP`
   `[, errcode]`. (Same-priv path = M2S.3, unchanged.)
3. **Gate/CS protection checks (deferred from M2S.3):** gate Present (`#NP`), gate
   DPL ≥ CPL for software `INT n` (`#GP`), target CS descriptor present/type/DPL
   (`#GP`/`#NP`); a fault *during* delivery escalates toward `#DF`.
4. **Inter-privilege `IRET`:** after popping `EIP/CS/EFLAGS`, if returning to
   CPL > current (RPL of popped CS), also pop `ESP/SS` and switch back; SS/DS/ES/FS/
   GS null-on-lower-privilege checks.
5. **Hardware task switch:** `CALL`/`JMP` far to a TSS descriptor or a task gate,
   and interrupt through a task gate — save outgoing state to the current TSS, load
   incoming from the new TSS, set `NT` + back-link, toggle busy bits, load the new
   `CR3`/LDTR. (This is the largest/gnarliest piece — partial is acceptable.)

## Corpus + gate

- `pcpl` — set up a TSS (SS0:ESP0) + a CPL3 code/data segment + a user task at
  CPL3 that issues `INT n` (or faults); delivery switches to the CPL0 handler stack
  (SS:ESP from TSS), the handler runs, inter-priv `IRET` returns to CPL3. Verifies
  the stack switch + the 5-word frame + the CPL transition.
- `ptask` (stretch) — a hardware task switch via `CALL`/`JMP` to a TSS (or a task
  gate), verifying the state save/restore + NT/busy. May be deferred if too gnarly.
Generate `qemu-system-i386` goldens. **Gate:** `pcpl` (and `ptask` if it lands) RTL
`--system` EQUIVALENT to the golden across the privilege transition + handler +
inter-priv `IRET`. Plus **pseg/pmode/ppage/pintr/pfault stay sys-green** and
**`make verify` (user) stays GREEN** (all gated behind `sys_mode`).

Honest done-partial OK (cross-priv interrupt delivery + inter-priv `IRET` + the
protection checks working; the full hardware task switch deferred/partial +
documented). Never fake a sys-diff; never regress user mode or prior stages. Next:
M2S.5 (SMM/`RSM`).
