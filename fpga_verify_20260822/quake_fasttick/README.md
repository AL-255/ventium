# FASTTICK diagnostic disk

This directory contains a reversible guest-side performance experiment for the
3.125 MHz FPGA run. `FASTTICK.COM` replaces real-mode IRQ0 with a minimal TSR
handler that updates the BIOS tick count and midnight flag, sends PIC EOI, and
returns without running the long DOS/DPMI timer chain. `AUTOEXEC.BAT` installs
it before launching the unchanged exact workload:

```text
quake -nosound -nocdaudio -condebug +viewsize 30 +timedemo demo1
```

The clean deployable image is `qk_td_fasttick.vhd` (SHA-256
`176f3b459492cb279a18c5c211c6eb33d7379ddabbe0492ee2a775533d430570`).
It was rebuilt from the clean viewsize-30 image, then only `FASTTICK.COM` and
`AUTOEXEC.BAT` were copied into its FAT16 partition. The COM binary is 82 bytes,
SHA-256 `8f9be38c553773b64987ebfcfb0167fedd311986dcfd934d1ffae41bc23f4e28`.

Pinned QEMU 8.2.2 with the same CR0-clearing production-BIOS stub completed the
control and FASTTICK runs with exactly 969 frames:

- unchanged control: `969 frames   6.2 seconds 156.3 fps`;
- FASTTICK: `969 frames   5.9 seconds 163.4 fps`.

The captured logs are `qemu_control_qconsole.log` and
`qemu_fasttick_qconsole.log`. This proves that the TSR preserves the demo's
architectural frame sequence. It is not an RTL correctness fix and must not be
used to accept the repaired unpatched reset/BIOS path.

`QCONSOLE.LOG` is written in `\QUAKE\ID1`, not `\QUAKE`. On this disk, ID1 is
FAT cluster 138, at physical disk LBAs 878-879. Earlier monitoring of cluster
137 observed only the parent directory and could never find the result.
