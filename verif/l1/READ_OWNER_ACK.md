# Current-owner read completion — October 12

READ-OWNER is a private derivative of
[PAIR-INTENT](../../fpga/PAIR_INTENT_TIMING.md): **31.040477 MHz** versus its
parent's **31.651579 MHz**. The later **FRESH-PAIR** derivative below now has
the best closed synthesized estimate, **31.822811 MHz**, still below **40 MHz**.
Its follow-on **INTENT-READY** private core has passed cache comparisons and
built; whole-core verification is running. INTENT-READY has no synthesis,
gameplay or physical result yet.

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

Fresh synthesis closed native **0** after **1,983.655 seconds**, the same exact
owner `9b6fbfe5476145ed986aa5b0ac56ae31`. Its independent audit rechecked
**4,684 input pins**, all 158 defines and **148 actual native HDL inputs**.
The only changed payload is L1. Checkpoint/report/source artifact hashes were
also rechecked independently after closure. There was no OOM, resource stop or
controller failure; peak scope RAM was **8,589,910,016 bytes**, swap
**408,125,440 bytes**. This is successful synthesis, not timing acceptance.

Utilization is **185,621 LUTs / 54,948 FFs / 277.5 BRAM36-equivalents / 47
DSPs**, versus READ-OWNER's 185,368 LUTs / 54,950 FFs / unchanged memories/DSPs.
Diagnostics are **0 errors, 1 critical warning, 1,564 warnings**. The critical
warning is the inherited generated PS8 scoped-XDC clock target; it is not
silently counted as clean. The timing stage still must audit the actual
40/100 MHz clocks, structural DRC and both setup/hold reports.

The timing stage `ventium-fresh-pair-clock-oct12`, invocation
`b02abead37244159aa52002d1b334b4b`, has also **closed native 0**. Its independent
audit checked **4,121 input pins**, actual 40/100 MHz clocks, no black boxes
and zero tested structural DRC errors. It took **493.546 seconds**, with
4,572,676,096 bytes peak scope RAM, zero swap and no OOM. The exact-owner
observer closed successfully too; neither Vivado family remains live.

The result is **31.822810591 MHz**, setup **−6.424 ns**, hold **−0.101 ns**.
The matched best-parent checkpoint reproduces **31.651579414 MHz**, so the
improvement over that control is **0.541%**. This is an unplaced synthesized
estimate, **not ≥40 MHz, routed timing, gameplay or board acceptance**.

All 30 reported worst paths share the long frontend/next-request dependency:
the worst ends at `pipe_mem_store_pair_q_reg/D` (111 levels, **31.213 ns** data,
including 24.398 ns estimated routing); 29 end at L1 LRU registers. The first
LRU path is **30.844 ns / 109 levels / −6.055 ns setup**. The worst path's
measured cumulative data delays are next request **23.021 ns**, pair-ready
**24.191 ns**, pair request **24.528 ns**, V snoop **24.880 ns**, REP invalidation
**27.189 ns**, next commit **28.282 ns**, endpoint **31.213 ns**. Rebuilt
hierarchy labels are not proof of RTL module ownership. Report SHA-256:
`cc82a40947bbf8425e61edb15ed0b50d19ca75270841311982e7ef026e445128`.
This confirms the measured target of the following intent-only readiness cut;
it does not predict that cut's eventual Fmax.

## Remaining acceptance

### Paired-store readiness follow-up, not in the active synthesis

READ-OWNER's second-worst reported endpoint is
`pipe_mem_store_pair_q_reg/D`: **31.250 ns data delay / 111 levels / −6.461 ns
setup**, behind speculative next-read preparation, paired-store readiness,
V-store instruction-cache snoop, REP continuation invalidation and next-read
commit. This is a measured **parent** path, not a fresh candidate result.
The path report remains unpacked at
`read-owner-clock-r1/core_setup_unplaced_estimate.rpt`.

The next conditional experiment is a separate **intent-only readiness**
result, not removal of the ordinary port's conflict guard. The existing core
consumes readiness only in `pipe_store_pair_offer && mem_store_pair_ready`;
that offer is also its checked intent, propagated to L1 with `l1d_c_req`.
Intent already suppresses conflicting cache lookahead. Therefore the guarded
request/ACK consumers can use a cofactor with no next-request dependency,
while the original general readiness port retains its full semantics.

