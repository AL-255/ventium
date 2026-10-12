# Request-independent code-kind hint — private timing proposal

Status, October 12: **extracted-mux tests pass; complete cache/core and timing
not yet verified**. Production RTL and the currently running MC+PAIR+SRT
synthesis inputs are untouched. The requirement remains at least **40 MHz
post-synthesis Fmax**, retaining UV, system/relocated fast pipes, fast memory
paths and full P5 L1s. No additional cycle, guest special case or timing
exception is proposed.

## Measured path and proposed change

The closed MC parent measures **29.58405 MHz**; the best prior matched result
is **30.34809 MHz**, both unplaced estimates. Its worst setup path explicitly
passes through `seg_access_fault`, `core_mem_code`, the cache's code/early data
selector, FP operand selection and the SRT input. See the
[combined candidate's path breakdown](../../fpga/MC_PAIR_SRT_TIMING.md).

`mem_code = mem_req && !cur_is_d` unnecessarily puts request/permission logic
on the payload selector. However, changing that existing port is **unsafe**:
the AXI wrapper can deny a request after upstream `core_req`, and the existing
code classification also affects cache readiness/capture when no read is
consumed. It must retain its original qualification.

[The recipe](prepare_payload_code_hint.py) instead adds a separate,
default-off `VEN_L1D_PAYLOAD_CODE_HINT` sideband through four exact frozen
sources: `core.sv`, `ventium_top.sv`, `ventium_l1_axi.sv` and `ven_l1d.sv`.
It carries `!cur_is_d` to **payload selection only**. Original request,
permission, ACK, read-ready, tags, capture, replacement and cache-state logic
remain unchanged. Address, strobe and saved code/data-owner comparisons are
retained; an unrelated early critical word cannot override the current owner.
Bypass and stream data retain their original priority. On every admitted read,
the old qualified code bit equals the new hint. Live assertions check that
implication and the selector owners on acknowledged reads.

Source parent: MC+PAIR+SRT whole-core model
`eefa9d57c41c5eb5154d0319fb2e82240f90469b7ce119ae0abe36d6aada9702`.
The recipe refuses source drift/reapplication. With the flag off, all original
tokens in all four files are retained. This is not a measured frequency gain;
the hint still depends on the core's existing `cur_is_d` logic.

## Completed evidence

Evidence root: `/home/yukidama/external/tmp/ventium-mc-pair-srt.fI8m6eUS`.

- Eight host source/Boolean/extraction tests pass, including the denied-fetch
  counterexample to requalifying code with downstream `c_req`.
- `payload-code-hint-leaf-r3` closes native zero in **32.02 seconds**:
  **262,144 vectors / 2,048 admitted reads**. All original control predicates
  match on every vector; low/high data and selectors match on every admitted
  read, including stalled reads. Selected paths: 45 code, 130 shadow, 49 early,
  1,068 stream, 233 bypass and 523 primary-window reads.
- Three compiled RTL mutants fail natively: reversed code kind, removed early
  address/strobe owner, and using the raw hint for control. These are actual
  assertion/data failures, not timeouts or build errors.
- Sources, driver, compiler/runtime and generated candidate pins rehash
  unchanged. Closure SHA-256:
  `37cf939922241f125476546becc68105f71952be6c2dc939894d3d2e2a863683`.

The first leaf attempt failed because its extractor began inside a conditional
declaration; the second compiled but exceeded its 30-second simulation cap.
A separate five-second observation advanced 41,269 time steps, excluding a
zero-time loop. The fixed run retains every vector and uses a measured 50-second
bound. Original failed artifacts and diagnostic output remain separately saved.
**This source-extracted miter is not a whole-cache or processor proof.**

### Stronger S_PIPE hint: separately checked, not in the queued candidate

The first hint still includes `pipe_load_req || pipe_store_req`, whose new-issue
path depends on decoded CS extent and permission-related logic. Further source
inspection identifies an earlier equivalent **on issued S_PIPE beats**:
`pf_miss`. A new data issue requires `pipe_frontend_ready`, which requires
`pipe_bytes_ok`; an I-fill requires its negation. A held data packet explicitly
suppresses `pf_miss`, even if executable-line invalidation makes its frontend
nonresident. Simply using `!pipe_bytes_ok` would therefore be wrong.

[The source-extracted request microtest](run_payload_fetch_kind_leaf.py) uses
the actual frontend permit, new/held load/store assignments, and complete S_PIPE
bus branch. It enumerates **1,048,576 Boolean guard-class vectors**, with
135,192 issued beats: 4,096 fetches, 65,544 reads and 65,552 stores. These include
65,536 held reads and 65,536 held stores. Native exit is zero in **7.54 seconds**;
two wrong hints fail natively, including the held-owner/nonresident corner.
The 28,672 idle hint differences are expected and cannot authorize a request.
Receipt: `payload-fetch-kind-leaf-r1/closed.json`, SHA-256
`347a4585d1c017723888f04902ae9b9656a5a43ec241a0e488abc222a84bdce0`.

This test fixes the state to S_PIPE and uses the actual current profile
(`VEN_IC_BRAM`, `VEN_FP_PIPE`, no `VEN_UOPCACHE`). It abstracts later squashes as
independent request cancellations; four additional host checks verify that the
actual driver tail only clears requests and the fragment stage cannot create
one. It is not a whole-core state/translation proof or a timing result.

[The private refinement recipe](prepare_payload_fetch_kind.py) changes only
the earlier proposal's hint assignment to
`(state == S_PIPE) ? pf_miss : !cur_is_d`, adding a live issued-beat equality
assertion. It reuses the same default-off flag and retains the original
`mem_code`, `cur_is_d`, all non-S_PIPE behavior, cache logic and every authority
guard. Drift/reapplication and flag-off equivalence tests pass. **It has not
been compiled into a whole core, exported, synthesized or deployed.** The live
synthesis and queued cache test retain their exact original inputs. If the
current timing result still misses 40 MHz, qualify this refinement in the
whole-core derivative after the cache gate, rather than spending another
synthesis on the weaker request-only cut without examining this dependency.

The [whole-core builder](build_payload_code_hint_core.py) now prepares that
combined derivative in `payload-kind-core-r1/`, without launching a compiler.
It retains all **195 source files**, changes exactly the four interface files
listed above, and preserves all 150 parent defines while adding only
`VEN_L1D_PAYLOAD_CODE_HINT`. The stronger core source is
`a9466e0aeed8d8e147974ec6280bd8a83a99cb7a0736d53d90cf7e3fc56d53a3`;
preparation receipt is
`6e8b7ee2f692b88c563a3e6891af8184288a66f37fc4f7a95bab1dd0699a276e`.
The cache file is byte-identical to the queued cache candidate, while its
upstream hint receives the separately checked S_PIPE refinement.

Four builder admission tests pass, including rejection of disabled assertions,
removed fast mode, missing/failing cache variants, an undetected negative test,
changed cycle streams and missing coverage. Compilation requires the exact
timing/cache continuation's successful native closure, a measured parent result
below 40 MHz, rehashed complete-cache evidence, the guarded-32 scope, and no
live Vivado. Its C++ harness basename is unique to the output directory and its
local object/header dependency must match. **Prepared is not compiled or passed.**

## Next regression, prepared but not yet passed

[The actual-cache driver](run_payload_code_hint_cache.py) reuses the closed
public-transaction backing-memory fixture, its coherent store/snoop/flush,
critical-word/code buffer, high-half and paired-response cases. It adds 32
idle-hint and 32 downstream-denial cases for code/data, resident/missing lines,
then demands the same address. No DUT state is deposited or hit forced.

Control, candidate-off and candidate-on must have identical complete per-clock
public observations, including response owners, addresses and backing narrow
extents. A deliberately wrong sideband must fail natively. Four host fixture
and guard-contract tests pass. The first preparation was superseded before
compilation after catching an incorrect environment-variable name and moving
new trace columns into the existing observer to fix record ordering.

Current preparation: `payload-code-hint-cache-r2/prepared.json`, SHA-256
`3ae6148d979a6d877769540d970c55c92c44bd9cd15393830be3c7a8a03d94bc`.
Execution requires the exclusive guarded-32 profile, explicit external TMPDIR,
at least 5 GiB disk reserve, no live Vivado, bounded builds and native tests.
Do not compile alongside the active synthesis/reporting family. Inspect its
independently audited timing first: if it already reaches 40 MHz, this further
proposal is unnecessary for that target.

The lightweight continuation is now live as
`ventium-payload-code-hint-after-timing-oct12.service`, invocation
`4b6f6ea3cf7f4f9e980e704082bffcc5`. It observes the exact current timing-queue
invocation `cc78495efc6d41229c3f285d9223b767`, then verifies its native closure,
audit and retained input hashes. Only a result below 40 MHz launches the bounded
cache regression; a failed or changed owner stops the continuation without a
restart. Queue source/evidence: `after_timing_payload_cache.py` and
`payload-cache-queue-r1/` under the evidence root. **No cache compiler has been
launched at this documentation point.**

After a real cache pass, complete-core differential/fault/cycle comparisons
must qualify all four changed interfaces before synthesis. Canonical `make
verify` still fails on the parent and is not waived here. The full standard
suite and physical FPGA Win95/Quake acceptance remain required.

Verified gameplay baseline: **0.51030715 total U+V simulated retirement-event
IPC**, older model `2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. It predates
both timing candidates; neither has a gameplay measurement.
