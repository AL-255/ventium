# `REP` String Fetch, Continuation & Store-Streaming Gates (`verif/rep_sfetch/`)

`verif/rep_sfetch/` verifies instruction-fetch avoidance, element-boundary continuation, cacheable store streaming, self-modifying-code (SMC) snoop recovery, and precise fault/interrupt/SMI/debug priority for `REP STOS` and `REP MOVS` string operations.

## Deployed Hardware (`c0e3fe43` on `main`) vs Experimental Flags

- **Deployed on `main` (`c0e3fe43`, 161 defines):**
  - **`VEN_REP_STOS_STREAM`:** Pipelined cacheable `REP STOS` store streaming is active in the board-qualified 40 MHz image, contributing to `c0e3fe43`'s **`0.515778001` total U+V gameplay IPC** (`0.397847833` primary/U-only) across interior Quake gameplay cycles `28,696,827,616–32,989,404,795` (`8.0 FPS`).
  - **IPC Counter Accounting:** Hardware retirement counters (`retire_n`) count individual retired `REP` string elements alongside macroinstructions.
- **Experimental `REP MOVS` & No-Uop Continuation (`experimental/uv-fast-ipc-apr`, default-off):**
  - **`VEN_REP_MOVS_CONT`:** Retains the decoded `F3 A5` (`REP MOVSD`) command token across non-final element store ACKs, re-entering `S_LOAD` from `S_PIPE` without redundant slow fetch/decode (`7 → 5` warm clocks/element).
  - **`VEN_REP_MOVS_LOAD_FUSE`:** Prepares destination address, rollback snapshot, and `ESI`/`EDI`/`ECX` updates on final `S_LOAD` ACK to enter `S_STORE` directly (`5 → 4` warm clocks/element; excluded on split-page `xp_cross` or faults).
  - **`VEN_REP_MOVS_STREAM`:** Cancellable next-source owner (`rep_movs_stream_pending_q`) entering `S_LOAD` on final `S_STORE` ACK (`4 → 3` warm clocks/element) while never issuing a younger source read before the older destination store ACK.
  - **`VEN_REP_CONT_NO_UOP` (`prepare_cont_no_uop.py`):** Decouples `rep_stos_cont_profile` admission from `VEN_UOP_SFETCH` so `cycle_mode=1` raw-decode builds can exercise `REP` continuation without enabling the uop cache.

## Gate Scripts & Coverage Matrix

| Script | Verified Architectural & Microarchitectural Invariants |
| --- | --- |
| `run-rep-sfetch-gate.sh` | Warm/cold `REP STOS` & `REP MOVSD` element cadence (`REP_MOVS_CONT=1`, `REP_MOVS_LOAD_FUSE=1`), zero timing-debt admission, and full cycle-functional state parity vs pinned QEMU (`64` REP element states). |
| `run-prepsfetch-gate.sh` | System-mode `REP STOS` & `REP MOVSD` destination read-only `#PF` (`CR0.WP=1`), non-present second-page source `#PF` (`MOVS_SOURCE_FAULT=1`), `DR1` data-write `#DB` watchpoints (`MOVS_DEBUG=1`), and `ECX=0` no-access fallback — proving exact `ESI`/`EDI`/`ECX` rollback and retry vs `qemu-system-i386`. |
| `run-movs-cont-corners.py` (`t_movs_cont_corners.s`) | Forward and reverse (`DF=0/1`) overlapping buffer propagation, unaligned cross-page source (`+4093`) and destination (`+4094`) dwords, and zero-count `MOVSD` with unmapped pointers (`454` QEMU-equivalent groups). |
| `run-movs-segment-gate.sh` (`check-movs-segment.py`) | `+define+VEN_SEG_ENFORCE` byte-granular `ES` limit fault (`#GP(0)` on element 2 after element 1 commits), verifying rollback, descriptor repair, and single-decode continuation retry (self-checked against Intel SDM since QEMU omits segment-limit faults). |
| `run-rep-smc-gate.sh` / `run-prepicbp-smc-gate.sh` (`t_rep_smc.s`) | Delayed/unaligned `REP` destination store overwriting the instruction's own 32-byte I-cache line (`MOVSD → STOSD`): sticky executable-invalidation recovery forces fresh 4-word fetch/decode before the next element. |
| `run-prepsmi-gate.sh` | APIC self-SMI arriving on an armed `REP STOS` / `REP MOVSD` continuation boundary: SMI preempts continuation (`divert=1`, `take=0`), writes exact P5 SMRAM `SMBASE+0xFE00` pointers, and `RSM` completes remaining elements cleanly. |
| `run-cont-no-uop.py` / `-irq.py` / `-smi.py` / `-debug.py` | 32-case QEMU system/x87 matrix, 36 held-external-`IRQ`/`INTA` cases, 4 SMI cases, and 18 `dbg_halt_req` pause/resume cases: pending unstarted next-source reads cancel cleanly on IRQ/SMI/halt, while already-started reads finish their element before event delivery (preventing MMIO read replay). |
| `run-movs-stream.py` (`t_movs_stream.s`) | `VEN_REP_MOVS_STREAM` `4 → 3`-clock cadence, `[MOVSSTREAM] ARM`/`CANCEL` witnesses, `DF=0/1` aliases, byte fallback, and full pinned-QEMU post-group state equivalence. |
| `run-icbp-fill-snoop-gate.sh` (`tb_icbp_fill_snoop.sv`) | Standalone I-cache bypass/fill store-snoop invalidation leaf gate. |

## Running Safely

Supply an isolated prebuilt `TB_BIN` (never overwrite `verif/tb/obj_dir/tb_ventium`), pass `--l1-axi` explicitly for L1/AXI models, and place all temporary outputs under `/home/yukidama/external/tmp`:

```sh
TMPDIR=/home/yukidama/external/tmp \
  tools/build_scope.sh -- bash verif/rep_sfetch/run-rep-sfetch-gate.sh
```
