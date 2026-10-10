# AGENTS.md — Ventium

Ventium is an RTL reconstruction of the Intel **Pentium (P5 / P54C, non-MMX)** in
synthesizable SystemVerilog, simulated with **Verilator** and verified
**differentially against QEMU** (`-cpu pentium`). It is ISA-exact and
cycle-approximate for the subset it verifies: 5-stage dual-issue (U/V) integer
pipeline, pipelined x87 FPU (including a faithful SRT divider that reproduces
the FDIV bug), x87 transcendentals, split L1 I/D caches + TLBs + paging MMU,
full system mode (protected mode, interrupts, TSS task switch, SMM, V86, debug
registers), documented P5 errata behind a flag, a PC SoC peripheral set, and a
routed KV260 FPGA image that has run on real silicon (40 MHz sign-off, correct
to ~71.4 MHz overclocked).

**The differential gate is the authority.** Any RTL change must keep the gates
below green; never trade functional correctness for cycle matches.

## Mandatory IPC reporting

Every progress report to the user, including intermediate updates and final
status reports, must state the current verified gameplay IPC. Identify the
measured build/window and whether it predates the current candidate. If the
candidate has no gameplay measurement yet, explicitly say so and retain the
last verified gameplay number as a labelled baseline; never present startup,
directed microbenchmark, or target IPC as measured gameplay performance.
When a newer verified gameplay measurement is available, use that measurement.

## Mandatory UV + fast-pipe acceptance mode

Processor fixes and performance acceptance must run with U/V dual issue and
the system fast pipeline enabled, including relocated protected-mode clients
and fast load/store paths. Never count U-only, single-stepped, pairing-disabled,
or globally slow-FSM results as a repair or a standard-suite pass. Such runs
may only be explicitly labelled diagnostic controls. Do not substitute a
passing control for the original failing workload in UV + fast-pipe mode.
Record the exact build defines and the `cycle_mode=1` connection, verify no
debugger STEP or intended-V breakpoint suppresses pairing during acceptance,
and require evidence that the fast paired path is actually exercised. Retain
normal ISA-required serialization and fallback for unsupported fast-path forms;
do not force unsafe instructions to pair. Distinguish primary/U retirement
counters from total U+V architectural IPC in every performance result.

## Standard test suite (acceptance requirements)

From now on, the **standard test suite** means all three of the following:

1. CoreMark correctness: both standard seed configurations complete without
   error and their data CRCs match the reference (performance scoring is
   separate).
2. Windows 95 boots to the desktop without error.
3. Quake timedemo completes without error (reaching gameplay or saving a
   snapshot alone does not count).

Run and pass the entire standard test suite after any major core or cache-system
modification before declaring that modification complete. Keep the differential
gates green as well; the suite does not replace them.

## ⚠️ Current checkout state (branch `ao486-mister-sim`)

The `README.md` describes the `main`-branch state. On **this** branch:

- The core has been **swapped into the ao486_MiSTer PC platform** for
  full-system simulation via `ao486-sim/ven/ven_ao486_shim.sv` (see
  `ao486-sim/VENTIUM_SWAP.md` and `ao486-sim/DISK_BOOT_STATUS.md`). The current
  RK-XCZU15EG-F hardware procedure is `HOW_TO_RUN_FPGA.md`.
- `fpga/scripts`, `fpga/sd`, and `sw/` (PS-side software) are **not present on
  disk** — they live on local worktree branches
  (`worktree-wf_0a0fe247-468-1`); read them with
  `git show worktree-wf_0a0fe247-468-1:fpga/...`. Only gitignored Vivado
  output under `fpga/build/` exists here.
- **The L2/northbridge is DISABLED for now**: `ven_l2.sv`/`ven_northbridge.sv`
  are absent, `make -C verif/tb l1axi_l2` is a stub (fails via `check-nb`), and
  the `g_l2` generate branch in `ventium_l1_axi.sv` `$fatal`s at elaboration.
  All builds/gates use the default `EN_L2=0` configuration (REVIEW_Aug3 H-09).
