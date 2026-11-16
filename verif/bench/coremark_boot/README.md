# BIOS-Bootable Bare-Metal CoreMark (`verif/bench/coremark_boot/`)

`verif/bench/coremark_boot/` builds freestanding 8 MiB BIOS-bootable disk images for the two standard CoreMark seeds (performance and validation) without modifying the five upstream CoreMark C source files or relying on a Linux-user syscall shim or CPU snapshot.

## Physical Standard-Suite Status (`c0e3fe43`, 2026-11-14)

CoreMark is **Gate 1 of the 3-gate Ventium Standard Acceptance Suite** (alongside cold Windows 95 OSR2 GUI + shutdown and cold DOS Quake `timedemo demo1`):

- **Verified Physical Result on `main` (`c0e3fe43`, RK-XCZU15EG-F at `40.000 MHz`):**
  - **Performance seed:** **`2.100128 CM/MHz`** (`4,000` iterations, `2 KiB` total data, `>10 s` duration, `Correct operation validated.`, all 5 reference CRCs matched).
  - **Validation seed:** **`2.106796 CM/MHz`** (`4,000` iterations, `2 KiB` total data, `>10 s` duration, `Correct operation validated.`, all 5 reference CRCs matched).
- **Mandatory Reporting Rule (`AGENTS.md`):** **Never substitute CoreMark CM/MHz or CoreMark IPC for physical Quake gameplay IPC.** Current verified physical Quake gameplay IPC on `c0e3fe43` is **`0.515778001` total U+V** (`0.397847833` primary/U-only) across cycles **`28,696,827,616–32,989,404,795`** (`8.0 FPS`). Unmeasured experimental rebuilds do not inherit either figure.

## Architecture & Timing Calibration

- **Boot & execution model:** The MBR boot sector reads the payload via BIOS EDD, enters flat 32-bit protected mode (`CPL0`, interrupts and paging off, L1 caches enabled), zeroes `.bss`, and invokes `main()` with stack-allocated buffers.
- **Timebase:** `start_time()` / `stop_time()` read P54 `CPUID` + 64-bit `RDTSC` outside the timed kernel, printing raw 64-bit start/end timestamps and tick deltas to both port `0xE9` and VGA text memory (`0xB8000`).
- **Clock calibration:** Integer-seconds conversion is calibrated for **`40.000 MHz`**. Always verify the actual core/TSC clock before interpreting `CM/MHz`, and never accept truncated 32-bit tick overflows or short (<10 s) runs as valid CoreMark scores (`PORT-END` indicates completion only).

## Building Disk Images & Running Unit Tests

Always use a fresh external scratch directory under `/home/yukidama/external/tmp` and never run Python with `-O`:

```sh
# 10-iteration smoke images + pinned QEMU CRC self-check (exits 33 via isa-debug-exit;
# retains CoreMark's expected <10s minimum-duration warning — smoke is NOT a valid score):
TMPDIR=/home/yukidama/external/tmp python3 -B \
  verif/bench/coremark_boot/build.py \
  --out /home/yukidama/external/tmp/coremark-boot-smoke --qemu-smoke

# Full duration-valid standard-suite images (e.g. 4,000 iterations at 40 MHz -> >10 s):
TMPDIR=/home/yukidama/external/tmp python3 -B \
  verif/bench/coremark_boot/build.py \
  --out /home/yukidama/external/tmp/coremark-boot-4000 --iterations 4000

# Result-parser unit tests (including malformed/insufficient-duration rejections):
TMPDIR=/home/yukidama/external/tmp python3 -B -m unittest discover \
  -s verif/bench/coremark_boot -p test_check_result.py
```

`build.py` defaults to `/usr/bin/x86_64-linux-gnu-gcc-13` with uniform optimization flags across all translation units (no LTO, no workload-specific RTL). Reference `crcfinal` depends on iteration count and must come from the matching seed/iteration run.

## Cold Full-PC Simulation (`ao486-sim`)

Run on an audited `U/V + system fast-pipe` (`cycle_mode=1`) model with private copies of `boot0.rom`, `boot1.rom`, and writable `coremark.img` inside an external scratch directory. Always set `AO486_BIOS_DIR` to the absolute ROM directory (missing BIOS files execute zero-filled memory through `0x7C00` and must never be treated as a valid boot):

```sh
# 10-iteration smoke example (30M-cycle cap; full 4,000-iteration runs require ~500M+ cycles):
AO486_BIOS_DIR="$RUN_DIR/rom" "$MODEL" --ide "$RUN_DIR/coremark.img" \
  --rate 40000000 --rate-rtc 40000000 --rate-vga 80000000 --mem 16 \
  --cycles 30000000 --ven-perf-every 1000000 --vgatext-every 1000000
```

Validate console output with `check_result.py`, verify non-zero paired V retirements, confirm zero unexpected faults/OOMs, and retain exact model/ROM/disk SHA-256 receipts.
