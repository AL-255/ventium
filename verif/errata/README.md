# Ventium M6 / M6B — documented P5/P54C silicon errata (selectable, default OFF)

M6 reproduces five **documented** Intel Pentium (P5/P54C) silicon errata in the
RTL, behind a per-erratum enable flag that defaults OFF. Run with `make m6`.
(M6 landed the first four; **M6B** added Erratum 79 once the system-mode infra —
V86 (M7.2), DR data breakpoints + #DB delivery (M2S.6), and the IDT #GP delivery
FSM (M2S.3) — existed to reach it.)

## The oracle problem

QEMU `-cpu pentium` computes the **correct** result — it does not reproduce P5
silicon bugs. So there is **no differential oracle** for errata. Every check in
`run-m6.sh` asserts the value the **Intel Specification Update documents** —
with the flag ON for the defect, and with the flag OFF for the clean (QEMU-
matching) result. This is NOT a diff vs QEMU.

## Errata-enable mechanism

The core (`rtl/core/core.sv`) takes a 5-bit `errata_en` input (plumbed through
`ventium_top` from the TB's `--errata <hexmask>`, default `0`). Each bit gates
exactly one defect; with `errata_en == 0` the datapath is the clean M0–M5 core,
so **`make verify` stays fully GREEN** (the HARD requirement). Bit assignment:

| bit | mask | erratum | source |
|-----|------|---------|--------|
| 0 | `0x1` | FDIV / SRT divide flaw | Erratum 23, 242480-022 p.78 |
| 1 | `0x2` | FIST/FISTP overflow undetected | Erratum 20, 242480-022 p.75 |
| 2 | `0x4` | F00F: LOCK CMPXCHG8B reg-dst hang | Erratum 81, 242480-041 p.51 |
| 3 | `0x8` | MOV moffs A2/A3 fails to pair | Erratum 59, 242480-022 p.99 |
| 4 | `0x10` | Erroneous #DB on V86 POPF/IRET w/ #GP | Erratum 79, 242480-041 p.50 |

The core also exposes `cpu_hung` (latched) for the F00F hang.

## What each test asserts

1. **FDIV (Err 23).** Reproduces the **published failing operand** (spec's
   fallback path). Canonical public pair `4195835.0 / 3145727.0`. The divisor
   `3145727.0` normalizes to significand `1.0111111…` — matching the documented
   missing-PLA pattern `1.0111` + ≥6 ones. With errata ON for that exact pair:
   - errata ON: floatx80 `0x3fffaab7f6392a768800` = the documented flawed
     `1.3337390689…` (double `0x3FF556FEC7254ED1`), wrong at the 13th significant
     binary digit (exactly the documented severity).
   - errata OFF: floatx80 `0x3fffaabaa0e3e35a14bd` = the correct `1.3338204491…`
     (double `0x3FF557541C7C6B43`) = QEMU/M3 exactly.

   *Honest scope (important).* Intel never published the per-operand reduced-
   precision quotient **bits** (only the divisor-pattern trigger and the worst-
   case severity), and QEMU is correct, so an arbitrary triggering operand pair
   has **no oracle** to self-check a flawed quotient against. We take the spec's
   explicit fallback — *reproduce the published failing operands* — and inject a
   flaw **only** for operand pairs with an exact bit-precise published result
   (currently the one canonical pair, held in a table). The documented SRT
   **trigger** `srt_flaw_divisor()` is modelled and exercised, but it is only a
   gate: a triggering divisor **not** in the published table returns the **exact
   clean quotient** — we deliberately do **not** fabricate an Intel-undocumented
   value. Two extra self-checks assert this (see §What each test asserts): a
   *non-table triggering* divisor and a *non-triggering* divisor both divide
   bit-exactly even with the flag ON. So only the published, self-checkable error
   is ever injected; the family-wide flaw is **not** claimed reproduced.

2. **FIST (Err 20).** Reproduces *Erratum 20* only ("Overflow Undetected on Some
   Numbers on FIST", doc p.75). Erratum 21 ("Six Operands…", doc p.77 — the small
   ±0.0625/±0.125/±0.1875 up/down case) is a **distinct** erratum and is **not**
   modelled here. Operand `4294967295.5` (the documented 32-bit/nearest
   affected operand: unbiased exp 31, top 33 significand bits = 1) → `FISTP m32`:
   - errata ON: stores `0x00000000` (zero), IE **not** set — the documented
     *Actual* response.
   - errata OFF: stores `0x80000000` (integer-indefinite), IE set — the *Expected*
     (masked) response. (Memory is not traced, so the test reads the stored dword
     back into ESI and the FPU status word into EDI.)

3. **F00F (Err 81).** The invalid `F0 0F C7 C9` (LOCK CMPXCHG8B with a register
   destination):
   - errata ON: the core HANGS (`cpu_hung` latched, TB prints `CPU HUNG`).
   - errata OFF: loud HALT, no hang.
   - A valid **memory** form (`F0 0F C7 09`) does NOT hang even with the flag on.

4. **MOV moffs (Err 59).** Cycle gate. An `A3` moffs store followed by an EAX-
   referencing `MOV` (`mov %eax,%ebx`):
   - errata OFF: the follower PAIRS (cycle trace: pipe=V, paired=true).
   - errata ON: the follower does NOT pair (false EAX dependency) — pushed to its
     own U clock. moffs is fast-pathed **cycle-mode only** (func mode keeps it on
     the proven slow FSM, so there is no functional risk).

5. **Erroneous #DB on V86 POPF/IRET with a #GP (Err 79, M6B).** A **system-mode**
   erratum. The `err_dbgp` `--system` image bootstraps real→protected + paging +
   a TSS, arms a 4-byte data-WRITE breakpoint on the V86 SS:ESP **linear** address
   (`0x2F000` = `SS<<4 + ESP` = `0x2000<<4 + 0xF000`), then enters V86 at IOPL=0
   and executes a `POPF` — which, being IOPL-sensitive in V86, `#GP(0)`-traps to
   the monitor **without accessing the stack**. There is **no QEMU oracle** (qemu
   delivers the clean `#GP`; verified — the clean image reaches isa-debug-exit
   under qemu-system with no spurious `#DB`), so this is self-checked vs the
   documented 242480-041 Erratum 79 text (verbatim PROBLEM/IMPLICATION). The
   monitor's `gp_handler` counts `#GP` deliveries; a vector-1 `db_handler` counts
   `#DB` deliveries, reads DR6, and witnesses the saved EIP it popped. The exit
   accumulates the witnesses into the visible GPRs (read from the trace record
   where `edx == 0xcafe0079` and `eax != 0x42`, i.e. before the exit code clobbers
   `eax`):
   - errata OFF: only the `#GP` fires — `#DB` count `= 0`, DR6 cause bits clear,
     saved EIP `= 0`. The data breakpoint does **not** trigger (the stack was
     never touched) — the documented **Expected**.
   - errata ON: the erroneous `#DB` **also** fires as the `#GP` handler is entered
     — `#DB` count `= 1` (exactly one, not two), DR6.B0 set, and the `#DB`'s saved
     CS:EIP `==` `gp_handler`'s first instruction. This is the documented
     **Actual** + **Implication** (a `#DB` delivered in addition to the `#GP`,
     saved state pointing at the `#GP` handler entry).
   - **Negative control (implicit):** the breakpoint is on SS:ESP but `POPF` never
     writes it (it traps first), so a faithful clean core must not fire (OFF). And
     the erratum is documented **only** for POPF/IRET, so the RTL chain is gated to
     POPF/IRET — the terminate `INT 0x20` (also an IOPL `#GP`) does **not**
     spuriously fire the `#DB` even with the flag ON (the `#DB` count is exactly 1).

## Deferred errata (NOT verifiable here → tracked under M2S)

These are documented but cannot be reproduced/self-checked in a user-mode
functional+cycle model without the exception/segment/paging/system-mode/bus
infrastructure that M2S builds, or without real silicon. They are explicitly out
of M6 scope (m6-errata-spec.md):

- BTB multiple-allocation / BTB-flush, SMM/NMI/STPCLK#/RSM, APIC and dual-
  processing (xAP/xDP) errata — need system mode / bus / DP infra.
- CMPXCHG8B page-boundary #UD (Err 26), EIP corruption after FP + MOV Sreg
  (Err 32), 0F-misdecode (Err 42) — need the exception/segment/cache-line paths.
- FBSTP A/D-bit on 16-bit wrap (Err 83) — needs paging A/D bits.
- Timing / performance-counter errata (e.g. event-monitor counting) — no oracle.

(Debug-exception-on-POPF/IRET, **Err 79**, was deferred at M6 pending debug +
exceptions; it is now **reproduced** in M6B — see §5 above.)