`prove_pair_intent_ready.py` extracts the actual frozen L1 assignment and runs
`tb_pair_intent_ready.sv` in eight load/store-pair, chain and code-buffer
profiles. Unit `ventium-pair-intent-ready-proof-oct12`, invocation
`7f0c8c82aab242c8bfe7d58584286c10`, closed successfully in **3.631 seconds**:
**3,145,728 vectors**, including **2,621,440 intent-qualified equivalence
checks**. It exhausts the binary control inputs and separately both address
offsets/strobe masks. The two chain+load/store profiles also produce six
native counterexamples to an **unconditional** replacement. All eight native
compiles/simulations and their artifacts were independently checked; peak
memory was 32,780,288 bytes, bounded to CPUs 10–11 / 256 MiB alongside Vivado.

Three symbolic counterexample searches are UNSAT: qualified readiness,
core request with the stated intent propagation, and ACK under request →
intent. Five SAT sensitivity queries demonstrate why global replacement,
lost credit/residency/ownership, or missing intent propagation are unsafe.
This combines source-extracted binary testing with an abstract handshake
proof; it is **not** arbitrary X/Z equivalence or sequential cache proof.

`prepare_intent_ready_cut.py` is a **draft two-file transformation**, with
four passing source-scope/caller tests in `test_intent_ready_cut.py`. It adds
the separate L1 result, carries it through the seam, and substitutes it only
in intent-qualified request/ACK consumers. Original readiness, original
assertions, actual lookup priority and all sequential RTL remain intact.
It rejects parent drift and reapplication. It did **not change the active
FRESH-PAIR synthesis**. The later private cache/core build below applies it
after that run closed; broader core/FP/fault regressions remain required.
No timing or gameplay gain is inferred from this microtest.

Two guarded native cache runners were prepared, then executed after timing
closure (results below):

- `run_intent_ready_pairs.py`: six full-P5 sequential A/B configurations
  (both tag layouts, zero/one/two saved windows), plus missing-arbitration and
  missing-credit negative controls. Both instances receive identical checked
  intent and retain every original port/state/data comparison. Additional
  checks cover fill ownership and saved payloads. Explicit intent without a
  request must never write; dropping intent retains the original hint behavior.
- `run_intent_ready_cache.py`: the exact fresh-core **152-define** profile,
  requiring the pair matrix first. It retains the high-word/window/coherence
  corpus and all **51 fresh-capture cases**. This runner has no additional
  negative control; its prerequisite runs the two actual pair mutations.

Both refuse live Vivado, retain the shared build lock (FD 9), 32 compiler
jobs, six fatal structural warning classes, bounded child runtimes and disk
admission. Closed compiler products use the existing byte-verified recoverable
archive helper. Neither runner promotes production RTL or claims core, timing,
standard-suite or hardware acceptance. Run the pair matrix with `--parent`
pointing to the fresh FPGA L1 source and `--proof` to `intent-ready-proof-r1`;
then the full-profile runner with `--parent fresh-pair-core-r1`, that same
`--proof`, `--pairs` pointing to the closed matrix, and the pinned original
`ventium-high-window-payload.WjAngfp4/tb_l1d_mem_chain.sv` fixture. Use distinct
new scratch output directories and the `ipc_parallel32` guard after Vivado
and its timing observer finish.

Review caught a vacuity in the pending missing-credit negative control: the
inherited one-slot test asserted no pair intent, so the new fast-ready result
was deliberately unobserved. The fixture now reserves intent with credit
absent and no actual V request, checks that both readiness results are false,
and still requires the solo U write to complete. Both A/B instances see this
same public traffic. A host test guards this qualified observation; the later
native matrix below confirms that the missing-credit mutation is detected.

`build_intent_ready_core.py` implements the follow-on whole-core build
procedure. It requires the closed full-profile cache result,
audits all 195 parent payloads, and permits only the L1/seam two-file delta.
The 152-define UV-fast profile, private harness basename and matching-header
check, shared guard and native build lifecycle are retained. Its native result
is recorded below; compilation alone does not establish processor correctness.

