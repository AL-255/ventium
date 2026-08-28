# FASTTICK + heap-scan completion-marker experiment

This is a binary-only next experiment after the 582-read IDE-completion retry.
It starts with the QEMU-proven FASTTICK+heap-scan workload, which eliminates a
long DOS timer chain and a post-allocation checksum loop while retaining the
same 969-frame timedemo.  The derived Quake executable additionally makes only
`Con_DebugLog` return and writes `969` to `DS:0x90b48` just before the original
timedemo-result printer.  The latter provides a board-readable completion
witness without creating a DOS file.

No FPGA RTL or bitstream is changed.  The patcher hash-locks its source and
both instruction contexts; a pinned-QEMU completion check is required before
deployment.

## First FPGA attempt — inconclusive composition failure

The image built from `QUAKE_MEM.EXE` booted and passed the normal 190/385/450
IDE-read checkpoints, but was deliberately stopped after a 75-second
CPU-only interval at 450 reads.  The read-only PC sampler showed active work at
`00A7:456A*` over the heap, not an IDE retry.  This identifies an experiment
composition mistake rather than a new hardware result: `QUAKE_MEM.EXE` has the
older checksum change, while the later no-render heap-scan bypass is at runtime
`0x456b0` and was not included.  The result marker was not reached.

Preserved evidence: `fpga_450_stall.log` SHA-256
`587f4ab7b75dc7e1b8e1c6b762cc1b9e4678a16d2e7e01b9014592ea03522287`;
the empty marker watch is `fpga_450_marker.log`.  The next image must retain
FASTTICK but use `QUAKE_NORENDER_HEAPSCAN.EXE` as its executable base.
