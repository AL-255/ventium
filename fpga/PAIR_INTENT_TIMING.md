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

The **unchanged canonical gate** closed in **397.078 seconds**, native exit 2:
**7 functional PASS / 101 FAIL**. All 20 cycle traces exactly match the parent;
no golden, mask or tolerance changes were made. Its coordinator invocation
`738217af094449d49991c35afee25702` is terminal, not still running. Evidence is
under `pair-intent-core-r1/verify-*.json` and `generic.log`. These failures remain
**red and unwaived**; this candidate does not inherit a differential pass.

The separate same-input replay `pair-intent-replay-r1` passed all **108 programs
/ 80,800 records** in **75.999 seconds**, including every architectural field
and exact candidate trace reproduction. Both models used the same retained
input image and QEMU initial ESP; no stack-field normalization was applied.
That A/B result does not turn the canonical QEMU gate green.

## FPGA-matched integration

`pair-intent-soc-r1` built successfully with a fresh private harness object and
its matching generated header. Verilator reports **23.270 seconds** native work;
the controller's **99.781 seconds** includes waiting for the replay's resource
lock. Model SHA-256:
`a02884bdd6f12dd6090ac0207d26f6aa1363c5aa2647448ca21d28ed8fea8d1e`.
All 102 shared core RTL files match the directed candidate. The PC changes are
the four hardware files plus the inherited simulation-only `core_mem_chain.svh`
probe; the latter disappears under `SYNTHESIS`. All 156 simulation defines and
the posted-16 transport are unchanged. The 98 inherited full-PC structural
warnings are unchanged, not claimed resolved.

`pair-intent-fpga-r1` exports 190 payloads, checks all 170 common HDL inputs,
and retains 158 hardware defines, 40/100 MHz clocks, full P5 caches and the
original filelist closure (117 units / 49 include edges). Manifest SHA-256:
`06a4179627952a02aa8444fe91b2a44d5f1dd11bf1f56c5bd0ff07bc232d7777`.
The Tcl source contract passed. Strict **CPU-hierarchy** hardware-profile lint
passed in **3.878 seconds**; this is not a full-SoC lint or timing pass.

The two unchanged short cold CoreMark seeds closed under exact invocation
`d9a1f4cead2a488ebb394708db8191f3`, actual CPU 11 affinity. Independent audit
rechecked 3,001 source pins, native arguments/owners, clean child termination
and no OOM. Both sets of CRCs match QEMU; **4,767,218 / 4,753,406 cycles** and
**1,055,307 / 1,054,254 V retirements** match the parent. Thus measured cycle
throughput gain is **0%**, as intended for a physical timing change. The runs
are below CoreMark's minimum duration and print its expected duration error:
they are **not** valid scores or error-free standard-suite acceptance.

Reproduction tools:

- `build_pair_intent_soc.py`: checked PC transfer and private native build.
- `freeze_pair_intent_rk_candidate.py`: byte-exact FPGA export.
- `lint_rem_split_rk.py`: strict 158-define CPU-hierarchy lint.
- `prepare_pair_intent_synthesis.py`: bounded synthesis/timing controller
  generation. Five tests check the four-file core / five-file PC distinction,
  complete replay admission, same clocks and unchanged resource lifecycle.
- `test_pair_intent_transfer.py`: four tests check every intended transformation
  and rejection of omitted, extra or unrelated byte changes.

## Native timing run started

All source/profile, replay, short-seed and reserve admission checks passed.
One native synthesis started at **2026-10-12 20:08 UTC**, controller invocation
`a6586063f10c4bb1ae08172c6ba3aab0`, owned Vivado scope
`c8c65f49b70c48c890b30ef35297dedf`. Evidence is under
`pair-intent-synthesis-r1`; it is not a closed timing result yet.

The matched mapper and original 40/100 MHz clocks are unchanged. Resource
guards remain one worker, 8 GiB resident / 6 GiB swap limits, 13 GiB combined
early stop, 2 GiB host RAM/swap floors and 4 GiB live disk floor. Admission
also retained the twice-measured-parent-growth disk reserve. No OOM reserve
was relaxed to launch this run.

The exact-owner observer `report_pair_intent_timing_after_synth.py`, invocation
`3bf6984f86ea48f888bbcb02cf0c61c4`, waits only for this synthesis, independently
audits its closure, then launches one original-clock timing report and audits
its measured Fmax. It cannot retry synthesis, start placement/routing or
deploy. An observation timeout is not permission to restart the native owner.

Synthesized Fmax, routed/physical acceptance, the standard suite and gameplay
performance remain unmeasured on this candidate. **40 MHz is not yet achieved.**
Keep a single Vivado family; do not change or prune its pinned inputs.

Closed cache compiler products are stored in per-case verified
`compiler-products.tar.zst` archives; binaries, headers, source and native
logs remain unpacked. This is lossless space recovery, not evidence deletion.

`closed-pair-intent-reserve.tar.gz` retains 67,836 closed traces/logs:
2,044,895,076 original bytes became 113,330,333 archive bytes (**1.80 GiB**
recovered). `closed-pair-intent-build-reserve.tar.gz` retains another 49,200
closed raw test logs and compiler-cache files: 582,895,163 bytes became
83,509,240 (**476 MiB** recovered). Every member's size and SHA-256 was checked
before removing its unpacked copy; all current pinned inputs stayed unchanged.
Sources, binaries, images and result receipts remain unpacked, including the
failed first cache experiment. Exact recovery manifests/hashes are in the
adjacent `*-plan.json`, `*-verified.json` and `*-closed.json` files. Restore
archives relative to the evidence root before rerunning raw-trace collectors.
After both PC seeds and their audit closed, the two PC compiler PCH files were
compressed to adjacent `.gch.gz` files and their decompressed hashes verified
before removing only the unpacked copies (**152 MiB** recovered). The exact
files, hashes and sizes are in `pair-intent-pc-pch-closed.json`; restore with
`gzip -dk` if a future incremental rebuild needs them. Sources, matching headers,
objects, binary and runtime evidence remain; every pinned input still matches.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V retirement-event IPC**, model `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. It predates this candidate and is not an FPGA
or full-timedemo average.
