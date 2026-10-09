# Shared FP arithmetic front: same-cycle FPGA-area proposal

Status: **leaf-qualified proposal, not applied to production RTL**. No Quake
IPC, whole-core timing or standard-suite improvement is assigned to it.
Current verified gameplay is **0.37393282 total U+V retirement-event IPC**,
posted16 model `3c8779f4`, cycles 1.2–2.3B; it predates this proposal.

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
