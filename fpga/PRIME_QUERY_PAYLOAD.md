# Resident-query payload selection — October 12

**Synthesis/audit closed: 30.676729 MHz, below the 40 MHz requirement;
canonical verification remains FAIL. No routed or FPGA acceptance.**
The completed [load-ACK synthesis](LOAD_READ_ACK_TIMING.md) is unchanged and does
not include this separate candidate. The target remains **at least 40 MHz
post-synthesis Fmax** with UV, fast paths and full P5 caches. The last completed
parent estimate at the original preparation was **30.02192 MHz**, not a timing
pass. The original load-ACK derivative remains uncompiled; the October 12
memory-divide result below motivates a separate exact-parent transfer.

## Measured dependency and proposed cut

The prior synthesized report's LRU path traverses `mc_prime_offer`,
`mem_next_addr`, address-region decoding (`mc_next_dram`), paired-store
readiness, snoop/continuation guards and `core_mem_next_commit` before the LRU
update. It has 120 logic levels and -8.617 ns slack at 25 ns. Its path is retained
in `ventium-srt-rem-split.pM3Jsjhi/clock-r1/core_setup_unplaced_estimate.rpt`
under external temporary storage. This is evidence of a late request qualifier
in the address-selection cone, not proof that the proposed cut reaches 40 MHz.

[`prepare_prime_query_payload.py`](../verif/l1/prepare_prime_query_payload.py)
changes two selectors in `core_mem_chain.svh`: the speculative read address and
byte/dword strobe use `!mc_valid_q`, rather than `mc_prime_offer`, to select the
live query payload. AGI/reference selector priority is unchanged.

Every retained offer requires `mc_valid_q`; all four live-prime classes exclude
it. Thus offered payloads are identical. Unoffered payloads may differ, which
is intentional: no new request/commit is generated, and the downstream
resident-cache lookup/capture requires its existing request-valid condition.
Memory-map decoding may evaluate another idle address but does not initiate
traffic. No new port, state, feature flag, exception, pipeline bubble or
arithmetic unit is added. All permission and coherence checks remain intact.

Simulation assertions compare old/new payloads on every request and require
every commit to have a request. They execute in the whole-core tests below.
This is not a claim of equivalence for every internal idle signal.

## Executed checks

- Four source tests pass: exact two-selector scope, unchanged request/commit,
  drift/reapplication rejection, and simulation-only ownership witnesses.
- The [native extracted-equation miter](../verif/l1/test_prime_query_payload.py)
  passes **65,536 samples** in a complete 16-bit control sweep. It observes
  1,024 retained, 1,024 FP-self, 512 held-read, 256 fresh-read and 96 ordinary
  live-prime cases without AGI/reference selection, plus 16,384 AGI and 8,192
  reference offers. Those are overlapping classification counts, not processor
  instructions. There are 6,304 intentionally different unoffered payloads.
- Four separately compiled mutations fail natively with exit 1 and an actual
  payload mismatch: always live, always retained, wrong query width and lost
  AGI width priority. They are not compile failures or timeouts.
- The [all-bit contract proof](../verif/l1/prove_prime_query_payload.py) finds no
  accepted-address/strobe counterexample for arbitrary 32-bit addresses and
  widths under the offer-owner implications. All four mutations and removal
  of live/retained exclusion have counterexamples. Idle differences also have
  a counterexample, explicitly preventing an all-signals-equivalent claim.

The native miter extracts the actual payload, retained-offer and live-prime
source equations. Other AGI/reference eligibility terms are over-approximated
as independent predicates while retaining their selector implication. The
formal check abstracts the four live eligibility predicates. Neither test is
a full-core temporal proof, an independent ISA oracle or a cache-system gate.

