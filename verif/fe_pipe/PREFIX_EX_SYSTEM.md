# Protected-client register-prefix/EX overlap experiment — October 10

**Experimental, default-off, not production or FPGA acceptance.** Latest
verified gameplay is **0.49843606 U+V retirement-event IPC**, parent
`958f7ec4`, clocks **2,400,048,811–2,500,048,811**. All thirteen consecutive
100M windows from 1,200,048,811 average **0.47898937**, including the new
0.40860952 and 0.41837727 dips: sustained 0.48 is not achieved. Audit:
`external/tmp/ventium-sfetch16-latest-r5.675qsYCh/audit.json`. This experiment has no
gameplay measurement. Neither short CoreMark CRCs nor directed tests qualify it.

`prepare-prefix-ex-system.py` extends the existing `VEN_P54_PREFIX_EX_CHAIN`
only to checked flat/relocated 32-bit clients, behind the additional
`VEN_P54_PREFIX_EX_SYSTEM`. The successor is restricted to a **register** form:
no new memory access/translation/EA can be captured. Its operands are read
after older writeback. Same executable page, returned-byte identity, complete
CS extent, event/debug/FP/fragment exclusion and ordinary EX permission are
required. Existing prefix grammar and EXT→EXT veto remain; the three-/ten-
clock execution holds and same-state countdown-generation reset are unchanged.

