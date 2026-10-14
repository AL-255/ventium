# Remove register-prefix admission from the memory-address payload

October 14, 2026. **Private timing experiment; not promoted or installed.**
The actual-decoder leaf comparison passes **35,065,154 complete payload
checks**, and the source-matched core builds. All 108 private-reference
functional programs and all 108 same-input comparisons pass. Canonical
verification remains **7 functional PASS / 101 FAIL**.
The additional prefix-boundary gate is **failed**, as detailed below.
The full-PC transfer, hardware-profile CPU lint, both short CoreMark CRC
controls and additional system/fetch/environment-fault controls now pass.
Guarded synthesis is running; there is no new synthesis result, Fmax,
throughput gain or physical-FPGA result.

## Measured reason for this change

The [fast-segment parent](../segment_extent/FAST_SEGMENT_ADMISSION.md) reaches
only **35.474830608 MHz synthesized/unplaced**. Its worst EIP-to-ESP path
still has 98 logic levels. The native path explicitly passes through
`p54_prefix66_base.len`, `pipe_mem_u_q.mem_index`, the address generator,
segment admission and memory request/ACK logic. This is a reported netlist
dependency, not an assumption that the shared FPU is the bottleneck.

PREFIX66's fast path admits only register operations. The old packed-payload
selection nevertheless qualifies memory-address fields with the complete
register-prefix admission predicate, including its decoded-length check.
That inserts an unnecessary late dependency ahead of the memory address path.

`prepare_prefix_mem_payload.py` retains the original candidate predicate,
instruction length adjustment, first/second pairing policy and all other
decoded fields. It independently selects 19 memory/unsupported-class fields
as `shift ? 0 : raw_decoder_field`. Eight fields are explicitly excluded by
the original candidate predicate. Eleven address-metadata fields are checked
to be zero in every admitted descriptor exercised by the actual decoder.
No extra cycle, pipeline register, memory speculation, opcode admission,
cache reduction, timing exception or guest-dependent behavior is introduced.

The recipe refuses any drift in both the prefix include and decoder:

- Prefix parent: `73c24c9f7252252203701e7a7872b735a781df020006db2cdf9750dee5a2f116`.
- Decoder: `d1eacb527bb88e22e3501159479adc851bb32e234e74f21848446f6cddcfc929`.
- New private include: `6a29557a726b5536f2655b4d5459d43e157f22579d365b641d9776d507ac4aa5`.

## Closed leaf evidence

Three Python/Z3 tests pass: exact append/reversal and field uniqueness;
source drift/reapplication refusal; and a one-bit cofactor identity with its
wrong-polarity negative control. The symbolic identity covers the explicitly
excluded flags, **not the entire decoder or whole core**.

`tb_prefix_mem_payload.sv` instantiates the production `decode.sv` with the
original and rewritten includes. It compares the **entire packed decoded
payload**, raw decoder payload and admission result, including invalid
descriptors. No fields are masked. It also asserts all 19 selected fields
are zero whenever the original prefixed descriptor is admitted.

Both minimal and exact 152-definition candidate profiles pass **17,532,577
checks each**:

- All 256 opcodes × 256 ModR/M bytes × 256 following SIB/immediate bytes
  under eligible PREFIX66 context.
- Each of six older-owner vetoes, context denial, non-cycle mode, default
  16-bit mode and unprefixed decode, each across all opcode/ModR/M pairs.
- 100,000 deterministic mixed-context/full-window samples and a directed
  non-EAX, SS-based memory load.
- Three deliberately wrong payload variants rejected per profile: reversed
  memory-selection polarity, forced-zero SS selection and incorrect base
  selection. All fail natively with the full-payload mismatch marker.

Each profile exercises **2,525,224 admitted prefix descriptors**. The
unshifted-memory counters are 9,648 and 12,244. Remaining immediate bytes and
EFLAGS vary deterministically; this is not exhaustive over all 56 input-byte
bits or a formal whole-decoder proof. Full-core fault, interrupt, page-boundary
and guest qualification remain necessary.

The leaf closes in **29.50 s**, native exit 0 / MainPID 0. Peak RAM is
**574,115,840 bytes**, with zero swap/OOM. All source and native-log hashes
were rechecked. Owner `ventium-prefix-payload-oct14-r1.service`, invocation
`945cf46e32034edaba388a55ce949cef`. It ran on actual CPU14 through the shared
heavy-build lock, with 2 GiB RAM, zero swap, one compiler and a 580-second
total budget. No Vivado instance overlapped either compiler.

Evidence root: `/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X`.
`prefix-payload-leaf-r1/closed.json` SHA-256:
`96d075884581ee10dc9b36845f673bef8c68eb8c72bf55c533684a667495ebcb`.

