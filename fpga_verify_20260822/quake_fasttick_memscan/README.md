# FASTTICK + heap-scan FPGA workaround

`qk_td_fasttick_memscan.vhd` combines the two independently reversible guest
workarounds used to shorten the 3.125 MHz silicon run:

- `FASTTICK.COM` replaces the DOS IRQ0 chain with the minimal BIOS-tick/PIC-EOI
  handler documented in `../quake_fasttick/README.md`.
- `QUAKE.EXE` has only file offsets `0x4457e..0x4457f` changed from `7c e0`
  (`jl` back into the bulk heap-checksum loop) to `90 90`, as documented in
  `../quake_memscan_patch/README.md`.

The disk was copied from the clean FASTTICK image and the independently hashed
`QUAKE_MEM.EXE` was copied over `\QUAKE\QUAKE.EXE`. The extracted executable is
SHA-256
`e7b4a6879355ba74d6cab8589db0ae1f1d18407e5bcaecff07a354c42b27167e`.
The complete clean disk is SHA-256
`57579c4f93fad16e1eb02a08cff670f47fd3df2010d5a3ffbfa28c90aa2894c6`.

Pinned QEMU 8.2.2, Pentium CPU, 32 MiB, and the same CR0-clearing production
BIOS stub completed the image with the exact required frame count:

```text
969 frames   5.6 seconds 172.8 fps
```

The full console record is `qemu_combined_qconsole.log`. This image is a
workload accelerator and diagnostic only. RTL acceptance still requires the
unmodified reset discriminator, unmodified production BIOS, and clean
unmodified Quake disk to pass on the repaired bitstream.
