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

Current verified **gameplay** IPC is **0.49843606**, model `958f7ec4`, clocks
2,400,048,811–2,500,048,811.
The fixed first window remains 0.49741357; all thirteen consecutive 100M windows
beginning 1,200,048,811 average **0.47898937**, including 0.40860952 and
0.41837727 dips. This aggregate is below the 0.48 target. Latest audit:
`external/tmp/ventium-sfetch16-latest-r5.675qsYCh/audit.json`.
Real V retirements and raw
endpoint frames are checked; no intervening window is excluded. This is not complete timedemo
or physical-board qualification. New private FST/C1/RET/sharing derivatives
remain unmeasured in gameplay; generic differential and full-suite work remain
open. This port changes no RTL and closes none of those obligations by itself.

The subsequent private [branch-read hint](../../fe_pipe/RAW_BRANCH_PRIME.md)
and [independent cache-window invalidation](../../l1/INDEPENDENT_WINDOWS.md)
reach short diagnostic ratios **2.029545721 / 2.035715820** on model `8a9cabcd`,
with matched five-CRC sets. They remain below 2.1, insufficient-duration and
unmeasured in gameplay; generic verification is still red. Those documents
separate matched gains, directed gates and outstanding full-suite/FPGA work.
The later [register-prefix/EX experiment](../../fe_pipe/PREFIX_EX_SYSTEM.md)
with IF-qualified INTR reaches **2.056586568 / 2.062922435** short ratios,
model `252109e4`. It remains experimental, below target, insufficient-duration,
unmeasured in gameplay and not period-correct P54/full-suite/FPGA acceptance.

### Protected-client PREFIX66 backport (private candidate)

Model **320c4232** changes only the PREFIX66 D1 context/owner leaf and adds
`VEN_P54_PREFIX66_SYSTEM` to the parent above. It retains the real prefix D1
clock, register-only whitelist and ordinary system/relocation guards; see
[`PREFIX66_SYSTEM.md`](../../fe_pipe/PREFIX66_SYSTEM.md) for the directed tests
and remaining qualification. Actual cache-backed cold runs remove 83,261 /
84,377 TSC clocks: short ratios **1.994712814 / 1.999582887**, gains **1.660818% /
1.687188%**, both below 2.1 and **not duration-valid scores**. All five CRCs
per seed match; no gameplay measurement exists for this derivative.

The first launcher failed before reset (insufficient TasksMax); the second
completed but failed its CPU-affinity audit. The final explicit-taskset repeat
reproduces both exact results with verified single-CPU child affinity, native
exit 0, all children reaped, stable source/media pins and no OOM:
`external/tmp/ventium-prefix66-system-soc.uLbhxUAh/coremark-r3/audit.json`.
Generic differential failures remain; this is not standard-suite acceptance.

The independently added exact-byte RET capture (`1cad4e49`) saves only
**520 / 247** more TSC clocks in this SoC: **1.994919737 / 1.999681651** short
ratios, **0.010374% / 0.004939%** throughput gain. It preserves both five-CRC
sets and closes native 0 with explicit CPU 3 affinity, no OOM, 285 stable pins
and retained successful supervisor. Receipt:
`external/tmp/ventium-prefix66-ret-soc.B0860bF9/coremark/audit.json`.
The earlier standalone RET percentage must not be projected onto this build.

### Every-clock diagnostic: 7M–8M

`external/tmp/ventium-coremark-soc-state.jeo3fLiy` cold-boots the unchanged
performance disk on the same native. Only existing read-only observers are
added. It completes in 91.26 host seconds, native exit 0, same five CRCs and
**exactly the same 5,096,514 measured guest clocks**. One million consecutive
`VENSTATE` core/bus observations are recorded; this is **not** the separate
complete retained-model state-delta format. Raw output is streamed directly
to gzip: 353,911,575 bytes become 22,069,608 bytes, with no uncompressed disk
copy. The independent analyzer re-reads the entire archive, checks its hash
and consecutive timestamps, and matches every state count against periodic
RTL counters. All one million clocks reconcile:

| Exclusive residency | Clocks | Percent |
| --- | ---: | ---: |
| Pipeline issue arm | 438,760 | 43.8760% |
| Pipeline dispatch to slow path | 88,490 | 8.8490% |
| Pipeline load-result wait | 39,112 | 3.9112% |
| Pipeline store-result wait | 7,348 | 0.7348% |
| Branch-misprediction penalty | 32,732 | 3.2732% |
| Address-generation interlock | 32,653 | 3.2653% |
| Registered I-cache read wait | 17,815 | 1.7815% |
| Slow IMUL execution | 180,645 | 18.0645% |
| Slow MOVSX execution | 52,017 | 5.2017% |
| Other slow execution | 43,129 | 4.3129% |
| Slow operand load | 48,373 | 4.8373% |
| Decode | 10,289 | 1.0289% |
| Slow store | 7,276 | 0.7276% |
| Fetch | 1,361 | 0.1361% |
| **Total** | **1,000,000** | **100.0000%** |

These are clock owners, **not percentages of wasted cycles or proven savings**.
The issue arm is useful work, and required execution latency cannot simply
be deleted. Slow instruction attribution uses the latched `q_pc` and the
actual ELF disassembly only in S_EXEC; the stale S_PIPE `q_kind` is not used
to classify current fast instructions. The slice's 0.715040 CoreMark
retirement-event IPC is not a gameplay result.

Three matrix IMUL sites (`115bc`, `115a6`, `114f6`) account for 167,685 clocks.
Four adjacent sign-extension sites (`115a0`, `115a3`, `114f0`, `114f3`) account
for 44,464 execution clocks. Preserve instruction-latency/NP contracts while
investigating surrounding dispatch, fetch and operand handoff. In particular,
do **not** enable old `VEN_FAST_MEM_EXT` wholesale: its documented two-clock
result cadence conflicts with the retained EXT result-retirement regression's
minimum four-clock contract. The old directed ISA passes do not waive that
timing check or supply current Win95/Quake acceptance.

Other measurable targets are the 3.2732% misprediction and 3.2653% address
interlock buckets. They need separate cause/owner witnesses before changing
prediction or forwarding. Eliminating all pipeline D-result waits in this
slice would cover only 4.6460% of its clocks; it is not by itself a demonstrated
route from the current short ratio to 2.1, nor proof that those waits are cache
misses. Preserve the small existing RET and write-buffer experiments as
independent A/B changes rather than crediting them with this whole gap.

### Prefix + RET every-clock follow-up

`external/tmp/ventium-prefix-ret-state.qeLjIB2y` closes native 0 in 98.48 seconds,
same **5,012,733** performance-seed ticks and all CRCs. The one-million-clock
7M–8M archive is lossless (353,919,689 raw bytes, 22,109,553 compressed), not a
full internal-state dump. Its independent analysis reconciles every clock,
including the new 17,634 paid prefix-D1 clocks. CoreMark event IPC is 0.722772,
**not gameplay IPC**. Equal-time slices execute different amounts of work, so
their residency differences are not themselves causal percentage gains.

Joining the actual pre-edge `VENSTATE` and `VENL1` records identifies a more
specific target: **all 39,341 pipeline load-wait clocks** in this slice have an
asserted cacheable read, no L1 ACK, idle L1 FSM, and a resident tag hit.
All 7,358 pipeline store waits likewise see a resident hit. These match the
independent pipeline counters exactly: they are **hit-service latency, not
cache misses** in this window. Another 5,591 slow-load clocks have that same
resident-read wait; only seven observed request-wait clocks have a different
fill/nonresident classification. This does not establish that every wait is
removable, or that no other phase has cache misses.

The two hottest pipeline read sites are `10d66` and `10ef2`, both
`mov 4(%eax),%edx`, with 5,296 and 4,476 wait clocks. Each follows a conditional
branch in a list traversal. The current raw-decoder early-read helper accepts
an unpaired V descriptor, but explicitly excludes branch-successor priming;
the older branch option requires the disabled uop cache and cannot simply be
enabled here. Investigate a checked fallthrough read using existing returned
instruction bytes and the existing resident-only query port. Preserve outcome,
GPR-address dependencies, permissions, events and invalidation ownership;
do not issue speculative AXI reads or add a whole decoder/cache to bypass them.