- `verif/m7/` (Quake/Win95 lockstep), `verif/bench/`, and the `verif/soc/`
  gate scripts are **absent** from this checkout (`verif/soc/` holds only stale
  `obj_dir*` build artifacts); `run-verify-all.sh` explicitly logs them as
  excluded. `verif/soc/run-all-soc-gates.sh` from the README does not exist here.
- `rtl/README.md`'s "SoC integration (`rtl/soc/`)" section is stale — there is
  no `rtl/soc/` here; the SoC platform is the ao486 swap.
- Root filelists `rtl_ven_core.f` / `rtl_ven_soc.f` (paths relative to repo
  root) are this branch's filelists for the ventium-swapped ao486 PC build.

## Repo layout

```
rtl/                synthesizable SystemVerilog (~68 files, ~32k lines)
  core/               pipeline spine core.sv (~8.3k lines) + core_*.svh include
                      fragments, decode.sv, issue_uv.sv, u_pipe/v_pipe.sv,
                      decode_stages.sv, bpred_btb.sv, ven_idiv.sv, *_pkg.sv
  fpu/                x87: fpu_top.sv state, fpu_x87_pkg.sv floatx80 datapath,
                      transcendental engines, SRT/sqrt/BCD iterative engines
  mem/                icache.sv, dcache_timing.sv, tlb.sv, uopcache.sv,
                      L1/AXI subsystem (ven_l1d, ventium_l1_axi, CDC FIFOs)
  bus/                biu_p5.sv pin-level P5 bus FSM (+ default-OFF biu.sv)
  northbridge/        ven_cachemap.sv
  ventium_top.sv      verification top (owns the DPI retire point)
  ventium_pkg.sv      shared types + DPI imports (fence with VTM_NO_DPI)
  ventium.f           pinned filelist — packages first, never glob rtl/**
verif/              all verification (see below)
tools/              pipeviz, f3diff, opcode_map, p5xtrans, srt, quake snapshotting
ao486-sim/          full-PC Verilator harness (MiSTer ao486 platform + ventium swap)
docs/               m*-spec.md design docs, trace-format.md, sphinx/
fpga/               (KV260 Vivado flow — see branch caveat above)
3rd-party/          ao486_MiSTer, opl3_fpga submodules
ventium-refs/       PRIVATE submodule: Intel manuals + the pinned QEMU golden
                    harness (07-p5-emulation-harness) + prebuilt test ELFs
tmp/                scratch (~800 dirs; ignore)
obj_dir_*/          throwaway define-variant/debug sim builds; scratch state
```

## Build & verify commands

Prereqs: Verilator 5.x (5.046 in use), gcc multilib (`-m32`), python3 (stdlib
only for the core path; `capstone` optional for stricter EFLAGS masking).
**Most gates require the private `ventium-refs` submodule** — it provides the
pinned QEMU 8.2.2 builds (`07-p5-emulation-harness/build/qemu/build/qemu-i386`
and `build-sys/qemu-system-i386`); the distro QEMU is NOT a substitute.
`git submodule update --init --recursive` first.

