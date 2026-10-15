# Backing address/strobe mux experiment — 2026-10-15

Status: **tested private derivative; rejected as a timing/area optimization;
not accepted or deployed**. This follows
the [rejected fetch/pair composition](PAIR_NEXT_DISJOINT.md), but starts from
the faster retained prefix-payload parent. That parent's synthesized/unplaced
estimate is **36.591166892 MHz**, not 40 MHz routed closure. The new derivative
measures **36.221385106 MHz unplaced**, 1.0106% worse, and adds 470 LUTs.
No production RTL or feature definition was changed.

Verified gameplay baseline: **0.50520554 total U+V IPC**, older model
`c7b95b78f47f5e709136f98230bdf33975cf8db0e925956b469649cbf6384afd`, cycles
5,600,065,237–5,700,065,237. Candidate gameplay is unmeasured.

## What changed, and why

The measured critical cone traverses request extent/routing, backing-store
pair credit, L1 admission and ACK before architectural writeback. The parent
has early backing address/strobe defaults, but repeats assignments inside late
request-qualified branches. [The recipe](prepare_backing_payload_mux.py)
factors `m_addr` and `m_wstrb` into a separate combinational selector in
`ven_l1d.sv`. It selects U/V payload by direction, or the original fill/bypass
address while filling. It does not depend on request, stream or pair-ready
signals. All request, credit, permission, ordering, state and latency equations
remain unchanged. Without dual-store pairing, the original producer is kept.

This is a mapping hypothesis, not a claimed timing improvement. Synthesis can
reshare equivalent logic; inspect the resulting path before promotion. There
are no added pipeline bubbles, disabled features, timing exceptions or
Quake-specific behavior. Full P5 caches and single-fill/posted16 remain.

The transform requires the exact parent SHA and rejects reapplication. Its
simulation witness checks **all 11 backing outputs unconditionally**, including
idle payload hints. It is not whole-core formal verification.

## Completed checks

| Check | Result |
|---|---|
| Extracted actual producer, default/dual/full profiles | 524,520 comparisons per profile, including 232 directed X/Z cases; all pass |
| Four deliberate leaf mutants | Late address, wrong V payload, fill strobe and lost credit all fail |
| Actual L1, unfiltered output miter | 150 transactions; 538 scenarios, 448 fresh, 64 same-bank and 1,536 held observations; pass |
| Actual L1 negative control | Deliberate idle-address corruption fails |
| Private core build | One changed file in 195-source closure; 152 unchanged definitions; assertions enabled; native exit 0, 20.67 s |
| Fresh qualified-private-QEMU comparison | 108/108 programs; 80,800 complete records; 30,132 actual V retirements; 109.47 s |
| Independent fresh-trace regrade | 857 input pins; 105 programs also pass without optional manifest masks |
| Unchanged canonical `make verify` | **FAIL**, native exit 2; 7 functional PASS / 101 FAIL; 384.65 s |
| Canonical cycle streams | All 20 exactly parent-identical; **not** cycle-band passes |
| Held-read address corpus | 48 complete A/B state/cycle comparisons pass |
| Cold paged load/store corpora | 72 cases each × delays 0/7; exact A/B state/clocks and full QEMU comparisons; 1,500 / 456 candidate memory-V retirements |
| Cold U translation / warm V corpus | 36 cases × delays 0/7; exact A/B state/clocks and full QEMU comparisons; 581 candidate memory-V retirements |
| Full-PC transfer/build | 102 shared sources audited, one changed; 156 unchanged definitions; native exit 0, 22.79 s |
| FPGA source export | 170 common HDL inputs, 190 payloads, 158 definitions, unchanged 40 MHz constraints; UNQUALIFIED |
| Strict frozen CPU-hierarchy lint | Pass, six structural classes fatal; not full-SoC lint |
| Host checks | 16 tests pass across recipe, observer, fresh-reference, transfer and controller tests |

The three directed memory corpora ran concurrently with disjoint taskset CPU
sets; actual QEMU/RTL child affinities were observed. Their owner closed in
18.70 s, exit 0. The held-read owner also closed exit 0; that older runner
inherits its explicit taskset, but has no separate sampled-affinity receipt.
None of these directed IPC or retirement counts is gameplay performance.

