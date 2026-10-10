# Register FST/FSTP repair — October 10

**Verified private repair, not production promotion or suite acceptance.**
Gameplay baseline remains **0.49929384 total U+V IPC**, `86731249`, cycles
3.2B–3.3B; the 21 consecutive windows from 1.2B–3.3B average **0.47844824**,
including the real 2.3B–2.4B dip at **0.26103520**. This FST candidate has no
gameplay result. Full direct-memory CoreMark remains **2.107843209 /
2.110905243 CM/MHz** on separate model `b5453f16`, not FPGA/cache/DDR scores.

## Two defects and the compact repair

1. `FX_FST_STI` incorrectly describes ST(i) as an input. With valid ST0,
   an empty destination is legal, but the old shared and legacy descriptions
   raise stack underflow and can replace the copied value with indefinite.
   The repair keeps ST0 as a source and removes only the false ST(i) read.
2. Exact register copies/pops retain stale C1. Clear C1 on shared FST/FSTP,
   legacy slow FST/FSTP and legacy fast `FK_FSTP0`. The existing final
   stack-fault override retains precedence, including masked indefinite/pop
   behavior and unmasked suppression of all destination/stack writes.

[`prepare_fst_register.py`](prepare_fst_register.py) applies those exact
two-file edits to an explicitly prepared source copy, refusing missing or
ambiguous anchors. It does not add queues, stages, datapaths, stalls or global
fallback. FST remains excluded from arithmetic-stream admission, so removing
the false source cannot admit it ahead of an outstanding arithmetic owner.
The legacy edits are prepared but **not independently RTL-qualified** yet.
Production source, live cold guests and frozen FPGA inputs are unchanged.

This implements the register-copy/underflow C1 semantics in Intel's
[FST/FSTP instruction description](https://www.intel.com/content/dam/www/public/us/en/documents/manuals/64-ia-32-architectures-software-developer-vol-2a-manual.pdf).
No throughput gain is claimed from this correctness repair; hardware timing
and area of the added status selection have not been measured.

## Closed micro-tests

[`run_fst_register_observe.py`](run_fst_register_observe.py) uses ordinary
FLD/FREE/FNSTENV/FLDENV instructions to construct state and seed C1, then
executes the actual DD register opcode and saves its result with FNSAVE.
It checks all eight destinations, pop/no-pop, source/destination emptiness,
masked/unmasked invalid operation, both prior C1 values and, with
`--all-tops`, all eight physical stack rotations. ST0-alias cases require
consistent source/destination emptiness. Values, tags, TOP and defined status
are checked. Empty-register numeric contents and architecturally undefined
C0/C2/C3 are not invented as expected values; their tags and stack motion
remain checked. Canonical comparison masks are untouched.

| Test | Cases | Native mismatches | Parent RTL | Repaired RTL |
| --- | ---: | ---: | ---: | ---: |
| TOP0 | 240 | 0 | 88 | 0 |
| All TOP rotations | 1,920 | 0 | 704 | 0 |

TOP0 failures split into 56 legal-empty-destination and 32 stale-C1 cases.
The full matrix retains all masked/unmasked source faults and wraparound.
Pinned QEMU is a third observer: its 208/1,664 mismatches are retained,
not adopted as a replacement oracle or filtered from the canonical gate.
Native x87 is **not claimed to be original P54 silicon**.

Both RTL runs use unstepped UV-fast execution, explicit `--l1-axi`,
`AXI_RLAT=7`, `AXI_WLAT=7`, real backing acknowledgements and 66 V retirements.
The only captured initial state is the unexecuted ELF entry (zero guest
instructions), not a gameplay save-state or repair injected by a debugger.
Ten host-side tests additionally check matrix coverage, exact expectations,
defined-bit/value/tag corruption sensitivity and fail-closed recipe anchors.

Evidence under `/home/yukidama/external/tmp/`:

- `ventium-fst-register.PuzUEngQ/{core-parent-r1,core-fixed-r2,core-parent-alltops,core-fixed-alltops}/`:
  complete fixtures, observations, invocation/pin receipts and native logs.
  `driver-top0.py` preserves the original TOP0 observer bytes.
- `ventium-fst-core-r2.BG2RRI25/`: exact C1-parent derivative, changing only
  shared top and legacy writeback. Model SHA256
  `dbd4330badd85af69910c3ff6ed331bd93e1489e7dbc870842bd98919afef3b5`.
  Native build passed in 19.82 seconds, four compilers in the bounded 10 GiB
  common build scope, six structural warning classes fatal and a verified
  local, uniquely named C++ harness object/header dependency.
- Parent model is `6f71bad6`. Its compiled shared-adder and FP forwarding
  changes remain intact. The historical production estimator pin no longer
  matches the current narrowed estimator; the derivative deliberately uses
  the parent's original frozen bytes and records that distinction. The
  initial preflight refusal remains in `ventium-fst-core.3C53tQdk`.

## Canonical gate: still FAIL

Unmodified `make verify`, with both functional/cycle AXI backends explicitly
selected at latency seven, closed in 185.46 seconds with stable pins:
`ventium-fst-verify.BYwPn7u5/`, invocation
`7a553b9de8204f858d62f467dd0876c9`.

There are 7 functional passes and 101 failures: 91 terminal-length failures
and 10 earlier C1 differences. Six hard cycle bands also fail (`mb_depadd`,
`mb_indepadd`, `mb_faddchain`, `mb_fpindep`, `mb_dmiss`, `mb_imiss`). This
latency-seven run is not a matched timing-regression comparison to earlier
direct-memory/latency-zero gates. No cycle band, trace, golden or status mask
was changed to obtain acceptance.

Three newly earlier first divergences are actual FSTP ST0 instructions:
`tx_cmp:08048064`, `tx_fprem:0804800e`, `tx_fxam:08048016`. Read-only native
observation of the **unchanged gate ELFs** confirms the source, real pop/tag
transition and repaired defined status in all three; QEMU retains C1=1 while
native and repaired RTL clear it. Evidence:
`ventium-fst-register.PuzUEngQ/canonical-fst/result.json` and its pinned
`check_canonical_fst.py`; this does not make the differential gate green.
The earlier arithmetic reconciliation remains in [ROUND_C1.md](ROUND_C1.md).

Remaining: legacy-path qualification, complete exception/owner regressions,
resolution of the real canonical-oracle/RTL discrepancies without masks,
full standard suite and measured performance/hardware acceptance.
