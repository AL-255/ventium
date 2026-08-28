# One-digit dtoa exit workaround

This experimental binary changes the captured `jne 0x5484e` loop at file
`0x540d1` into a jump to its existing post-loop code.  It preserves all stack
and x87 cleanup performed by the original compare, but emits at most one
fractional digit.  It is intentionally a workload workaround: textual float
output may be inaccurate, while Quake simulation/timedemo state remains the
acceptance target.  It also contains the existing non-DOS completion witness.

The logger-enabled oracle twin is SHA-256
`9764f5c29052ed5a18745298711bd1932e331c1b313ba5c63a25252677e8adc0`.
Pinned QEMU completed it with the exact `969 frames` record; its displayed
`0.4 seconds   0.4 fps` is deliberately formatter-distorted and is not a
performance claim.  The FPGA logger-return candidate is SHA-256
`859a85d81efa54573005279ba9715c5b09a6085f1aea73bd75ff3a8dfc433a34` and
its clean deployment VHD is SHA-256
`10b2e9f85bd795543b7f49a118b25fd432435448c9201c10dbaa3e264ee2a981`.

## FPGA result: formatter workaround rejected

Despite passing pinned QEMU, this image reached the same 582-read FPGA stall
with no completion marker.  Its live PC ring was in Quake resource/search code
(`00A7:4A9*`, `4DF*`, `53D*`), including the local `strcmp` routine, not the
dtoa loop.  Therefore the earlier formatter loop was a symptom of corrupted or
inconsistent loaded data, not the root cause.  The preserved board log is
`fpga_582_retry.log`, SHA-256
`a1922f0211ce7e5e8c40a40ab99027d6fb3a5c75c5b63f2620ddfc2b544501ea`.

The implicated FPGA IDE RTL has separate same-edge consumers of
`io_done & drq`: one changes status, one clears `last_read`, and one selects
the next request from `~last_read`.  Repair it by latching a single completion
record containing the terminal flag, consuming that record atomically for
status/DRQ/request/IRQ, and clearing it only after consumption.  Required
proof: directed terminal and non-terminal PIO completion tests, repeated
IDE-read data-integrity comparison, then the clean unmodified Quake disk to a
hardware-observed 969-frame result.  Do not accept delay or polling changes.
