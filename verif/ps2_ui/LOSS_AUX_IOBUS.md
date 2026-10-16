# Current-AUX keyboard ownership backport — October 16

Private candidate only: no production submodule, active FPGA export or full-PC
model was changed. The existing FPGA synthesis does **not** contain this repair.

`prepare_loss_aux.py` combines the retained keyboard ownership/resynchronization
proposal with the newer latched AUX-status fix. Exact-position/context patching
rejects drift, reapplication and loss of the AUX expression. The result differs
from the previously tested resync proposal in **only that AUX expression**.

- Current parent SHA: `2ee3b64fc24875b3aaca0e6296a2514161f19cef5e6f79aa90923ca06f1846da`.
- Combined SHA: `9c9d62149a25a5e3f97683ca269b77d01dcf4034517c02a225a5bce0bd2dc405`.
- Retained proposal details/limitations: [proposals/README.md](proposals/README.md).

The fix retains a received scan byte and a pending headless ACK until the
selected producer actually writes the keyboard FIFO. A full FIFO gets credit
only from a real keyboard pop, not a mouse read. Headless ACK handling no longer
starts a physical transmit to a nonexistent keyboard. Held I/O writes have one
owner. Reset/self-test uses the proposal's existing inhibit/resync sequence.
There is no application-specific behavior, speculative replay or larger FIFO.

## Newly executed current-source integration test

`tb_loss_aux_iobus.sv` instantiates the actual frozen `iobus.v`, `ps2.v` and
`simple_fifo.v`; registered chip selects and delayed I/O completion match the
platform. Stimulus uses CPU-side I/O requests and ordinary PS/2 pins. Internal
observations are read-only; there is no force, FIFO seeding or saved state.

The 16 cases per controller cover:

- Exact receive-final/AUTOACK collision, with an actual coincidence witness,
  at half-periods 64 and 1,667 clocks. Scan then ACK must both reach port 60h.
- Full 64-byte FIFO plus a 65th ACK. IBF must remain asserted until a keyboard
  read permits that retained ACK to commit exactly once.
- Mouse output selected while the keyboard FIFO is full. AUX and IRQ ownership
  must remain correct; reading the mouse byte must not grant keyboard credit.
- Each case runs with translated/raw keyboard input and I/O wait 0/7 clocks.

All **16 combined-candidate cases pass**. All **16 unchanged-parent cases
produce the required native exit-1 loss witnesses**, not correctness passes.
The parent demonstrably overwrites a coincident scan with `FA`, or prematurely
clears IBF after losing an ACK at a full FIFO. These are current-source bugs,
not assumptions inherited from October 2.

Evidence: `external/tmp/ventium-fprem-sequence.iSZ9BAj4/ps2-loss-aux-iobus-r1/`.
Owner `ventium-ps2-loss-aux-iobus-oct16-r1`, invocation
`5769ca2c1a514614ac838f4811d0da49`, closed native 0 / MainPID 0.
Duration 28.756 s; peak memory 15,753,216 bytes, zero OOM events, swap prohibited,
CPU 13. Both compiles exit 0. An independent recheck verifies all 20 pinned
inputs, all 32 native logs and exact retained-owner closure. Sources, images,
commands and logs are retained separately. Two recipe tests also pass.

## Extended RX retention and actual RTL mouse transport

`run_loss_aux_extended.py` adds 12 combined-controller real-iobus cases:
start a physical frame while space exists, fill all 64 FIFO entries with real
port-60 ACK commands while reception is in flight, then verify the retained
scan. Variants use raw/translated input and I/O waits 0/7; self-test must cancel
the full FIFO and pending scan, produce exactly `55`, then receive a new frame.
A command-byte translation change after reception must not reinterpret a byte
already held in the skid register. All 12 pass. Eight parent controls reproduce
the expected missing-scan failure. No internal state is injected.

