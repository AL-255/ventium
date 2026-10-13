# New-request CS-extent cofactor

October 13, 2026. Private derivative of the measured PRIME-COHERENCE core;
**not production promotion, canonical correctness, timing or FPGA acceptance**.
Its parent reaches **32.955444239 MHz synthesized Fmax**, below the mandatory
40 MHz UV + fast-pipe target. The derivative's Fmax and gameplay IPC are unmeasured.

## Why this is the next timing change

The completed parent's worst path crosses the slow reference decoder's
`d_len`, shared `cs_extent_fault`, new-store admission, AXI ACK and GPR
writeback: 106 levels, −5.344 ns at 40 MHz. The earlier
[proposal and fixture history](PAYLOAD_REGION_HINT.md#pending-follow-up-new-memory-cs-extent-cofactor)
already identified the following exact consumer invariant:

- A new integer load/store request implies S_PIPE, no held packet, and every
  integer pre-issue guard.
- At that consumer the S_DECODE fault arm cannot contribute;
  `pipe_cs_issue_eligible` is true and `pipe_u_eff.len == u_d.len`.
- Therefore only those two request predicates may use a direct live-U-length
  **33-bit** CS-extent comparison. Keep the complete global fault expression
  and exception priority, and both held-request muxes, unchanged.

`prepare_pipe_mem_cs_extent.py` now accepts two explicit source hashes: its
original PAYLOAD-REGION parent and the current parent
`3d8aebbdf338a63ab86bb58a6fab2ebb43f0f280bdbd3626ff4710941a5983c6`.
An entire-file comparison shows their only differences are the qualified
FLOAD high-valid port/cofactor/assertions: 15 added / 1 removed lines.
All pre-issue, request and CS-fault expressions are identical. Drift, unknown
parents and reapplication still fail closed. The three earlier commit-cofactor
headers are retained unchanged.

No register, pipeline stage, clock, feature define, instruction whitelist or
cycle is added. Simulation asserts equality of the **complete** old/new load
and store request outputs on every non-reset edge, including blocked offers.
This is not a global replacement for `cs_extent_fault`: doing that is unsafe.

## Current-source leaf and private model

Evidence root: `/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.

`prime-cs-leaf-r1` passes **65,536 extracted-RTL comparisons** over all four
segment-enforcement/FP-pipeline profiles, detects both missing-limit and
32-bit-wrap mutants, and passes six independent SMT queries. The SMT lemma
is a manually modelled Boolean/bitvector statement, not automatic formal
translation of the full RTL. Four host tests pass on **each** accepted source.
Leaf service `ventium-prime-cs-leaf-oct13.service`, invocation
`54e7340a50e74997bf41cc0e2a5cc444`, closed native 0 in **4.069789 seconds**,
with unchanged pins, CPU12 affinity, peak 45,412,352 bytes, no swap.
Closure SHA-256:
`05c3a71f561f4e6735afd2ccc932b1f25bdb72033fbfae4ef3e7702051160bb0`.

`build_prime_cs_core.py` checks that every actual compiled leaf fixture equals
the source-extracted old/new expressions, validates the exact terminal owner,
then transfers only `rtl/core/core.sv` into the complete **195-source** parent.
All **152 UV-fast definitions**, assertions and source ordering remain.
The new model uses a unique private C++ host with its own object and verified
dependency on the matching generated `Vventium_top___024root.h`.

`prime-cs-core-r1` built with **32 compiler jobs** in **19.607281 seconds**,
native 0 / stable pins. Service `ventium-prime-cs-core-oct13.service`, invocation
`7fa276d110a548648f09f0d00fbf5c4a`, is terminal with MainPID 0 / exit 0.
Model SHA-256:
`73f6f9dbd0ca16640456304a01453a8bfd5c28a98fa0c9ec5548a9d1fdd61dca`.
Build closure SHA-256:
`8c568d4065e3145151f5fc9d2a1cbac823aff55ac3d69593c7fc20468a3f90f2`.
This is a successful build, not an execution-test pass.

The unchanged canonical gate is now running under
`ventium-prime-cs-verify-oct13.service`, invocation
`46e6ef60528d4ffe8a500a102fa20ca4`. It uses the real AXI backend, identical
latency 7, UV-fast cycle-functional traces and all 20 complete parent/candidate
cycle streams. Its native gate has a 600-second cap. Parent canonical status
remains **7 functional PASS / 101 FAIL**, unwaived; do not infer correctness
from parent equality or change any mask/golden/band to hide a failure.

## Required qualification still open

Run the complete existing core/FP/fault/replay comparisons and directed CS
boundaries, including actual accepted and held fast-memory requests. Earlier
CS-overrun fixtures faulted in **S_FETCH**, not S_PIPE: their successful guest
results do not prove coverage of this local consumer. Retain that limitation
until there is direct state/request evidence; warmup V events alone do not
close it. No host register injection or pairing-disabled control counts.

Then transfer the exact candidate to the PC/HW profiles, lint, run both short
CoreMark correctness controls, and measure a new matched synthesis. Full
duration-valid performance, the complete standard suite, and physical FPGA
Win95 desktop/UI plus original FreeDOS Quake timedemo remain required.

Current derivative gameplay IPC is **unmeasured**. Older verified simulation
baseline: **0.51030715 total U+V retirement events/cycle**, build `2b4d7a48`,
cycles **1,200,065,237–1,300,065,237**. It predates the derivative and is not
FPGA or full-timedemo IPC. No CPI or timing gain is yet claimed for this change.
