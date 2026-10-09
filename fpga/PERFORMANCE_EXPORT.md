# UV-fast performance FPGA export — October 9

This is **UNQUALIFIED source preparation**, not a bitstream, timing pass or
transfer of simulation acceptance to silicon. Latest verified Quake gameplay
is **0.49083588 total U+V IPC**, larger-L2 model `86731249`, clocks 1.2B–1.3B.
This passes the fixed-window target, not full timedemo or silicon acceptance.
Current full direct-memory CoreMark
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

Strict `ventium_top` lint of the **actual frozen** 114-definition parent and
135-definition export also passes (native exit0, unchanged payload pins).
IMPLICIT/PINMISSING/UNDRIVEN/MULTIDRIVEN/LATCH/UNOPTFLAT are hard errors,
including the `SYNTHESIS`/`VTM_NO_DPI` branches. Evidence:
`ventium-performance-core-lint.YXj5sPxa/{inputs,closed}.json` and the exact
commands/logs. This checks the CPU hierarchy, not the complete SoC/vendor RAM
implementation or timing. All **131** existing board observer/ABI tests pass.
The exported shim already has capability-checked UV64 selectors76/77/78;
no duplicate performance counter or new observation RTL was added.

Use `TMPDIR=/home/yukidama/external/tmp python3 -B` for these host tools.
Run the freezer with `--help` for its required named inputs; output must be a
fresh, empty, canonical directory outside the input roots. Refusal leaves
any incomplete output for inspection, never an accepted manifest. The first
attempt refused the driver alias; the next refused the missing headers.
Neither wrote payloads. Both issues were corrected before the successful export.

## Remaining gates

No board deployment has occurred. External free space initially was only7.6GiB.
Checked cleanup removed54 regenerable GCC precompiled headers (4.424GiB), then
664 relocatable objects/static archives (71,222,760bytes) from six closed builds.
All sources, executable models, receipts, test evidence and guest data remain;
removed compiler products can be regenerated. Receipts:
`ventium-pch-cleanup.WHAS3yCU/removed.json` and
`ventium-object-cleanup.uqb5lvjO/removed.json`. Free space then cleared the exact
12GiB admission floor; rounded `df -h` output alone was not sufficient.

The earlier posted16 full synthesis stopped after4,469seconds at approximately
20GiB resident +7.38GiB swap, entering technology mapping after timing
optimization. The new export includes the separately measured tag-LUTRAM area
relief (isolated L1 LUTs22,051→13,014; FFs6,877→1,691), but also more L2 capacity.
Full-chip memory relief is **not assumed** and resource ceilings are unchanged.

A fresh single guarded synthesis started **2026-10-09 23:25:07UTC** at
`ventium-performance-synth40.t5wzn9jz`, invocation
`d08d8a9f17ff4f1a86fa4a40352ac84f`. It uses40MHz, `balanced`, one synthesis
worker, hard20GiB RAM/8GiB swap, a27GiB combined early-stop threshold, 2GiB
host/disk reserves and a4-hour bound, not an ETA. Input pins and live resource
samples are retained. Controller R1 refused a manifest list/count type error
**before any Vivado launch**; R2 checks the exact definition list and count.
The failed admission source/log is preserved. No implementation has started.

The generic differential gate remains failing. Larger-L2 Win95 closed normally
at a visually clean desktop but needs independent acceptance; Quake continues.
No complete timedemo/standard-suite pass is claimed. Hardware IPC must count
**both** U and V retirements; the legacy primary-retire debug pulse alone is
insufficient. Native synthesis, implementation timing/resource and deployment
checks remain mandatory before hardware qualification.
