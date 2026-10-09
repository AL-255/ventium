# Independent REP continuation admission — October 9

Private, default-off `VEN_REP_CONT_NO_UOP`. Not production, FPGA or standard-suite
acceptance. Latest verified gameplay is **0.43739106 total U+V retirement-event
IPC**, REP model `139121ae`, cycles **1,200,084,750–1,300,084,750**.
The audit in `external/tmp/ventium-rep-gameplay-audit.753XgqaN/audit.json`
rechecks 234 source / 17 runtime pins, native identity and unchanged gameplay
frames: **43,739,106 = 32,629,256 U + 11,109,850 V / 100M clocks**.
This is not a completed timedemo or FPGA result. Permission/target-read and
read-retirement priming candidates are newer and unmeasured; **0.48 remains open**.

## Cause and narrow fix

The current full-PC inventory enables `VEN_REP_MOVS_CONT`,
`VEN_REP_MOVS_LOAD_FUSE` and `VEN_REP_MOVS_STREAM`, but omits `VEN_UOP_SFETCH`.
Their shared `rep_stos_cont_profile` is therefore zero, disabling all three
paths. Measured MOVSD residency is 758,808 of 2,918,429 slow-decode clocks
(26.00%); this does not mean all those clocks can be eliminated.

`prepare_cont_no_uop.py` changes only profile admission in a private source
copy. Its opt-in branch selects `cycle_mode`, as the older uop-short-fetch
profile did, without enabling a uop cache. Ordinary decode, exact shapes,
q_* ownership, final-store ACK, event/debug priority, translation, partial-
progress rollback, sticky executable invalidation and preissue cancellation
remain unchanged. This also enables ordinary STOS continuation, not the
absent `VEN_REP_STOS_STREAM` flag. No later-source read precedes the older
destination ACK; no RAM port, queue, guest recognition or workload change.
The old dependency was deliberately conservative and needs fresh coverage.

## Directed evidence

Root: `external/tmp/ventium-rep-no-uop.7Yn9EBWr`.

- Three fail-closed source-anchor/reapplication tests.
- Board model `c90d053cc7aadb70de9f6d06bd29601772b5b965f3a879d13626674650d4421d`;
  identity-address user model `cbe7441199347173e49647a672c3a7ad403513b83b63013416f76345c89e7446`.
  Native builds pass six structural hard-error classes, stable input pins
  and per-model host-object/header ownership checks.
- `matrix-r5`: **32 complete pinned-QEMU system/x87 comparisons**, each with
  separate cycle execution. Forward/reverse nonuniform copies, exact alias,
  overlapping propagation both ways, unaligned source/destination page
  crossings, zero count, byte/word/address16 fallback, static instruction-page
  crossing and CPU-store MOVSD→STOSD SMC at I-line offsets 0/17/31. Caches are
  enabled in the basic fixture. Every basic execution has actual U/V pairing;
  candidates have 184 next-source arms and 193 fused source acknowledgements,
  controls none. Source/destination #PF retries and MOVS/STOS data #DB variants
  retain full QEMU traces plus guest frame/pointer/memory checks.
- `system-matrix`: **76 cases**, full QEMU comparison and exact functional
  parent parity across 19 system fixtures at AXI latency 0/7.
- `smi-r1`: **four structural cases**. MOVS requires immediate ARM→CANCEL,
  no source/GPR side effects, exact P5 save-map pointers and RSM restart.
  STOS requires an otherwise-ready continuation to lose to SMI. This is
  RTL structural coverage, not a QEMU SMI differential claim.
- `irq-r3`: **36 external-IRQ structural cases**, each in cycle-functional and
  cycle mode: counts 4/32, placements 0/17/31, AXI latency 0/7/31, both models.
  The existing pin-only probe raises a held IRQ after an actual retirement and
  lowers it only on INTA. Exact witnesses require the candidate's second source
  to finish after the request but before INTA, with no cancellation/replay of
  an already-started read. The handler checks the complete committed prefix,
  untouched suffix, saved EIP/CS/IF and ESI/EDI/ECX; IRET and final memory are
  checked too. Control takes the IRQ after one element, candidate after two.
  All runs retain actual U/V pairing, one request/acknowledgement and exactly
  one vector64 delivery. The initial checker incorrectly treated that intended
  interrupt as an unexpected fault; its failed run is retained.
- `debug-r4`: **18 halt/resume cases**, each functional and cycle execution:
  placements 0/17/31, AXI latency 0/7, inactive/pending/started stimulus.
  The new host probe links the unchanged frozen RTL archive and drives only
  `dbg_halt_req`, never STEP, breakpoint, internal registers or guest memory.
  Pending next-source reads cancel before access; already-started reads finish
  their element before HALTED. Exact ECX/ESI/EDI/restart EIP, all GPRs/EFLAGS
  stable for 1,024 clocks, complete committed memory prefix and untouched suffix
  are checked. Resume retains every architectural record and full pinned-QEMU
  agreement. Inactive traces are byte-identical in both modes; actual U/V pairs
  remain outside the pause. Debug-active cases are **diagnostics, not performance
  or standard-suite acceptance**. Initial attempts rejected optimized-away
  signal aliases and incorrect comparator CLI spelling; their failures remain.

