# Credit-qualified paired-store enqueue — 2026-10-16

Status: **isolated proposal, not production RTL or an accepted processor fix**.
Native admission-equation, full-cache/AXI A/B, selected fault regressions,
actual same-clock no-L2 wrapper and directed whole-core system checks pass.
The isolated processor and full-PC derivative build; canonical verification
**fails**. Fresh qualified-private-reference comparisons pass separately.
Timing, gameplay, the standard suite and FPGA acceptance are unmeasured.
No new Vivado run or deployment was launched for this proposal.

## Reason and scope

The [system read ACK cut](SYSTEM_READ_ACK.md) regressed the matched unplaced
estimate to 34.7524 MHz from its RAW/input parent's 35.3744 MHz. The leading
paths still traverse paired-store credit and general ACK. This proposal starts
from that **RAW/input parent**, not the timing-regressed ACK derivative.

The directly connected L1 already qualifies a paired backing request with
`m_pair_ready`. The AXI master then repeats pair-credit qualification at enqueue.
Under that explicit caller contract, ordinary single-slot credit is sufficient
for enqueue: the paired request could not have arrived without the stronger
pair credit. The original pair/quad queue allocation and payload logic remain
unchanged, as do every downstream state-machine and AXI-output equation.

`prepare_qualified_pair_credit.py` pins the complete predecessor master, cache
and integration wrapper. It produces two changed files:

- `ven_axi_master.sv`: adds default-off `PAIR_REQ_CREDIT_QUALIFIED`. The default
  branch retains the original enqueue equation verbatim. The opt-in branch
  removes only the repeated pair-credit selection, retaining single credit,
  read-idle, request, write, shutdown, alias and fatal-error guards. Nonsynthesis
  assertions check the caller contract and old/new enqueue equality.
- `ventium_l1_axi.sv`: enables the contract only for dual-store, same-clock,
  no-L2 integration. The CDC branch remains excluded; `EN_L2=1` does not enable
  it. The intervening SMRAM deny logic can only suppress the qualified pair.

Derived master SHA-256:
`00089d0af807232a41af150f5f9c0d176258902a5a869873063da6f6e0edba1d`;
derived wrapper:
`2e7d24a7ae3c1802c8c3ca833330592723271332122bb555174e8e24879ce20c`.

The cache itself is byte-identical. No extra buffering, new latency, forced
pairing, disabled fast path, cache-size change, guest change or save-state is
involved. The dirty checkout's RTL and running full-PC models are untouched.

**This contract cannot be a generic default.** With one free slot and a
non-quad pair held by an unqualified producer, the shortcut admits a request
the original master correctly rejects. The negative test demonstrates that
counterexample explicitly. It must not be enabled on a different producer or
across a clock/queue boundary without a new integration proof.

## Retained checks

Evidence root:
`/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4`.
Exact inputs: `raw-prime-storage-fpga-r1/ventium/rtl/mem`.

| Check | Result and limitation |
|---|---|
| Host source/scope tests | 6 pass; source preservation, default-off and CDC/L2 guards |
| Native equation enumeration | 8,192 binary combinations per profile; generic and qualified, quad off/on |
| Qualified combinations compared | 7,344 without quad; 7,368 with quad; all other combinations explicitly excluded by the contract |
| Generic comparisons | All 8,192 per profile, with no caller assumption |
| Negative equation controls | Fatal, alias and single-credit guard removals fail; unqualified-pair counterexample fails |
| Complete L1/AXI A/B | 2,387 clocks, 68 U stores, 3 paired V stores, including 1 load/store pair and 1 quad enqueue |
| Backpressure coverage | 30 blocked-store clocks; 84 full-queue clocks |
| Cache/AXI equivalence | 4,781 half-edge checks; cache data/valid/tag/LRU arrays, queue state, packets and final 64 KiB RAM agree |
| Sequential negative control | Removing single credit fails with `BACKING-AXI-MISMATCH m_ack` |

The equation test uses Icarus's four-state engine with **binary stimulus**; it
is not an exhaustive X-propagation or sequential proof. The cache test uses
two real full P5 caches, complete AXI masters and independent RAM slaves, with
the parent's hardware feature defines, 32-job bounded compilation and unchanged
strict structural-warning errors. The first run used all 159 hardware defines;
the follow-up removed **only `SYNTHESIS`** (158 remain) so the actual master/cache
contract assertions execute too. Both runs produce the same coverage counts;
the generated follow-up model contains both new contract assertions. The first
run's external comparisons were active, but its internal nonsynthesis witnesses
were excluded and are not claimed as tested there. It supplies requests through public ports,
not forced cache/queue state. All candidate/default pair-ready outputs agree,
including idle hints. The complete integration wrapper and processor are not
instantiated by this first cache test.

