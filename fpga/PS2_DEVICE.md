# Hosted PS/2 device transport — October 10, 2026

Status: **unintegrated peripheral prototype**, not a functional mouse or an
FPGA acceptance pass. The active `2b4d7a48` source export and implementation
are unchanged. Its wrapper still ties the mouse input pins high.

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

## Still required before physical mouse acceptance

1. A general PS/2 mouse policy: reset/ID, enable/disable, sampling and
   resolution parameters, stream/remote modes, status, resend/error handling,
   and correctly signed button/motion packets. Do not introduce guest-specific
   command recognition or synthetic cursor writes.
2. Versioned, loss-detectable control-register mailboxes and reset-safe wrapper
   wiring. Preserve distinct TX admission/completion/abort and stable RX
   ownership; a stale ready read must not silently drop a software write.
3. Native protocol/CSR/reset tests, then a separately source-matched export,
   structural lint and FPGA implementation. Do not edit the active frozen
   source or restart its implementation to sneak this prototype into it.
4. Cold Win95 desktop and actual keyboard/mouse interaction on the deployed
   candidate, with original guest media, captures, bitstream/source hashes,
   measured clock and UV+fast evidence. Keyboard-only UI is not mouse coverage.
