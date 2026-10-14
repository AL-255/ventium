# 8042 AUX status must describe the selected byte

October 14, 2026. **Private one-line repair, native microgate queued; not yet
qualified or installed.** Four recipe/coverage tests pass. No production RTL,
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

The planned matrix has **496 distinct stimuli per build profile**:

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

At **04:05:39 UTC**, service `ventium-ps2-aux-oct14-r1.service`, invocation
`e58b5bea7ec94decbba0fbd572bdd755`, is confirmed live on CPU13, waiting for the
exact live timing sequencer invocation `22c3239ddc57427ab4f265337a7d895c`.
Observation failure never means that job has finished. No compiler is launched
until it becomes terminal and the queued source hashes still match. There is
no retry or modification of the timing/FPGA job.

Output is reserved at
`/home/yukidama/external/tmp/ventium-ps2-aux.syNvZwg1/r1`.
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

Native RTL results, full-PC source transfer, differential/standard suite and
physical Win95 keyboard/mouse acceptance remain **open**. This peripheral
repair does not claim a processor timing or throughput improvement.

Gameplay baseline: **0.47330821 total U+V IPC**, older simulation `c7b95b78`,
cycles **1,500,065,237–1,600,065,237**. The fast-segment candidate and this
peripheral derivative have no gameplay measurement.
