<!-- Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com) -->
<!-- SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1 -->

# Ventium coverage suite (`verif/cov/`)

A code-coverage + ISA-execution harness that drives the **full user-mode ISA
assembly suite** through a Verilator **`--coverage`** build of the core, measures
how much of the RTL is exercised and how correct it is, and surfaces every
problem so the suite can be iterated toward 100 %.

It answers four questions in one run:

1. **How much RTL is covered?** — per-file Verilator **line + toggle** coverage
   (`cov_summary.py`), with the least-covered files ranked so you know where to
   aim next.
2. **What ISA is actually executed?** — the executed-opcode histogram is built
   from **retired instructions** (one record per committed instruction in the
   RTL trace), *not* from a static disassembly of the image. Retired ==
   genuinely executed on the silicon model.
3. **What is unimplemented / broken?** — for every test the RTL retire stream is
   diffed against the QEMU golden. The first instruction the core **fails to
   retire** (the `d_unknown → S_HALT` "stopped-short" signature) or where it
   **diverges** is decoded and named — that is the exact gap to fix.
4. **Are the caches covered?** — a dedicated memory-subsystem run
   (`run-mem-cov.sh`) coverage-instruments the faithful standalone cache/bus
   testbenches.

The coverage build lives in its own `obj_dir_cov`, so `make verify` and every
existing gate keep using the byte-identical default `obj_dir/tb_ventium`.

## Quick start

```sh
make coverage-all    # every lane + the combined CORE (ISA+SYS) headline
# or run a single lane:
make coverage        # user-mode ISA suite -> core coverage + ISA report + correctness
make coverage-sys    # bare-metal images in --system mode (privileged paths)
make coverage-mem    # cache/bus subsystem coverage (ven_l1d / axi / l2)
make coverage-unit   # optional engines (idiv / srt / sqrt / bcd / fbld) + biu_p5
```

## Four complementary lanes

Verilator only instruments the modules a build **instantiates**, so no single
run can cover everything. Coverage is gathered in four lanes and rolled up:

| lane | runner | covers | top |
|------|--------|--------|-----|
| ISA  | `run-cov.sh`      | the core under the user-mode ISA corpus | `ventium_top` |
| SYS  | `run-sys-cov.sh`  | the core under bare-metal `--system` images (int/IRET/seg/TSS/SMM/paging/TLB) | `ventium_top` |
| MEM  | `run-mem-cov.sh`  | `ven_l1d` / `ven_axi_master` / `ventium_l1_axi` / `ven_l2` | standalone TBs |
| UNIT | `run-unit-cov.sh` | optional iterative engines (`ven_idiv`, `fpu_srt_div`, `fpu_sqrt_iter`, `ven_bcd`, `ven_bcd_to_fp`) + `biu_p5` | standalone gates |

ISA + SYS share the `ventium_top` hierarchy, so they **merge** into the
authoritative CORE coverage number (`run-all-cov.sh` does this:
`build/cov/combined/cov_summary.txt`). MEM/UNIT cover leaf modules under their
own tops and are reported separately.

### Measured baseline (this checkout)

| pool | line | toggle |
|------|------|--------|
| CORE, user-mode ISA only | 55.2 % | 54.7 % |
| **CORE, ISA + system-mode** | **80.6 %** | **59.5 %** |
| ven_l1d / ven_axi_master / ven_l2 | 75 / 74 / 95 % | 43 / 37 / 64 % |
| ven_idiv / bcd / sqrt / srt / biu_p5 | 92 / 83 / 78 / 68 / 90 % | 99 / 98 / 83 / 73 / 63 % |

Adding the system-mode lane lifted core line coverage 55 % → 81 %; the next gap
the report points at is `biu_p5` (pin-level bus, exercised only via the UNIT
lane / `make bus`).

or directly:

```sh
bash verif/cov/run-cov.sh                 # whole suite
bash verif/cov/run-cov.sh t_shift t_mul   # just these programs
GOLDEN=0 bash verif/cov/run-cov.sh        # coverage only, skip the QEMU oracle
COV_DEFS="+define+VEN_UOPCACHE" bash verif/cov/run-cov.sh   # widen RTL features
```

## What runs, per program

`run-cov.sh` discovers every `verif/tests/**/manifest.json` and, for each:

1. builds the ELF (`gcc -m32`, GNU as — no nasm),
2. `isa_verify`s it (pure original-Pentium ISA),
3. flattens it to a raw image (`elf2flat.py`),
4. generates the **QEMU golden** functional trace (the correctness oracle),
5. runs the **coverage TB** on the image, dumping a per-test `coverage.dat`
   (via `$VEN_COV_DAT`) plus the RTL retire `.vtrace`,
6. `compare.py --mode func` → **correctness** verdict vs QEMU,
7. `isa_coverage.py analyze` → executed-opcode histogram + the first
   unimplemented/diverging instruction.

Then it merges every `coverage.dat` (`verilator_coverage`), annotates the
sources, and prints the coverage + ISA reports.

## Outputs (`build/cov/`)

| path | contents |
|------|----------|
| `cov_summary.txt` / `.json` | per-file line/toggle %, least-covered ranking |
| `isa.txt` / `.json`         | executed-opcode histogram + unimplemented list |
| `annotated/`                | Verilator-annotated sources (`%`/`~` = uncovered lines) |
| `merged.dat`                | merged coverage database |
| `work/`                     | per-test ELF/flat/vtrace/compare logs |
| `dat/`                      | per-test `.dat` + `.isa.json` |
| `mem/`                      | memory-subsystem coverage (from `run-mem-cov.sh`) |

## Components

| file | role |
|------|------|
| `run-cov.sh`            | top orchestrator (build → per-test → merge → report) |
| `run-mem-cov.sh`        | dedicated cache/bus coverage (instruments `verif/l1/tb_*`) |
| `run-unit-cov.sh`       | optional arithmetic-engine coverage (idiv/srt/sqrt/bcd gates, --coverage) |
| `isa_coverage.py`       | retired-instruction decoder: opcode histogram + unimplemented/diverge detection (capstone) |
| `cov_summary.py`        | parses a Verilator `.dat` → per-file/overall line+toggle % |
| `tb_cov_l1d_sweep.sv`   | breadth sweep of `ven_l1d` (all 128 sets × 2 ways + evict + write-through + flush) |
| `verif/tb` `make cov`   | the `--coverage` core build (separate `obj_dir_cov`) |

The `tb_main.cpp` coverage dump is guarded by `#if VM_COVERAGE` and keyed off
`$VEN_COV_DAT`, so it is inert in every non-coverage build.

## Iterating toward 100 %

The honest baseline from the user-mode integer+x87 corpus is **partial**: the
large untouched regions are the **system-mode** paths (`core_smm.svh`,
`core_iret.svh`, `core_int_deliver.svh`, `core_tss_priv.svh`, paging/TLB) and
parts of the FP/transcendental datapath that the user-mode corpus never reaches.
To climb:

1. Read `cov_summary.txt`'s least-covered list and the `annotated/` sources.
2. Add an assembly test under `verif/tests/<name>/` (`.s` + `manifest.json`) that
   exercises the uncovered lines — it is auto-discovered, no Makefile edit.
3. For privileged/paging coverage, extend the runner to the system-mode images
   under `verif/sys/tests/` (run in `--system` mode) — a documented follow-up.
4. Re-run `make coverage`; confirm the % rose and no new divergence appeared.

Any instruction the core can't execute shows up in the `isa.txt`
"UNIMPLEMENTED / DIVERGING INSTRUCTIONS" section with its opcode-map cell,
mnemonic and the test + PC where it was hit.
