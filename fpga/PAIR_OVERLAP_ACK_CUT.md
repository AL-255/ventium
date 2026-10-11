# Guarded paired-bank overlap ACK cut — October 11, 2026

**Isolated draft, not included in the running readiness synthesis.** Predicate
proof and source-extracted microtests pass. No whole-cache/core, gameplay,
synthesis, standard-suite or FPGA acceptance exists for this draft.
The target remains **at least 40 MHz synthesized Fmax**, retaining UV and the
fast pipeline. The measured predecessor remains **27.83654 MHz** unplaced.

## Exact change

The [recipe](../verif/l1/prepare_pair_overlap_ack_cut.py) changes only
`pair_lookup_active` and adds a local ownership predicate in a private copy of
the [readiness candidate](PAIR_READY_COFACTOR.md). It accepts only L1 SHA-256
`1d8a499aff0093a0861b20ec9faefee0820672cefe42d47504cd53f9ef71277b`.

The original legacy-overlap term requires an owned, cacheable current read
**and** the general `c_ack`. Its sole bank-lookup consumer already requires
idle, non-stream, non-flush and non-snoop operation. In that context, the
registered read-ACK equation necessarily acknowledges `rd_match`; no backing
write/paired-store acknowledgement is relevant. Use the ownership predicate
at this guarded consumer, keeping the actual ACK equation unchanged.

Preserved conditions include request/direction, matching response ownership,
cacheability, the V-only orphan exclusion, every outer cancellation/lookup
guard, and the combinational-ACK profile's disabled overlap. No register,
latency, port, bank, array mutation, backing request or response grant changes.
A simulation-only assertion compares the complete old/new bank-lookup result.

This is a potential dependency cut, **not a demonstrated timing gain**. The
mapped predecessor's critical path traverses `l1d_c_ack` and paired-bank
readiness, but flattened net names alone do not identify the precise RTL arm.
In particular, this target's core requests only lane 1, while the generic
legacy-overlap arm excludes a V-only request. Its overlap contribution is
therefore logically inactive for this integration; the mapper may already
eliminate it. Do not promote this draft or spend another synthesis on it solely
because the isolated proof passes. Inspect the current timing result first.

## Executed checks

[The test driver](../verif/l1/test_pair_overlap_ack_cut.py) checks exact-source
scope, rejects modified/repeated inputs, and runs:

- An all-binary-predicate Z3 equivalence query: **UNSAT**. The model retains
  arbitrary other read/write/bypass/stream ACK terms. Three defects—dropping
  V-only exclusion, dropping owned-read identity, and ignoring snoop—are SAT.
- Actual source-extracted registered ACK, overlap and lookup expressions in
  Icarus: sixteen registered compile-time combinations plus disabled
  combinational-ACK overlap, **65,792 samples each / 1,118,464 total**. Inputs
  include directed ownership/cancellation cases and deterministic broad
  combinations, not exhaustive full-cache states. All exit zero.
- The same three defects fail natively with exit **1** at directed samples
  160, 64 and 104 respectively. No permissive log-only failure is accepted.

Owner `ventium-pair-overlap-ack-leaf-oct11.service`, invocation
`621be855d81f40d2b251fca3886f13d2`, closes successfully in **13.11 seconds**.
It uses CPU 11, a 512 MiB cap, and no Verilator/Vivado build. Independent
rehashing checks six input pins, twenty generated source/binary/log sets and
the candidate. Sources of the ongoing synthesis are not modified.

Evidence: `/home/yukidama/external/tmp/ventium-pair-overlap-ack.eOFgJjVT/leaf-r1`.
Closure SHA-256:
`713d9f3f9370a8cbf76660322ed96014588827c471ff352fc5a3bb83c885c575`.
Candidate L1 SHA-256:
`cadf6d05a078a50cfc9cc4fd3d0e5c51afae677417a6981763e2f0d5b3dac946`.

Verified gameplay baseline: **0.51030715 total U+V simulated retirement-event
IPC**, older model `2b4d7a48`, cycles **1,200,065,237–1,300,065,237**.
This draft has no gameplay measurement. The inherited canonical differential
gate remains FAIL; these isolated tests do not replace it.
