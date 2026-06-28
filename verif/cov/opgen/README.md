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

## Status (PM32 / user, CPL3)

`run-opgen.sh`: **217 PASS + 15 KNOWN + 0 NEW-FAIL** (clean). The 15 KNOWN are
real findings surfaced by the sweep (`known_diverge.txt`):

* **CORE-GAP** — `BT/BTS/BTR/BTC` with a *memory* operand HALT (reg-direct OK);
  `POP ES/SS/DS/GS` HALT (segment-POP gaps).
* **MODE-CPL0** — `CLI/STI/POPF` diverge on IF/IOPL because they are
  CPL0/system-mode ops (re-tested by the mode lanes, not a CPL3 bug).

The runner fails only on a **new** divergence, so a regression cannot hide.

## Dimensions still being generated

| dimension | status |
|-----------|--------|
| operand cases (reg/mem/imm, all ModRM/SIB via LEA) | done, validated |
| PM32 / CPL3 (user) | done (217 PASS) |
| **x87** opcodes (D8–DF, 141) | generator TODO |
| **branches** (Jcc/CALL/JMP/LOOP, J*) | generator TODO |
| **modes**: real-mode + PM32-CPL0 (privileged ops, 16-bit defaults) | mode-lane TODO |

The generated tests (`tests/op_*`, `tests/ea_sweep`) are build artifacts of the
generators (gitignored) — run the pipeline to (re)create them.
