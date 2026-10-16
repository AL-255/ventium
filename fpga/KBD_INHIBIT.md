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
to distinguish that loss. A controller self-test during input is one relevant
integration scenario; its end-to-end reproduction remains required below.

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

## Required next steps

Test coincident stop/inhibit edges and actual controller self-test/full-FIFO
interaction, including the retained-AUX controller and the board's shared reset.
Then qualify the actual wrapper/debug-MMIO path and compose this exact change
with the processor/keyboard-controller candidate. Do not infer that generic
physical PS/2 devices share this retry policy. Current microtests are neither
controller integration nor Win95 UI/standard-suite/physical-FPGA acceptance.

Current candidates have no verified gameplay IPC. Older measured baseline:
**0.49046518 total U+V**, model `7e877b3b…`, cycles
**1,600,065,247–1,700,065,247**; this peripheral repair claims no IPC gain.
