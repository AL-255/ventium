# Ordinary PS/2 input microtests

These sources preserve the byte-exact October 2 isolated UI-input qualification.
They are not connected to the canonical full-PC host, do not modify production
RTL, and do not establish Windows UI acceptance.

New investigation: [latched AUX byte ownership](AUX_STATUS.md), a separate
one-line status repair and actual-iobus mixed keyboard/mouse microgate. Its
qualification status is tracked separately from the October 2 loss witnesses.

October 16 follow-up: [current-AUX keyboard ownership backport](LOSS_AUX_IOBUS.md)
combines the retained loss/resync proposal with the newer AUX repair. Sixteen
actual-iobus cases pass and sixteen old-controller loss witnesses reproduce.
It is a separate private candidate, not part of the running FPGA synthesis;
the live-input adapter below must not be assumed compatible with its new
retained-producer protocol.

## October 16: current-model live keyboard adapter (not UI acceptance)

`prepare_pc_live_input.py` now prepares a **host-only** derivative of the frozen
V-result full-PC host (`v-result-carry-soc-r1`, model `b6b92dbf…`). It does not
edit that model, the checkout's dirty `sim_ven.cpp`, RTL, defines, the running
synthesis inputs, guest software or snapshots. The prepared main has a unique
basename to avoid accidental VPATH object reuse. This original host-only variant
was not linked; the separate retained-controller variant's actual build and
integration status are tracked below.

The optional `--ui-fifo /absolute/private-directory/input.fifo` endpoint reuses
the previously tested LF-framed commands: `1 key ctrl+esc`, `2 key enter`,
`3 capture`. The directory must already be owned mode 0700; the FIFO is owned
mode 0600. IDs increase monotonically. Legacy `--kb*`, save/restore/snapshot
and debugger-breakpoint options are rejected when live input is enabled.
Keyboard transport runs at ordinary PS/2 timing derived from the configured
clock (half-period 1,667 core clocks at 40 MHz), not the legacy 24-clock sender.

`pc_keyboard_input.h` drives only the external keyboard pins. It observes
the real 8042/FIFO before and after **every** ordinary clock edge, including
PS-service ticks, without adding evaluations or clocks. AUTOACK/reply
arbitration, actual FIFO write-index movement, stored bytes, reset and break-
prefix ownership are checked. Optimized-away timeout/data expressions are
reconstructed from the exact pinned controller expressions; acceptance also
requires independent post-edge FIFO evidence. Input loss is an error, not
silent acceptance or speculative retry. FIFO delivery is **not** UI success.

Capture uses the original raw pixel conversion unchanged. It checks buffered
write/final-close failures, creates command captures exclusively, and caps
them at 64. It neither changes colors nor overwrites earlier captures. A
completed raw file is not evidence that the guest responded to an input.

Actual limited checks on October 16:

- Five Python source-integration tests pass, including exact input hashes,
  unchanged pixel loops/evaluation counts and rejection of changed anchors.
- The native binding unit test passes 32,768 mux cases and nine negative
  controls. Its observations are synthetic **host tests, not RTL execution**.
- The existing native protocol/endpoint tests print `UI-HOST-MICRO-OK`.
- The entire generated main passes C++ syntax checking against the actual
  current model's generated headers, including its hierarchy bindings.

Evidence preparation: `external/tmp/ventium-fprem-sequence.iSZ9BAj4/pc-live-input-host-r1/`.
Generated main SHA-256:
`96f237afb4b51a19a7cc28f78132e9d12af72d924d6ff6eb19bfbdb185879db2`.
Successful bounded host-check owner:
`ventium-pc-live-input-host-oct16-r3`, invocation
`a213959852aa4b5ea40251422e9a5ddf`, native exit 0, 00:17:46–00:17:50 UTC,
184,983,552-byte memory peak, zero swap, actual child affinity CPUs 12–13.
The shell's ordered `-e` command chain includes both compilations/executions
and the final syntax check. Results were observed in the tool transcript;
this small check did not create a separate native log file. R1 and R2 failed
before compilation (systemd dollar expansion, then an absent user-manager
`rg` PATH entry); they are not passes. The successful exited unit was then
stopped to release its waiting `systemd-run --wait` client, not to kill a test.

Remaining: real-controller adapter integration tests, a private full-PC link,
UI-disabled architectural/cycle comparison, cold boot with the endpoint,
keyboard-driven visible UI changes, and general mouse motion/button input.
The inherited `--mouse` device remains unchanged and is **not** qualified by
these keyboard checks. Do not launch another long Win95 run or count this as
standard-suite/physical-FPGA acceptance until the input path is qualified.

The retained-controller adapter now has native controller microtests and a
successfully linked private whole-PC model. Its two cold keyboard probes pass
with exact guest reads and actual V retirements; an independent audit rechecks
19,475 source pins and native closure. The pinned QEMU positive/negative controls
also pass. See [current integration evidence](LOSS_AUX_IOBUS.md#cold-whole-pc-integration-probe),
including the preserved failed link and its one-wire binding correction.

No IPC gain is claimed. The current candidates are gameplay-unmeasured; the
latest verified older baseline is **0.48146083 total U+V** on model `7e877b3b…`,
cycles **1,100,065,247–1,200,065,247**. This does not establish timedemo completion.

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
