# Build and Run the Board-Qualified Ventium FPGA Profile (`c0e3fe43`)

This `main` source release publishes the complete hardware source closure and fresh-build recipe for FPGA image **`c0e3fe43`**, built with **Vivado 2025.2** and physically qualified on **RK-XCZU15EG-F** (`xczu15eg-ffvb1156-2-i`) on **2026-11-14**. Ongoing unqualified CPU/cache/APR development remains on **`experimental/uv-fast-ipc-apr`**; do not substitute experimental RTL into this release profile.

## What Is Reproducible

The repository contains the exact frozen P5/P54C core, shared pipelined x87 FPU, L1 caches/TLBs, patched `ao486` PC/AT peripherals, PL top-level wrapper, 16-slot RAW-bypass posted DDR4 bridge, MMCM DRP clock controller, XDC constraints, ordered `.f` filelists, post-`opt_design` MUXF remap hook (`fpga/fresh_opt_muxf_post.tcl`), and **161 hardware defines**.

`fpga/known_good_c0e3fe43.json` SHA-256 pins all **193 input files**. Building requires **no private submodule**, guest disk image, pre-existing `.dcp` checkpoint, Vivado IP cache, external `ao486` checkout, or maintainer home-directory paths.

Unlike the earlier `2886d24c` release (which relied on incremental placement reuse and had `-9.841 ns` setup slack), **`c0e3fe43` was built entirely from fresh sources** using the `retime_muxf_route_first` Vivado 2025.2 strategy (`PerformanceOptimized` synthesis with `GLOBAL_RETIMING on`, `RuntimeOptimized` `opt_design` followed by explicit `opt_design -muxf_remap`, `AltSpreadLogic_high` placement, and `AlternateCLBRouting`), achieving **true 40 MHz post-route static timing closure** (`40.264133 MHz`, `WNS = +0.164 ns`, `WHS = +0.010 ns`, `0` failing endpoints, `0` DRC/routing errors). Because Vivado multi-threading and host environments can still introduce small non-determinism across machines, any newly built bitstream should still have its own `timing_summary.rpt`, `route_status.rpt`, and physical board behavior verified before claiming hardware acceptance.

## Prerequisites

- Linux x86-64 with Bash, Python 3.11+, Tcl (`tclsh`), coreutils, `flock`, and an active `systemd --user` manager (cgroup v2).
- AMD Vivado **2025.2** with Zynq UltraScale+ device support and license for **`xczu15eg-ffvb1156-2-i`**.
- Sufficient RAM/swap and scratch disk: the qualified `c0e3fe43` build (`--threads 8`) peaked at ~`14.6 GiB` resident RAM + ~`19.2 GiB` swap and completed in ~`2h 48m`. Provide at least **16 GiB** free scratch space (`build_known_good.py` refuses `< 8 GiB` free). On lower-memory hosts, pass `--threads 2` or `--threads 1` to reduce concurrent worker footprint.

## Clean Clone and Offline Source Preflight

```bash
git clone https://github.com/AL-255/ventium.git
cd ventium
python3 -B fpga/build_known_good.py --check
tclsh fpga/test_known_good_wrapper.tcl "$PWD"
python3 -B -m unittest discover -s fpga -p test_known_good.py -v
```

Do **not** pass `--recursive` for the public FPGA build: `ventium-refs` is a private differential-verification oracle submodule and is not needed for synthesis or board tooling. The exact patched `ao486` peripheral RTL is already vendored under `3rd-party/ao486_MiSTer/` with its licenses.

## Build One Fresh 40 MHz Programmable-Clock Image

Choose a new output directory **outside** the repository checkout on a scratch volume with ample free space (`TMPDIR` is automatically placed inside `<output>/tmp`):

```bash
python3 -B fpga/build_known_good.py --build \
  --vivado-root /opt/AMD/2025.2/Vivado \
  --output /path/to/scratch/ventium-c0e3fe43-build
```

Optional concurrency flag: `--threads {1,2,8}` (default `8`, matching the qualified `c0e3fe43` build). Synthesis/implementation run fan-out (`-jobs 1`) stays strictly single-run, IP checkpoint caching (`IP_CACHE_PERMISSIONS disable`) and incremental checkpoints (`AUTO_INCREMENTAL_CHECKPOINT 0`) are disabled, and mandatory `U/V + system fast-pipe` (`cycle_mode=1'b1`) plus the 16-slot posted-DDR completion barrier are verified before synthesis launches.