```bash
make verify          # THE fast gate (~2s warm): func + M4/M5 cycle bands,
                     # parallel + golden-cached in build/golden-cache/.
                     # Run this after ANY rtl/ change. verify-clean drops cache.
make verify-sys      # system-mode gates (pseg/pmode/ppage/pintr/pfault/pcpl/
                     # ptask/psmm/pdebug/pv86 + the REVIEW_Aug3 regression set
                     # ptaskpg/pretfoutpg/pcalltss/pjmpgate/pltr/pretfres/
                     # piopermwrap/piretgp0 + the REVIEW1_Aug3 R2 set
                     # pxfer/pselnull + the Aug4 sets: pxprobe/pxc04*/pcgparam/
                     # pcg16/pcgpg/pxwalkd/pjmpoff/pdescprec/pint16f/psamepf/
                     # ptswflt + the REVIEW1_Aug4 set pxwrap/pxwrapm +
                     # the fragment-abort pair pxfrag (differential) +
                     # pxdplan (frame page-plan probe witness) +
                     # standalone scripts run-prsmflush-gate.sh,
                     # run-psmmmeta-gate.sh and
                     # verif/fxabort/run-fxabort-gate.sh) vs qemu-system goldens
make verify-all      # umbrella: gates classified PASS vs XFAIL-PINNED;
                     # success = VERIFY-ALL-OK (N correctness gates PASSED +
                     # M pin(s) HELD). verif/run-verify-all.sh GATES array =
                     # source of truth; expected-failure pins are reported
                     # separately, never as correctness passes. (No pins remain:
                     # xc04 moved to PASS with the R2-C03 walk freeze, and the
                     # ic-alias pin retired with the R2-H09 physical snoop tags
                     # — both 2026-08-04.)
make m1 m2 m3 m4 m5 m6   # historical per-milestone gates (m3=x87, m6=errata)
make l1              # L1/memory-subsystem gates (verif/l1/run-*.sh; incl. the
                     # REVIEW_Aug3 C-01 run-l1axi-narrow-gate.sh MMIO gate and the
                     # REVIEW1_Aug3 run-l1axi-route-gate.sh extent/router/CD gate)
make bus bus-sva     # biu_p5 protocol gates + SVA corpus
make docs-status     # M-02: status docs vs RTL/gates consistency check
make verify-srt verify-idiv verify-bcd verify-fbld verify-fppipe ...
                     # standalone iterative-engine unit gates (no refs needed)
make coverage[-sys|-mem|-unit|-all]   # Verilator coverage → build/cov/
make opgen           # per-opcode generated regression (555 P54C encodings)
```

Lint (`make lint` → `verif/lint/run-lint-gate.sh`, prints LINT-GATE-OK): the
structural classes `IMPLICIT`/`PINMISSING`/`UNDRIVEN`/`MULTIDRIVEN`/`LATCH`/
`UNOPTFLAT` are hard errors across five configurations (default, VEN_L1_AXI,
the deployed KV260 define set, VEN_BCD_ITER, and the FP_PS_ALL area-relief
profile); width/style warnings stay visible but non-fatal. The single-block
`lint_off LATCH` waivers in `core.sv` (the native DIV/IDIV scratch) and
`fpu_writeback.sv` are documented in place. The bare default-config invocation:

```bash
cd rtl && verilator --lint-only -sv -Wall -Wno-UNUSED -Wno-fatal \
  -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN -Werror-MULTIDRIVEN \
  -Werror-LATCH -Werror-UNOPTFLAT \
  --top-module ventium_top -f ventium.f +define+VTM_NO_DPI
```

