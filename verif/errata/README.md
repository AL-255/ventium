# Ventium M6 / M6B — Documented P5/P54C Silicon Errata (`verif/errata/`)

`make m6` (`bash verif/errata/run-m6.sh`) verifies Ventium's runtime-selectable models of **documented Intel Pentium (P5/P54C) silicon errata** behind `errata_en[4:0]` (`--errata <hexmask>`, **default `0` = clean core**).

## Oracle Discipline

QEMU `-cpu pentium` always computes architecturally clean results and never emulates P5 silicon bugs. Each check in `run-m6.sh` therefore self-checks against the **Intel Pentium Processor Specification Update** (`242480-022` / `242480-041`):
- With the erratum bit **ON**, RTL reproduces the documented silicon defect.
- With the erratum bit **OFF** (`errata_en == 0`), RTL produces the clean IEEE/SDM result, keeping `make verify` and `make verify-sys` green.

## `errata_en[4:0]` Bit Map (`rtl/core/core.sv`)

| Bit | Mask | Erratum | Intel Spec Update Reference | Current `make m6` Check |
| ---: | --- | --- | --- | --- |
| `0` | `0x01` | `FDIV` / SRT divide flaw | Erratum 23 (`242480-022` p. 78) | **Active** (4 checks) |
| `1` | `0x02` | `FIST`/`FISTP` overflow undetected | Erratum 20 (`242480-022` p. 75) | **Active** (2 checks) |
| `2` | `0x04` | `F00F`: `LOCK CMPXCHG8B` reg-dst hang | Erratum 81 (`242480-041` p. 51) | **Active** (3 checks) |
| `3` | `0x08` | `MOV moffs` (`A2`/`A3`) fails to pair | Erratum 59 (`242480-022` p. 99) | **Withdrawn / Inert Guard** (2 checks) |
| `4` | `0x10` | Erroneous `#DB` on V86 `POPF`/`IRET` `#GP` | Erratum 79 (`242480-041` p. 50) | **Active** (`--system`, 4 checks) |

## Per-Erratum Behavior & Self-Checks

1. **`FDIV` Divide Flaw (Erratum 23, `--errata 0x1`):**
   - For the canonical published pair `4195835.0 / 3145727.0` (`1.0111111...` divisor), `errata=0x1` returns the documented flawed `floatx80` quotient `0x3fffaab7f6392a768800` (`1.3337390689...`, wrong at the 13th binary digit), while `errata=0` returns the exact `0x3fffaabaa0e3e35a14bd` (`1.3338204491...`).
   - Non-published triggering divisors and non-triggering divisors return the exact quotient in both modes (no undocumented values are fabricated here; for first-principles PLA-wide reproduction across all operands, see `+define+VEN_SRT_FDIV_BUG` in [`../srt/README.md`](../srt/README.md)).
2. **`FIST`/`FISTP` Overflow Undetected (Erratum 20, `--errata 0x2`):**
   - On `4294967295.5` (`FISTP m32`, RNE), `errata=0x2` stores `0x00000000` with `IE=0` (documented *Actual*), whereas `errata=0` stores integer indefinite `0x80000000` with `IE=1` (documented *Expected*). (Distinct Erratum 21 is not modeled.)
3. **`F00F` `LOCK CMPXCHG8B` Register-Destination Hang (Erratum 81, `--errata 0x4`):**
   - Invalid `F0 0F C7 C9` latches `cpu_hung` (`CPU HUNG`) when `errata=0x4`, and halts cleanly as an invalid opcode without hanging when `errata=0`. Valid memory-destination `LOCK CMPXCHG8B` (`F0 0F C7 09`) never hangs in either mode.
4. **`MOV moffs` `A2`/`A3` Pairing Withdrawal Guard (Erratum 59, `--errata 0x8`):**
   - The early default-build `A2`/`A3` fast-path arm was withdrawn (`REVIEW_Jul29` H-02; safe moffs store fast-pathing lives separately behind `+define+VEN_FAST_MOFFS_STORE` in full-P5 builds). In the default build, `run-m6.sh` asserts that `errata_en[3]` is completely inert (`ON` trace == `OFF` trace) and that `A3` stays on the slow FSM (`paired=0`).
5. **Erroneous `#DB` on V86 `POPF`/`IRET` `#GP` (Erratum 79, `--errata 0x10`, `--system`):**
   - `err_dbgp/err_dbgp.bin` enters V86 at `IOPL=0` with a 4-byte data-write breakpoint (`DR0`/`DR7`) armed on linear `SS:ESP` (`0x2F000`) and executes `POPF`, which traps `#GP(0)` without touching the V86 stack.
   - `errata=0`: only `#GP` fires (`#DB` count `0`, `DR6` clear).
   - `errata=0x10`: erroneous `#DB` also fires (`#DB` count `1`, `DR6.B0=1`, saved `#DB` `CS:EIP` pointing to `gp_handler`'s first instruction), while the terminating `INT 0x20` (`IOPL` `#GP`) does not spuriously re-trigger `#DB`.
