# Hosted PS/2 device transport — October 10, 2026

Status: **native-tested peripheral components and a prepared source overlay**,
not a board-accessible mouse or an FPGA acceptance pass. The active timing
candidate is unchanged. Its frozen wrapper still ties the mouse inputs high;
the separate overlay below adds a loss-detectable register interface and wiring.

Latest verified gameplay is **0.51030715 U+V retirement-event IPC** on simulated
`2b4d7a48`, cycles **1,200,065,237–1,300,065,237**, the first predeclared window,
not a full-demo average. Newer timing candidates are gameplay-unmeasured. This
peripheral work claims **no IPC gain** and does not waive the canonical gate.

## Why a bidirectional endpoint is needed

The keyboard-only injector cannot receive device commands. Connecting another
transmit-only instance to the mouse pins would therefore not supply a usable
mouse: the 8042 sends initialization/identification commands and needs the
device to supply the host-to-device clock and ACK bit before replies can arrive.
The simulation mouse is an external device model, not synthesized hardware.

`ven_ps2_device.sv` implements only the byte transport. It connects through
ordinary wired-AND PS/2 clock/data levels to the existing controller. There is
no path into guest RAM, the controller FIFO, IRQ state or CPU registers.

- One outgoing byte is owned after `tx_valid && tx_ready`. `tx_done` reports
  a complete frame; `tx_aborted` separately reports host preemption. An aborted
  byte is not silently resumed as a suffix or counted as delivered.
- One received byte, odd-parity/stop error flags and `rx_valid` remain stable
  until `rx_ready`. A second host request waits for space before clocking/ACK.
- Input framing errors are delivered as error metadata after the serial ACK;
  the device-policy layer must request retransmission, not execute bad commands.
- Clock high/low phases are 40 microseconds at the tested 3.125/40 MHz clocks;
  outgoing frames require 100 microseconds of continuous idle first. Integer
  ceiling division applies at other supported clocks. Out-of-range clock
  parameters are rejected. Host/controller outputs must be synchronous to `clk`.
- Reset discards transport ownership and releases both device lines. The
  integration must use the same guest reset domain as the 8042.

## Directed verification

`tb_ps2_device.sv` uses the **actual frozen FPGA 8042 and FIFO**, normal
port-64h/60h requests, physical serial levels, AUX status and IRQ12. It does not
force controller state. Its independent pin oracle checks framing, odd parity,
every transmitted bit and the 12.5 kHz wire clock.

The native two-frequency test passes **49 directed checks per frequency**,
including host command/reply traffic, byte transparency, IRQ consumption,
full receive-mailbox backpressure, bad parity/stop bits, pending and active
transmit preemption, truncated host receive/recovery, and queued/active-frame
reset. Each frequency completes 26 outgoing frames and reports two explicit
preemption events. Neither interrupt observation nor these tests proves a
Windows mouse driver can initialize or use the eventual device.

The first retained run failed an incorrect test assumption: this controller
retains IBF until both serial send completion **and an output reply**. The test
now checks IBF after a real reply has traversed the wire/FIFO/IRQ path. The
controller and transport were not changed to bypass that failure.

Reproduce with the explicit frozen platform's `rtl/` directory. The bounded
runner snapshots all four source files, records hashes and native exits, and
also requires rejection of an even-parity DUT mutation and four invalid-clock
configurations. Use a fresh retained service name on subsequent runs:

```sh
systemd-run --user --unit=ventium-ps2-device-check --remain-after-exit \
  --property=MemoryMax=512M --property=MemorySwapMax=0 \
  --property=TasksMax=16 --property=CPUQuota=100% --property=RuntimeMaxSec=210 \
  --setenv=TMPDIR=/home/yukidama/external/tmp \
  /usr/bin/taskset -c 12 /usr/bin/python3 -B \
  /home/yukidama/github/ventium/fpga/run-ps2-device-gate.py \
  --platform-root /home/yukidama/external/tmp/ventium-zero-c1-fpga40.rQeGd6ln/ventium/3rd-party/ao486_MiSTer/rtl
```

No Vivado, full-core rebuild, long guest or board mutation is launched. The
source-controlled runner prints its fresh evidence directory in the journal.

Retained native transport evidence under `external/tmp/`:

