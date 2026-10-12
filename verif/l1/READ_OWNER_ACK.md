# Current-owner read completion — October 12

Private derivative of [PAIR-INTENT](../../fpga/PAIR_INTENT_TIMING.md), whose
closed synthesized estimate is **31.651579 MHz**, still below **40 MHz**.
Its closed synthesized estimate is **31.040477 MHz**, worse than that parent
and still below **40 MHz**. It has no gameplay or physical result yet.

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
(`ventium-v-carry-cm10-read-owner-oct12.service`) **closed both seeds**. Both
CRC sets and benchmark clocks match the controls:

| Seed | Benchmark cycles | Final U / V retirements | Host elapsed |
|---|---:|---:|---:|
| Performance | 4,767,218 | 3,409,929 / 1,055,307 | 214.776 s |
| Validation | 4,753,406 | 3,405,882 / 1,054,254 | 206.110 s |

Retirement counts are the final 13M-cycle observations, not gameplay. The
independent audit passes **3,258 source pins**, native argv/affinity/exit,
unchanged media and real posted-AXI transport, with zero OOMs. These
10-iteration runs deliberately do not meet CoreMark's duration requirement;
neither a valid CM/MHz score nor an error-free standard-suite pass is claimed.

`ventium-read-owner-synth-queue-oct12.service`, invocation
`a6b99406107a457eb2a05496d39b33cb`, closed successfully after observing that
exact CoreMark owner, auditing both seeds and losslessly compacting the closed
PC PCH caches. One synthesis started at **2026-10-12 21:33:25 UTC**:
`ventium-read-owner-synth-oct12.service`, invocation
`fdeeb7141fa4486c948a3208e6def744`, owned Vivado scope
`4ff50012167547d48350c57846b67c7a`. Its source/resource admission checked
**4,223 pins** and **7,390,146,560 bytes** of free disk.

Resource bounds remain **8 GiB resident / 6 GiB swap**, **13 GiB combined**
early stop, **2 GiB host RAM/swap** and **4 GiB disk** live floors, with one
native build family. The exact-owner timing observer is
`ventium-read-owner-report-queue-oct12.service`, invocation
`64cc20fa966446caa9e49a739c5da240`. It audits native synthesis closure before
launching the unchanged original-clock report. Neither queue can retry
synthesis, route, deploy, waive canonical failures or relax resource reserves.
Both native owners have now closed successfully, with unchanged input pins.
Synthesis took **1,979.322 seconds** and used **185,368 LUTs / 54,950 FFs /
277.5 BRAM tiles / 47 DSPs**: 1,056 fewer LUTs and six fewer FFs than PAIR-INTENT.
Peak resident usage was **8,589,848,576 bytes**, zero swap and no OOM. The
inherited PS8 scoped-XDC `Synth 8-3321` critical warning remains; successful
native closure is not a claim of warning-free synthesis.

The exact clock-report owner `d302db2cf5194128a1fce5b4d9ba53b8` closed in
**493.107 seconds**. The independent audit passes, reopens both DCPs with
the original **25 ns core / 10 ns PL** clocks, and reproduces the parent's
**31.651579 MHz**. READ-OWNER instead gives **31.040477 MHz** (setup
**−7.216 ns**, hold **−0.101 ns**). These are unplaced synthesized-netlist
estimates, not routed sign-off or measured board clocks. Area decreased but
worst timing regressed; do not promote this as a timing improvement.

The new worst path is `eip_reg[0]/C` → `pipe_mem_v_hit_q_reg/D`, with **111
logic levels** and **32.005 ns** data delay (7.062 ns logic / 24.943 ns estimated
routing). It traverses frontend decode, speculative-next request, selected
cache tags and fresh paired-bank admission. This directs the next experiment:
under a fresh current U read (`c_req && !rd_armed`), neither old-owner nor prime
lookahead can select the next address. Cofactor that admission using current
tags while preserving saved-window suppression, invalidation and byte extents.
Neither changing the clock constraint nor disabling pairing is a repair.
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
The same checked operation recovered **159,386,376 bytes** from the closed PC
PCH caches (`read-owner-pc-pch-closed.json`), also retaining adjacent verified
gzip copies. Restore an individual missing PCH with `gunzip -k <file>.gch.gz`.

## Fresh paired-capture follow-up — October 12

