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