Intel AP-500 241799-002 §5.5 (printed p12, local reference PDF) permits prefix
decoding to overlap the last clock of a preceding multi-cycle operation.
However, the existing [experiment's caveat](../issue_uv/PREFIX_EX_CHAIN.md)
still applies: exact P54 microcode-resource qualification for these cross-kind
handoffs remains open. Do not count this as period-correct P54 acceptance.
Added control/byte-selection logic has not been physically implemented or timed.

## Evidence

Core root: `external/tmp/ventium-prefix-ex-system-core.1Nzzc4xS`, model
**`650f0f19`**, exact one-file/two-flag derivative of `1abbf89e`.
Strict structural build passes and unique host/generated-header ownership is
checked. The initial 48-fixture smoke passes. The later fixture changes the
initial multiplier destination from zero to seven to exercise nontrivial
products; both fixture versions are preserved with their respective runs.

`matrix/`: **384 cold paged fixtures**, six operation classes, flat/relocated
segments and every 32-byte instruction offset. Both native models and AXI
latencies 0/7 give **1,536 full QEMU architectural comparisons plus 1,536 cycle
runs**, all passing in 85.41 s. Actual V retirement is required. Of 768 matched
totals, **364 improve by 14 clocks, 404 equal, none regress**. Eligible warm
IMUL gaps improve **11→10**, MOVSX gaps **4→3**; consecutive EXT remains at
four and rejected double-prefix IMUL at twelve. Returned-window misses can
still prevent overlap, so not every eligible encoding is claimed to overlap.

`guards/`: **4,167 checks of the actual include**, with mocked cache/context
inputs: all 4 KiB offsets, CS limits, wrap, old/new shape exclusions, 41
event/owner/flush/return denials, debug and both FP pipe owners. This is
admission testing, **not architectural interrupt delivery**. Full CPU event,
fault-boundary and SMC qualification remain open.

SoC root: `external/tmp/ventium-prefix-ex-system-soc.VWfuIg4C`, model
**`e061070f`**. Same original cold ten-iteration disks, CRC oracle, compiler,
full caches, board-memory transport and 40/40/80 MHz timebases:

| Seed | Parent ticks | Candidate ticks | Removed | Throughput gain |
| --- | ---: | ---: | ---: | ---: |
| Performance | 4,927,211 | **4,919,533** | 7,678 | **0.15607%** |
| Validation | 4,912,277 | **4,905,555** | 6,722 | **0.13703%** |

Short ratios **2.032713268 / 2.038505327 CM/MHz** are below 2.1 and retain
the minimum-duration errors. Both five-CRC sets match; native exits 0, explicit
CPU 3 affinity, no OOM, reaped children. Independent `coremark/audit.json`
rechecks 290 pins and supervisor `94c787ec68db46f0a7d2b96ea0587a8a`.
The same 98 inherited SoC structural warnings remain unchanged.

Unchanged generic verification remains **FAIL**, native 2, **7 PASS / 101 FAIL**
functional tests plus retained hard cycle failures. No terminal record is
trimmed and no golden, mask or timing band is relaxed. `generic.log` and
supervisor `3e105103952c4a5db19f3d7ff1461dfb` preserve the failure.

## Follow-up observation and limitation

`external/tmp/ventium-prefix-ex-system-state.tHUIXnon` repeats the same guest
ticks/CRCs with exactly one million existing pre-edge VENSTATE observations,
native 0 in 103.40 s. Raw state sequences show the hot matrix IMULs still
mostly retain their S_PIPE prefix clock; the whole-run log has only 7,677
overlap events. The unconditional raw-INTR exclusion is a suspected blocker
even when IF is clear; it must be tested, not assumed to explain every loss.

The two copied independent analysis scripts **fail** here. Performance sample
endpoints shifted to 7,002,664/8,002,664, not the requested 7M/8M trace window;
the stdout prefix logger also interleaves with stderr observation lines.
Therefore this run is **not an accepted all-clock/counter reconciliation or
joined L1-owner breakdown**. Preserve the failure; do not mix unequal windows
or silently discard records. A subsequent observer must align its window with
the independently selected native counter samples and parse stream framing.

Full duration-valid CoreMark, Win95 desktop, complete original Quake timedemo,
generic-gate repair and physical implementation remain outstanding.

## IF-qualified raw-INTR correction

`prepare-prefix-ex-masked-irq.py` replaces the raw `!intr` admission test
with `!(intr && eflags[9])`. The older EXT/IMUL owners cannot change IF.
A masked raw INTR is therefore not deliverable at either boundary; an
unmasked new pin, resolved delivery, IRQ shadow, NMI and SMI remain vetoes.
No interrupt latch, delivery priority or execution countdown changes.

Core **`9b3011f4`**, `external/tmp/ventium-prefix-ex-irq-core.gnc3N0NS`:

- Same exact profile; only the IF-qualified include changes. Structural build
  and unique host/header check pass.
- `guards/`: original and correction each pass **4,171 actual-include checks**.
  A required-failure original reaches precisely
  `MASKED-INTR-BLOCKED-PREFIX-OVERLAP`, native 1. The masked-INTR test does not
  override the independently asserted delivery permit or NMI/SMI.
- Repeated 384-fixture paged matrix: **1,536 full QEMU comparisons plus 1,536
  cycle runs**, all pass in 85.28 s; 364 of 768 paired totals improve and
  404 equal. This corpus compares with pre-overlap `1abbf89e`, not the first
  overlap model. Actual interrupt delivery is still not tested by this leaf.

SoC **`252109e4`**, `external/tmp/ventium-prefix-ex-irq-soc.DqS2SSdj`:

| Seed | First overlap ticks | IF-qualified ticks | Removed | Incremental gain |
| --- | ---: | ---: | ---: | ---: |
| Performance | 4,919,533 | **4,862,426** | 57,107 | **1.17445%** |
| Validation | 4,905,555 | **4,847,492** | 58,063 | **1.19779%** |

Both five-CRC sets match. Short ratios **2.056586568 / 2.062922435 CM/MHz**
remain below 2.1 and insufficient-duration; the prefix qualification caveat
above remains. Independent `coremark/audit.json` rechecks 291 pins, actual CPU
3 affinity, native 0/reaped children, no OOM and successful supervisor
`08ba3b43bcd5456eaa8339bc8d6781c6`. The SoC retains the same 98 inherited
structural warnings. The correction needs its own remaining event/fault/SMC,
full-suite and FPGA qualification; it is not promoted to production.

The correction's unchanged generic rerun also remains **FAIL**, native 2,
**7 PASS / 101 FAIL** plus retained cycle failures, in 212 s. Supervisor:
`79b419c766f34fe497dc652018f7e0f8`; no oracle or grading changes.