The measured V-admission path now has a private one-file derivative,
`prepare_fresh_pair_capture.py`. It accepts only the READ-OWNER L1 hash above.
For `c_req && !rd_armed`, `mc_lookup_old` is impossible because `rd_match`
requires `rd_armed`; `mc_lookup_prime` is impossible because it requires
`!c_req`. Therefore fresh U admission uses current tags directly. Its byte
or aligned-dword extent cannot cross a cache line. Idle excludes fill-forward;
the data-read guard excludes code reuse. Saved primary/shadow window identity
still suppresses redundant capture, with the original flush and offset rules.
In particular, bytes **29–31** cannot reuse the four-byte saved window.
The separate prime path, actual U capture, data selectors, bank reservation,
request/response interfaces and all sequential updates remain byte-identical.
The full original predicate and the no-next-lookup implication remain native
simulation assertions. No new clock, register, stall or pairing restriction.

Evidence below uses the same external root as above:

- `fresh-pair-leaf-r3`: **26 feature profiles × 179,264 binary vectors**,
  **4,660,864 comparisons**, pass in **32.045 seconds** with eight concurrent
  native simulations on CPUs 0–7. All **eight mutants fail natively**: wrong
  tags, lost primary/shadow suppression, flush qualification, byte extent,
  snoop, saved owner and dword alignment. Native unit
  `ventium-fresh-pair-leaf-r3-oct12.service`, invocation
  `df34956299634217b15315dcd18ef564`, closed zero. Equations are extracted from
  native-preprocessed source, not translated to a Python oracle. This is not
  exhaustive symbolic, arbitrary X/Z or sequential reachability proof.
- R1 failed at leaf **compilation**: the extractor consumed beyond a semicolon
  followed by an inline comment. R2 passed every positive profile but rejected
  a mutation anchor that also occurred in a comment. Both failed runs and their
  hash-matching `driver-r1.py` / `driver-r2.py` remain intact. R3 changes only
  extraction/mutation setup, not the RTL candidate or comparison requirements.
- `fresh-pair-cache-r3`: full 128-set/two-way banked cache A/B passes **747,037
  both-edge comparisons**, including **463 next lookups**, all enabled outputs,
  the existing owner/FSM checks and every tag/valid/LRU/data-bank entry. Its new
  public-traffic microbench checks **51 cases / 41 accepted U/V pairs / 123 held
  V observations / two saved-window cases / eight bank conflicts / four policy
  guards**. Every current byte position, byte 31 and every aligned dword are
  exercised. A missing-primary-window mutant fails. Native owner
  `a89bcc14721d44d7b1c6cfa984454a40` closed zero in **29.635 seconds**. No
  hierarchical cache writes or injected response owners.
- Cache R1 refused the incomplete leaf preflight, without compiling. Cache R2
  passed the older corpus and fresh reads but exposed a **new test setup error**:
  a cold critical-word response need not retain a complete reusable window.
  R3 establishes both saved windows by normal rereads of resident lines and
  explicitly checks their identities. The RTL derivative remains unchanged.
  Preserve the failed log and `fresh_pair_capture_leaf-r2.svh` reproducer.
- `fresh-pair-core-r1`: all **195 payloads / 152 defines** retained; only L1
  changes. UV, fast pipeline and actual AXI backend remain selected. The full
  model builds in **20.565 seconds**, native owner
  `9d6745a2a0a141af912ed4bb58bbb4e2`, with a unique local host object using its
  matching generated header. Independent closure checks rehashed **245 leaf /
  273 cache / 3,064 core pins** and verified all three exact owners exited zero.

Fresh derivative L1 SHA-256:
`182856870bdf5627a2c0c48180fbb2a2a604b679728b40d53e9811bb1df31d37`.
Whole-core model SHA-256:
`e1621913f28c5cd1c10b0c19f57bc59277807034dfb6b94a79bd7fe58d6a1a81`.

Canonical verification `ventium-fresh-pair-canonical-oct12`, invocation
`b9a31628a6d64d9fbf836522a98b787d`, **closed in 393.720 seconds**, native
`make` exit **2** / controller exit **1**: **7 functional PASS / 101 FAIL**,
still red and unwaived. All **20 cycle traces match READ-OWNER**. Independent
checks confirmed the exact failed owner and rehashed **3,068 pins**; no masks,
goldens or cycle bands changed.

