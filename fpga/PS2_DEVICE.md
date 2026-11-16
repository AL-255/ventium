# Hosted PS/2 Keyboard & Mouse Subsystem (`fpga/` & `fpga/board-tools/`)

## Qualification Status (`c0e3fe43`, 2026-11-14)

On **RK-XCZU15EG-F** (`xczu15eg-ffvb1156-2-i`), board-qualified release image
**`c0e3fe43`** (`161` defines, `VEN_DDR_POSTED`, `VEN_KBC_FAST`,
`VEN_KBD_AUTOACK`, `cycle_mode = 1'b1`) integrates both the **inhibit-safe PS/2
keyboard injector** (`ven_ps2_kbd_inject.v`) and the **bidirectional PS/2 mouse
serial endpoint + CSR mailbox** (`ven_ps2_device.sv`, `ven_ps2_mailbox.sv`)
inside the posted-DDR4 SoC wrapper.

- **Physical Windows 95 OSR2 GUI Qualification:** Cold-booted to desktop at
  both **`40.000 MHz`** (STA-signed-off at `40.264133 MHz`) and **`58.824 MHz`**
  (`N = 17` runtime DRP overclock), exercising live PS/2 mouse cursor/button
  movement and PS/2 keyboard typing across **Calculator (`355/113`)**,
  **Notepad**, and **MS Paint**, followed by clean Start-menu OS shutdown
  (`docs/win95-desktop-c0e3fe43.png`).
- **Verified Physical Gameplay IPC Baseline:** **`0.515778001` total U+V IPC**
  (`0.397847833` primary/U-only, counters include `REP`-element retirement) on
  image **`c0e3fe43`** across DOS Quake `demo1` gameplay cycles
  **`28,696,827,616–32,989,404,795`**. PS/2 peripheral and host-service tests
  claim zero IPC gain and never substitute for full-core differential or
  standard-suite gates.

---

## 1. Architectural Overview: Keyboard Injector vs. Mouse Endpoint

Both endpoints drive the unmodified MiSTer `ao486` 8042 PS/2 controller
(`ps2.v` + 64-entry FIFO) over real wired-AND serial `ps2_clk` / `ps2_dat` pins
in the 8042's guest-reset domain — never writing guest RAM, controller FIFOs,
or PIC/IRQ state directly:

1. **PS/2 Keyboard Injector (`ven_ps2_kbd_inject.v`, CSRs `0x380..0x3A0`):**
   - **Transmit-only** endpoint paired with `VEN_KBD_AUTOACK` for
     host-to-keyboard commands.
   - **Host Clock-Inhibit & Backpressure Safety:** During `SEND`, if the 8042
     pulls `ps2_clk` low (for example during `0xAA` controller self-test or
     64-entry FIFO full backpressure) *before* a completed stop-low phase, the
     transmitter retains ownership of the in-flight scan byte, keeps
     `inject_ready = 0` (`busy = 1`), releases wired-AND lines, waits for a
     fresh `100 us` continuous bus-idle window, and replays the **entire 11-bit
     frame** rather than dropping the byte or emitting a truncated suffix. Once
     stop-low has completed for a full synchronous clock, the frame retires
     without duplicate replay. Shared guest reset discards any held scan byte.
   - **Management CSRs (`ven_mgmt_axil`):** `0x380` write submits a scan byte;
     `0x390` reads `ready`/`busy`; `0x3A0` reads keyboard injector capability.

2. **Bidirectional PS/2 Mouse Endpoint (`ven_ps2_device.sv` + `ven_ps2_mailbox.sv`):**
   - Windows 95 and DOS mouse drivers issue 8042 `0xD4` auxiliary commands
     (`0xFF` reset, `0xF2` ID, `0xF3` sample rate, `0xE8` resolution, `0xF4`
     enable stream reporting) that require device-generated `12.5 kHz` serial
     clocking, host-to-device bit sampling, framing ACK, and `IRQ12` replies.
   - **`ven_ps2_device.sv` (Byte Wire Transport):** Generates `40 us` high/low
     clock phases (`12.5 kHz`) after `100 us` continuous idle, captures
     host-inhibited commands with odd-parity/stop validation, and distinguishes
     completed device frames (`tx_done`) from host-preempted frames
     (`tx_aborted`) without silently resuming partial bytes.
   - **`ven_ps2_mailbox.sv` (Single-Writer CSR Boundary):** Exposes
     sequence-numbered TX admission/completion and RX byte/error handshakes on
     `0x10`-aligned 32-bit registers (`WSTRB = 4'b1111` required):

