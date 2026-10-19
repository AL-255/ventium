# Build the board-tested Ventium FPGA profile

This public `main` source release corresponds to the processor in FPGA image
**`2886d24c`**, tested on RK-XCZU15EG-F on 2026-10-17. Experimental CPU/cache
development stays on **`experimental/uv-fast-ipc-apr`**. Do not substitute that
branch's RTL and call the result this image.

## What is reproducible

The repository contains the frozen core/FPU/cache RTL, patched ao486 peripherals,
PL top, AXI/DDR bridges, clock controller, constraints, ordered filelists and
exact **159 hardware defines**. `fpga/known_good_2886d24c.json` hashes the input
closure. The FPGA build requires **no private submodule**, guest disk, previous
checkpoint, external ao486 checkout or developer home-directory tree.

The deployed image was produced by an incremental physical-layout reuse followed
by a clock-only repair. Its original routed checkpoint and bitstream are **not
in Git**. The public recipe performs fresh synthesis/place/route using the same
processor sources and repaired clock logic. It does **not** promise identical
placement, timing, build duration or a byte-identical bitstream. The full-width
clock wrapper is used for source synthesis; the deployed ECO used its narrowed
post-synthesis port adapter. CPU/cache sources and defines are unchanged.

The portable recipe has source/hash, Tcl-expansion and host-unit checks. It has
not been rerun through full Vivado or requalified on the board as part of this
publication: the owner cancelled FPGA builds before moving computers. This is
publication of the tested source profile, **not a new FPGA acceptance result**.

## Prerequisites

- Linux x86-64 with Bash, Python 3.11+, Tcl, coreutils, `flock`, and a working
  systemd user manager/cgroup v2.
- AMD Vivado **2025.2**, Zynq UltraScale+ support, and a license for
  **`xczu15eg-ffvb1156-2-i`**. AMD tools/IP are supplied by your installation,
  not redistributed here.
- Substantial RAM/swap and scratch disk. Recent runs used about 20 GiB resident
  RAM plus swap; allow at least 16 GiB free disk as a practical starting point.
  The entry point rejects less than 8 GiB free. RAM/swap are not artificially
  capped; a build can still exhaust a machine. Monitor available disk/resources.

## Clean clone and source preflight

```bash
git clone https://github.com/AL-255/ventium.git
cd ventium
python3 -B fpga/build_known_good.py --check
tclsh fpga/test_known_good_wrapper.tcl "$PWD"
python3 -B -m unittest discover -s fpga -p test_known_good.py -v
```

Do **not** use `--recursive` for this public FPGA build. `ventium-refs` is a
private verification oracle and is unnecessary here. The exact patched ao486
RTL used by this profile is vendored with its license; do not replace it by an
unpatched upstream checkout. Historical verification targets may need that
private oracle and are separate from FPGA source preflight.

## Build one 40 MHz image

Choose paths on your own machine. The output leaf must not exist and must be
outside the checkout. `TMPDIR` is explicitly set by the builder beneath it.

```bash
python3 -B fpga/build_known_good.py --build \
  --vivado-root /opt/AMD/2025.2/Vivado \
  --output /path/to/scratch/ventium-2886d24c-build
```

The launcher sources that installation's `settings64.sh`; there is no mandatory
`/home/yukidama` or `/tools` installation path. It uses one synthesis worker,
40 MHz core / 100 MHz PS reference and HP0 AXI, the full P5 split 8 KiB L1s,
shared pipelined x87, U/V issue (`cycle_mode=1`) and system fast load/store paths.
The historical `logic_only` synthesis option disables synthesis timing-driven
optimization, **not timing analysis or the 25 ns/10 ns constraints**.

**Exclusive launch warning:** `fpga/run_vivado_exclusive.sh` stops the previous
Ventium scope and other same-user Vivado/VRS processes under the selected vendor
installation before starting. Do not run it alongside an unrelated Vivado job.
The complete invocation has an eight-hour timeout; there are no automatic
retries, clock-specific builds or board writes. Stop it deliberately if disk is
running out. Keep `started.json`, `closed.json` and `native.log`.

Outputs, after successful completion:

```text
build/rk_ao486_system.bit
build/rk_ao486_system.bit.bin
build/{clocks,route_status,timing_summary,utilization,drc,mmcm}.rpt
```

Check native exit and completion marker, unchanged source hashes, complete
routing, DRC, clock periods, setup/hold, timing coverage and CDC. Do not call
bitgen success timing sign-off. The tested original had **−9.841 ns setup** at
40 MHz: **28.701817 MHz conditional post-route period budget**, despite physical
40 MHz workload passes. A new placement has no inherited hardware qualification.

## Board preparation and deployment boundary

The flow is **PL-only PCAP**, assuming Linux/FSBL already initialized PS DDR/MIO
and provides the 100 MHz PS reference. It deliberately skips the board preset;
it is not an SD-card image, FSBL or standalone boot firmware generator. Use the
[RK board template](https://github.com/AL-255/RK-XCZU15EG-F-Template) for Linux/BSP
setup. No login credentials are supplied in this repository.

Before programming, stop the guest daemon, hold guest reset and verify the
posted DDR bridge is drained. Reserve guest physical RAM **0x60000000–0x6fffffff**
with a device-tree `reserved-memory` **`no-map`** region before Linux boots;
confirm the active reservation. Never let `/dev/mem` guest writes overlap Linux
RAM. Record the new bitstream SHA256 and board boot identity. Follow your Linux
FPGA-manager driver's raw-bitstream loading procedure; don't blindly copy an
old machine's deployment paths or permissions.

The board debug window is at **0xA0000000**. The included Python helpers under
`fpga/board-tools/` support register inspection, clock measurement and the
programmable PLL. Run `--help` and check the debug ABI before register writes.
Changing the PLL requires held guest reset, the actual external DDR drain,
no DDR fault, and stable lock. Keep the 100 MHz reference/AXI clock unchanged.
The core's boot divider is 25 (40 MHz); overclock qualification is workload-
and image-specific, not a general guarantee.

Guest boot additionally requires a matching PS-side disk/BIOS/input service,
properly licensed BIOS/media and operating-system configuration. Guest images,
Windows files, Quake data, captures, checkpoints and proprietary documentation
are intentionally not included. This source release guarantees neither a
ready-to-boot SD card nor that historical absolute runtime paths exist.

## Acceptance

For a new physical implementation, use U/V + fast-pipe (no STEP/breakpoint that
suppresses pairing), demonstrate fresh V retirement, and retain logs/captures,
source/image hashes and the measured core clock. The standard suite is:

1. Both standard CoreMark seeds complete with correct data CRCs.
2. Windows 95 cold-boots to a clean desktop and keyboard/mouse interaction works.
3. Original FreeDOS/DOS Quake completes the full timedemo without error.

The original `2886d24c` has both CoreMark seeds and a complete Quake timedemo
passing at 40 MHz, plus Doom DEMO3. **Win95/full-suite qualification remains
open for this programmable-clock image.** Earlier images' passes do not fill
that gap. See [README results](README.md#verified-fpga-results).

Current verified gameplay IPC: **0.496499864 total U+V**, original `2886d24c`,
cycles **625,021,130,428–629,480,208,865**. Public rebuilds are unmeasured until
separately tested; startup or CoreMark counters are not gameplay IPC.