The fresh oracle remains the separately qualified private QEMU
`da49b8105f90b4257494a7b7f1e57e5428fa66dc667278b824d381d9d0e9f84d`.
It does **not** replace canonical QEMU. Existing x87 stack-fault masks still
matter for `tx_regform`, `tx_regform2` and `tx_stack`; no masks, goldens or
cycle bands were added or changed. All executable flat images match the
canonical run. Of their ELFs, 54 differ only in the previously bounded,
non-loadable randomized GCC `STT_FILE` basename; no trace/ELF was rewritten.

The full-PC compiler retains 98 inherited structural warning lines unchanged;
its build is not a full-SoC lint waiver. Runs retain `cycle_mode=1`, real AXI,
UV/relocated fast paths, and actual paired execution. No snapshots, stepping,
breakpoint suppression or U-only substitution are used.

### Short cold CoreMark controls—not accepted scores

| Seed | CRCs | Ticks | Cycle gain | Final cumulative V retirements |
|---|---|---:|---:|---:|
| Performance, 10 iterations | `e9f5/e714/1fd7/8e3a/fcaf` | 4,767,218 | 0% | 1,055,307 |
| Validation, 10 iterations | `18f2/e3c1/0747/8d84/c64e` | 4,753,406 | 0% | 1,054,254 |

Both cold controls match the parent, completing in 208.92 / 212.08 host seconds.
They deliberately print CoreMark's **short-duration error**; the checker
requires that to be the only error. Thus these are CRC/cycle regression
controls, **not error-free full-seed acceptance or duration-valid CM/MHz
scores**. Independent regrading checked 17,636 source pins, native
argv/affinity/closure, media identity and no OOM. Peak owner RAM: 185,843,712 B.

## Test gap caught before promotion

The first sequential-cache run passed its positive test but failed its
verification objective: the deliberate late-U-address mutant survived. The
inherited fixture deasserted `c_we` with `c_req`, selecting V during idle and
never observing the corrupted idle U address. R2 adds a public-pin idle U-write
case with a nonzero address. Both positive equivalence and mutation rejection
then pass. No RTL behavior, test verdict or output mask was relaxed. Failed
R1, its original driver and native logs remain separate evidence.

The fresh-trace audit was initially invoked before canonical assembly had
finished and stopped on a missing ELF. The unchanged audit was rerun only
after canonical closure; its successful receipt includes all 108 images.

## Identities and evidence

Root: `/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X`.

- Parent core: `e3ec298c7049e348ba7ebb6921ef4cdc875faf71cdda76810e124c05a16041e6`.
- Changed RTL: `ead9467baf45f218b5fab2a71879b8f8f35fc824a01118bf3840b5b5cc1eb422`.
- Candidate core: `7c88579767354f269055420cafe3acca089acda87e5ac174b633b3e7905dcdb5`.
- Candidate PC: `917b5e3a729902f19410fdaa3b43ac9a8827612109013f04388f03556c95dd91`.
- FPGA manifest: `a14e64b46af3a14ca21400183c1e231ee2a80e335df59756426fa6f171494ab1`.
- Fresh audit: `0930a519b3eed250b1a48b58f079cedfa659d222aa98ed558cfde441f6fbf5c1`.
- CoreMark audit: `0c892c05ae3ed68b7747e1dfbee36a0abbb50223454b364a13d8ba67698fcf61`.

Evidence directories use `backing-payload-mux-` followed by `leaf-r1`,
`cache-r1`, `cache-r2`, `core-r1`, `freshfunc-r1`, `held-r1`, `system-r1`,
`soc-r1/coremark-r1`, `fpga-r1` and `lint-r1`. Native owners are terminal,
MainPID 0; canonical intentionally retains failure status. All other completed
positive owners exit 0. The memory-system owner is invocation
`518d54d9b6de4dba88f6b8e06b16882f`; CoreMark owner is
`428892377c684a4fb95379cf1af554da`.

## Next measurement and remaining acceptance

[The prepared timing controllers](../../fpga/prepare_backing_payload_mux_synthesis.py)
retain the parent's native ownership/watchdog/reaping and disk/memory admission
code byte-for-byte. They target a matched logic-only synthesis and independent
clock/path audit, **not route or deploy**. The disk rule is not weakened to fit
another run. Read the native `started.json`/`closed.json` before treating a
prepared controller as a launched or successful measurement.

