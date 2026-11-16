# FPGA Build, Deployment & Hardware Qualification Guide

This guide documents the authoritative build, programming, clock-control, telemetry, and hardware-acceptance procedures for **Ventium** on the **RK-XCZU15EG-F** (`xczu15eg-ffvb1156-2-i`) platform using **AMD Vivado 2025.2**.

> **Historical Notice:** Earlier Kria KV260 / PS-assisted `ven_soc` flows, fixed `/32` (`3.125 MHz`) diagnostic clock wrappers, and August–October bring-up failure logs are historical. Always match tools, defines, and expectations to the exact branch and image profile below.

---

## 1. Current Qualification Summary & Mandatory Reporting Rules

### Latest Board-Qualified Baseline: Image `c0e3fe43` (2026-11-14)

Published on **`main`** (`v0.2.0-c0e3fe43`, commit `64e567a6`; see [Release Notes](docs/PUBLIC_FPGA_RELEASE_2026-11-14.md) and [Physical CLB & Congestion Map](docs/FPGA_PHYSICAL_MAP_2026-11-14.md)):

- **Artifact Identity:**
  - Raw PCAP bitstream (`rk_ao486_system.bit.bin`) SHA-256: `c0e3fe43b2b7ce88e013df107be94d56c0fcfcae626ce4c262975fba92dcc3b7`
  - Framed bitstream (`rk_ao486_system.bit`) SHA-256: `091e0fab60650ab890c783e2c63650e9e60770e822cf04334de3a13b3c9738a8`
  - Routed checkpoint (`fresh-routed.dcp`) SHA-256: `2bd41907b5f87343078d47d1a62895129dcf511a804442c5e876cf9d2f9ce44b`
  - Hardware profile: **193 hash-pinned files** (`fpga/known_good_c0e3fe43.json`) and **161 synthesis defines** (`fpga/known_good_defines.txt`, SHA-256 `1d40a25641a10ba87012c9f159e6a50427f3bc188c66f249be80b012a4a7c8dc`), hardwired to **`U/V + system fast-pipe`** (`cycle_mode = 1'b1`).
- **Verified Physical Quake Gameplay IPC:** **`0.515778001` total U+V IPC** (**`0.397847833` primary/U-only IPC**) across interior gameplay cycles **`28,696,827,616–32,989,404,795`** (`2,214,014,744` U+V events, including `506,223,958` paired V-pipe retirements; `+3.88%` over prior release `2886d24c`). Hardware retirement counters include individual `REP` string iterations.
- **Prior Release Baseline (`2886d24c`, 2026-10-17):** `0.496499864` total U+V IPC (`0.383002768` primary/U-only) across cycles `625,021,130,428–629,480,208,865`, completing Quake `demo1` in `125.8 s` (`7.7 FPS`) at measured `39.999826 MHz` ([Oct 17 Quake Report](docs/FPGA_QUAKE_TIMEDEMO_2026-10-17.md), [Oct 17 Doom Report](docs/FPGA_DOOM_2026-10-17.md)).
- **Physical Standard Acceptance Suite (`40.000 MHz` Boot Clock — All 3 Passed):**
  1. **CoreMark (both standard seeds):** `4,000` iterations, full `2 KiB` dataset, all 5 reference CRCs matched on both seeds (`2.100128 / 2.106796 CM/MHz`).
  2. **Windows 95 OSR2 GUI:** Cold boot to clean `640×480` desktop, interactive PS/2 mouse and keyboard session across Calculator (`355/113`), Notepad, and MS Paint, followed by clean OS shutdown ([screenshot](docs/win95-desktop-c0e3fe43.png)).
  3. **DOS Quake `timedemo demo1` + Gameplay:** Cold FreeDOS boot at measured `39.999802 MHz`, **`969` frames in `121.2 s` (`8.0 FPS`)**, zero errors, full `3,075`-frame lossless capture ([capture GIF](docs/quake-timedemo-c0e3fe43.gif)), plus interactive single-player gameplay.
