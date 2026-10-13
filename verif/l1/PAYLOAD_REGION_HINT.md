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

The unchanged canonical gate closed in **399.295 seconds**, owner
`c189bf42f3f24b36bad6dae226ff80c9`: native `make` exit **2**, controller exit **1**,
**7 functional PASS / 101 FAIL**, red and unwaived. All **20 cycle traces**
equal the parent and input pins remain unchanged. A separate historical-trace
comparison correctly **fails** for 107 functional cases: the independently
generated QEMU runs supplied different initial stack pointers (for example,
`mb_accimm`: parent `0x40800050`, candidate `0x40800040`). The unchanged worker
explicitly seeds RTL ESP from its own golden. Do not mask ESP or call that
cross-run comparison a pass; the full regression plan includes **same-input
replay** of both models and candidate self-reproduction.

The eight unchanged processor corpora **passed**, owner
`0d72abdc98e54d339f5b3f1f56a945d5`, **302.652 seconds / 4,240 native probe runs**.
QEMU/full-state/cycle comparisons and new region-equality assertions pass.
Aggregate coverage matches the parent: 21,190,336 clocks, 18,172 AGI offers,
24,352 reference offers, 282,808 prime offers, zero retained next owners,
5,616 intent clocks, 3,072 pair requests, 1,872 accepted pairs and 1,536
shape-only overlaps. These are separate directed executions, not gameplay.

The wide-FP matrix also **passed**, owner `dc065a605adc44359d9b2d017b77cc31`,
**70.119 seconds / 384 fixtures / 1,536 measurements / 768 zero-cycle-delta
comparisons**, on real AXI at latencies 0 and 7. Full x87/QEMU and complete
cycle-stream comparisons remain. Closure SHA-256:
`bf91f6479f56308dd5c5f7a124e0798b2132b280bbec166a13b777093dec5021`.

The **12-phase operand-boundary, fault and same-input replay** plan passed in
**617.338 seconds**, retained native owner
`9d9912a1caf843cf9613731c53625cd3`, output `payload-region-regressions-r1`.
All six boundary offsets pass, along with 32 fault measurements, 1,024 integer,
288 memory, 48 held-response cases and 2,560 branch measurements. The canonical
same-input replay passes **108 cases / 80,800 records**, including candidate
self-reproduction, without ESP masking. This closes the A/B input mismatch
above, **not** the original canonical gate's 7 PASS / 101 FAIL.

Seventeen host tests pass across source scope, driver/admission, exact
core/PC/FPGA transfer and guarded synthesis/timing preparation. The new timing
adapter retains the complete resource/watchdog lifecycle and byte-identical
native timing Tcl; its source/DCP comparison control is the actual 33.154300 MHz
INTENT-READY parent. No new candidate Fmax is available yet.

The native **full-PC transfer/build passed** in **24.205 seconds**, owner
`afc999c6ad294224a849f8758fb7e03e`. All 102 common RTL sources match the directed
model after exactly two changes; 156 simulation defines and posted-16 transport
remain. The unique local harness object uses the matching generated header.
All 98 inherited platform structural diagnostics are unchanged, not waived.
PC model SHA-256:
`ac3de53084d2638155c0d10d78827857bae0aae7cc6578f1f35acf769c50b893`.

The hardware freeze passes its native Tcl source contract: 190 payloads, 170
matched HDL inputs, all 158 original hardware defines and unchanged 40/100 MHz
clocks. Manifest SHA-256:
`5e5bdf083c4d2ba7f678a2fd46f9dab794d15fd1a286cc904497fdc6eb503603`.
Strict frozen-core lint passes in **3.879 seconds**, owner
`7b07ea9254a74429ab6c635a8abbed92`; this is not full-SoC lint.

Short cold CoreMark transfer checks are running under
`ventium-fp-exec-cm10-payload-region-oct12.service`, invocation
`b2eee78444af48f19a4602c39b9d80e0`. These 10-iteration seeds are not
duration-valid scoring or standard-suite acceptance. The exact-owner queue
`ventium-payload-region-synth-queue-oct12.service`, invocation
`d6b6dbcb9bff43f982ba037fbd52c8dc`, waits for both seeds and an independent
audit before launching one exclusive, resource-guarded synthesis and matched
original-clock timing audit. Neither observer retries, routes or deploys.
On interruption, inspect these owners; do not duplicate their jobs.

Derivative source SHA-256:

- L1: `3a11ad8b8ce9e7569b0b1b144fe3666414186046e8e05fc1aff82e8aa5f1b874`.
- Seam: `1ba072672d09c4228017e64c11d3dd0506c4bddb5dc5a1a72924ea6defc2015d`.

To preserve disk reserve, **355,203,913 bytes** of closed generated compiler
products were reclaimed using byte-verified recoverable archives. Native
executables, headers, dependency files, all sources and **3,616 protected input
pins** were retained/rehashed. Receipt: `payload-region-compiler-archive.json`;
restore each `compiler-products.tar.zst` with its recorded `recovery` command.
No active run data was removed.

The now-closed eight-corpus text is also recoverable in
`closed-payload-region-checks.tar.gz`: **38,352 entries / 969,241,198 bytes →
87,605,566 bytes**, with every archived member byte-verified before deleting
only its unpacked duplicate. Source/binary/receipt/input pins remain. Restore
with `tar -xzf closed-payload-region-checks.tar.gz -C` followed by the evidence
root above; receipt `closed-payload-region-checks-closed.json` contains its hash.

The closed wide-FP text is likewise recoverable in
`closed-payload-region-fp-text.tar.gz`: **487,386,668 → 29,588,731 bytes**,
11,916 byte-verified members. Before archiving, all 384 fixtures were rechecked
against QEMU and the complete A/B cycle streams; 208,128 candidate architectural
records were compared. Restore into `/home/yukidama/external/tmp` using the
command in `closed-payload-region-fp-text-closed.json`. All protected inputs,
native executables and receipts remain unpacked.

Closed regression text is recoverable from
`closed-payload-region-regressions.tar.gz`: **887,168,686 → 82,708,064 bytes**,
36,984 members; 128 explicitly pinned files were excluded, including fault
evidence needed by transfer admission. Restore into the evidence root. Seven
closed historical matrix runs were separately retained in
`closed-payload-region-reserve.tar.gz`: **1,825,082,160 → 149,236,802 bytes**,
79,440 byte-verified members; restore into `/home/yukidama/external/tmp`.
Their aggregate/per-case metadata, current source/freeze inputs and executable
models remain unpacked. Both archives have corresponding `*-closed.json`
receipts with hashes; historical traces must be restored before replaying them.

Synthesis/timing and full standard-suite/physical FPGA acceptance remain
required. No frequency gain is inferred from this edit alone.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V retirement events/cycle**, model `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. It predates this candidate and is not FPGA or
full-timedemo IPC.
