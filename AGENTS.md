# AGENTS.md — Ventium

## Branches and current hardware

Ventium reconstructs the non-MMX Pentium P5/P54C in SystemVerilog. The current
board is **RK-XCZU15EG-F**, part **xczu15eg-ffvb1156-2-i**, using Vivado **2025.2**.
KV260 deployment recipes and early silicon failure lists are historical.

- **main** publishes the frozen source profile of board-tested image
  **2886d24c**, with a public FPGA build entry point and hash manifest.
- **experimental/uv-fast-ipc-apr** retains unqualified core/cache/performance/APR
  work and the full development harness; renamed from ao486-mister-sim.
  Do not replace its working RTL with the release snapshot or promote its RTL
  merely because another image passed.
- Inspect branch, dirty tree, filelists and hashes before working. Preserve
  uncommitted and submodule changes. Frozen sources are not necessarily the
  current checkout, even when define counts match.
- Read README.md and HOW_TO_RUN_FPGA.md. Older experimental-branch procedure
  sections are forensic history; use the exact dated image/source profile.

Last verified physical Quake gameplay: **0.496499864 total U+V IPC**, image
**2886d24c**, cycles **625,021,130,428–629,480,208,865**; primary/U alone
**0.383002768**. Counters include REP-element retirement. Quake completed at
7.7 FPS near 40 MHz. Both CoreMark seeds passed up to 52.6316 MHz; that does not
qualify Quake/Win95 at the higher clock. The conditional post-route timing
estimate is **28.701817 MHz**, not 40 MHz STA sign-off. Win95/full-suite
acceptance remains open for this programmable-clock image.

## Mandatory reporting and acceptance

Every progress/final report must state current **verified gameplay IPC**,
build/window, and whether it predates the candidate. Say explicitly if the
candidate is unmeasured and label the last verified number as a baseline.
Never substitute startup, CoreMark, microbenchmarks or targets for gameplay.
Distinguish total U+V retirement from primary/U-only counters.

**The differential gate is the correctness authority.** Never weaken masks,
convert failures into expected-failure pins, or trade correctness for cycle
matches. Repair/performance acceptance requires **U/V + system fast pipeline**,
including relocated protected-mode clients and fast load/store paths. Record
exact defines and `cycle_mode=1`, exclude STEP/intended-V breakpoints that
inhibit pairing, and prove actual paired execution. U-only/slow/single-step
runs are diagnostic controls only. Preserve ISA-required serialization and
precise-fault fallbacks; never force unsafe pairing.

The **standard test suite** means all three:

1. Both standard CoreMark seeds finish without error with reference data CRCs.
2. Windows 95 boots to a clean desktop.
3. Quake completes its full timedemo without error.

After major core/cache changes, pass the differentials and entire suite before
declaring completion. FPGA-targeted changes additionally require that candidate
on the physical board: cold Win95 desktop plus keyboard/mouse UI interaction
and a complete Quake timedemo in UV-fast mode. Retain logs/captures, source and
bitstream hashes, measured clocks and fresh V-retirement evidence. Simulation,
snapshots, a movie, a gameplay window or an older image's pass do not alone
establish current-image acceptance. Source-package CI is not a CPU/FPGA gate.

## Builds and verification

On **main**, the public source preflight is:

```sh
python3 -B fpga/build_known_good.py --check
tclsh fpga/test_known_good_wrapper.tcl "$PWD"
python3 -B -m unittest discover -s fpga -p test_known_good.py -v
```

Follow HOW_TO_RUN_FPGA.md for an explicitly authorized fresh build. No private
submodule is needed. Do not alter hash pins to silently bless experimental
inputs. A fresh implementation is not bit-identical or automatically qualified
by the original physical image.

On the **experimental branch**, inspect the actual target before launch:

```sh
make verify            # required after RTL changes
make verify-sys        # system-mode differentials
make l1                # memory subsystem
make bus bus-sva
make lint
make verify-all        # report PASS and expected failures separately
```

