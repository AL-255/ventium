# M2S.3 — interrupts / exceptions (IDT delivery)

Third system-mode RTL stage. M2S.1 (segmentation) and M2S.2 (paging) **compute**
fault decisions (`#GP/#NP/#SS` selector checks; `#PF` + `CR2` + error code) but
currently **HALT** instead of vectoring. M2S.3 turns those decisions — plus
software `INT` — into real **IDT-delivered** faults/interrupts, with the exception
frame, gate dispatch, and `IRET` return. Gated against `qemu-system-i386`.

## Scope

1. **IDT delivery.** On a fault/interrupt (vector `v`): read IDT entry `v` (an
   interrupt-gate or trap-gate descriptor; IDTR from `LIDT`, M2S.1), load the
   gate's target `CS:EIP` (with the segment descriptor load + checks from M2S.1),
   and push the **exception frame** on the (new) stack: `EFLAGS`, `CS`, `EIP`
   `[, error code]`. Interrupt gate clears `IF` (and `TF`); trap gate leaves `IF`.
   `EIP` ← handler. (Same-privilege delivery first; cross-privilege stack switch
   via TSS is M2S.4 — keep handlers at CPL 0 for now.)
2. **Restartability + priority.** A **fault** pushes the *faulting* instruction's
   `EIP` (restart); a **trap** (e.g. `INT3`, single-step) pushes the *next* `EIP`.
   When several conditions coexist, deliver by IA-32 fault priority.
3. **Error code.** Pushed for `#DF(8)/#TS(10)/#NP(11)/#SS(12)/#GP(13)/#PF(14)/
   #AC(17)`; not for the others. `#PF` also sets `CR2` (M2S.2).
4. **Software/cond:** `INT n`(`CD ib`), `INT3`(`CC`), `INTO`(`CE`, on OF),
   `BOUND`(`#BR`); the M2S.1/.2 hardware faults (`#UD/#GP/#NP/#SS/#PF`).
5. **`IRET`** (`CF`): pop `EIP`, `CS`, `EFLAGS` (near, same-privilege; the
   cross-privilege/NT task-return forms are M2S.4). In `boot_mode=user`,
   `int 0x80` STILL halts (no IDT there) — system-mode IDT delivery is gated.

## Corpus + gate

Add bare-metal tests under `verif/sys/tests/` (real mode → PM → IDT set up):
- `pintr` — software `INT n`/`INT3` to handlers that record + `IRET`; `INTO`.
- `pfault` — trigger `#PF` (touch a not-present page) → handler maps it (or counts)
  + `IRET`; trigger `#GP`/`#UD` → handler. Exercises the M2S.1/.2 decisions now
  *delivering*. Deterministic, ends via `isa-debug-exit`.
Generate `qemu-system-i386` goldens. **Gate:** `pintr`/`pfault` RTL `--system`
EQUIVALENT to the golden across the fault → frame-push → handler → `IRET` sequence
(cr0..cr4 + selectors + GPRs + eflags + eip; the pushed frame is checked indirectly
via the post-`IRET` register state + handler reads of the stack). Plus **pseg/pmode/
ppage stay sys-green**, and **`make verify` (user) stays GREEN** (IDT delivery gated
behind `sys_mode`; user `int 0x80`=halt unchanged).

Honest done-partial OK (same-priv delivery + `IRET` + the common vectors working;
cross-privilege stack switch deferred to M2S.4, exotic vectors documented). Never
fake a sys-diff; never regress user mode or the prior stages. Next: M2S.4 (TSS /
task switch / cross-privilege).
