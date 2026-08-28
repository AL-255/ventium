# Quake no-render plus second heap-scan accelerator

This diagnostic workload starts from `quake_norender/QUAKE_NORENDER.EXE` and
changes only the `jl` backedge at file offset `0x44eb0` (runtime EIP
`0x456b0`) to two NOPs.  That loop performs a four-pass, 64 KiB-stride heap
checksum after Quake's allocation is already complete.  The allocation,
outer-pass count, game loop, demo input, console output, and timedemo frame
counter remain intact.

`make_patch.py` hash-locks its input and checks the full local instruction
context before producing `QUAKE_NORENDER_HEAPSCAN.EXE`.  The VHD is derived
from the never-booted no-render image and is checked with QEMU before it is
sent to the FPGA.

The generated executable SHA-256 is
`16cfc75dc096bf5b1a9869f469e1e5d009a84737a7e380e29385a8588e4a79e3`.
The VHD SHA-256 is
`74c028b4fdc63f0aada78f1a9209bf6a8523cffefffceeb233705238acd6b04b`.
Pinned QEMU 8.2.2 (`-cpu pentium`, 32 MiB, production CR0-clearing BIOS)
completed the guest’s exact record:

```text
969 frames   2.5 seconds 388.2 fps
```

The captured `QCONSOLE.LOG` has SHA-256
`d903eeda991b4a17a9a03e5acef3c27dadd6007a74b4d932e8358d32e4ecfa28`.
