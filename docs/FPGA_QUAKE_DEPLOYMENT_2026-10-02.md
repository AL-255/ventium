# RK FPGA Quake deployment — October 2, 2026

## Current status (20:35 UTC)

Administrator access and the boot-time DDR reservation work. The board remains
held in reset on the historical image. At the user's request, a new **40 MHz**
current-source image is being synthesized; no new bitstream is deployed yet.
The first daemon's SIGBUS has an instruction-level cause (`DC ZVA` on Device
memory), and an isolated scalar-access successor is built and microtested,
and staged on the board. Its control-only `--ident` probe exits zero; DDR
initialization and cold guest startup are not yet qualified. No FPGA
timedemo/movie is accepted.

Verified **simulation** gameplay IPC is **0.42633263**, model
`5c2491f3b2eb73243e47cb614ae6d2e36012eb36f4f402e32fa3e9da27290033`,
clocks **7,099,999,637–7,199,999,637**. No FPGA gameplay IPC is measured.

## Fresh 40 MHz build

The current build is under
`/var/tmp/ventium-fpga-quake-oct02.rc0wVn/fpga40-vco1g.3vpbYB/`.
Its frozen-input manifest SHA is
`adfb6ff13531761637599ec837527a788483706413b78735666023460f121c1c`:
179 explicit source/evidence files, the verified simulator's exact 107 defines,
plus only `SYNTHESIS`, `VTM_NO_DPI`, and `VEN_ALTSYNCRAM_XPM` for hardware.
The legacy FPGA default missed 79 verified defines and added three unverified
uop-cache defines; it is not used. Full P5 caches remain selected.
Common RTL/source pins were checked unchanged from the accepted 5c build.
The host resource guard is intentionally updated, not an RTL/profile change.

The new clock is a real MMCM derivative of PL0: **100 MHz × 10 / 25 = 40 MHz**,
with a 1 GHz VCO and output gated until LOCKED. Its source SHA is
`7d156871987abc06ee09412016ddb305d6551d6adf4a19e4159e131179d041aa`.
Genuine AMD Unisim simulation checked startup gating and 200 exact 25 ns
periods (actual exit 0, 0.13 seconds). The initial M8/D20 prototype was
superseded because the modeled PL0 rate of 99,999,001 Hz put its VCO slightly
below the 800 MHz minimum. The new VCO is safely inside range. This is not
routed timing or a silicon-clock measurement.

The external PL top now feeds its actual `CLK_HZ` to PIT/RTC/VGA; accelerated
4 MHz/80 kHz/90 MHz simulation defaults are not copied into physical hardware.
The hosted PS/2 sender scales its existing timing with that same parameter,
using 64-bit arithmetic and appropriately sized counters. Ordinary-pin tests
checked both legacy and 40 MHz profiles: 12 frames, 132 bits, phase lengths,
byte order, framing/parity and prelaunch host inhibition. These are narrow
tests, not full keyboard/controller acceptance. No arbitration fixes added.

The template PS preset produced catalog validation errors. The preliminary
run was explicitly stopped (actual outer exit 143), and the documented
**PCAP-only, preset-free** flow is now used: booted Linux keeps PS DDR/MIO
configuration; PL overrides retain 100 MHz PL0 and native 128-bit HP0 with
the explicit 64-to-128-bit converter. The final BD validated at 40 MHz,
and HP0 remained 128 bits after propagation.