The same run also compiles the actual `ven_ps2_device.sv` transport against
both controllers with AUTOACK off/on. Both parent cases pass the existing
`fpga/tb_ps2_device.sv`; both combined cases **fail** its first-command timeout
at 3.125 MHz. The run remains failed: owner
`ventium-ps2-loss-aux-extended-oct16-r2`, invocation
`b20d3d4239844ae891581fa90cda6472`, native 1, 113.082 s,
23,056,384-byte peak, zero OOM. Evidence: `ps2-loss-aux-extended-r2` under the
same scratch root. R1 failed before compilation on a symlink-spelled pin key;
R2 resolves both spellings uniquely and still requires the exact digest.

The separate `run_loss_aux_transport.py` diagnostic establishes the cause:
the reset-resync proposal adds an 8,192-clock inhibit interval before the
ordinary SEND inhibit. The old receive deadline did not budget both intervals
at the low clock rate. This diagnostic changes only the wait bound from
`15000 + CELL*12` to `2*8192 + CELL*12 + 256` and adds read-only latency logs.
Every data, parity, IRQ, FIFO, abort, reset and completion assertion and every
stimulus remains identical; two host tests enforce that exact transformation.
The original TB, failed run and controller RTL are unchanged.

| First command, measured waiting clocks | Parent | Combined | Old bound | Diagnostic bound |
|---|---:|---:|---:|---:|
| 3.125 MHz | 10,942 | 19,113 | 18,000 | 19,640 |
| 40 MHz | 43,392 | 51,563 | 53,400 | 55,040 |

Both AUTOACK profiles give the same numbers. The observed difference of 8,171
clocks is the remaining reset interval after the TB's initial I/O setup.
The next nine ordinary commands have identical parent/candidate latency.
The final post-reset command takes 16,121 rather than 10,942 clocks at 3.125 MHz
because that test's 3,000-clock idle wait also ends before resync finishes;
at 40 MHz the final latency is unchanged. This is a bounded reset/startup
latency change, **not** a lost command or per-command throughput regression.
No core IPC/performance gain follows from this peripheral test.

All four diagnostic native cases pass, each exercising both frequencies with
49 checks, 26 completed device bytes and two explicit TX aborts per frequency.
Owner `ventium-ps2-loss-aux-transport-oct16-r1`, invocation
`2f094d333baf49b6a997e593c5a2329d`, native 0, 168.674 s,
22,003,712-byte peak, zero OOM, CPUs 12–13. Sources, commands, 36 command-latency
observations per case and logs are retained in `ps2-loss-aux-transport-r1`.
Both new runners use two Icarus workers, 512 MiB RAM, no swap, 32 tasks and
a 350-second owner cap; neither starts Verilator/Vivado.

## Retained-byte host observer and native controller checks

`ui_input_host.h` now has an explicitly selected retained-controller contract;
legacy arbitration checks remain intact. After real receive-final, a full FIFO
must show the exact translated byte in the pending register, without a FIFO
write. The host releases both pins and waits without resending. Completion
requires a real scan commit, real space/read credit, the selected byte, the
advanced write index and that byte in actual FIFO memory. Reset, self-test,
owner replacement, wrong data or a one-emulated-second commit timeout fail
closed. A retained byte cannot be skipped by a later capture request.

The separate `pc_keyboard_retained.h` binding observes the pending registers
and FIFO before/after each edge. It reconstructs optimized-away combinational
mux aliases from the pinned controller's observed state, never from requested
input. The whole-PC link below requires the controller's named FIFO read wire;
the earlier binding's generated-cell alias is absent in that model. The native
RTL test instead observes the actual controller mux and commit wires through
read-only probe ports.

- `retained-host-r1`: all three ASan/UBSan C++ tests pass, including the old
  host/binding regressions, 256 new binding cases, four direct/retained streams
  and 28 negative controls. Five existing PC-preparation Python tests also pass.
  Owner `ventium-retained-host-oct16-r1`, invocation
  `384cdf4e645a4904bd6da26bcbb401fc`, native 0, 6.383 s,
  398,225,408-byte peak, no OOM. Independent recheck verifies 20 pins/logs.
