# Data-segment size without fetch-decode feedback

October 13, 2026. **Private candidate; not synthesized or deployed.**
The parent has an independently audited **35.856430851 MHz unplaced estimate**,
still below the required 40 MHz. No frequency or gameplay gain is claimed for
this change.

## Structural change

The parent's 93-level worst path crosses instruction-fetch demand-size decode
and the data-segment limit checker before reaching cache/store-pair admission,
AXI ACK and a register input. `S_FETCH` is unconditionally classified as code,
so the data fault cannot consume its size. Nevertheless, sharing the generic
`cur_size` mux puts that late decoded size in the data-comparator cone.

`prepare_data_size.py` makes one hash-checked `core.sv` change:

- Preserve the single existing per-state access descriptor generator.
- Take `cur_data_size` before the `S_FETCH`-only demand-size override.
- Apply that override afterwards, leaving the actual `cur_size` bus/fragment
  descriptor unchanged in every state.
- Use the earlier size only in the two data-segment extent comparisons,
  retaining the whole-object overrides for x87 environments and other accesses.

The original canonical size, fetch-limit checks, data/code classification,
fault qualification, page probes, requests and sequential state are unchanged.
An assertion requires exact extent equality whenever `cur_is_d` is true.
There is no extra cycle, queue, RAM port, feature switch or timing exception.
Root RTL and the running full-PC model are untouched.

This removes a source-level dependency; Vivado may still refactor or share
logic, and the separate real fetch-limit path remains. Only a matched new
synthesis can establish the effect on frequency and area.

## Closed checks

| Check | Result | Scope |
| --- | --- | --- |
| Recipe tests | 4 pass | Exact reversible delta; all other size assignments, fetch checks and classification retained; drift/reapplication rejected |
| Symbolic data-owner equivalence | UNSAT for disagreement | All binary beat sizes, fetch sizes and 8-bit object overrides under the actual fetch-excludes-data premise; not whole-core sequential proof |
| Missing exclusion negative proof | SAT | Shows why the cofactor cannot be used for a fetch consumer |
| Source-derived native leaf | 362,144 checks pass | Actual state enum, classification, extent function and new tap; unchanged non-fetch size arms abstracted as arbitrary size |
| Leaf coverage | 352,910 data owners; 650 differing inactive fetch extents; 173,128 large-object overrides | Directed state/width sweep plus deterministic simulator random vectors |
| Negative RTL variants | All 3 fail | Fixed dword data width, lost fetch bus width, lost whole-object override |
| Full-core build | Native exit 0, 20.82 s | 195 sources, exactly one changed; 152 UV-fast definitions; explicit board `AXI_LINE_REPLAY=0`; private matching host object/header |
| Fetch-boundary differential | 22/22 pass | Full architectural QEMU comparison, `--cycle-func --l1-axi`, AXI latency 7; required fault frames/retries and actual backing activity |

The leaf proof is two-state, not arbitrary X/Z equivalence. Existing non-fatal
testbench style/width warnings remain visible; all six hard structural classes
are enabled. The first fetch launcher rejected a symlink-spelled output path
before creating a run. The second uses its canonical path without changing a
guard, fixture or checker; the failed launch is retained separately.

The unmodified canonical `make verify` and the separately qualified private
QEMU functional corpus are running. `run_data_size_checks.py` binds the exact
model and changes only explicit path/model identities. Canonical cycle replay
uses the already audited **single-fill** parent traces, not the earlier
double-fill baseline. No record, mask, golden, comparator or timing band is
changed. The canonical gate still needs an actual new result; the parent's
known failures are not waived by the leaf or boundary passes.

## Reproduction and remaining work

Evidence root: `/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X`.

| Artifact | SHA-256 |
| --- | --- |
| `leaf-r1/closed.json` | `5fffbdcd021240d496ff7241c50bf8f1e0506e97ce7a5e5bb2e82612fb396277` |
| `core-r1/build-closed.json` | `5d05a324dd2a3aa2e617f251fb8470004f15979e7bc25a65d27c70071c17f63d` |
| `core-r1/obj/tb_ventium` | `fef9f3b6ad52a1dbf86ec19c8e6eb50dd79d3b4aa9f3601e35797cb93a62a041` |
| `core-r1/candidate/rtl/core/core.sv` | `6c020b3c171fb422756a7874fb48cd32a683953ff5b95d44b708be3a7fa08b1c` |

Closed owners: `ventium-data-size-leaf-oct13-r1.service`,
`ventium-data-size-core-oct13-r1.service`, and
`ventium-data-size-fetch-oct13-r2.service`; each has MainPID 0 / exit 0.
Live checks: `ventium-data-size-canonical-oct13-r1.service` and
`ventium-data-size-func-oct13-r1.service`. Native completion and independent
artifact/source checks are required before advancing this candidate.

Still required: broader regression closure, source-matched full-PC transfer,
short CoreMark controls, hardware-profile lint, >=40 MHz synthesized Fmax,
routed timing and physical FPGA standard-suite acceptance. The parent's cold
Win95 and Quake jobs remain running without restart; their results cannot
qualify this new candidate. No Vivado build or board programming was launched
for this change.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. It predates this candidate and is not FPGA or
Doom performance.