**19 host tests passed** across `test_intent_ready_{cut,pairs,cache,core}.py` on
2026-10-12. These check transformation boundaries, retained comparisons,
native-run safety guards and fail-closed source admission. The closed leaf
proof was re-audited from its native logs and hashes, including exact symbolic
query text/results and a deliberately altered-transcript rejection. These
are preparation/proof-evidence checks, **not sequential RTL execution**. The
live synthesis inputs were not changed and no competing cache build launched.

### INTENT-READY native cache/core preflight closed

After both exact fresh timing owners closed, controller
`ventium-intent-ready-after-clock-oct12`
(`cd0b8b1d69294bc1bafe8589c8089bca`) checked the measured critical path, then
ran four sequential guarded phases. The controller closed native **0** with
unchanged pins; actual workers were observed on CPUs **0–31**. It cannot
launch synthesis, route or deployment. Evidence is under the same root:

- `intent-ready-pairs-r1`: **46.518 seconds**, six positive native cases and
  two required native failures (lookup arbitration and backing credit).
  The positives total **2,042 both-edge samples**, 90 pair-ACK samples and
  **258 intent-qualified readiness samples**; these are observer samples,
  not unique retired instructions. All old-port/data/state comparisons stay
  active. Guarded scope `84610ba3b65f4e5090bd9b4bb2752638`.
- `intent-ready-cache-r1`: **13.152 seconds**, exact 152-define profile,
  **747,037 both-edge comparisons / 463 next lookups / 66,339 wide responses**,
  plus the 51 fresh-capture cases, all unchanged. Full bank/tag/valid/LRU and
  saved-owner comparisons pass. Scope `aeb66d8bde2f49efa999f98bd0a8a681`.
- `intent-ready-core-r1`: **20.846-second** native build, only the two intended
  files changed among 195 payloads, same 152 defines and a private harness
  object using its matching generated header. Build scope
  `8bde0586f5d344cabfea62c48deca72e`; preparation scope
  `4da8238c95d44a299f9440526ea729f5`. Model SHA-256
  `6fa8f7ad89e4f84a3c484a5e8c81d933e9bda429ca6c7019bd5e2c63d3ce1b5e`.

Independent rechecks found all **86 pair / 3,170 cache / 3,374 core input pins**
unchanged, including the full cache's retained native artifacts. Source hashes:
L1 `df7a426143baf6571d233a450fdc7c1eac17c946bd208b5334846b8fb255a29d`;
seam `806e4392b97b983097278dbad3efa9f9dfae61bb6d9488955632e18e797c2b38`.

Unmodified canonical verification closed as
`ventium-intent-ready-canonical-oct12`, invocation
`ce61b29b9e65437eb5e3ecab0e942a95`, against the fresh-core parent. It retains
the real AXI backend, all record comparisons, masks, goldens and timing bands.
The native gate exited **2** after **398.719 seconds**: **7 PASS / 101 FAIL**.
All 20 parent/candidate cycle traces match, and input pins are unchanged.
That equality is not a waiver of the red canonical gate.

`run_intent_ready_core.py` binds the unchanged eight-corpus plan to exact
parent `e1621913` and candidate `6fa8f7ad` model hashes. Three additional host
checks pass (**22 total** for these adapters), verifying byte-identical native
plan/comparison/coverage logic and rejecting lifecycle drift. It retains the
4,240-probe and exact cycle/intent/pair coverage requirements, not just exit
status. `ventium-intent-ready-corpora-oct12`, invocation
`b587a086b6124ea9984ac3d0934254ef`, closed **native 0** in **301.702 seconds**;
guarded scope `52f34fc2f2ff490f9510875738aa2280`. All eight corpora pass with
**4,240 probes**, exactly 21,190,336 observed clocks, 5,616 intent samples,
3,072 requests and 1,872 accepted pairs. These are directed observer counts,
not gameplay metrics. Independent rechecks found all **3,387 input pins**
unchanged. Output is `intent-ready-checks-r1`.

