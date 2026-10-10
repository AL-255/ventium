# 16-bit demand-fetch candidate

This targets the measured real-mode fetch dip, not a Quake instruction or PC.
The observed `86731249` 2.3B–2.4B window spends 34,702,072/100M clocks in
S_FETCH. Sparse samples show CR0=0x10: paging and cache-disable are both clear.
Do not extrapolate reset-time uncached microbenchmarks to that interval.

`prepare-sfetch16-demand.py` adds default-OFF `VEN_SFETCH16_DEMAND` to a private
core copy. It reuses the existing reference decoder's demand-fetch sequencer:

- Only 16-bit **S_FETCH** changes. S_PIPE, U/V eligibility, execution, retirement,
  permission checks and event ownership are unchanged.
- An interior request obtains four bytes; another is requested only if the
  existing decoder still needs bytes. No cached instruction/length prediction.
- The old full-window page, CS-limit and 16-bit-wrap predicate is evaluated
  first. True boundaries retain the original byte-exact demand/strobe policy.
- Each interior request is a subset of the previously fetched 16-byte extent.
  Existing valid-byte accounting, stale-suffix clearing and walk ownership stay
  intact. No additional cache port, buffer, speculative retirement or stage.
- Removing the new define yields the original source byte-for-byte in recipe
  checks. There is no global real-mode pairing enable or U-only fallback.

## Current evidence

Private model `3dcf4cbb4f74471ae67f6f5c78fad587fa1f0e35693672090d8b597e6d5ccc3d`
is exactly the `dd094313` estimator-width control plus this one core-file change
and define. The actual private harness object/header ownership is checked.
32-job build: native exit0, strict structural classes, 12.36 seconds, stable
source pins. Production `rtl/core/core.sv` is not changed by this experiment.

Five recipe tests pass. Initial 24 cold-reset fixtures pass full QEMU system
traces at AXI latencies 0/7 on both models, with identical retirements, no
faults, native debug-exit133, and an actual 32-bit U/V pair after the 16-bit loop.
Both observation modes have identical clock totals. The fixture exercises
1–15-byte prefix/ModR/M/SIB/immediate shapes, real/16-bit-protected/paged code,
and instruction/page-line placement. Reset-CD real/protected short loops fall
233→145 clocks at latency0; the **cache-enabled paged** counterpart falls
65→56 clocks. These are directed loops, not gameplay gains or CoreMark scores.

Evidence root: `external/tmp/ventium-sfetch16-core.Jk3rQBYO/` (`build-closed.json`,
`smoke-r2/closed.json`). The first 32-worker corpus attempt hit the fixed
128-TID guard while launching QEMU descendants; it is retained as FAIL, not
an RTL failure/pass or an OOM. The rerun keeps 32 cases queued but limits
simultaneous process trees to eight without changing resource caps.

The expanded corpus closes PASS in 233.03 seconds: **2,880 BIOS fixtures ×
two models × AXI latencies 0/7 = 11,520 measurements**, each with full functional
and cycle observations. All 5,760 matched whole-fixture totals improve.
Four 15-byte NOP-prefix loops at paged offsets 17/21/25/29 and latency7 regress
**one clock per warm loop** (269→270 through 273→274); retain this small tradeoff,
not a blanket no-regression claim. The resource-aware rerun has zero PID-limit
events and OOMs, and peak charged memory 2,746,503,168 bytes.

Additional **360 cache-enabled fixtures / 1,440 measurements** pass at offsets
0/3/15/31, with no whole-fixture or warm-loop regressions in that selection.
The real-mode short loop with CD=NW=0 improves **89→58 clocks** at latency0
(34.83% fewer), and 414→271 at latency7. These remain microbenchmark results.
The existing 22 exact fetch-fault/priority cases pass on both models at both
latencies (**88 checks**, full `--cycle-func` differential and real AXI activity).
They test 32-bit fault bodies and 16-bit startup, not every 16-bit exception/event.

`make verify` still **FAILS**: 7 functional passes, 101 terminal-length failures,
no earlier architectural-field differences, and the same four hard timing-band
failures. All 20 cycle-record streams are identical to the `dd094313` control;
different trace-header image paths are not execution differences. Functional
parent runs have different QEMU-initialized stack addresses and are compared
to their own goldens, not normalized to claim byte identity. No gate weakening.