| Offset | Read | Write | Semantics |
| --- | --- | --- | --- |
| `0x400` | `0x50533201` | Rejected | Mouse mailbox capability (`"PS2\x01"`) |
| `0x410` | Status word | Rejected | Ready, retained TX done/abort, RX valid, armed, protocol/RX-abort error flags |
| `0x420` | Reset generation | Rejected | Saturating counter incremented on each guest-reset assertion |
| `0x430` | `0` | Arm generation | Arms submission only when written value equals live `0x420` generation |
| `0x440` | `0` | Submit TX byte | `[7:0]` byte (`[31:8] == 0`); advances TX admission sequence; aborted if RX preempts |
| `0x450` | TX sequence | Rejected | Monotonic saturating TX admission sequence |
| `0x460` | `0` | Ack TX event | Clears retained TX delivery/abort event matching exact sequence |
| `0x470` | RX payload | Rejected | Received host byte plus parity/stop error flags (stable until `0x490` ack) |
| `0x480` | RX sequence | Rejected | Monotonic saturating RX event sequence |
| `0x490` | `0` | Ack RX event | Releases RX mailbox for next host command matching exact sequence |
| `0x4A0` | `0` | W1C errors | Clears sticky RX-abort / protocol-error status indicators |

---

## 2. Board Software Stack (`fpga/board-tools/`)

- **`ven_ps2_mouse.py`:** Pure-Python standard 3-button PS/2 mouse (`ID = 0x00`)
  policy implementing `0xFF` reset (`BAT 0xAA` + `0x00`), defaults, sample rate,
  resolution, stream/remote/wrap modes, status (`0xE9`), scaling, and
  whole-packet resend (`0xFE`). Splits large `(dx, dy)` deltas across legal
  signed packets, restarts interrupted 3-byte movement packets from their
  header on `tx_aborted`, and raises explicit backlog errors rather than
  silently dropping motion.
- **`ven_ps2_mailbox_host.py`:** Connects `ven_ps2_mouse.py` to ordered 32-bit
  CSR callbacks. Verifies `0x50533201` capability, attaches while guest reset is
  held, issues at most one store per poll, confirms TX admission via `0x450`
  sequence advancement, resolves retained TX events before consuming RX, and
  invalidates stale state across guest-reset generations.
- **`ven_ps2_mmio.c` & `ven_ps2_mmio.py` (`libven_ps2_mmio.so`):** Little-endian
  AArch64 `/dev/mem` backend mapping the non-RAM management aperture at
  `0xA000_0000` with aligned volatile 32-bit accesses, `dsb sy` barriers,
  same-peripheral post-store status readback, and an exclusive non-blocking lock
  at `/run/lock/ventium-ps2-mouse.lock` (rejects symlinks, hardlinks, forks, and
  cross-thread sharing). Build on the board or cross-compile with:
  ```sh
  aarch64-linux-gnu-gcc -std=c11 -Wall -Wextra -Werror -O2 -fPIC -shared \
    fpga/board-tools/ven_ps2_mmio.c -o /home/yukidama/external/tmp/libven_ps2_mmio.so
  ```
- **`ven_ps2_service.py`:** Long-lived board daemon (`SOCK_SEQPACKET` at
  `/run/ventium-ps2-mouse.sock`, mode `0600`, max 4 same-UID clients) plus
  `status` and `input` CLI subcommands. Attach while guest reset is held before
  `ven_board_probe.py run` releases the core. Keep button presses held across at
  least one delivered sample before sending button release so rapid clicks do
  not collapse between stream intervals.

---

## 3. Directed Simulation & Host Regressions

All PS/2 RTL and host-stack gates run without Vivado using fresh scratch
directories under `/home/yukidama/external/tmp`:

```sh
export TMPDIR=/home/yukidama/external/tmp
export PYTHONDONTWRITEBYTECODE=1

# Software unit suite (mouse policy, mailbox host adapter, MMIO fixture, socket service):
python3 -B fpga/run-ps2-mmio-gate.py --out "$TMPDIR/ps2-mmio-check"

# Bidirectional serial transport, mailbox CSRs, and full 8042 + adapter wire path:
python3 -B fpga/run-ps2-device-gate.py --platform-root 3rd-party/ao486_MiSTer/rtl
python3 -B fpga/run-ps2-mouse-policy-gate.py --platform-root 3rd-party/ao486_MiSTer/rtl --mailbox
python3 -B fpga/run-ps2-mailbox-gate.py --out "$TMPDIR/ps2-mailbox-check"
python3 -B fpga/run-ps2-mailbox-host-gate.py --out "$TMPDIR/ps2-mailbox-host-check"

# Keyboard injector inhibit, 8042 AA self-test, 64-entry FIFO backpressure & MMIO gates:
python3 -B -m unittest discover -s fpga -p 'test_kbd_*.py' -v
```
