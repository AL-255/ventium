# Heap-scan logger-ret completion marker

This is the narrowest PIO-write workaround.  It leaves Quake's console setup,
conditional logger branch, argument preparation, and formatting calls intact.
Only the entry instruction of `Con_DebugLog` becomes `ret`, preventing its
`fopen`/`fwrite`/`fclose` DOS file traffic.  The final timedemo-result wrapper
stores a persistent `969` witness at `DS:0x90b48` immediately before calling
the original result printer.

## FPGA result (2026-08-24)

The exact patched executable (`SHA-256
71985ca618021a90172723c563fb30c3a7a79d4880271fe513b1bc46b7462943`) was
booted from the clean workload image (`SHA-256
6dcefb3f21a60cc3855e05c76316a95695a6c5921955970fba2019ce11a96e02`) on
the unmodified FPGA image (`IDENT=a0486501`).  It preserved the normal read
trajectory through the previous CPU-only periods and reached 582 completed
IDE reads.  It then reproduced the established failure: no further request was
issued for at least 18 s while the device reported a completed read
(`io_done=1`, `cmd=20`, `status=5e`, `rdcnt=50944`).  The persistent 969 marker
was not observed, so this is not a successful timedemo result.

`fpga_582_retry.log` is the preserved board log (SHA-256
`b1365c38ad762ec7a8cc511caaafc5d15b5df72c0e7ffdf926feb432859e1720`).  The
board debug sampler recorded a live loop with `cs:eip=26d9:...` and advancing
memory fetches, rather than a halted CPU.  The empty `fpga_582_retry_marker.log`
is also evidence that the result wrapper was never reached.

This falsifies the hypothesis that the terminal condebug PIO write caused the
582-read failure.  The appropriate RTL repair remains a minimal, cycle-safe
IDE completion handshake fix: latch exactly one completion event and classify
it with the request's latched terminal/non-terminal metadata; update status,
DRQ and completion request atomically from that event.  Do not mask it with a
delay, polling loop, or broad logging suppression, since those perturb the
guest schedule and did not cure the retry.
