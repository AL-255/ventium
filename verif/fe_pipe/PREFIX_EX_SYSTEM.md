# Protected-client register-prefix/EX overlap experiment — October 10

**Experimental, default-off, not production or FPGA acceptance.** Latest
verified gameplay remains **0.49510940 U+V retirement-event IPC**, parent
`958f7ec4`, clocks **2,000,048,811–2,100,048,811**. This experiment has no
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
