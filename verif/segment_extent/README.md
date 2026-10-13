# Shorten the late segment-extent arithmetic path

October 13, 2026. **Isolated prototype, not promoted, synthesized or deployed.**
The latest preceding synthesis estimates **35.056967572 MHz**, below the
required 40 MHz. There is **no measured frequency gain** for this rewrite yet.

## Measured path and change

Retained report:
`/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI/endpoint-map-clock-r1/core_setup_unplaced_estimate.rpt`.
The 97-level unplaced setup path goes from `q_pc[0]` to `gpr[4][16]` through
fetch-size decode, segment extent checking, fragment/request qualification,
L1 pair readiness, AXI acknowledgement and retirement. Relevant arrivals:

| Point | Arrival (ns) |
| --- | ---: |
| Late fetch demand size | 17.713 |
| Extent arithmetic/compare carry chains | 19.013–20.499 |
| `seg_access_fault` | 21.403 |
| `fx_start` | 22.587 |
| L1 `code_access` | 23.567 |
| L1 store-pair intent ready | 24.127 |

`prepare.py` replaces exactly two uses of
`({1'b0,offset} + zero_extend(count) - 33'd1) > zero_extend(limit)`
in `core.sv`. Address/limit relationships are computed separately; the late
eight-bit count sees a nine-bit distance comparison. Adjacent 256-byte blocks,
32-bit overflow and the old zero-count underflow behavior are preserved.
All access/privilege/segment qualifiers remain unchanged. No added register,
FSM state, instruction latency, feature flag, fault bypass or pipe fallback.

This is a hypothesis about synthesis structure, not a promised gain: the
tool can refactor logic, and the address/limit paths or downstream high-fanout
ready chain may still dominate. Merely replacing the request-qualified
`code_access` with a payload hint would need a separate contract proof and was
**not** done.

## Closed verification

| Check | Result | Scope |
| --- | --- | --- |
| Recipe test | 1 test method passes | Exact anchors, two replacements, drift/reapplication rejection |
| QF_BV arithmetic identity | `unsat` for any disagreement | All two-state 32-bit offset/limit and 8-bit count inputs; mathematical model, not translated whole-core RTL |
| Exact proposed SV leaf | 2,852,512 vectors pass | Six high-address patterns, all low bytes/counts, boundary limits and random vectors |
| Negative variants | Both rejected | Removing zero-count handling or adjacent-block handling fails; symbolic counterexamples also exist |
| Native full core | Build exit 0, 20.11 s | Private matching host/header; 195 sources, one RTL file changed; 152 UV-fast definitions retained |
| Canonical `make verify` | Still **7 PASS / 101 FAIL**, make exit 2; 400.98 s | No masks, goldens, bands or backend changes; not accepted |
| Canonical cycle comparison | 20/20 identical to LMSW parent | Entire cycle records |
| Same-input architectural replay | 108 cases / 80,800 records identical; 77.40 s | Parent versus candidate and candidate versus its original trace, no stack normalization |
| LMSW memory/fault/retry | 44 RTL self-checks; 28 QEMU differential passes | Same 16 null/limit/LOCK oracle disagreements; gate remains exit 1 |

The fault rerun's results, exception vectors and record counts are identical
to the LMSW parent at AXI latencies 0/7/31. This is useful integration evidence
for the extent predicate, not a comprehensive segment-limit corpus. The
canonical gate remains red regardless of same-input equivalence. Standard
suite, full-PC transfer, FPGA source freeze, synthesis and physical acceptance
have **not** run on this derivative.

## Evidence and lifecycle

All paths below are relative to
`/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.

- `segment-extent-leaf-r1`: closure SHA-256
  `2f1dda6a24336b19fe66147b3d57505c068fd306a70b03fea8c5685ae27e99a1`;
  unit `ventium-segment-extent-leaf-oct13-r1.service`, invocation
  `1fc5082ab9d3422db829ce8404b43d4a`, exit 0.
- `segment-extent-core-r1`: model
  `d039f5db76c653b249826d446dd5eab8ef9ac4d73243af6818a22cb26e4383c5`;
  build closure `179dfe5322ee874ff5f1a80a654b19d7fe73410d277828caafee096fe7046a41`;
  build invocation `1de03d3c0da9462cb96300ff5774fc1c`, exit 0;
  canonical invocation `c2ecd51a644641698e69b7539ffcde0e`, owner exit 1.
- `segment-extent-replay-r2`: owner
  `ventium-segment-extent-replay-oct13-r2.service`, invocation
  `c04f984c0ec94b4d86d222a197a433ab`, exit 0. The first replay adapter failed
  before launching native cases due to passing a string to a Path-only hash
  helper; r2 fixes that adapter error, not RTL or comparison policy.
- `segment-extent-lmswfault-r1`: owner
  `ventium-segment-extent-lmswfault-oct13-r1.service`, invocation
  `242c53785746445699ae0c86a347520c`, exit 1, retaining the reference disagreements.

All owners are terminal with MainPID 0. Compile used the exclusive 32-job
scope, 10 GiB RAM / 2 GiB swap. No Vivado run was launched for this rewrite.

To retain disk reserve, four generated precompiled headers from the **closed**
LMSW core/full-PC builds were compressed, byte-compared against the originals,
then only their expanded `.gch` copies were removed. Sources, headers, objects,
binaries, input pins and evidence were kept. Recovery archive:
`lmsw-closed-pch-oct13.tar.gz` (51 MiB), SHA-256
`71d1d1e3344efb288b0d75fd28e3df0266fc948ca3cfe7d6a780ee7341e2226a`.
It contains the fast/slow `.gch` pair under `lmsw-core-r1/obj` and
`lmsw-soc-r1/obj1-speed-q16-parentpolicy`; extract into the evidence parent to
restore them. About 300 MiB net was freed, recoverably.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. Predates this candidate; not FPGA/Doom IPC.
