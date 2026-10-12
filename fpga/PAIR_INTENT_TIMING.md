# Checked store intent before speculative cache lookup

Target: **at least 40 MHz synthesized Fmax**, UV+fast, full P5 caches.
This is an **unqualified experimental derivative**, not a deployed fix.
The previous [NEXT-PAIR experiment](NEXT_PAIR_TIMING.md) closed at
**30.393289 MHz**, worse than its **30.591330 MHz** source parent.

## Actual structural change

Start again from the closed **BACKING-PAYLOAD** source, not from the slower
request-cofactor experiment. Its critical path serializes speculative next-read
decode/translation with current paired-store readiness, backing admission and
retirement. The cache's port-conflict guard cannot simply be deleted: a next
lookup changes the bank/tag address used by a simultaneous V store.

`verif/l1/prepare_pair_intent.py` adds a checked **intent** sideband through
`core` → `ventium_top` → `ventium_l1_axi` → `ven_l1d`. Intent equals the
existing `pipe_store_pair_offer`, before readiness. Actual request remains
`offer && ready`; actual ACK, backing credit, routing/permissions, cache
mutation and retirement are unchanged. Intent alone cannot write anything.

The cache gives intent priority over its nonbinding next-read lookup. Both
old-response lookahead and idle priming reject the conflicting hint, with
`c_next_ready=0`, so no next owner is captured. Pair readiness can then use
`intent || !next_conflict`. In the request cone the exact combinational identity
`intent && (intent || !next_conflict) == intent` removes that dependence
without assuming away a real physical conflict. The wide-read-valid cofactor
must follow the same arbitration decision. No clock/latency, timing exception,
cache geometry, extra write-buffer slot or workload-specific behavior is added.

The current RAW core is additionally asserted not to offer intent and a next
hint together. This assertion is checked on decoded instructions; it is not a
timing false-path constraint. The cache microbenchmarks deliberately create
simultaneous public-port traffic to verify safe priority even outside that
producer invariant. Preserve this distinction when interpreting A/B evidence.

## Evidence and retained failure

Evidence root:
`/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.

- `pair-intent-cache-r1` failed natively at the existing **FP-HIGH-VALID**
  assertion: the first edit updated pair readiness/lookup selection but missed
  the separately factored wide-read-valid guard. The original failure is kept.
  The correction updates that guard to the actual new arbiter; no assertion
  was removed or relaxed.
- `pair-intent-cache-r2` passed in **40.117 seconds**: six full-P5 cache
  configurations (two tag organizations × zero/one/two saved read windows).
  Existing traffic compares all enabled response/backing ports and all cache
  bank data, tags, valid/LRU and owner state against the unchanged parent.
  Separate intentional-conflict tests check reserve-before-request, same-cycle
  hint restoration when intent drops, exactly-once V stores, bank conflicts,
  snoop priority and backing backpressure without blocking an owned U read.
- The negative control keeps readiness permissive but lets the hint steal the
  port. It fails natively at **PAIR-INTENT: conflicting hint acquired the cache
  port**. This is an expected sensitivity failure, not a correctness pass.
- `pair-intent-core-r1` built natively in **20.424 seconds**, unchanged input
  pins, 152 defines, assertions and the actual AXI backend retained. Its model
  SHA-256 is `f3fb3256fb40d9af50d73f2ac80b26bb4f5e27ff4b95d9f279172b4e0c025e41`.
  The build uses a fresh private harness object and its matching generated
  class headers. Four RTL files differ from the simulation-only probe parent
  `7ce9cfa4`; the inherited probe itself has no synthesized effect.

The eight instruction-level A/B/QEMU corpora in `pair-intent-checks-r1`
closed successfully in **301.444 seconds**: paired stores, held accesses,
branches, integer/FP operations and AGI/reference/AGI-store hints all pass.
All **4,240** simulator invocations retain complete architectural comparisons
and exact parent/candidate retirement clocks. Inputs remained unchanged; the
intent/hint non-overlap assertion did not fire.

Aggregate probe counts exactly match the unchanged parent: **21,190,336
observed clocks**, 18,172 AGI offers, 24,352 reference offers, 282,808 raw-prime
offers, zero retained next owners, 5,616 read/pair-shape clocks, 3,072 requests,
1,872 accepted read/store pairs and 1,536 shape-only hint overlaps. Counts
include separate cycle and cycle-functional executions; they are not unique
workload cycles or gameplay measurements. There is **no measured cycle gain**;
the intended benefit is a shorter physical dependency, still unmeasured.

The exact-owner coordinator `queue_pair_intent_canonical.py` observed directed
unit invocation `715fecee043343fb8a0fa8bdc01663a5` close successfully and has
started the **unchanged canonical gate**. Its own unit invocation is
`738217af094449d49991c35afee25702`; native evidence is under
`pair-intent-core-r1/verify-*.json` and `generic.log`. Parent canonical failures
remain red and unwaived. This candidate does not inherit a differential pass.

Whole-PC transfer, short-seed CRC/cycle comparisons, FPGA export/lint,
synthesis/timing and routed/physical acceptance remain outstanding. The
standard suite and gameplay performance have not been run on this candidate.
Do not launch a new Vivado synthesis before those source/profile checks and
the unchanged disk/memory reserve admission pass. Keep a single Vivado family.

Closed cache compiler products are stored in per-case verified
`compiler-products.tar.zst` archives; binaries, headers, source and native
logs remain unpacked. This is lossless space recovery, not evidence deletion.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V retirement-event IPC**, model `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. It predates this candidate and is not an FPGA
or full-timedemo average.