The complete wide-FP matrix also passed: `intent-ready-fp-r1`, **69.095 seconds**,
**384 fixtures / 1,536 measurements / 768 zero-cycle-delta comparisons** at
AXI latencies 0 and 7, retaining full QEMU/x87 and actual U/V-pair checks.
All 13 matrix input pins were independently rehashed. Its native scope was
`6faf0d38866c45f6a3ea0b3fafb913be` (940.7 MiB peak, zero swap). The outer
`ventium-intent-ready-fp-oct12` service was transient and collected after exit;
its journal and the native scope journal/closed receipt retain the evidence.
Do not claim it remains an inspectable exited unit.

Closed eight-corpus text is recoverable from
`closed-intent-ready-checks.tar.gz`: **38,352 entries**, **969,202,890 →
87,612,464 bytes**, SHA-256
`c7f7ae453d4d6e0085e06023b053c19be8a5ea8b05f1e77fadd7e8453dadbcd1`.
Every member was byte-verified before removing its unpacked copy; restore into
`ventium-load-read-ack.GyWDDtiI`. Sources, models, receipts and pinned inputs
remain unpacked. No current verification output was selected.

Closed FP text was independently re-compared before compaction (384 fixtures,
208,128 candidate architectural records). Archive
`closed-intent-ready-fp-text.tar.gz` preserves **11,916 files**, **487,372,820 →
29,590,451 bytes**, SHA-256
`e835d9472369976a7c71d6f8dea8279c988785384affe7dd64320bf4a4ed73dc`.
Restore into `/home/yukidama/external/tmp`; every member was byte-verified and
all current regression input pins remained unchanged.

For additional synthesis headroom, **25 large historical input-inventory JSON
files** from the closed Oct 11 U-shift, branch-residency and bus-cancel runs
were losslessly preserved in `closed-oct11-metadata.tar.gz`, **1,286,186,569 →
163,238,587 bytes**, SHA-256
`c8c81f26fdcdcfccb920fe683964c7c8abda16d20ddec05b47fdced5f3647475`.
All six exact synthesis/timing owners were confirmed closed; byte verification
preceded removal of the unpacked copies, and **5,071 current pins** were
unchanged. No source, executable, DCP, media, result receipt or timing report
was removed. Restore into `/home/yukidama/external/tmp` before historical
re-audits; the explicit member list is `closed-oct11-metadata-plan.json`.

Four verbose fresh timing cone/cell inventories are also recoverable in
`closed-fresh-pair-cones.tar.gz`, **251,179,264 → 10,757,810 bytes**, SHA-256
`b79b3d89e2f5a98252298f75a5b6b1fbf6c1b06ec652904774bae84b2552aeb2`.
Restore into `/home/yukidama/external/tmp` before repeating the full historical
fresh timing audit. Its critical-path reports, original XDC/project, DCP and
current dependency pins remain unpacked.

`run_intent_ready_regressions.py` now runs the unchanged 12-phase FP boundary,
fault, integer/memory/held/branch and same-input replay plan against exact
models `e1621913` / `6fa8f7ad`. Unit
`ventium-intent-ready-regressions-oct12`, invocation
`311a3dc90f574573bf44861d77c1c193`, closed **native 0 in 609.385 seconds**.
All 12 phases passed, including six boundary matrices, 32 fault measurements,
integer/memory/held/branch cases and **108 programs / 80,800 records** of
same-input replay. All gate comparisons, native timeouts and the canonical
failure status remain intact. Native scope:
`2ebad809529c4d86a45ec53d3d18fe5b`.

Source-transfer and measurement procedures:

- `fpga/build_intent_ready_soc.py prepare`: requires that closed 12-phase
  proof plus the complete FP matrix and canonical receipt, then transfers
  exactly L1/seam into the fresh full-PC source with 102 common RTL payloads.
  `build` retains the guarded 32-job compiler and private matching-header harness.
- `fpga/freeze_intent_ready_rk_candidate.py`: checks all 170 shared HDL
  inputs and permits only those two changes in the 190-file FPGA export.
