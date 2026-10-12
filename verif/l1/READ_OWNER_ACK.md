# Current-owner read completion — October 12

Private derivative of [PAIR-INTENT](../../fpga/PAIR_INTENT_TIMING.md), whose
closed synthesized estimate is **31.651579 MHz**, still below **40 MHz**.
This derivative has no timing, gameplay or physical result yet.

## Change

The measured 107-level path reaches the FPU bank through speculative next-read
selection, selected cache tags, saved-window reuse and read ACK. Reuse the
[earlier absorption lemma](READ_ACK_ABSORPTION.md): during an active read, a
next lookup implies the exact saved owner `rd_match`, which already supplies
the guarded ACK. Otherwise lookup is not redirected, so saved-window ACK
alternatives can use current tags directly.

`prepare_read_owner_ack.py` accepts only L1 SHA-256
`d3ae3b048f3bb71859e2515fa6a39bcc6ab65db1a92c4d7a5ab9e58f0f01df95`.
It changes both read-only **and ordinary read** ACK alternatives. Actual reuse
signals, data selection, capture, backing requests, write ACKs and all cache
state remain unchanged. Code ACK eligibility uses the aligned current
instruction read: either hit-under-fill profile permits it during a data fill,
not a code fill. That removes the indirect selected-next extent dependency too.

The complete original read equation is retained as a simulation assertion
against general ACK. The existing read-only/general ACK assertion remains;
checking only two newly changed formulas against each other would be circular.
No added register, cycle, feature switch, memory port or timing exception.

## Closed evidence

