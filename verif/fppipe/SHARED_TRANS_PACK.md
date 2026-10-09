# Same-cycle transcendental packer sharing — October 9

Private resource-reduction proposal, not production RTL or FPGA acceptance.
Current verified gameplay baseline is **0.37026314 total U+V retirement-event
IPC**, posted16 model `3c8779f4`, cycles **1.2–3.0B**. The running combined
dispatch/shared-ALU/raw-prime candidate has no gameplay measurement yet; it does
not contain this additional packer experiment. The 0.48 requirement is open.

## Structural change

`ven_fp_trans` originally invokes `normalize_round_pack` at six disjoint
sequencer consumers: F2 result, atan table selection, atan result, FY result,
FY squared operand and atan squared operand. Each invocation describes a
128-bit normalizing shift, leading-zero count and rounding incrementer.
The private generator selects the original operands before one unchanged
function call. It preserves signed exponent expressions, directed rounding,
sticky-bit insertion and all six destinations. No clock, state, handshake,
arithmetic function or precision policy changes.

This is an area hypothesis, not an assumed gain. A wider input mux can worsen
timing; matched synthesis must measure both area and critical-path delay.
It is not a Quake-specific optimization or an IPC improvement by itself.

## Closed simulation evidence

Root `/home/yukidama/external/tmp/ventium-shared-trans-pack.UbaS9owN` retains
the original renamed control, candidate, oracle, generated fixture, exact
commands, pins, raw logs and `closed.json`. Model SHA-256:
`ac65cadad3e89b7f06c3213b808a9ef8ab8bd6d12b2672594b56569ef69b0b8e`.

- Three seeds each pass **1,640 independent-arithmetic cases** under the
  current 113-define board-core profile. The renamed historical FPATAN oracle
  has its own nonstubbed divider package; DUT defines remain unchanged.
- The unmodified and shared modules receive identical real shared-ALU/SRT
  replies. Every edge compares all outputs, request operands, flags, busy/done,
  sequencer state and internal pack destinations: **776,060 checked clocks**.
  All six consumers are exercised in every seed.
- **144 reset-abort positions per seed** check command cancellation, no stale
  post-reset request, and unchanged cycle-by-cycle behavior. Aborted commands
  are not counted as arithmetic passes.
- Native builds use assertions and all six hard structural-warning classes.
  Every native test exits zero and source pins remain unchanged.
- Six host tests enforce unchanged arithmetic functions, exactly six replaced
  calls and otherwise identical sequential code; missing/duplicate anchors and
  reapplication fail closed. The initial host-test extraction incorrectly
  selected a ROM-read block instead of the sequencer; its corrected boundary
  is explicit and changes no DUT or arithmetic expectation.

This is bounded equivalence evidence, not formal proof, whole-core
differential acceptance or completion of the standard suite. The current
generic gate's previously recorded terminal-observation/cycle-band failures
remain failures; this proposal does not trim traces or relax those checks.

## Hardware measurement

Matched control/candidate out-of-context synthesis **closed successfully** in
one Vivado family, sequentially, with the same xczu15eg-ffvb1156-2-i part, 25 ns clock,
zero I/O-delay assumptions, full profile and `flatten_hierarchy none`.
The guard caps memory at 8 GiB plus 2 GiB swap, reserves disk space and records
native resource/lifecycle evidence. Native exit 0, stable inputs, both native
markers/checkpoints, **527.08 seconds**, peak cgroup RAM **7.052 GiB**, zero
swap and OOM events. The native family has exited. `synthesis-closed.json`
binds invocation `f529a5268cae4221b541ba05e16898e9` and all source inputs.

| Native leaf measurement | Original | Shared packer |
| --- | ---: | ---: |
| CLB LUTs, after synthesis LUT combining | 32,702 | 28,695 |
| Flip-flops | 5,634 | 5,651 |
| CARRY8 | 953 | 877 |
| DSP48E2 | 30 | 30 |
| RAMB36 / RAMB18 | 2 / 1 | 2 / 1 |
| F7 muxes | 77 | 313 |
| Setup WNS at 25 ns | +14.344 ns | +12.800 ns |
| Unplaced setup-path frequency estimate | 93.84 MHz | 81.97 MHz |

This saves **4,007 CLB LUTs (12.25%)** and 76 CARRY8s (7.97%), but costs
17 flip-flops and worsens the estimated critical setup delay. The path moves
from `at_x_sig0_q` to the state-select mux feeding `at_table_index_q`; its
logic depth grows from 45 to 50 levels. These are **unplaced** reports, not
routed timing or a guaranteed frequency. Both leaves retain -0.075 ns
estimated hold slack; neither is a physical timing sign-off. No unconstrained
internal endpoint, missing I/O delay, combinational loop or latch is reported.

Native `LUT*` primitive counts are 37,782 / 33,478, distinct from the combined
CLB LUT counts above; do not mix the two metrics. No unchanged full-board
rebuild or deployment was launched. Whole-board congestion/timing benefit is
still unmeasured. If this state-select path limits implementation, retaining a
dedicated atan-table packer while sharing the other five is a straightforward
same-latency alternative to measure, not an already qualified fix.

## Reproduce

```sh
export TMPDIR=/home/yukidama/external/tmp
# OUT is a fresh experiment root, SOURCE an audited frozen whole-core tree.
python3 -B verif/fppipe/prepare-shared-trans-pack.py \
  --source "$SOURCE/fp_shared/ven_fp_trans.sv" --out "$OUT/candidate"
python3 -B verif/fppipe/run-shared-trans-pack.py \
  --source "$SOURCE" --compile-record /absolute/model/Vventium_top__verFiles.dat \
  --out "$OUT"
python3 -B -m unittest discover -s verif/fppipe -p test_shared_trans_pack.py
```

Use the exclusive Vivado launcher for hardware experiments and preserve the
matched constraints/source closure. Do not infer a whole-board result from
these isolated leaf reports.