Successful receipts:

- `qualified-pair-credit-leaf-r2/closed.json`: 0.277 seconds; 42 input/output
  pins independently rechecked, four positive profiles and four expected
  failures.
- `qualified-pair-credit-cache-r2/closed.json`: 4.787 seconds including build,
  native exit 0; 65 pins independently rechecked. Owner
  `ventium-qualified-pair-cache-oct16-r2.service`, invocation
  `6eec9d6c85dc476fbe3042f70e2a3083`, exited successfully, MainPID 0.
- `qualified-pair-credit-cache-mutant-r1/closed.json`: 4.635 seconds, native
  exit 1 as required; 65 pins independently rechecked. Owner
  `ventium-qualified-pair-cache-mutant-oct16-r1.service`, invocation
  `2a29c67300214008b95160bf3096c405`, exited successfully after grading that
  expected failure. This is not a passing mutant design.
- `qualified-pair-credit-cache-witness-r1/closed.json`: 4.790 seconds including
  build, native exit 0, 65 pins independently rechecked, same complete A/B
  results with internal assertions included. Owner
  `ventium-qualified-pair-cache-witness-oct16-r1.service`, invocation
  `be8dfacb127a42bc98ff4fd14757d81e`, exited successfully, MainPID 0. This is
  the current positive receipt. Earlier receipts retain their frozen driver
  versions; the current driver intentionally includes the witnesses.

Failed infrastructure attempts remain retained: leaf r1 truncated a
preprocessor branch during equation extraction; cache r1 used an obsolete
flat-tag observation name. Leaf r2 retains both preprocessor arms, and cache
r2 compares both current per-way tag arrays in full. Neither failed attempt
is counted as a correctness pass.

### Fault, reset and actual-wrapper follow-up

`qualified-pair-credit-native-audit-r1.json` independently reconstructs **18
native fault/regression executions plus two wrapper executions**, checks 191
source/artifact pins, reaped binaries, retained outer-service identities and
their distinct child-scope journal identities. The audit explicitly does
**not** turn the original failed fault controller into a pass.

The fault checks run the exact original and candidate AXI master against the
existing ID, post-AR RID, orphan-B, RRESP, BRESP, stale-first narrow replay,
quad-store, quad BRESP-error and non-quad split-pair fixtures. Non-pair fixtures
tie only the optional pair inputs inactive; their stimulus and checks remain
unchanged. The candidate uses the qualified branch except in split-pair
rejection, which deliberately exercises the **generic default** with a held,
uncredited request. Internal assertions remain enabled; the existing narrow
fault-injection defines suppress only the intentionally violated responder
assumptions, not containment checks.

The original `qualified-pair-credit-faults-r2` controller remains **FAIL**:
its first twelve native runs passed, then the quad fixture printed PASS and a
timeout fatal in the same simulator evaluation despite exit code 0. A first
named-block exit attempt did not fix this: generated C++ still reached the
timeout. The final `tb_axi_quad_pair.sv` repair records completion, leaves the
poll loop and calls `$finish` once afterward, retaining the timeout on missing
completion. The canonical shell gate now rejects fatal/error diagnostics even
when the process exits zero and prints a PASS marker. Host tests inject that
exact misleading log and require failure. No DUT RTL or expected AXI values
were changed to resolve this testbench defect.

`qualified-pair-credit-quad-r3` separately passes all six original/candidate
quad cases in 32.006 seconds. The audit reuses only the twelve clean non-quad
rows of the failed earlier controller, reconstructing their complete generated
fixtures and master sources against current inputs; it excludes the bad quad
row. This is collected per-case evidence, not a renamed successful original
run. Both earlier failed quad attempts and their native logs remain retained.

`qualified-pair-credit-wrapper-r3` passes both original and candidate actual
`ventium_l1_axi` integrations in 11.526 seconds, with the same coverage:
**65 U stores, 2 V stores, 1 quad enqueue, 30 blocked-store clocks, 53 full-queue
clocks, 100 AXI write transactions, one AXI-only reset/retry and four denial
checks**. The 60 byte-mask/offset stores include split writes; final backing
RAM is checked byte-for-byte. Denial coverage is three independent V-readiness
queries (SMRAM, unrouted high address, VGA/MMIO) plus an actual denied U/V SMRAM
request that must not partially reach DDR. A held AR is reset through public
reset/handshake pins, then the still-present producer request retries correctly.
There is no forced internal ACK, cache state or queue credit. The source recipe
enables the candidate parameter through the real wrapper, not a test-only
direct-master override. All hardware feature defines are retained; only
`SYNTHESIS` is removed to include assertions, and `AXI_BFM_MON` adds observation.

