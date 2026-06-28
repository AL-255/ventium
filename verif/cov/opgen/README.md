<!-- Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com) -->
<!-- SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1 -->

# Per-opcode regression generator (`verif/cov/opgen/`)

A **script-generated** regression suite with ONE test per Pentium-P54C opcode,
each covering all the cases for that opcode (every register, the ModRM memory
forms, immediate spreads) — built from the machine-readable opcode reference so
no opcode is missed by hand. The exhaustive ModRM/SIB **effective-address**
decode is covered once (LEA) across all forms; per-opcode tests cover operand
variants. Generation is **self-checking**: every test is assembled (gas rejects
a mis-encoding) and diffed against the QEMU golden (a wrong result is a
DIVERGE), so a missing/incorrect case can never pass silently.

## Pipeline

```sh
python3 gen_opspec.py     # x86reference.xml -> opspec.json/.txt (THE checklist)
python3 gen_easweep.py    # exhaustive ModRM/SIB EA sweep (697 LEA forms)
python3 gen_tests.py      # one op_<key>/ test per opcode (+ opgen_status.txt)
bash    run-opgen.sh      # PARALLEL build+golden+diff across all cores
```

* **`x86reference.xml`** — pinned copy of ref.x86asm.net's reference (the source
  of coder32.html). `gen_opspec.py` filters it to **P54C** (`proc_start ≤ 5`:
  8086…Pentium; MMX/SSE/PPro and 64-bit-only forms excluded) → **555 opcode
  encodings** (372 with ModRM, 283 group `/digit`, 141 x87).
* **`opspec.txt`** is the authoritative per-opcode checklist; **`opgen_status.txt`**
  records, for every one, GEN (auto test) / MANUAL (with reason) — nothing is
  silently dropped.
* **`run-opgen.sh`** fans the per-opcode workload out across **all cores**
  (`xargs -P $(nproc)`); each worker spins its own qemu-i386 gdbstub.

## Status (PM32 / user, CPL3) — integer + x87 + branches + special

`make opgen` (parallel, ~20 s on 32 cores): **397 PASS + 29 KNOWN + 0 NEW-FAIL
+ 0 ASM-FAIL** (clean), 436 op_* tests + the EA sweep + the synthetic
`op_prefixes` test. The runner fails only on a **NEW** divergence, so a
regression cannot hide. `make opgen-modes` runs the real-mode/CPL0 lane.

### Self-improvement log (continuous campaign)

* **cycle-mode coverage pass** — a `--cycle` pass over the flats lifts
  `decode.sv` 69 %→**100 %** line, core_fastpath 92.6 %, opgen core 56→60 %.
* **minimal repros** (`gen_repros.py` → `repros/`, `REPROS.md`) — one isolating
  instruction per finding for the RTL owner.
* **16-bit operand-size (66-prefix)** variants on the two-operand ALU/MOV ops.
* **16-bit addressing** (`addr16`/0x67) added to the EA sweep (721 forms,
  EQUIVALENT to QEMU).
* **prefix-combination** decode test (LOCK / segment-override / 66 / 67 / REP).

### Findings analysis (`known_diverge.txt`) — surfaced, NOT fixed here

The 25 KNOWN are real divergences the per-opcode sweep found (the core is
unchanged — these are an analysis catalog):

| class | n | what |
|-------|--:|------|
| **CORE-GAP** | 12 | `BT/BTS/BTR/BTC` with a **memory** operand HALT (reg-direct passes) — bit-string-on-memory looks unimplemented; `POP ES/SS/DS/GS` HALT (segment-POP gaps). |
| **TRANSC** | 10 | `F2XM1/FYL2X/FPTAN/FPATAN/FXTRACT/FYL2XP1/FSINCOS/FSIN/FCOS` are deferred → HALT without `+VEN_TRANSCENDENTAL` (work in the FLAGS/feature build); `FPREM1` differs on the `fstat` C2 flag. |
| **MODE-CPL0** | 3 | `CLI/STI/POPF` diverge on IF/IOPL — these are CPL0 ops; the difference is CPL3-user-mode semantics, validated properly by the (TODO) real-mode / PM-CPL0 mode lanes. |

## Dimensions

| dimension | status |
|-----------|--------|
| operand cases (reg/mem/imm, all ModRM/SIB via LEA) | done, EA sweep EQUIVALENT to QEMU |
| PM32 / CPL3 (user) — integer | done |
| **x87** (D8–DF, 141 incl. distinct transcendentals via `sec_opcd`) | done |
| **branches** (Jcc rel8/rel32, CALL/JMP/RET, LOOP, JECXZ, near-indirect) | done |
| special operands (LEA/SHLD/SHRD/AAD/AAM/CMPXCHG8B/string/PUSH-POP-rm) | done |
| **mode**: real-mode / CPL0 (flags, IF/IOPL, privileged MOV CR0/DR7, 16-bit) | done (vs qemu-system) |
| mode: PM32-CPL0 + more privileged/IO/far/seg streams | framework in place (`gen_modes.py`) |
| MANUAL (priv/io/far/seg/MOV-Sreg/MOV-moffs/fault) | listed in `opgen_status.txt` |

**PM32/user: 423 GEN, 383 PASS + 29 KNOWN + 0 NEW-FAIL** (clean). The 29 KNOWN
(`known_diverge.txt`) are real findings: CORE-GAP (BT/BTS/BTR/BTC and SHLD/SHRD
with a **memory** operand HALT; POP ES/SS/DS/GS HALT), TRANSC (transcendentals
deferred without `+VEN_TRANSCENDENTAL`), MODE-CPL0 (CLI/STI/POPF).

**Mode lane** (`run-modes.sh`): the real-mode flag/IF/IOPL/privileged stream is
**EQUIVALENT to qemu-system at CPL0** — confirming the MODE-CPL0 findings are
CPL3-user-mode semantics, not core bugs, and covering the privileged paths the
user lane can't reach.

```sh
bash run-opgen.sh    # PM32/user, parallel, vs qemu-i386
bash run-modes.sh    # real-mode/CPL0, vs qemu-system
```

Generated tests (`tests/`, `modes/`) are gitignored build artifacts — run the
generators to (re)create them.

## 100% ISA coverage accounting (`coverage_report.py` → `COVERAGE.txt`)

Every one of the **555 P54C opcodes** is accounted for (`python3 coverage_report.py`):

| bucket | n | meaning |
|--------|--:|---------|
| TESTED | 406 | generated `op_*` test, differential **PASS** vs qemu-i386 |
| FINDING | 30 | generated test that diverges — real core bug, **cataloged** (`known_diverge.txt`), for the RTL owner to fix |
| COSIM | 16 | IN/OUT/CPUID/RDTSC/INVD/WBINVD — covered by the `--cosim` lane (gated ops) |
| MODE | 38 | privileged / seg / flag ops — covered by the real-mode/CPL0 streams (`run-modes.sh`, vs qemu-system) |
| DEFER | 7 | far CALL/RET (psocfarcall) + INT/IRET (sys lane) |
| SKIP | 58 | prefixes, undocumented x87 aliases, removed-on-Pentium (TR regs), invalid POP CS — not standalone-testable |
| **UNCOVERED** | **0** | — |

**100.0% covered.** No opcode is un-addressed: each is validated, a cataloged
finding, lane-covered, or justifiably skipped. The 30 FINDINGs are the analysis
output (real core gaps — BT/SHLD-on-memory, POP-seg, transcendental-deferred,
CLTS/LMSW/INVLPG, MOV-moffs); the RTL is untouched.
