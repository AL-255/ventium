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

Both short cold CoreMark transfer checks and their independent audit **pass**,
retained owner `b2eee78444af48f19a4602c39b9d80e0`. Expected performance and
validation CRCs match QEMU. The benchmark intervals are exactly the parent's
**4,767,218 / 4,753,406 cycles**; final V retirement counts are
**1,055,307 / 1,054,254**. Native runs close zero in **208.342 / 203.631 seconds**,
with unchanged inputs, no OOM and all children reaped. These 10-iteration seeds
are **not duration-valid scoring or standard-suite acceptance**.

The exact-owner preflight queue closed successfully and launched synthesis at
**2026-10-13 01:46:48 UTC**:

- Native controller: `ventium-payload-region-synth-oct12.service`, invocation
  `cdbc6f773cad4361a08df3e4588c6d18`.
- Sole Vivado scope: `14d45806f37c4ecdacba205e00507cbc`, capped at **8 GiB RAM /
  6 GiB swap / 48 tasks**, with the original resource early-stop checks.
- Matched report observer: `ventium-payload-region-report-queue-oct12.service`,
  invocation `2f76bcfe5baa42008b89a920cbd28fd7`. It audits native synthesis
  closure before launching the original-clock checkpoint comparison.

These jobs are live, not acceptance results. Neither observer retries, routes
or deploys. On interruption, inspect these owners; do not duplicate their jobs.

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
After the seed audit, the closed PC compiler's two precompiled-header caches
were retained as adjacent byte-verified `.gch.gz` files, reclaiming another
**159,455,641 bytes**. `payload-region-pc-pch-closed.json` records exact paths
and hashes; `gzip -dk` restores each cache. The executable, harness object,
generated headers, sources and all provenance inputs remain unpacked.

Synthesis/timing and full standard-suite/physical FPGA acceptance remain
required. No frequency gain is inferred from this edit alone.

## Pending follow-up: new-memory CS-extent cofactor

The parent critical path also traverses the reference decoder's `d_len` and
the combined `cs_extent_fault` before `pipe_load_req`. A fast new memory
request already requires `S_PIPE`, no retained packet, and every integer
pre-issue guard. At that consumer, the `S_DECODE` fault arm cannot contribute,
`pipe_cs_issue_eligible` is true, and `pipe_u_eff.len` equals `u_d.len`.

[The unpromoted recipe](prepare_pipe_mem_cs_extent.py) therefore gives only
new load/store admission a direct **33-bit** live-length CS-limit predicate.
The complete global fault signal, exception delivery and held-request muxes
remain byte-identical. Simulation-only comparisons check both complete new
request outputs, including rejected requests. There is no register, new cycle,
feature define or mode fallback. **The running PAYLOAD-REGION synthesis does
not contain this follow-up.** No integrated model or Fmax is claimed for it.

[The small extracted-RTL miter](run_pipe_mem_cs_extent_leaf.py) passes **65,536
comparisons** across segment enforcement and FP-pipeline on/off combinations.
It uses the actual pinned pre-issue, global fault and request expressions,
including held requests. Two compiled mutants fail at the real overflow
corner `EIP=ffffffff, length=2, CS.limit=ffffffff`: losing the fault gate or
truncating extent arithmetic to 32 bits wrongly admits a load. Six independent
SMT queries prove the two-valued Boolean/33-bit arithmetic lemma and exhibit
unsafe global replacement, overflow and zero-length-underflow counterexamples.
The SMT model is not an automatic SystemVerilog proof.

Evidence: `pipe-mem-cs-leaf-r1`, retained native owner
`824ca5ee7b6b4db5a82bb37e354f04db`, **4.043 seconds**, peak **64,286,720 bytes**,
one CPU, no swap; four additional host tests pass. Closure SHA-256:
`b048b6e525e75b884f0aa398b2f53e9f3220dc90ec8bd1a51ddce00d34d2dbe3`.
The full-core source pin is
`7b6dcfe3c35b07bca3016c178cf81ebfb7cf104ea30d17e10b6f40b4c8a4506f`.
Before promotion, require native whole-core lint/build, CS-end/over-limit
load/store and held-packet regressions, unchanged canonical comparisons,
the full FP/fault/replay plan, PC transfer and measured timing. Complete
standard-suite and physical FPGA acceptance are still required afterward.

### Directed CS-memory fixture preparation

The older `pfetchlim` image gives CS a different base from DS/SS/ES; that
violates the deployed `VEN_SYS_FASTPATH_RELOC` common-base admission contract.
It remains useful for global fault delivery, but cannot qualify this fast
memory consumer. [The new fixture](t_pipe_mem_cs_extent.S) keeps all four bases
zero and varies only the byte-granular CS limit. Its 12 configurations cover
load/store, 2/3/6-byte ModR/M encodings, and exact-end/one-byte-overrun cases.
The exception handler checks **#GP(0), saved CS, exact fault EIP and count**;
the guest checks both the load destination and store-memory witness. Exact-end
accesses must commit before a next-fetch fault; overrun accesses must not commit.
Guest WBINVD provides a cold data line without host state injection. A taken
branch isolates the memory instruction from the preceding V slot.

`prepare_pipe_mem_cs_fixtures.py` assembled all 12 images and checked their
actual opcodes, descriptor bytes, copied jump targets, reset vectors and fail
doors in **0.654 seconds**, single CPU. Four host tests passed, including 60
deliberately corrupted image checks. Evidence: `pipe-mem-cs-fixtures-r1`,
closure SHA-256 `73d221c3ab924dedfe538fe2dc035c25ebcc62e5c94815cc57670c2037aa36fa`.
**This is preparation, not a native core execution pass.** While the single
PAYLOAD-REGION Vivado family remains active, no new whole-core build or
regression was started. Still require execution against the parent/derivative
with real AXI latency 0/7, complete architectural/cycle A/B equality, and actual
new-request/held-owner evidence at the probe PC. A legal guest result or a U
trace label alone does not prove fast admission. Existing canonical failures
remain unwaived; QEMU's known CS-extent gap is not authority for these faults.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V retirement events/cycle**, model `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. It predates this candidate and is not FPGA or
full-timedemo IPC.
