# Primed U / registered V ownership repair — October 9

Private candidate, **not full-suite or FPGA acceptance**. Current verified
gameplay is **0.38065044 total U+V IPC**, dispatch-only model
`ba2463bf`, cycles **1.2–1.3B**. This predates the ownership repair, which has
no gameplay measurement. Original posted16 `3c8779f4` measured 0.37026314
over 1.2–3.0B; different windows/builds are not a speedup comparison.

## Actual full-PC failure

Combined raw-prime/shared-FP/dispatch model
`cf07083d99f4f28bd2db17ea01f18ec9f6f81ad75e353485b101ab9df585a63c`
closed **FAIL** in both cold guests:

- Win95: `fresh V hit lacks an admitted registered U owner`, at logged native
  timestamp **302611000**; invocation `98d0434d98734339981c3f63ea22231e`.
- Quake: the same assertion at native timestamp **415795000**; invocation
  `da9ed12a57434234b718bc7f6f8afe03`.

Artifacts: `ventium-raw-v-prime-soc-r2.AtMi5nga/{win95-cold-raw-prime-oct09.1,
quake-cold-raw-prime-oct09.1}` under `/home/yukidama/external/tmp`.
These are native failures, not OOM, host-stop, desktop or timedemo passes.
No assertion was removed. Neither guest reached accepted gameplay on this
model. Earlier directed passes did not cover this interaction.

## Cause and repair

The prior register U can prime its following load without creating a core
memory owner. That load's next admission edge already has a registered cache
ACK. A newly decoded V load in another line was nevertheless allowed through
the leaf's legacy-response-overlap path. U retires immediately and does not
create `pipe_mem_active_q`; V's delayed response has no older core owner to
retain it. The assertion correctly catches this contract violation.

`prepare-prime-pair-owner.py` changes only `rtl/mem/ven_l1d.sv` in a private
copy. Under the core dual-load profile, a lane-1-only V cannot enqueue via
legacy response overlap. Fresh U/V capture remains enabled when U genuinely
waits for a registered read; same-line `pair_now` still retires both loads
immediately. Otherwise V executes as the following ordinary U instruction.
Generic two-lane leaf requests retain their overlap capability. No new
registers, cache ports, decoder, timing exception or global pairing disable.

## Closed directed evidence

Root: `/home/yukidama/external/tmp/ventium-prime-pair-owner.Nyc96NPJ`.
Core model: `53a55449dd37038ff57eb3aa9a2c124145a367957322ab51a8f8a6383360596f`.
Full-address user model:
`be7073855356bd7c8f41a3aaa2d8bd957222a0cf08b3ddc282c9120d5a0c7c82`.
Both builds close native zero, stable pins, verified model-local host header,
assertions and six hard structural checks; UV + system fast path unchanged.

- `red/result.json`: **8 expected assertion reproductions**, plus 24 passing
  control/immediate-pair runs. Marked red reproduction, **not a correctness
  pass**. Cold paged fixtures, both layouts/modes, AXI latency 0/7.
- `green/result.json`: **32/32 runs pass**, including 16 complete unfiltered
  QEMU architectural comparisons. Same-line load pairing and independent
  ordinary U/V retirement are explicitly witnessed.
- `micro/result.json`: previous **48 measurements / 96 full QEMU comparisons
  pass**; priming benefits and negative controls are retained.
- `system-matrix/result.json`: **76/76 pass**, 19 fixtures × two models × two
  latencies, complete architectural state/PC streams.
- `leaf/closed.json`: native zero, stable pins; original **150** cache-chain
  acceptances plus three ownership checks pass: rejecting an orphaned V,
  preserving immediate same-line pairing, and preserving ordinary fresh
  registered U/V capture and response drain.
- `test_prime_pair_owner.py`: four host generator-guard tests pass.

The unchanged generic gate closes **FAIL**, native exit 2, stable pins,
156.8 seconds: seven functional passes / 101 length-only failures and existing
cycle-band failures. No earlier architectural divergence is reported, but the
gate is not green. No records, comparison scope or timing bands were changed.

## Repaired full-PC qualification

`ventium-prime-pair-soc.4XekFM7G` closes its native build with unchanged pins
and model `4b5fb92fc540c4351a3558dd99ffee82d297c5b55220cda9e53ec5a144eb3ebd`.
The sole RTL delta from failed `cf07083d` is the leaf ownership repair. The
same 98 pre-existing third-party structural warnings remain; this is not a
hard whole-platform lint pass. All shared core/FP payloads match the tested
micro model; the parent's qualified SoC shim and transport are unchanged.

Fresh cold runs are active with no saved state or guest patch:

- Win95: `ventium-prime-pair-win95-oct09.service`, CPU28, invocation
  `7ed95e87152f471bab79d4a690e6c8fa`.
- Quake: `ventium-prime-pair-quake-oct09.service`, CPU27, invocation
  `67c8d5fa54e14074bb04f41baafb982b`.

Both preserve UV-fast, original media, 16 MiB guest RAM, 40/40/80 MHz clocks,
posted16 DDR3, one CPU / 2 GiB RAM / no swap, and strict native closure.
Actual child executable hashes and affinities are recorded in each
`native-admission.json`. No runtime acceptance is claimed at launch.
Sixteen unopened, unpinned GCC precompiled headers from closed builds were
removed to restore the 8 GiB launch reserve: 1,453,710,202 bytes, rebuildable
from retained generated makefiles. No models, sources, media or logs removed.

Standard CoreMark, Win95 desktop, complete Quake timedemo, measured ≥0.48
gameplay, generic gate and whole-board synthesis/route/deployment remain
required. Microtests do not qualify the failed guest runs as acceptance.
