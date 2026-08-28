# Win95 repaired-fast silicon acceptance — 2026-08-23

## Result

**PASS for the established headless VMM/System-VM desktop signature** on the
same repaired L1 bypass-ownership bitstream used for the Quake investigation.
This is a clean control-flow acceptance result, not a claim of pixel-perfect GUI
rendering: the board design has no connected display output.

The first launch exited before the CPU ran because the prior Quake forensic run
had intentionally asserted the debug block's sticky external freeze. The daemon
reported `FROZEN latched at t=0`, zero polls, an empty BDA, and no boot sector.
The same hashed bitstream was reprogrammed to clear PL diagnostic state; IDENT
then returned `A0486501` and the clean run started at 2026-08-23 05:38:05 UTC.

## Reproducibility

- bitstream: `fpga_run_20260822_l1bypown/rk_ao486_system.bit.bin`
- bitstream SHA-256:
  `891881f6b7196023bf1d34a6433b7a53f7814166ce6a38dbeb31c0db5f15b5dc`
- source-controlled probe SHA-256:
  `436a8d86f3f3fcd6f2b56f4548130b29031a9066ae4cf0f6f73e2688e9a7e600`
- pristine sparse Win95 source:
  `/home/yukidama/github/ao486_MiSTer/fpga/rk-ao486-system/disk-backup/w95fresh.pristine.vhd`
- pristine source SHA-256:
  `877ae318beb3dc784f966fefaa148af2446abc7beb52eb50d288e3225f5995f8`
- disk restore: `rsync -S --inplace`; the discarded frozen launch performed no
  CPU poll and no disk access, so the restored image remained the run input
- runtime clock: measured `3.125029 MHz`
- CR0 in the successful run: `0x60000010`; CD/NW were not cleared

No key injection, cache flush, stall watchdog, guest-memory patch, trace freeze,
or Verilog debug modification was used during the accepted run. The only
diagnostics were read-only `win95`, `vga-text`, and `perf` probe modes.

## Acceptance evidence

The repeat detector after the first successful sample reported:

```text
samples=1500 transitions=553
top_last_ar=001021c0:1500
top_eip=000001e5:735, 000001e6:725, 0000fec6:3, 0000fee6:3,
        0000018c:3, 00000170:2, 0000012a:2, 0000017e:2
lowmem EBDA_seg=9fc0 IVT13=024c0122 IVT19=05b0002f
       tick=0005f000->0005f0d7
DESKTOP SIGNATURE PRESENT
```

The B8000 text page was completely blank, independently corroborating the
graphics-mode transition:

```text
vga_text printable=0/2000 nonblank=0/2000 nonzero_attrs=0/2000
```

The ten-second post-success interval remained live:

```text
elapsed=10.000087s cycles=31250560 retired=373986
clock=3.125029MHz ipc=0.011967 irq_ack=142
axi rd_beats=0 ar_hs=0 b_hs=3266 cr0=60000010
```

After capture, `ven-w95-l1.service` was stopped and confirmed `inactive`.
FPGA-manager remained `operating`. The unrelated clean Quake disk still hashed
to `13f0a1286ceb0da61ddb2f2f20cacdcabbe585dc2967ba39df3a519463795509`.

## Preserved logs

| Artifact | SHA-256 |
|---|---|
| `win95_l1bypown.log` | `0f6409cc53e8a8039f7a5d79db53f6120fbfcdc80d4ff511322ecd526df6db91` |
| `win95_l1bypown_desktop.log` | `2f07c740301d37baf3d19250bbac6656f0779449a535ca99aad30a3a210b1ebf` |
| `win95_l1bypown_vga.log` | `58df20bc024eac33a2098f01349198b53d73df20dad29c8949a81563d7795180` |
| `win95_l1bypown_perf.log` | `dd40b93d05171b6300763aebf4ad097a01d8eaa8eba1f744cdf09189418d5666` |

This closes Win95 on the repaired fast image. It does not waive the separate
Quake protected-mode `LDS` blocker.