Evidence root: `/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.
`query-payload-leaf-r1` closes native zero in **1.27 seconds**, owner
`ventium-prime-query-payload-leaf-oct12`, invocation
`d5de1f9d9ad74cab89a3518f750be4be`. Its SHA-256 is
`d9666207feaea6813c2d6b7d1602653ec81b88ef31fea79105762866da8fd60f`.
The proof in `query-payload-proof-r1` closes zero as
`ventium-prime-query-payload-proof-oct12`, invocation
`c1c1e07298e944dd88f324bb53db3b98`; receipt SHA-256
`c7e5e9e15ada055493bfb26f50c0bee0286336f298922e6e0f75eeb8fad70c8f`.
Both are CPU-12-only light jobs with no swap, separate from Vivado.

## Original deferral after timing/history review

The [private core builder](../verif/l1/build_prime_query_payload_core.py)
prepares `query-payload-core-r1`: 195 input files, the same 152 definitions,
one changed header and a unique private harness basename. It admits the native
positive/negative results and proof, rechecks their pins, and retains the
model-local generated-header dependency audit. **No compiler is launched yet.**

The [October 11 next-query experiment](NEXT_QUERY_PAYLOAD_CUT.md) already tried
a related idle-address rewrite: `(mc_valid_q && !A) ? retained : query`, where
`A` included the late prime selector. Its complete directed checks passed but
Fmax regressed **23.58546 to 22.51593 MHz (-4.53%)**, so it was rejected.
The present proposal is not byte-identical: it removes that late prime input
entirely and also changes the strobe selector. Nevertheless, this is a related
previously tested optimization family, not an entirely new untried approach.
Leaf equivalence does not predict mapped timing.

The newly closed load-ACK report instead puts all 30 reported worst setup
paths in the current-address/FP-conversion/SRT-input cone. Therefore do not
automatically compile or synthesize this prepared query proposal. Investigate
the measured critical dependency first and retain this evidence for possible
later use. No build or synthesis of this candidate is queued.

If subsequently selected, run its guarded 32-job build,
canonical `make verify`, complete parent/candidate architectural/cycle replays,
memory/held-read/FP/store/fault and branch/priming regressions. Only a qualified
candidate should transfer into the PC model and a new measured synthesis.
The inherited canonical **7 PASS / 101 FAIL** is still an acceptance blocker;
unchanged A/B behavior does not waive it. Full original standard-suite and
physical FPGA Win95/UI and Quake timedemo acceptance remain required.

## Retargeted after the memory-divide timing result

The [memory-divide candidate](MEMDIV_INPUT_CAPTURE.md) closes at
**29.077375 MHz**, with all 30 reported worst paths now ending at D-cache LRU
registers. Its 120-level path explicitly traverses `mc_prepare_ok`, the late
`mem_next_addr` selector, address-region eligibility, paired-store readiness,
snoop/continuation checks and next-read commit. This is new measured evidence
for revisiting the deferred selector, not an inferred benefit from leaf proofs.

[`build_memdiv_query_core.py`](../verif/l1/build_memdiv_query_core.py) reuses
the exact reviewed builder and original source-extracted miter/all-bit proofs,
changing only the admitted parent model identity and pinning both runner files.
The parent model is
`be5375aa32db48600498fc4b2c3a610c7cd99a0fa208c5186e602c44dd9b3d10`.
Its `core_mem_chain.svh` is the exact byte-identical predecessor already
tested by the recipe. A fresh `memdiv-query-core-r1` under the evidence root
retains all 195 inputs and 152 definitions; only this header changes. The
memory-divide and exponent changes remain present, and all UV/fast/cache and
assertion settings remain enabled. No active or historical frozen export is
modified.

The guarded 32-job build starts only after synthesis and the timing audit
have closed and no native Vivado remains. It closes native zero in **20.91 s**,
with unchanged inputs and the private generated-header dependency verified.
Model SHA-256:
`e65a06e1e3c26d48723bdeb0d9d97061879f15b1ff916e493d4fe94ae336a525`.
Service:
`ventium-memdiv-query-core-oct12`, invocation
`a01d2a23cf2a4285a37650e4d1cad8f1`. Timing, gameplay and physical acceptance
remain unmeasured; the subsequent synthesis launch is recorded below.

### Same-parent whole-core checks

All tests below use the exact memory-divide parent and the selector candidate,
unchanged enabled profiles, assertions, AXI latency 0/7 and cold system fixtures.
The complete directed architectural traces compare against QEMU; parent and
candidate state/cycle traces are identical, not normalized or selectively masked.
Counts include both latency settings; they are directed records, not gameplay.

| Check | Fixtures | Candidate records | Actual V retirements |
| --- | ---: | ---: | ---: |
| AGI priming | 20 | 36,960 | 2,560 |
| Reference-load priming | 20 | 26,712 | 2,560 |
| Original full FP matrix | 384 | 208,128 | 768 |
| Held-read ownership | 24 | 9,200 | 1,360 |
| Memory pairing / bank and line boundaries | 72 | 31,392 | 1,500 memory V |
| Branch / priming, all 32 line offsets | 640 | 353,920 | 1,280 |

AGI/reference runs retain their original 20-fixture smoke selection, **not their
full matrices**; they witness 12,096 / 13,888 accepted resident primes. The FP
matrix is the complete original 384-fixture sweep, with 1,536 measurements,
49.69 s runtime and no cycle or FP-acceptance count differences. The branch
sweep closes in 213.09 s; memory pairing in 21.32 s.

Evidence directories under the root above are `memdiv-query-{agi,ref,fp,held,
memory,branch}-r1`. Native owners all close zero and are reaped:

| Check | Owner invocation |
| --- | --- |
| AGI | `11f6dc7b1462435aa6414670779fe32e` |
| Reference | `9498aec3213941fba6b910536226a99a` |
| FP | `0155905dc7e542f3ac4d432e3a216f24` |
| Held | `a6658071f3b8495e800c1f0f29af65ea` |
| Memory | `33c9d575ded441fabe16c4b1b7b052c7` |
| Branch | `9d0d66914da64424a0c36308dfd6883b` |

The FP and memory/branch traces were independently re-compared in full and
losslessly compressed to `closed-memdiv-query-{fp,memory}-text.tar.gz`.
Each archive has a member/hash index and every member is byte-verified before
removing the unpacked text. Restore with `tar -xzf ARCHIVE -C
/home/yukidama/external/tmp`; models, sources, receipts and input pins stay
unpacked. No failed record is discarded.

Canonical `make verify` closes **FAIL**, native make exit 2 in **410.74 s**,
invocation `f798af9e77334e9ca5020c5acb8f25df`: **7 PASS / 101 FAIL**.
All 20 complete cycle streams match the parent. Masks, goldens and cycle bands
are unchanged. The separate identical-input replay passes **108 programs /
80,800 records** in 91.63 s, reproducing the candidate's original functional
traces too, without ESP normalization. Owner invocation:
`94ccb53a8a7346f7a308ccf9b304a78e`. The canonical failures remain unwaived.

The unchanged full FP fault matrix **passes all 32 native runs** (16 fixtures
times parent/candidate), including **23,585 candidate architectural records**,
complete UV/QEMU and A/B comparisons. Inputs are independently rehashed and
the native owner is closed/reaped:
`ventium-memdiv-query-faults-oct12`, invocation
`d274760dc8ec48678d431f5a2447d7f6`. The
[source-matched PC transfer](build_memdiv_query_soc.py) checks all evidence
above, exact source deltas and stable input hashes before preparation.

### PC/hardware transfer and timing preparation

The PC build passes in **22.79 s**, invocation
`97038040411c4d1b9a618cfb93508b91`, with unchanged inputs and the unique
private C++ header dependency verified. All **102 shared RTL inputs** match
the directed core; only `core_mem_chain.svh` differs from the memory-divide
PC parent. Its 156 definitions and posted-16 transport are unchanged.
The inherited **98 full-SoC structural warnings remain**; this is not a clean
full-SoC lint result. Model SHA-256:
`eebeb872631af564d340958bfe0c3576ab7ac9c56fb18b7f57af2b2a9ea50987`.

The [hardware export](freeze_memdiv_query_rk_candidate.py) freezes 190 payloads,
170 simulation-matched units and the same 158 hardware definitions. It keeps
the 40 MHz core / 100 MHz PL constraints, full P5 caches and no mouse overlay.
Manifest SHA-256:
`a15a7ec363d5ce5cd894a9d8e7f3a238cf0c57dc2086febe35c5587e787ef4be`.
Strict **CPU-hierarchy lint passes** in 3.78 s, invocation
`d325f58b68504a508c7ab7f6ea040469`; the six structural classes remain errors.

Both original **10-iteration CoreMark preflight seeds pass** under
`ventium-fp-exec-cm10-memdiv-query-oct12`, invocation
`d47f25f33bed4ac8aa5a509a13a5ab7d`. Both have all five correct CRCs and
exactly **4,767,218 / 4,753,406 ticks**, with **1,055,307 / 1,054,254 actual
V retirements**. They close in 206.73 / 206.64 seconds. The independent audit
rechecks 2,394 source pins, exact native argv/CPU11 affinity, real posted-16
board AXI profile, process closure and zero OOM events. These are neither
duration-valid scores nor full standard-suite seeds; no throughput gain is
claimed.

The [new synthesis preparation](prepare_memdiv_query_synthesis.py) and two
passing preparation tests retain the exact closed controller lifecycle:
one Vivado family, 8 GiB RAM / 6 GiB swap, 13 GiB combined early stop,
2 GiB host RAM/swap floor, 4 GiB disk stop, and initial disk reserve above
6 GiB plus twice historical measured growth above the stop floor. Mapper and
real clocks are unchanged. The independent timing audit compares the original
memory-divide checkpoint and must reproduce its **−9.391 ns / 29.077375 MHz**.
The [queue](run_memdiv_query_timing.py) cannot start/restart synthesis or
deploy; it distinguishes audit completion from actual attainment of 40 MHz.

Synthesis was launched October 12 at **12:45:58 UTC**, service
`ventium-memdiv-query-synth-oct12`, invocation
`8720fc70120341cd9bb0c85f20bc6938`. Its single owned Vivado family used
scope invocation `6d6b2a938d314a669853f187fa1bf2cf`, with 8 GiB RAM,
6 GiB swap and 48-task limits. Native outputs are in
`memdiv-query-synthesis-r1`; the completed checkpoint/Fmax audit is below.
Timing-queue invocation `2cf0d0fe3bfb4917a806bd3aa99a102a` adopts this exact
owner, then audits native closure and runs the independent timing measurement.
No routing or board programming is authorized by either controller.

For disk headroom, six closed historical timing-report sets are losslessly
archived as `memdiv-query-reserve-reports.tar.gz`: 1,602,557,831 original bytes,
70,392,864 archive bytes, every member hash verified. Models, source inputs,
checkpoints and current pins are retained. Four closed-build precompiled-header
caches (376,609,210 bytes) were removed; they are regenerable build products,
not source files or model binaries.

Gameplay baseline: **0.51030715 total U+V simulated retirement-event IPC**,
older `2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. This candidate is
gameplay-unmeasured; no IPC gain is claimed. The measured Fmax change is below.

