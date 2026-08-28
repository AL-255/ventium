# Quake no-render heap-cap + console-background bypass

This is a second guest-only FPGA discriminator.  It composes the hash-locked
800-surface cap from `../quake_norender_heapcap/` with a one-byte return at
`Draw_ConsoleBackground`'s entry (runtime `0x78e6`, file `0x70e6`).  The
function owns the late `sprintf("%4.2f", 1.06)` overlay path whose corrupted
x87 conversion can overflow a local buffer and then fault in generic memcpy.
The no-render workload has no framebuffer acceptance target; its host/demo
loop and 969-frame counter remain outside this overlay.

`make_patch.py` verifies the complete parent executable hash and exact function
prologue, replaces the prologue with `ret` plus NOP fill, and the generated
EXE is FAT-round-tripped before execution.

| Artifact | SHA-256 |
|---|---|
| `QUAKE_NORENDER_HEAPCAP_NOCONBACK.EXE` | `8e3a93dff2131a71dab904f00ca3b96a9507d6f1c6021b14cd721943f3db156d` |
| clean disk before QEMU | `007a6bba636f158c37dde6871cda98f88e4fa0590fa9c5f73185b3ff5d06b13a` |

Pinned QEMU 8.2.2 (`-cpu pentium`, 32 MiB, production `boot0.rom`) completed
the actual guest workload and wrote:

```text
969 frames   2.6 seconds 369.8 fps
```

## FPGA result: fail

The same `IDENT=A0486501` bitstream used by the other current experiments was
run from the clean disk.  It passed the old `t≈927.5 s` failure point but never
wrote the 969-frame record.  IDE reads stopped at 584 and remained unchanged
for more than eleven simulated minutes; the guest had returned to the same
DOS/DPMI idle class seen with the heap-cap-only image.  The preserved daemon
log is `fpga_noconback_failed.log`, SHA-256
`5d34281068609faa17caf4b26bdb1224bed841206210eb9cc85ec92cc6a6ad38`.

This is not an acceptance pass.  The console-background overflow is a genuine
failure path, but bypassing it only exposes a sibling/earlier terminal path.
The board was restored after the run to clean
`qk_td_norender_heapscan.vhd`, SHA-256
`74c028b4fdc63f0aada78f1a9209bf6a8523cffefffceeb233705238acd6b04b`.
