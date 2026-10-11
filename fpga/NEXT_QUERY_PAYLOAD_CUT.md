# Next-read address payload experiment — 2026-10-11 UTC

**Directed whole-core comparisons pass; canonical verification is unqualified.
No timing, gameplay, full-suite or FPGA pass.**
It is not included in the completed V-carry synthesis. The objective
remains at least 40 MHz synthesized Fmax with UV and fast pipeline retained.

The previous synthesized critical path traverses raw decode, address/permission
qualification, next-read selection and L1 lookup before returning through
memory acceptance. `core_mem_chain.svh` selects the live `mem_next_addr` using
the final permission-qualified `mc_prime_offer`, even when no retained
descriptor exists. This serializes live-address preparation after eligibility.

Let `A = agi_prime_select || ref_prime_select || mc_prime_offer`, `V` be the
registered retained-owner valid bit, `Q` the live physical query and `R` the
retained physical address:

```
old address = A ? Q : R
new address = (V && !A) ? R : Q
```

They differ only when `V=0` and `A=0`. In that case no next-read request can
exist: AGI and reference offers imply their selects; the ordinary chain offer
implies `V`; the prime offer is part of `A`. The driver checks those implications
against the actual pinned assignment expressions, rejecting top-level OR or
ternary guard bypass. No permission, request, commit, width/strobe, cached-data
owner, memory ordering or clock-edge predicate is changed.

Downstream review: `ventium_l1_axi` uses the address for next-region/SMM
qualification and passes it to `ven_l1d`; actual next lookup requires next
request. Both `mc_lookup_old` and `mc_lookup_prime` are request-qualified.
This is a conditional payload argument, not permission to discard ownership
or remove eligibility from cache effects.

## Evidence and limits

Parent header SHA: `e8cddd9561a4b69c3be59c53b99216bf87851e8732ab5be7e9770f8a372d6129`.
Proposed header SHA: `e142b3257cbb32b9e0592fa714919c74a7199a8423fea43391f4c7b3a21dcb61`.
Parent whole-core model: `8c8898416ab8af4e6e53f9c4d94e3d9c2bbd1020edce3abdb300272dfc8104d6`.
Evidence: `/home/yukidama/external/tmp/ventium-next-query-payload.sd8MaX6W`.

- Four recipe/guard-parser tests pass; all unrelated header text is unchanged.
- Actual source-extracted old/new address and request equations pass Icarus
  simulation of **4,096 samples**, all 128 Boolean control combinations with
  32 complementary walking-bit address patterns. **3,232 active requests**
  have identical addresses. The **256 inactive differences** are retained.
  Other permission/extent conditions are independent symbolic Boolean inputs,
  not an assertion that only successful accesses can happen.
- Both deliberate defects (always using the live address, or always using
  the retained address) fail the offered-address check with native exit 1.
- Leaf receipt SHA: `070aa4c8bba65ce924f9a12ba9f5f96f43a3c3f8f9a5eaf98481f1ab7d885ec5`.

The additional [seam regression](../verif/l1/run_next_query_seam.py) instantiates
the real `ven_cachemap` and extracts the unchanged seam permission, L1 lookup,
ready and capture equations from the frozen parent sources. It checks that
changing an inactive address cannot change lookup selection/address, ready or
capture. This includes 24 address boundaries, all 128 payload/offer control
combinations, 16 chipset configurations, and idle, owned-response, fill and
independently blocked-control cases. DRAM holes, PAM, SMRAM/save-aperture and
top-of-memory rejection remain active.

Both ordinary and prime-under-fill profiles pass **196,608 samples each**
(393,216 total), including 155,136 offers per profile. They observe 25,598 /
30,524 ready events and 13,966 / 16,652 captures respectively. In each profile,
12,032 inactive address pairs select different map regions without affecting
the observed lookup/handshake. Removing the request guard deliberately fails
both negative controls at sample 512 (`req=0`), native exit 1.

The native run closes in 3.73 seconds, unit
`ventium-next-query-seam-oct11.service`, invocation
`38db534638c048e48cf3eff8d5cf2176`; an independent read checks all 6,879 pins,
eight native exit/log receipts and both positive sample counts. Receipt:
`seam-r1/closed.json`, SHA-256
`633f3a12d53e4f3bf0a5638cd95c7fbdc7189c2debba494cf1b8ced88be0f478`.
Icarus reports expanded `always_comb` sensitivity for constant selects; those
diagnostics are retained. This is a **combinational seam test**, not a cache
array/sequential-owner test, whole-core differential pass or timing result.

The initial core-build helper selected `core.sv` instead of this header and
was rejected by the source-hash check before compilation. Its archived source
is `core/failed_build_driver.py`. Revision 2 fixes the target and checks it
before copying. Its build was cancelled while waiting on the shared heavy-build
lock held by the existing Vivado family; **no native compilation started**.
The cancellation receipt and original logs remain. Do not bypass the guard.

## Whole-core checks

After the V-carry synthesis and native timing audit closed, revision 3 built
natively in **12.37 seconds**, with only `core_mem_chain.svh` changed. The
model is `b191540ebf0e3038f7dfef1363dde38e2e73c6ca3e474bac624d6db98dafc59b`,
under `core-r3`; invocation `3fa56835e6cc49d194f4ea7e8dcbba0b` closes native 0.
Its private host object uses its own generated model header. The actual
Verilator command retains all **150 distinct RTL `+define` switches** and
the parent's C++ options; C++ `-D` switches are not extra RTL features.

The memory, FP and AGI matrices run concurrently with 4 + 16 + 12 workers:

| Corpus | Cold paged cases | Complete A/B architectural records | Additional witness |
| --- | ---: | ---: | --- |
| Integer memory | 72 | 31,392 | 1,500 targeted V-memory retirements |
| x87/integer | 72 | 39,024 | 7,220 early FP command accepts |
| Address dependency | 12 | 4,776 | All 350 AGI-priming accepts retained |

Both AXI latencies 0/7 pass the complete original QEMU comparisons and exact
parent/candidate retirement-state and cycle-stream comparisons. No state or
terminal record is removed. Native owners all close with exit 0; the longest
matrix takes 11.27 seconds. The independent audit rereads **18,080 pins**,
all 75,192 complete architectural records, the native exits and retained
terminal owners. Audit SHA-256:
`f150e0010da2e3eaaae307031029186c35fa8b05be5d533ea6a63d6b6ad483ef`.

### Canonical failures remain failures

The unchanged canonical `make verify` exits **2 / FAIL**: **7/108 functional
passes**, with **91 length-only failures** and **10 x87 `fstat` mismatches
plus length failures**. The first field differences in those ten cases are
C1 (`0x0200`): `tx_addsub`, `tx_chain`, `tx_cmp`, `tx_fp_denorm`, `tx_fprem`,
`tx_fxam`, `tx_muldiv`, `tx_round`, `tx_sqrt`, `tx_unifdiv`. They must be
investigated instruction by instruction; these are not all terminal-observer
failures, and clearing/masking C1 globally is not an acceptable repair.
No comparator, golden, record or cycle band was changed. Twelve of the 19
scored cycle cases also fail; all 20 complete candidate/parent RTL cycle
streams remain identical.

[The failure inventory](../verif/issue_uv/audit_canonical_failure_inventory.py)
reads all 108 retained functional traces (80,800 candidate records), preserving
every field and record. It does **not** claim their parent/candidate streams
are identical: only one is; independent canonical initial states differ,
including stack addresses. An initial inventory assertion incorrectly assumed
identical inputs and failed on `mb_accimm`; the corrected inventory records
the complete first differences instead of masking them. This does not change
the separate, same-input directed A/B comparisons above.
Inventory SHA: `0ae1deb7f6d7aa605ba9e97feeb4c4793dd46a996a53f0230399203a14390988`.

## Full-PC and hardware export

The native full-PC build closes with exit 0 in **14.64 seconds**; model
`bd5ec894072fd4f23123069594da525faa5605ea9d9ec3ed2715f93c25d3ebd0`.
All 102 shared RTL files match the directed model. The 154 simulator defines
and posted-16 transport remain unchanged. Its 98 inherited structural warnings
are recorded; this is not a full-SoC lint pass.

Both original short cold CoreMark seeds pass their original CRCs:

| Seed (10 iterations) | Parent clocks | Candidate clocks | Actual V retirements |
| --- | ---: | ---: | ---: |
| Performance | 4,767,218 | 4,767,218 | 1,055,307 |
| Validation | 4,753,406 | 4,753,406 | 1,054,254 |

The unchanged auditor compares the FP-only ancestor; the intervening carry
candidate has the same clocks. This is **0% cycle-throughput change**, not a
duration-valid CM/MHz score or a standard-suite pass. Audit rechecks 31,556
source pins, original media, CRCs, actual CPU-11 affinity and native child
reaping. Both owners exit 0 with no OOM. Audit SHA:
`9bab595aa1bef2e4f745892de9ef28dab3ceafb9de50b305f6dff1cc63e7a21c`.

The [exporter](freeze_next_query_payload_rk_candidate.py) retains all **156
hardware defines**, 190 payloads and the 117-unit/49-include source closure;
only `rtl/core/core_mem_chain.svh` changes from the carry export. Four exporter
tests pass. The first export refuses two previously unlisted historical driver
path aliases before copying; the final recipe admits only those exact aliases
and still checks their resolved paths and hashes.

Manifest SHA: `8d4d3998dcfdc6badf6e9999e871f6fe1de1fdda878ca6f981868cf18a1c5e77`.
Independent export audit checks 31,717 pins and all 102 shared directed RTL
files. Strict CPU-hierarchy lint closes native 0 in **2.29 seconds** against
that exact export; not a full-SoC lint pass.

Matched diagnostic synthesis starts at **00:47 UTC, October 11**, unit
`ventium-next-query-full-synth-oct11.service`, invocation
`3f8e52d02fde4c21a6b79389a05a0081`. The actual exclusive Vivado scope is observed
live, invocation `ff738a2cb56046849a3b732c7df3e4cd`, with the unchanged 8 GiB
RAM/6 GiB swap limits, 30-minute native cap, 4 GiB disk stop floor and host
memory reserve. A retained queue audits that exact run and then its original
40/100 MHz clocks; it never retries, places, routes or deploys automatically.

Before launch, lossless, verified archives recover about 1.08 GiB from six
closed models' compiler intermediates and four older models' generated C++.
RTL, private harness objects, executables, traces and reports are preserved;
per-model `generated-objects.tar.zst` / `generated-cpp.tar.zst` and their
receipts give exact restoration commands. No source pin is removed.

A native timing report must demonstrate any gain; this proposal does not
inherit the parent's 23.5855 MHz estimate or full-system qualification. The
40 MHz target, canonical gate, full standard suite and new physical FPGA
validation remain open.

Verified gameplay baseline: **0.51030715 U+V retirement-event IPC**, model
`2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. It predates both timing
experiments, which are gameplay-unmeasured.