### Closed timing result and next measured dependency

The synthesis above closes native zero in **1,999.33 seconds**, with all
**2,785 input pins** checked and exactly the intended one-header difference.
Peak guarded memory is 8 GiB, swap is zero, and no OOM/resource stop occurs.
The source-matched mapper and clocks are unchanged:

| Resource | Memory-divide parent | Query selector |
| --- | ---: | ---: |
| CLB LUTs | 186,597 | 186,766 |
| Registers | 54,817 | 54,831 |
| BRAM tiles | 277.5 | 277.5 |
| DSPs | 47 | 47 |

The independent clock/netlist audit closes native zero in **491.09 seconds**,
invocation `f739dd7fce474279ae52ef4ab6414fad`, with **2,798 input pins** checked,
peak memory 4,726,325,248 bytes and zero swap/OOM. It reproduces the original
parent's **29.077375 MHz / −9.391 ns**, verifies actual 40/100 MHz clocks and
reports the candidate at **30.676729 MHz / −7.598 ns**: **+5.50%** estimated
Fmax, still **not 40 MHz**. Core hold slack is −0.101 ns. Neither result is
routed sign-off or a measured physical clock; no bitstream is built/deployed.
The inherited PS-IP `create_clock` synthesis warning is retained, not waived;
the actual post-synthesis clock objects pass the independent audit.

The 30 reported worst setup endpoints are now **19 GPR bits, 10 EIP bits and
one retained V-read-valid bit**, instead of the parent's D-cache LRU bits.
The worst path has **110 logic levels**, data delay **32.387 ns** (6.410 ns
logic plus 25.977 ns unplaced estimated routing). It still traverses raw
decode/AGU/DTLB, next-read eligibility, load/store-pair readiness, backing-write
admission and the general ACK, then `pipe_v_pair_now_accept` and GPR writeback.

The next selected experiment is therefore the
[immediate paired-load read-ACK cut](PAIR_NOW_READ_COMPLETION.md), which changes
that one read-only consumer to the existing fragment-qualified read ACK.
The separately microtested [SMC address proposal](SMC_ADDRESS_TIMING.md) is
**deferred**, not automatically compiled/synthesized: it does not remove the
new worst path. Full canonical and standard/physical acceptance remain open.
