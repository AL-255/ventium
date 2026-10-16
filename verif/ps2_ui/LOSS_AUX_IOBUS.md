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

## Remaining acceptance work

This new test does **not** exercise the proposal's full RX-skid, interrupted-
frame reset or physical keyboard transmit matrix; the older isolated results
are not silently reassigned to this new source. Repeat those cases on the
combined controller, including continuous/inhibition-boundary input and real
iobus ordering, before promotion. The resync device-model limitation documented
in the proposal remains open.

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
