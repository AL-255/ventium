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

## Remaining acceptance work

The broader interrupted-frame keyboard reset and physical keyboard transmit
matrix still needs repeating on this exact combined source, including
continuous/inhibition-boundary input. The resync device-model limitation in
the proposal remains open. The real RTL mouse tests above do not prove a
universal physical-keyboard abort/retry contract.

The prepared `pc_keyboard_input.h` adapter still describes the **old** FIFO
arbitration. It cannot qualify this candidate unchanged: a retained scan and
delayed FIFO commit require corresponding real ownership observations, not
disabling its loss checks. Full-PC linking, cold Win95 interaction, the whole
standard suite, full FPGA wrapper validation and matching physical-board runs
remain required. No performance gain or completed repair is claimed.

Latest verified gameplay observation is **0.48146083 total U+V IPC**, older
decode-bus model `7e877b3b…`, cycles **1,100,065,247–1,200,065,247**. It contains
neither this peripheral backport nor the current V-result timing candidate.
Both candidates remain gameplay-unmeasured.
