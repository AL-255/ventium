# 8042 AUX status must describe the selected byte

October 14, 2026. **Private one-line repair, native microgate passed; not yet
full-PC qualified or installed.** Four recipe/coverage tests pass. No production RTL,
active synthesis input, guest image or FPGA image was changed.

## Defect and proposed repair

The current platform's `ps2.v` reports status-port bit 5 from
`!mouse_fifo_empty`, but chooses the port-60h data, interrupt and FIFO pop with
the **latched** `status_mousebufferfull` flag. Consider this ordinary sequence:

1. A keyboard byte arrives with both queues initially empty. OBF selects it;
   keyboard IRQ asserts and the latched AUX flag is zero.
2. A mouse byte arrives before software consumes that keyboard byte. The mouse
   FIFO becomes nonempty, but the already-selected output byte remains keyboard.
3. Port 64h reports AUX=1 while port 60h still returns the keyboard byte.

The repair changes only the status bit's source to `status_mousebufferfull`.
It does not add a register, FIFO, stall, replay, arbitration change or clock of
latency. The same owner now selects status, data, IRQ and consumption. Reset and
ordinary port-60h reads continue to clear ownership in the existing logic.

This is a software-visible routing problem: for example,
[Linux's primary i8042 driver](https://github.com/torvalds/linux/blob/master/drivers/input/serio/i8042.c)
selects the keyboard or auxiliary destination using the status sampled before
the data read. It is **not yet proof of the cause of any particular Windows 95
UI failure**. The older FIFO-loss/resynchronization proposals are separate and
are not silently included in this repair.

`prepare_aux_status.py` accepts only production SHA-256
`1e4920f53d5a9616d6b121a7148906490a3edd166d2aaecca5fa0ec9439fcf2d`,
which also matches the frozen fast-segment full-PC source. It rejects drift and
reapplication. The exact reversal test verifies that only one line changes.
The deployable derivative retains the original module name and license;
renamed parent/fixed/constant-zero/constant-one copies are test-only artifacts.

## Microgate coverage and limits

`tb_ps2_aux_status.sv` instantiates the actual production `iobus.v`, `ps2.v`
and `simple_fifo.v`, with the registered chip selects from `system.v`. It does
not seed FIFO memory or force/deposit architectural or peripheral state.
Inputs are wired-AND, odd-parity PS/2 frames or ordinary D2h/D3h controller
output-buffer commands. Those commands are explicitly distinguished from
wire-origin bytes and from device-command ACKs.

The completed matrix has **496 distinct stimuli per build profile**:

- Keyboard-only, mouse-only, both ordered arrivals, repeated status polling,
  interleaved queues and simultaneous wire arrival.
- Four combinations of keyboard/mouse wire versus controller-command origin.
- Translation on/off and IRQ enable/disable.
- Added I/O completion waits 0/1/7/31; each transaction must strobe exactly once.
- Wire half-periods 32/64/1875/2917 clocks for race and simultaneous controls.
- Full data/status/IRQ agreement, exact drain, and reset with both queues pending.

Each stimulus runs against both the unchanged parent and the one-line repair.
The parent must **fail** the three keyboard-owned/mouse-queued scenarios with an
explicit origin mismatch and pass the other controls. Failed native processes
remain failed bug witnesses, not controller passes. Constant-AUX mutants must
fail real keyboard/mouse cases, including wire and controller-command input.

Four profiles cover neither feature define, `VEN_KBC_FAST` alone,
`VEN_KBD_AUTOACK` alone and both (the full-PC candidate's setting). Headless
device-command ACK collisions, full-FIFO backpressure, parity recovery and
physical host-to-device commands are not qualified by this narrow test; see
the separate [loss-fix proposal](proposals/README.md).

## Actual state and reproduction

Recipe tests: `python3 -B -m unittest discover -s verif/ps2_ui -p test_aux_status.py -v`
finishes with **4 PASS**. This does not compile or run the RTL.

The first run waits for the exact timing sequencer invocation
`22c3239ddc57427ab4f265337a7d895c` to close. It then completes all **996 native
executions in profile 0**, but fails before profile 1 compilation: the driver's
negative-control loop shadows the RTL-source list with an integer. This is a
driver failure, not an RTL failure or a complete matrix pass. The failed
`ventium-ps2-aux-oct14-r1.service` invocation
`e58b5bea7ec94decbba0fbd572bdd755` and its receipt remain unchanged.

The two-line driver correction renames that loop variable; it changes no RTL,
fixture, oracle or expected result. The separate full rerun,
`ventium-ps2-aux-oct14-r2.service`, invocation
`527a4a8260594a0884b515c30fd3f329`, closes normally in **164.88 s**, native exit
0 / MainPID 0, with **3,984 executions** across all four compiled profiles:

- **1,984 repaired-case passes** (496 per profile).
- **1,024 unchanged-parent control passes**.
- **960 unchanged-parent bug witnesses**, each a native failure with the exact
  status/data origin mismatch, not a passing guest or controller result.
- **16 constant-AUX negative variants rejected** by the same origin check.

All source pins and native-log hashes were independently rechecked. Actual
CPU13 affinity is recorded for each native child. Peak scope RAM is
**918,839,296 bytes**, with zero OOM events and no swap.

Evidence root is `/home/yukidama/external/tmp/ventium-ps2-aux.syNvZwg1`.
Failed partial receipt `r1/closed.json` SHA-256:
`531dfb4e036eff28c41914039cb8603e6d0096d8775e4e0f3703ce14045581b2`.
Complete receipt `r2/closed.json` SHA-256:
`c20586f06a84633b1d4bdec25b7be45f9e76e027ec4124528bb0f211bd1ae042`.
The gate enters the **existing shared build lock**, uses Verilator 5.046 through
`tools/verilator_serial.sh`, then lowers its scope to **2 GiB RAM, zero swap,
64 tasks and one compiler**. Native CPU13 affinity is checked. Limits are 120 s
per compile, 10 s per stimulus, 590 s total, 4 GiB free external disk and 2 GiB
available host RAM. No root-disk fallback or concurrent Vivado build is allowed.
Fresh runs must use a new output leaf and set external `TMPDIR` explicitly.

For a direct run once heavy builds are idle, use the same bounded driver:

```sh
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
VENTIUM_VERILATOR_BIN=/tools/verilator/v5.046/bin/verilator \
VENTIUM_BUILD_SCOPE_PROFILE=default \
tools/build_scope.sh -- taskset -c 13 python3 -B \
  verif/ps2_ui/run_aux_status.py --out /home/yukidama/external/tmp/NEW_OWNED_LEAF
```

After native closure and no-open-handle checks, ten disposable PCH caches
were removed: **821,804,453 bytes**. All **5,005 protected source, receipt,
binary and log hashes** remain unchanged. The caches are regenerable, not
recoverable; exact targets are in `pch-prune-plan.json` and closure in
`pch-prune-closed.json`. No test model or evidence was removed.

Full-PC source transfer, differential/standard suite and
physical Win95 keyboard/mouse acceptance remain **open**. This peripheral
repair does not claim a processor timing or throughput improvement.

Gameplay baseline: **0.51186266 total U+V IPC**, older simulation `c7b95b78`,
cycles **1,700,065,237–1,800,065,237**. The fast-segment candidate and this
peripheral derivative have no gameplay measurement.

## Source-matched PC transfer — October 15

The one-line repair is now applied in the private source tree
`external/tmp/ventium-fprem-sequence.iSZ9BAj4/aux-status-soc-r1/source`.
**Prepared only: no compiler, guest, FPGA synthesis or deployment has run for
this derivative.** The active early-bus synthesis and older cold Quake inputs
are untouched. Compilation must wait until the exclusive synthesis/clock audit
sequence has closed, rather than overlap its memory use.

`fpga/build_aux_status_soc.py` independently re-audits all **3,984** original
native microcases using `audit_aux_status.py`: exact case/variant/profile
coverage, actual native verdicts, log and model hashes, retained successful
owner, source pins and zero OOM events. This is a **regrade**, not a fresh RTL
run. All 1,984 repaired cases pass; the 960 original-controller failures and
16 incorrect constant-bit variants remain explicit negative witnesses.
Three new host tests reject additional HDL changes, incomplete coverage,
wrong affinity, relabelled failures and false completion markers.

The PC parent is `593833e1650b5869373abbd74debcc63d15ea53eca1aa87f62e833982ead2fe9`.
Every copied source file is compared with it; only `rtl/soc/ps2.v` in the
ao486 platform differs, exactly matching the qualified one-line recipe and
microtested source `2ee3b64fc24875b3aaca0e6296a2514161f19cef5e6f79aa90923ca06f1846da`.
All **102 CPU/shared-FP source files**, all **157 definitions**, `cycle_mode=1`,
full P5 caches, strict waiting-x87, early-bus change and posted-16 transport
are unchanged. The host harness has a private basename for a future fresh
model; the existing guarded 32-job builder will verify its local object/header.
No candidate binary identity or inherited full-suite/timing pass is invented.

This does **not** integrate the separate FIFO-loss/resynchronization proposals,
add an interactive host UI, or claim that Win95 input is robust. Those known
limitations and physical keyboard/mouse acceptance remain open. The canonical
gate also remains red; this peripheral transfer does not fix its oracle/cycle
failures. Short CoreMark results on the parent are not results for this model.

Current verified gameplay baseline: **0.50520554 total U+V IPC**, older model
`c7b95b78f47f5e709136f98230bdf33975cf8db0e925956b469649cbf6384afd`, cycles
**5,600,065,237–5,700,065,237**. The early-bus and AUX derivatives are
gameplay-unmeasured.

## Current-core transfer and adapter regression — October 15, 22:37 UTC

The earlier early-bus preparation is **not the current processor candidate**.
`build_aux_status_soc.py prepare --parent-profile pipe-wait` now carries the
same one-line AUX repair onto the closed wait-cofactor PC model
`55e9255323354c314c102b2e7362ad3f9a5dfb1ca9c4e613a289f379936b6fce`, with
directed core `c9e4b9f86ad080f72ffd8ecef3d4ffc73eb1ecb8574ba7cd185bcae4fa3a643a`.
The explicit profile checks both identities and rejects failed/drifted closure.
No older CPU/FPU/cache files are copied back over the newer fixes.

Current prepared source is
`external/tmp/ventium-fprem-sequence.iSZ9BAj4/pipe-wait-aux-soc-r2/source`.
Independent readback verifies **18,011 input pins**, all **102 unchanged shared
core/FPU files**, all **157 unchanged simulator defines**, and only the
controller-line delta plus a private host-harness filename. Its prepared receipt
SHA-256 is `19728c8f243c4cecf796c9a977ade974b52d4157f5c2396d18fbc71276d04908`.
The preparation owner, `ventium-pipe-wait-aux-prepare-oct15-r2.service`, invocation
`d5155124351344a590432bee46ce0685`, is exited / MainPID zero / native zero.
**The full-PC derivative is still uncompiled, unmeasured and unqualified.**

The preparer also rejects overlapping input/output directory trees before
copying. Without that guard, selecting an output beneath the copied source
could recursively copy into itself and exhaust disk space. Five host tests
pass, including both exact parent profiles, false completion/incorrect negative
verdict rejection, one-line scope and overlapping-path rejection. The first
wait-core preparation (`pipe-wait-aux-soc-r1`) predates this guard and remains
superseded evidence, not an input to a future build. Its HDL is byte-identical
to r2; neither preparation launched a compiler.

The **unchanged combined adapter-path gate** then runs against that repaired
controller and the current 159-definition FPGA profile. Both KBC feature flags
are actually compiled. The ordinary local input socket, Python policy/adapter,
AXI management bridge, mailbox, serial transport and 8042/FIFO pass at:

| Clock | Host commands | Delivered bytes | Native time |
|---|---:|---:|---:|
| 3.125 MHz | 20 | 50 | 17.43 s |
| 40 MHz | 20 | 50 | 142.72 s |

The even-parity mutation exits **1** at the serial bit-9 check; it is a required
negative witness, not a passing native execution. Independent closure rechecks
all **40 pins**, actual CPU12 affinity, exact feature flags, terminal owner,
reaped children and matching repaired-controller bytes in r2. Peak memory is
**24,735,744 bytes**, with no OOM events under 256 MiB/no swap. The small Icarus
peripheral compile/test overlaps the owned Vivado family; no additional Vivado
or full-core compiler starts. All **14,126 live synthesis input pins** are
independently unchanged.

Evidence: `external/tmp/ventium-ps2-aux-adapter.ZWUZA8mW`, owner
`ventium-ps2-aux-adapter-oct15-r1.service`, invocation
`e101a954d6b848589d4798a8d2e35fa4`, native exit zero / MainPID zero.
Closed receipt SHA-256:
`04dbed0d6e95ebe96d2c22ee9cc099480840bfddb1a3ce4986809d6c1af80b33`.
The fixture used r1's identical repaired HDL; r2 additionally fixes the host
preparation guard. AXI callbacks remain a BFM, not physical ARM MMIO. This
regression does not instantiate the processor, execute Windows, replace the
mixed-keyboard/mouse ownership microgate, or qualify the separate FIFO-loss
proposals. Full-PC compilation, current-source mouse-wrapper integration,
canonical/standard-suite checks, timing and physical UI acceptance remain open.

No gameplay or frequency gain is claimed. Candidate gameplay IPC remains
**unmeasured**; the verified baseline remains **0.50520554 total U+V** on the
older `c7b95b78…` model/window identified above.

## Current-source mouse export boundary

`fpga/freeze_aux_mouse_rk_candidate.py` is the new export path for the current
wait-cofactor core plus the AUX repair and ordinary mouse transport. The older
`freeze_ps2_mouse_rk_candidate.py` export is a **158-define, older-core** artifact;
it must not be deployed as though it contains the latest 159-define processor.
Neither exporter edits the active synthesis inputs or starts Vivado.

The new exporter requires the exact current FPGA manifest
`d655cc8bf1dcea77cc82996c7ebade06387b3da07d7e83a65c84a0ed0a6feefc`, a successfully
closed source-matched AUX full-PC build and its exact terminal owner invocation.
It compares all **170 common HDL inputs**, permits only the qualified AUX line
to differ, retains all **159 hardware / 157 simulator defines**, and verifies
the actual generated model's compile command. All newer core/FPU/cache fixes,
strict waiting-x87 policy, UV/fast-pipe, full P5 L1s and posted-16 transport stay
in the source closure. The three reviewed wrapper transformations plus two
mouse modules produce **192 payloads**, with no other processor change.

The combined adapter proof above must match the exported repaired controller,
FIFO, management bridge and mouse modules byte-for-byte. Its successful owner,
positive runs, parity-negative witness and input hashes remain required. A new
Tcl source-contract check extends the **strict 159-define** profile instead of
silently removing `VEN_X87_MF_STRICT` to satisfy the older mouse checker.

Nine host/source-contract tests pass, including real current-source composition,
all inherited filelist/include edges, native Tcl expansion and negative controls
for old core provenance, unclosed/failed owner, extra RTL edits, missing strict
x87 mode, retired half-cache mode and missing/duplicate mouse inputs:

```sh
TMPDIR=/home/yukidama/external/tmp taskset -c 12 python3 -B \
  fpga/test_freeze_aux_mouse_rk_candidate.py \
  --source /home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/pipe-wait-fpga-r1 \
  --overlay /home/yukidama/external/tmp/ventium-ps2-mouse-overlay-r2.McPNAkCQ -v
```

After the exact synthesis/clock sequence successfully closed and its Vivado
scope became inactive, the AUX full-PC build completed in **22.95 s**, native
exit zero, with **18,011 unchanged input pins** and all 98 inherited structural
warnings unchanged. The private harness object uses this model's own generated
header. Owner `ventium-pipe-wait-aux-soc-build-oct15-r1.service`, invocation
`40c0859c175748bd8d010675a4cd1c5c`, is exited / MainPID zero. Verilator 5.046 was
first probed in the user-service environment. Compilation used the existing
guarded 32-job command, not an overlapping Vivado/compiler family.

New processor/platform simulator SHA-256:
`70c8de9eb55fda79b9fe359553ebd0b73de1e865c61414773000354edaff7b57`.
`pipe-wait-aux-soc-r2/build-closed.json`:
`2dd8025fd2e10345e97ff80dd5d280539005b87fa9a2c2189b43eefc80e9dcba`.
This is a **compiled, not guest-qualified** model; no new CoreMark, Win95 or
Quake execution is attributed to it.

The combined source export is now published at
`external/tmp/ventium-fprem-sequence.iSZ9BAj4/pipe-wait-aux-mouse-fpga-r1`:

- Manifest SHA-256:
  `d693f7b45f03baa7cb2d70c15ee162b47bd3e3fc5f8264d348c93bdfdbf4ecb5`.
- Freeze receipt SHA-256:
  `73677dff41c5fcaa6ee2466fd86f02cea971bcc9950dd1718daa324d73863ada`.
- Successful export owner `ventium-pipe-wait-aux-mouse-export-oct15-r1.service`,
  invocation `8ba30fbb717842f3979f3964d4cac15f`, exited / MainPID zero / native zero.

Independent readback rechecks **18,254 export input pins**, all **192 payload
hashes/sizes**, input aliases, all 18,011 PC build pins and the actual binary.
Only the AUX controller line and three wrapper files differ from the current
FPGA parent; the two mouse RTL modules are the only new payloads. Export peak
RAM is 189,693,952 bytes under a 1 GiB/no-swap/120-second bound. No Vivado run,
board reset, programming, firmware or guest-image change occurred.

The manifest explicitly leaves `simulator_sha256=null` because the PC model
does not instantiate the complete new FPGA mouse wrapper; it names the matched
processor/platform model separately. Full-wrapper elaboration/lint, timing,
canonical/standard-suite and physical UI acceptance remain required. This
integration does not qualify the separate FIFO-loss proposals or inherit its
parent's **37.951 MHz synthesized/unplaced** estimate as a new-wrapper result.
Gameplay IPC remains unmeasured for the candidate; the older verified baseline
and window above are unchanged.
