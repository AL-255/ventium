# Win95 clean-image FPGA retry — 2026-08-28

## Result

**PASS** for the established headless Win95 VMM/System-VM desktop signature on
the current candidate image.  The guest reached the VMM fetch region on the
same unmodified, pristine VHD after the early DOS/V86 phase.

| Item | Value |
|---|---|
| FPGA identity | `a0486501` |
| Raw bitstream SHA-256 | `5dff8335c4885765dbd6be12e9af02f44eb07d87b9e491968ca7b15a5f34db2d` |
| Input VHD | `w95fresh.pristine.vhd` |
| Input SHA-256 | `877ae318beb3dc784f966fefaa148af2446abc7beb52eb50d288e3225f5995f8` |
| Initial disk state | copied with sparse-preserving `rsync -S --inplace` |
| Run | `/tmp/ao486/ao486d --bios /tmp/ao486 --hdd /tmp/ao486/w95fresh.vhd --membase 0x60000000 --secs 7200 --text` |
| Desktop signature | **present** |

## Acceptance evidence

The documented long run reached the expected `001021c0` VMM/VxD fetch region
at raw cycle 1,947,344,804.  The full 1,500-sample acceptance probe then
reported:

```text
samples=1500 transitions=741
top_last_ar=001021c0:1500
top_eip=000001e5:747, 000001e6:747, 0000feab:1, 0000015e:1,
        0000012c:1, 0000fee8:1, 0000fed2:1, 00000152:1
lowmem EBDA_seg=9fc0 IVT13=024c0122 IVT19=05b0002f tick=00069cfc->00069dd3
DESKTOP SIGNATURE PRESENT
vga_text printable=0/2000 nonblank=0/2000 nonzero_attrs=0/2000
```

The all-blank B8000 page is the expected graphics-mode corroboration.  This is
a headless control-flow acceptance result, not pixel capture.

## Early non-terminal observation

An earlier run was stopped after approximately 54 million instructions.  The
same 1,500-sample probe then reported:

```text
samples=1500 transitions=801
top_last_ar=000fff40:1500
top_eip=000001e5:779, 000001e6:715
lowmem EBDA_seg=9fc0 IVT13=024c0122 IVT19=05b0002f tick=00063eed->00063fc4
DESKTOP SIGNATURE ABSENT
```

`05c1:000001e5/000001e6` is the known V86 DOS idle stub, so EIP alone is
not a failure detector.  At this early point, the unanimous fetch address
`000fff40` shows that the VMM/VxD phase had not started.  It is not a failure:
the later uninterrupted run above reached the required `001021c0` signature.

A temporary `l1bypown` control bitstream was also sampled only through this
same early phase before it was stopped, so it has no bearing on the candidate
result.  The exact candidate bitstream was restored before the accepted run.

The board process was stopped after both the early observation and the final
accepted run.  The board disk was restored from the same pristine source and
rechecked before the independent Quake workload:

```text
source SHA-256 = 877ae318beb3dc784f966fefaa148af2446abc7beb52eb50d288e3225f5995f8
board  SHA-256 = 877ae318beb3dc784f966fefaa148af2446abc7beb52eb50d288e3225f5995f8
size=2147483648 blocks=186504
```

No RTL, bitstream, or persistent board-debug capture was created by this
retry.  The board root filesystem had only 4.3 MiB free, so all daemon output
was sent to `/dev/null` and the result above was collected through bounded,
read-only debug registers.