Retained successful owners:

- Quad: `ventium-qualified-pair-quad-oct16-r3.service`, invocation
  `2ce7d4a82eda48f3bc45496422de8821`.
- Wrapper: `ventium-qualified-pair-wrapper-oct16-r3.service`, invocation
  `0c43425c096f45cfabfa17809d89da57`.

Both have MainPID 0 and exit 0. Wrapper attempts r1/r2 failed before simulation
(ambiguous fixture replacement and unsupported side-effecting increment in a
short-circuit expression); they remain failures. The final eleven host tests
pass. Closed compiler products are stored in verified `.tar.zst` archives beside
their runs; binaries, source snapshots, headers, logs and receipts remain loose.
Five additional closed object trees were archived to recover about **701 MiB**
net; `tar --zstd -xf compiler-products.tar.zst -C <run-directory>` restores them.

### Whole-core derivative and cold system checks

`build_qualified_pair_credit_core.py` builds the exact two-file derivative of
`raw-prime-storage-core-r1`, model
`41f99bcff8125a2caa7fe768f03f242bed1a43323e4d3a190109167248a34e9b`.
All **195 source files** are inventoried; only the two memory files change,
and all **153 ordered feature defines** remain identical. The build retains
the real AXI backend, `AXI_LINE_REPLAY=0`, assertions, U/V fast system/relocated
execution and fast load/store paths. It uses a unique private C++ harness
basename and checks its compiled dependency against this model's generated
header. No stale external harness object is accepted.

`qualified-pair-credit-core-r1/build-closed.json` records a successful
**23.513-second**, 32-job bounded build. Binary SHA-256:
`5a2fcb865e53dc67a3f866ab1edbc8bbbc4917708e984a62d60bc8400c67f2d3`.
Owner `ventium-qualified-pair-core-oct16-r1.service`, invocation
`e45d4f5570e845e4a740c0d8e61a3d35`, exited 0 with MainPID 0.
The distinct build-scope invocation is `13b4cea9a79c46798ed72770db54c3eb`.
After closure, 225 generated compiler products were archived and byte-compared
before removal, recovering **195 MiB** net. The archive SHA-256 is
`ac1f4152a61addbc542e1958bd283a8f2f831b8836eef9b4283f67f29f05b5a2`;
`compiler-archive.json` records each member and the recovery command. Binary,
headers, dependencies, private harness, source and logs remain loose.

`run_qualified_pair_credit_core.py` preserves the existing cold system
supervisor, fresh pinned QEMU-system reference, fixtures and comparison policy.
Fifteen cases (`pseg`, `ppage`, `pfault`, `pintr`, `pcpl`, `ptask`, `pv86`,
`pxc04`, `pxfrag`, `pxwalkd`, `pcgparam`, `pretfoutpg`, `piopermwrap`,
`pjmpgate`, `pxfer`) run at AXI delays **0, 7 and 31**, on both parent and
candidate, in `--cycle-func --l1-axi` and `--cycle --l1-axi` modes. There are
no snapshots, STEP, guest patches, forced processor state or new comparison
masks. The unrelated ACK-owner observation is removed, but the real AXI
master's new qualification/equality assertions remain enabled.

`qualified-pair-credit-system-r1/closed.json` passes **180 native RTL
executions** in **46.358 seconds**. All **90 complete parent/candidate
retirement-trace pairs**, including retirement clocks, match exactly. The
candidate emits **47,886 records** across the two modes and **5,349 actual
V retirements in cycle-mode traces**. Functional-mode system state also
matches the fresh QEMU traces. Each native child has an observed CPU affinity,
expected debug-port exit, completed wait and closed process group; cgroup OOM
counters are zero. Retained owner:
`ventium-qualified-pair-system-oct16-r1.service`, invocation
`021fc00592d541f7ba13f41704bf3b8e`, MainPID 0, exit 0. Independent read-only
reconstruction confirms these counts and comparisons. Fifteen host tests pass.