- `retained-rtl-r1`: actual combined controller and FIFO pass eight ordinary
  raw/translated streams at four wire rates, four full-FIFO retention cases
  (including translation changes while pending), two exact scan/ACK collisions,
  and four reset/self-test cases that must refuse host completion. FIFO pressure
  is created through real controller commands; no internal state is injected.
  Owner `ventium-retained-rtl-oct16-r1`, invocation
  `ed4c35bcb360418c916bacec480bdb3e`, build/native 0, 8.692 s.
  Model SHA `61973cb91b95678225b01d8326924cb6635abbfe9d7a1a21768de5f167f4f395`;
  native log SHA `0f6ef6a2594151671d53db58d527863820a9bb8910ba4cfb25ddd4558ead885e`.
  Independent recheck verifies 19 pins/logs; the private harness object and its
  generated-header dependency are local to this model.

Both owners closed with MainPID 0. The RTL owner's 14,237,696-byte peak is
**not** the compiler peak: the normal build guard ran one compiler in a separate
4 GiB/64-task scope, whose systemd journal reports 298.8 MiB peak. The requested
`-j 2` was clamped to one; native execution used CPUs 12–13. These are peripheral
microtests, not full-PC, gameplay, Win95 or physical-FPGA acceptance. No live
Quake source, CAD export or production controller RTL was changed.

## Cold whole-PC integration probe

`fpga/build_retained_ui_soc.py` prepares an isolated derivative of V-result
PC `b6b92dbf…`: the combined controller above and an explicitly selected
`pc_keyboard_retained.h` host binding. All processor sources and all 157
defines are unchanged. It does not change the active timing experiment or
either cold Quake run. Three preparation tests verify this source boundary,
unchanged clock/evaluation calls and unchanged raw-pixel conversion.

The first queued build (`retained-ui-soc-r1`, invocation
`acf578b5604a4bd0b9da1ce53381332b`) was cancelled **before compilation** because
Vivado owns the shared heavyweight build lock. Its only native log is the
lock-wait message; all three queue-process identities are gone, input hashes
hold, and `queue-cancelled.json` records the outcome. This is neither a compile
pass nor a compile failure. No competing compiler was started.

After synthesis closed, `retained-ui-soc-r2` actually compiled and **failed** in
10.863 s: the retained host referenced the old generated-cell alias
`__Vcellinp__keyb_fifo__rdreq`, which the new generated class does not expose.
The class exposes the controller's actual `kb_fifo_rdreq` wire instead. The
failure's sources, generated header, native log and closed receipt remain
unchanged; native compiler exit 2 / owner exit 1, invocation
`6696807317554144842353f0359ed076`. No guest ran.

`fpga/build_retained_ui_bound_soc.py` prepares a fresh model with exactly that
single private read-only binding substitution. It verifies the failed build,
the generated member and the exact RTL wire-to-FIFO connection. All RTL and
157 definitions remain identical. A source-contract test rejects drift and
reapplication. `retained-ui-soc-r3` links successfully in **22.910 s**, native 0,
with its own private host object and generated-header dependency. It retains
the same 98 structural warnings, not a full-SoC lint pass. Owner invocation:
`9309d088dcd5444a8540d1eda3242d5f`, exited / MainPID 0. New model SHA:
`0e25af3b6831e0acc44a0f0faba224f66316be2a499127165a66534893983779`.

`pc_input_probe.S` is a new generic diagnostic guest, not a modified Windows
or Quake image. An ordinary BIOS boot enters protected mode, configures the
real 8042, then checks every port-60 byte for Ctrl+Esc and Enter. It has separate
raw and translated modes, rejects AUX/error status, and publishes readiness
and pass/fail text through VGA and the reference diagnostic port. There is no
snapshot, CPU/register/memory injection or application-specific handling.

