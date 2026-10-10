# Hosted PS/2 device transport — October 10, 2026

Status: **unintegrated peripheral prototype**, with byte transport and a hosted
mouse policy, not a board-accessible mouse or an FPGA acceptance pass. The active
`2b4d7a48` source export and implementation are unchanged. Its wrapper still
ties the mouse input pins high.

Latest verified gameplay is **0.49366456 U+V retirement-event IPC** on older
simulated `bfb867f7`, cycles **5,200,065,237–5,300,065,237**; the 41-window mean
is **0.498471873**. Candidate `2b4d7a48` is unmeasured. This peripheral work
claims **no IPC gain** and does not repair or waive the failing canonical gate.

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

## Still required before physical mouse acceptance

1. Integrate the now-tested general mouse policy with an actual PS-side service
   and UI input producer. Do not introduce guest-specific command recognition
   or synthetic cursor writes. Keep the protocol/wire gates passing.
2. Versioned, loss-detectable control-register mailboxes and reset-safe wrapper
   wiring. Preserve distinct TX admission/completion/abort and stable RX
   ownership; a stale ready read must not silently drop a software write.
   The existing `ven_mgmt_axil` and wrapper share the SoC clock; the new bank
   must retain 0x10-aligned lane-0 addresses. Do not copy the keyboard port's
   write-time `valid & ready` drop behavior. Retain completion until explicit
   acknowledgement and expose guest-reset generation before accepting new
   software ownership. This integration is not implemented by the policy gate.
3. Native protocol/CSR/reset tests, then a separately source-matched export,
   structural lint and FPGA implementation. Do not edit the active frozen
   source or restart its implementation to sneak this prototype into it.
4. Cold Win95 desktop and actual keyboard/mouse interaction on the deployed
   candidate, with original guest media, captures, bitstream/source hashes,
   measured clock and UV+fast evidence. Keyboard-only UI is not mouse coverage.
