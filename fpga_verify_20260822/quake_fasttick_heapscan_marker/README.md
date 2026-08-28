# FASTTICK + no-render heap-scan completion-marker experiment

This composition combines the FASTTICK disk with the later, QEMU-proven
no-render heap-scan executable and the narrow logger-return/969-marker binary.
It corrects the first FASTTICK experiment, which accidentally used the older
heap patch and therefore remained in the long checksum loop at `0x456b0`.

The executable is copied from the hash-locked `quake_heapscan_loggerret_marker`
artifact; the disk itself comes from the FASTTICK image.  No RTL or FPGA image
is changed.
