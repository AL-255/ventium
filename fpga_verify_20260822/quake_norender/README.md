# Quake no-render timedemo accelerator

This diagnostic image preserves the validated FASTTICK and heap-scan
workarounds, then changes one additional byte in the retail DOS `QUAKE.EXE`:

```text
runtime EIP 0x336fa / file offset 0x32efa
83 ec 04 ...    R_RenderView: sub esp,4; ...
c3              ret
```

The wrapper was identified from the executable's embedded
`R_RenderView: ...` error strings and their direct code references. Its normal
body performs stack/alignment checks and calls the renderer at `0x3340a`; the
one-byte patch returns before rasterization. The host/demo loop, game
simulation, console events, and frame counter remain unchanged.

`QUAKE_NORENDER.EXE` has SHA-256
`ab85733550b61a0cfee9bbb8a66aafd1f80d502575603d5bfabc585ebe528639`.
Against `../quake_memscan_patch/QUAKE_MEM.EXE`, `cmp -l` reports only one-based
offset 208635 (`0x83 -> 0xc3`). The complete clean disk
`qk_td_norender.vhd` has SHA-256
`6509329ecdae02ec2058de897cb5c775db780c057d4d9d48be9dcd36e8288ff6`.

Pinned QEMU 8.2.2 with the Pentium CPU, 32 MiB, and the CR0-clearing production
BIOS stub completed the exact demo frame sequence:

```text
969 frames   2.6 seconds 372.1 fps
```

The full 840-byte record is `qemu_norender_qconsole.log`. This is a reversible
workload accelerator only. It cannot validate rasterizer output or replace the
unmodified reset/BIOS/Quake checks on the repaired RTL image.
