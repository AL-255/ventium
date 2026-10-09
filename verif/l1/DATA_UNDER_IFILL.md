# Registered data hits during instruction fills — October 9

Private, default-off `VEN_L1D_DATA_UNDER_IFILL`. Not a full-suite or FPGA pass.
Verified gameplay remains **0.38588696 total U+V IPC**, XPM model `50f37229`,
cycles **1.2B–1.3B**; this predates pop-drain, word reuse, tag RAM and this change.
Earlier complete **direct-memory** CoreMark is **2.10736/2.11041 CM/MHz**;
neither target has been measured for this candidate on the board.

## Cause and fix

`fill_independent_hit` previously rejected all requests while `code_fill_q`
was set. That instruction fill writes the separate `code_line_q` registers,
not D-data banks, D tags or their terminal LRU entry. Blocking an already
resident D read, even in the same physical set, unnecessarily holds execution
behind the remaining instruction beats.

The private transformation changes only that admission predicate. An I fill
may overlap a contained D hit using the existing **registered** capture and
response owner. A D fill retains its original different-set restriction.
No new port, buffer, capacity, bypass acknowledgement or guest-specific rule
is added. Stores, cross-line reads, misses and uncacheable reads retain their
old path. Resident priming admission is deliberately unchanged. Snoops, flush,
reset, current validity and full backing-transaction ownership remain binding.

## Closed checks

Root: `external/tmp/ventium-data-under-ifill.wiE5Rd33`, source `candidate`.

- Three transformation/scope guards pass.
- `leaf-r1/closed.json`: parent/off/on × randomized seeds 1/7/101 pass the
  existing 150-request ownership corpus, 51 instruction-word cases and **659
  new cases** per run. All eight held I-fill phases, same/different sets, every
  byte offset and aligned dword are covered. **640 resident reads per seed
  complete in two clocks while the I fill remains paused**; the controls
  cannot complete until it drains. No asynchronous SRAM response is admitted.
- Invalidations on capture/response edges, reset, all eight simultaneous
  backing-beat edges, final I publication versus same-set D LRU, and unsafe
  miss/store/MMIO/crossing/same-set-D-fill forms are checked. Backing address,
  beat count and payload are independently checked, without forced DUT state.
- Two freshly built mutants are rejected by real native assertions: wrongly
  admitting same-set hits during D fills, and returning I bytes for a D owner.
  The positive binary is pinned unchanged; neither mutant is selected.
- Board `bf7b3f51` and full-address user `672703e2` build under the six structural
  hard-error classes, with private model-local host objects/header dependencies.
- `system-matrix/result.json`: **76 cases** pass complete pinned-QEMU
  architectural comparisons, with functional/cycle executions and unchanged
  inputs. Complete functional traces match the parent. All 38 cycle comparisons
  are non-regressing; `pdualstore` saves 3/16 clocks at latency 0/7 and
  `pperm_warm_ro` saves 5/17. The other cases are cycle-identical.
- `boundaries/result.json`: all **64** instruction-offset/latency cases pass,
  including their real V-retirement witnesses.
- Canonical generic gate remains **FAIL**, native 2: 7/108 functional passes,
  101 terminal-record length mismatches and the same four hard cycle failures.
  No oracle, exception mask or timing band was changed.

These local savings do **not** establish a gameplay gain. A subsequent passive
sample of the unchanged XPM model still finds substantial memory/FP overhead;
the new candidate's full standard suite, physical implementation and 0.48 IPC
qualification remain open. No new bitstream or running guest was modified.

## Reproduce

```sh
TMPDIR=/home/yukidama/external/tmp python3 -B verif/l1/test_data_under_ifill.py
python3 -B verif/l1/prepare_data_under_ifill.py --source TAG_RAM_SOURCE --out FRESH_SOURCE
# Complete parent profile includes CODE_WORD_REUSE and TAG_LUTRAM.
# Execute the following inside tools/build_scope.sh's ipc_parallel32 envelope:
python3 -B verif/l1/run_data_under_ifill.py \
  --control-source TAG_RAM_SOURCE --candidate-source FRESH_SOURCE \
  --profile COMPLETE_PARENT_DEFINES --out FRESH_LEAF_OUTPUT
```

Closed compiler PCH reclamation after the matrices recovered **1,236,904,692
bytes** across 14 files. All native models, source and evidence remain; PCH
files can be regenerated. Receipt:
`external/tmp/ventium-ifill-cache-reclaim.NdCckbOT/closed.json`.
