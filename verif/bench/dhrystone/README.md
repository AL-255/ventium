# Bare-metal 32-bit Protected-Mode Dhrystone 2.1 Benchmark

> **Mandatory Scope & Reporting Caveat (`AGENTS.md`)**: Simulated Dhrystone 2.1
> is a **synthetic integer microbenchmark** whose code (~4.3 KiB) and active
> data working set fit entirely inside L1 instruction/data caches and TLBs. It
> **never** substitutes for physical-board acceptance or real-world gameplay
> IPC. Current **verified physical hardware gameplay IPC** is
> **`0.515778001` total U+V** (`0.397847833` primary/U alone) on board-qualified
> RK-XCZU15EG-F image **`c0e3fe43`** across Quake gameplay cycles
> `28,696,827,616–32,989,404,795` (`8.0 FPS` `demo1` at `39.999802 MHz`,
> post-route STA closed at `40.264133 MHz`).

## Purpose

This directory provides a self-contained, bare-metal 32-bit protected-mode port
of Reinhold P. Weicker's **Dhrystone 2.1** (May 25, 1988 C Version 2.1) for
apples-to-apples `DMIPS/MHz` comparison against other open-source x86 FPGA soft
cores (**`ao486`**, **`z386`**, and **`z486`**).

### Reference `z486` / `ao486` Benchmark Methodology

Published numbers from nand2mario's `z486` repository
(`https://github.com/nand2mario/z486`, commit `62ae68e3`, `README.md` and
`tests/dhrystone/`) and technical report
(`https://nand2mario.github.io/posts/2026/z486/`):

- **VAX 11/780 normalization**:
  $$\text{DMIPS/MHz} = \frac{\text{Iterations} \times 10^6}{\text{Cycles} \times 1757}$$
- **Published cross-core comparison table (`z486` technical report)**:
  - Compiler flags: **`-O3 -fno-inline`**, separate compilation, no LTO, no
    explicit `register` declarations (`REG` undefined), `i386` ISA target,
    freestanding byte-loop `strcpy`/`strcmp`/`memcpy` (`support.c`).
  - Memory/cache setup: 32-bit protected mode with 4 KiB paging enabled
    (`CR0 = 0x80000001`), matched **8 KiB I$ + 8 KiB D$** for `z386` and `z486`
    (native cache for `ao486`), earliest-cycle memory interface response.
  - Published scores:
    - **`ao486`**: `2,934.0` cycles/Dhrystone, CPI `4.556`, **`0.194 DMIPS/MHz`** (`17.46 DMIPS` @ 90 MHz)
    - **`z386`**: `2,526.4` cycles/Dhrystone, CPI `4.101`, **`0.225 DMIPS/MHz`** (`19.15 DMIPS` @ 85 MHz)
    - **`z486` (Aug 2026 initial release)**: `1,725.0` cycles/Dhrystone, CPI `2.800`, **`0.330 DMIPS/MHz`** (`28.05 DMIPS` @ 85 MHz)
    - *(Note: `z486` `README.md` notes an Oct 2026 revision reduced Dhrystone CPI from `2.8` to ~`2.0`, corresponding to ~`0.46 DMIPS/MHz`, without an updated table.)*
- **Current `z486/tests/dhrystone/Makefile` baseline**:
  - Uses `-m32 -march=i386 -mno-80387 -ffreestanding -fno-builtin -O2 -DREG=register -DDHRY_EMBEDDED`.

## Ventium Execution & Self-Check Contract

1. **Unmodified Dhrystone 2.1 Procedures**: `dhry.h`, `dhry_1.c`, and `dhry_2.c`
   preserve Reinhold Weicker's Version 2.1 `Proc_1`..`Proc_8` and
   `Func_1`..`Func_3` without algorithmic modification, compiled as separate
   translation units with `-fno-lto -ffreestanding -fno-builtin` against the
   same simple byte-loop `strcpy`/`strcmp`/`memcpy` (`support.c`) as `z486`.
2. **Real System/Paged Protected-Mode Boot (`boot_bios.S`, `link.ld`)**:
   Cold-resets at `F000:FFF0`, installs a flat 4 GiB 32-bit GDT (`CS=0x08`,
   `DS/ES/SS/FS/GS=0x10`), relocates `.text`/`.rodata`/`.data` to physical
   `0x00010000` (ordinary L1-cacheable DRAM, matching `z486`'s
   `CODE_PHYS_BASE = 0x00010000`), zeroes `.bss`, builds 4 KiB identity page
   tables (`0..4 MiB`) at `0x00070000..0x00071FFF`, enables L1 I$/D$ (`CR0.CD=0`,
   `CR0.NW=0`) and 4 KiB paging (`CR0 = 0x80000001`), and runs 20 warm-up
   iterations followed by a full `initialize_dhrystone()` state reset before
   entering the timed run.
