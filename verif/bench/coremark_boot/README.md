# BIOS-bootable CoreMark port

This port measures the normal PC cache/memory path without a Linux-user
service shim or a saved CPU state. It does **not** change the five upstream
CoreMark algorithm/framework C files. The original barebones formatter only
replaces its UART stub with the port's console function. All translation
units use the same optimization flags; there is no LTO or workload-specific
RTL. Generated source, compiler identity, commands, CRC output and hashes are
retained outside the repository.

The boot sector performs an ordinary BIOS EDD disk read. The payload enters
flat 32-bit protected mode, enables the caches, clears BSS and calls `main`.
It runs at CPL0 with paging and interrupts disabled, using stack-allocated
data. This environment does not test OS paging, interrupts or the previous
Linux-user runtime. The new GCC 13.4 build is not byte-identical to the older
GCC 13.3/Linux images; do not attribute differences solely to RTL.

`start_time`/`stop_time` use P54 CPUID/RDTSC, not a host clock or an assumed
instruction count. Raw 64-bit endpoints and their difference are printed
outside the timed loop, both to E9 and ordinary VGA text memory. The port's
integer-seconds conversion is calibrated for **40MHz**. Verify the actual
core/TSC clock before interpreting a hardware result. Intervals that exceed
32-bit CoreMark ticks print an error; do not accept them after truncation.
`PORT-END` means completion only, never correctness or performance acceptance.

## Build and short reference check

Use a fresh external output directory and a bounded service (512 MiB/180 s is
sufficient for this build/QEMU smoke). Do not run Python with `-O`.

```sh
TMPDIR=/home/yukidama/external/tmp python3 -B \
  verif/bench/coremark_boot/build.py \
  --out /home/yukidama/external/tmp/coremark-boot-new --qemu-smoke

TMPDIR=/home/yukidama/external/tmp python3 -B -m unittest discover \
  -s verif/bench/coremark_boot -p test_check_result.py
```

The builder defaults explicitly to `/usr/bin/x86_64-linux-gnu-gcc-13`, produces
two sparse 8 MiB disks and uses the private pinned QEMU with `-cpu pentium`.
Both 10-iteration smoke runs must return native 33 through `isa-debug-exit` and
match all five CRCs. They must also retain the benchmark's **minimum-duration
ERROR**. Thus a smoke pass is not an error-free standard-suite pass or a valid
CoreMark score. QEMU TSC values are never processor-performance evidence.

For a longer disk, omit `--qemu-smoke` and specify `--iterations N`. Obtain
the CRC reference from the same seed/iteration count; `crcfinal` depends on
iterations. Require at least 10 target seconds, the benchmark's validated
message, no errors and matching CRCs. Do not alter the benchmark's duration
check. The earlier valid direct-memory scores 2.107843209/2.110905243 are not
scores for this port, the SoC cache/DDR path or the physical FPGA.

## Cold SoC use

Use an independently admitted UV+system/relocated-fast-pipe model with fast
loads/stores and `cycle_mode=1`. Copy the original `boot0.rom`/`boot1.rom`
into a private run's `rom/` and **set `AO486_BIOS_DIR` to its absolute path**.
Copy the selected `coremark.img` into the run as writable guest media; do
not run against the original built image. No snapshot, debugger STEP,
pairing suppression or register/RAM injection is needed.

```sh
# Within a fresh, bounded run directory; MODEL is the audited model binary.
AO486_BIOS_DIR="$PWD/rom" "$MODEL" --ide "$PWD/coremark.img" \
  --rate 40000000 --rate-rtc 40000000 --rate-vga 80000000 --mem 16 \
  --cycles 30000000 --ven-perf-every 1000000 --vgatext-every 1000000
```

This 30M cap is for the 10-iteration smoke only. A cycle-cap exit is not a pass:
require a complete VGA result, all CRCs and consistent printed raw TSC/total
ticks. `check_result.check` validates one console result and deliberately does
not grant board/suite qualification. Separately check native closure, input
hashes, real V retirement, no faults and no OOM. Do not accept the apparent
`[BOOT]` message if the log says a BIOS file could not open: executing zeros
can also pass through address 7c00. Missing ROMs are a failed launcher, not an
RTL bug or a usable cold-boot result.

## October 10 evidence

Reference root: `external/tmp/ventium-coremark-boot.z4ICVy4Y/smoke-r2`.
Both seeds close native 33 under pinned QEMU, with all five expected CRCs;
the bounded builder closes 0 with stable inputs. An earlier GCC 15 smoke is
retained separately, not conflated with the explicit GCC 13.4 build.

Cache-backed model: `958f7ec4`, same binary/source closure as the demand-fetch
Quake run and FPGA export; full P5 L1s, 256 KiB L2, posted-16 DDR transport,
40/40/80 MHz timebases. The SoC smoke root is
`external/tmp/ventium-coremark-boot-soc-r2.nTgGznlY`.
The first launcher attempt omitted `AO486_BIOS_DIR` and was stopped; its
separate failed artifacts are retained under `ventium-coremark-boot-soc.6oFO6yAk`.

The performance seed completes by the 12,000,437-clock VGA observation, with
all five CRCs correct and 5,096,514 measured TSC clocks. Its short diagnostic
ratio is **1.96212548 CM/MHz**, **not a score** and below 2.1. The minimum-duration
error is retained. Validation also completes by 12,000,437 clocks, with all
five CRCs correct and 5,085,420 TSC clocks: **1.96640592**, likewise not a score.
Both native children exit 0 and are reaped; the supervisor closes successfully.
The independent `audit.json` rechecks 256 pins, unchanged private disks/ROMs,
the actual executable, real V retirement and matching QEMU/SoC console CRCs.
The result-checker passes six tests including twelve malformed-output controls.

The independent 7M–11M steady benchmark interval has
2,858,729 U+V events/4M clocks (CoreMark IPC, **not gameplay IPC**): S_PIPE
65.67%, S_EXEC 27.60%, S_LOAD 4.85%, other states 1.88%. Pipeline D-result waiting
is 4.65% of all clocks, already inside S_PIPE; do not add it again. This is a
residency description, not a proven cache-miss or causal-savings breakdown.

Current verified **gameplay** IPC is **0.49741357**, model `958f7ec4`, clocks
1,200,048,811–1,300,048,811, from a predeclared cold-Quake window with real V
retirements and both raw endpoint frames reviewed. It is not complete timedemo
or physical-board qualification. New private FST/C1/RET/sharing derivatives
remain unmeasured in gameplay; generic differential and full-suite work remain
open. This port changes no RTL and closes none of those obligations by itself.
