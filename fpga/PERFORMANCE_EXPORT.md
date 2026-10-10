# UV-fast performance FPGA export — October 10

This is **UNQUALIFIED source preparation**, not a bitstream, timing pass or
transfer of simulation acceptance to silicon. Latest verified Quake gameplay
is **0.49929384 total U+V IPC**, larger-L2 model `86731249`, clocks 3.2B–3.3B.
The fixed 1.2B–1.3B gate remains **0.49083588**; the newer sample does not
replace it. All21 consecutive 100M windows from1.2B–3.3B average **0.47844824**,
including the2.3B–2.4B dip at **0.26103520**. The sustained target, full timedemo
and silicon acceptance remain open. New model`958f7ec4` has no gameplay result.
The latest audit is`ventium-l2-gameplay.VedZVnwA/latest-3300000000/audit.json`:
49,929,384 total U+V retirements over100M clocks, unchanged RGB endpoint frames
showing advancing gameplay, stable source/runtime pins, matching native/service
identity and no OOM. It is selected by latest complete timestamp, not highest IPC.
Current full direct-memory CoreMark
scores are **2.107843209 / 2.110905243 CM/MHz** on the separate `b5453f16` model;
they are not FPGA/cache/DDR scores.

Subsequent directed testing found [SRT C1 and reduced-precision exponent
defects](../fp_shared/tb/SRT_ROUND_FLOOR.md) in that unchanged FP source.
The value-repair proposal is private and has no gameplay/FPGA acceptance;
the new synthesis below also excludes that proposal. Do not treat
successful synthesis as closing either correctness defect.

## Current demand-fetch derivative

`external/tmp/ventium-sfetch16-fpga40.faJqNOcM` is the new **UNQUALIFIED**
186-payload /136-definition export, manifest
`91ba41600281207c754d32b3aeb0795cf9e5878ccce6b13519e14b672f9c404c`.
It copies the actual compiled source closure of SoC model
`958f7ec4ab8e5b2e12ccc8e35fec6fd987e1693ef480c5df432ccc6eeda9eff2`.
Relative to the previous performance source, it adds the tested default-off
`VEN_SFETCH16_DEMAND` experiment and cycle-equivalent estimator width reduction.
The old hardware parent therefore has12 changed RTL payloads, five new headers
and one separately SHA-pinned Tcl wrapper update. No current dirty RTL is
implicitly imported. The wrapper update enables the opt-in
[`logic_only` diagnostic](SYNTHESIS_PROFILES.md); it changes no clock or
timing-acceptance requirement.

Select the new source profile explicitly with `--variant sfetch16`, supply
`--wrapper-sha256`, and use `--synthesis-profile logic_only` to check that
profile during export. The default remains the original performance profile.
Counts alone do not admit missing/substitute/reordered features. The manifest
records the source-contract profile; the native controller separately pins
the actual environment and command. A source manifest is not a run receipt.

Checks on the new export:20 freezer contract tests,48 existing safe-freezer
tests,35 independent real-Tcl/source checks,25 UV/fast-path guards and7 synthesis
profile checks pass. Native strict CPU-hierarchy lint passes in2.37seconds
with all six structural warning classes fatal, actual136 hardware definitions
and stable payload hashes. Evidence:`ventium-sfetch16-hw-lint.d7uWMpzh/`.
This is not clean whole-SoC lint; the simulated platform still has98 inherited
structural warnings. Re-auditing the *old* export against changed live exporter
tools correctly refuses its old tool hash; its historical receipts were not
rewritten or weakened to claim current-tool provenance.

Cold Quake remains active onCPU27; cold Win95 starts independently onCPU26,
service`ventium-sfetch16-win95-oct10.service`, invocation
`63dafab27323462dacd95f2752da438d`. Both use this exact model, fresh guest disks,
UV/system/relocated fast mode, original clocks/media and no snapshot/STEP.
Neither run is a completed standard-suite result.

The new single native synthesis starts **2026-10-10 03:30:33UTC** at
`ventium-sfetch16-logic-synth.oLSgt6W7/`, controller invocation
`4f4e19065df643c69a441a87dd989891`, owned Vivado scope invocation
`b9884d7c4d9b44c6b2a4c9ed4ab0229c`. It uses40MHz constraints, one worker,
`logic_only`,8GiB RAM/6GiB swap caps, a13GiB combined early-stop threshold and
a90-minute bound. The normal shared/exclusive launch guards are unchanged.
Starting admission requires12GiB disk,10GiB available RAM (8+2 reserve) and
10GiB free swap (6+4 reserve); runtime host/disk reserves remain2GiB. This is
a lower-cap diagnostic based on the previous timing-optimization phase cost,
not proof that the full processor will fit or meet40MHz. Implementation and
deployment do not run from this controller.

Recoverable cleanup made room:1,264 closed failed-synthesis scratch files,
32,978 cached trace names and25 old trace/log files were independently hashed,
archived, reread and then unlinked by exact inventory. Hardlinked cache data
was counted only when actually freed. Net recovery was approximately6.84GiB;
archives, inventories and receipts are in`ventium-fpga-space.QMM3SwPU/`.
All models, media, source files and active-run inputs remain. Recover a file
with`tar -xzf ARCHIVE -C NEW_EMPTY_DIRECTORY -- EXACT_INVENTORY_PATH`; do not
extract over an active run. The four archives retain both successful and
failed test evidence; no failure was discarded.

## Previous October 9 frozen inputs

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

A previous single guarded synthesis started **2026-10-09 23:25:07UTC** at
`ventium-performance-synth40.t5wzn9jz`, invocation
`d08d8a9f17ff4f1a86fa4a40352ac84f`. It uses40MHz, `balanced`, one synthesis
worker, hard20GiB RAM/8GiB swap, a27GiB combined early-stop threshold, 2GiB
host/disk reserves and a4-hour bound, not an ETA. Input pins and live resource
samples are retained. Controller R1 refused a manifest list/count type error
**before any Vivado launch**; R2 checks the exact definition list and count.
The failed admission source/log is preserved. It closed at01:16:36UTC after
6,688.66seconds with native exit143 when the host memory/swap reserve fired;
this was not an OOM, successful synthesis or implementation. Source pins were
stable and the family was reaped. Its timing-optimization phase finished after
1h50m26s at18,805MB reported peak. No implementation started.

The generic differential gate remains failing. Larger-L2 Win95 closed normally
at a visually clean desktop but needs independent acceptance; Quake continues.
No complete timedemo/standard-suite pass is claimed. Hardware IPC must count
**both** U and V retirements; the legacy primary-retire debug pulse alone is
insufficient. Native synthesis, implementation timing/resource and deployment
checks remain mandatory before hardware qualification.