## Whole-core transfer and next gates

`build_prefix_mem_payload_core.py` checks all **195 parent sources**, the
parent executable and closed leaf evidence. Exactly
`rtl/core/core_prefix66_decode.svh` changes. All **152 defines**, assertions,
UV/relocated system fast paths and `AXI_LINE_REPLAY=0` remain. Root RTL and
the frozen parent are untouched. The unique private host object was rebuilt
against this candidate's generated header.

The 32-job build closes in **20.16 s**, native exit 0, pins unchanged. Its
scope is capped at 10 GiB RAM / 2 GiB swap; actual affinity excludes CPU11's
older gameplay simulation. New core model SHA-256:
`e3ec298c7049e348ba7ebb6921ef4cdc875faf71cdda76810e124c05a16041e6`.
Parent core model:
`1fb2f09e09ccddfca30ef2423e96226ddae40b4df44b4089204bed2cd79e505c`.

The unchanged canonical `make verify` closes in **397.68 s**, native Make exit
2, with **7 functional PASS / 101 FAIL**. All 20 complete cycle traces are
identical to the parent; existing cycle-band failures remain failed. Input
hashes are unchanged. No golden, mask, comparison option or band was relaxed.
This is not a green canonical gate.

`run_prefix_mem_payload_checks.py` binds those unchanged gates to this model.
Its separate **108-program** private-oracle
functional corpus closes in **113.32 s**, all programs passing, source pins
unchanged and no OOM. Existing comparison policy, including historical x87
stack-fault masks, is unchanged; this is not an unmasked proof of every field.
The private oracle cannot substitute for a green canonical gate. Two further
adapter tests verify unchanged comparison policy and exact reversal of the
same-input replay's identity-only changes.

Core build receipt `prefix-payload-core-r1/build-closed.json` SHA-256:
`6e2dcaca707181bfba2ef9d6ea2fa72d53bafa3f567bc3341b289c173109f2a5`.
Private functional receipt `prefix-payload-func-r1/closed.json` SHA-256:
`4b09e1abc36b7d894b981064dee9735c771fdcde28c2dea14548677b470a1736`.
Failed canonical receipt `prefix-payload-core-r1/verify-closed.json` SHA-256:
`38cf4c8370a51c2aab600d74175696661bc74ffa7a273b0ffd2c9f73606f1cb6`.

The unchanged-input replay then closes in **172.76 s**, exit 0, under owner
`ventium-prefix-payload-same-input-oct14-r1.service`, invocation
`9f953a4118ca4ffba146bb69e73c294d`. All **216 native executions** (108 programs
on each model) pass, using identical input bytes and initial ESP. Complete
architectural records, including the old stack-fault programs, are exactly
equal between parent, candidate and the candidate's first private-reference
run: **80,800 records**, no A/B field masks. Sampled clocks and **30,132 V
retirements** are unchanged. This is **0% sampled cycle-count gain**; the
experiment targets clock frequency, not additional issue throughput.
Actual child affinities, native waits and source pins pass, with zero OOM.
Receipt `prefix-payload-same-input-r1/closed.json` SHA-256:
`eb385ea90c4771b5fe8462cae7e1f8f4ecda22fde4cb223eb09a38132e6ae898`.

### Boundary gate: partial evidence, unresolved reference failures

The **unchanged** `run-prefix66-boundary.py` and assembly fixture run on both
full-core models, with identical enabled profiles. They exercise mapped
instruction crossings, demand-mapped missing tails, finite CS limits and
self-modifying code at four page offsets, in flat and relocated segments.

The gate closes **failed**, native exit 1, in **5.09 s**. Eighteen cases
complete at AXI latencies 0/7: **144 native RTL executions**, of which 72 are
complete QEMU architectural comparisons and 72 are cycle-mode controls with
actual V retirements. Twelve further cases fail **before RTL execution**:
free-running reference QEMU exits 135 (fixture failure), not 133 (success).
These are all eight finite-CS cases and four SMC cases at offsets 4094/4095.
No expected exit, fixture, comparison or field mask was changed to pass them.

A separate diagnostic on `k3-r0-o4094` retains the exact same binary and runs
both RTL models at latency 7. Both exit 133; their 129-record architectural
traces are byte-identical and match a fresh **single-stepped** QEMU trace,
including full system state. Single-stepped QEMU reaches the success marker,
unlike free-running QEMU in the failed gate. This distinguishes the observed
execution modes but does not resolve the reference discrepancy or qualify
all twelve skipped RTL cases. It is **not** a passing boundary gate.

