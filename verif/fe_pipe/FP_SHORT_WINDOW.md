# Exact x87 instruction-byte capture — October 9

Private, default-off `VEN_FP_SHORT_WINDOW`; **not production or standard-suite
acceptance**. Current verified gameplay is **0.39002079 total U+V IPC**, code-word
model `f3be9a11`, cycles **1,200,000,000–1,300,000,000**. It predates this change,
tag LUTRAM and data-under-I-fill. The 0.48 target is open.
Earlier full direct-memory CoreMark scores are 2.10736/2.11041 CM/MHz, not this
candidate's score or an FPGA cache/DDR measurement.

## Cause and fix

`S_PIPE`'s existing slow handoff demands all 16 reference-decoder bytes before
copying the resident instruction window. A short x87 instruction can already
have its complete encoding in the current registered I-cache line, while an
unused suffix lacks the required registered owner. The old handoff enters the
bus-fetch path and repeatedly spends clocks acquiring bytes it will not use.

`prepare-fp-short-window.py` changes only `rtl/core/core.sv` in a private copy:

- Recognize an **unprefixed D8–DF encoding**, known to the existing reference
  decoder, with its actual 2–7-byte length. No new instruction grammar.
- Require current registered ownership of both endpoints, no collision/snoop,
  no checked-fetch diversion, and exact page/protected-CS extent checks.
- Reuse existing exact-length capture/zero-padding into `ibuf`, then enter
  **ordinary S_DECODE**. It still owns #NM/#MF, debug, event, operand and
  execution decisions. This is not x87 direct dispatch or speculative execution.

No FPU command/queue/state logic, memory transaction, cache capacity, RAM port
or stored predecode state is changed. Existing direct integer dispatch still
excludes x87. Flag-off source is whitespace-equivalent to the parent.

## Closed checks

Root: `external/tmp/ventium-fp-short-window.vbTYVUL1`.

- Five source-recipe checks: default-off identity, exact scope, anchor drift,
  reapplication and source-copy isolation.
- Board model `11c8da0fe78ac29af45b443370e90a548fcf867f933fdc83061d43e03700d3c7`;
  full-address user model `1659cae989fe080bfe312c6b212a3d650e315162de3394df17d4df5aa09d3081`.
  Native builds pass six structural hard-error classes, stable input pins and
  private host-object/generated-header ownership checks.
- `unit-r1`: **492 checks of the extracted actual predicate**. All 256 opcode
  values, all length values, owner loss, snoops, context/fetch blockers, exact
  page/CS edges and wrap rejection. This is an admission unit, not a RAM model.
- `matrix-r1`: **288 complete pinned-QEMU architectural comparisons** and
  288 cycle executions. Nine forms include FNSTCW, FLDCW, FIST32, FST32,
  FADD32, FIADD32, FCOM32, FNSTSW and prefixed FNSTCW. Flat/256-MiB relocation,
  offsets 0/17/18/31, AXI latency 0/7. Every execution has an actual U/V witness;
  actual `FP-SHORT` captures are required for the affected cases. Prefixed
  FNSTCW never uses the new capture. All 144 matched warm comparisons are
  non-regressing; no guest state, trace records or oracle fields are replaced.
- `events-r4`: full QEMU x87/system-state comparison at both latencies and
  both models, 303 records each. Eight visits to the same byte-17 FNSTCW
  include TF, RF, CR0.TS and CR0.EM. The handlers prove exactly two #NM faults
  **before** the store, one TF #DB **after** it, exact restart EIPs and successful
  retries. Real V retirement remains present. Capture itself is allowed under
  debug; the unchanged decoder still makes all architectural decisions.
- `smc-r1`: **16 complete QEMU comparisons** plus cycle runs. Ordinary CPU
  stores change RAM-resident FNSTCW into FNSTSW, followed by a taken transfer.
  Both eight-visit phases check the different expected results, at four
  placements including a line crossing, two latencies and both models.
- `system-matrix`: **76 cases** from the retained ordinary/system corpus pass
  full QEMU comparison and complete parent architectural parity.
- Canonical UV-fast/AXI `make verify`: **FAIL**, native exit 2, stable pins;
  7/108 functional passes, the same 101 terminal-record mismatches and four
  hard bands (depadd, indepadd, dmiss, imiss). No waiver or comparator change.

Representative byte-17 warm loops, flat context, zero added AXI latency:

| x87 instruction + DEC/JNZ | Parent clocks | Candidate clocks |
| --- | ---: | ---: |
| FNSTCW / FNSTSW | 12 | 7 |
| FLDCW / FCOM32 | 11 average | 5 |
| FIST32 | 13 | 8 |
| FST32 | 14 | 9 |
| FIADD32 with SIB + disp32 | 14 average | 8 |
| Already-fast FADD32 | 3 | 3 |
| Prefixed FNSTCW, negative control | 12 | 12 |