`build_pc_input_probe.py` builds two one-sector payloads in 8 MiB boot disks.
`run_pc_input_probe_qemu.py` executes the pinned references' QEMU 8.2.2 with
`-cpu pentium` and real QMP keyboard events. Both positive modes pass; replacing
Esc with Tab produces the required guest failure. Native exits are **33, 33,
35** (the diagnostic exit device's success/success/failure codes), respectively.
All children were waited/reaped, source/ROM/media hashes hold, and OOM counters
are zero. These results validate the guest diagnostic, **not Ventium RTL**.

Evidence under the same scratch root:

- `pc-input-probe-images-r1/built.json`: disk hashes
  `63a1611996385d675f82f0dbc9775cd515d73d15bf47ac798e288c8576a4939e`
  (translated) and
  `e7c0f854ee2ff6ad9081edce05df5e99db28ff85b29b5949a05015cb11fc0952`
  (raw).
- `pc-input-probe-qemu-r1/closed.json`: retained owner
  `ventium-pc-input-probe-qemu-oct16-r1`, invocation
  `e2c6fe81a86c445fba895de3d79af71b`, native 0 / MainPID 0,
  116,977,664-byte peak, actual CPUs 16–17. Each case takes under 0.16 s.

`run_retained_pc_input.py` started at **03:04:58 UTC**, owner
`ventium-retained-pc-input-oct16-r1`, invocation
`6910ce34b0b4409ca5b490bf502cb6b2`, evidence `retained-pc-input-r1`.
It uses the new compiled model and independently retained QEMU proof. Two bounded cold
boots use actual external PS/2 pins at a 1,667-clock half-period, not the legacy
accelerated sender. The grader requires nine wire bytes, the exact six or nine
guest reads, actual V retirements, the posted-16 AXI backend, clean endpoint
completion and the guest's pass marker. Three parser tests reject missing,
duplicated or wrong bytes, lost prefixes, incomplete commands, absent pairing,
accelerated timing and reported errors. Parser tests are not RTL results.
Both actual Ventium cold runs **pass** and stop cleanly at 6,500,000 clocks:

| Controller mode | Guest reads (hex) | U / V retirements | Native time |
|---|---|---:|---:|
| Translated | `1d 01 81 9d 1c 9c` | 881,912 / 29,326 | 112.021 s |
| Raw | `14 76 f0 76 f0 14 5a f0 5a` | 881,909 / 29,321 | 108.406 s |

The external sender delivers exactly nine bytes once in each case. The guest
independently reads and checks the real port-60 data; its displayed pass marker
precedes the host-requested clean stop. Both native exits are 0, actual affinities
are CPUs 16 and 17, and the endpoint ends empty with no outstanding ownership or
error. Peak owner memory is 79,724,544 bytes, swap prohibited, OOM counters 0.
There are no forced DUT-state writes, saved states, guest workload patches,
STEP/breakpoint controls or disabled pairing. These retirement totals are
diagnostic counts, **not gameplay IPC**.

`audit_retained_pc_input.py` independently regrades the native logs and checks
**19,475 source pins**, the model hash, commands, ROM/media, native waits,
absent child processes and exact terminal owner identity. Its `audit.json`
passes. This closes the tested cold keyboard transport integration, not the
broader physical-device resynchronization contract. A text-mode capture being
unavailable is explicitly **not** graphics or UI acceptance. Windows desktop
interaction and mouse motion remain separate work.

## Remaining acceptance work

The broader interrupted-frame keyboard reset and physical keyboard transmit
matrix still needs repeating on this exact combined source, including
continuous/inhibition-boundary input. The resync device-model limitation in
the proposal remains open. The real RTL mouse tests above do not prove a
universal physical-keyboard abort/retry contract.

The existing `pc_keyboard_input.h` adapter still describes the **old** FIFO
arbitration and must not qualify this candidate unchanged. The new explicit
retained binding above addresses delayed-commit observation; its full-PC link
and the two tested cold keyboard streams now pass. UI-disabled architectural/
cycle comparison, cold Win95 interaction, the whole
standard suite, full FPGA wrapper validation and matching physical-board runs
remain required. No performance gain or completed repair is claimed.

Latest verified gameplay observation is **0.48146083 total U+V IPC**, older
decode-bus model `7e877b3b…`, cycles **1,100,065,247–1,200,065,247**. It contains
neither this peripheral backport nor the current V-result timing candidate.
Both candidates remain gameplay-unmeasured.
