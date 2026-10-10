# UV-fast performance FPGA export — October 10

This is **UNQUALIFIED source preparation**, not a bitstream, timing pass or
transfer of simulation acceptance to silicon. Latest verified Quake gameplay
is **0.49038392 total U+V retirement-event IPC**, demand-fetch SoC model
`958f7ec4`, clocks **1,700,048,811–1,800,048,811**. All six consecutive 100M
windows from 1,200,048,811 average **0.489820525**: 0.49741357, 0.49761630,
0.49037029, 0.47794855, 0.48519052 and 0.49038392. The sub-0.48 interval is
retained. Latest audit: `ventium-sfetch16-latest-r3.NdYg8m3Q/audit.json`,
49,038,392 events (37,988,356 U + 11,050,036 V), raw advancing combat/explosion frames,
stable pins/native identity and no OOM. This does not replace the fixed first
gate **0.49741357**, clocks **1,200,048,811–1,300,048,811**. Its original pre-run plan
selects periodic samples12/13, not zero-offset interpolated clocks.
Audit:`ventium-sfetch16-gameplay.uR79KRxi/window/audit.json`:49,741,357 events
(38,343,171U +11,398,186V) over100M clocks,244 source/17 runtime pins,
matching native/service identity and no OOM. Both unchanged RGB endpoint
images were independently viewed: live weapon/HUD, corridor progression and
monster/explosion. Captures bracket the endpoints within500k-clock progress
records, not cycle-exact images. The first collector incorrectly demanded
globally uniform startup timestamps; its failed attempt is retained. The
corrected collector preserves the original sample indices and reports the
actual48,811-clock offset, with all counter families reconciled.
The fixed first window exceeds0.48, but it is not sustained acceptance;
full timedemo and silicon acceptance remain open. Private FST/C1/RET/converter-sharing
and protected-client PREFIX66 candidates have no gameplay
measurement. Equal-clock windows do not establish an equal-work speedup.

Historical larger-L2 model`86731249` measured0.49083588 at its fixed1.2B–1.3B
gate and0.49638834 at3.8B–3.9B. All27 consecutive100M windows1.2B–3.9B average
0.4813445296, including the2.3B–2.4B dip0.26103520. Those are partial-run
observations on the older model, not completion or the new candidate's average.
Current full direct-memory CoreMark
scores are **2.107843209 / 2.110905243 CM/MHz** on the separate `b5453f16` model;
they are not FPGA/cache/DDR scores.
The new [BIOS-bootable CoreMark port](../verif/bench/coremark_boot/README.md)
now completes both short CRC diagnostics on this exact cache-backed SoC:
5,096,514 / 5,085,420 TSC clocks for ten iterations, diagnostic ratios
**1.96212548 / 1.96640592 CM/MHz**. Both minimum-duration errors remain visible;
neither ratio is a valid score or a 2.1 target pass. This uses GCC 13.4 and a
bare-metal stack port, not the older GCC 13.3/Linux-user image.

The protected-client PREFIX66 private derivative `320c4232` now measures
**1.994712814 / 1.999582887** on the same short bootable diagnostics, both CRC
sets correct. It has started its own cold Quake run on CPU 6, service
`ventium-prefix66-quake-oct10.service`, invocation
`2e3e2dd5c8064373926d93d42703ac55`; actual native PID 516043, pinned model,
single-CPU affinity, UV/system/relocated fast load/store mode and unchanged
original demo1 disk are recorded. No snapshot, STEP or guest modification.
It remains gameplay-unmeasured and is **not included in this FPGA export**.
The retained supervisor and original 969-frame completion criterion stay in
force. The additional RET experiment `1cad4e49` saves only 520/247 clocks here,
not its older standalone gain; neither experiment is a duration-valid score.

Cold deployment now uses the checked-owner lifecycle helpers described in
[COLD_LIFECYCLE.md](board-tools/COLD_LIFECYCLE.md). Their host tests and the
fresh pinned package are not a board deployment or processor correctness pass.

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

Cold Quake remains active on CPU27. The independent cold Win95 run on CPU26,
service `ventium-sfetch16-win95-oct10.service`, invocation
`63dafab27323462dacd95f2752da438d`, reached the Welcome desktop. Root viewed
`win95-cold-sfetch16-oct10.1/frame_00004.ppm` through a raw RGB PNG conversion:
readable text, icons and taskbar, no visible error. Its closed raw SHA is
`0589d29b72d19308e5eb7eb4d62d0c96348cf6eb949d96c236f5d6a202f5f36c`.
An owned empty host-stop request then closed the native process at
995,227,441 clocks / 206,982,616 primary retirement events, native exit0,
actual wait, no terminal error, unchanged input pins and final no-OOM receipt.
This is **desktop observation plus CLOSED_UNQUALIFIED**, not a standard-suite
pass. The supervisor's final exit properties were not retained before systemd
garbage collection; do not fabricate them from the now-empty unit. Separate
closed-frame human review and support for this exact new build layout in the
strict checker also remain open. Existing checker requirements are unchanged.

