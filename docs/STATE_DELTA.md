# Complete Retained-RTL Cycle-Delta Recorder (`STATE_DELTA`)

Specification and usage contract for the lossless Verilator retained-state cycle recorder (`ao486-sim/ven/state_delta.h`, `tools/build_state_delta.py`, `tools/state_delta_read.py`, `tools/state_delta_analyze.cpp`).

> **Status (Nov 2026):** Host-only Verilator analysis facility for `ao486-sim` full-PC models (used for million-cycle IPC and cache state-delta diagnostics). Current board-qualified physical Quake gameplay IPC baseline is **`0.515778001` total U+V** (`0.397847833` primary/U-only) on RK-XCZU15EG-F image **`c0e3fe43`** across cycles `28,696,827,616–32,989,404,795`. On the maintainer host, always direct `TMPDIR` and scratch outputs under `/home/yukidama/external/tmp`.

---

## 1. Scope & Sampling Contract

This recorder captures a **complete named dump of retained numeric Verilator RTL model state** on every clock tick—not a selected-signal trace and not a `.vtrace` stream:

- **Included:** Top ports, registers, retained combinational nets/temporaries, packed/unpacked arrays, L1 I/D cache arrays/tags/valid/LRU state, TLBs, `fp_shared` / FPU state, PC/AT peripherals, VGA RAM, and ROM tables. Every root save-state serializer field is verified covered; unknown declarations or uncovered stateful child cells fail generation loudly (`ven_state_fields.audit.json`).
- **Excluded:** Eliminated Verilator nets, C++ function-local temporaries, Verilator runtime/scheduler pointers, external host DDR backing arrays, and disk image files. Native checkpoints + disk bundles remain the replay authority.
- **Sampling Boundary:** One full baseline is recorded immediately before the first captured tick; each subsequent record is sampled after rising-edge evaluations, DDR service, and final settling with `main_time` incremented (including ticks nested in bus operations, zero subsampling, zero extra `eval()` calls).

---

## 2. Building the Relinked Profiler (Without Recompiling RTL)

Work on a **private copy** of an already compiled, savable `ao486-sim` object directory (never overwrite canonical binaries or use symlinks):

```sh
TMPDIR=/home/yukidama/external/tmp \
make -C ao486-sim ven-state-profiler VEN_OBJDIR=/home/yukidama/external/tmp/<private_obj_dir>
```

`tools/build_state_delta.py` regenerates the field include for that exact elaboration, compiles `sim_ven.cpp` with `-DVEN_STATE_DELTA_HOST`, relinks with `-lz`, verifies `Vsystem__ALL.a` and generated model headers remain hash-identical before/after, and writes `ven_state_relink.json`.

---

## 3. Simulator Flags & Validated Capture Driver

| Flag | Meaning |
| --- | --- |
| `--ven-delta-out PATH.gz` | Output path (refuses overwrite). |
| `--ven-delta-start N` | Earliest absolute cycle (arms after init/restore). |
| `--ven-delta-cycles N` | Consecutive cycles to capture (`1..1,000,000`; default `1,000,000`). |

Stopping before `N` cycles fails the run; valid completion requires both the `ENDDLT01` terminal image footer and `STATE-DELTA-OK`.

For reproducible gameplay-window capture (`tools/run_state_delta_capture.py`), validate `ven_state_relink.json`, check a 1,000-cycle pilot against the frozen reference executable (`host_relink_check.json`), and verify byte-identical final native snapshots and disks between recorder-OFF and recorder-ON runs (`--snapshot-version 4 --mouse` when PS/2 mouse state is present). Keep `TMPDIR=/home/yukidama/external/tmp` with sufficient free disk space for four private disk/snapshot copies.

Unit/host tests:
- `ao486-sim/ven/test_state_delta.cpp` + `tools/test_state_delta.py` (binary stream round-trip, array tails, corruption/truncation rejection).
- `python3 -B tools/test_build_state_delta.py` & `python3 -B tools/test_state_delta_capture.py`.

---

## 4. Reading & Analyzing Captures

- **Python schema & stream reader:**
  ```sh
  python3 -B tools/state_delta_read.py TRACE.gz --schema
  ```
  `Reader.records()` reconstructs and validates every mutable field on every cycle.
- **Fast C++ million-cycle analyzer:** Compile `tools/state_delta_analyze.cpp` (`g++ -std=c++17 -O2 -Wall -Wextra -Werror ... -lz` under `tools/build_scope.sh`) and run `analyze TRACE.gz OUTPUT_PREFIX [fpd_layout.tsv]`, where `fpd_layout.tsv` is produced from the matching model's `ventium_decode_pkg.sv` via `python3 -B tools/fpd_layout.py`. Exports state/hold/frontend/cache-backend distributions, per-field activity, `.commit_observations.bin`, and U/V opportunity diagnostics (`tools/compare_state_delta_commits.py` compares commit-group integer boundaries).

---

## 5. On-Disk Binary Format (`VENDLT01`, Gzip Level 1, Little-Endian)

1. **Header:** `"VENDLT01"` (8 B), `field_count` (`u32`), `baseline_cycle` (`u64`), `record_count` (`u64`), `state_size` (`u32`).
2. **Schema Table:** Per field: `name_len` (`u32`) + UTF-8 `name`, `type_len` (`u32`) + UTF-8 `type`, `byte_size` (`u32`). Cumulative packed offsets with no C++ struct padding.
3. **Baseline Image:** Full initial packed state (`state_size` bytes).
4. **Cycle Delta Records (`record_count` entries):** `abs_cycle` (`u64`), `changed_block_count` (`u32`), followed by strictly increasing 16-byte aligned blocks: `aligned_offset` (`u32`), `changed_mask` (`u16`), and replacement bytes in set-bit order. Unchanged cycles still emit a 0-block header.
5. **Footer:** `"ENDDLT01"` (8 B), `completed_count` (`u64`), and an independently sampled full terminal state (`state_size` bytes) verified byte-for-byte against the reconstructed stream.
