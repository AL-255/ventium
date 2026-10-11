# Paired-memory readiness timing cut — October 11, 2026

**Directed checks pass; no new synthesized Fmax or FPGA acceptance yet.**
The target remains **at least 40 MHz synthesized Fmax**, with UV dual issue,
system/relocated fast paths, fast loads/stores and full P5 caches retained.
The measured predecessor is only **27.83654 MHz** (unplaced synthesis estimate).

## Change and rationale

Its worst reported path has 122 logic levels, from `eip_reg` through decode,
next-read address/permission qualification, L1 paired-store readiness and backing
acceptance to `pipe_mem_v_hit_q`. The readiness logic unnecessarily refers to
the selected next-lookup address/tag even in contexts excluding that lookup.

[`prepare_pair_ready_cofactor.py`](../verif/l1/prepare_pair_ready_cofactor.py)
changes only private `ven_l1d.sv`, on the descriptor-corrected predecessor:

- `c_req` excludes `mc_lookup_prime`; a current store also excludes
  `mc_lookup_old`. Store-pair readiness consequently needs neither next lookup.
- For a current read, the surviving exclusion is `c_next_req && rd_match`.
  Retain it: dropping it incorrectly admits a V store while the read-ahead
  path owns the cache lookup. This deliberate defect is a negative test.
- Read readiness uses the existing parallel **current** tag result and saved
  window identities. The common readiness predicate retains cacheability,
  reset, flush, snoop, state, stream/code exclusions, backing credit and shape
  checks. It does not make a saved line valid without a live resident tag hit.
- Aligned full dwords cannot cross a 32-byte line; the selected-address
  `xline` calculation is redundant in these predicates.
- The corresponding store/read-capture cofactor removes the same redundant
  terms. `VEN_P54_STORE_LOAD_PAIR` remains **disabled** in the actual target;
  this conditional branch has symbolic coverage, not an enabled target result.

No register, cycle, new cache port, speculation permission or fallback is added.
Request/ACK equations, array writes and registered response ownership are not
changed. Simulation-only assertions compare both changed predicates against
their original expressions on clock edges. All unrelated source bytes remain
unchanged. This is an exact dependency simplification, not yet a demonstrated
timing gain; next-read eligibility still has real dependencies elsewhere.

## Verification

Evidence root:
`/home/yukidama/external/tmp/ventium-pair-ready-cofactor.btYwXlBN`.

The [symbolic checks](../verif/l1/test_pair_ready_cofactor.py) find no binary
counterexample for readiness or store/read capture, including symbolic addresses,
strobes, lookup state and feature combinations. Three incorrect variants do
produce counterexamples. This proof models the predicate implications; it is
not a formal proof of the entire cache or processor.

The [cache miter](../verif/l1/run_pair_ready_cofactor.py) runs the actual old and
new full-size caches, preserving the existing store/coherence fixtures and
comparing outputs, tags, validity, replacement state and every data-bank word.
Six configurations cover FF/LUTRAM tags and zero/one/two saved windows:

- 1,934 sampled half-cycle states, 96 pair-ACK samples, 204 rejected store
  lookahead samples in total. These sample counts are not unique instructions.
- Snoop cancellation, backing-credit/backpressure, withdrawal, same-bank
  rejection, independent hit/miss tags and window invalidation remain checked.
- Each configuration creates a real primed U response, confirms next-read/V-store
  exclusion, withdraws the hint in the same cycle, and checks exactly one V
  backing write. No state is injected.
- The first negative run exposed the historical fixture's `$finish` after a
  printed FAIL (native exit zero). Revision 2 preserves every check and adds a
  fatal exit for nonzero error count. The deliberate missing-exclusion defect
  now exits **1**; all six positive runs exit **0**. Revision 1 remains recorded
  as a failed test-flow run, not a pass.

Revision 2 closes in 31.54 seconds, invocation
`1a80ae8ce1bb4c25beef3a597f34e81c`; receipt SHA-256:
`2e3be97ff0d8a02008060e530ed5dc680bd380cc52c387a375494da31d2e81df`.

The [full core builder](../verif/l1/build_pair_ready_core.py) retains all 195
source files and 150 distinct UV-fast definitions, changing only `ven_l1d.sv`.
It verifies the private C++ harness uses its own generated model header.
Guarded-32 native build: 19.88 seconds, invocation
`2c01f05bf660433f9159fca82e0b603e`.

| Cold paged corpus | Cases | Candidate architectural records at AXI 0/7 | Candidate V witness |
| --- | ---: | ---: | ---: |
| Paired reads/read-ALU, same-bank and split rejection | 72 | 31,392 | 1,500 memory V retirements |
| Load/store pairs with post-store data readback | 72 | 32,112 | 456 memory V retirements |
| FP/integer/memory overlap | 72 | 39,024 | Paired execution and FP early-command checks retained |

All three pass complete fresh-QEMU architectural comparisons and complete
predecessor/candidate architectural **and cycle** equality, including relocated
paging and instruction-line seams. No terminal trimming, register masks,
golden changes, guest STEP, snapshot or pairing-disable control is used.
Together: **102,528 candidate architectural records**, zero measured clock-count
change. This is **0% cycle-count gain**, not a measured Fmax/gameplay gain.
Independent rehashes confirm their pinned inputs after native closure.

