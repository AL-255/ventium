# Scalar x87 reference-packet dispatch — October 9

Private, default-off `VEN_FP_SCALAR_DISPATCH`; **not production, full-suite or
FPGA acceptance**. Latest verified gameplay remains **0.43739106 total U+V
IPC**, REP model `139121ae`, clocks **1,200,084,750–1,300,084,750**. It predates
this candidate, instruction-permission shadow, target read and read-retirement
priming. No gameplay gain is claimed for this change. The full REP direct-memory
CoreMark scores are **2.107861982 / 2.110913372 CM/MHz**, not this model's scores.

## Implementation

After acquiring the complete checked x87 encoding, the ordinary slow handoff
spends another clock in `S_DECODE` capturing the same reference-decoder packet.
For a restricted scalar-memory operation with no pending architectural event
or older FPU work, capture that packet at the existing `S_PIPE` handoff and
enter `S_FLOAD` directly. This removes a dispatch clock, not an operand check.

`prepare-fp-scalar-dispatch.py` changes only private `rtl/core/core.sv` and adds
`core_fp_scalar_dispatch.svh`. It reuses `capture_reference_decode(eip)` and
the original issue-time TF/RF capture. No new decoder, memory transaction, FPU
command producer, queue, retirement or architectural write occurs on that edge.
The existing shared-store pre-probe, operand loads, `S_FEXEC`, `S_FSTORE` and
fragment engine remain unchanged.

Admission requires the existing exact short-byte/page/CS/registered-owner
predicate; 32-bit supported, unlocked, unprefixed scalar x87 memory operations;
one read/write direction; valid protected/relocated context; EM/TS/ES clear;
no older async/shared FP work, debug, step, interrupt shadow, SMI/NMI/INTR,
AGI, misprediction or stall. Environment/control/BCD/transcendental operations
remain on their original paths. Already-fast forms continue using their
existing earlier dispatch. Disabled builds drive the new predicate false.

## Closed evidence

Root: `external/tmp/ventium-fp-scalar-dispatch.6fiRUL1F`.
Parent is the pair-safe read-retirement candidate `19ac54ac`.

- Board-address model:
  `2dfec98c132fc60e62b07d19ec3e4a959c8c9a0ee6cfcc1eb294e8ec5f1074ed`.
  Full-address user model:
  `2b61d70586c2ec328d1fcbac50c79baf556c2b3d12ef401397744eb1b7e9a012`.
  Native builds pass with assertions, six structural hard-error classes,
  stable source pins and model-local host-object/generated-header checks.
- `hardware-lint-r2`: parent and candidate also pass with `SYNTHESIS` and
  `VTM_NO_DPI`, keeping all six structural hard errors. The initial attempt
  refused the recorded duplicate `VEN_FPREM`; the retry preserves that exact,
  unvalued duplicate in both profiles rather than changing any define. This
  is synthesis-guard lint, not Vivado synthesis or hardware timing evidence.
- Actual helper leaf: **66,688 checks each**, enabled and disabled. Includes
  all 128 operation enum values/four memory directions, all pairs of 24
  blockers, all system contexts, all FSW values and relevant CR0 combinations.
- Five transformation guards pass: missing/duplicate anchors, reapplication,
  unchanged original capture, disjoint copy scope and existing-output safety.
- `matrix-r1`: **all 288 complete QEMU architectural comparisons and cycle
  counterparts pass**, but the short warm-slice **performance gate FAILS**.
  At AXI latency seven, FIST/FST's selected 12-iteration slice gains one clock
  while the complete program loses one clock. That failure is retained.
- `throughput-r1`: a separate **256-iteration** fixture passes all 288 full
  QEMU comparisons/cycle counterparts. All 144 matched complete-program totals
  and 223-interval steady windows are nonregressing. At AXI latency seven,
  FIST/FST steady throughput is unchanged: both are ten clocks per iteration.
  This supports a queue/fill-transient explanation for the short slice; it
  does **not** retroactively turn `matrix-r1` into a pass.
- `events-r1`: four full QEMU comparisons plus cycle executions. Eight visits
  include normal, TF, RF, TS and EM cases; exact #NM-before-store, #DB-after-store,
  restart EIP, sentinel, DR6 and actual candidate-dispatch witnesses pass.
- `smc-r1`: sixteen full QEMU comparisons plus cycle executions. An ordinary
  CPU store changes RAM-resident FST32 to FIST32; both eight-call phases check
  their different results. Four instruction placements include line crossings.
