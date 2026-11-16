# Full-PC Verilator Harness (`ao486-sim/`) — Build, Boot & Checkpoints

`ao486-sim/` co-simulates the MiSTer PC/AT SoC (`3rd-party/ao486_MiSTer/rtl/system.v`)
with the host C++ platform service (`ao486-sim/ps/`: BIOS/VGA ROM loading, CMOS,
IDE/VHD sector serving, VGA capture, PS/2 injection, and DDR latency modeling)
in two configurations:

- **`ven` (`ao486sim_ven`, primary):** Swaps the 486 CPU for **`ven_ao486_shim`**
  wrapping `ventium_top` (`rtl_ven_core.f` + `rtl_ven_soc.f`, full P5 8 KiB
  2-way L1 I$ + `ven_l1d`, shared pipelined 80-bit x87 FPU, and mandatory
  `U/V + system fast-pipe` defines).
- **`all` (`ao486sim`, reference control):** Stock `ao486` 486 core baseline
  prepared by `./ao486-sim/setup.sh`.

> **Physical vs. Simulation Authority (`c0e3fe43`, 2026-11-14):** On **`main`**,
> board-qualified image **`c0e3fe43`** (`161` defines, `retime_muxf_route_first`,
> `40.264133 MHz` post-route STA sign-off on **RK-XCZU15EG-F**) passes all three
> physical standard-suite gates (both CoreMark seeds, cold Windows 95 OSR2 GUI +
> PS/2 interaction + clean shutdown, and cold DOS Quake `demo1` at `8.0 FPS` /
> `40.000 MHz`). Verified physical interior Quake gameplay IPC is **`0.515778001`
> total U+V** (`0.397847833` primary/U-only, counters include `REP`-element
> retirement) across cycles **`28,696,827,616–32,989,404,795`**. On
> **`experimental/uv-fast-ipc-apr`** (renamed from `ao486-mister-sim`),
> simulation runs and checkpoints are development/profiling tools; they do not
> substitute for QEMU differential gates or physical board qualification.

---

## 1. Build Safeguards & Private Variant Object Directories

Full-PC Verilator C++ compilation is multi-GiB and governed by repository-wide
locks (`tools/verilator_serial.sh` and `tools/build_scope.sh`):

1. **Explicit Verilator Binary:** On the maintainer host, pass
   `VENTIUM_VERILATOR_BIN=/tools/verilator/v5.046/bin/verilator` (check
   `$VENTIUM_VERILATOR_BIN --version` on other hosts). Never bypass
   `tools/verilator_serial.sh` or pass `-j 0` to Verilator.
2. **Scratch Storage (`TMPDIR`):** Place all variant object directories, disk
   working copies, frame dumps, and checkpoints on verified writable scratch
   storage under **`/home/yukidama/external/tmp`** — never in `$HOME`, repo root,
   canonical `ao486-sim/obj_dir_ven`, or symlinks into `external/ventium_run`.
3. **Full P5 Cache & Fast-Pipe Profile:** Keep the full 8 KiB L1 I$/D$ and
   `U/V + system fast-pipe` defines (`VEN_SYS_FASTPATH*`, `VEN_SYS_FASTLOAD*`,
   `VEN_SYS_FASTSTORE_FLAT`, `VEN_L1_AXI`). Never revive `VEN_CACHE_HALF` or
   `VEN_IC_NARROWB`.

Build an isolated Ventium full-PC simulator binary:

```sh
export TMPDIR=/home/yukidama/external/tmp
export VENTIUM_VERILATOR_BIN=/tools/verilator/v5.046/bin/verilator
VARIANT_OBJ="$TMPDIR/ventium-pc-sim/obj_dir_ven_cand"

tools/build_scope.sh -- make -C ao486-sim ven \
  VENTIUM_VERILATOR_BIN="$VENTIUM_VERILATOR_BIN" \
  VEN_OBJDIR="$VARIANT_OBJ" \
  VEN_EXE=ao486sim_ven
```

---

## 2. Cold Boot Workloads (`ao486sim_ven`)

Run from `ao486-sim/` (so relative `../3rd-party/ao486_MiSTer` ROM paths resolve,
or set `AO486_BIOS_DIR` explicitly) against a **private writable copy** of the
guest VHD image under `/home/yukidama/external/tmp`:

### Cold Windows 95 Desktop Boot

If your raw FAT16 Windows 95 disk image still references an uninstalled PnP/Cirrus
display driver instead of standard planar VGA (`mode 12h`), apply the scripted
`SYSTEM.INI` update once on a copy (`[boot] display.drv=vga.drv`):

```sh
cp /path/to/clean/w95_200.vhd "$TMPDIR/ventium-pc-sim/w95_work.vhd"
ao486-sim/tools/apply_win95_display_fix.sh "$TMPDIR/ventium-pc-sim/w95_work.vhd"

cd ao486-sim
AO486_RTC_EPOCH=946684800 "$VARIANT_OBJ/ao486sim_ven" \
  --ide "$TMPDIR/ventium-pc-sim/w95_work.vhd" \
  --rate 40000000 --ddrlat 2 --mem 32 --mouse \
  --fb-every 50000000 --fb-out "$TMPDIR/ventium-pc-sim/fb" \
  --cycles 4000000000
```