All evidence below is relative to
`/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.

- `read-owner-leaf-r1` fails at **testbench compilation**, before simulation:
  the assignment extractor stopped at the first semicolon inside a conditional
  fill-eligibility expression. The failed driver is retained as `driver-r1.py`,
  matching its original input hash. R2 extracts the complete conditional block;
  the RTL derivative and comparisons are unchanged.
- `read-owner-leaf-r2` passes **220,480 binary vectors in each of three profiles**:
  ordinary hit-under-fill, data-under-instruction-fill, and no hit-under-fill.
  The native source miter includes actual code-access, selected-address extent,
  fill eligibility and intent equations. Five independently compiled mutations
  fail: missing saved owner, residency, cacheability, flush guard and code-fill
  exclusion. Native closure **38.238 seconds**, invocation
  `ea0b8c1c2fa44b718d34f68fb440a64d`. This is not arbitrary X/Z or reachability proof.
- `read-owner-cache-r1` passes the full-profile **128-set, two-way, 32-byte-line**
  banked-cache A/B test: **737,677 both-edge checks**, 414 next-read observations,
  66,339 wide responses, plus write-update, warm-store and payload-owner tests.
  All enabled outputs, FSM/owner state, tags, valid/LRU and every data-bank word
  are compared. No hierarchical state writes. Removing the saved read owner
  fails natively at `PARALLEL-CACHE-MISMATCH output c_read_ack`.
  Native closure **18.559 seconds**, invocation
  `3f8d1ec29a8e42f4bd10fa35cc55d476`; six structural warning classes remain errors.
- `read-owner-core-r1` builds in **20.423 seconds**, invocation
  `04158a2b1aae4b8d8f8b113971503702`, unchanged input pins. Only `ven_l1d.sv`
  differs among 195 payloads; all 152 defines remain. The private harness object
  is local and uses its matching generated header. Model SHA-256:
  `3091744d8c87eef66ed5c598d43575a80e2e8de6d0790a478de96fb0b96cb9d2`.
- `read-owner-fp-r1` passes **384 fixtures / 1,536 measurements**, with complete
  QEMU state comparisons and **768 zero-cycle-delta** A/B comparisons, in
  **68.111 seconds**. Native unit invocation
  `bc994c1e6ba34f4780b8c46fa9868237` closed successfully; this uses the actual AXI
  backend at latencies 0 and 7 with paired execution, not a gameplay benchmark.
- The unchanged canonical gate closes in **395.488 seconds**, native `make`
  exit **2**: **7 functional PASS / 101 FAIL**, red and unwaived. All 20 cycle
  traces equal the parent, and an independent rehash confirms 2,609 unchanged
  pins. No mask, golden or cycle band changed. Owner
  `e51aa91bda764d1fbbf81687c99afcb5` closed as a failed unit, not a passing gate.
- `read-owner-checks-r1` passes all **eight corpora / 4,240 native probe runs**
  in **307.384 seconds**, owner `d43c725466f146fcb04030ed335bcae4`: load/store,
  held requests, branches, integer, FP, AGI, reference hints and AGI/stores.
  QEMU/full-state/cycle comparisons and the original read-ACK assertion pass.
  Aggregate probe coverage exactly matches the parent: 21,190,336 clocks,
  18,172 AGI offers, 24,352 reference offers, 282,808 prime offers, zero
  retained next owners, 5,616 intent clocks, 3,072 pair requests, 1,872 accepted
  pairs and 1,536 shape-only overlaps. These counts aggregate separate native
  executions; they are not unique workload cycles or gameplay IPC.

Derivative L1 SHA-256:
`fd235f7706cba770ba898dd49d9d8c2a698b42e836c3716af204c2779b56816e`.
An independent rehash found no drift in the 37 leaf, 65 cache and 2,605
whole-core input/artifact pins. The full-state/cycle drivers
`run_read_owner_core.py` and `run_read_owner_regressions.py` retain the existing
paired-intent and wide-FP/fault regression plans, changing only exact model
identities and the one-file delta contract. The wider FP/fault plan **passed
all 12 phases in 615.529 seconds**:
`ventium-read-owner-regressions-oct12.service`, owner
`bbfbd546679f444fb1dd1e36e7ce7128`, guarded scope
`a2c9f0f3793f44db8409e663e2fe2360`, actual CPUs **0–7**. Its 12 phases include
six operand-boundary matrices, FP faults, integer, memory, held requests,
branches and same-input canonical replay. All **32 FP fault runs** pass full
QEMU state comparisons. Replay passes **108 programs / 80,800 records**, without
masking the unresolved canonical failures. Independent checks rehashed 2,629
input pins and every phase's native receipt; all remain unchanged.
Six source-transfer tests pass, checking the exact one-file core/PC/FPGA delta
and rejecting missing edits, added bytes, wrong parents and reapplication.
`read-owner-soc-r1/prepared.json` prepares the full-PC transfer: all 102 shared
core/FP sources match, only L1 differs from PAIR-INTENT, and the same 156
simulation defines and posted-16 transport remain. Its build controller
`ventium-read-owner-soc-oct12.service`, invocation
`8a8556872377450fbc5047b88c9cbad5`, **closed successfully** in **177.357 seconds
including its shared-lock wait**. The private host object uses the matching
generated root header. The inherited **98 full-SoC structural warnings** are
unchanged, not a clean full-SoC lint result. Model SHA-256:
`ab2a70233aebf761de2e81019c16459d86805ac7a2f2b9730bcabcc918534440`.

The new `read-owner-fpga-r1` export passes its source contract: **190 payloads**,
**170 matched HDL inputs**, **158 hardware defines**, unchanged 40/100 MHz
clocks, full P5 caches and posted-16 transport. Only `ven_l1d.sv` differs from
PAIR-INTENT. Manifest SHA-256:
`90e4ec12f6d61699a175484366450a41d67a8d7b1717b3d228f8b5b0ab8bb87c`.
Strict CPU-hierarchy lint passes in **3.878 seconds**, invocation
`5ec358f7611149a2a0f7626d5b0a8cd2`; six structural warning classes remain errors.
This is not full-SoC lint, timing closure or hardware acceptance.
Five synthesis-preparation tests also pass. The planned controllers retain the
closed resource lifecycle byte-for-byte, require the complete FP/fault matrix
and replay evidence, and use **PAIR-INTENT / 31.651579 MHz** as both source and
timing control. The native Tcl timing audit and original 40/100 MHz clocks are
unchanged. These tests do not generate or launch a Vivado run.
The checked controllers have now been generated under
`read-owner-{synthesis,clock}-r1`; preparation itself launched no Vivado.

Short cold CoreMark preflight owner `32c0d97ff9bf4d57b6e96b10c3475eb5`
(`ventium-v-carry-cm10-read-owner-oct12.service`) has closed the performance
seed in **214.776 seconds**: correct CRCs, **4,767,218 benchmark cycles**,
3,409,929 U and 1,055,307 V retirements at the final 13M-cycle observation.
Validation is still running. These 10-iteration runs deliberately do not meet
CoreMark's duration requirement; neither a valid CM/MHz score nor an error-free
standard-suite pass is claimed.

`ventium-read-owner-synth-queue-oct12.service`, invocation
`a6b99406107a457eb2a05496d39b33cb`, observes that exact CoreMark owner. Only
after both seeds close and the independent audit passes does it compact the
closed PC PCH caches, launch one existing guarded synthesis controller and
register its exact-owner timing observer. The queue cannot retry synthesis,
route, deploy, waive canonical failures or relax native resource reserves.
No new timing result is available yet; **31.651579 MHz** remains the latest
closed synthesized estimate, below **40 MHz**.
Closed cache compiler products were archived losslessly and byte-compared
before removing unpacked copies. Retain sources, generated headers, native
binaries, logs and receipts; recover products with each receipt's tar command.
The closed FP matrix was independently recompared (208,128 candidate records)
before archiving 11,916 trace/log files: **487,358,972 → 29,591,438 bytes**, every
member hash verified. The archive is `closed-read-owner-fp-text.tar.gz`, SHA-256
`e84a0c496f9cf5a243501fab2565747bc3833ae2919b4d8744d58528e4740e03`.
Restore with `tar -xzf closed-read-owner-fp-text.tar.gz -C /home/yukidama/external/tmp`.
All protected pins remain unchanged; this is recoverable compaction, not loss
of native failure evidence or acceptance-trace filtering.
The eight-corpus closed logs/traces are likewise recoverable from
`closed-read-owner-checks.tar.gz` (38,352 entries, **969,164,582 → 87,746,209
bytes**, SHA-256
`3ecd43995b4366ac9466f5eaf1d23eded20abe2af717ef02fb9c3aab50e6d70f`).
Restore this archive with `tar -xzf closed-read-owner-checks.tar.gz -C
/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`. Closed native
receipts and all pinned inputs stay unpacked and unchanged.
For synthesis headroom, 9,302 compiler intermediates from 39 explicitly
inventoried, closed models were compacted losslessly: **1,929,235,446 →
247,238,435 bytes**, recovering **1.57 GiB**. Model executables, input sources,
generated headers/dependency files and pinned inputs stay unpacked. Neither
active directed-core model was selected. Archive `closed-model-products.tar.gz`
has SHA-256 `ea6bd9047d80469ef51f242527acf87d2c0193917260915773d0ff6a45a99495`;
restore with `tar -xzf closed-model-products.tar.gz -C /home/yukidama/external/tmp`.
The native archive unit `72a7fbd77d4b42afaca2306bec585618` exited zero after
member-by-member hash verification and rechecking protected pins/binaries.
The 12-phase regression streams are likewise preserved in
`closed-read-owner-regressions.tar.gz`: **37,112 entries**, **997,530,444 →
86,224,638 bytes**, SHA-256
`0cf9f5daaf136c4246408852b19460f1a09e97067714dbefa9824e90df346884`.
Restore with `tar -xzf closed-read-owner-regressions.tar.gz -C
/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.
The closed directed-core PCH files are recoverable from their adjacent
`.gch.gz` files (`read-owner-core-pch-closed.json`); this recovers another
155,157,873 bytes without changing model inputs or executable binaries.

## Remaining acceptance

The canonical gate remains **7 PASS / 101 FAIL**, red and unwaived.
Required next: close both short CoreMark preflights and their independent audit,
measure **≥40 MHz
synthesized Fmax**, routed setup/hold, full standard suite and physical UV-fast
Win95 cold desktop/UI plus original FreeDOS Quake complete timedemo. Compile or
cache-test success cannot replace those requirements.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V retirement events/cycle**, model `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. It predates this candidate; it is not FPGA or
full-timedemo IPC.
