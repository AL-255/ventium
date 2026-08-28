# Bounded-dtoa timedemo workaround

The 582-read FPGA capture proves execution is trapped in Quake's x87 fractional
digit loop (`runtime 0x548d1`).  This image replaces only that six-byte
backedge with a 32-digit bound, retains the no-render/heap-scan workload, makes
only `Con_DebugLog` return, and writes a persistent 969 witness before the
original timedemo-result print.  It is hash- and context-locked; no RTL changes
are made.

The triggering capture is preserved in
`../quake_heapscan_loggerret_marker/fpga_582_capture.log`: all active Quake
EIPs fall in the formatter loop around `0x548d1`, whose original six-byte
`jne 0x5484e` is the exact patched context.  The board trial uses executable
SHA-256 `431fd51942d49d7bf243fcef23975be7da0b3d74a5a14c510e310b0f098e8a1c`
and clean VHD SHA-256
`cb3d96119de88d4629d40b2a162dee6bfb2149e01b1c5d6d5f1542aee9f2a49a`.

The logger-enabled QEMU oracle twin did not reach its result file before the
interactive runner's 30-second process limit, so QEMU completion remains
unproven.  This is explicitly a controlled FPGA trial, not a validated pass.

## FPGA result: rejected

The board passed the normal early read sequence but entered a sustained
FreeDOS timer/idle loop at 450 reads before reaching the patched `0x548d1`
site.  The PC ring alternated `05F7:*` and `0070:*`, rather than Quake's
`00A7:548*` formatter code.  The persistent marker was absent.  The guard is
therefore rejected: allowing 32 generated digits can corrupt a caller buffer
on an earlier formatter use.  Preserved log SHA-256:
`5196cbd4ac99f6958f8b220c16466e51b0a78a3ecfb533558f0f072b5531c523`.

Any successor must use the captured call-site's actual format/buffer contract
or repair the underlying x87 non-convergence; a generic digit cap is not safe.