- `ventium-ps2-device.sczpOaeg`: first failed test, native exit 1; original
  source copies retained alongside the failure.
- `ventium-ps2-device-r2.oas7wFZB`: corrected initial 90-check suite, native 0.
- `ventium-ps2-device-r3.b7jKP460`: expanded 98-check suite, native 0 in
  37.51 seconds, 14,233,600-byte scope peak, no OOM and stable input pins.
- `ventium-ps2-device-gate.mwnatltt`: source-controlled runner passes the same
  98 checks (37.31 seconds), rejects the even-parity mutation at the actual
  serial-bit comparison, and rejects all four invalid clock configurations.
  Scope peak is 17,420,288 bytes with zero OOM events; invocation
  `a8a77e8b9b8f4c26b9600623c0c78c96`, native supervisor exit 0. This uses DUT
  SHA-256 `8db5ceb38d329590e293e49ef67e4f347fe93fde5877d233f877b661de7fde48`.

## Hosted mouse policy and end-to-end wire check

`board-tools/ven_ps2_mouse.py` supplies a general three-button ID-00 device;
it has no MMIO, IRQ, framebuffer or guest-memory access. Commands cover reset,
defaults, ID, sample rate, resolution, stream/remote/wrap, status, scaling,
reporting control, polling and packet resend. Framing errors request a retry
without executing the received byte. Status button order is deliberately
different from movement-packet button order. Wrap echoes bytes without
executing them, except reset/exit-wrap. Extended wheel identification is not
advertised. The command contract was checked against the
[Cypress/Infineon PS2D datasheet, mouse command table](https://www.infineon.com/dgdl/Infineon-PS2D_001-13681-Software%2BModule%2BDatasheets-v01_02-EN.pdf?fileId=8ac78c8c7d0d8da4017d0fab8b401c89).

Policy API and integration obligations:

- `reset()` must accompany a real transport/8042 reset, not merely restarting
  the Python process against an unknown live guest. It invalidates old tokens
  and queues normal BAT/ID bytes. Protocol `FF` separately responds with ACK.
- `input(dx, dy, buttons)` accepts sensor counts at the selected resolution,
  positive X right/Y up, buttons left/right/middle = 1/2/4. The caller converts
  physical units if necessary. A bounded backlog raises an explicit exception
  instead of dropping input. Large movement is split across valid packets;
  this hosted sensor does not emulate physical-counter overflow or a wheel.
- `advance(now_ns)` uses monotonically increasing device time, schedules only
  changed stream samples, respects sample rate and never queues a catch-up
  burst. Disabled stream reporting still permits explicit remote reads.
- `peek()` offers a byte. `admitted()` is called only after hardware confirms
  ownership; `completed(token, delivered=...)` must distinguish delivery from
  abort. An interrupted packet restarts at its header. Only the final delivered
  byte consumes movement; input arriving during transmission remains pending.
- The adapter must resolve earlier TX events before calling `receive()` and
  service RX before scheduling new motion. Late/duplicate completion and RX
  while a byte is owned raise errors. New commands replace an unsent response
  suffix. Resend remembers a packet with a delivered prefix, not merely queued
  data, and does not consume its movement again after successful delivery.

`test_ven_ps2_mouse.py` covers command/default state, framing/parameter errors,
all wrap echo bytes, all button combinations and signed motion boundaries,
stream timing, scaling, remote polling, whole-packet resend, each packet-byte
abort, reset/stale ownership and explicit backlog failure. These tests alone
would not prove a working 8042 path.

`tb_ps2_mouse_policy.sv` and `run-ps2-mouse-policy-gate.py` therefore connect the
**actual frozen 8042/FIFO** and `ven_ps2_device` to the frozen Python policy.
Commands enter through ports 64h/60h; the policy consumes bytes actually
received from the serial pins. Replies return through framing/parity checks,
AUX/OBF/IBF status, IRQ12 and port 60h, and are compared with independent literal
packet expectations. No internal controller state is forced. The first run
passed 19 host commands and 46 delivered bytes at each of 3.125/40 MHz, native
zero in 5.81/44.14 seconds, with 22,605,824-byte scope peak and zero OOM events.
It is retained as `external/tmp/ventium-ps2-mouse-policy.p9twben1`.

Reproduce in a fresh service with the transport gate's resource properties,
but `RuntimeMaxSec=300`, invoking `fpga/run-ps2-mouse-policy-gate.py` with the
same explicit `--platform-root`. The runner snapshots its sources and tools,
records native status/logs, and rejects byte-only-resend, double-consumption
and inverted-Y-sign mutations through the protocol tests. It does not exercise
a PS-side CSR adapter, operating-system driver or physical FPGA.

Final source-controlled closure (21:26 UTC):
`external/tmp/ventium-ps2-mouse-policy.vuru25_e`, invocation
`44801bad210c469580053b131032fed2`. All **14 protocol tests** pass; all three
deliberately broken policies fail assertions, not imports/builds. The real-wire
cases repeat the 19 commands / 46 bytes at each frequency, native zero in
5.82 / 45.07 seconds. Actual simulator affinity is CPU 12, both child processes
are reaped, scope peak is 22,175,744 bytes and OOM counts are zero. An independent
closure check rehashed all **23 source/tool/mutation pins**, counted actual
RX/TX log records and verified the exited service identity. Closure SHA-256:
`f7e47110eddac66fb554f6458cc77db158787ed8bc9d69b986141adc9ac5fd0d`.

Two additional review fixes are included: physical button releases remain
observable after leaving wrap mode, and backlog admission reserves space for
the eventual commit of an opposite-direction in-flight motion sample. Directed
tests cover both. Neither fix changes the processor or claims a gameplay gain.

## October 11: retained mailbox and wrapper overlay

[`ven_ps2_mailbox.sv`](ven_ps2_mailbox.sv) adds a single-writer CSR boundary.
An offered byte remains owned under transport backpressure. Admission advances
a sequence number; successful delivery and host-preemption produce distinct,
retained events, cleared only by an acknowledgement of that exact sequence.
Receiving a host command before a queued TX reaches the wire explicitly aborts
that TX, so the policy can resolve it before consuming RX. The RX byte, framing
errors and sequence remain stable until their separate exact acknowledgement.

The management domain records each guest-reset assertion once and disarms
submission. Software must observe the new generation and explicitly arm it;
pending bytes cannot leak into the next guest. Counters saturate rather than
wrap. Sequence exhaustion requires guest reset; generation exhaustion requires
management/fabric reset. The physical transport still uses the actual 8042
guest-reset domain. This is not support for independent concurrent writers or
reattaching a fresh policy process to an unknown live device.

The source overlay uses only 0x10-aligned lane-0 offsets:

| Offset | Read | Write |
|---|---|---|
| `0x400` | Capability `50533201` | Rejected |
| `0x410` | Status; exact bits documented in the module | Rejected |
| `0x420` | Guest-reset generation | Rejected |
| `0x430` | Zero | Arm the exact observed generation |
| `0x440` | Zero | Submit byte; upper 24 bits must be zero |
| `0x450` | TX admission sequence | Rejected |
| `0x460` | Zero | Acknowledge retained TX event by sequence |
| `0x470` | RX byte plus parity/stop errors | Rejected |
| `0x480` | RX sequence | Rejected |
| `0x490` | Zero | Acknowledge RX by sequence |
| `0x4A0` | Zero | W1C RX-abort/protocol-error indicators |

All writes require all four byte strobes. Invalid/stale writes are visible
through the protocol-error status, not silent admission. A ready read is only
advisory: the PS adapter must verify actual sequence advancement before calling
`Mouse.admitted()`. It must service completion before RX, recheck generation
around observations and reject an old image without the exact capability.
Neither a CSR read nor an AXI response acknowledges a byte's serial delivery.

[`prepare_ps2_mouse_mailbox.py`](prepare_ps2_mouse_mailbox.py) checks the three
exact current wrapper/management/project input hashes, refuses missing,
duplicate or already-applied anchors, and writes a separate five-file overlay.
It forwards actual AXI byte strobes and one registered command pulse, preserves
the existing AXI response retention, connects the wired-AND mouse pins, and
passes the wrapper's `CLK_HZ` into the byte transport. It changes no processor
RTL, feature defines or clock constraints. It is **not a complete independent
build directory**: a later source-matched export must deliberately incorporate
it through the existing clock/profile wrapper, never run the legacy base Tcl
alone or edit the live export.

Native closure: `external/tmp/ventium-ps2-mailbox-r2.rDP90LzX`, service
`ventium-ps2-mailbox-r2-oct11.service`, invocation
`57153f0ed3a841a79899cd2c4f868ba5`, native exit 0, 29,401,088-byte memory peak,
zero OOM events and unchanged source/tool pins. The runner
[`run-ps2-mailbox-gate.py`](run-ps2-mailbox-gate.py) records:

- **1,969 directed mailbox checks**, including all byte values, busy writes,
  partial strobes, retained/error events, stale acknowledgements, host-command
  preemption, reset at each ownership stage, and natural counter saturation
  with a narrowed test instance. No private state is forced.
- **233 actual `ven_mgmt_axil` integration checks** with separated AW/W arrivals,
  B/R backpressure, byte-strobe propagation, address-bank isolation and actual
  control/forensic guest resets. The serial side here is an explicit BFM.
- The existing debug-register regression and both modules' six-class structural
  lint pass; twelve recipe checks pass. Six broken mailbox variants and three
  broken register bridges fail native assertions; two invalid counter widths
  fail elaborated parameter guards. Compile failures/timeouts are not counted
  as successful mutation detection.

The prepared overlay is `external/tmp/ventium-ps2-mouse-overlay-r2.McPNAkCQ`.
The initial mailbox-only run and first prepared overlay remain separate
historical evidence. Reproduce using a fresh empty external output, the bounded
one-CPU/512-MiB/no-swap service profile above, and the runner's `--overlay` option.
No Vivado, full guest, board write or additional heavy build is launched.

The protocol runner's new `--mailbox` mode then passes the **actual 8042/FIFO +
serial transport + mailbox + unchanged Python mouse policy** path at both
3.125 and 40 MHz: **19 host commands / 46 delivered bytes per clock**. Every
outgoing byte crosses independently checked serial framing/parity, AUX status,
IRQ12 and port 60h. CSR admission sequences and retained completion records
are checked before acknowledgement. The existing direct-transport mode is
rerun as a separate control and also passes. Each run retains the 14 policy
tests and three deliberate policy-mutation failures. These tests still do not
execute a PS MMIO service or Windows driver.

Both services close with native exit 0, reaped children and zero OOM events:

| Mode | Evidence leaf under `external/tmp` | Native seconds, 3.125 / 40 MHz | Peak bytes |
|---|---|---|---|
| Mailbox wire path | `ventium-ps2-mouse-policy.twwpiusp` | 12.69 / 93.13 | 26,210,304 |
| Direct control | `ventium-ps2-mouse-policy.1s56t25o` | 12.22 / 92.70 | 21,815,296 |

Invocations are `e82a954c9cca4a32964164c3bd28b8fc` and
`15c48e993f454492b2a35e2c730745ac`, respectively; actual child affinity is CPU
12 / 13. An independent closure audit rechecks supervisor identities, absent
native processes, every recorded RX/TX line and all 35 / 25 / 23 pins across
the mailbox/AXI gate and two wire runs. Its receipt is
`ventium-ps2-mailbox-r2.rDP90LzX/audit.json`, SHA-256
`3d7e60fdf663fc42b40e1d5434c105bebfe7a302b2a4b2ecf6f3232b2f0dd3f6`.

## Still required before physical mouse acceptance

1. Integrate the now-tested general mouse policy with an actual PS-side service
   and UI input producer. Do not introduce guest-specific command recognition
   or synthetic cursor writes. Keep the protocol/wire gates passing.
2. Complete the PS adapter against the explicit mailbox ABI, including MMIO
   ordering, exclusive ownership, reset races and delivery-before-RX ordering.
   The leaf/AXI tests do not establish a working Linux service or UI producer.
3. Incorporate the separately prepared overlay in a source-matched candidate,
   run full integration lint/verification, retain the 40 MHz timing requirement,
   and implement/deploy it. Do not edit the active frozen synthesis inputs.
4. Cold Win95 desktop and actual keyboard/mouse interaction on the deployed
   candidate, with original guest media, captures, bitstream/source hashes,
   measured clock and UV+fast evidence. Keyboard-only UI is not mouse coverage.
