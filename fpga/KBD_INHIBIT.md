# FPGA keyboard inhibit repair — October 16, 2026

**Private repair; not exported, synthesized or deployed.** The current timing
export still contains the original keyboard injector. The earlier
[`ven_ps2_device` tests](../verif/ps2_ui/LOSS_AUX_IOBUS.md) test a different,
bidirectional endpoint; they cannot qualify this transmit-only board device.

## Reproduced defect and proposed fix

The frozen `ven_ps2_kbd_inject.v` honors host clock/data only before starting
a frame. Its `SEND` state continues advancing through host-clock inhibition
and eventually advertises `inject_ready`, although the physical wire remained
low and could not deliver the byte. Software has no abort/completion status
to distinguish that loss. Controller self-test during input now reproduces
the early-ready defect with the actual 8042, as recorded below.

[`prepare_kbd_inhibit.py`](prepare_kbd_inhibit.py) adds an inhibit branch to
`SEND`. Before a completed stop it retains the existing byte, releases device
pins, resets frame counters and returns to the existing continuous-idle wait.
Ready remains low; after release it sends the complete byte, not a suffix.
If the stop-low phase was already observed for a full synchronous clock,
it completes without retrying, avoiding a duplicate. Guest reset still discards
the old byte. No new storage bits, interface, FIFO, CPU path or timing constant
is introduced. The endpoint remains transmit-only and does not implement
physical host-to-keyboard commands; the board's AUTOACK profile is unchanged.

- Original source: `3fee16426277e11292ab018346e28c31c99de0e2f38d9f23b4c9443d6ef719c8`.
- Proposed source: `b0dff672729c1658249bd50359204c5ee79498d8b7b0cdef60dadd6526ae88bf`.

## Closed public-pin tests

`tb_kbd_inhibit.sv` uses only public pins, ready/busy and reset. It covers
both halves of start/data/parity, stop-high, stop-low and completed idle,
at 3.125/40 MHz parameter profiles. It checks byte ownership throughout a
long inhibit, each bit/parity of a whole retry, exact edge counts, a subsequent
different byte, no completed-stop duplicate and reset cancellation. The logical
TB clock is fixed; this is not a board-frequency measurement.

| Native matrix | Interrupted-byte cases | Completed-stop/idle controls |
|---|---:|---:|
| Original injector | 42 required early-ready failures | 4 pass |
| Proposed injector | 42 pass | 4 pass |

Evidence root: `external/tmp/ventium-fprem-sequence.iSZ9BAj4`.
`kbd-inhibit-witness-r2` closes in 1.48 s, peak 18,251,776 bytes, owner
`ventium-kbd-inhibit-witness-oct16-r2`, invocation
`801fd2bf927c41ff83eef0bdc0e01ee8`. These expected failures are **red witnesses,
not original-controller correctness**. `kbd-inhibit-fixed-r1` closes in 3.86 s,
peak 18,497,536 bytes, owner `ventium-kbd-inhibit-fixed-oct16-r1`, invocation
`4941c796a16f4968ab45a7972c5dba3b`. Both owners exit 0 / MainPID 0; all children
are waited/reaped, no swap/OOM, actual CPUs 12–13. Two recipe tests pass.

`audit_kbd_inhibit.py` independently checks exact matrices, build commands,
native logs/images/exit codes, 7 parent / 61 candidate source pins, retained
owners, identical testbench bytes and the exact source transformation. Its
`kbd-inhibit-fixed-r1/audit.json` passes.

The earlier R1 witness matrix remains **failed**: it reproduced all 42 defects,
but two 40 MHz completed-frame controls exhausted its 200,000-clock TB budget.
One normal control actually needs 205,560 clocks. R2 changes only that TB
deadline to 300,000 clocks plus its explanatory comment, not injector RTL or
any assertion. R1's copied sources and native failure logs remain intact.

## Actual-controller integration — closed October 16

[`tb_kbd_controller_inhibit.sv`](tb_kbd_controller_inhibit.sv) connects the
actual transmitter to the retained-AUX `ps2` controller
(`9c9d62149a25a5e3f97683ca269b77d01dcf4034517c02a225a5bce0bd2dc405`),
through ordinary wired-AND serial pins. Its only controller accesses are guest
I/O ports; no internal state, FIFO writes or forced signals are used. The exact
`VEN_KBC_FAST` / `VEN_KBD_AUTOACK` target definitions are retained. This test
does not claim physical host-command reception by the transmit-only injector.

The [runner](run_kbd_controller_inhibit.py) passes **104 candidate cases**:
26 interruption positions × two clock parameter profiles × controller `AA`
self-test or shared guest reset. Positions include every start/data/parity
half, both stop halves, completed idle, and explicit one-clock-before,
coincident-with, and one-clock-after-stop boundaries. For `AA`, the boundary
checks observe actual clock-pin events. The reset signal is shared as in the
board wiring, not a controller-only reset with a surviving old-guest device.

- **46 interrupted `AA` cases** retain ownership and automatically retry a
  full eleven-bit frame; the producer never submits the byte again. The
  controller returns self-test `55`, then translated `5a → 1c`, with IRQ1.
- The other **58 reset/completed-byte cases** do not replay the flushed byte.
  Shared reset cancels the device's old owner. An already completed byte is
  intentionally discarded by controller self-test, not resurrected afterward.
- Every case receives a distinct subsequent `1c → 1e` byte through port60
  and checks IRQ1, no AUX/error status and no stale/duplicate output.
- The original injector, with the **same retained controller and testbench**,
  produces two required native-exit1 early-ready witnesses at stop-high,
  one per clock profile. They are negative evidence, not correctness passes.

Evidence: `kbd-controller-inhibit-r1`, unit
`ventium-kbd-controller-inhibit-oct16-r1.service`, invocation
**`486e28f20e57408ebc43339826eaf9ac`**. Native closure is exit0 / MainPID0 in
**201.76 seconds**, peak **21,254,144 bytes**, no swap/OOM, actual CPUs12–13.
All 106 children are waited/reaped; four native compilations succeed. Two
matrix/grading unit tests pass. The [independent audit](audit_kbd_controller_inhibit.py)
rechecks 15 source/tool pins, the exact matrix/defines, all native logs/images,
exit codes and closed owner. `kbd-controller-inhibit-r1/audit.json` passes.
The injector source is **unchanged** from the earlier 46-case isolated repair.

## Required next steps

Full-FIFO/backpressure interaction and the actual wrapper/debug-MMIO path remain
unqualified. Compose the exact controller and endpoint changes with the processor
candidate, then verify the full suite and physical Win95 keyboard/mouse UI.
Do not infer that generic physical PS/2 devices share this retry policy. These
integration microtests are not Win95 UI/standard-suite/physical-FPGA acceptance.

Current candidates have no verified gameplay IPC. Older measured baseline:
**0.49046518 total U+V**, model `7e877b3b…`, cycles
**1,600,065,247–1,700,065,247**; this peripheral repair claims no IPC gain.