Synthesis started at 20:11 UTC, `balanced` profile (Default synthesis), one
run job/internal worker. Scope invocation is
`1e9b119f6c8744988529c6382906ac20`; initial limits were 8 GiB memory,
2 GiB swap and 32 tasks. Timing optimization grew beyond that working set.
After repeated actual host-headroom checks, the **same invocation** was
extended to 9 GiB (soft limit 8 GiB), then 11 GiB (soft 10 GiB), and finally
13 GiB hard / 12 GiB soft, then 14 GiB hard / 13 GiB soft,
retaining 2 GiB swap, 32 tasks and one run.
At 20:31:29 it used 12.37 GiB; swap was full and the soft limit was throttling
it. Host available memory was about 3.1 GiB. No memory-max/OOM/kill event was
recorded; one task-cap event occurred without a corresponding tool error.
This is resource pressure, not useful completion evidence or permission to
expand indefinitely. The user then authorized terminating Chrome; by the
actual process check it had already exited, so no signals were sent.
With 7.5 GiB host-available memory, the same scope was extended to
**18 GiB hard / 17 GiB soft**, still bounded by the reviewed 20 GiB ceiling.
At 20:35:07 memory was 14.927 GiB, anonymous memory 13.357 GiB and host
available memory 7.650 GiB. Pressure stopped accumulating and synthesis
recovered to approximately one productive CPU core. No OOM/max/kill event
occurred. The independent resource/source audit is under
`vivado-resource-watch.rryo52rB/resource-watch.json` in the task directory.
Preliminary runs are gone; routing has not started. Do not treat process
progress as a synthesis/timing pass.
Inspect area before implementation; then check routed DRC/setup/hold and
clock reports, hash/program the artifact, measure silicon MHz, and run the
unmodified cold timedemo with the matching widened capture tool.

Preflight found the actual core clock is `mmcm_clk` (25.000 ns), whereas the
old resume reporter searched only legacy divider names. The separately pinned
resume script is now
`impl-resume-current.QSFuiF98/launch_impl_existing.tcl` in the task directory,
SHA `0299790cad0488ef90895bdbb35287c5f67d6bec6ea964fa05fb19d8f98a6f1f`.
It accepts the actual MMCM name, validates an explicitly requested 40/45/50 MHz
target and finite clock/slack values, and prints its completion marker only
after successful reports. All 61 real-tclsh/stub-only cases passed; root
independently reran them. This new resume copy does **not** change the original
179 frozen inputs. Set `VEN_FPGA_CORE_MHZ=40` when resuming the existing XPR;
do not regenerate the BD or repeat synthesis. A completed implementation and
finite negative WNS still do not constitute timing closure.

The FPGA's existing retired counter counts primary retire events only; it
omits simultaneous V-pipe retire events. Its read-only cycle counter is valid
for MHz measurement, but its displayed IPC is **not comparable to total
simulator U+V gameplay IPC** without a separately qualified total counter.

Resource cleanup removed only exact reviewed `.o`, `.a`, and `.gch` compiler
intermediates from closed old builds. Binaries, sources, receipts, logs,
media and current model/build directories were preserved. The initial cleanup
recovered 5.11 GiB root-disk space and 1.82 GiB tmpfs space; its SHA/path
manifest is under `/var/tmp/ventium-generated-cleanup-oct02.xy3EgO/`.
Intermediates are rebuildable with matching inputs, not backed up. Additional
old tmpfs-intermediate cleanup recovered another 3.85 GiB without deleting
model executables or sources; its manifest is under
`/var/tmp/ventium-generated-cleanup2-oct02.9fZBVC/`.

## Boot-memory change and rollback

The original board DT was preserved locally and on the boot partition. Only
`/reserved-memory` and its guest-RAM child were added: all 186 original nodes,
1,362 properties and 133 symbols were independently compared unchanged.
BOOT.BIN, Image and boot.scr were not modified.

| Artifact | SHA-256 |
| --- | --- |
| Original DT / `system.pre-ventium-oct02.dtb` | `6363f525e5d440ee78ae7c6dc476131e641b14539fa266fb9fd1885a78d47488` |
| Installed `/boot/firmware/system.dtb` | `6d820ea0755d9f87256a9bc86ee0ca454480951ac403fc91cbdfd0845280e9bf` |

The new boot ID is `2861e4e8-cd4c-48cd-9f44-7f7d8a991ebb`.
Root read the effective DT: `reg = <0 0x60000000 0 0x10000000>`, `no-map`,
and no reusable/pool property. Root `/proc/iomem` reports
`60000000-6fffffff : reserved`; System RAM ends below and resumes above it.
The boot log explicitly reports `nomap non-reusable guest-ram@60000000`.
CMA's separate 512 MiB pool moved to `0x40000000–0x5fffffff`.

