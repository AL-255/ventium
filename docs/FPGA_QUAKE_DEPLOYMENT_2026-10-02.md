# RK FPGA Quake deployment — October 2, 2026

## Current status (19:41 UTC)

Administrator access works. The DDR reservation and FPGA programming are
complete; cold Quake startup is not yet working. The clean ARM daemon exits
with SIGBUS while clearing reserved guest RAM, before disk/ROM initialization
and core release. This is not an OOM or a Quake acceptance result.

Verified **simulation** gameplay IPC is **0.42633263**, model
`5c2491f3b2eb73243e47cb614ae6d2e36012eb36f4f402e32fa3e9da27290033`,
clocks **7,099,999,637–7,199,999,637**. No FPGA gameplay IPC is measured.

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
reports PL0 about 100 MHz. No new Vivado run was launched. It is **not** a
current-5c hardware qualification: the external board flow was untracked and
no exact archived source/daemon pairing proves that ancestry.

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
fault-PC evidence; do not weaken exclusive guest-memory ownership to bypass it.
See [ARM64 /dev/mem protection](https://raw.githubusercontent.com/torvalds/linux/v6.12/arch/arm64/mm/mmu.c)
and [memory-type definitions](https://raw.githubusercontent.com/torvalds/linux/v6.12/arch/arm64/include/asm/pgtable.h).

## Movie requirements

The passive recorder is private BRAM: arming/draining it does not modify guest
RAM, halt execution or flush caches. Stream binary VENVCAP1 over **non-PTY**
SSH directly to the host; keep progress on stderr and credentials out of
commands/scripts/logs. The armed first capture has not produced a frame while
the guest remains in reset.

Preserve raw colors and dimensions. Presentation is 15 fps, with no gamma,
brightness or contrast processing. Retain capture-cycle timestamps; a
constant-rate presentation is not measured silicon FPS. One recorder buffer
does not guarantee capture of every game-engine frame. A full movie needs
continuous temporal coverage through the visible 969-frame completion result,
plus separately checked timedemo completion. Never count 969 scanout samples
as proof that the game completed 969 timedemo frames. Use bounded compressed
lossless output to avoid filling the host or board filesystem.
