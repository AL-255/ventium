# Same-line paired-read ACK cut — October 11, 2026

**Isolated draft; not part of the currently running readiness synthesis.**
Predicate proof and source-extracted microtests pass. Full-cache/core checks,
canonical verification, timing and FPGA validation are still pending.
The requirement remains **40 MHz synthesized Fmax or better**, with UV,
system/relocated fast pipes, fast loads/stores and full P5 caches retained.
The last measured predecessor is **27.83654 MHz**, unplaced synthesis.

## Why this cut

The measured predecessor traverses the general read/write acknowledgement on
its way to paired-read admission. The enabled `VEN_P54_DUAL_BYTE_LOAD_PAIR`
path returns a same-line V value from an existing primary/shadow read window;
`pair_now_valid` then prevents the sideband hit-return leaf from enqueueing
that same V a second time.

That predicate requires `c_ack` **and** `(window_reuse || shadow_reuse)`.
For the registered response profile, either reuse predicate already proves
`c_req && !c_we`, excludes stream-mode override, and is itself a read-ACK
term. The extra ACK dependency therefore adds no acceptance condition, but
can pull the general backing-write/paired-store ACK mux into read admission.
Unlike the [generic overlap draft](PAIR_OVERLAP_ACK_CUT.md), this predicate
is used for the target's lane-1-only requests.

The [exact-parent recipe](../verif/l1/prepare_pair_now_ack_cut.py) removes only
that redundant conjunct in the registered profile. It keeps `c_ack` for the
separate combinational-ACK profile. Request validity, address/size identity,
same-line and distinct-bank checks, existing-response exclusion and both
reuse predicates are byte-for-byte unchanged. Real ACK/data selection, bank
state, requests and clock edges are unchanged. A simulation-only assertion
compares the complete original and candidate `pair_now_valid` values.

This is not a bypass of cancellation or ownership. A missing/invalidated
window must still reject the immediate return, and a same-bank pair must
still serialize. No timing gain is claimed before actual synthesis.

## Executed evidence

[The microtest](../verif/l1/test_pair_now_ack_cut.py) verifies exact-source
scope and rejects repeated or changed inputs. It runs an all-binary-predicate
Z3 equivalence query, **UNSAT**, retaining arbitrary other ACK terms and
the stream override. Dropping window ownership produces a counterexample.

Icarus executes the source-extracted primary/shadow reuse, registered ACK
and old/new same-line return equations. Eight registered feature combinations,
windows disabled, and unchanged COMB-ACK qualification pass **69,635 samples
each / 696,350 total**. There are **31 positive return samples**; most samples
exercise rejection. These are combinational predicate inputs, not real cache
transactions or exhaustive sequential state exploration. The COMB case tests
preservation of its ACK conjunct, not that different profile's complete ACK
implementation. Deliberately dropping ownership, bank separation or address
identity fails natively at samples 0, 1 and 2, respectively.

Run owner `ventium-pair-now-ack-leaf-oct11.service`, invocation
`b9234521ffc74d75913cf103336fa649`, closes native zero in **14.52 seconds**.
Independent rehashes check six pinned inputs, all thirteen generated
source/binary/log sets and the candidate. This small CPU-11/512-MiB-capped
Icarus job does not compete for the heavy Verilator/Vivado build lock.

Evidence: `/home/yukidama/external/tmp/ventium-pair-overlap-ack.eOFgJjVT/pair-now-r1`.
Receipt SHA-256:
`39d6cda6fc97ec9f02ebe4e6c9d2641cd0fe51ac22066fb6c27d867a9b595170`.
Parent L1 SHA-256:
`1d8a499aff0093a0861b20ec9faefee0820672cefe42d47504cd53f9ef71277b`.
Candidate L1 SHA-256:
`debab0ccd20eef18b3c2e5e9f349350e4f2b48eff8bd4b29213c5658fe499e6d`.

Before promotion, run the actual full-size cache with primary/shadow returns,
byte 31, crossing dword rejection, same-bank rejection, held V responses,
no double enqueue, invalidation and backing-pressure tests; then the full
UV-fast core/QEMU comparisons and unchanged canonical gate. Do not include
the separate generic-overlap draft automatically. The live readiness
synthesis and its clock audit must close before another heavy build starts.

## Full-cache regression queued, not yet passed

[`run_pair_now_cache.py`](../verif/l1/run_pair_now_cache.py) retains the original
dual-store/coherence fixture and instantiates two full-size 128-set, two-way
caches. The only candidate RTL difference is the same-line ACK cut above.
It compares external outputs, all tag/valid/LRU/data arrays, full primary and
shadow windows, and the actual paired response slots' owner/address/data.
The [new transaction extension](../verif/l1/tb_l1d_pair_now_extra.svh) uses
ordinary fills/captures to test primary/shadow returns, byte 31, crossing
dword rejection, bank/identity/size/cacheability rejection, no double enqueue,
a genuinely held V response, snoop plus fresh external-writer data, and flush.
The existing store/backpressure tests are not removed or relaxed.

Both fixture-generation variants pass structural generation checks; **native
compilation and simulation have not started**. Planned runs are FF tags with
the primary window, LUTRAM tags with primary/shadow windows, and an ownership
defect that must fail. Compiler assertions and all six structural warning
classes remain fatal. A historical printed FAIL followed by `$finish` is
upgraded to a native fatal exit without changing its checks.

Queue `ventium-pair-now-cache-queue-oct11.service`, invocation
`dd01077f8cdb49fcb9e002d176f8b51b`, waits for the exact readiness timing queue
`e46bc1ace6b943998fc4f84738c31f11` to close successfully, checks its independent
timing audit and all pinned inputs, then launches one guarded-32 cache run.
No competing Verilator/Vivado build starts while synthesis or timing is live.
Its controller and receipts are under the evidence root's parent directory,
`after_timing_cache.py` and `cache-queue/`. Do not equate a queued job or a
generated fixture with an executed pass.

Verified gameplay baseline: **0.51030715 total U+V simulated retirement-event
IPC**, older model `2b4d7a48`, cycles **1,200,065,237–1,300,065,237**.
This draft has no gameplay/FPS or FPGA measurement. The inherited canonical
gate is FAIL, not superseded by these microtests.