Rollback, if necessary, means restoring the hash-verified original DT to
`system.dtb`, syncing and rebooting. **After rollback, the hardcoded guest
aperture is unsafe again: do not launch the daemon or map guest DDR.**
Never substitute a runtime DT overlay for boot-time memory exclusion.

## Programmed artifact and protocol pairing

The board retained `/lib/firmware/rk_ao486_system.vga_capture_20260829.bit.bin`,
SHA `279bc2c0caa14cbea169ddf1b25a60407ef0b44bbc3a92186d96e251895064fd`.
It was copied back to the host and independently hashed, then programmed using
the existing FPGA-manager/configfs loader. Manager state is `operating`;
the control-only clean-daemon IDENT probe returns `a0486501`, CTRL `1` (reset).

This historical RK image targets `xczu15eg-ffvb1156-2-i`; its recorded core
clock is 3.125 MHz, WNS +4.521 ns and WHS +0.014 ns. The live Linux clock tree
reports PL0 about 100 MHz. This was a recovered artifact, not a newly built
image; the current-source build above is separate. It is **not** a
current-5c hardware qualification: the external board flow was untracked and
no exact archived source/daemon pairing proves that ancestry.

Actual read-only hardware-counter measurement while reset is held:
6,250,569 cycles over 2.000077 seconds = **3.125164 MHz**, zero retire events.
Counter endpoints are 1,382,828,105–1,389,078,674. This is clock evidence,
not gameplay IPC or performance acceptance.

Use the tools at commit `f2ffc0106b0ba42ec3fa2020ad61675cfe440212`:

| Tool | SHA-256 |
| --- | --- |
| `fpga/board-tools/ven_board_probe.py` | `1dd0baf6909f7f767cea639568b059698511cc96b34ca1193b95b678295dc857` |
| `fpga/board-tools/ven_vga_stream_to_video.py` | `dae7ff6512889f9075153ce4b8c0be32e471f60f3ed9f63cea8a99335d2c8649` |

These decode the 64 KiB RGB332 recorder, 9-bit width/height and 17-bit pixel
count. Today's widened tools are **not** compatible with that metadata packing.
Prepared host copies are under
`/var/tmp/ventium-fpga-quake-oct02.rc0wVn/historical-vga-f2ffc01/`.

## First cold attempt

The isolated clean daemon SHA is
`3feafe09a07b397cec4a61b435383f8c603f6e60db267e10958388ccad3e931c`.
It removes the default BDA LED rewrite/cache-flush intervention and rejects
injection/flush/debug workarounds. It checks manager state, unmasked iomem,
input identity and ROM completion before releasing the core. Its compile and
host-stub checks are not board qualification.

Cold disk SHA is
`2df14ac9ae5f927cab2410e784d14c655f0e96644ca80ced3c0b012df7a36e4c`.
This is FreeDOS DOS Quake 1.06 shareware with CWSDPMI, starting ordinary
`quake -nosound -nocdaudio -condebug +timedemo demo1`; no snapshot or guest-code
patch was introduced. ROM hashes are `dca915c5…dd26a3` (general P5 cache-enable
BIOS bootstrap) and `fb0d673a…e08296` (VGA BIOS).

Service `ventium-quake-cold-oct02.service`, invocation
`c3c79a6d275744b8b652495aff9a9653`, failed at 19:40:11 UTC with
`ExecMainCode=2`, `ExecMainStatus=7`, `Result=signal`. Its last log line is
`zeroing 256 MB guest RAM...`; the core was not released. Memory limits were
512 MiB, zero swap, 32 tasks and a two-hour host safety deadline.

