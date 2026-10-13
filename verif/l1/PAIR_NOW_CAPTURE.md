# Remove immediate-return feedback from V-only bank capture

Private proposal based on FP-WIDE-CONTEXT, **not** part of its synthesized
checkpoint, not production RTL and not FPGA acceptance. It is an alternative
next timing step; do not combine unqualified proposals by editing a frozen
export. No Fmax or gameplay gain is measured for this change.

## Identity and scope

PAYLOAD-REGION's captured-V timing path passes through saved-window validity →
`pair_now_valid` → `pair_hit[1]` → response ready → captured V. The immediate
saved-window return suppresses a new bank capture. For a **V-only request**
with dual-load pairing, however, both cannot occur:

- An immediate return requires a current read and a reusable saved line.
- Free-bank lookup requires no current request.
- Legacy registered-read overlap explicitly excludes V-only requests.
- Fresh-U capture excludes reusable saved lines.
- Prime capture requires no current request; store/load capture requires a write.

`prepare_pair_now_capture.py` changes only the immediate-return suppression
inside the two-lane `pair_hit` equation. Under `VEN_P54_DUAL_LOAD_PAIR`, that
suppression is needed only when `pair_req_valid[0]` is also asserted. Actual
immediate return, bank arbitration, tags, response state, priorities and core
mode remain unchanged. The core currently ties request lane 0 low, so this
offers synthesis a constant that can remove the entire immediate-valid cone
from captured-V hit eligibility. The general cache interface still supports
two-lane standalone requests and must preserve their priority.

This is a cache-local identity, not an assumption that the core never asserts
next lookahead. Existing assertions remain; a new per-lane simulation witness
checks the original hit equation. No new state, cycle, port, clock exception,
feature flag or guest-specific behavior is introduced.

Parent L1 SHA-256:
`d565f12a984a4e83c8816a0214705999033a2c0906ad66f44f27d5b117b4d4f8`.
Derivative:
`a136afca875bf647f1b0c9e05c025cb12b6057c28bd7d434d6a634c03328893a`.
The recipe rejects drift/reapplication; exact reversal restores the parent.

## Closed leaf evidence

Evidence root: `/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.

`pair-now-capture-leaf-r1` passed eight source-extracted Icarus profiles,
**149,509 comparisons each / 1,196,072 total**, in **10.295 seconds**, peak
memory **19,890,176 bytes**. Profiles: full, standalone (no dual-load pairing),
no legacy capture, no chain, primary window only, no windows, dual-load prime
and store/load capture. The compiled negative case removing two-lane priority
fails at check 3: both requests valid, immediate V valid, bank lookup active;
old hit mask `01`, broken mask `11`.

Owner `ventium-pair-now-capture-leaf-oct13.service`, invocation
`b4dff045e4ec4d33a72617a0ac8fab7c`, closed successfully. Closure SHA-256:
`a3876c620fba4960550efd25fd270a69bb637f4dca77fe7e193a537c4c0ccaa0`.

`pair-now-capture-proof-r1` has four UNSAT abstract checks: V-only exclusion,
hit equivalence, saved-line/fresh-capture exclusion and request/prime exclusion.
Five SAT cases exercise weakened abstract contracts (two-lane priority and
legacy/fresh/prime/store exclusions). These SAT cases are **not all native
RTL mutation witnesses**: the over-approximation intentionally omits further
relationships, notably prime/next-lookup coupling. Only the two-lane-priority
mutation is also established by the compiled native test above. The four
positive checks prove the stated abstraction, not automatically elaborated
SystemVerilog or sequential cache behavior.

Proof owner `ventium-pair-now-capture-proof-oct13.service`, invocation
`36ba43f19f864732885d84388c8c8205`, closed successfully; all input and leaf
artifact hashes rechecked. Closure SHA-256:
`44b2366e6ae6dac703641837f28938bf0e59df228f86d291fbc47ac4529daef7`.

## Next verification

`run_pair_now_capture_cache.py` is prepared, **not yet run**. It retains the
full-size sequential cache A/B, both-edge outputs/banks/tags/owners, and all
existing traffic. `pair_now_capture_leaf.svh` adds public-traffic tests for
128 primary/shadow byte/dword offsets (106 immediate returns, 22 rejections),
two standalone two-lane priority cases, and two fresh byte/dword captures with
immediate requests asserted. It checks real response data/owners and rejects
duplicate V responses. A separate deliberately broken build must fail.

Native full-cache qualification waits for the sole Vivado report job to close.
Then choose the next candidate using the actual timing paths, and require core,
full-PC, source-transfer and timing evidence. Canonical gates and full FPGA
Win95/Quake acceptance remain outstanding. Leaf passes are not substitutes.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V retirement events/cycle**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**; predates this proposal, not FPGA/timedemo IPC.
