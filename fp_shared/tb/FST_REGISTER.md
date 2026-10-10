# Register FST/FSTP repair — October 10

**Verified private repair, not production promotion or suite acceptance.**
Latest gameplay baseline is **0.50468964 total U+V event IPC**, `bfb867f7`,
cycles 1,800,065,237–1,900,065,237. Its seven consecutive windows from
1,200,065,237 average **0.4999549657**, including the real 0.47318727 dip.
This FST candidate has no gameplay result. The same separate cache-backed
performance model qualifies **2.101890118 / 2.107616105 CM/MHz**; these are
neither this FST candidate's scores nor FPGA measurements.

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
The legacy edits now have two passing 1,984-case native unit profiles below;
their matrix controller remains red on its stale negative-control count.
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

## Legacy writeback matrix queued

`prepare_fst_legacy_tb.py` generates a test shell from the **actual module
ports** and the unchanged core compilation-unit state-type prefix. It does
not substitute an implementation of the writeback equations or invent enum
encodings. `fst_legacy_body.svh` prepares 1,920 copy/pop/rotation/fault/C1 cases
plus 64 fast `FK_FSTP0` cases and an unadmitted-fast-arm negative check.
It checks actual write enables, indices, values, status and fault outputs.
These are writeback-port tests, not architectural-state-file or full-core tests;
central ES/B recomputation remains outside this unit.

Four generator tests pass. Four RTL profiles (parent/repaired, combinational/
two-stage legacy FP configuration) were queued in
`external/tmp/ventium-fst-legacy.2Z6k47XD/`. Service
`ventium-fst-legacy-oct10.service`, invocation
`7e1452b97b81477ab63332d347968441`, waits behind the same Vivado/build lock.
The bounded body allows 600 seconds total, one compiler, the normal 4 GiB
scope and all six structural warning classes fatal. The expected parent
failure is counted explicitly; it is not a passing correctness profile.
No live FPGA or guest input is changed by preparing this test.

That first attempt **failed**, not passed: parent-combinational C++ compilation
exceeded its 130-second per-profile limit; `closed.json` retains the timeout
and no completed profile results. It was ordinary compiler work, not a stuck
lock. The source/test expectations were not changed to accommodate it.

R2 ran after acquiring the single heavy-build lock at
`ventium-fst-legacy-r2.qlOa6MXC`, invocation
`2d1d395f82b247069cc0b7348b97791f`. It uses identical RTL, ports, vectors,
expected parent failures and strict structural checks. Only host test code
optimization changes to `OPT_FAST=-O0`, with 145 seconds per profile inside
the same 600-second total native bound and 4 GiB/one-compiler guard. This is
not a processor performance setting. R2 closes in 192.63 seconds: both fixed
profiles pass all 1,984 cases, while both parents report 992 mismatches rather
than the controller's expected 736. The combined controller remains FAIL.

Inspection found a testbench defect: it required `fp_we_fstat=1` even if the
correct architectural status was already present, then compared the unselected
default-zero payload. The real `fpu_top` updates status only under the write
enable. The test now compares `fp_we_fstat ? fp_fstat_wval : fstat`, retaining
all defined status bits, fault/pop/tag/data checks and every original vector.
This is not a relaxed architectural mask or an RTL change.

R3 (`ventium-fst-legacy-r3.JhDeXJu3`) repeats all four actual RTL profiles in
172.98 seconds. Both repaired profiles again pass **1,984/1,984**, native 0;
both parent controls fail with **720 actual architectural mismatches**. The
driver still expected 736, so its original FAIL receipt remains, not rewritten.
The corrected expected count is independently explained by the vectors:
448 legal-empty-destination cases + 256 stale-C1 slow copies + 16 stale-C1
fast pops. Empty-source fast cases already clear C1 through fault handling;
they must not be counted again. The 272 removed false positives were unchanged
status with no write. No parent correctness pass or complete legacy-matrix
gate pass is claimed from these results. Source pins remain stable.

The initial R3 launcher stopped before compilation because its TMPDIR spelling
used the external symlink rather than the required canonical path. Its failed
service is retained; the distinct native invocation
`0fd7de9967f84a4b8fb900910b3c551d` uses the same prepared inputs and resolved
TMPDIR. Neither launcher changes production RTL, guest media or FPGA inputs.
