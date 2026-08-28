# Quake heap-scan diagnostic patch

This experiment changes exactly two bytes in the DOS `QUAKE.EXE`:

```text
file offset 0x4457e: 7c e0  (jl  inner_loop)
                     90 90  (nop; nop)
```

The loop is the hot runtime `EIP=0x44d60..0x44d7e` range seen in historical
full-system traces. The patch keeps the allocation, four outer passes, and the
first pair of dword probes per pass, but removes the bulk heap-checksum walk.
The original executable SHA-256 is
`7cdb244122cc607cc6f162524bfcac60f6d11d8ca2ff07473d6cd962311161fb`;
`QUAKE_MEM.EXE` is
`e7b4a6879355ba74d6cab8589db0ae1f1d18407e5bcaecff07a354c42b27167e`.
`cmp -l` reports only 1-based offsets 279935 and 279936.

Stock QEMU 10.2.1 completed both images with exactly 969 frames:

- unchanged control: `969 frames   5.2 seconds 184.7 fps`;
- patched executable: `969 frames   5.2 seconds 187.7 fps`.

The logs are `qemu10_control_qconsole.log` and
`qemu10_patch_qconsole.log`. The clean deployable disk is
`qk_td_memscan.vhd`, SHA-256
`386de92df5e083e24aef5245c32cb3c1b418729e28d1333967966acd9e569fbf`.

This was not selected as the primary workaround: the control completes just as
readily in QEMU, while the old FPGA image never even creates
`\QUAKE\ID1\QCONSOLE.LOG`. That behavior points to the already-reproduced L1D
bypass response-owner defect, not an intrinsically prohibitive Quake loop.