Canonical `make verify` **failed** separately under
`ventium-qualified-pair-verify-oct16-r1.service`, invocation
`451739253c1242f3a0e15a4732252be6`: native gate exit **2**, controller exit **1**,
MainPID 0, **398.806 seconds**. It uses the existing canonical oracle,
fresh private work/cache directories and both explicit AXI backend flags.
The result is **7 functional PASS / 101 FAIL**, with the same per-program
verdict inventory as the parent. All **20 complete cycle RTL traces** are
parent-identical; the nine failing cycle-band cases remain failing. Separate
same-input replay and qualified-reference checks are recorded below. No oracle,
tolerance, flag mask or expected result was changed in the canonical run.

`qualified-pair-credit-core-audit-r1.json` independently reconstructs the full
directed system comparisons and all 20 canonical cycle comparisons, rechecks
**1,871 source/artifact pins** and all three closed service identities, and
explicitly retains `canonical_gate_passed=false`, `standard_suite=false` and
`hardware_acceptance=false`. Parent equality does not waive the red gate, and
the directed system result is not a substitute for a standard-suite pass.

### Same-input functional replay and fresh qualified reference

`qualified-pair-credit-failure-inventory-r1.json` classifies the unchanged
canonical failures: **90 length-only failures, 11 failures with field
differences, 101 length mismatch reports**. Comparing independently started
parent/candidate runs directly gives only one fully identical RTL stream:
their QEMU-established initial stacks differ. No ESP masking or trace
normalization is used to turn that into equality.

`qualified-pair-credit-replay-r1` instead reruns the actual parent using each
candidate run's flattened image and loader-established initial ESP. All
**108 complete streams / 80,800 records match exactly**, including clocks,
in **55.979 seconds**, with 32 bounded workers and actual wait/reaping. Owner
`ventium-qualified-pair-replay-oct16-r1.service`, invocation
`2c070ff455414eea8b1501e24cf0c04c`, is closed with MainPID 0 / exit 0. The PC
transfer independently rereads every full trace; equality does not waive the
canonical verdict.

`qualified-pair-credit-func-r1` freshly regenerates all reference traces using
the previously independently qualified QEMU
`998b4f5d3eda4493f391ea6775adcc88f3dd810ba2829f7d635cac27877f9b85`
and its explicit terminal-state observer. All **108 programs / 80,800 records**
pass the unchanged manifest comparison policy, with **30,132 V retirements**,
in **107.843 seconds**. Owner `ventium-qualified-pair-func-oct16-r1.service`,
invocation `7ff491629b654336aac024ac9a4672cf`, is closed, exit 0 / MainPID 0;
peak RAM is 152,768,512 bytes, OOM counters zero. QEMU and RTL child affinities
are observed on CPUs4–7, not inferred from a service property.

The independent `audit.json` rechecks **12,528 input pins**, every full
comparison, complete executable-image equality and native owner. Removing
all optional comparison masks gives **105 passes**, with only the existing
`tx_regform`, `tx_regform2` and `tx_stack` stack-fault differences failing.
Neither the masks nor the original canonical reference is replaced. The
qualified private result is not labelled a canonical or standard-suite pass.

### Full-PC transfer and integration controls

`qualified-pair-credit-soc-r1` transfers only the two tested memory files into
the exact RAW/input parent. All **102 shared processor sources** match the
directed model; all **157 full-PC definitions** are unchanged. The full P5
caches, posted-16 transport, retained 8042, keyboard retry and mouse fixes
remain. The unique private C++ harness object/header binding is verified.

The native build closes in **25.859 seconds**, with model
`03e347c7055cf24255b4527f446b7b9f293452da3e36b205fc910f413a81f961`.
Owner `ventium-qualified-pair-soc-oct16-r1.service`, invocation
`ee033f51c928486e8d765b9d4ab9bd54`, is closed exit 0 / MainPID 0. The inherited
**98 full-SoC structural warnings are unchanged, not waived as clean**.

Cold keyboard probes in `qualified-pair-credit-input-r1` both pass at 6.5M
clocks, raw modes 0/1. Independent audit verifies the actual native executions,
grades, ownership and **71,328 source pins**, with no OOM. Owner
`ventium-qualified-pair-input-oct16-r1.service`, invocation
`8ff5592ed42c44899394e37e21856a62`, is closed exit 0 / MainPID 0. This is input
transport coverage, **not Windows UI or physical-board acceptance**.

