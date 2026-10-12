# Same-line paired-read ACK cut — October 11, 2026

**Private derivative; not part of the measured readiness candidate.**
Predicate proof, source-extracted microtests and full-cache checks pass.
Cold whole-core matrices now pass on the MC+PAIR+SRT derivative below;
canonical verification, timing and FPGA validation remain pending.
The requirement remains **40 MHz synthesized Fmax or better**, with UV,
system/relocated fast pipes, fast loads/stores and full P5 caches retained.
The readiness predecessor now measures **30.34809 MHz**, unplaced synthesis.

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

Before promotion, run the full UV-fast core/QEMU comparisons and unchanged
canonical gate. Do not include the separate generic-overlap draft automatically.
The new measured worst path runs through read-hint commit rather than this
same-line-return predicate; this draft is therefore deferred from the next
isolated timing experiment, not claimed as a measured timing improvement.

## Full-cache regression passed after fixture correction

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

Compiler assertions and all six structural warning classes remain fatal.
A historical printed FAIL followed by `$finish` is upgraded to a native fatal
exit without changing its checks.

Queue `ventium-pair-now-cache-queue-oct11.service`, invocation
`dd01077f8cdb49fcb9e002d176f8b51b`, waits for the exact readiness timing queue
`e46bc1ace6b943998fc4f84738c31f11` to close successfully, checks its independent
timing audit and all pinned inputs, then launches one guarded-32 cache run.
No competing Verilator/Vivado build starts while synthesis or timing is live.
Its controller and receipts are under the evidence root's parent directory,
`after_timing_cache.py` and `cache-queue/`.

The first actual cache run (`cache-r1`, invocation
`216eddf713554fb2b2d03169c4e94a9b`) failed natively with 23 fixture expectations.
Old/new cache comparisons agreed: a cold critical-word ACK did not imply a
full saved line, and waiting for fill completion did not upgrade that window.
The fixture now performs an ordinary resident read after fill completion and
checks window validity, fullness and line identity. No internal state is forced,
no check is relaxed, and no candidate RTL changes. The failed source/logs remain.

Revision 2 (`cache-r2`, invocation `680b154a32cc493596404d204af4cbdf`) closes
native zero in **13.55 seconds**. FF/primary and LUTRAM/primary+shadow cases
both pass: respectively 15/17 transaction checks, 5/7 immediate same-line
returns, and three held-backpressure checks each. The deliberately unowned
return mutant compiles successfully and fails natively as required. All pinned
inputs independently rehash unchanged. Receipt SHA-256:
`2cf0ead134ea015f86c271fbb5df4d16598bf3299d660f01865def93a6ca7bb5`.

## Whole-core continuation prepared, not launched

[`build_pair_now_core.py`](../verif/l1/build_pair_now_core.py) admits only the
exact measured readiness core (`64e997d5…`) and the successfully closed actual
cache regression above. It rehashes both native positive binaries/logs, the
rejected ownership mutant and all pinned sources, and requires real immediate
returns and held-response checks. A printed success or an unrun leaf proof is
insufficient. Its derivative changes only `rtl/mem/ven_l1d.sv`, preserves all
195 source files / 150 definitions, and checks the private harness's compiled
dependency file against its own generated model header.

The three admission unit tests pass, including twelve deliberately incomplete
or failed row variants. These test the builder's rejection behavior, **not the
cache or CPU**. This whole-core build is not queued or running; the timing
and cache owners are now terminal. The original canonical differential
gate still requires a new run and a genuine pass; no comparator, terminal
record, C1 mask or cycle band is changed by this continuation.

## October 12: integrated against the newly measured critical path

The [MC+PAIR+SRT timing audit](MC_PAIR_SRT_TIMING.md) closes at **28.88838 MHz**,
with the paired-response capture cone at **29.76102 MHz**. That cone again
traverses generic cache ACK into bank readiness. The measured parent's L1
source is byte-identical to the cache-tested source above, so the existing
recipe and actual cache evidence are reused, not replaced with a new draft.
The unused generic-overlap proposal remains excluded.

The builder now admits either of the two exact known parent model hashes;
unknown/changed models are rejected. Four admission tests pass. It retains
the parent's complete source/profile audit, requires the actual cache positives
and rejected mutant, explicitly enforces guarded-32, and uses an output-specific
private C++ basename.

Evidence root: `/home/yukidama/external/tmp/ventium-mc-pair-srt.fI8m6eUS`.
`pair-now-core-r1` closes native zero in **20.10 seconds**, owner
`ventium-mc-pair-srt-pair-now-core-oct12.service`, invocation
`6f1d5f1c060449b4aa9c089d15973eb0`. All **195 source files / 150 definitions**
are retained; only `rtl/mem/ven_l1d.sv` differs. All 1,480 started input pins
independently rehash, and the local harness object uses this model's header.
Model SHA-256:
`b84cc5b4618defd2067c8c37b2e084229a3e6759a2358eab4c570e035f5eceb4`.
Build closure:
`43dbd144d51b747ba1bdfadb4da58fd5a84adc0a401493580902a66717b90084`.

Four cold matrices run concurrently with **32 total workers** (4 memory,
4 store, 8 held-read, 16 FP), under bounded user units and actual CPU affinity.
All four native owners close zero; complete fresh QEMU state and complete
parent/candidate cycle streams match at AXI latency 0/7. All input pins
independently rehash unchanged:

| Corpus | Cases | Candidate records | Witness |
| --- | ---: | ---: | --- |
| Paired reads/read-ALU and rejection | 72 | 31,392 | 1,500 memory V events |
| Load/store pairs plus readback | 72 | 32,112 | 456 memory V events |
| Held read / unsafe prime rejection | 24 | 9,200 | 346 held primes |
| FP/integer/memory overlap | 72 | 39,024 | 144 paired V, 7,220 early FP accepts |

These are **111,728 candidate architectural records with no observed cycle
change**, not a gameplay gain. Receipts: `pair-now-{memory,store,held,fp}-r1/`.
The original 16-fixture FP fault matrix is now running as
`ventium-pair-now-fault-oct12.service`, invocation
`8c39731e21174073a7433df693eb389a`. The unchanged canonical gate is queued on
the shared build lock as `ventium-pair-now-verify-oct12.service`, invocation
`f358fc432c534afa9922955ae9f7d3c1`. Neither pending run is counted as passed.
No new synthesis, routing, full-PC or FPGA run is launched for this derivative.
The separate AGI/reference priming ACK dependency still needs a checked fix;
do not claim this isolated cut can by itself reach 40 MHz.

Verified gameplay baseline: **0.51030715 total U+V simulated retirement-event
IPC**, older model `2b4d7a48`, cycles **1,200,065,237–1,300,065,237**.
This draft has no gameplay/FPS or FPGA measurement. The inherited canonical
gate is FAIL, not superseded by these microtests.
