# Quake no-render heap-cap discriminator

This experiment extends the QEMU-validated `quake_norender_heapscan` workload.
It is a guest-only diagnostic and is not an RTL repair or a Quake acceptance
pass.

## Change

`R_NewMap` converts `r_maxsurfs` to an integer at runtime EIP `0x32274`.  The
original code clamps values at or below 800 to 800, but allocates `value * 64`
bytes otherwise.  A historical FPGA/cosimulation signature read a corrupt
`8,000,000.0` value and consequently requested 512 MB from `Hunk_Alloc`.

`make_patch.py` hash-locks `QUAKE_NORENDER_HEAPSCAN.EXE` and changes only the
following conditional branch at runtime `0x3229b` (file `0x31a9b`):

```text
81 fa 20 03 00 00 7f 0d    cmp edx,800; jg allocate
                       ->  jmp existing-800-surface branch
```

The allocation, startup, host loop, game/demo input, and 969-frame counter are
unchanged.  This is appropriate only for the no-render workload: the renderer
does not consume the surface cache after its documented early return.

| Artifact | SHA-256 |
|---|---|
| `QUAKE_NORENDER_HEAPCAP.EXE` | `4e236687c134363c5d7a3be7f256aacf0b9f7531e603813f8ac946e1ff6e4227` |
| clean disk before QEMU | `e8c7797ad15e387d6a128ac3454da50577c66a97fadb340b7922812f29bf6a3f` |

The executable was written into the FAT16 partition at byte offset `63*512`
and round-tripped byte-for-byte before running.

## Pinned QEMU oracle

Pinned QEMU 8.2.2 (`-cpu pentium`, 32 MiB, production `boot0.rom`) completed
the guest’s actual timedemo sequence:

```text
969 frames   2.5 seconds 386.0 fps
```

This establishes that the branch patch does not forge the result and preserves
the no-render guest workload on the reference processor.

## FPGA result: fail

The FPGA used bitstream
`013396318e9c385b80c36d43422fa5795c3c50c65615126082ca5ff302eda4b9`
(`IDENT=A0486501`, 3.125 MHz).  It logged the expected:

```text
29.7 megabyte heap
600k surface cache
```

Therefore the cap did bypass the bad 512 MB surface-allocation path.  It did
not complete timedemo: `QCONSOLE.LOG` contained only normal startup text, no
`969 frames` record was written, and IDE reads stalled at 584 for more than ten
simulated minutes.  The preserved daemon log is
`fpga_heapcap_failed.log`, SHA-256
`6743f2ec2c09c4e272c3603bbfb9da95b95a5615d1cb9c0b1f535043f5703e81`.

The board disk was restored after the run to the clean baseline
`qk_td_norender_heapscan.vhd`, SHA-256
`74c028b4fdc63f0aada78f1a9209bf6a8523cffefffceeb233705238acd6b04b`.

Conclusion: the oversized allocation is a genuine corruption symptom that can
be bypassed safely in this restricted workload, but it is not the remaining
terminal FPGA blocker.  Do not report this experiment as a Quake pass.
