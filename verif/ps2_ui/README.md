# PS/2 8042 Keyboard, Mouse & Live-Input Verification (`verif/ps2_ui/`)

`verif/ps2_ui/` contains host and RTL verification harnesses for the PC/AT `8042` PS/2 keyboard/mouse controller (`3rd-party/ao486_MiSTer/rtl/soc/ps2.v`, `simple_fifo.v`, `iobus.v`), the FPGA PS/2 device/mailbox injectors (`ven_ps2_device.sv`), and the full-PC live keyboard FIFO adapter.

## Physical Hardware Status (`c0e3fe43` on `main`, 2026-11-14)

On the board-qualified **RK-XCZU15EG-F** release image **`c0e3fe43`** (`40.264133 MHz` post-route STA sign-off, **`0.515778001` total U+V / `0.397847833` primary/U** verified Quake gameplay IPC across cycles `28,696,827,616–32,989,404,795`), the PC/AT PS/2 keyboard & mouse controller and hardware injection mailboxes pass **cold Windows 95 OSR2 GUI boot, interactive multi-application mouse & keyboard session (Calculator `355/113`, Notepad, MS Paint), and clean OS shutdown**, as well as `make bus`'s integrated `verif/bus/run-ps2-iobus-gate.sh` delayed-read regression.

## Harnesses & Verified Controller Properties

| Test / Script | Instantiated Scope | Verified Contract |
| --- | --- | --- |
| `test_ui_input_host.cpp` | Pure C++17 host unit test (`UI-HOST-MICRO-OK`) | LF-framed `--ui-fifo` command parsing, scancode/parity framing, monotonic command IDs, retained-byte tracking, and exclusive raw frame-capture finalization. |
| `ui_ps2_probe.sv` + `test_ui_ps2.cpp` | `ps2.v` + `simple_fifo.v` (`+VEN_KBC_FAST +VEN_KBD_AUTOACK`) | Translated/raw scan streams across wire half-periods `32/64/1875/2917`, break-prefix ownership, and baseline controller loss witnesses (`UI-PS2-MICRO-OK`). |
| `run_aux_status.py` (`tb_ps2_aux_status.sv`, `test_aux_status.py`) | `iobus.v` + `ps2.v` + `simple_fifo.v` (496 stimuli × 4 `KBC_FAST`/`AUTOACK` profiles) | **Latched `AUX` status ownership:** port `0x64` bit 5 (`AUX`) must follow the latched selected output byte (`status_mousebufferfull`) rather than `!mouse_fifo_empty`, preventing a newly queued mouse byte from misrouting an already-latched keyboard byte on port `0x60`. |
| `tb_loss_aux_iobus.sv` / `run_loss_aux_extended.py` (`proposals/`) | `iobus.v` + `ps2.v` + `simple_fifo.v` | Skid-register scan retention, `scan > ACK > reply` arbitration, 64-byte full-FIFO `IBF` backpressure (mouse reads never grant keyboard FIFO credit), and single-strobe held I/O writes. |
| `tb_hosted_resync.sv` / `run_hosted_keyboard_transport.py` | `ven_ps2_device.sv` ↔ `ps2.v` wired-AND pins (`3.125 MHz` & `40 MHz` profiles) | Mid-frame controller reset / `0xAA` self-test 8,192-clock inhibit resynchronization (`tx_aborted` retry across all 9 frame phases) and physical host-to-keyboard serial command/ACK transmission (`AUTOACK=0`). |
| `prepare_pc_live_input.py` / `run_retained_pc_input.py` (`pc_input_probe.S`) | Cold-boot BIOS/PM32 guest + full-PC `ao486-sim` PS/2 pins | End-to-end 1,667-clock half-period (`40 MHz`) external PS/2 wire delivery of `Ctrl+Esc` and `Enter` in both translated and raw modes with active `U/V + fast-pipe` pairing. |

## Running Standalone Microgates Safely

Always use an owned scratch directory under `/home/yukidama/external/tmp` (`TMPDIR`) and `/tools/verilator/v5.046/bin/verilator` inside `tools/build_scope.sh`, keeping all six structural lint classes fatal:

```sh
export TMPDIR=/home/yukidama/external/tmp
export PYTHONDONTWRITEBYTECODE=1
PS2_RUN_DIR=$(mktemp -d "$TMPDIR/ventium-ps2-micro.XXXXXX")

# 1. Host protocol & binding checks:
g++ -std=c++17 -O2 -Wall -Wextra -pedantic \
  verif/ps2_ui/test_ui_input_host.cpp -o "$PS2_RUN_DIR/ui_host_micro"
"$PS2_RUN_DIR/ui_host_micro" "$PS2_RUN_DIR"
python3 -B -m unittest discover -s verif/ps2_ui -p 'test_*.py'

# 2. Latched AUX-status 4-profile iobus gate:
VENTIUM_VERILATOR_BIN=/tools/verilator/v5.046/bin/verilator \
VENTIUM_BUILD_SCOPE_PROFILE=default \
  tools/build_scope.sh -- python3 -B verif/ps2_ui/run_aux_status.py \
  --out "$PS2_RUN_DIR/aux-status"
```