Full FP `ventium-fresh-pair-fp-oct12` (`fddb7f232e1741559f1cbffd8b997918`)
**closed successfully in 67.579 seconds**: **384 fixtures / 1,536 native
measurements / 768 zero-cycle-delta comparisons**, actual AXI latencies 0 and 7.
Independent checks confirmed the closed owner and all 13 input pins. The
eight-corpus A/B checks `ventium-fresh-pair-checks-oct12`
(`2281576132ce48ea8e8e7cf3565f34b2`) **closed successfully in 303.706 seconds**:
**4,240 native probes**, with coverage identical to READ-OWNER: 21,190,336
clocks, AGI 18,172, reference 24,352, retained 0, prime 282,808, intent 5,616,
request 3,072, accept 1,872 and shape-only 1,536.

Six source-transfer tests pass for the new `build_fresh_pair_soc.py` /
`freeze_fresh_pair_rk_candidate.py` recipes: they match the actual tested core
delta and reject omitted edits, extra bytes, parent drift, reapplication and
unrelated changes. Five synthesis-preparation tests also pass. They preserve
the closed READ-OWNER native lifecycle, original 40/100 MHz clocks, full
FP/fault/replay/CoreMark requirements and resource floors. Source/area control
is READ-OWNER; the independent timing control remains the better PAIR-INTENT
checkpoint. These tests alone do not establish hardware acceptance.

The full-PC build `ventium-fresh-pair-soc-oct12`
(`58f090d1d4974b90a228998c000fdafe`) **closed successfully in 23.574 seconds**:
102 shared core/FP sources, one deliberate L1 delta, 156 simulation defines,
and 16 posted-write slots. Model SHA-256:
`bb5a251dd9e5e21c54450dad145993007921f0482f7edf778a10a9c16be9eb20`.
All 3,677 input pins were independently rehashed. The inherited **98 full-SoC
structural warnings remain unchanged**; this is not clean full-SoC lint.

The FPGA export contains 190 payloads, 170 HDL files and 158 hardware defines,
with unchanged 40/100 MHz clocks and full P5 caches. Manifest SHA-256:
`0c767b0435e78a86aa0f61907dff21f9a2184aedea071d209a1230eb10e4ced7`.
Independent rehashing checked all 190 payloads and 3,873 input pins. Strict
CPU-hierarchy lint `ventium-fresh-pair-lint-oct12`
(`edc2bd61b3ca4b4fb1516500a76e6444`) **closed successfully in 3.778 seconds**;
its 195 pins were independently rechecked. It is not full-SoC lint or FPGA
qualification.

Both cold **10-iteration** CoreMark diagnostic seeds
`ventium-v-carry-cm10-fresh-pair-oct12`
(`fd4ce700cf9e4337a1f638ac2f1cc80e`) closed successfully and were independently
audited: performance **4,767,218** ticks, validation **4,753,406** ticks,
identical to the control, with matching reference CRCs. Actual V retirements
were 1,055,307 / 1,054,254; the real posted AXI backend was active. All 3,719
source pins were rehashed, both native children were reaped, and no OOM occurred.
These runs are **duration-invalid**, not accepted scores or a standard-suite
pass. They show no measured cycle regression from this timing-only change.

Before compaction, all **208,128 candidate FP records** were independently
recompared against QEMU and the control. The **11,916** closed text artifacts
are preserved losslessly as `closed-fresh-pair-fp-text.tar.gz`, **487,358,972 →
29,595,082 bytes**, SHA-256
`3741484f8ee5bcd6ddc099c48abe19e33dbfe2aa23fb369e514e7eedf081039f`.
Every archive member was byte-verified before removing unpacked copies;
inputs, binaries and native closure receipts remain unchanged. Restore with
`tar -xzf closed-fresh-pair-fp-text.tar.gz -C /home/yukidama/external/tmp`.
The failed cache-R2 compiler intermediates were likewise archived with the
existing byte-checked helper; its native failure log, test binary and original
fixture remain unpacked. See its `compiler-compaction.json` for restoration.

