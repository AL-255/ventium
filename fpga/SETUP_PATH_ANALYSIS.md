# Read-only synthesized-path analysis

`analyze_setup_paths.py` reads an existing native Vivado report; it does not
launch tools, modify constraints, or change a checkpoint. It admits only
full-clock-expanded, same-clock, single-period synthesized setup paths.
It checks every data-path row against cumulative arrival time, separates
clock insertion from data delay, hashes the input, groups bitwise endpoints,
and reports an **unplaced estimate**, never routed or measured frequency.
Unknown/truncated formats, mixed clocks, hold reports, multicycle requirements,
ambiguous markers and inconsistent delay totals fail visibly.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 fpga/analyze_setup_paths.py \
  /path/to/core_setup_unplaced_estimate.rpt \
  --marker 'lookup=/mc_lookup_next$' \
  --marker 'wait=/pipe_mem_wait$' \
  --marker 'fp=/fp_shared_direct$'
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s fpga -p test_analyze_setup_paths.py -v
```

Output is JSON on stdout. `--include-rows` retains every parsed cell/net row.
Markers refer to actual netlist names, **not inferred RTL-module ownership**:
Vivado's rebuilt hierarchy often contains shared logic from neighboring modules.
Absent markers produce no cut; the explicit endpoint remainder is always kept.
The estimate uses `1000 / (period - worst_slack)`, including the reported
clock/setup effects. It is not simply `1000 / data_path_delay`.

## Closed parent: why the FP change alone is not a 40 MHz claim

The source-matched [L1 capture candidate](L1_LEGACY_CAPTURE_CUT.md) native report
is `ventium-l1-capture-clock.c0os0diB/core_setup_unplaced_estimate.rpt` under
external scratch. All 30 reported worst paths terminate at bits of the same
FPU bank-enable family, not 30 independent bottlenecks. The parser reproduces
**22.49162187 MHz**, −19.461 ns slack at 25 ns, and the 44.164 ns data path.

| Actual named boundary | Data delay since source clock pin |
| --- | ---: |
| `ic_front_bytes[0]` | 14.020 ns |
| `mc_query_ea3[0]` | 19.596 ns |
| `mc_lookup_next` | 28.930 ns |
| L1 `hit` | 30.945 ns |
| `l1_store_pair_ready` | 32.352 ns |
| `core_store_pair_req` | 33.781 ns |
| `pipe_mem_wait` | 39.397 ns |
| `fp_shared_direct` | 40.311 ns |
| FPU bank CE endpoint | 44.164 ns |

These are boundaries on **one mapped static path**, not independent operation
latencies or a claim that all dependencies are dynamically sensitizable.
The [FP-only admission cut](FP_EXEC_NOMEM_CUT.md) removes an unnecessary ACK
dependency from FP execution. Even if that succeeds, the prefix of the old
path already exceeds 25 ns before L1 lookup completes. The next native report
must identify surviving register-to-register paths; do not subtract the old
tail and assert that the design meets 40 MHz, or waive it as a false path.

Five parser tests pass, including twelve malformed/unsupported-input subcases.
The real parent report parses in full, and its derived estimate matches the
independent native audit. This tool is diagnostic evidence only; no processor,
standard-suite, timing-closure or FPGA acceptance is implied.