3. **Exact `CPUID` + `RDTSC` Loop Window (`dhrystone_port.c`)**:
   Serializes with P54 `CPUID` and samples 64-bit `RDTSC` immediately before
   and after the canonical `Run_Index = 1..Number_Of_Runs` loop. Zero port I/O
   executes inside the timed loop.
4. **Full 20-Field Self-Check**:
   Verifies `Int_Glob == 5`, `Bool_Glob == 1`, `Ch_1_Glob == 'A'`,
   `Ch_2_Glob == 'B'`, `Arr_1_Glob[8] == 7`,
   `Arr_2_Glob[8][7] == Number_Of_Runs + 10`, `Ptr_Glob` and `Next_Ptr_Glob`
   (`Ptr_Comp`, `Discr`, `Enum_Comp`, `Int_Comp == 17/18`, `Str_Comp`),
   `Int_1_Loc == 5`, `Int_2_Loc == 13`, `Int_3_Loc == 7`,
   `Enum_Loc == Ident_2`, `Str_1_Loc`, and `Str_2_Loc`, exiting via
   `isa-debug-exit` (`0xF4`) with native code `33` only on pass.
5. **Two-Point Steady-State Marginal Cross-Check**:
   `run_dhrystone.py` runs both `N_low = 200` and `N_high = 2200` (`ΔN = 2000`
   steady-state iterations; verified identical at `ΔN = 5000`), confirming exact
   agreement between guest `RDTSC` and hardware `[PERF]` U-pipe / paired V-pipe
   retirement counters.

## Simulated Results on Board-Qualified `c0e3fe43` RTL Profile

