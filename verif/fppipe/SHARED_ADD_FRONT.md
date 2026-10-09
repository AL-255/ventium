# Shared FP arithmetic front: same-cycle FPGA-area proposal

Status: **integrated-test-qualified proposal, not applied to production RTL**. No Quake
IPC, whole-core timing or standard-suite improvement is assigned to it.
Current verified gameplay is **0.37576697 total U+V retirement-event IPC**,
posted16 model `3c8779f4`, cycles 1.2–2.5B; it predates this proposal.

`ven_fp_alu.fast_front` originally invokes `fx_add_s1` separately for add,
subtract and reverse subtract. The helper contains operand alignment, sticky
generation, wide arithmetic and leading-bit detection. Synthesis retains
substantial separate logic despite the leaf's "shared" name.

`shared-add-front.patch` selects operand order/sign before **one** invocation.
`f_special` continues to receive the original operands and opcode: flipping
or exchanging those first would change NaN propagation and special cases.
No validity, register, latency, forwarding or command-acceptance logic changes.

The optional second patch, `shared-add-auto-dsp.patch`, removes the module-wide
`use_dsp="yes"` attribute. Native synthesis shows that the attribute forces
many wide add/subtract/rounding operations into **unpipelined DSP cascades**.
Automatic mapping retains 16 DSP48E2s for multiplication while using ordinary
carry logic for the additions. No multiplier is replaced with a sequential
engine and no clock is added.

## Reproduce the sequential A/B

```sh
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
  python3 -B verif/fppipe/run-shared-add-front.py
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
  python3 -B verif/fppipe/run-shared-add-front.py --auto-dsp
```

The runner creates a fresh external directory, copies and patches only private
RTL, renames the untouched original leaf as the control, pins inputs and
builds with assertions and all six hard structural-warning classes under the
32-job shared memory guard. The fixture checks **311,557 edges per seed**, seeds
1/17/20260830, requiring exact busy/done/commit-next timing, all 85 result bits
and the entire registered unrounded front, even when final rounding could hide
a difference. It covers all RC/PC values, eight dispatch codes, distinct NaNs,
denormals, unsupported encodings, signs/cancellation, alignment limits,
back-to-back starts, bubbles and in-flight resets.

Both proposals pass all **934,671 edge comparisons** against the original.
This is broad simulation equivalence coverage, not an exhaustive formal proof.
The independently repeated runner outputs are `ventium-shared-add-front-repro.x6aii95z`
and `ventium-shared-add-front-repro.uu2sv3zy` under external scratch. The first
attempt's malformed patch was rejected before any build; its failed service
record is preserved. The corrected patch also passes `git apply --check`.

## Closed, same-constraint native FPGA leaf synthesis

Part `xczu15eg-ffvb1156-2-i`; clock **40 MHz (25 ns)** applied before synthesis;
same packages, default synthesis, OOC/flatten-none, zero external I/O delays.
Only one Vivado family runs at once through the exclusive launcher. Each
experiment has an 8 GiB RAM/2 GiB swap cap and a proactive 9 GiB combined guard.

| Measurement | Original | One add front | One add front + automatic DSP |
| --- | ---: | ---: | ---: |
| Reported combined CLB LUTs | 8,093 | 5,221 | 5,787 |
| FF | 462 | 455 | 475 |
| CARRY8 | 195 | 155 | 267 |
| DSP48E2 | 88 | 58 | 16 |
| Native synthesis seconds | 96 | 42 | 48 |
| Unplaced setup WNS at 40 MHz | +9.446 ns | +8.748 ns | +12.275 ns |
| Path-local unplaced frequency estimate | 64.29 MHz | 61.53 MHz | 78.59 MHz |

Use `report_utilization`'s combined CLB LUT count, **not** the larger count of
individual LUT primitive cells. The frequency row is `1000/(25-WNS)` for this
leaf and is **not routed core Fmax**, board reliability or clock authorization.
The automatic-DSP candidate saves **28.49% LUT / 81.82% DSP** against the original,
with a better local timing estimate; it costs 566 LUTs versus sharing alone.
It is the preferred integration candidate, subject to full-design verification.

Native artifacts: `ventium-shared-add-front.8wI530Oz/{synth-control,synth-candidate}`
and `ventium-shared-add-front-repro.uu2sv3zy/synth-candidate`. Each contains
utilization, timing, fanout, native completion and DCP. Root-level `.py`/`.tcl`,
`synthesis-started.json`, watch logs and `synthesis-closed.json` retain commands,
source pins, ownership and native exit. Both closed with zero swap/OOM;
peak cgroup RAM was 3.843 GiB / 2.887 GiB. No full-board CAD retry was launched.

Before promotion: exact-source integrated FP/architectural gates, ordinary
differential gate (currently separately red), standard suite, and full placed/
routed timing. Keep the current dispatch guest runs intact: they do not include
this proposal. Do not claim area savings have raised their IPC.

