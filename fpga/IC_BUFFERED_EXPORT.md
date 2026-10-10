# Shared fetch-residency hardware export — October 10

**UNQUALIFIED** source export, not a routed/deployed bitstream. Its performance
parent is documented in [STORE_ADMIT_EXPORT.md](STORE_ADMIT_EXPORT.md); the
new sharing change and closed microtests are in the
[fetch-congestion audit](../docs/FPGA_FETCH_CONGESTION_2026-10-10.md).

Current verified gameplay remains parent `958f7ec4`: **0.49630560** U+V event
IPC at clocks 3,600,048,811–3,700,048,811; all 25 consecutive windows average
0.4848174992. Performance model `bfb867f7` and sharing model `89b68b62` remain
gameplay-unmeasured. REP events are not exact P54 macroinstructions.

## Exact inputs

Root: `/home/yukidama/external/tmp/ventium-ic-buffered-fpga40.LNOW5XUc`.
Manifest SHA:
`53444d56d06ebf3729ad134a8e530a2c5662ef4ee639708676223c5e6fb39c83`.
Native model:
`89b68b6216e1948dc3c96cf304bb1097f98145015ec257332dc0dc85978393bb`.
Native source root: `ventium-ic-buffered-soc.gsztNdDc` on external scratch.

188 payloads / 147 hardware defines; native has 145, hardware adds only
`SYNTHESIS` and `VTM_NO_DPI`. Relative to the exact performance export, only
`rtl/core/core.sv` changes, `core_ic_residency_span.svh` is added, and
`VEN_IC_RESIDENCY_SPAN` enables both sharing stages. All **168** non-wrapper
compiled source payloads match the native build; the hardware top is unchanged
and its simulation transport projection checked. Full closure: 117 filelist
units / 47 include edges. Clocks remain **40 MHz core / 100 MHz PL**, full
P5 L1 caches, 256 KiB L2, 16 posted slots, UV/system/relocated fast pipeline.

The freezer pins both native build receipts, model and actual compiler profile.
It admits only 17 enumerated historical **script** path aliases to their exact
canonical external targets, never arbitrary/RTL aliases. Every payload and
input pin is checked before publication and afterward. No old test acceptance
is inherited; historical flow evidence is explicitly ancestry only.

## Checks

```sh
TMPDIR=/home/yukidama/external/tmp python3 -B -m unittest discover \
  -s fpga -p 'test_freeze*py'
TMPDIR=/home/yukidama/external/tmp python3 -B \
  fpga/test_ic_buffered_board_profile.py PARENT SIM EXPORT
```

**79 freezer tests** and **33 independent real-Tcl profile checks** pass.
Missing/substituted/duplicate/out-of-order/forbidden flags are exercised.
Dropping the new flag alone admits the old parent profile, not this candidate.
The new source is not accidentally qualified by that legacy-profile test.

Strict hardware CPU lint: `ventium-ic-buffered-hw-lint.qdv1TlTQ/closed.json`,
native 0 in 2.30 seconds, stable pins, retained supervisor
`b7f952b5b06c48a78d63d665c04090a7`. IMPLICIT/PINMISSING/UNDRIVEN/MULTIDRIVEN/
LATCH/UNOPTFLAT are fatal. This is not clean full-platform lint, CDC or timing
sign-off; the full-PC model retains 98 inherited platform structural warnings.

New full-PC short CoreMark: native 0 for both seeds, original five CRCs, exact
parent ticks 4,767,218 / 4,753,406. These duration-invalid diagnostic runs prove
no observed cycle cost; they do not grant the parent's 900-iteration qualified
2.101890118 / 2.107616105 CM/MHz scores to the new model.

## Remaining work

Full synthesis diagnostic: `ventium-ic-buffered-full-synth.6cLKnbGf`, retained
controller `5c441fa813414299b1d46271ef45c11d`, exclusive single Vivado family,
8 GiB RAM / 6 GiB swap, 30-minute cap, external scratch and monitored reserves.
It uses the same logic-only mapper objective as the older parent, not relaxed
clock constraints. No automatic place/route or deployment is launched by it.

Generic differential verification remains **red**. This exact new source still
needs duration-valid CoreMark, Win95 desktop, complete original DOS Quake,
whole-chip area/timing and silicon acceptance. The local 66.0% lookup-cone LUT
reduction is not a whole-chip prediction or a measured gameplay improvement.
Its separate duration-valid seeds, Win95 and Quake cold boots are now running;
exact service identities and bounds are in the
[target log](../docs/CACHE_BACKED_TARGETS_2026-10-10.md).
