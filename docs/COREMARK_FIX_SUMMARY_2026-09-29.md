# CoreMark fixes and gain attribution — 2026-09-29

## Result and limits

The corrected FIXED32 candidate completes both standard seed datasets with
matching CRCs. At ten iterations, the measured clock-query window gives
**2.100583 CM/MHz (performance)** and **2.103951 CM/MHz (validation)**.
Whole-program CoreMark IPC is **0.758462 / 0.758529**, respectively.
These are **short-run diagnostics, not valid-duration CoreMark scores**:
the invocation does not satisfy CoreMark's ten-second requirement.
The requested valid-duration 2.1 CM/MHz acceptance has therefore not been
established. Work is stopped at the user's request.

The unchanged performance workload retires 3,660,809 instructions. Relative
to the historical raw control, clocks fall from 9,224,125 to 4,826,619:
**47.674% fewer clocks / 91.109% higher modeled throughput**. That control
is not a fully period-qualified P54 implementation. A more useful later
comparison is the real-occupancy raw candidate versus FIXED32: timed clocks
fall from 5,454,222 to 4,760,583, **12.717% fewer / 14.570% higher throughput**.
Do not compare these short direct-memory measurements to an official P54C
score, real FPGA gameplay, or the older valid-duration baseline as though
they were identical benchmark configurations.

Gameplay IPC remains **0.45746656** on frozen build
`3237b6523e8ec4c2db59ae0ef59012de45729b4852dcbdf8b3c20b7bc568d66d`,
cycles **1,150,151,638–1,400,151,638**. It predates these fixes; FIXED32 has
no gameplay measurement.

## Techniques and measured contributions

Each row is a successive, matched ten-iteration performance checkpoint.
“Step throughput gain” is `old clocks / new clocks - 1`.
“Contribution” is that row's saved clocks divided by the total 4,397,506
saved clocks. Contributions sum to 100%; throughput gains do not add.

| Fixing technique | Clocks after change | Clocks saved in step | Step throughput gain | Contribution to total saved clocks |
| --- | ---: | ---: | ---: | ---: |
| Raw-byte frontend bundle: resident tagged bytes, shared reference-decoder capture/direct handoff, short integer/byte operations, real pre-writeback execution occupancy | 5,527,385 | 3,696,740 | 66.880% | 84.064% |
| Transfer-width-correct memory penalties, encoding-extent short dispatch, CL occupancy corrections | 5,151,285 | 376,100 | 7.301% | 8.553% |
| Exact slow-dispatch base/index dependency mask instead of broad register dependence | 5,126,964 | 24,321 | 0.474% | 0.553% |
| Overlap an already-paid prefix D1 clock with the preceding AGI | 5,087,263 | 39,701 | 0.780% | 0.903% |
| Prior-clock AGI history from actual gated GPR write enables, including the documented implicit PUSH/POP ESP exception | 4,936,433 | 150,830 | 3.055% | 3.430% |
| Combined paid `66` register admission/pairing, final-ACK plain MOV retirement, and existing I-BRAM control-target port steering | 4,826,619 | 109,814 | 2.275% | 2.497% |
| **Total** | **4,826,619** | **4,397,506** | **91.109% vs historical control** | **100.000%** |

The first, second and final rows are **bundles, not isolated feature
ablations**. In particular, no independent percentage is established for
`66` admission versus MOV ACK retirement versus target steering.
Likewise, writer-history repair and implicit-ESP filtering are not separately
measured. Assigning individual gains to those subfeatures would invent evidence.

The transfer-width correction is independently reconciled: 117,932 slow
reads and 7,346 slow stores incorrectly paid three clocks, yielding exactly
**375,834 saved clocks** of the second row's 376,100. The remaining 266 clocks
are the net effect of its other changes, not an isolated SHORT or CL gain.
The direct-memory trace retains 1,196 clocks of real modeled memory debt
(133 misses × eight plus 44 transfer crossings × three). This does not
measure the SoC L1/AXI service or establish its bottleneck.

## Correctness and hardware discipline

