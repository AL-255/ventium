<!-- Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com) -->
<!-- SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1 -->

# Per-Opcode P54C Regression Generator (`verif/cov/opgen/`)

`verif/cov/opgen/` generates and runs a systematic per-opcode differential suite across all **555 non-MMX Intel Pentium (P5/P54C) opcode encodings** derived from `x86reference.xml` (`proc_start <= 5`, excluding P55C/MMX, P6 `CMOVcc`/`FCOMI`, SSE, and 64-bit forms).

## Pipeline

```sh
make opgen          # regen opspec + 721-form EA sweep + op_* tests, run in parallel, print 555-opcode accounting
make opgen-modes    # run real-mode / PM32-CPL0 mode streams against qemu-system-i386
```

Underlying scripts:

| Script | Role |
| --- | --- |
| `gen_opspec.py` | Filters `x86reference.xml` to the 555 P54C encodings (`372` ModRM, `283` `/digit` group extensions, `141` x87) → `opspec.json` / `opspec.txt`. |
| `gen_easweep.py` | Generates exhaustive 32-bit and `0x67` 16-bit ModRM/SIB effective-address `LEA` sweeps (`721` forms). |
| `gen_tests.py` | Emits one `op_<key>/` assembly test per user-mode opcode (16/32-bit operand sizes, carry-in `CF=0/1` diversity, immediate spreads, prefix combinations) + `opgen_status.txt`. |
| `run-opgen.sh` | Parallel build + `qemu-i386` golden + default `tb_ventium` run + `compare.py --mode func` across cores; fails on any **new** divergence not listed in `known_diverge.txt`, and flags any cataloged entry that now passes as `RESOLVED`. |
| `gen_modes.py` / `run-modes.sh` | Generates and diffs real-mode and PM32-CPL0 privileged/segment/far-transfer/interrupt streams against `qemu-system-i386`. |
| `run-transc.sh` | Re-runs transcendental opcodes against the feature-enabled `cov-feat` (`+VEN_TRANSCENDENTAL +VEN_FPREM +VEN_BCD_ITER +VEN_SRT_ITER`) build. |
| `coverage_report.py` | Reconciles all 555 P54C opcodes into `TESTED`, `MODE`, `COSIM`, `FINDING` (`known_diverge.txt`), `DEFER`, and `SKIP` (`0` uncovered). |
| `gen_repros.py` | Emits standalone minimal single-instruction reproducers (`repros/`, `REPROS.md`) for cataloged default-build findings. |

Generated test directories (`tests/`, `modes/`) are gitignored build artifacts.

## Default-Build Catalog (`known_diverge.txt`) vs Full-P5 / System Gates

`run-opgen.sh` tests the **minimal default `ventium_top` user-mode build** (`verif/tb/obj_dir/tb_ventium`, without `KV_FULL_DEFS` / `VEN_FP_SHARED` / `--cosim`). Several entries in `known_diverge.txt` reflect intentional default-build gating or CPL3 `linux-user` semantics rather than defects in the full-P5 system/FPGA profile (`c0e3fe43`):

- **Resolved in `opgen` (`RESOLVED` & regression-protected):** Memory-destination `BT`/`BTS`/`BTR`/`BTC` (register and immediate forms, `0F A3/AB/B3/BB`, `0F BA /4..7`) and memory-destination `SHLD`/`SHRD` (`0F A4/A5/AC/AD`).
- **Feature-gated x87 transcendentals (`TRANSC`):** `F2XM1`, `FYL2X`, `FPTAN`, `FPATAN`, `FYL2XP1`, `FSINCOS`, `FSIN`, `FCOS` halt loudly (`d_unknown → S_HALT`) when `+VEN_TRANSCENDENTAL` is off in the plain default build, and execute in `+VEN_TRANSCENDENTAL` / `VEN_FP_SHARED` (`u_fp_shared` on `c0e3fe43`, verified in `verif/trsc/` and `fp_shared/tb/`).
- **CPL3 `linux-user` vs CPL0 system semantics (`MODE-CPL0`):** `CLI`, `STI`, and `POPF` IOPL behavior differ under QEMU `linux-user` at CPL3; verified `EQUIVALENT` at CPL0 in `run-modes.sh` and `make verify-sys` (`ppopf`, `pv86`).
- **System / full-profile instructions covered by `verif/sys/`:** `CLTS`, `INVLPG`, `LMSW` (`verif/sys/lmsw/`), `SMSW` (`verif/sys/smsw_memory/`), `LAR`/`LSL`/`VERR`/`VERW`/`SLDT`/`STR` (`verif/sys/tests/pverrw/`, `pltr`), segment `POP ES/SS/DS/FS/GS`, and `MOV moffs` (`A0–A3`) are exercised in `--system` / full-P5 configurations (`make verify-sys` and physical Win95/Quake/Doom on `c0e3fe43`).

> **Decoder Change Invariant (`AGENTS.md`):** Whenever decoder behavior changes, review every changed arm and update `tools/opcode_map/coverage_data.json` before regenerating its fingerprint/table — never refresh only the fingerprint to conceal semantic drift.