Verilator builds are slow (minutes). Variant TB builds:
`make -C verif/tb OBJDIR=obj_dir_<name> VL_EXTRA_DEFINES=+define+VEN_FOO` —
**never clobber the canonical `obj_dir/tb_ventium`**.
Python drivers already inside `tools/build_scope.sh` must preserve its real
locked descriptor when launching a guarded child (`subprocess.run(...,
pass_fds=(9,))`). Python closes it by default; the nested guard then correctly
rejects the active marker and waits on its own parent's lock. Do not bypass
the lock/cgroup check to cure this self-deadlock. For systemd-launched builds
and gates, explicitly set
`VENTIUM_VERILATOR_BIN=/tools/verilator/v5.046/bin/verilator`; the user manager
does not inherit an interactive shell's compiler PATH. Check the trivial
`tools/verilator_serial.sh --version` probe in that environment before queueing.
For an external/private C++ harness, a fresh `OBJDIR` alone is insufficient:
Verilator's generated makefile can find an old harness `.o` through `VPATH`
and link it without recompiling against the current generated class layout.
Use a per-model private source basename, verify the harness object is local
to that model's object directory, and inspect its `.d` file for the matching
generated headers. Do not accept a build that silently reuses an external
model-dependent object. Keep failed builds and their native logs distinct.
Compiling `VEN_L1_AXI` does not select the testbench's AXI backend: pass
`--l1-axi` and verify backend activity. The unified gate uses `TB_EXTRA_FLAGS`
for FUNC jobs and separate `TB_CYCLE_EXTRA_FLAGS` for CYCLE jobs; setting one
does not configure the other. Preserve exact invocation and actual V-retirement
evidence when qualifying UV-fast execution; see `docs/UV_FAST_VERIFY_BACKEND_2026-10-08.md`.
When deriving a new model from frozen FPGA inputs, audit the entire source
closure against the intended revision and explicitly list deliberate deltas.
Matching define counts or preserving the parent's hashes does not incorporate
later committed fixes. In particular, old Oct 3 snapshots omit L1 response-owner
repair `0f12b208`; restore it before applying newer cache experiments. Never
describe a frozen derivative as the current checkout without that source audit.
Key `+define+` switches: `VTM_NO_DPI`, `VEN_TRANSCENDENTAL`, `VEN_SRT_ITER`,
`VEN_IDIV_ITER`, `VEN_BCD_ITER`, `VEN_FP_PIPE`/`VEN_FP_PIPE2`, `VEN_UOPCACHE`,
`VEN_L1_AXI`, `VEN_SEG_ENFORCE`. `cycle_mode` is a `ventium_top` **port**
(0 = functional, 1 = dual-issue cycle accounting), not a define.

