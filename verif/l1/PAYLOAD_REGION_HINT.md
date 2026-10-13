# Payload-only cache-region hint — October 12

Private successor to [INTENT-READY](READ_OWNER_ACK.md), whose audited
post-synthesis unplaced estimate is **33.154300 MHz**, below the **40 MHz**
requirement. This successor has **no measured Fmax** and is not promoted to
production RTL. UV/fast mode, full P5 caches and all 152 core defines remain.

## Change and limits

The measured parent path traverses `core_mem_wstrb` → `core_d_last` →
cacheability → `shadow_payload_select` before the U ALU and paired V branch.
The saved code/data payload discriminator redundantly consults the complete
first-and-last-byte memory-type query even though it already requires an
**aligned dword**. Every current 430FX map boundary is at least 16 KiB aligned;
any selected byte of an aligned dword is in its first byte's map region.

[The two-file recipe](prepare_payload_region_hint.py) adds
`c_payload_cacheable` under the existing payload-hint profile. For the no-L2
integration it is the existing first-byte cache-map result AND not CR0.CD.
Only `code_payload_access` consumes it. The separate L2/ignore-CD diagnostic
policies retain their existing cacheability result; neither is enabled here.
Original width/alignment/code-kind checks and every response-owner comparison
remain. **ACK, capture, tags, LRU, backing requests and their complete access
extent checks are unchanged.** No register, extra cycle, cache port, timing
exception or guest-specific condition is added.

The original complete consumed-data mux assertion and all payload-owner
assertions remain. The seam additionally asserts equality of full and hinted
cacheability on each admitted aligned access. Changing cache-map granularity
requires requalification; the recipe/build admission pins its exact source.

## Closed evidence

Evidence root: `/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.

- `payload-region-leaf-r1`: **262,144 vectors**, arbitrary saved data and owner
  combinations, actual unchanged cache-map RTL in ordinary and high-memory
  simulation profiles. All original controls, low/high data and selectors match
  on **every vector**, not merely ACKs. Includes all strobe masks, CD, PAM,
  holes, SMRAM, TOM, wraparound and region-edge addresses. **4,413** vectors have
  differing full/hinted cacheability; alignment excludes these differences
  from code payload classification. Two compiled mutants fail on actual data
  comparisons: dropping CD and dropping alignment. **13.036 seconds**, native
  owner `722b6cf1b63641f5a7ac0da5795d2db8` closed zero.
- Z3 proves the **address-arithmetic lemma**: an aligned 32-bit address plus
  any offset 0–3 retains bits 31:14 (`unsat` counterexample). Removing alignment
  produces a counterexample (`sat`). This is not a symbolic proof of the
  decoder or cache FSM; those are exercised natively.
- `payload-region-cache-r1`: full 128-set/two-way/32-byte-line cache A/B passes
  **747,037 both-edge checks**, **463 next-read observations**, **66,339 wide
  responses**, and the original **51 fresh-capture corner cases**. Compares
  enabled interfaces, response owners, both saved windows, every data-bank
  word, tags, valid bits and replacement state. Deliberately differing hints on
  unaligned traffic do not change state or data. **12.144 seconds**, owner
  `f1e8aa899531495ab89a5c30379fd608` closed zero.
- `payload-region-core-r1`: guarded **32-job** native build passes in
  **20.432 seconds**. Exactly the intended two files differ among 195 payloads;
  all 152 defines remain. A unique private C++ harness object and its matching
  generated header are checked. Model SHA-256:
  `3a91aa88841f949855d27e0ed500064854ad9b24390c318629054de858061164`.
  Owner `53d261b56eb34fb0a588e92c1942dcc3` closed zero.

The unchanged canonical gate is running, owner
`c189bf42f3f24b36bad6dae226ff80c9`. Its parent's result is **7 PASS / 101 FAIL**;
compilation and cache tests do not waive that debt. Further whole-core
regressions, native transfer, synthesis/timing and full standard-suite/physical
FPGA acceptance remain required. No gain is inferred from this edit alone.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V retirement events/cycle**, model `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. It predates this candidate and is not FPGA or
full-timedemo IPC.