Twelve unused PCH caches from closed builds were removed (1,045,414,718 bytes),
recoverable by recompilation. Source, binary, objects and dependencies remain.
Additionally, 3,164 closed immutable paths were hardlinked to byte-identical
copies; all paths/hashes remain, recovering approximately 473 MB. Ledgers:
`backing-payload-mux-pch-removal.json` and
`closed-products-dedup-oct15-{plan,closed}.json`. Do not edit retained hardlinked
evidence in place. The active CoreMark directory was excluded from deduplication.

A second closed-product pass subsequently relinked **75,733** additional paths,
preserving every path and hash and recovering **6,157,869,056 bytes** of free
space. It covered only receipt-closed scratch artifacts and excluded the
then-active candidate PC tree. All targets passed open-file, inode, filesystem
and pre/post SHA checks. Ledgers:
`closed-small-products-dedup-oct15-{plan,closed}.json`; closure SHA-256
`07502add57fccac276afee29aa68da47de3b5cf13fbfcf140d826c99aad82293`.

**Matched synthesis launched at 12:43:28 UTC Oct 15 and has now closed**.
Owner `ventium-backing-payload-mux-synth-oct15-r1.service`,
invocation `cbbcfd1117154e86a51cee9055977a87`, owns the sole Vivado family in
scope invocation `0dfa7cd53ef144c5bfe4eedad284d6fb`. Admission verified
13,157,089,280 bytes free, above the unchanged 7,208,493,056-byte measured-growth
reserve. Native limits remain 8 GiB RAM / 6 GiB swap, 13 GiB combined early
stop, 4 GiB disk floor, 2 GiB host reserve and 45-minute timeout. No Chrome
process was killed. Output: `backing-payload-mux-synthesis-r1/`; the separate
clock audit also completed under `backing-payload-mux-clock-r1/`.
The synthesis lifecycle retains canonical failure and does not authorize
placement, routing, deployment or an acceptance claim.

### Closed native timing result

| Metric | Retained prefix parent | Payload-mux experiment |
| --- | ---: | ---: |
| Synthesized/unplaced frequency estimate | 36.591166892 MHz | 36.221385106 MHz |
| Core setup slack at 40 MHz | -2.329 ns | -2.608 ns |
| CLB LUTs | 186,045 | 186,515 |
| CLB registers | 54,985 | 54,994 |
| BRAM tiles / DSPs | 277.5 / 47 | 277.5 / 47 |
| Paired-V capture slack | -1.726 ns | -1.980 ns |

Synthesis took 1,905.59 s, peak resident 7,900,467,200 B and peak swap
1,224,683,520 B. The independent clock audit took 469.09 s, peak resident
4,762,648,576 B, zero swap. Both native owners are terminal, MainPID 0,
exit 0, with all input pins unchanged and no OOM. Synthesis retains one
critical warning and 1,558 warnings; successful execution is not clean timing.
The audit verifies zero black boxes and zero structural DRC errors, not the
full standard suite.

Clock owner invocation: `562cd862bed24bed9de2df2b3dec79c6`; owned Vivado scope:
`0d4b19e7ff404c0aa5fc2c6ef862683d`. Native source/clock/mapper matching checks
covered 18,031 synthesis and 18,036 clock-audit pins. No placement, routing,
bitstream generation, deployment or second simultaneous Vivado family occurred.

The new worst path is `q_pc[0]` to `state[0]/CE`: 91 logic levels and
27.311 ns data delay, including 21.892 ns estimated routing (80.16%). It still
crosses fetch/decode, fetch extent, fragment request shaping, route permission
and L1 admission. The paired-V capture cone remains about 69,000 cells.
Factoring the backing payload selector did not break the upstream serial
dependency. Fewer levels on one endpoint did not improve its delay. Retain the
faster parent; do not spend a route run on this hypothesis or claim 40 MHz.

Still required: measured ≥40 MHz synthesized/routed closure; canonical gates;
duration-valid ≥2.1 CM/MHz and both full correctness seeds; full Quake timedemo
and cold Win95 desktop/UI on the **candidate FPGA**, with source/bitstream hashes,
clock and UV-fast evidence. Simulation alone cannot close these. Existing-image
Doom still has no valid FPS because its earlier run failed before gameplay.
