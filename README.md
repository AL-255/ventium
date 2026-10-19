# Ventium

<p align="center">
  <img src="docs/quake-timedemo.gif" alt="DOS Quake demo1 on Ventium FPGA at 40 MHz" width="640">
</p>

**Quake on real FPGA: 7.7 FPS at 40 MHz.** Cold FreeDOS boot, original DOS
Quake `demo1`, **969 frames in 125.8 seconds**, U/V + fast pipeline enabled.
The complete capture above plays at **15 fps**, native 320×200; GIF palette
compression only, no brightness/gamma/contrast changes or dropped frames.
Playback cadence is not engine FPS. [Evidence](docs/FPGA_QUAKE_TIMEDEMO_2026-10-17.md).

Ventium is a synthesizable SystemVerilog reconstruction of the Intel
**Pentium P5/P54C (non-MMX)**: five-stage in-order U/V integer pipeline,
shared pipelined x87, split 8 KiB L1 caches, TLBs, paging, and substantial
protected-mode/system support. The core replaces ao486 in the MiSTer PC
platform, adapted to the **RK-XCZU15EG-F** (`xczu15eg-ffvb1156-2-i`).

**`main` publishes the board-tested `2886d24c` source profile.** Ongoing
unqualified CPU/cache/APR work lives on
[`experimental/uv-fast-ipc-apr`](https://github.com/AL-255/ventium/tree/experimental/uv-fast-ipc-apr).
This is not a claim of complete Pentium compatibility or a fully accepted
Windows 95 image. The unsupported-ISA and historical design documents remain
useful references; the pinned FPGA profile and results below define this release.

## Build the FPGA image

The complete hardware source closure is public: no private submodule, local
external checkout, disk image or prebuilt checkpoint is needed for this build.

```bash
git clone https://github.com/AL-255/ventium.git
cd ventium
python3 -B fpga/build_known_good.py --check
tclsh fpga/test_known_good_wrapper.tcl "$PWD"

# Vivado 2025.2 with Zynq UltraScale+ device support/license; choose your paths.
python3 -B fpga/build_known_good.py --build \
  --vivado-root /opt/AMD/2025.2/Vivado \
  --output /path/to/scratch/ventium-2886d24c-build
```

Read [HOW_TO_RUN_FPGA.md](HOW_TO_RUN_FPGA.md) first for prerequisites, the
single-Vivado rule, output/report checks and safe board preparation. The output
directory must be new and outside the checkout. Large generated files and
guest media do not belong in Git.

The source manifest pins the exact tested processor/159-define profile and the
repaired programmable-clock logic. The original image reused a prior physical
layout; a fresh source build **does not guarantee the same bitstream hash,
timing or workload reliability**. The portable recipe has offline checks but
has not had a new full Vivado/board qualification during publication. The
original routed checkpoint and bitstream are not embedded in the repository.

## Verified FPGA results

Latest physical evidence: **2026-10-17**, image **`2886d24c`**. All results below
use U/V dual issue and the system fast pipeline, not U-only diagnostic controls.

| Measurement | Verified result | Scope |
| --- | --- | --- |
| Quake `demo1`, cold FreeDOS/DOS | **7.7 FPS**; 969 frames / 125.8 s | 39.999826 MHz; full timedemo + full capture; sound off |
| Quake gameplay IPC | **0.496500 total U+V**; U alone 0.383003 | Interior gameplay window, not boot/startup |
| Doom shareware 1.9 `DEMO3` | **20.50 FPS**; 2,134 gametics / 3,644 realtics | 39.999830 MHz; 320×200 high detail, screenblocks 10, sound off |
| CoreMark performance / validation | **2.100128 / 2.106796 CM/MHz** | 40 MHz, 4,000 iterations, full 2 KiB, correct CRCs for both seeds |
| Highest tested passing CoreMark clock | **52.6316 MHz** | Both seeds passed twice; not Quake/Win95 qualification |
| Windows 95 on this clock image | **Not qualified** | Earlier image/simulation results do not qualify this image |

IPC is measured over cycles **625,021,130,428–629,480,208,865**, image
`2886d24c`, with 2,213,929,775 U+V retirement events across the qualifying
intervals. Counters include REP-element retirement, not deduplicated x86
macroinstructions. New/experimental candidates have no inherited gameplay IPC.

Sources: [Quake and capture](docs/FPGA_QUAKE_TIMEDEMO_2026-10-17.md),
[Doom](docs/FPGA_DOOM_2026-10-17.md),
[CoreMark and clock sweep](fpga/PROGRAMMABLE_CLOCK.md).
Detailed reports retain original machine-local evidence paths; those paths are
historical provenance, not public build dependencies.

### Frequencies: target, timing estimate and measured silicon

| Quantity | Frequency / outcome |
| --- | --- |
| Core implementation constraint / boot clock | **40 MHz** (25 ns) |
| PS reference and HP0 AXI | **100 MHz** (10 ns) |
| Measured Quake/Doom core clock | **≈39.99983 MHz** |
| Conditional post-route core timing estimate | **28.701817 MHz**; setup −9.841 ns at 25 ns, worst hold +0.004 ns |
| CoreMark sweep | Both seeds pass at **40, 50, 52.6316 MHz** |
| Higher tested points | Performance seed times out at **55.5556 and 62.5 MHz** |

The timing estimate is `1000 / (25 − WNS)` for the reported same-clock setup
path. It is **not** the programmed frequency or a measured failure threshold.
The image has empirical 40 MHz workload passes, **not 40 MHz STA sign-off**.
52.6316 MHz is the highest tested passing point, not an absolute maximum or
thermal/reliability guarantee. This image was not qualified at 70/71.4 MHz.
One programmable PLL image was used for the whole sweep; no per-clock rebuilds.

Later fresh synthesis/APR trials did not produce a newer qualified image. The
last trial was cancelled on **2026-10-19** during routing at the owner's request.
No final timing or performance gain is claimed for it.

## FPGA utilization and physical layout

These are the **routed `2886d24c`** measurements, not estimates from an
unfinished synthesis. The CLB map uses Vivado physical tile coordinates and
actual synthesized hierarchy ownership, including mixed-owner sites.

![Compact hierarchy-colored CLB map](docs/fpga-physical-2886d24c/clb-hierarchy-compact.png)

Non-CLB-only columns are removed for readability. X labels retain physical
coordinates, but horizontal spacing is compressed; do not infer wire lengths.
White denotes unused CLBs, grey partial-height device gaps.
[Uncompressed physical-coordinate map](docs/fpga-physical-2886d24c/clb-hierarchy.png).

| Resource | Used / available | Utilization |
| --- | ---: | ---: |
| CLB LUTs | 186,086 / 341,280 | **54.53%** |
| Occupied CLB sites | 33,528 / 42,660 | **78.59%** |
| Registers | 55,190 / 682,560 | 8.09% |
| Block RAM tiles | 277.5 / 744 | 37.30% |
| DSP48E2 sites | 47 / 3,528 | 1.33% |

![Directional routing-congestion windows](docs/fpga-physical-2886d24c/routing-congestion.png)

Reported regional congestion peaks at **90.37%**, despite global routing usage
of **28.32% vertical / 27.54% horizontal**. Unreported areas are unknown, not
zero. The worst EIP-to-paired-load-return setup path has **89 logic levels**
and **74.7% routing delay**. Free LUT count alone does not describe that local
connectivity bottleneck. [Method and analysis](docs/FPGA_PHYSICAL_MAP_2026-10-17.md).

Regenerate the graphics without Vivado (Python + NumPy + Matplotlib):

```bash
python3 fpga/scripts/render_device_view.py \
  --data docs/fpga-physical-2886d24c/physical-map.json.gz \
  --image-id 2886d24c --output /path/to/scratch/ventium-maps
```

## Verification and scope

Architectural differentials against the pinned QEMU Pentium oracle remain the
correctness authority. They are separate from source packaging checks and
physical timing. The full standard acceptance suite is **both CoreMark CRC
seeds + Windows 95 boot-to-desktop/UI interaction + complete Quake timedemo**.
It must pass in U/V + fast-pipe mode after major core/cache changes. A snapshot,
startup capture, U-only/slow control or an older image's pass is not acceptance.

The public FPGA build does not require `ventium-refs`; most historical
differential gates do, and that private submodule is not publicly supplied.
Do not replace the pinned oracle with distribution QEMU and claim equivalence.
The generic verification Makefile/tests predate this source release; their
full compatibility with the imported hardware profile has not been requalified.

## Source layout and licenses

```text
rtl/                         Core, legacy x87, caches/TLBs, AXI and P5 bus
fp_shared/                   Shared pipelined x87 implementation
ao486-sim/{ven,stubs}/        Frozen CPU/platform adapter and memory primitives
3rd-party/ao486_MiSTer/       Exact patched peripheral RTL required by this build
fpga/rk/                     Frozen board integration, project Tcl and constraints
fpga/known_good_2886d24c.json Hash-pinned public source profile
fpga/board-tools/            Debug and programmable-clock utilities
docs/                        Results, physical maps and historical design docs
```

Ventium-authored code is under [Solderpad Hardware License 2.1](LICENSE).
Third-party files retain their own notices; see
[third-party attribution](fpga/THIRD_PARTY.md). Vivado/IP licensing is separate.
No HDD images, proprietary OS/game data, private manuals, generated checkpoints
or vendor tools are distributed with this source release.
