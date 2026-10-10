# Completed simulator disk writes — October 10, 2026

The PS stdio shim could acknowledge a write while its final bytes remained in
libc's buffer. An independent live FAT observer could therefore miss a completed
guest update until another seek or file close. Buffered writes to `/dev/full`
also incorrectly reported success. This is a host simulation bug, not a CPU
performance fix.

`FileWriteAdv` now requires a complete `fwrite` **and successful `fflush`** before
reporting success; `FileWriteSec` uses the same path. This applies to all guests
and write sizes, without adding guest clocks or modifying RTL. It guarantees
visibility to other host readers, not power-loss durability (`fsync`). The ATA
caller's handling of failed writes is a separate, unresolved issue.

## Closed regression

`test_disk_write_visibility.cpp` links the actual PS shim. It tests 18 writes
(1, 511, 512, 513, 4096 and 8192 bytes at three offsets) through an independent
descriptor **before closing the writer**, then checks final bytes and a
neighboring untouched byte. Two `/dev/full` cases check deferred errors.

| Actual implementation | Stale live reads | Falsely successful errors | Native exit |
|---|---:|---:|---:|
| Frozen control `623dcb7e…` | 18/18 | 2/2 | 1 |
| Fixed shim | 0/18 | 0/2 | 0 |

Evidence: `/home/yukidama/external/tmp/ventium-stdio-visibility.WtUyV8Ue/checked/`.
The runner records source pins, compiler commands and actual native exits.
Reproduce with a **new** output directory:

```sh
TMPDIR=/home/yukidama/external/tmp python3 -B ao486-sim/ven/run_disk_write_visibility.py \
  --control-shim /home/yukidama/external/tmp/ventium-code-payload-soc.1oJrvfzN/source/ao486-sim/ps/ps_shim.cpp \
  --model-dir /home/yukidama/external/tmp/ventium-code-payload-soc.1oJrvfzN/obj1-speed-q16-parentpolicy \
  --out /home/yukidama/external/tmp/stdio-visibility-new-run
```

Two superseded cold Quake controls were gracefully stopped after checking their
native identity. Their closed disks independently passed the unchanged timedemo
checker: 969 frames in 138.4 seconds (`652de481`, 7.0 FPS) and 128.1 seconds
(`86731249`, 7.6 FPS), at modeled 40 MHz. Both exited normally, with logs,
captures and media preserved. They had not triggered the live completion
observer. Buffering is a reproduced explanation for missed live writes; no
pre-stop FAT snapshot proves it was the specific cause in those two runs.
These are older Quake component passes, not current-candidate or full-suite passes.

The already-running `4fb1bdae` suite binaries remain frozen and **do not contain
this host repair**. No running input was replaced. Their gameplay IPC remains
unmeasured. The latest verified older baseline is **0.46555093 U+V event IPC**
on `bfb867f7`, cycles 4,300,065,237–4,400,065,237; this host-only test measures no IPC.