These are placement-specific directed loop savings, **not gameplay gains**.
The first smoke run passed architectural/cycle comparisons but did not enable
the diagnostic plusarg; it is not the capture-witness result. Event attempts
r1/r2 rejected stale fixture/symbol names in the new runner; r3 rejected the
legacy stderr PC-change observer mixed into canonical fault-log grading.
r4 reads canonical fault stdout separately. All failed logs are retained;
neither RTL nor the fault-count oracle was weakened to pass.

## Combined full-PC qualification

`external/tmp/ventium-short-ifill-soc.aumJObke` combines this capture change,
tag LUTRAM and D-under-I-fill with the existing code-word/pop/LRU/XPM model.
Only `core.sv` and `ven_l1d.sv` change versus the code-word parent; all compiled
core/FP files match the microtested source. The 123-macro inventory adds exactly
the three corresponding feature flags. Host content is unchanged, with a unique
basename and verified local generated headers. Native build exit zero:
`05611d6c2ac8dc767b162ed18bbf1c63daeff78d760702b4ada03eed83d37d71`.
The same 98 third-party structural warnings remain; this is not clean SoC lint.

Cold Quake/Win95 services are launched on CPU22/23, with unchanged media,
40/40/80 MHz, full P5 L1s, 32 KiB platform L2, posted16 and FPGA XPM
registered/read-first behavior. No snapshots, STEP or guest changes. They are
unqualified until native results and visual/gameplay evidence are checked.

Native admission IDs are `37dc265fbdc94300aa8af60f702f697e` (Quake) and
`c09f78702ecc45db8c00b74cf3b59d0f` (Win95). The first Win95 launch rejected
an unresolved output-path alias before starting a simulator; the retry uses
the resolved path and unchanged launcher. Four superseded XPM/pop guests
subsequently closed through their ordinary host stop requests, with native
exit zero, reaped children and no OOM. Their incomplete timedemos remain FAIL;
Win95 remains CLOSED_UNQUALIFIED. Receipts:
`external/tmp/ventium-old-window-stop.5IpBAhgh/closed.json`.

### Current CoreMark qualification

`external/tmp/ventium-short-ifill-coremark.qQqbebWo` builds this same core
source with the unchanged qualified host-only settle optimization. Model:
`c93ae26b20685827dacf45b466256e4139bb1d068d7546ec467801c0a8502c0b`.
The two 10-iteration seeds match all CRCs and exact control/optimized serialized
model plus mapped RAM. Retirement counts match the parent; each uses **96 fewer
core clocks**. These short runs are not score-eligible.

`qualify-r1` remains FAIL: its copied check incorrectly required unchanged
parent RTL clocks. It nevertheless records exact within-model state equality.
`qualify-r2` requires identical control/optimized counts and full state, unchanged
parent retirement counts, nonregressing clocks, zero actual faults and all
15 unsafe-mode negative controls. It passes, with stable pins and no OOM.
This changes a host-equivalence expectation, not any architectural comparison,
CoreMark CRC, score threshold, differential timing band or runtime limit.

Both full 1,500-iteration seeds are now active in `full-r2`, invocation
`2034f3eec45a4ab6830530d668a3baf9`, CPUs16/17. Each retains its **3,600-second
hard cap**. No result or ≥2.1 claim for this binary exists yet. This is the
direct-memory core test, not a cache/DDR/FPGA score.

## Reproduction and remaining work

```sh
TMPDIR=/home/yukidama/external/tmp python3 -B verif/fe_pipe/test_fp_short_window.py
python3 -B verif/fe_pipe/prepare-fp-short-window.py --source PARENT --out CANDIDATE
# Build separate UV-fast, AXI-enabled models with private host basenames.
# Add only +define+VEN_FP_SHORT_WINDOW to the candidate.
python3 -B verif/fe_pipe/run-fp-short-window.py --control CONTROL --candidate CANDIDATE_TB --out MATRIX
python3 -B verif/fe_pipe/run-fp-short-events.py --control CONTROL --candidate CANDIDATE_TB --out EVENTS
python3 -B verif/fe_pipe/run-fp-short-smc.py --control CONTROL --candidate CANDIDATE_TB --out SMC
```

Use `tools/build_scope.sh` with the bounded `ipc_parallel32` profile for
compilation/fan-out; the predicate runner also requires that scope. All new
outputs go to external scratch. Remaining: generic-gate closure, full latest
CoreMark seeds, Win95 desktop, complete Quake timedemo, ≥0.48 gameplay IPC,
combined FPGA timing/resource qualification and deployment. No hardware MHz
claim follows from these simulation clock reductions.