Warm 32-element MOVSD at zero added AXI latency: candidate gaps are
29×3 clocks + 2×2 clocks. Controls mostly cost 5 clocks at offsets 0/31,
alternate 10/12 at offset 17, and cost 11 at the static page crossing. These
are **directed results, not gameplay IPC**. Higher AXI latency largely masks
the gain; the whole offset 17 fixture at latency 7 regresses 31,035→31,754
clocks (+2.32%). No universal speedup or latency waiver.

## Failures retained and remaining coverage

`page-smc-r2` stays **FAIL**: changing the second page of an instruction
starting at page+4095 fails the guest under free-running QEMU (exit 135), while
single-step QEMU passes. Free-running CPU logs show ESI advancing after MOVSD
was changed to STOSD, consistent with stale translated code. Both RTL models
at both latencies match all 1,098 records against single-step QEMU. The separate
static page-crossing case does not replace dynamic SMC or resolve that oracle
disagreement. No guest patch, trace trimming or oracle-state substitution.

Earlier driver failures remain archived: initial cache-disabled timing;
incorrect assumption that data #DB uses `start_fault`; handler-PC counting
that ignored the trace's synthetic delivery record; and a cold pair witness.
The final driver retains all records, counts the handler's MOV DR6 execution,
and checks a repeated warm U/V pair. `matrix-r1` through `matrix-r4` are retained.

Canonical UV-fast/AXI `make verify` remains **FAIL**, native exit 2, stable pins:
existing terminal-record discrepancies and four hard cycle bands. No waiver.
Focused NMI arrival coverage remains needed. Host halt/resume covers both
pending and already-started phases; SMI covers preissue cancellation and
external IRQ covers completion of a started source. This candidate is not
declared complete.

## Full-PC measurement

`external/tmp/ventium-rep-no-uop-soc.O13aL61T` freezes only this core predicate
and flag on combined parent `05611d6c`. Model
**`139121ae7864dd89b3b3cc06096ea51e4a045205497a10f93035d21b848c70ad`**:
124 defines; full P5 L1s, posted16, platform L2 and registered XPM read-first
behavior unchanged. Native build, full source-closure equality and private
host/header checks pass. The 98 existing platform warnings remain unchanged.

Cold Quake runs on CPU 29 in `ventium-rep-no-uop-quake-oct09.service`, invocation
`d9d3b18bc2eb40ada26198c0a1214d7b`; actual native admission is recorded.
No snapshot, guest edit, STEP or global slow fallback. The initial service
attempt was rejected before guest launch for a missing required file-size
limit, and its failed receipt is retained. Quake-only disk admission is 6 GiB
against <1 GiB bounded artifacts; the prepared Win95 launcher retains 8 GiB.

This full-PC model has **no gameplay score, Win95 desktop or FPGA
acceptance yet**. Its matching core has passed the direct-memory CoreMark
qualification below. Cold Win95 is now running on CPU30, invocation
`06d2598e26e541908ef2f442414ef802`, with native admission verified. Existing combined tests
continue independently; source/native pins and complete timedemo checks remain
mandatory before any success claim.

## CoreMark qualification

Direct-memory model `cb4b2f841284b123786791cdf5fc356eabb546555facaa185b39e8a5edd30951`
is built from this exact core in `external/tmp/ventium-rep-no-uop-coremark.Gszccvp5`.
Both short ten-iteration seeds pass CRCs, zero actual faults and exact
control/optimized whole-model plus mapped-memory equality. The host-only
settle optimization changes no simulated clock or state. Both seeds save
**1,648 core clocks** versus the combined parent, with identical retirement
counts; short seeds are not score-eligible.

`qualify-r3` repeats on CPUs16/17 and passes all 15 invalid-mode controls.
Full 1,500-iteration seeds closed in `full-r3`, invocation
`f9fede48a89b4afba77ef45ea3435e49`, with the unchanged **3,600-second cap each**.
Fresh measured host rates project about 3,436/3,366 seconds. The launch-only
planning buffer is reduced from four minutes to two; correctness, CRC, score
and hard runtime gates are unchanged. The combined parent just closed at
3,413/3,327 seconds on those CPUs. The independent closed-run audit rechecks
114 pins, all five CRCs per seed, zero actual fault deliveries, native exit0,
no OOM and reaped children:

| Seed | Whole-program clocks | Retirements | CM/MHz | Host seconds |
| --- | ---: | ---: | ---: | ---: |
| Performance1500 | 711,621,545 | 542,165,465 | **2.107861982** | 3,518.21 |
| Validation1500 | 710,592,874 | 541,458,844 | **2.110913372** | 3,503.84 |

`full-r3/independent-audit.json` passes. This meets the **2.1 direct-memory**
target, not FPGA/cache/DDR throughput or full standard-suite acceptance.
Whole-program clocks fall by 168,436 / 168,519 versus the combined parent;
the small runtime-calibration retirement differences remain reported, not
normalized away. The later instruction-permission shadow is not in this model.