Both guests use this exact model, fresh disks, UV/system/relocated fast mode,
original clocks/media and no snapshot/STEP. Neither is a completed standard-suite
result. The remaining five live October10 controllers now have the existing
`tools/hold_supervisor_closure.py` metadata keeper attached before closure,
under `ventium-oct10-supervisor.PiDsQ0zq`; it changes no guest or run behavior.

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

### Closed native synthesis and checkpoint audit

That synthesis completed at **2026-10-10 03:49:00UTC**, native exit0, in
**1,106.82seconds (18.45minutes)**. All source pins remained stable; no OOM,
resource stop or controller failure occurred. Scope peak was8GiB RAM and
0.654GiB swap. Actual native synthesis used `-no_timing_driven` and produced
`rk_ao486_bd_wrapper.dcp`; this is not a timing-closure result.

| Synthesized resource | Used | Device utilization |
| --- | ---: | ---: |
| CLB LUTs | 190,864 | 55.93% |
| Registers | 54,571 | 8.00% |
| BRAM tiles | 277.5 | 37.30% |
| DSPs | 47 | 1.33% |

Independent native project reopening at
`ventium-sfetch16-synth-audit.DendiK1P` completed successfully in63.40seconds,
with stable DCP/source pins and no OOM. It checks native run completion and
non-staleness, zero unresolved black boxes, and zero errors from actual
`MDRV-1`/`LUTLP-1` checks. Actual project clocks are **40MHz core /100MHz PL**.
The generated PS XDC's unknown-port clock warning remains in the original log;
the active core/platform clocks were independently verified, not inferred
from the command line. Other synthesis warnings remain; this is not a blanket
clean-DRC or CDC claim. LUT hierarchy totals use Vivado's reconstructed
hierarchy and must not be mistaken for isolated RTL module area measurements.

### Bounded implementation characterization

After the audit, `ventium-sfetch16-impl40.S3MGZiu2/run.py` resumes this exact
project without new synthesis or run reset. Controller invocation
`1c331a468aa345b081b456226536c6c9`, scope invocation
`ef3052a8447247e4b167d9a3d8fab614`. The existing resume script admits the
real40MHz clock first; `RuntimeOptimized` omits the previously crashing
`bram_power_opt` phase. The exported spread-placement/default-routing
profile stays intact. One Vivado family,90-minute timeout,10GiB RAM/4GiB
swap caps,13GiB combined early stop,2GiB runtime host/disk reserves.
Admission reserves2GiB RAM/4GiB swap beyond the caps. Starting disk admission
is10GiB for this existing-project operation, versus12GiB for full synthesis.
The global exclusive guard and ceilings are unchanged.

This is **P&R characterization, not qualified deployment**. It deliberately
retains the frozen source: the pending C1/FST repairs, canonical gate failures
and incomplete standard suite are not hidden by synthesis success. There is
no routed frequency result or new silicon acceptance yet. The repaired FST
model is separate; see [its closed tests](../fp_shared/tb/FST_REGISTER.md).

The implementation closed at **05:32:05 UTC** after its fixed 90-minute bound:
native timeout exit **124**, controller exit1, stable inputs, no resource stop
or controller failure and no OOM. Peak cgroup RAM was 9,213,423,616 bytes and
peak swap 1,212,366,848 bytes. All Vivado/vrs processes were gone afterward;
the exact controller's failed closure is retained by the metadata keeper.
Routing had not completed: global iteration1 reached zero overlaps, then
iteration2 ended at130 reported overlaps when the bound expired. Intermediate
global timing had WNS −31.972 ns; without final same-clock path reports this
is **not a CPU Fmax**. The requested 40MHz core /100MHz PL clocks are unchanged,
but neither is a new sign-off result. No bitstream was produced or deployed.
Placed/physopt checkpoints and native logs remain for analysis. The emitted
`iter_100_CongestedCLBsAndNets.txt` names only two CLB tiles and **no nets**;
do not infer a guilty RTL block from that empty net list. No automatic retry
was launched. Queued, bounded correctness builds can now acquire the normal
shared lock; they do not change the frozen FPGA source.

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