- `fpga/prepare_intent_ready_synthesis.py`: prepares controllers that retain
  the original 40/100 MHz clocks, matched logic-only mapper, one Vivado family,
  memory/disk admission and live stop thresholds. It requires short CoreMark,
  strict CPU lint and all existing proof receipts before synthesis starts.
  Source and timing control now both use the closed **31.822810591 MHz**
  fresh-pair checkpoint, SHA-256
  `32b06bb08c58472c577a0ff046301643ffba2cab13600f17103f8c32d8c5960d`.

**30 host tests pass** across the intent-ready L1 and FPGA adapters. They check
byte-exact transformation/transfer boundaries, unchanged native comparison
plans, guard preservation, explicit model/checkpoint identities and rejection
of source drift or extra payload changes. All four new command-line entry
points also passed their `--help` checks. These are host checks, not native
FPGA timing measurements. No new Vivado family was launched in this step.

PC preparation closed successfully as `ventium-intent-ready-pc-prepare-oct12`,
invocation `2cedbd56917b4edb9940ed5879ae5d88`. The subsequent
`ventium-intent-ready-pc-build-oct12`, invocation
`ea139197273f4c40981251a318ed0ddf`, compiled in **24.021 seconds**, native 0.
All 102 common RTL payloads agree with the directed model; only the two intended
files change. The private harness used its local object/matching generated
header. All **5,192 build input pins** were independently rehashed. The 98
inherited full-PC structural warnings are unchanged, **not a clean SoC lint**.
PC model SHA-256:
`f8dad22699bef9fb8476656ed0f5610c7c18f0e11d870d943e7c981b41331ddc`.

FPGA source export `intent-ready-fpga-r1` is closed and its **5,386 input pins**
were independently rehashed. It preserves 190 payloads, 158 defines, 170 shared
HDL inputs, original clocks and transport. Manifest SHA-256:
`034095db8f09866e527046fd6f130a950759f3798c3a72d69bfd53d5756a2c1b`.
Strict **CPU-hierarchy** lint passed in **3.828 seconds**, native 0, unit
`ventium-intent-ready-lint-oct12`, invocation
`e27e9feec56148ad906075aed931dd1a`; all 195 lint pins were rehashed. This is
not full-SoC lint or FPGA acceptance.

Closed regression text is recoverable in
`closed-intent-ready-regressions.tar.gz`, **36,984 entries**, **887,131,526 →
82,720,712 bytes**, SHA-256
`7b6ef3e1c1095a4ab9505239b987c77074cb5cfec6704eb67e86b4cee22f1354`.
The archive explicitly excludes the 128 pinned native fault-trace files needed
by PC/source qualification. Unpinned case products from both closed suites are
preserved in `closed-intent-ready-case-products.tar.gz`: **62,304 entries**,
**185,707,023 → 11,071,595 bytes**, SHA-256
`44d5a94426d51604defb560d98f0fcd6c5ff6a44554e1968347db3eab5677c10`.
All 5,463 protected pins stayed unchanged; 224 pinned case products were skipped.
Both archives restore into `ventium-load-read-ack.GyWDDtiI`. Each member was
byte-verified before deleting its unpacked copy. Closed directed-core PCH
caches have verified adjacent `.gch.gz` copies, recovering **155,156,742 bytes**.

Short cold CoreMark is running as
`ventium-v-carry-cm10-intent-ready-oct12`, invocation
`0e44f5f0d48244f6937bbd10d126c389`. The **performance seed passed**, native 0
in **202.666 seconds**, with matching CRCs, unchanged **4,767,218 ticks**, and
1,055,307 actual V retirements at the final observation. The validation seed
and independent audit remain pending. These 10-iteration tests are
**duration-invalid**, not CM/MHz scores or standard-suite acceptance.

Controller `ventium-intent-ready-synth-launch-oct12`, invocation
`7b6377bdeec04f8c929efd93e60d7fba`, is **waiting on that exact CoreMark owner**.
It requires its independent audit, byte-verifies/compresses the unused PC PCH,
and retains the original disk admission (**>7,208,493,056 bytes free**) before
launching one bounded synthesis. Native RAM/swap/disk stop thresholds stay
unchanged. Its exact-owner observer can audit synthesis and then original-clock
timing, but cannot retry synthesis, route or deploy. No INTENT-READY synthesis
has started at this entry, and no Fmax result is inferred from compilation.

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
