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
identities and the one-file delta contract. The wider FP/fault plan is running:
`ventium-read-owner-regressions-oct12.service`, owner
`bbfbd546679f444fb1dd1e36e7ce7128`, guarded scope
`a2c9f0f3793f44db8409e663e2fe2360`, actual CPUs **0–7**. Its 12 phases include
six operand-boundary matrices, FP faults, integer, memory, held requests,
branches and same-input canonical replay. No result is claimed yet.
Six source-transfer tests pass, checking the exact one-file core/PC/FPGA delta
and rejecting missing edits, added bytes, wrong parents and reapplication.
`read-owner-soc-r1/prepared.json` prepares the full-PC transfer: all 102 shared
core/FP sources match, only L1 differs from PAIR-INTENT, and the same 156
simulation defines and posted-16 transport remain. No compiler or new FPGA
export has started yet; this is explicitly unqualified.
Five synthesis-preparation tests also pass. The planned controllers retain the
closed resource lifecycle byte-for-byte, require the complete FP/fault matrix
and replay evidence, and use **PAIR-INTENT / 31.651579 MHz** as both source and
timing control. The native Tcl timing audit and original 40/100 MHz clocks are
unchanged. These tests do not generate or launch a Vivado run.
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

## Remaining acceptance

The canonical gate remains **7 PASS / 101 FAIL**, red and unwaived.
Required next: complete QEMU and
parent whole-core state/cycle comparisons (including FP/fault/held/branch cases),
same-input replay, matched PC/FPGA transfer, CoreMark preflights, **≥40 MHz
synthesized Fmax**, routed setup/hold, full standard suite and physical UV-fast
Win95 cold desktop/UI plus original FreeDOS Quake complete timedemo. Compile or
cache-test success cannot replace those requirements.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V retirement events/cycle**, model `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. It predates this candidate; it is not FPGA or
full-timedemo IPC.