## Integrated FP qualification, October 9

`ventium-dispatch-fp-integration.iFPahYUp` freezes the tested protected-dispatch
parent's **165 payload files / 110 board-core defines**. Its only RTL delta is
`fp_shared/ven_fp_alu.sv`, byte-identical to the preferred leaf above. Every
build uses assertions, six hard structural-warning classes, and the bounded
32-compiler profile. Full-core harnesses have private basenames and verified
model-local generated-header dependencies:

- Board-core model: `9d9d798f35267288e42923ab1778a3639a08ad844e51e6a984c802516586f58b`.
- Full-address user-test model, only `VEN_KV260_SOC` removed:
  `3e885dce77914185c4da75f82b964b44e3f48dd5e937375a92abeee2d7a5e3b5`.

The FP suite closes with unchanged inputs in `fp-suite-r9-closed.json`:

- ALU: 1,216 independent-reference checks per seed.
- Transcendentals: 1,640 comparisons per seed, including the extreme-ratio
  FPATAN case; no case was removed.
- Top: smoke, independent pipeline throughput, dependent forwarding/interlocks,
  P54 multiply initiation interval, 10,656-command mixed streams (including
  setup), queued FXCH/stack ordering and cancellation/reset.
- Historical architectural state/routing fixture: 101 checks per seed. It
  replays separately tested deferred-engine results into old writeback, so it
  is **not** an independent arithmetic or whole-core oracle.

All use seeds 1, 17 and 20260830. The original ALU also passes the updated top
fixture's five modes on all three seeds. A forwarding-disabled **diagnostic**
control separately passes; it is not a candidate performance/standard-suite
substitute. Native failures from earlier attempts remain available.

Two stale test assumptions were repaired, not hidden by changing DUT modes:

1. `VEN_SRT_ITER` deliberately replaces the unused combinational divider with
   a zero stub. The historical FPATAN oracle called it and returned zero for
   `atan2(3f008000000000000000,40008000000000000000)`. Both original and
   candidate failed identically. `prepare-trans-oracle.py` creates a renamed
   **reference-only** package without that stub, restoring the macro before
   DUT compilation. Arithmetic expressions are unchanged. Executable guards
   require the reference quotient `3eff8000000000000000` and verify that the
   hardware package remains stubbed. The local C reference agrees. Three
   generator host contracts pass.
2. The old throughput test required dependent command admission to wait until
   after architectural writeback, rejecting the already implemented registered
   forwarding and queued FXCH. It now checks exact early-admission boundaries,
   the old state before commit, **both** ordered responses, younger arithmetic
   values, and unchanged pop/unmasked interlocks. The sequential architectural
   oracle likewise gets its own reference-only `VEN_FP_PIPE{,2}` envelope via
   `prepare-arch-oracle.py`; the DUT retains both defines. The tracked generator
   reproduces the tested reference files byte-for-byte.

`run-shared-fp-system.py` adds a separate **unfiltered** whole-core QEMU gate:
streamed FADD/INT3, pending divide/queued FXCH/INT3, and streamed FADD/integer
branch/INT3. Original/candidate × AXI latency 0/7 yield **12 full comparisons,
13,816 architectural records**, all passing. Each case witnesses 64 overlapping
FP bursts and 64 trap entries. The branch cases witness **62** next-cycle
integer-branch retirements with pending FP work. Actual V retirements are
71 (stream/branch) or 327 (FXCH); neither STEP nor pairing suppression is used.
All PCs, intermediate-U states, integer/x87/CR fields are compared through the
ordinary comparator; no terminal record or retirement-group interior is cut.
This covers INT3, **not arbitrary-arrival hardware IRQ/NMI/SMI**. Exact closure:
`full-system-ab-r3/result.json`; all source/model pins unchanged.

```sh
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
  python3 -B verif/fppipe/run-shared-fp-system.py \
  --control /absolute/dispatch-parent/tb_ventium \
  --candidate /absolute/shared-add-candidate/tb_ventium \
  --out /home/yukidama/external/tmp/new-shared-fp-system-run
```

These results do not close the generic differential/timing bands, standard
suite, full-board synthesis/route or gameplay target. None of the live cold
guest or full CoreMark runs was restarted or changed to this FP derivative.

The independent 19-fixture system matrix also closes **76/76 PASS** (both
models, AXI latency 0/7; `system-matrix/result.json`), pins unchanged. The
unmodified full-address generic gate closes **FAIL**, native make exit 2,
148.2 seconds: seven functional passes, 101 length-only mismatches and the
existing cycle-band failures. This matches the dispatch parent; it is not a
green differential gate. `generic-user-r2-closed.json` records stable inputs.
Its first service attempt lacked Verilator in PATH and failed before the
generic corpus; that failure remains separate from the completed retry.