**Exclusive Vivado Process Rule:** `fpga/run_vivado_exclusive.sh` enforces a single Vivado process family per host user: launching a new build terminates any previous `ventium-vivado.scope` and same-user Vivado/VRS workers from that installation. Never launch a build alongside another active Vivado job you want to keep. A hard 8-hour timeout bounds the run; retain `started.json`, `closed.json`, and `native.log`.

Expected build products under `<output>/build/`:

```text
rk_ao486_system.bit
rk_ao486_system.bit.bin
fresh-routed.dcp
{clocks,route_status,timing_summary,utilization,utilization_hierarchy,congestion,cdc,drc,mmcm}.rpt
```

Audit `closed.json`, `route_status.rpt` (`0` unrouted/error nets), `drc.rpt` (`0` errors), `clocks.rpt` (`40.000 MHz` core / `100.000 MHz` PL/HP0), and `timing_summary.rpt` (`WNS >= 0`, `WHS >= 0`) before programming hardware.

## Board Preparation and Safe Deployment

The generated bitstream targets **PL-only PCAP** loading on a running ZynqMP Linux system that has already initialized PS DDR4, MIO, and the `100 MHz` `pl_clk0` reference (see [RK-XCZU15EG-F-Template](https://github.com/AL-255/RK-XCZU15EG-F-Template)). No credentials, SD-card images, or guest OS disks are included here.

1. **Reserve Guest DDR4 (`no-map`):** Ensure physical RAM **`0x60000000–0x6fffffff`** (`256 MiB`) is reserved via a Linux device-tree `reserved-memory` **`no-map`** node before booting Linux, and verify `/proc/iomem` / `/sys/firmware/devicetree` before starting any `/dev/mem` guest daemon.
2. **Quiesce & Drain Before Programming:** Stop any running guest daemon, assert guest reset, and verify the posted-DDR bridge reports `drained=1, fault=0` before loading `rk_ao486_system.bit.bin` through Linux `fpga_manager`.
3. **Debug & Runtime DRP Clock Utilities (`fpga/board-tools/`):**
   - Management/debug MMIO resides at **`0xA0000000`**.
   - `ven_pll_ctrl` operates on the always-on `100 MHz` reference over ZynqMP EMIO GPIO (`ven_pll_clock.py`). Runtime divider changes (`1000 MHz / N`, boot `N = 25` -> `40.000 MHz`) require guest reset asserted + posted DDR drained + zero DDR fault for 32 reference clocks. Keep `pl_clk0` fixed at `100 MHz`.

## Physical Acceptance Summary (`c0e3fe43`)

Reference image **`c0e3fe43`** (`rk_ao486_system.bit.bin` SHA-256 `c0e3fe43b2b7ce88e013df107be94d56c0fcfcae626ce4c262975fba92dcc3b7`) passed the complete three-part physical standard acceptance suite in `U/V + fast-pipe` mode:

1. **CoreMark:** Both standard 4,000-iteration seeds pass with exact reference CRCs (`2.100128 / 2.106796 CM/MHz` at `40.000 MHz`).
2. **Windows 95:** Cold boot to desktop, interactive PS/2 mouse & keyboard multi-application GUI session (`Calculator`, `Notepad`, `MS Paint`), and clean OS shutdown (`40.000 MHz` and warm-die `58.824 MHz`).
3. **DOS Quake:** Complete `timedemo demo1` (`969` frames in `121.2 s` = **`8.0 FPS`** at `39.999802 MHz`) plus interactive `E1M1` gameplay (`40.000 MHz`, `58.824 MHz`, and `62.500 MHz`).

Current verified physical Quake gameplay IPC: **`0.515778001` total U+V IPC** (`0.397847833` primary/U-only IPC), image **`c0e3fe43`**, cycles **`28,696,827,616–32,989,404,795`** (counters include `REP`-element retirement; prior `2886d24c` baseline was `0.496499864` / `0.383002768`). Freshly compiled rebuilds remain unmeasured until independently validated on hardware.