Closed eight-corpus text is preserved as `closed-fresh-pair-checks.tar.gz`:
38,352 entries, **969,164,582 → 87,624,096 bytes**, SHA-256
`9efbb5da38699d639323321f4c36272de3f2e54a3ba7c7368068644d2a07e55f`.
An additional 156,580 unpinned per-case products from five older closed runs
are recoverable in `closed-case-products.tar.gz`, SHA-256
`fc820215a03c68b9b9164db9309b3a55ad8b71e641f577c039d6ab96c000eb0e`;
all 3,937 protected current pins were preserved. Both restore into the
`ventium-load-read-ack.GyWDDtiI` scratch directory. Source fixtures, native
models and aggregate receipts remain unpacked.

The closed fresh-PC and directed-core compiler PCH caches were byte-verified
in adjacent `.gz` copies before removing the unpacked copies, recovering
**159,407,036** and **155,145,803 bytes**, respectively.
Ten verbose cone/cell-inventory reports from three closed timing comparisons
are recoverable in `closed-cone-reports.tar.gz`, **559,196,131 → 24,016,787
bytes**, SHA-256
`12862ca4a8bce88e47246d59b135774b0f5b7d323cc190e9744fba4198efc980`.
Restore that archive into `/home/yukidama/external/tmp` before rerunning those
historical report audits. Critical-path reports, DCPs, project/clock inputs,
native closure receipts and current protected pins remain unpacked.

The wider **12-phase FP/fault/replay run closed successfully in 607.420
seconds**, controller `ventium-fresh-pair-regressions-oct12`
(`255ffa88e48c43f9bdb2e7c3b97c6953`; nested build scope
`23155721e38e49568930b3d86f15526e`). Independent checks rehashed 3,088 root
inputs, every phase's input pins and all 12 result receipts. Coverage includes
six boundary matrices, 32 fault measurements, integer, memory, held-response,
branch and **108-program / 80,800-record same-input replay**. The canonical
gate remains red; replay equality does not replace it.

Closed regression text is recoverable from
`closed-fresh-pair-regressions.tar.gz`: 37,112 entries,
**997,530,444 → 86,085,832 bytes**, SHA-256
`b40842b18f5f91e26574044335b74e97c308a1ab46c1b302520213a70932e4fb`.
Unpinned per-case products from the two closed fresh suites are preserved in
`closed-fresh-pair-case-products.tar.gz`: 62,528 entries,
**188,156,515 → 11,204,254 bytes**, SHA-256
`928f4e5a2fac86d4fb1638570b40d7b991e27a46311b0cf78073a52374297628`.
All 4,540 protected pins, including each phase's inputs, remained unchanged.
Both archives restore into `ventium-load-read-ack.GyWDDtiI`; restore before
reopening archived per-case evidence. Every archived member was byte-verified
before deleting its unpacked copy.

**Fresh synthesis launched on 2026-10-12 at 23:00 UTC** as
`ventium-fresh-pair-synth-oct12`
(`9b6fbfe5476145ed986aa5b0ac56ae31`), with the sole guarded Vivado family
`dca1ede960cc46cc87c11abc5cdd96d5`. Disk headroom exceeded the unchanged
admission bound (**more than 7,208,493,056 bytes free**). Limits remain 8 GiB
RAM / 6 GiB swap, 13 GiB combined early stop, 4 GiB live disk floor and one
Vivado family. The original 40/100 MHz clocks and matched logic-only mapper
are unchanged. Observer `ventium-fresh-pair-report-queue-oct12`
(`b0801720945c41daadeb70d778c956b8`) tracks that exact synthesis invocation,
then independently audits the native result and original-clock timing;
it cannot retry synthesis, implement or deploy.

No fresh candidate synthesis **result**, routed or gameplay result is claimed.
The last completed synthesized
candidate is still READ-OWNER at **31.040477 MHz**; best remains PAIR-INTENT
at **31.651579 MHz**, both short of the required **40 MHz**.

## Remaining acceptance

The canonical gate remains **7 PASS / 101 FAIL**, red and unwaived.
Required next: achieve
**≥40 MHz synthesized Fmax**, resolve canonical differential failures,
qualify routed setup/hold, the full standard suite and physical UV-fast
Win95 cold desktop/UI plus original FreeDOS Quake complete timedemo. Compile or
cache-test success cannot replace those requirements.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V retirement events/cycle**, model `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. It predates this candidate; it is not FPGA or
full-timedemo IPC.