### Cold FreeDOS / Quake `timedemo demo1`

```sh
cp /path/to/clean/qk_td.vhd "$TMPDIR/ventium-pc-sim/qk_work.vhd"
cd ao486-sim
AO486_RTC_EPOCH=946684800 "$VARIANT_OBJ/ao486sim_ven" \
  --ide "$TMPDIR/ventium-pc-sim/qk_work.vhd" \
  --rate 40000000 --ddrlat 2 --mem 32 \
  --ven-perf-every 10000000 \
  --fb-every 50000000 --fb-out "$TMPDIR/ventium-pc-sim/qk_fb" \
  --cycles 3500000000
```

---

## 3. Native Profiling Checkpoints & Replay (`--snapshot-v3` / `--snapshot-v4`)

`ao486-sim/ven/sim_ven.cpp` builds with Verilator `--savable` and supports
deterministic same-binary checkpointing for profiling windows:

- **Use `--snapshot-v3` (no mouse) or `--snapshot-v4` (when `--mouse` is active):**
  - `--snapshot-v3` serializes the Verilator RTL model (including caches and x87),
    guest DDR, DDR-model burst queues **plus the `prev_rd` read-edge latch**,
    pointer-free plain-ATA controller/drive/file-offset state
    (`ao486-sim/ven/ide_checkpoint.h`), and SPI transaction state. Legacy v1/v2
    formats omit `prev_rd` and must not be used for new captures.
  - `--snapshot-v4` extends v3 with PS/2 mouse host state (`--mouse`).
  - For retired-PC-triggered checkpoints (`--save-at-retired-pc CS:OFFSET`), see
    [`../tools/PC_SNAPSHOT.md`](../tools/PC_SNAPSHOT.md).
- **Same-Executable & Private-Disk Rules:**
  - Never restore a serialized model into a changed RTL/Verilator binary; native
    snapshots are **not** cross-RTL architectural importers.
  - Always capture with `--save-at N --save-stop --save-file PATH` and pinned
    `AO486_RTC_EPOCH` so ATA `fflush` completes before copying/hashing the disk.
  - `--cycles` is an **absolute** cycle target across the restored timeline.
    When measuring post-restore IPC, discard a declared warm-up window and
    difference two post-warmup samples (`tools/cpi_interval.py`) rather than
    dividing cumulative counters by post-restore cycles alone.

### Reproducible Capture, Replay Gate & Bundle Staging

```sh
# 1. Standalone pointer-free ATA checkpoint unit check (no Verilator build):
g++ -std=c++17 -Wall -Wextra -Werror -Iao486-sim/ps \
  ao486-sim/ven/test_ide_checkpoint.cpp -o "$TMPDIR/test-ide-checkpoint"
"$TMPDIR/test-ide-checkpoint"

# 2. Cold v3 capture into a fresh 5-file sealed bundle (sim + ROMs + snap + VHD):
OUTDIR="$TMPDIR/ventium-capture-new" \
SIM_BIN="$VARIANT_OBJ/ao486sim_ven" \
DISK_IMAGE=/path/to/clean/qk_td.vhd \
AO486_BIOS_DIR="$PWD/3rd-party/ao486_MiSTer/releases/bios" \
  bash ao486-sim/ven/run-gameplay-capture.sh

# 3. Verify uninterrupted vs. save+restore byte-exact state & disk equivalence:
OUTDIR="$TMPDIR/ventium-replay-check" \
SIM_BIN="$VARIANT_OBJ/ao486sim_ven" \
DISK_IMAGE=/path/to/clean/qk_td.vhd \
AO486_BIOS_DIR="$PWD/3rd-party/ao486_MiSTer/releases/bios" \
SAVE_CYCLE=12000000 END_CYCLE=16000000 \
  bash ao486-sim/ven/run-checkpoint-replay.sh

# 4. Verify a completed 5-file bundle receipt and stage an isolated replay copy:
python3 -B tools/checkpoint_bundle.py "$TMPDIR/ventium-capture-new" \
  --stage "$TMPDIR/ventium-replay-staged"
python3 -B -m unittest discover -s tools -p test_checkpoint_bundle.py -v
```

---

## 4. Reference Control: Stock `ao486` 486 Baseline (`ao486sim`)

To build and run the original unmodified 486 CPU control (`ao486-sim/sim_main.cpp`
+ `ao486-sim/rtl.f` + `ao486-sim/patches/ao486_MiSTer.patch`):

```sh
./ao486-sim/setup.sh   # initializes 3rd-party/ao486_MiSTer, applies patch, builds time_shim + ao486sim
cd ao486-sim
env TZ=UTC FAKE_TIME=946684800 LD_PRELOAD=../tmp/time_shim.so \
  ./obj_dir/ao486sim \
    --ide "$TMPDIR/ventium-pc-sim/w95_work.vhd" --rate 4000000 --ddrlat 1 --mem 32 \
    --mouse --video-fb \
    --kb "enter,enter,enter,enter" --kb-start 550000000 --kb-gap 120000000 \
    --cycles 4000000000
```

For an instruction-traced 486 control build, pass a private `OBJDIR`:

```sh
tools/build_scope.sh -- make -C ao486-sim FAST=1 \
  OBJDIR="$TMPDIR/obj_dir_ao486_dbg" EXE=ao486sim_dbg
```
