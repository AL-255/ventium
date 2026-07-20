# Reproducing the Win95 boot-to-desktop (from a clean clone)

This reproduces the result documented in [`../AO486_SOC_FIX.md`](../AO486_SOC_FIX.md):
Windows 95 booting to a complete, correctly-rendered desktop on the `ao486_MiSTer`
486 SoC under Verilator, with L1+L2 caches on and no runtime injection.

## What the repo provides vs. what you supply

The repo is fully self-contained **except the disk image**, which is a ~2 GB Win95
installation and cannot live in git. Everything else — the sim source, the RTL
submodule + its boot-path patch, the deterministic-clock shim, and the guest
display-driver fix — is committed and scripted.

| Provided by the repo | You supply |
|---|---|
| Sim harness (`ao486-sim/`), RTL submodule + `patches/ao486_MiSTer.patch` | A raw Win95 FAT16 HDD image (`w95_200.vhd`) |
| `setup.sh` (submodule init + patch + build) | `verilator`, `g++`, `make`, `mtools` |
| `tools/time_shim.c`, `tools/apply_win95_display_fix.sh` | |

## Prerequisites

```sh
# Debian/Ubuntu example
sudo apt-get install verilator g++ make mtools git      # verilator >= 5.0
```

## 1. Clone + build

```sh
git clone git@github.com:AL-255/ventium.git
cd ventium
git checkout ao486-mister-sim
./ao486-sim/setup.sh          # submodule init -> apply RTL patch -> build shim -> build sim
```

`setup.sh` is idempotent. It initializes `3rd-party/ao486_MiSTer`, applies
`ao486-sim/patches/ao486_MiSTer.patch` (functional boot-path RTL changes:
`l2_cache.v`, `rtc.v`, `system.v`, `read.v`, x87 decode), builds `tmp/time_shim.so`,
and builds `ao486-sim/obj_dir/ao486sim`.

## 2. Provide the Win95 disk image

Place a **raw Win95 FAT16 hard-disk image** at `ao486-sim/run_w95/w95_200.vhd`
(a standard MiSTer ao486 Win95 install works; standard MBR, partition 1 at LBA 2048).
This file is not in the repo (size).

## 3. Apply the display-driver fix (once, in place)

```sh
cd ao486-sim
tools/apply_win95_display_fix.sh run_w95/w95_200.vhd
```

This sets `[boot] display.drv=vga.drv` in the guest `SYSTEM.INI` (backs up the
original alongside the image). Required because the stock image points `display.drv`
at an uninstalled PnP/Cirrus driver that doesn't match the emulated standard-VGA
adapter — the direct cause of the "display adapter not configured properly" first-boot
hang. Details: `AO486_SOC_FIX.md` §2.10. (Skip only if your image already uses
`vga.drv`.)

## 4. Boot to the desktop

```sh
cd ao486-sim
env TZ=UTC FAKE_TIME=946684800 LD_PRELOAD=../tmp/time_shim.so \
  ./obj_dir/ao486sim \
    --ide run_w95/w95_200.vhd --rate 4000000 --ddrlat 1 --mem 32 \
    --mouse --video-fb --save-every 200000000 \
    --kb "enter,enter,enter,enter" --kb-start 550000000 --kb-gap 120000000 \
    --cycles 4000000000
```

- No `--no-l1`, no `--w95-*`, no `--ptefix`: caches on, no injection.
- The four Enters dismiss the first-boot Mouse / DST-clock / Date-Time dialogs.
- The accurate frame is written to `../tmp/ao486_fb.ppm` (mode-12h plane reader).
  The desktop appears at ~cyc 0.75–0.96 B (≈40–55 min wall-clock; the release build
  is faster than the traced debug build).
- Expected result — the complete desktop (teal background, icons My Computer / Inbox /
  Recycle Bin / The Internet / Set Up MSN, and the taskbar with Start + clock):
  see [`docs/win95_desktop.png`](docs/win95_desktop.png).

## Diagnostic (traced) build

The eip/VGA-mode examples in `AO486_SOC_FIX.md` use a debug build with instruction
tracing. Build it with:

```sh
make -C ao486-sim FAST=1 OBJDIR=ao486-sim/obj_dir_dbg EXE=ao486sim_dbg
# then run ./obj_dir_dbg/ao486sim_dbg with the same flags as above
```

## Notes on reproducibility

- **RTL submodule patch**: the boot depends on local changes to the `ao486_MiSTer`
  RTL (L2 cache, RTC, `system.v`, x87 decode). They are captured in
  `ao486-sim/patches/ao486_MiSTer.patch` against the pinned submodule commit
  `e1bd767` and applied by `setup.sh` — no fork needed. If you re-pin the submodule,
  regenerate the patch.
- **Determinism**: `time_shim.so` pins the host clock; `--rate 4000000` fixes the
  guest CPU:timer ratio. Same image + same flags → same boot.
- **Disk image**: the one external dependency. The display fix (step 3) is the only
  guest modification required; it is scripted and reversible via the `.system.ini.bak`.