Model SHA-256:
`64e997d504e7f73fcd1f6b5e524a68cb6f901bf88f44b97fb613dfa1adf9d055`.
Changed L1 SHA-256:
`1d8a499aff0093a0861b20ec9faefee0820672cefe42d47504cd53f9ef71277b`.

## Full-PC and hardware-source continuation

The unchanged canonical gate closes **FAIL**, native exit 2, in 388.21 seconds
under invocation `34068c0081984225a386eecaee9d30b5`. All 20 complete cycle
traces match the predecessor, and all 688 input pins were independently
rehashed. A matching A/B failure is not a canonical pass; no canonical mask,
golden or cycle band changed.

The [full-PC builder](build_pair_ready_soc.py) rechecks all 102 shared RTL
sources against this core, preserving the platform and 154 simulator definitions.
Relative to the measured exact-fragment platform, its only three RTL deltas are
the two [descriptor-width corrections](DESCRIPTOR_READ_EXTENT.md) and this L1
cofactor. Native compilation closes successfully in **22.34 seconds**, invocation
`506a50659a324b01a1eaa2ae257f353a`, with the private harness bound to its own
generated header. The 98 inherited platform structural warnings are unchanged
debt, not a full-SoC lint pass. All 597 build input pins were independently
rehashed. New full-PC model SHA-256:
`6583d6577f3099fe0e84bf52762516300843a8c1658f5cc373ec8c2240dcc090`.
No old performance result qualifies this new binary.

Queue invocation `b172564a5ba04239b3dab9b8196ab6dd` then runs both unchanged short
CoreMark disks. The performance seed closes native zero in 199.97 host seconds,
with all five reference CRCs and **4,767,218 ticks**, unchanged from the parent;
it records 1,055,307 V retirements. The validation seed is running under
`6f65614c784e4b26af74d9009165a6f1`. These ten-iteration CRC/cycle checks are
**not** duration-valid scores or the full standard suite. The reported diagnostic
ratio is not a new qualified CM/MHz score. The parent/candidate audit follows
true native closure, not merely the completed guest console.

The [hardware freezer](freeze_pair_ready_rk_candidate.py) closes successfully
under `e18dcd7d19e74518b99ca344b82a9bec`. It preserves all 190 payload paths,
156 hardware definitions, 40/100 MHz clocks, posted-16 transport and filelist
closure (117 units / 49 include edges). Exactly the three RTL deltas above are
admitted from the compiled model; no dirty checkout source is substituted.
The real Tcl source-contract check passes. Independent rehash checks cover its
796 input pins and all exported payloads. Manifest SHA-256:
`2d573cb347eaa630a7010f197d2ee0788f2aeef8340c6bb24d06767dd9712ece`.

Strict CPU-hierarchy lint passes in 3.68 seconds under
`7eb83a747d714f7389eb47d7310cb5c1`, using all 156 hardware definitions with the
six structural warning classes fatal. All 195 input pins are independently
rechecked. This does not qualify the full platform's existing warning debt.

The [timing-controller derivation](prepare_pair_ready_timing.py) retains the
closed predecessor's complete native launch/monitor/stop/reap lifecycle verbatim.
It retains one Vivado family, the shared build lock, 8 GiB RAM / 6 GiB swap caps,
the 13 GiB combined early-stop limit, 2 GiB host reserves and 4 GiB disk stop
floor. Synthesis admission still requires over 6 GiB free disk and twice
measured parent growth above that floor. It does not kill user applications.

Timing queue `e46bc1ace6b943998fc4f84738c31f11` waits for exact full-PC/CoreMark,
freeze and lint owners before one synthesis and the independent original-clock
report/audit. Both candidate and parent use the **diagnostic `logic_only`
(`-no_timing_driven`) mapper** for a matched comparison; this does not optimize
synthesis for timing or establish routed sign-off. The original 40 MHz
constraint and the requirement to actually reach 40 MHz remain unchanged.

Next: complete short CoreMark validation, guarded synthesis and original-clock
timing audit. Do not count a 40 MHz constraint, an overclock or an older DCP as meeting
the synthesized target. Green differential gates, full CoreMark correctness,
Win95 cold desktop/UI and complete Quake timedemo, including physical FPGA
validation of the actual new candidate, remain required.

Disk hygiene: 28 regenerable compiler PCH files from the two closed cache-test
runs were removed (2,340,612,753 bytes). Source, generated C++, objects, binaries,
headers and logs remain. Cleanup receipts list every exact target/hash; the PCH
files can be regenerated, but were not archived byte-for-byte.

Before synthesis admission, 13,087 byte-identical closed `.vtrace` copies across
eleven old experiment trees were consolidated as hardlinks, reclaiming
1,955,467,264 allocated bytes. **Every path and every byte remains available.**
The operation excludes current inputs and observable open files, checks hashes
before/after each atomic replacement, and retains a complete plan/event/closure
receipt under the evidence root. Separate a linked trace by copying it to a
fresh file before any intentional edit. No source, model, media, checkpoint or
unique trace was removed. Available disk rose to approximately 7.3 GiB.

Verified gameplay baseline: **0.51030715 total U+V simulated retirement-event
IPC**, older model `2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. This timing
candidate has no gameplay measurement or new FPS measurement.
