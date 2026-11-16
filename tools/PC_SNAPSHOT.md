# Passive Retired-PC Native Checkpoints (`tools/retire_pc_snapshot.h`)

The full-PC `ao486sim_ven` harness can trigger a native Verilator checkpoint
from an actual `vtm_retire*` callback without modifying RTL, re-evaluating the
model, or injecting guest state.

> **Diagnostic Scope & Physical Baseline (`c0e3fe43`, 2026-11-14):** Retired-PC
> checkpoints are simulator localization/profiling aids, never benchmark
> shortcuts or substitutes for cold-boot standard-suite gates. Current verified
> physical DOS Quake gameplay IPC on **RK-XCZU15EG-F** release image
> **`c0e3fe43`** (`161` defines, `40.264133 MHz` STA-signed-off,
> `cycle_mode = 1'b1`) is **`0.515778001` total U+V** (`0.397847833`
> primary/U-only) across cycles **`28,696,827,616–32,989,404,795`**.

---

## Building & Invoking Retired-PC Saves

Use a private variant `ao486sim_ven` built against the matching generated model
ABI. To relink an already-verilated private `OBJDIR` with updated host helpers
while verifying unchanged RTL archive hashes, run through `tools/build_scope.sh`
with `TMPDIR` on real writable scratch storage (`/home/yukidama/external/tmp`,
never a repo symlink):

```sh
TMPDIR=/home/yukidama/external/tmp \
  tools/build_scope.sh -- python3 -B tools/build_state_delta.py \
  /home/yukidama/external/tmp/ventium-pc-sim/obj_dir_ven_cand
```

Pass the trigger flags on a **cold** `ao486sim_ven` run (against a private disk
copy under `/home/yukidama/external/tmp`):

```text
--snapshot-v4 --save-file /home/yukidama/external/tmp/private-run/trigger.snap
--save-at-retired-pc 0028:C002A7BC --save-stop
```

- **Target Address (`CS:OFFSET`):** Hexadecimal **post-commit `CS` selector :
  fetched instruction offset** (not a linear address; far control transfers may
  update `CS` before callback observation).
- **Optional Occurrence Filters (decimal or `0x` hex):**
  - `--save-pc-occurrence N`: Trigger on match `1..1,000,000` (default `1`).
  - `--save-pc-after-retire N`: Count matches strictly after harness retirement
    ordinal `N` (default `0`).
- **Observation & Settled Save Point:** Observes both U and V retirement
  callbacks (retaining a 256-entry pre-trigger retirement ring) and serializes at
  the harness's normal settled checkpoint boundary after PS polling. Logs
  `PC-SNAPSHOT` (trigger vs. settled save cycle/retire delta), `PC-HISTORY`, and
  `PC-TRIGGER`. Because serialization occurs post-commit, this is a
  **post-instruction** checkpoint, not pre-execution state or an architectural
  `.vtrace` (emit `.vtrace` exclusively via `verif/diff/tracefmt.py`).

---

## Safety & Invariants

- **Cold Runs Only:** Incompatible with `--restore`, cycle/periodic save
  triggers, `--ven-stop-retire`, RTL breakpoints, or `--rmtest`. Requires
  `--snapshot-v3` or `--snapshot-v4` (`--mouse` requires `--snapshot-v4`).
- **Path & Descriptor Integrity:** `--save-file` must name a nonexistent file
  below existing, non-symlink directory ancestors (`..` traversal, symlinks, and
  hardlinks are rejected). The file is reserved with `O_CREAT | O_EXCL` and
  reopened via `/proc/self/fd` so path replacement cannot truncate another file.
- **Closed Failure Semantics:** Unreached targets or save errors exit non-zero
  (an empty reserved file from an unreached PC is never a valid snapshot). Always
  preserve the stopped run's flushed private disk, ROMs, binary, and SHA-256
  receipts together (`tools/checkpoint_bundle.py`).

## Host Unit Tests

```sh
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
  python3 -B tools/test_retire_pc_snapshot.py
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
  python3 -B tools/test_retire_pc_snapshot_dpi.py
```
