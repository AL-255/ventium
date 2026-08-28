# Quake heap-scan completion marker

This binary-only FPGA diagnostic is based on the QEMU-validated no-render,
second-heap-scan workload.  It disables boot-time `-condebug`, then stores the
literal `969` at Quake data address `DS:0x90b40` immediately before the
existing timedemo-result `Con_Printf` invocation.

The value is a completion witness, not a synthetic frame counter: the patched
instruction is reached only after Quake computes and reports the fixed
969-frame timedemo result.  The wrapper then calls the original printer with
the original variadic arguments.  Pinned QEMU must still write its normal
result record; on FPGA the marker is read before the known-failing IDE PIO
write, so it cleanly separates timedemo execution from that I/O defect.

`make_patch.py` hash-locks the source executable and validates both changed
instruction contexts.  The deployment VHD is made by replacing only
`\\QUAKE\\QUAKE.EXE` in a copy of the clean heap-scan VHD.

## Validation and FPGA result (2026-08-24)

The executable is `4e14a4c8cc92b39b96a02ad3893cce9e7c9e90538b8e7a06a6f09d46164356f2`.
The clean deployment image is
`624f047a7c9fb17859a6948500b542f4d8d05dd402042c273a87760dee258091`.
Pinned QEMU Pentium completed the unmodified result printer and produced:

```text
969 frames 2.5 seconds 381.1 fps
```

Its `QCONSOLE.LOG` hash is
`c142f646df570224cde73d1f02d886a298dd5679f3b98a8893695369b7b56f65`.

The FPGA run on `IDENT=a0486501` booted normally and passed the former
584-read boundary, but then remained in an active real-mode BIOS/IO.SYS disk
retry path at 582 reads.  The IDE device was idle and complete
(`cmd=20`, `io_done=1`, `rdcnt=50944`), so this is not the later PIO-write
deadlock.  The read-only marker watcher timed out after 900 seconds without
the 969 witness.  The on-die PC ring confirms repeated `0070:018x` ->
`f000:e82x` -> `f000:44xx/48xx` execution, identifying the remaining failure
as an INT 13h retry loop.

The repair target is the IDE completion ownership in
`3rd-party/ao486_MiSTer/rtl/soc/ide.v:159-192`: completion currently derives
`status` and `request` directly from level `io_done & drq` while `last_read`
is independently cleared by the same condition.  The fix should make a
one-shot, per-block completion event that latches the terminal/non-terminal
classification atomically with the daemon's register-5 publication.  That
event must emit exactly one of `RDY/no-request` (terminal) or request `5`
(another block), then clear only after the next management handoff.  Preserve
the existing register-5 priority and verify back-to-back 1-sector and
multi-sector reads plus PIO writes; simply delaying the daemon or forcing
`last_read` high would hide the race and corrupt multi-sector transfers.

Preserved evidence:

- `fpga_marker_900s.log` — SHA-256 `4b6b8c761eca3110e88b49073174f34b95df1bab962dd056d606f9dfda8dd7c3`
- `fpga_marker_result.log` — SHA-256 `d2d1e631d51381fd682e1e3a4c95bcc2dcde27224951544bec766406b72f8bda`
- `fpga_marker_ring.log` — SHA-256 `036409a3d22c1a42daa91233cea9bcc469bb9ae0647c36d402e0a53a27d7571e`