Full-PC simulation (this branch's focus):

```bash
ao486-sim/setup.sh        # idempotent: submodule init + base patch + vencore
                          # patch (ao486-sim/patches/ao486_MiSTer{,_vencore}.patch)
                          # + build
make -C ao486-sim         # → ao486-sim/obj_dir/ao486sim (legacy ao486 core, top: system)
make -C ao486-sim ven     # → ao486-sim/obj_dir_ven/ao486sim_ven (Ventium-swapped
                          # cosim: rtl_ven_core.f + rtl_ven_soc.f + ven/ shim under
                          # +define+VEN_CORE; run from the ao486-sim/ CWD)
```

## The verification architecture (producer/consumer)

Everything diffs **`.vtrace`** JSON-Lines per-instruction architectural-state
traces. The format contract is `docs/trace-format.md`; the executable
definition is `verif/diff/tracefmt.py` — **emit traces only through
tracefmt.py, never hand-format**.

- Producer (golden, functional): `verif/qemu-trace/gen_trace.py` — QEMU
  gdbstub single-step; `--system` for qemu-system BIOS images.
- Producer (golden, cycle): `verif/qemu-plugins/p5trace.c` — TCG plugin
  (`make plugin`; needs QEMU_SRC + static libcapstone from refs).
- Producer (RTL): `verif/tb/` — Verilator C++ testbench
  (`./obj_dir/tb_ventium --out t.vtrace --image blob --load 0x.. --entry 0x..
  [--cycle] [--system] [--x87] [--errata 0xM]`).
- Consumer: `verif/diff/compare.py` (`--mode func|cycle`) and
  `compare_stream.py` (O(1) memory, for multi-million-instruction traces).
  Exit codes 0/1/2; gates print `*-OK` / `*-GATE-OK` markers.

Key `verif/` subdirs: `tests/` (user-mode corpus, auto-discovered via
manifest.json), `sys/` (bare-metal system images + `run-sys-golden.sh` +
directed non-differential gates: a20, seg, fenv, intlim, tsslim, retfsel,
callsel, xc04, unimpl, ...), `errata/` (`make m6`: FDIV/FIST/F00F/moffs/V86-db
— self-checked vs Intel spec updates, QEMU computes correctly so there is no
differential oracle), `cov/` (+ `cov/opgen/` per-opcode suite), `fpu87/`
(SoftFloat/TestFloat triangulation — needs the two `berkeley-*` submodules),
`trsc/` (transcendental gates), `external/test386/` (vendored GPL test386
differential), `bus/`, `l1/`, `srt|idiv|bcd|fbld|fppipe/` (unit gates),
`fxabort/` (focused --binary TB around the whole core: fragment-engine
abort/reset phases), `lib/` (shared golden-fan-out plumbing).

Gotchas: stale goldens must be regenerated deliberately (several gates exist to
catch drift); some gate scripts hide compile errors behind `>/dev/null` — check
`verif/CORE_VALIDATION_REPORT.md` for known pitfalls.

## Tooling (`tools/`)

- `tools/pipeviz/` — PySide6 interactive pipeline visualizer (Konata-style
  pipeline diagram, cache/TLB/branch/hotspot analysis tabs, asm/C authoring).
  `tools/pipeviz/run.sh <program.flat|.elf>`; deps in its `requirements.txt`;
  offscreen regression: `QT_QPA_PLATFORM=offscreen python3 tools/pipeviz/verify_examples.py`.
  Exhaustive README + `docs/user-guide.md`.
- `tools/opcode_map/gen_opcode_map.py` — regenerates
  `docs/sphinx/isa/opcode-map.rst` from `coverage_data.json` (source of truth).
  **Update `coverage_data.json` whenever a decoder arm changes in
  `rtl/core/core.sv`**; CI runs `--verify-rtl`.
- `tools/p5xtrans/` — executable C/`__float128` silicon spec for x87
  transcendentals; the bit-exact oracle the RTL engines must match.
- `tools/srt/` — Python golden models for the radix-4 SRT divider (FDIV-bug
  faithful), sqrt, rem.
- `tools/f3diff/` — QEMU-vs-RTL PC-stream diffing for FreeDOS-stall debugging.
- `tools/quake_snapshot.py` / `quake_fpstate.py` — fast-forward Quake past its
  ~1B-instruction init under golden QEMU and dump a bootable memory+regs image.

## FPGA (KV260) — flow lives on worktree branches (see caveat)

Vivado/Vitis **2025.2**, part `xck26-sfvc784-2LV-c`.
`vivado -mode batch -source fpga/scripts/impl_kv260_soc.tcl` (BD → synth →
impl → `ventium_kv260.{bit,xsa}` under `fpga/build/`); knobs `PL0_MHZ`,
`OUTTAG`, `FE_PIPE`. All current images use full P5 L1s (8 KiB, 2-way,
128 sets, 32-byte lines); `VEN_FP_PIPE2` was part of the 40 MHz image with
WNS +0.104 ns. PS-side apps (`ven_soc_app`,
`hid_kbd`, `fb_vnc`, `venclk.sh`) cross-build with
`make CROSS_COMPILE=aarch64-linux-gnu-`. Board deploy on stock Kria Ubuntu:
`xmutil loadapp ventium` (dfx-mgr); the verified recipe + bring-up gotchas are
in `fpga/sd/kv260-runtime/README.md` (on the worktree branch). Silicon
findings (40 MHz): `FWAIT` hangs, `MOV`-moffs not decoded, IVT/L1 coherence
gap blocks interrupt-driven real-mode guests — see README "On silicon".

## Conventions

- Use `/home/yukidama/external/tmp` for all new generated runs, temporary builds,
  and scratch files; set `TMPDIR` explicitly for commands that create temporary
  files. Check that the external filesystem is mounted, writable, and has enough
  available space before starting. Do not silently fall back to the root disk or
  create new top-level home-directory work folders.
  Existing repo symlinks into `external/ventium_run` are active backing storage,
  not permission to delete that entire tree. Prune only verified disposable,
  closed artifacts; preserve sources, media, accepted binaries and useful evidence.
- One module per file, filename == module name; packages are `*_pkg.sv`;
  `ven_*`/`vtm_*` prefixes for ventium-specific blocks; `core_*.svh` are raw
  `` `include ``d case-arm fragments of core.sv (netlist-identical — keep them so).
- **The fragment engine ("fx", REVIEW1_Aug3 R2-C03):** the core's mem ports are
  driven by the engine, not directly by the bus driver. `core_bus_driver.svh`
  produces `bd_*`; the engine (core.sv) splits any translatable beat that
  straddles a page into probe-then-execute fragments (reads: two translated
  fragments merged; writes: probe page 2, write page 1, write page 2) and gates
  the FSM-visible `mem_ack`/`mem_rdata`. S_LOAD/S_LOAD2/S_STORE keep the older
  xp_pend/xs machinery. Invariants: detection reads `cur_lin_nat` (never the
  redirected `cur_lin` — comb-loop hazard); engagement is registered except two
  loop-free intercepts; the
  sequencer freezes and all shaping outputs blank while `state == S_WALK`
  (`fx_walk_hold` — the walk is a detour of the producer's beat; an armed
  read-merge once corrupted the walk's PDE latch, the pxc04 defect).
- **One request-address generator (R2-M02, complete):** every translatable
  state's address is `cur_lin` (`cur_lin_nat` per-state in core.sv + the fx
  redirect); the bus driver's per-state address arms are deleted except the
  physical-by-definition states (S_WALK, S_SMI_SAVE/S_RSM, S_RMINT_*).
  CHECK 5 and `mem_addr_arm` are retired (there is no second generator to
  compare). The segment-identity drive (`cur_seg_rel`/`cur_seg_idx`) is a
  separate `always_comb` at the top of `core_bus_driver.svh` — sharing the bus
  driver's block closed the `cur_seg_rel → acc_usr → perm_fault → bus block`
  cycle (UNOPTFLAT, now a build error via `-Werror-UNOPTFLAT`).
- Non-cacheable reads are byte-exact pieces (R2-H01): the core drives read
  strobes, ven_l1d fragments into 1–3 aligned pieces, ven_axi_master issues one
  single-beat AR per piece with exact ARSIZE + lane mask. Any AXI slave model
  must honor ARSIZE (bytes on their own lanes) — see the `axi_slave_bfm` and
  `tb_main.cpp` axi_drive implementations.
- Use the `.f` filelists; never glob `rtl/**` (package ordering matters).
- Only lint waiver is `-Wno-UNUSED`. No formatter config; match surrounding style.
- Interface contracts to read before touching them: `docs/rtl-interface.md`
  (top ports, DPI signatures), `docs/trace-format.md`.
- Unsupported ISA reaches a loud halt, never silent failure
  (`docs/unsupported-isa.md`).

## Docs to read first

- `README.md` — project state (main-branch view), benchmark/IPC results.
- `docs/trace-format.md`, `docs/isa-coverage.md`, `docs/unsupported-isa.md`,
  `docs/modeled-by-effect.md`.
- `docs/m*-spec.md` — per-milestone design specs (m1 core … m11
  transcendentals, m2s* system mode).
- `rtl/README.md`, `verif/CORE_VALIDATION_REPORT.md`, `verif/qemu-trace/README.md`.
- `ao486-sim/VENTIUM_SWAP.md` — integration design;
  `ao486-sim/DISK_BOOT_STATUS.md` — historical forensic log;
  `HOW_TO_RUN_FPGA.md` — current RK-XCZU15EG-F build and verification procedure.
- Status/review trail: `REVIEW1_Aug3.md` + `PROGRESS_Aug3_R2FIXES.md` are the
  latest round; before them `REVIEW_Aug3.md` + `PROGRESS_Aug3_REVIEWFIXES.md`;
  `PROGRESS_Aug3.md` (disputed — do not trust its "all closed" claims),
  `PLAN.md`, `TODO.md`, `PROGRESS.md` are older; `docs_old/` historical.
- Sphinx docs (`docs/sphinx/`, https://al-255.github.io/ventium/): local build
  `sphinx-build -b html -W --keep-going docs/sphinx _site`; deployed by
  `.github/workflows/docs.yml` on push to main.