Failed receipt `prefix-payload-boundary-r1/closed.json` SHA-256:
`cae9437414fa4e47d43ea0081129838b5a3d085030ffbf0e77735a55628924a3`.
Diagnostic traces live in `prefix-payload-smc-diagnostic-r1`; identical RTL
trace SHA-256:
`81f60ec036ca11644f67fbe167cec752b04491603619c5895bf536e2253d95a3`.
Stepped QEMU trace SHA-256:
`c599d38217f36d239ba876f98a848b24a055e0f5e976c231f152e4874310b15b`.

## Source-matched full-PC export and additional controls

`audit_prefix_mem_payload_checks.py` independently rechecks **19,622 pins**,
the complete 80,800-record replay and 30,132 V retirements. It confirms 105
unmasked private-reference passes and the three unchanged historical masked
cases; canonical **7 PASS / 101 FAIL** and all 20 unchanged cycle traces are
retained. Audit `prefix-payload-regression-audit.json` SHA-256:
`e16799c98385d94ddae7d4cb7296a56cf207ec0f3b43110058a0d03d841c02e8`.

`build_prefix_payload_soc.py` checks all **102 shared RTL sources** against
the directed core and permits exactly the one prefix include delta. All
**156 full-PC definitions**, UV/system/relocated fast paths, full P5 L1s,
single-fill layout and posted-16 transport are unchanged. The unique private
host object uses this model's generated headers. The 32-job build closes in
**24.14 s**, native exit 0, input pins unchanged, capped at 10 GiB RAM / 2 GiB
swap with actual CPU affinity `0-9,12-31`. It retains the parent's **98
platform structural warnings**; CPU lint below is not full-SoC lint.

Full-PC model SHA-256:
`5eee4d74d729663ad6af4abaa3f0fdbd5cc59937a36945ca81ff46e33b891ce9`.
Build receipt `prefix-payload-soc-r1/build-closed.json` SHA-256:
`b83975fa3eb178ca664b23693027454663472f913c383c82934ae751eece95bb`.
Owner `ventium-prefix-payload-soc-oct14-r1.service`, invocation
`1e5c158894e3432cb1a42d3a6a8da222`, is terminal with MainPID 0 / exit 0.

`freeze_prefix_payload_rk_candidate.py` exports the same single delta onto
the immediate hardware parent. The **190 payloads / 170 HDL sources**,
**158 hardware definitions**, 40/100 MHz clocks, logic-only diagnostic mapper
and source contract are checked. Qualification remains **UNQUALIFIED**.
Manifest `prefix-payload-fpga-r1/input-manifest.json` SHA-256:
`9e53127a928b0044465174583cb7ed87abc8da1d7644056054d3ceeeb5688bbb`.
Strict hardware-profile CPU-hierarchy lint closes in **3.88 s**, exit 0;
the six structural warning classes remain hard errors. Receipt SHA-256:
`d2d71f5eea9183709a79c952f9e9b89747196abc9e644ce713c99e6cab086dfb`.

Additional cold controls use the same compiled candidate, without guest
patches, snapshots, STEP, changed comparison masks or changed fixtures:

- Five generic system fixtures at AXI delays **0/7/31**, both parent and
  candidate: **30 native executions**, complete parent/candidate states and
  clocks identical; the candidate contributes **30,141 records / 5,487 V
  retirements**. Four fixtures also compare complete QEMU architectural
  state. The invalid-SS fixture retains its original Intel-spec assertions,
  not QEMU's permissive segment-limit behavior. Exit 0 in **24.81 s** under
  `ventium-prefix-payload-system-oct14-r2.service`, invocation
  `793205bba8bb4a80b96bfa412dda7004`. The first adapter launch failed on a
  missing Python import **before any test started**; its failed unit is
  retained, the import was corrected and a new unit used.
- **44 x87 environment-store fault/retry fixtures**, delays 0/7: **88 native
  executions** with original complete-state comparisons against the existing
  private environment-corrected QEMU. Exit 0 in **12.38 s**, unchanged source
  pins and zero OOM. This does not promote that private oracle. Owner
  `ventium-prefix-payload-env-fault-oct14-r1.service`, invocation
  `f0f73968038a4c7893c92229be49f3d1`.
- The separate original **22-case fetch-boundary corpus** passes **176 native
  RTL executions / 88 complete QEMU comparisons**, with **21,832 candidate
  records, 4,968 V retirements and 44 probe witnesses**. Its independent audit
  regrades actual native waits, full records, witnesses and **18,357 pins**;
  per-child CPU affinity was not observed by this older driver. Owner
  `ventium-prefix-payload-fetch-oct14-r1.service`, invocation
  `be2bb456fc8046b88812c798257e50cb`, closes in **24.11 s**. This passing
  fetch corpus does **not** supersede the failed prefix-boundary gate above.

