# Combined cache-backed candidate: hardware source export

This is **UNQUALIFIED**, not a routed bitstream or deployment. See
[the measured changes and outstanding targets](../docs/CACHE_BACKED_TARGETS_2026-10-10.md).
Verified gameplay baseline is parent `958f7ec4`: **0.50588294** U+V event IPC
at 3,300,048,811–3,400,048,811 clocks; all 22 consecutive windows average
0.4817253664. Combined candidate `bfb867f7` remains gameplay-unmeasured.

The new frozen root is
`/home/yukidama/external/tmp/ventium-store-admit-fpga40.00qKufA7`.
Manifest SHA:
`3c9b67ddbcb83fb77e6c8e32cfa58ad42da1ac68d84ff78e05ce04ecf6076a92`.
It contains **187 payloads / 146 hardware defines**, exported from the actual
144-define native model
`bfb867f7844b467eeafba12fe6d5035e89d0d2cf03111911cbdd599d7fb204e6`.
The only added hardware definitions are `SYNTHESIS` and `VTM_NO_DPI`;
simulation already uses XPM RAM fidelity.

Compared with the older demand-fetch hardware export: seven changed native
RTL/header payloads plus `core_raw_branch_mov.svh`. All 167 non-wrapper
compiled source payloads match the native build byte-for-byte. The physical
system wrapper is unchanged; its equivalence to the simulation-only transport
projection is checked explicitly. Clocking remains **40 MHz core / 100 MHz
PL**, full P5 L1s, 256 KiB L2 and 16 posted transport slots. No new constraints,
RAM ports, bypasses, debug counters or source edits are introduced by export.
Historical payload evidence is labelled ancestry only, never current acceptance.

## Reproduce source checks

Use canonical paths for the freezer's input/output roots. The one known native
build-driver alias is separately pinned and rechecked; no RTL alias is admitted.
The output must be a fresh empty directory on external storage. The freezer
requires both native build-receipt hashes and pins this exact model/profile;
it refuses an arbitrary similarly named derivative. Run with `--help` for args.

```sh
TMPDIR=/home/yukidama/external/tmp python3 -B -m unittest discover \
  -s fpga -p 'test_freeze*py'

TMPDIR=/home/yukidama/external/tmp python3 -B \
  fpga/test_store_admit_board_profile.py PARENT SIM EXPORT
```

**73 host freezer tests pass.** The independent native-source/profile auditor
passes **29 real Tcl admission checks**, including each missing/substituted
extension, duplicates, ordering, forbidden profiles and the legacy parent.
The full conditional include graph closes: 117 filelist units / 46 edges.
The first preflight refused the aliased driver, and the second refused the
missing branch-read header; neither published any payload. Both were corrected
before the successful manifest was published. No incomplete output was accepted.

Strict lint of the actual frozen **hardware** CPU hierarchy also closes native
0 with stable source pins. IMPLICIT, PINMISSING, UNDRIVEN, MULTIDRIVEN, LATCH and
UNOPTFLAT are fatal. Resource guard remains active. Evidence:
`ventium-store-admit-core-lint.h0bWzn8q`, supervisor invocation
`8aeae6ccd12848c1859783b47891accc`, native elapsed 2.37 seconds.
This is not full-platform/vendor-IP lint, CDC or timing sign-off; the simulator's
98 inherited platform structural warnings remain recorded.

## Remaining hardware work

No synthesis, route or board operation is performed by these tools. The older
demand-fetch P&R timed out; its placement and hierarchy reports require analysis
before another expensive full route. Reconstructed synthesis hierarchy can
absorb neighboring combinational logic: its 54,033-LUT `u_icache` and 27,836-LUT
`u_regfile` totals alone do not prove those RTL modules have that standalone cost.

Both duration-valid cache-backed CoreMark seeds on the exact exported native
model now pass: **2.101890118 / 2.107616105 CM/MHz**, 900 iterations, all five CRCs,
native exit 0, stable pins and no OOM. Details and raw-TSC evidence are in the
linked target document. This is simulation evidence, not a board score.

The combined candidate's generic differential gate is still red; cold Win95
desktop, complete original DOS Quake demo, routed frequency and silicon
acceptance remain open. CPU lint/source admission closes none of those
requirements, and does not resolve inherited NP-prefix/EX qualification.