Measured with Verilator `5.046` (`/tools/verilator/v5.046/bin/verilator`),
`x86_64-linux-gnu-gcc-13` (`Ubuntu 13.3.0-6ubuntu2~24.04.1`), `cycle_mode=1`,
`--system --cosim --l1-axi`, all **158** simulation RTL defines of
board-qualified image **`c0e3fe43`** (`fpga/known_good_defines.txt` minus
Vivado synthesis-only `{SYNTHESIS, VTM_NO_DPI, VEN_ALTSYNCRAM_XPM}`: 8 KiB L1
I-Cache, 8 KiB 8-bank L1 D-Cache `ven_l1d`, 32-entry 4-way I-TLB, 64-entry
4-way D-TLB, 256-entry BTB, zero-wait-state AXI backing `AXI_RLAT=0 AXI_WLAT=0`
matching the `z486` report's earliest-cycle memory interface):

| Core / Compiler Profile | Flags Summary | Cycles / Dhry | Loop CPI (U+V) | Loop IPC (Total U+V / U-only) | Paired V Share | **DMIPS / MHz** | DMIPS @ Rated FPGA Clock |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| **`ao486`** *(published, `z486` report)* | `-march=i386 -O3 -fno-inline` | `2,934.0` | `4.556` | `0.219` *(scalar)* | — | **`0.194`** | `17.46` @ 90 MHz |
| **`z386`** *(published, `z486` report)* | `-march=i386 -O3 -fno-inline` | `2,526.4` | `4.101` | `0.244` *(scalar)* | — | **`0.225`** | `19.15` @ 85 MHz |
| **`z486`** *(published Aug 2026 release)* | `-march=i386 -O3 -fno-inline` | `1,725.0` | `2.800` | `0.357` *(scalar)* | — | **`0.330`** | `28.05` @ 85 MHz |
| **Ventium (`c0e3fe43`, `z486_report`)** | `-march=i386 -O3 -fno-inline` *(exact parity)* | **`955.0`** | **`1.525`** | **`0.6555`** / `0.4953` | `24.44%` (`32.35%` groups) | **`0.5960`** | **`23.84`** @ 40 MHz STA (`37.25` @ 62.5 MHz OC*) |
| **Ventium (`c0e3fe43`, `z486_makefile`)** | `-march=i386 -O2 -DREG=register` *(Makefile parity)* | **`905.3`** | **`1.521`** | **`0.6573`** / `0.4894` | `25.55%` (`34.31%` groups) | **`0.6287`** | **`25.15`** @ 40 MHz STA (`39.29` @ 62.5 MHz OC*) |
| **Ventium (`c0e3fe43`, `i486_o3_noinline`)** | `-march=i486 -O3 -fno-inline` | **`857.0`** | **`1.352`** | **`0.7398`** / `0.5590` | `24.45%` (`32.36%` groups) | **`0.6641`** | **`26.56`** @ 40 MHz STA (`41.51` @ 62.5 MHz OC*) |
| **Ventium (`c0e3fe43`, `pentium_o3_noinline`)** | `-march=pentium -O3 -fno-inline` *(Weicker rule + P5 sched)* | **`852.0`** | **`1.301`** | **`0.7688`** / `0.5775` | `24.89%` (`33.13%` groups) | **`0.6680`** | **`26.72`** @ 40 MHz STA (`41.75` @ 62.5 MHz OC*) |
| **Ventium (`c0e3fe43`, `i486_o2`)** | `-march=i486 -O2 -DREG=register` | **`805.4`** | **`1.338`** | **`0.7476`** / `0.5588` | `25.25%` (`33.78%` groups) | **`0.7067`** | **`28.27`** @ 40 MHz STA (`44.17` @ 62.5 MHz OC*) |
| **Ventium (`c0e3fe43`, `pentium_o2`)** | `-march=pentium -O2 -DREG=register` *(standard P5 `-O2`)* | **`797.2`** | **`1.290`** | **`0.7753`** / `0.5746` | `25.89%` (`34.94%` groups) | **`0.7139`** | **`28.56`** @ 40 MHz STA (`44.62` @ 62.5 MHz OC*) |

*\*`40.000 MHz` is post-route STA sign-off (`40.264 MHz` closed on `c0e3fe43`); `62.500 MHz` is an empirical single-board runtime MMCM DRP Quake pass and is not STA sign-off above 40 MHz.*

### Key Takeaways

- **Strict Same-Flag Parity (`-march=i386 -O3 -fno-inline`)**: Ventium (`c0e3fe43`)
  achieves **`0.5960 DMIPS/MHz`** (`955.0` cycles/Dhrystone) — **`3.07x` `ao486`**
  (`0.194`) and **`1.81x` `z486`** (`0.330`).
- **Pentium Instruction Scheduling (`-march=pentium`)**: Under Reinhold Weicker's
  no-inlining ground rule (`-O3 -fno-inline`), Ventium reaches **`0.6680 DMIPS/MHz`**
  (`852.0` cycles/Dhrystone, **`3.44x` `ao486`**, **`2.02x` `z486`**); under standard
  `-O2` (`pentium_o2`), Ventium reaches **`0.7139 DMIPS/MHz`** (`797.2`
  cycles/Dhrystone, **`3.68x` `ao486`**, **`2.16x` `z486`**), delivering
  **`28.56 DMIPS` at its `40.0 MHz` STA-signed-off clock** (exceeding `z486` at
  `85 MHz` and `ao486` at `90 MHz`).
- **Additional Diagnostic Controls**:
  - **5,000-iteration convergence (`N_high = 5200`, `ΔN = 5000`)**: `955.0000`
    cycles/Dhrystone (`0.595971 DMIPS/MHz`) on `z486_report`, `852.0000`
    cycles/Dhrystone (`0.668019 DMIPS/MHz`) on `pentium_o3_noinline`, and
    `797.6802` cycles/Dhrystone (`0.713509 DMIPS/MHz`) on `pentium_o2`.
  - **Unbuffered AXI write-stall sensitivity (`AXI_RLAT=5, AXI_WLAT=3` directly
    on write-through L1 without SoC L2/posted-DDR bridge)**: `0.4803 DMIPS/MHz`
    (`z486_report`), `0.4993 DMIPS/MHz` (`pentium_o3_noinline`), and
    `0.5340 DMIPS/MHz` (`pentium_o2`).
  - **Older `experimental/uv-fast-ipc-apr` (`5c630403`, 108-define pre-`c0e3fe43`
    RTL)**: `0.4712 DMIPS/MHz` (`z486_report`), `0.5395 DMIPS/MHz`
    (`pentium_o3_noinline`), and `0.5754 DMIPS/MHz` (`pentium_o2`), showing the
    `+23.8%`–`+26.5%` integer throughput improvement delivered by `c0e3fe43`.

## Reproduction

Build a private `tb_ventium` binary from the `c0e3fe43` source tree into an
external scratch directory (never inside `verif/tb/obj_dir*`), then run:

```sh
export TMPDIR=/home/yukidama/external/tmp

python3 -B -m unittest discover -s verif/bench/dhrystone -p 'test_*.py' -v

python3 -B verif/bench/dhrystone/run_dhrystone.py \
  --binary /home/yukidama/external/tmp/ventium_dhrystone_20261116/obj_c0e3fe43/tb_ventium \
  --out /home/yukidama/external/tmp/ventium_dhrystone_20261116/repro_run \
  --profiles z486_report z486_makefile pentium_o3_noinline pentium_o2 \
  --low-runs 200 --high-runs 2200 --warmup 20 --cpu-pin 2
```
