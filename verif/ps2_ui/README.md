# Ordinary PS/2 input microtests

These sources preserve the byte-exact October 2 isolated UI-input qualification.
They are not connected to the canonical full-PC host, do not modify production
RTL, and do not establish Windows UI acceptance.

New investigation: [latched AUX byte ownership](AUX_STATUS.md), a separate
one-line status repair and actual-iobus mixed keyboard/mouse microgate. Its
qualification status is tracked separately from the October 2 loss witnesses.

The pure-host test checks bounded command parsing, scancodes/parity, endpoint
identity, byte/prefix ownership and checked raw-capture finalization. The narrow
RTL test instantiates unchanged production `ps2.v` and `simple_fifo.v` with
`VEN_KBC_FAST` and `VEN_KBD_AUTOACK`. It uses ordinary PS/2 pins and CPU I/O only:
no forced/deposited registers or seeded FIFO memory.

A successful narrow test deliberately reproduces existing controller failures:
AUTOACK overwriting a simultaneous scan, full-FIFO scan/ACK loss and natural
host-command timeout losing a break prefix. Its final marker
`UI-PS2-MICRO-OK controller_bug_witnesses_expected=1 rtl_unchanged=1` means the
test specification held, **not** that those controller bugs are fixed. The
diagnostic sender must refuse false acceptance; it never speculatively replays.

## Bounded reproduction

For new runs, use an owned scratch directory under `/home/yukidama/external/tmp`
and set `TMPDIR` there explicitly, as required by the current `AGENTS.md`.
Check that the external filesystem is mounted, writable and has enough free
space. Do not fall back to the root filesystem. Historical paths below are
retained evidence locations, not instructions to create new `/var/tmp` runs.
Apply owner limits of 2 GiB memory, swap disabled, 64 tasks and two free CPUs,
excluding any running gameplay CPU. Cap each compile/test phase below 590 seconds;
stop on an actual resource failure instead of automatically retrying.

The actual qualified toolchain was Verilator 5.046 and g++ 15.2. The commands below
are build inputs, to run inside those resource/time limits; no complete PC model
or Vivado job is needed. Set `PS2_TEST_DIR`, `PS2_REPO_DIR` and `PS2_RUN_DIR` to
the absolute source/repository/owned scratch paths.

```sh
g++ -std=c++17 -O2 -Wall -Wextra -pedantic \
  "$PS2_TEST_DIR/test_ui_input_host.cpp" -o "$PS2_RUN_DIR/ui_host_micro"
"$PS2_RUN_DIR/ui_host_micro" "$PS2_RUN_DIR"

verilator --cc --exe --build -j 2 --assert --top-module ui_ps2_probe \
  --Mdir "$PS2_RUN_DIR/obj_ps2" -o ui_ps2_micro -Wall -Wno-UNUSED -Wno-fatal \
  -Werror-IMPLICIT -Werror-PINMISSING -Werror-UNDRIVEN -Werror-MULTIDRIVEN \
  -Werror-LATCH -Werror-UNOPTFLAT +define+VEN_KBC_FAST +define+VEN_KBD_AUTOACK \
  -CFLAGS "-O2 -std=c++17 -I$PS2_TEST_DIR" \
  "$PS2_REPO_DIR/3rd-party/ao486_MiSTer/rtl/soc/ps2.v" \
  "$PS2_REPO_DIR/3rd-party/ao486_MiSTer/rtl/common/simple_fifo.v" \
  "$PS2_TEST_DIR/ui_ps2_probe.sv" "$PS2_TEST_DIR/test_ui_ps2.cpp"
"$PS2_RUN_DIR/obj_ps2/ui_ps2_micro"
```

Production width/style/declaration-initializer warnings remain visible. The six
structural warning classes above remain hard errors.

## Actual retained qualification (not a proposed result)

Owned leaf: `/var/tmp/ventium-fpga-quake-oct02.rc0wVn/ui-input-host`.

- `qualified-host.wux0xra0`: compiler/native/pin waits 0; wrapper 0;
  `UI-HOST-MICRO-OK`. Peak 138,256,384 bytes, all OOM counters zero.
- `qualified-ps2.bdch8m4u`: compiler/native/pin waits 0; wrapper 0; ordinary
  translated streams pass at half-periods 32/64/1875/2917, plus raw and normal
  break-prefix controls. Peak 541,044,736 bytes, all OOM counters zero.
  Closed native log SHA256
  `c90d3becdfdd3946cd916a5d1f940234ba615f1479396406d8a4c239e4c8c5f0`.
- Before/after manifests held all 83 original and 11 isolated source pins.
  These hashes are observations, not atomic loaded-source ancestry.

The separate host-only diagnostic executable was relinked from one isolated
main and the frozen 5c RTL archive/eight non-main objects; it has a new native
identity and cannot inherit the accepted Win95 desktop PASS. Gameplay IPC remains
unmeasured for 5c2491; verified baseline 0.43038841 belongs to older 4092c92a,
clocks 2,199,999,637–2,299,999,637.