Closed receipt hashes, relative to the same evidence root:

| Evidence | SHA-256 |
| --- | --- |
| `prefix-payload-system-r2/closed.json` | `e7707265d23fdbf8b780a9324b5a6d3ebed439beeb2f23748fa34f38852a374f` |
| `prefix-payload-env-fault-r1/closed.json` | `88f62830159802647c58fadec4a8e4b8639339949f26a94127e6ade4178b774c` |
| `prefix-payload-fetch-r1/audit.json` | `fb0ac0169a432b900e0d72403923c657253d7dd9474c6410c9f98d2cef3ae5ed` |

Both unchanged ten-iteration cold CoreMark disks also complete and match the
reference CRCs. Performance/validation ticks remain **4,767,218 / 4,753,406**,
respectively: **0% cycle-count gain**, with **1,055,307 / 1,054,254** final V
retirements. The runs take **211.96 / 221.22 s**; actual CPU12, child argv,
private BIOS/media, posted-16 transport, native waits and closed owner are
rechecked by `audit_prefix_payload_coremark.py`. Its independent audit checks
**21,696 source pins**, all children reaped and zero OOM; peak RAM is
**77,111,296 bytes**. The guest's duration-validation error is retained:
these are **short CRC controls, not error-free standard-suite completion or
duration-valid CoreMark scores**.

Owner `ventium-data-size-cm10-prefix-oct14-r1.service`, invocation
`1790900109be409398c87b786d3432b0`, is terminal with MainPID 0 / exit 0.
`prefix-payload-soc-r1/coremark/closed.json` SHA-256:
`c883e8bb8df44f0bb8030be49137f39ec576a8cf92a95bd5274340a34076964e`.
Its `audit.json` SHA-256:
`5e98dd945d304dc87c1287c6b1fa5692e40fc5529f3da078a984b33ea6352560`.

Four gate-adapter and seven export/timing-policy tests pass. They retain the
original fixture/comparison bodies, check exact source deltas and reject
relaxed memory/disk guards. `prepare_prefix_payload_synthesis.py` prepares
new controllers from the closed parent's exact native lifecycle: one Vivado
family, 45-minute synthesis limit, 8 GiB RAM / 6 GiB swap, 13 GiB combined
early stop, 2 GiB host and 4 GiB disk stop floors, plus the unchanged measured
disk-growth admission. Preparation alone launches nothing and authorizes no
route or deployment.

To preserve that reserve, 68 explicitly inventoried compiler caches and
compiler-product archives were deleted (**1,766,321,496 bytes**). All archive
members were checked to be generated `.cpp`/`.o`/`.a`/`.gch` products; mixed
project archives were excluded. No target was open, all associated current
build owners were closed, and **29,413 protected hashes** were unchanged.
Sources, runnable models, generated headers, logs, receipts, media and timing
checkpoints remain. Cache copies are not byte-recoverable but are regenerable.
Cleanup receipt `prefix-compiler-cache-prune-closed.json` SHA-256:
`a0b01d7b231f5249a9317e4d838cc9c4561ef7da291612ead320efa2b88a5a90`.

After the proof preflight rechecked **26,263 pins**, the single guarded
synthesis launched at **2026-10-14 05:03:33 UTC**. Controller
`ventium-prefix-payload-synth-oct14-r1.service`, invocation
`b8e00fc7ed774b9cbc19b5a024780859`, owns Vivado scope invocation
`63a2e45de4ce46d6be2bb3015e3123c7`. Native closure, independent DCP audit and
read-only clock analysis are pending. The immediate comparison remains
**35.474830608 MHz synthesized/unplaced**; no frequency gain is presumed.

Still required: a green canonical gate, resolution of reference disagreements,
measured synthesis, full-suite and physical acceptance. Do not assume this
cofactor improves Fmax until its own timing report exists.

Latest verified gameplay baseline: **0.50430455 total U+V IPC** on older
simulation model `c7b95b78`, cycles **1,800,065,237–1,900,065,237**. This private
candidate is gameplay-unmeasured; the older window is not its performance.
No complete standard suite, physical Win95 UI, Quake timedemo or Doom FPS
result is claimed for this experiment.

The still-failed prefix-boundary gate now has a bounded native
[reference investigation](../qemu-trace/tb_page/README.md). All four failing
SMC cases reuse stale translated code in pinned QEMU; two finite-CS witnesses
separately execute beyond their segment limit. Eighteen free-running QEMU
diagnostics reproduce the failures, with no guest changes. An exact upstream
two-line TB bookkeeping backport is prepared but not yet built or natively
qualified. The original gate stays failed, and this does not modify the frozen
RTL currently under synthesis.