- `fault-r1`: **48 full QEMU comparisons** plus cycle executions. FISTP32,
  FSTP64 and FSTP80, aligned/cross-page destination, absent/read-only second
  page, both models and AXI latencies 0/7. Every candidate fault has an actual
  scalar-dispatch witness. Handlers verify precise #PF EIP/error/CR2, all
  destination canaries unchanged and unpopped ST0. Only the PTE is repaired;
  restart stores exact 1 and pops exactly once. Real V pairing is required.
- `system-matrix`: 76 cases pass complete QEMU comparisons and parent
  architectural parity; no trace trimming, changed guest, snapshot or masks.
- Unchanged UV-fast/AXI `make verify`: **FAIL**, native exit 2, stable pins.
  7/108 functional passes; 101 terminal-record mismatches. The same four hard
  bands fail: depadd 1.133, indepadd 0.639, dmiss 5.000, imiss 13.003 CPI.
  An independent parent replay under **identical image/initial-stack inputs**
  matches every complete architectural record for all 108 programs. This is
  nonregression evidence, not a green differential gate. The first cross-run
  audit refused differing QEMU-loader ESP values; the replay executes the
  parent afresh, without normalizing any register or dropping a trace record.
  `qualification-closed.json` explicitly preserves both failed gates.

Representative flat-context, byte-17 steady loop clocks:

| Instruction + DEC/JNZ | AXI latency | Parent | Candidate |
| --- | ---: | ---: | ---: |
| FIST32 | 0 | 8 | 7 |
| FST32 | 0 | 9 | 8 |
| FIST32 / FST32 | 7 | 10 | 10 |
| FIADD32 | 0 / 7 | 8 | 7 |
| FCOM32 | 0 / 7 | 5 | 4 |
| Already-fast FADD32 | 0 / 7 | 3 | 3 |

FNSTCW/FNSTSW, FLDCW and prefixed FNSTCW negative controls are unchanged.
These are directed loop measurements, not isolated gameplay gains or an
FPGA frequency/resource result. The added combinational predicate and packet
capture path still need complete-chip timing/area qualification.

## Full-PC integration, not launched

`external/tmp/ventium-fp-scalar-soc.auXK03FE` derives from pair-safe read-prime
model `15f56054`. Only `core.sv` and the new helper change; every core/FP source
matches the microtested candidate. The compile adds exactly the scalar flag
(128 unique defines), with unchanged U/V, fast system/relocated paths, full P5
L1s, 32-KiB platform L2, posted16 and registered read-first Xilinx-memory model.
The host source content is unchanged, with a unique basename/local header.

Native build passes, model
`73ce5538dd633c5fb62030c54e4b62d44d2572a9ff3165e73ba96ac7f0d92e39`.
The same 98 third-party structural warnings remain; no new structural-warning
waiver is added. This is **not clean whole-SoC lint**. No cold guest, gameplay
measurement, CoreMark score, full-suite or FPGA acceptance is claimed for it.
Existing cold guest measurements continue on their frozen earlier models.

## Reproduce

Set `TMPDIR=/home/yukidama/external/tmp`. Build separate frozen parent/candidate
models with unique host basenames, U/V, system/relocated fast path and AXI;
add **only** `VEN_FP_SCALAR_DISPATCH` to the candidate. Compile/fan-out under
`tools/build_scope.sh --` with the bounded `ipc_parallel32` profile. Runners
use eight QEMU workers followed by 32 RTL workers, with 60-second child limits.

```sh
python3 -B verif/fe_pipe/test_fp_scalar_dispatch.py
python3 -B verif/fe_pipe/prepare-fp-scalar-dispatch.py --source PARENT --out COPY
# Each runner accepts --control TB --candidate TB --out FRESH_EXTERNAL_DIRECTORY:
python3 -B verif/fe_pipe/run-fp-short-window.py --feature scalar-dispatch ...
python3 -B verif/fe_pipe/run-fp-scalar-throughput.py ...
python3 -B verif/fe_pipe/run-fp-scalar-events.py ...
python3 -B verif/fe_pipe/run-fp-scalar-smc.py ...
python3 -B verif/fe_pipe/run-fp-scalar-fault.py ...
```

Remaining: generic-gate closure, full standard suite, ≥0.48 gameplay IPC and
qualified FPGA integration/deployment. No U-only or global-slow workaround.