The closed per-case evidence is retained in `full-r2/cases.tar.gz` and
`cached/cases.tar.gz`. Every archived file was reread and SHA256-compared before
removing the unpacked copies. Top-level receipts, exact executed sources and
inventories remain available; the data is recoverable by extracting the archives.

SoC model `958f7ec4` builds from actual gameplay parent `86731249`, changing only
this core fetch policy and the separately checked estimator-width reduction.
It preserves repaired 256 KiB L2, full P5 L1, posted16, UV-fast and 40MHz settings;
the 98 preexisting structural warnings remain unwaived and unchanged. Its source
closure is `external/tmp/ventium-sfetch16-soc.p8u2t1lA/`. This is a simulation
integration candidate, not a new accepted bitstream. The cold full 969-frame
Quake flow is running with unchanged media and completion checks, native
PID 201252 on CPU27, invocation `dc6c0bb3294b4056a2015a9a29ab9c21`. Its
`admission-audit.json` rechecks 244 source and 17 runtime pins and no OOM.

16-bit-specific faults/events, the remaining SMC oracle discrepancy below,
generic-gate repair and the full standard suite remain promotion requirements.
No gameplay measurement exists for either new core or SoC candidate. Latest
verified gameplay on the older `86731249` is **0.49722017 total U+V IPC**, cycles
2.9B–3.0B; all 1.2B–3.0B windows average **0.47771903**, below sustained 0.48.
Full timedemo and FPGA qualification remain open.

## Self-modifying code and oracle correction

`sfetch16-smc.S`, selected by `run-sfetch16-demand.py --scenario smc`, repeatedly
rewrites real RAM code between a three-byte `MOV AX,imm16` and three one-byte
NOPs. Prefixes and line/page positions vary; far CALL/return uses real guest
instructions. Real, protected16 and paged16 modes run with caches enabled and
finish with an actual 32-bit U/V pair. No debugger writes or state injection.

The full matrix has **1,152 fixtures**, all 32 line offsets, six prefix counts,
both interior/page-tail placement and all three modes. The first full run
retains **FAIL**: 1,064 fixtures / 4,256 A/B measurements pass, 87 fixtures fail
the free-running QEMU self-check, and one GDB listener startup fails. Fixed,
unique per-case ports outside the host's ephemeral range replace recycled
ephemeral ports; QEMU startup stderr is now retained. The missing fixture passes
unchanged in the targeted rerun, with real AXI activity checked.

All **87** execution failures have exactly this shape: the instruction starts
with unchanged prefixes on page 1, while every modified byte is on page 2.
Free-running pinned QEMU executes the old MOV after it has been replaced by
NOPs (exit135), including with one-instruction TBs. Stepped QEMU executes the
new bytes correctly. Both RTL models match its complete trace at AXI latencies
0/7 on all 87 cases (**348 diagnostic A/B measurements**, native exit133,
zero faults, actual U/V). This is evidence of a QEMU code-cache invalidation
discrepancy, **not a waived free-running gate or a standard-suite pass**.
Investigate second-page TB invalidation; do not modify the guest to hide it.

Independent `smc-coverage-audit.json` accounts for all **4,608** A/B measurements:
1,065 ordinary fixture passes and 87 diagnostic-only fixtures. It verifies
actual backing-service counters and V pairing in every selected artifact.
`smc-full/`, `smc-open-diagnostic/`, `smc-port-rerun/` and
`external/tmp/ventium-smc-qemu-diag.6lXlSy0p/` retain receipts and failures.
Closed full-corpus case data is losslessly archived with every file rehashed
before removing unpacked copies; extract `smc-full/cases.tar.gz` to replay it.

The tests also exposed wrong instruction-byte metadata in the system golden
collector: QEMU's g-packet omits CS.base, but the collector used `selector<<4`
even in protected mode. It now observes the actual hidden CS cache using a
fixed read-only monitor query, with six fail-closed protocol tests. Across 24
identical BIOS images, **3,800 architectural records are unchanged** and 2,304
byte-metadata records are corrected. The 24-fixture differential and all 88
fetch-fault checks pass again (`observer-smoke/`, `boundary-observer/`). No
record trimming, flag-mask changes or QEMU binary changes are involved.
