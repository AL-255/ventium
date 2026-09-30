# Passive retired-PC native checkpoints

The full-PC `ao486sim_ven` harness can request a checkpoint from an actual
retirement callback, without changing RTL, evaluating the model again, or
injecting guest input. This is a diagnostic feature, not a benchmark shortcut
or proof of standard-suite completion.

Use an executable built with the matching generated model and native ABI.
For an existing compiled model, `tools/build_state_delta.py OBJDIR` performs a
guarded host-only relink and verifies unchanged generated model/archive hashes.
It must run through `tools/build_scope.sh` with scratch on a real writable
filesystem, not the repository's external `tmp` symlink.

Add these options to the usual **cold** full-PC invocation:

```text
--snapshot-v4 --save-file /absolute/private/run/new.snap
--save-at-retired-pc 0028:C002A7BC --save-stop
```

The address is hexadecimal **post-commit CS : fetched instruction offset**,
not a linear address. Transfers can change the selector before observation.
The example matches an ordinary protected-mode instruction; it does not
recognize or special-case any guest in the helper.

Optional filters:

- `--save-pc-occurrence N`: select occurrence 1–1,000,000 (default 1).
- `--save-pc-after-retire N`: count matches only after this absolute harness
  retirement number, strictly greater than N (default 0). Decimal and `0x`
  numbers are accepted for these filters.

Both U and V callbacks are observed. The first selected callback remains the
trigger even if another instruction retires on the same edge. A bounded
256-retirement history precedes that callback.

The native save occurs at the harness's normal **settled checkpoint point**,
after any existing PS polling. `PC-SNAPSHOT` reports exact trigger and save
cycles/retirements and their overshoot; `PC-HISTORY` and `PC-TRIGGER` report
the callback registers. This is a **post-instruction** checkpoint, not exact
pre-execution state or an architectural `.vtrace`.

Restrictions and safety:

- Cold runs only; no `--restore`, cycle/periodic save trigger, retirement stop,
  RTL breakpoint or RM-test mode. V3 or V4 is required; connected mouse needs V4.
- The save path must be new, with existing non-symlink directory ancestors;
  existing files, symlinks, hardlinks and `..` traversal are rejected.
- The output is exclusively reserved, and serialization reopens the held
  inode through `/proc/self/fd`. A replaced pathname cannot cause the writer
  to truncate a foreign target. Identity/link/extent changes fail closed.
  Use a private directory; ancestor traversal is not a hostile-user security
  boundary.
- Unreached targets, missing/stale callbacks or save/report failures return
  failure rather than checkpoint success. An unreached target may leave an
  empty reservation; it is not a usable snapshot.
- Preserve the **closed paired guest disk**, native image, ROMs, executable,
  settings and hashes before any restore. Never use a live acceptance disk or
  mix generated model ABIs. A saved file alone is not restore qualification.

Bounded host tests (no RTL/DUT run):

```text
python3 -B tools/test_retire_pc_snapshot.py
python3 -B tools/test_retire_pc_snapshot_dpi.py
```

The second test compiles the actual production DPI callback. Host tests do not
replace actual native/disk noninterference pilots or differential gates.