The two short CoreMark controls pass under
`ventium-qualified-pair-cm10-oct16-r1.service`, invocation
`f3fa6b9958944cd3aa310128c919b186`, now closed exit 0 / MainPID 0. They retain the original 10-iteration
disks/CRCs, 40/40/80 MHz timebases, native CPU12/13 affinities and 600-second
per-child limit. Independent audit rechecks **71,365 pins**, native completion
and reaping, with no OOM. The performance seed produces CRCs
`e9f5/e714/1fd7/8e3a/fcaf`, **4,771,298 clocks** and **1,055,307 V retirements**;
validation produces `18f2/e3c1/0747/8d84/c64e`, **4,755,366 clocks** and
**1,054,254 V retirements**. Both cycle counts equal the parent: **0% measured
throughput change**. These short controls cannot establish a duration-valid
CM/MHz score or full-seed correctness.

### Sealed FPGA export and CPU lint

`qualified-pair-credit-fpga-r1` seals **192 payloads**, including **170 shared
compiled HDL sources**, against the tested PC. Only the two intended memory
files differ from the RAW/input FPGA parent. All **159 hardware defines**,
full P5 caches, posted transport, input fixes and 40 MHz core / 100 MHz PL
clock configuration remain unchanged. Configuration is not a timing result.
The manifest SHA-256 is
`ad6b7c19643faf50a98d12d96d0edaa018716566d64bd0d498566156570b7964`.

The export owner `ventium-qualified-pair-freeze-oct16-r1.service`, invocation
`5fcc97bbf2ff479f91a9bdbc9002324f`, is closed exit 0 / MainPID 0. The separate
source audit rechecks **72,857 pins** and all payload bytes under
`ventium-qualified-pair-source-audit-oct16-r1.service`, invocation
`29103035f46941d9854e64ff927d1376`, also closed successfully. Its receipt
explicitly denies canonical, standard-suite and hardware acceptance.

Strict **CPU** structural lint passes in **3.828 seconds**, retaining all 159
defines and all six structural-error classes. Owner
`ventium-qualified-pair-lint-oct16-r1.service`, invocation
`d36f37842841477fb7d2289f700c9ac6`, is closed exit 0 / MainPID 0; input hashes
remain stable. This is **not full-SoC lint**, whole-wrapper elaboration,
synthesis, routed timing, or physical validation. No new Vivado run or board
programming has occurred for this candidate.

Closed RAW-parent and rejected ACK-parent compiler products were losslessly
archived, byte-compared and removed from loose storage, recovering about
**236 MiB** net. Their binaries, headers, sources, dependencies and evidence
remain. Each directory has `compiler-archive.json` and the recovery command.
Archive SHA-256 values are respectively
`76280693fdc3bb4fd30f32f6f5e1b5a0701124e2b9078eec058f2ebe40608eeb`
and `546122ed3978bafd1655076e4b149110dcb777d65dfc13c1f4b5ae24ff352ef8`.
The closed candidate PC's 275 compiler products were likewise archived and
byte-verified, recovering another **210 MiB** net. Archive SHA-256:
`85fabca60f22e15ad353f6c71c9a627e1a29e3694485351d2b4fdcc04d08397b`.
All binaries, generated headers/dependencies, source and acceptance evidence
remain loose; its `compiler-archive.json` records exact members and restoration.

## Remaining gates

Before synthesizing or accepting the whole-core candidate:

1. Extend the now-passing fault and wrapper coverage to shutdown and additional
   same-edge release/route-fault combinations. Existing evidence does not cover
   every paired fault scenario. Preserve the explicit generic-producer contract.
2. Verify unpaired/CDC exclusion configurations separately; their exclusion is
   currently source-checked, not claimed as a new native CDC acceptance pass.
3. Resolve the red canonical gate. Same-input functional replay and the fresh
   qualified-reference corpus now pass, as do the build and directed
   system/fault comparisons. Existing canonical failures remain failures,
   not newly waived passes.
4. Only then measure matched synthesis/timing. This simplification may have
   little timing effect because the original ready-to-request path remains;
   **no MHz, area, CPI or IPC gain is claimed**.

Full CoreMark correctness/scoring, Win95 desktop and UI, Quake timedemo and
matching physical-FPGA validation remain mandatory before accepting a major
core/cache change. The earlier ACK candidate's two 900-iteration CoreMark runs
timed out at their 60-minute caps without final CRCs; neither they nor this
candidate's short CRC controls qualify the full suite.

Last verified gameplay baseline: **0.497040387 total U+V IPC**, model
`b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e`, clocks
**1,100,065,247–2,100,065,247**. U-only IPC is 0.384240079. That model predates
the RAW/input and ACK candidates and this proposal; none has a newer verified
gameplay measurement. This is not timedemo completion or FPGA acceptance.
