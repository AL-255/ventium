# UV-fast performance FPGA export — October 9

This is **UNQUALIFIED source preparation**, not a bitstream, timing pass or
transfer of simulation acceptance to silicon. Latest verified Quake gameplay
is **0.43894030 total U+V IPC**, model `e9097d96`, clocks 1.2B–1.3B. The larger-L2
model below remains gameplay-unmeasured. Current full direct-memory CoreMark
scores are **2.107843209 / 2.110905243 CM/MHz** on the separate `b5453f16` model;
they are not FPGA/cache/DDR scores.

## Frozen inputs

`external/tmp/ventium-performance-fpga40.im8cm8YD` contains **186 payloads**,
135 definitions and an atomic input manifest:
`d04781ecd0a80a4a53e3707aba86b83a439cc1411044b4d5d7a8eeaf008a5279`.

The 181-payload parent is
`ventium-posted16-fpga40-r2.OVLOTtHM/inputs`, manifest
`890fc180a8f364db3e3276ea778e98dfb2c8ae193b45076051b317081b883b55`.
The performance source is the actual compiled, pinned source of
`ventium-l2-init-soc.tt7Ma9rk`, model
`86731249748f06e2baa1ba59ea3a92d5fb1313ca12b70935006374aad859c6df`.
Its native build closed successfully with stable pins, but retains **98
inherited structural warnings**; this is not clean whole-SoC lint.

Compared with the hardware parent: **11 payloads change and five core headers
are added**. The includes implement instruction-permission shadow, scalar FP
dispatch, held-read, reference-operand and AGI resident priming. The dependency
check caught their absence before output publication. Hardware definitions
equal the 133 actual compiler definitions plus only `SYNTHESIS` and
`VTM_NO_DPI`; the simulator already selected FPGA-style XPM memory behavior.

All core, FP, cache, bridge, headers and filelists are byte-identical to native
compiled inputs, except the reviewed `system.v` projection: hardware keeps
its original top/ports/line endings and changes only the L2 instance to
1,024 sets (256 KiB). Simulation-only board transport ports/body/connections
are **not copied into hardware**; the real hardware top already contains the
16-slot posted DDR bridge. Blindly copying the simulated wrapper would add a
second transport boundary. Original clocking remains 40 MHz core / 100 MHz
platform, with unchanged HP0 width/conversion and real posted-write drain.
The split 8 KiB P54C L1 caches, UV/system-fast load/store and pipelined FP stay
enabled. No slow/STEP fallback is admitted.

## Tools and checks

- `freeze_performance_rk_candidate.py` requires explicit parent/build/model
  hashes and canonical input/output roots. It rechecks native pins, accepts
  only the reviewed 11 changes/five additions, checks 117 filelist units and
  45 include edges, runs the real Tcl source contract, rehashes destinations,
  then publishes. No Vivado or board access occurs. The build receipt's one
  `~/external/.../build.py` alias is resolved to the pinned driver and checked
  again; RTL/model/output aliases remain forbidden.
- `test_freeze_performance_rk_candidate.py`: **17 host tests** cover exact
  definitions, each missing feature, profile drift, CRLF/LF preservation,
  model-only connection drift, missing/ambiguous/escaping includes and hidden
  filelist inputs. The existing **48 freezer tests** also pass.
- `test_performance_board_profile.py PARENT SIM EXPORT`: independently
  rehashes all payloads, build pins and model; proves the geometry-only
  projection and 166 byte-identical native source payloads; **30 real Tcl
  admission checks** pass, including legacy posted-parent admission and
  rejection of partial/reordered/duplicate/forbidden profiles.

Use `TMPDIR=/home/yukidama/external/tmp python3 -B` for these host tools.
Run the freezer with `--help` for its required named inputs; output must be a
fresh, empty, canonical directory outside the input roots. Refusal leaves
any incomplete output for inspection, never an accepted manifest. The first
attempt refused the driver alias; the next refused the missing headers.
Neither wrote payloads. Both issues were corrected before the successful export.

## Remaining gates

No Vivado run or board deployment was started. External free space was only
7.6 GiB, below the existing 12 GiB build-admission floor. A single guarded build
must satisfy storage/RAM admission and full implementation timing/resource
checks. The current generic differential gate remains failing, both cold
larger-L2 guests are still running, and no complete timedemo/standard-suite
pass is claimed. Hardware IPC must count **both** U and V retirements; the
legacy primary-retire debug pulse alone is insufficient.