Most differentials require the private ventium-refs pinned QEMU oracle;
distribution QEMU is not interchangeable. The main generic Makefile/tests have
not been fully requalified against the imported FPGA profile. Missing, excluded
or blocked tests are never passes. Do not require recursive submodule checkout
for the public FPGA build.

Use ordered .f filelists, never glob RTL. Root rtl_ven_core.f/rtl_ven_soc.f
describe ao486-integrated hardware. The deployed profile uses full P5 L1s and
no enabled L2; never revive VEN_CACHE_HALF/narrow-I-cache flags. Read
docs/rtl-interface.md before interface edits and docs/trace-format.md before
trace edits. Emit .vtrace through verif/diff/tracefmt.py, not hand-formatted JSON.

Development safeguards:

- Use private variant object directories, not the canonical testbench output.
- Python guarded children must inherit the owner's real lock descriptor
  (`pass_fds=(9,)`); don't bypass locking to cure a self-deadlock.
- Set the Verilator executable explicitly for systemd; on the maintainer host
  it is /tools/verilator/v5.046/bin/verilator. Check the actual version.
- Verify actual child CPU affinity, not only systemd AllowedCPUs. Budget tasks
  for startup/helper pools as well as nominal workers.
- External C++ harnesses need per-model source basenames and verified local
  object/header dependencies; VPATH can reuse incompatible old objects.
- VEN_L1_AXI compilation does not select the TB backend: pass --l1-axi and
  verify traffic. FUNC/CYCLE jobs have separate extra-flag variables.
- Keep IMPLICIT/PINMISSING/UNDRIVEN/MULTIDRIVEN/LATCH/UNOPTFLAT lint failures
  fatal. Document narrowly scoped existing waivers.
- When decoder behavior changes, review the changed arms and update
  tools/opcode_map/coverage_data.json before regenerating its fingerprint/table.
  Never refresh only the fingerprint to conceal semantic drift.

## RTL invariants

- Keep one module per file, *_pkg.sv packages and raw core_*.svh fragments.
- The fragment engine owns split-page requests/merging. Detection uses
  cur_lin_nat, not redirected cur_lin; shaping freezes during S_WALK.
  Preserve probe-before-write and precise restart/abort semantics.
- Use the canonical translatable address generator. Keep segment identity in
  its separate combinational block; do not reintroduce the
  cur_seg_rel → acc_usr → perm_fault → bus loop.
- Non-cacheable accesses are byte-exact; AXI models must honor ARSIZE/lane
  semantics rather than silently widening reads.
- Posted DDR acknowledgement is not external completion. Preserve the true
  drain/fault barrier for I/O, debug halt and clock changes.
- Unsupported ISA must fail loudly rather than silently execute something else.

## Resources, cleanup and the public repository

- Use **one Vivado process family only**, through fpga/run_vivado_exclusive.sh.
  Replacement launches terminate previous same-user Vivado/VRS workers for the
  selected installation. Check ownership first; don't launch an audit over
  useful active work or leave orphan workers.
- User policy permits uncapped Vivado RAM/swap. Don't stop solely for swap use
  or kill unrelated applications. Retain ownership/task/runtime/disk safeguards
  and actual OOM/error monitoring. Historical experimental controllers may
  still contain old caps: inspect them before launching.
- On the maintainer host, all new runs/build scratch belong under
  /home/yukidama/external/tmp with explicit TMPDIR. Verify mount/writability/free
  space; don't fall back to root or create home-directory work folders. Other
  hosts should choose an explicit scratch volume.
- external/ventium_run backs live repository symlinks. Prune only reviewed,
  closed disposable artifacts; preserve source edits, media, accepted binaries,
  frozen inputs and useful evidence. Never follow cleanup symlinks. Record
  exact deletions and recoverability.
- This repository is **public**. Never commit credentials, private references,
  HDD/OS/game images, generated DCP/bitstreams, simulator products or other large
  blobs. Retain third-party licenses. PROGRESS*.md/REVIEW*.md are local notes,
  not publication inputs.
- Honor the user's stop/cancel request: don't restart background synthesis,
  simulation or board runs merely because a session resumes.
