# Experimental NP/prefix overlap

`VEN_P54_PREFIX_EX_CHAIN` is default-off and requires `VEN_P54_INT_EXEC_OCC`,
`VEN_PIPE_SDISPATCH`, `VEN_PIPE_SDECODE`, and `VEN_IC_BRAM`. It reuses raw returned
I-cache bytes, the one reference decoder, and the existing execution record.
No EX hold is shortened; no persistent decoded cache or benchmark-specific
instruction recognition is added.

Intel AP-500 241799-002 §5.5 (printed p12) permits prefix D1 work to overlap
the preceding multi-cycle instruction's last clock. P17 explicitly gives
MOVZX three execution clocks plus one unhidden prefix clock. However, p18
schedules consecutive memory MOVSX four clocks apart. Both AP-500 revisions
have that example. Alpert/Avnon's Intel-authored 1993 pipeline description
also places complex-instruction microcode sequencing in D1.

Consequently, EXT-to-EXT is explicitly vetoed. The remaining EXT/IMUL2
cross-kind and IMUL2-to-IMUL2 handoffs are experimental pending exact P54 D1
microcode-resource qualification. Their performance must not be counted as
a period-correct P54 acceptance result merely because architectural CRCs pass.

On a successful final EXT/IMUL2 EX edge, the opt-in handoff can capture an
unprefixed `0F` EXT/IMUL2 or exactly `66`-prefixed immediate IMUL. It rejects
two-prefix `66 0F`, system/control/store forms, pending events/debug/FP owners,
timing debt, active memory fragments, stale/colliding/unbuffered byte windows,
and consume-edge invalidation. EA capture requires an exact known address mask
disjoint from the older actual GPR write mask. Register source/WAW dependencies
read committed GPRs in the following EX clock. A separate old-PC register keeps
the delayed retirement callback correctly stamped; the execution counter is
explicitly rearmed when a new owner replaces `q_*` without leaving S_EXEC.

Verification is prepared but intentionally not run: the user deferred
non-CoreMark gates until the score exceeds 2.0 CoreMark/MHz.

- `tb_int_exec_occupancy.sv`, the `native-chain` profile, checks the production
  countdown's same-state generation reset and full three-/ten-clock EX holds.
- `t_prefix_ex_chain.s` and `run-prefix-ex-chain.sh` check full QEMU post-state,
  retired-PC ownership, register dependencies, memory forms, ordinary66/0F
  forms, EXT-to-EXT veto, EA hazards, and two-prefix rejection.
- A further whole-core debug/invalidation injection fixture is required before
  enabling this profile for full-system use; the current scope is flat user
  mode only. No Windows95/Quake compatibility claim is made for this profile.