The static daemon's `__memset_generic` uses `DC ZVA` for large zero fills.
Linux 6.12 ARM64 maps non-map-memory `/dev/mem` pages as Device-nGnRnE,
not Normal-NC. This is a suspected access-attribute mismatch, pending exact
fault-PC evidence at first inspection; do not weaken exclusive guest-memory
ownership to bypass it.
See [ARM64 /dev/mem protection](https://raw.githubusercontent.com/torvalds/linux/v6.12/arch/arm64/mm/mmu.c)
and [memory-type definitions](https://raw.githubusercontent.com/torvalds/linux/v6.12/arch/arm64/include/asm/pgtable.h).

At 19:48 UTC the guarded bounded probe
`devmem_sigbus_probe.aarch64` (SHA
`5f25cbbb7cfa56458a52098098f9af2c07dabf1f5b932002d12c91a3c7013760`)
independently checked manager/DT/root-iomem/IDENT/CTRL=1. Aligned read64 at
`0x60000000` succeeded. An explicitly requested 64-byte `DC ZVA` experiment
faulted with SIGBUS, si_code 1, ESR `0x92000061`, PC `0x400bac`, exit 135.
Root disassembled that exact PC as `dc zva, x0`. A scalar 64 KiB clear at the
same address returned zero using `str xzr` and `dsb sy`. Neither experiment
released the guest or changed its disk. This confirms the instruction/mapping
mismatch; it does not yet qualify the complete replacement daemon.

The successor ARM binary is `/tmp/ao486/ao486d.device-safe-oct02`, SHA
`03e1860ffb80a4b3113e2644259933a95650e687fc0ca57ebf69ee04ad94c4b6`.
It uses explicit scalar Device-memory loads/stores and normal-memory file
bounces instead of libc bulk operations on `/dev/mem`. Bounded host tests
checked sizes, aliases, partial overlap, short reads and file transfers;
cross-compilation and disassembly also passed. At 20:20 UTC its `--ident`
returned zero, IDENT `a0486501`, CTRL `1`, and explicitly left DDR unmapped.
That is control-path evidence only; do not count it as guest startup.
The updated host-stub startup gate also passed in 1.5 seconds: non-operating
manager/System-RAM overlap are rejected before mapping, malformed/short ROM
loads and rejected Device aliases/bounds do not release the guest, and a valid
stubbed startup holds then releases exactly once. Its proof is under
`startup-guard-hoststub-axi-audit/` in the task directory. It uses ordinary
host RAM and stubbed x86/IDE, not real ARM Device execution or ROM correctness.

## Movie requirements

The passive recorder is private BRAM: arming/draining it does not modify guest
RAM, halt execution or flush caches. Stream binary VENVCAP1 over **non-PTY**
SSH directly to the host; keep progress on stderr and credentials out of
commands/scripts/logs. The armed first capture has not produced a frame while
the guest remains in reset. That failed old capture is a 16-byte header-only
archive, not a movie. No capture process remains active.

The newly staged wide probe is `/tmp/ao486/ven_board_probe.wide-oct02.py`,
SHA `cd2842b6da87df26a5fa16840903f8347c628d718239a1d183aba578c038b102`.
It belongs to the new 512 KiB capture interface, **not** the currently loaded
historical image. After programming, use observed CSR dimensions as authority;
`video_lores=1` decimates scanout but does not force Mode 13h. A uniform
320×200 stream should explicitly request that geometry and `--skip-unmatched`
to skip BIOS/text modes without resizing them. Confirm the actual geometry
before interpreting its pixels. The current decoder's default lossy H.264
output is not a lossless RGB movie, and the old private FFV1 assembler pins
historical tool provenance; neither is automatic acceptance for the new run.

Preserve raw colors and dimensions. Presentation is 15 fps, with no gamma,
brightness or contrast processing. Retain capture-cycle timestamps; a
constant-rate presentation is not measured silicon FPS. One recorder buffer
does not guarantee capture of every game-engine frame. A full movie needs
continuous temporal coverage through the visible 969-frame completion result,
plus separately checked timedemo completion. Never count 969 scanout samples
as proof that the game completed 969 timedemo frames. Use bounded compressed
lossless output to avoid filling the host or board filesystem.
