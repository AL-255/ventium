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

Derivative L1 SHA-256:
`fd235f7706cba770ba898dd49d9d8c2a698b42e836c3716af204c2779b56816e`.
An independent rehash found no drift in the 37 leaf, 65 cache and 2,605
whole-core input/artifact pins. The full-state/cycle drivers
`run_read_owner_core.py` and `run_read_owner_regressions.py` retain the existing
paired-intent and wide-FP/fault regression plans, changing only exact model
identities and the one-file delta contract. Their native results are pending.
Closed cache compiler products were archived losslessly and byte-compared
before removing unpacked copies. Retain sources, generated headers, native
binaries, logs and receipts; recover products with each receipt's tar command.

## Remaining acceptance

The unchanged canonical gate is launched as
`ventium-read-owner-canonical-oct12.service`, invocation
`e51aa91bda764d1fbbf81687c99afcb5`; its result is pending. The parent
remains **7 PASS / 101 FAIL**, red and unwaived. Required next: complete QEMU and
parent whole-core state/cycle comparisons (including FP/fault/held/branch cases),
same-input replay, matched PC/FPGA transfer, CoreMark preflights, **≥40 MHz
synthesized Fmax**, routed setup/hold, full standard suite and physical UV-fast
Win95 cold desktop/UI plus original FreeDOS Quake complete timedemo. Compile or
cache-test success cannot replace those requirements.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V retirement events/cycle**, model `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. It predates this candidate; it is not FPGA or
full-timedemo IPC.