- Use one real decoder/capture and one GPR writeback/retirement authority;
  avoid duplicated instruction semantics. Integer occupancy precedes
  writeback rather than retiring first and charging a later debt.
- Preserve paid prefix D1, true base/index AGIs, byte-parent hazards,
  explicit ESP hazards and all actual execution clocks. A 33-bit prefix
  PC token is transient ownership state, not a decoded-instruction cache.
- Correct operand-size-16 immediate `69` to consume/sign-extend two bytes,
  preserving its dword form and the following instruction.
- Separate operand width from code-IP width: `66` in CS32 must not truncate
  fallthrough EIP. Reject explicit ESP WAW and pending older owners in the
  new register-only prefix path.
- Plain MOV retires only on the final reconstructed operand ACK. CMP/TEST
  retain their additional execution clock; faults and width/high-byte merges
  remain gated through the existing paths.
- Control-target pre-reading reuses the two existing registered I-cache
  ports. It adds no SRAM ports, descriptor cache, allocation or speculative
  architectural effects. Returned tags/collisions/extent still govern use.
- All new performance switches are optional. The measured profile has no
  uop cache, out-of-order issue, same-pair load-use forwarding, experimental
  prefix/EX chaining, benchmark recognition or Quake-specific workaround.

## Verification at stop

- FIXED32 fast differential gate: **107 functional programs pass**, including
  the new word-immediate IMUL regression; all **20 M4/M5 metric bands pass**.
  The former DIV-band failures are resolved without loosening tolerances.
  The canonical script separately reports 20 non-gating per-instruction cycle
  comparator divergences; this is not a claim of exact cycle-trace equivalence.
- Both short CoreMark seed runs pass all five CRC fields and reproduce the
  same complete clock/retirement/counter partitions after the corner repairs.
- Focused checks cover execution occupancy/CL forms, 32,768 memory-boundary
  cases, actual-writer history, SHORT suffix independence, prefix ownership,
  final-ACK MOV merging and target-port steering.
- Corrected prefix alignment matrix: **382/384 cases pass** full architectural
  QEMU comparisons and pairing/spacing checks. Two golden runs failed to connect
  to QEMU before RTL execution. They were not retried after the stop request;
  the matrix is **not fully green**.
- The 152-case MOV and 11-case target whole-core witnesses used the preceding
  combined binary; their source-level leaves pass, but those runs must not be
  relabelled as a complete FIXED32 matrix or an isolated performance ablation.
- Windows 95 desktop, Quake timedemo, system gates, full verification and FPGA
  synthesis/deployment were **not rerun**. Major-change standard-suite acceptance
  is incomplete; these commits are a checkpoint, not release qualification.

## Host-only acceleration and reproducibility

Skipping a same-clock settle only when every generated DUT input is unchanged
improves host throughput approximately **25–28%**, with every clock-edge eval,
guest clock, retirement and CRC retained. This is **0% guest performance gain**.
The port list is generated from the exact Verilated header; unsafe debug/device
configurations fail closed. Parallel builds and fixture stages use bounded
resource scopes; golden fanout is limited to 24 active QEMUs to leave task
headroom inside the 32-worker scope.

Two model threads, serial LTO, and frontend-O3/larger-function experiments
preserve guest results but are slower: approximately 5%, 1.9%, and 2.75–3.96%
more host wall time, respectively. They are not credited as performance fixes.
The faster measured single-thread host still projects a 1,500-iteration run
around 40 minutes, outside the authorized 30-minute cap. No long run, guest
timer manipulation, dataset change or timed-loop snapshot splice was used.

Measured FIXED32 binary SHA-256:
`75e3d944c98c7d498d00457b9828894cbf136d11356ee2c0e705abbbd8592736`.
It was built from the explicitly frozen worktree, which also contains older
unrelated system changes not included in this CoreMark-only checkpoint.
The pushed revision is therefore not claimed to be byte-identical to that
measured build. Full build hashes, define profile, exclusive cycle tables,
evidence paths and remaining work are in
[the detailed cycle survey](P54_COREMARK_CYCLE_SURVEY_2026-09-29.md).