- **Post-Route Static Timing & Utilization Sign-Off (`40.000 MHz` Constraint):**
  - **Core STA:** Closed at **`40.264133 MHz`** (`WNS = +0.164 ns`, `WHS = +0.010 ns`, `0` failing endpoints, `0` DRC/routing errors, `0` final `>=85%` global congestion hotspots).
  - **PS/HP0 AXI4 (`100.000 MHz`):** Closed (`WNS = +5.691 ns`).
  - **Resources (`xczu15eg-ffvb1156-2-i`):** `171,819 / 341,280` CLB LUTs (`50.35%`), `30,703 / 42,660` CLBs (`71.97%`), `39,520 / 682,560` FFs (`5.79%`), `277.5 / 744` BRAM36-eq (`37.30%`), `47 / 3,528` DSP48E2 (`1.33%`).
- **Empirical Single-Board Runtime MMCM DRP Overclocking (Not STA Sign-Off Above 40 MHz):**
  - **`58.824 MHz` (`N = 17`):** Passed cold Windows 95 GUI + shutdown + DOS Quake `demo1` + interactive `E1M1`.
  - **`62.500 MHz` (`N = 16`):** Passed cold DOS boot + Quake `demo1` (`11.6 FPS` wall-clock) + interactive `E1M1` + clean DOS exit (`66.667 MHz` / `N = 15` exceeds physical setup margin on this board).

### Mandatory Reporting & Acceptance Contract (`AGENTS.md`)

1. **Always state verified gameplay IPC, image ID, and cycle window.** Explicitly report whether a candidate checkout or rebuild is **unmeasured** and label `0.515778001` (`c0e3fe43`) as the prior verified baseline. Post-freeze working RTL on `experimental/uv-fast-ipc-apr` is unmeasured on physical gameplay unless separately board-qualified.
2. **Never substitute non-gameplay metrics.** BIOS POST, OS boot, CoreMark, microbenchmarks, simulator windows, or design targets never substitute for physical interior Quake gameplay IPC.
3. **Separate `total U+V` from `primary/U-only` counters** and note that hardware retirement counters include per-element `REP` string iterations.
4. **Require `U/V + system fast-pipe` (`cycle_mode=1`).** Runs using U-only issue, slow-FSM fallbacks, single-stepping (`STEP`), intended-V breakpoints, guest-memory patches, or forced cache flushes are diagnostic controls only—never acceptance passes.

---

## 2. Branch Boundary & Public Fresh-Source Build (`main`)

The repository maintains a strict separation between the reproducible hardware release and ongoing core/APR experiments:

- **`main` (`v0.2.0-c0e3fe43`, commit `64e567a6` — [github.com/AL-255/ventium/releases](https://github.com/AL-255/ventium/releases)):** Publishes the official self-contained, hash-pinned source closure (`fpga/known_good_c0e3fe43.json`) and portable fresh-source Vivado 2025.2 builder (`fpga/build_known_good.py`). **No private `ventium-refs` submodule or prebuilt DCP is required.**
- **`experimental/uv-fast-ipc-apr`:** Retains active core/cache/FPU/APR development and the full Verilator + pinned-QEMU differential harness. Do not overwrite its working RTL with the release snapshot, and never alter hash pins on `main` to bless unqualified experimental inputs.

### Running the Public Source Preflight & Fresh Vivado Build on `main`

From a clean checkout of `main`:

```bash
# 1. Verify all 193 pinned files, ordered .f filelists, and 161 hardware defines (no Vivado needed):
python3 -B fpga/build_known_good.py --check
tclsh fpga/test_known_good_wrapper.tcl "$PWD"
python3 -B -m unittest discover -s fpga -p test_known_good.py -v

# 2. Launch an authorized fresh source-only Vivado 2025.2 build into external scratch:
python3 -B fpga/build_known_good.py --build \
  --vivado-root /opt/AMD/2025.2/Vivado \
  --output /home/yukidama/external/tmp/ventium-c0e3fe43-fresh \
  --threads 8
```

`fpga/build_known_good.py --build` invokes `fpga/run_vivado_exclusive.sh` with the exact `retime_muxf_route_first` recipe (`Synth_design -directive PerformanceOptimized -retiming`, `opt_design -muxf_remap`, `place_design -directive AltSpreadLogic_high`, and `route_design -directive AlternateCLBRouting`) at `40.000 MHz` core / `100.000 MHz` PS-AXI.

**Sign-off verification on any fresh build:** A fresh Vivado run is not guaranteed to be bit-identical to the reference binary and does not inherit qualification automatically. Before board deployment, inspect the generated reports under `rk_ao486_system/rk_ao486_system.runs/impl_1/`:

- `rk_ao486_bd_wrapper_timing_summary_postroute_physopted.rpt`: require `WNS >= 0.000 ns`, `TNS = 0.000 ns`, `WHS >= 0.000 ns`, `THS = 0.000 ns`, and `0` failing endpoints across both `40 MHz` core and `100 MHz` HP0/PS domains.
- `rk_ao486_bd_wrapper_drc_routed.rpt` and route status: require `100%` routed nets, `0` overlaps, and `0` DRC Errors or Critical Warnings.
- Verify `rk_ao486_system.bit.bin` contains the Xilinx sync word `aa 99 55 66` at byte offset `0x50` (never run `bit2bin.sh` twice or byte-swap the raw `.bit.bin`).

---

## 3. Experimental Branch Vivado Flow (`experimental/uv-fast-ipc-apr`)

### Pre-Hardware Differential Verification

Hardware is the final verification gate, not a substitute for architectural lockstep. Before synthesizing RTL changes on `experimental/uv-fast-ipc-apr`, run the Verilator + pinned-QEMU (`ventium-refs/`) gates:

```bash
make verify          # functional differentials + M4/M5 cycle bands (mandatory after RTL edits)
make verify-sys      # system-mode protected / paged / V86 / x87 corpus
make l1              # L1 cache & TLB subsystem gates
make bus bus-sva     # P5 bus protocol & SVA assertions
make lint            # Verilator structural lint (IMPLICIT/PINMISSING/UNDRIVEN/MULTIDRIVEN/LATCH/UNOPTFLAT fatal)
make verify-all      # full regression umbrella (report PASS and pinned expected failures separately)
```

RTL filelists (`rtl_ven_core.f`, `rtl_ven_soc.f`) are strictly ordered—never use wildcard globs, and never revive `VEN_CACHE_HALF` or narrow-I-cache flags.

### Exclusive Single-Family Vivado Guard & Scratch Rules

1. **One Vivado family at a time (`fpga/run_vivado_exclusive.sh`):** Never run `vivado -mode batch` directly. `fpga/run_vivado_exclusive.sh` acquires a host lock, stops any prior `ventium-vivado.scope` systemd cgroup (`KillMode=control-group`), and terminates lingering same-user `vivado`/`vrs` descendants from the target installation before launching (`VEN_FPGA_JOBS=1`). **Always check process ownership first** so you do not kill an active build in progress.
2. **Scratch directory discipline:** On the maintainer host, place all build directories and `TMPDIR` under `/home/yukidama/external/tmp` after verifying mount status, writability, and free disk space. Never fall back to `/` or create scratch directories in `$HOME`, and never follow symlinks into `/home/yukidama/external/ventium_run` when pruning disposable build outputs.
3. **Memory policy:** Uncapped Vivado RAM/swap (`VENTIUM_VIVADO_MEMORY_POLICY=unbounded` / `--memory-profile unbounded`) is permitted on the maintainer host; retain task/runtime/disk bounds and monitor for real OOM or tool errors rather than aborting on swap usage alone.

### Fresh-Source Experimental APR (`fpga/run_fresh_strategy.py`)

Isolated source-only APR trials on `experimental/uv-fast-ipc-apr` use `fpga/run_fresh_strategy.py`, which copies a verified source closure (rejecting symlinks and prebuilt `.dcp`/`.bit`/`.xpr` artifacts) into a fresh `/home/yukidama/external/tmp/<leaf>` directory and runs synthesis + implementation + post-route audits:

```bash
TMPDIR=/home/yukidama/external/tmp \
  python3 -B fpga/run_fresh_strategy.py \
  --strategy performance-retime-muxf-route-first \
  --memory-profile unbounded \
  --output /home/yukidama/external/tmp/ventium-apr-trial-$(date +%Y%m%d-%H%M%S)
```

> **Current Experimental APR Status (`experimental/uv-fast-ipc-apr` HEAD `5c630403`):** On the heavier post-freeze experimental RTL tree (`~186k–202k` LUTs prior to `c0e3fe43`'s front-end fanout/mux cleanup), isolated fresh-source APR exploration concluded at the accepted legal **`35.736 MHz`** MUXF route (`a8e5d6bf` / `5c630403`). Reaching `>=40 MHz` STA sign-off on future experimental candidates requires preserving `c0e3fe43`'s front-end congestion reductions alongside any new RTL changes.

---

## 4. RK-XCZU15EG-F Host Requirements, DDR4 Reservation & Programming

### SoC Interconnect & Memory Architecture

```text
ZynqMP ARM Cortex-A53 PS (Linux 6.12 AArch64)
  ├── M_AXI_HPM0_FPD ──► 64 KiB AXI-Lite Control / Debug / PMU @ 0xA000_0000 (0x10-aligned regs)
  ├── zynqmp_gpio    ──► EMIO Mailbox ──► ven_pll_ctrl (100 MHz ref, MMCME4_ADV XAPP888 DRP)
  └── S_AXI_HP0_FPD  ◄── 128-bit @ 100 MHz (dwc_mem + acc_mem CDC)
                           ▲
                           └── ven_ddram_axi_posted (16-slot posted write queue + CAM RAW bypass)
                                 ▲
                                 └── MiSTer PC/AT + ven_ao486_shim + Ventium P5/P54C Core
                                     Guest Physical RAM Aperture: 0x6000_0000–0x6FFF_FFFF (256 MiB)
```

### Mandatory `no-map` DDR4 Reservation Preflight

Before mapping `/dev/mem` or starting `ao486d`, **prove on every board boot** that `[0x6000_0000, 0x7000_0000)` (all 256 MiB of guest DDR4) is excluded from Linux System RAM via a boot-time `no-map` reserved-memory node—**never** `cma=512M` (CMA permits movable kernel/page-cache allocations that PL DMA/writes will corrupt):

```bash
# Run as root on the RK-XCZU15EG-F PS:
cat /sys/class/fpga_manager/fpga0/state          # must be 'operating' BEFORE any 0xA000_0000 access
ls -d /proc/device-tree/reserved-memory/*        # verify covering node has 'no-map' and no reusable pool
grep -E '60000000|System RAM' /proc/iomem        # root-only unmasked check: zero overlap with System RAM
```

> **Warning:** Accessing `0xA000_0000` over `/dev/mem` when `/sys/class/fpga_manager/fpga0/state` is not `operating` stalls the PS AXI interconnect and drops the board off the network.

### Programming the PL & External DDR-Drain Lifecycle

1. **Quiesce any prior guest:** Stop any running `ao486d`/watcher service by verified systemd `InvocationID` and `MainPID` (`fpga/board-tools/COLD_LIFECYCLE.md`, `ven_cold_owners.py`), hold guest reset (`CTRL = 0x1` at `0xA000_0020`), and confirm external posted-DDR drain before reprogramming or zeroing RAM.
2. **Program via FPGA Manager / PCAP:** Copy `rk_ao486_system.bit.bin`, verify its `sha256sum` on-board, and load via `fpgautil` or the board wrapper:
   ```bash
   sudo fpgautil -b /tmp/ao486/rk_ao486_system.bit.bin
   # (or: sudo /usr/local/bin/load-bitstream.sh /tmp/ao486/rk_ao486_system.bit.bin)
   cat /sys/class/fpga_manager/fpga0/state        # require 'operating'
   ```
3. **External Posted-DDR Drain Barrier (`ven_ddram_axi_posted`):** Posted write acceptance is **not** external DDR4 completion. Both hardware (`ven_ao486_shim`) and cold-startup software (`fpga/board-tools/ven_posted_reset_guard.h`) enforce the external drain barrier across port I/O, quiescent `HALT`, `STEP`, cold RAM zeroing, and MMCM clock switches. Before initializing RAM on a posted-DDR image, require `CTRL = 0x1` (reset held) and two consecutive reads of scan selector `79` returning **`0x50440003`** (`fault=0, capability=1, drained=1`) separated by `>= 1 ms`.
4. **BIOS Cache Enable (`CR0.CD/NW`):** Ventium honors architectural `CR0.CD` and `CR0.NW` reset bits (`1`), whereas stock ao486 `boot0.rom` leaves them set. Use `python3 tools/patch_boot0_cache_enable.py 3rd-party/ao486_MiSTer/releases/boot0.rom /tmp/boot0.rom` (expected SHA-256 `dca915c5483793a710ee118c5232aad01ef3191bea7d50c2befb1a47d2dd26a3`) so POST executes `WBINVD` and clears `CR0.CD/NW` cleanly without RTL hacks.

---

## 5. Runtime MMCM DRP Clock Control (`ven_pll_ctrl`)

Programmable-clock images (`c0e3fe43`, `2886d24c`) synthesize a single `MMCME4_ADV` driven by the fixed `100.000 MHz` PS reference clock (`VCO = 100 MHz * 10 = 1000 MHz`, output `F_core = 1000 / N MHz` for integer `N in 10..50`, boot default **`N = 25` → `40.000 MHz`**).

`fpga/ven_pll_ctrl.sv` executes the AMD XAPP888 DRP reconfiguration state machine from the always-on `100 MHz` domain and communicates with the PS through an isolated EMIO GPIO mailbox (`/dev/gpiochip1`, `zynqmp_gpio`, ABI1 header `0x504c`), leaving `100 MHz` HP0/AXI-Lite timing untouched and requiring **zero PCAP reloads**.

### Switching & Verifying Core Clocks Safely

 Hardware refuses any clock switch unless guest reset is held and the 16-slot posted DDR4 bridge is completely drained (`safe = 1`, `busy = 0`). Always use `fpga/board-tools/ven_pll_clock.py` and `ven_cold_clock.py`:

```bash
# 1. Verify held-reset boot clock admission (requires ABI 5, held reset, CR0 reset, 0 retirements, 39.5-40.5 MHz):
sudo python3 -B /tmp/ao486/ven_cold_clock.py

# 2. Inspect current MMCM DRP mailbox status (read-only; e.g. raw=504c5499 -> divider=25, locked, safe):
sudo python3 -B /tmp/ao486/ven_pll_clock.py --status

# 3. Empirical single-board runtime DRP switch (ONLY while guest reset is held and DDR is drained):
sudo python3 -B /tmp/ao486/ven_pll_clock.py --divider 17   # 1000 / 17 = 58.824 MHz (Win95 + Quake empirical pass)
sudo python3 -B /tmp/ao486/ven_pll_clock.py --divider 16   # 1000 / 16 = 62.500 MHz (DOS Quake empirical pass)

# 4. Always restore the 40.000 MHz STA-signed-off baseline after overclock experiments:
sudo python3 -B /tmp/ao486/ven_pll_clock.py --divider 25   # 1000 / 25 = 40.000 MHz
```

| Divider `N` | Nominal Core Clock | Qualification Tier on `c0e3fe43` | Notes |
| :---: | :---: | --- | --- |
| **`25`** | **`40.000 MHz`** | **Post-route STA signed off (`40.264 MHz`) + Full Suite PASS** | Default boot clock; mandatory baseline for standard qualification |
| `17` | `58.824 MHz` | Empirical single-board silicon pass (not STA sign-off) | Cold Win95 GUI + shutdown + Quake `demo1` + interactive `E1M1` |
| `16` | `62.500 MHz` | Empirical single-board silicon pass (not STA sign-off) | Cold DOS Quake `demo1` (`11.6 FPS`) + `E1M1` + clean exit |
| `15` | `66.667 MHz` | Exceeds single-board setup margin | Fails setup margin; recover cleanly via `--divider 25` |

---

## 6. Board Tools, Telemetry (`0xA000_0000`) & Standard Acceptance Suite

### `0xA000_0000` AXI-Lite Control, PMU & Debug Register Map

All 32-bit registers sit on `0x10` byte boundaries inside the 64 KiB `0xA000_0000` aperture:

| Offset / Selector | Direction | Function & Acceptance Semantics |
| --- | :---: | --- |
| `0x000` | R | `IDENT` — must read `0xA0486501` when PL is `operating` |
| `0x010`, `0x030`, `0x040` | R/W | MiSTer PS management bus address (`0x010`), write data/pulse (`0x030`), read data (`0x040`) |
| `0x020` (`CTRL`) | R/W | `[0]` hold guest reset, `[1]` run enable, `[8]` PS IDE/FDD request-notify enable (not PIC `INTR` mask) |
| `0x050`, `0x060`, `0x070` | R | IDE/FDD/core status (`0x050`), DDR/AXI bridge counters (`0x060`), last accepted AR address (`0x070`) |
| `0x080`–`0x0e0` | R/W | Last retired EIP (`0x080`), freeze status/threshold (`0x090`), comparator config/range (`0x0a0`/`0x0b0`), 128-entry PC & aux rings |
| `0x100` / `0x110` | R | 64-bit core cycle counter (`perf_cyc` low/high; runs continuously on `clk_sys` even while reset is held) |
| `0x120` / `0x130` | R | 64-bit **primary/U-only** retirement counter (`perf_retired` low/high; excludes paired V-pipe retirements) |
| `0x150`, `0x160` | R | External `INTA` count (`0x150`) and live architectural `CR0` (`0x160`) |
| `0x170`–`0x1b0` | R | AXI R beats (`0x170`), AR handshakes (`0x180`), B responses (`0x190`), AR-to-RLAST occupancy (`0x1a0`), AR-to-first-R latency (`0x1b0`) |
| `0x200`–`0x270` | R | Sticky forensic-freeze frame (`0x200 == 0x56440001`: `{CS, EIP, ESP, EFLAGS, fault_PC, CR0, state, vector}`) |
| `0x280`–`0x2c0` | R/W | Quiescent debugger (`0x2c0 == 0x56450005` ABI 5): halt/BP/step (`0x280`), 32-bit EIP BP (`0x290`), scan selector (`0x2a0`), scan data (`0x2b0`) |
| **Scan `0..75`** | R (halted) | GPRs, EIP, EFLAGS, segment/GDT/IDT/LDTR/TR hidden caches, `CR0..CR4`, `DR0..DR7`, 80-bit x87 stack + environment, stop cause |
| **Scan `76..78`** | **R (live)** | **64-bit total U+V retirement counter** (`76` low, `77` high) + capability `0x55563634` (`"UV64"` at `78`); safe to sample live |
| **Scan `79`** | **R (live)** | **Posted-DDR4 drain status:** `0x50440000 \| {fault, capability, drained}` (`0x50440003` = healthy & fully drained) |
| `0x3a0`+ | R/W | Hardware PS/2 keyboard (`0x564b0001`) & PS/2 mouse Set-2/stream injection mailboxes + 128-RAMB36 RGB332 passive VGA capture |

### Key `fpga/board-tools/` Utilities

- **`ven_board_probe.py`:** Primary MMIO inspection/control tool (`prepare-cold`, `perf`, `vga-capture --frames 1` or `--stream --stop-on-sigusr1`, `ps2-keys`, `quake --precheck-only`, `dump-state`, `dump-ring`).
- **`ven_ps2_mouse.py` / `ven_ps2_service.py` / `ven_ps2_mailbox_host.py`:** Hardware PS/2 mouse packet and keyboard event delivery over the 8042 peripheral pins (never BDA RAM injection).
- **`ven_total_retire.py`, `ven_ipc_window.py`, `ven_quake_ipc.py`:** Exclusive-selector `UV64` total U+V retirement reader (with high/low/high rollover protection), bracketed cycle-window IPC bound calculator, and passive DOS Quake 1.06 interior-frame (`33..900`) clock-weighted IPC accumulator.
- **`ven_record_stream.py` & `ven_encode_recording.py`:** Host-side lossless gzipped RGB332 stream collector and bit-exact `libx264rgb` `320×200 @ 15 fps` MP4 encoder/verifier.
- **`ven_uv_fast_guard.py`:** Verifies ABI-5 running state (no `STEP`/HALT/BP/freeze) and proves genuine `S_PIPE` paired U+V execution in post-run ring captures.

### Executing the Three-Gate Physical Standard Acceptance Suite

Every candidate targeting FPGA acceptance must pass **all three** workloads on physical hardware at the STA-signed-off `40.000 MHz` (`N = 25`) clock in `U/V + fast-pipe` mode (`cycle_mode = 1'b1`), using private writable copies of pristine disk media and retaining full hashes and logs:

1. **Gate 1 — CoreMark (Both Standard Seeds):**
   Run both standard 4,000-iteration performance and validation seeds (`ven_coremark_clock_trial.py`). Require measured `~40.000 MHz` clock, all 5 reference CRCs matched on both seeds, native exit `0`, and verified positive V-pipe retirement deltas (`total U+V - primary/U > 400M`).
2. **Gate 2 — Cold Windows 95 OSR2 Desktop, GUI Interaction & Clean Shutdown:**
   Clone the pristine sparse 2 GiB VHD with `rsync -S --inplace` (never `scp`, which expands sparse holes). Cold-boot under `ao486d --membase 0x60000000 --bios /tmp/ao486 --hdd <writable_w95.vhd>` with zero memory/BDA patches or forced cache flushes. Capture `640×480` frames via `ven_board_probe.py vga-capture`, exercise live PS/2 mouse and keyboard interaction across Calculator, Notepad, and MS Paint, and complete a clean Start-menu OS shutdown.
3. **Gate 3 — Cold DOS Quake `timedemo demo1` + Interior Gameplay IPC:**
   Verify the clean writable Quake VHD (`ven_board_probe.py quake --disk <run.vhd> --precheck-only`), start `ven_record_stream.py` on the host, cold-boot FreeDOS/CWSDPMI/Quake (`+timedemo demo1`), and sample interior frames `33..900` passively with `ven_quake_ipc.py`. Wait for natural `ao486d` exit (`MainPID=0`, `ExecMainStatus=0`) before sending `SIGUSR1` to close video capture. Verify the closed FAT16 `QCONSOLE.LOG` records **`969 frames`** with zero faults, verify paired `S_PIPE` retirement with `ven_uv_fast_guard.py`, and report both clock-weighted **`total U+V` IPC** and **`primary/U-only` IPC** with their exact cycle window.

---

## 7. Quick Troubleshooting & Hardware Provenance Checklist

| Symptom | First Diagnostic Checks |
| --- | --- |
| `fpga0/state` is not `operating` | Verify raw `.bit.bin` (sync word `aa 99 55 66` at `0x50`), part `xczu15eg-ffvb1156-2-i`, and `fpgautil` / `dmesg` output before any MMIO read. |
| PS hangs on `0xA000_0000` access | `fpga0/state` was not `operating`, or MMCM/AXI reset held `S_AXI_HPM0_FPD`; power-cycle/reboot and check `fpga0/state` first. |
| `IDENT` mismatch or `UV64` absent | Bitstream on PL does not match expected `.bit.bin` SHA-256 or tool ABI (`0x2c0 == 0x56450005`, scan `78 == 0x55563634`). |
| `ven_pll_clock.py` refuses switch | Guest is still running (`CTRL != 0x1`), posted DDR4 has not drained (`scan 79 != 0x50440003`), or divider `N` is outside `10..50`. |
| Extremely low IPC (`~0.01–0.05`) | Inspect live `CR0` (`0x160`): `CR0.CD/NW` (`0x60000000`) remained set because stock `boot0.rom` was used instead of the cache-enable ROM. |
| Corrupt guest RAM / Linux OOPs | Boot-time `0x6000_0000–0x6FFF_FFFF` `no-map` reservation is missing or replaced by `cma=`; inspect root `/proc/iomem` immediately. |

### Mandatory Evidence Bundle for Hardware Qualification Reports

Every hardware qualification report must record:
1. Exact branch, commit SHA, dirty `git diff` (if any), ordered `.f` hashes, and full define list (`cycle_mode=1`).
2. Vivado version (`2025.2`), post-route `WNS`/`TNS`/`WHS`/`THS`, failing-endpoint count, DRC summary, CLB/LUT/FF/BRAM/DSP utilization, and global routing congestion hotspot count.
3. SHA-256 digests of `.bit`, `.bit.bin`, `ao486d`, BIOS ROMs, and pristine input VHDs.
4. Measured core frequency (`perf_cyc` delta over host monotonic interval) + `ven_pll_ctrl` status word.
5. Complete Standard Suite logs/captures, paired V-pipe retirement proof, and interior Quake gameplay **`total U+V` IPC** and **`primary/U-only` IPC** with exact cycle bounds.
