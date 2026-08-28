# Task-switch phase contract (A4-H09)

**Status: OPEN / witness-modeled.** The fault vector and classifier fixes are
closed (uniform across both oracles and pinned case-by-case); the partial-state
phase behavior itself is an implementation choice, not ISA-exact closure. It is
witness-graded against this document only, pending either a reorder to the
pinned QEMU/SDM sequence with a true differential gate, or a P5 hardware
oracle for every disputed phase (see "Authority" below).

The hardware task switch is **not** a transaction on this core, and it is not one
on real P5 silicon or in the pinned QEMU either — a fault part-way through leaves
an architecturally *partial* switch that the `#TS` handler is expected to recover
from. This document names the phase boundary the RTL implements, so that each
phase's side effects, error attribution, and resume state are explicit instead of
implied by the final incoming commit.

## The phases, per source (JMP / CALL / NT-IRET)

| # | phase | side effects on entry | failure vector / attribution |
|---|---|---|---|
| 0 | source validation (S_LJMP descriptor beats) | none (reads only) | descriptor P/type/limit/busy checks: `#NP`/`#GP`/`#TS(selector)`, **no state moved** — R2-C01 matrix, TI preserved |
| 0b | current-TR precheck (R2-H04) | none | current TSS invalid/limit → `#TS`, before any outgoing write |
| 1 | `S_TSW_SAVE` — outgoing image | 16 dword writes into the CURRENT TSS (EIP, EFLAGS, 8 GPRs, 6 selectors; LDTR is deliberately NOT written — the outgoing LDTR field is static task-creation state, and writing it corrupted the outgoing task) | `#PF`/`#TS` mid-save: outgoing TSS partially written, TR still the outgoing task, NT/backlink/busy untouched. QEMU saves at the same relative point (after incoming reads, before LDTR checks) |
| 2 | `S_TSW_READ` — incoming image | reads into `tsw_*` staging (no guest-visible effect) | `#PF`/`#TS`: outgoing save stands (phase 1), incoming TR not committed, busy bits untouched |
| 3 | `S_TSW_LDT` — incoming LDT descriptor | reads only | `#TS(ldt_sel)`: same partial state as phase 2 |
| 4 | `S_TSW_SEG` — incoming segment descriptors | reads only (staged bases/limits/attrs) | `#TS(sel)` for a type/privilege/null/bounds failure, `#NP(sel)` for a presence-only failure (the pinned oracle's `tss_load_seg` order: S/type/privilege before P), before any commit; a null incoming selector stages zeros (R2-C02) |
| 5 | `S_TSW_BUSY` — busy/backlink + commit | beat 0: incoming descriptor busy byte (9→B); CALL form: back-link word into the incoming TSS + NT set; JMP/NT-IRET: outgoing busy clear (B→9). Final beat commits TR, CR0.TS=1, incoming EIP/CR3/CPL | a fault between the two busy writes leaves the OUTGOING descriptor busy (safe: that task is still running) and the incoming one busy-but-not-entered — recoverable by the `#TS` handler; this is the REVIEW2_aug2 C-05 order, chosen so no reachable partial state shows a running task as available |

## Explicit invariants

- Phases 0–0b are side-effect-free; the first guest-visible write is phase 1's
  outgoing save. Both oracles (SDM 8.2's enumerated steps, QEMU `switch_tss_ra`)
  also fault after outgoing saves for incoming-LDTR/segment problems — the
  pselnull oracle gap documents the one ordering where the RTL is *stricter*
  (incoming-LDTR TI prevalidation in `S_TSW_READ`, before any state moves).
- Busy-bit order within phase 5 is incoming-set then outgoing-clear (never the
  reverse), so a mid-phase fault cannot mark a still-running task available.
- The final incoming commit (TR, TS, EIP, CR3, CPL, hidden caches) is the last
  beat of phase 5; nothing after it can fault as part of the switch.

## Authority

The differential gate against the pinned QEMU is the authority for every
behavior reachable in a clean run; clean task switches (JMP/CALL/NT-IRET,
paged and unpaged) are differentially green (`ptask`/`ptaskpg`/`ptaskcpl`/
`pcalltss`). For fault-injection partial states the two implementations
evaluate the phases in deliberately different orders (QEMU's `switch_tss_ra`
is incremental — commit, then post-commit LDTR/segment validation; this core
validates pre-commit so no reachable partial state is half-installed, the
C-09/C-05 atomicity requirement). Where the orders differ the partial states
necessarily differ too, and those cases are **witness-graded against this
document**, not diffed — `ptswflt` enumerates each per-phase delta against
the pinned source. What the phase-model choice may NOT change is the
semantic content of a fault: vector, error code, and attribution per failure
class follow the pinned oracle (`#TS(sel)` type/privilege, `#NP(sel)`
presence, `#PF` with the faulting address), and those are pinned by the
`ptswflt` cases. No P5 hardware oracle is available in this checkout; if one
is ever obtained, every disputed phase above must be re-pinned against it and
this section replaced.

## Regression

`pselnull` cases D/E pin the LDTR/null-selector boundary (witness + oracle-gap
pins). The fault-injection matrix (`ptswflt`) injects `#NP`/read-only/
page faults and malformed descriptors at every phase above and checks old/new
TR, both busy bytes, back-link, the outgoing TSS image, CR3, CPL, selectors,
and the saved fault EIP against QEMU where the phase order is shared, with
witness-only pins where QEMU's differs (the pselnull pattern).
