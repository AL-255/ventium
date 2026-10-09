# Registered-result forwarding to memory arithmetic — October 9

**Private candidate; not promoted to production or FPGA.** Verified gameplay
remains **0.38065044 total U+V IPC**, dispatch-only `ba2463bf`, cycles
**1.2–1.3B**. This predates both the ownership repair and this experiment.
The 0.48 target is not reached; microbenchmark speedups are not gameplay IPC.

## Change

`prepare-fp-memory-forward.py` changes only `fp_shared/ven_fp_top.sv` in a
private derivative of the [primed-U/V ownership repair](PRIME_PAIR_OWNER.md).
Default-off `VEN_FP_ARITH_MEM_FWD` permits M32/M64/I16/I32 arithmetic to use
the existing **registered final ALU result** as ST0. Its converted memory
operand remains command-owned and does not select the STi bypass.

The existing earlier-stage dependency checks, pop/map restrictions, stack-fault
check, all-exceptions-masked requirement, ES exclusion, multiplier initiation
interval, architectural write port and ordered response path are unchanged.
The STi assertion is qualified by `issue_reads_sti`: a memory instruction's
unused `cmd_sti=0` is not a second ST0 read. No arithmetic unit, cache port,
early memory command, saved state or workload-specific behavior is added.

## Closed evidence

Root: `/home/yukidama/external/tmp/ventium-fp-memory-forward.1wOpXMgI`.

- Core model: `87c8d05917410bea1c18ed952d32926027d7c33f18c6a7be6b1c803bdb008590`.
- Full-address user model:
  `ec8b5cb30cb70b57592bf8df8dc8b9d2be461f569eeef436567d6d90ef2e524a`.
- Both builds close native zero with stable pins, unique private C++ harness
  objects, matching generated headers, assertions and six hard structural
  checks. The only added profile flag is `VEN_FP_ARITH_MEM_FWD`.
- `leaf-r4/closed.json`: **236 new checks on each variant**, plus original
  48 control / 47 candidate register-forwarding checks. The old memory-negative
  case is retained in control and replaced by positive coverage in candidate.
  Coverage includes every memory format and fast arithmetic operation,
  register/memory producers, nonidentity stack maps, all RC/PC combinations,
  NaNs/denormals/infinities/signed integer extrema, sticky flags, exact anchors,
  metadata, unaccepted-input poisoning, earlier overlapping owners, pop,
  unmasked exceptions, ES, DIV exclusion and seven reset positions per format.
  The serial numeric helper is not an independent arithmetic oracle.
- `matrix-r2/result.json`: **88 measurements / 176 full QEMU comparisons**,
  11 cold paged programs × two segment layouts × two code alignments × two
  AXI latencies. Both cycle modes use runtime `--l1-axi` and require an actual
  V-retirement witness. No architectural records are filtered.
- `events/result.json`: another **88 measurements / 176 full QEMU
  comparisons**, with **16 real INT3 entries per fixture** following FP bursts.
  These are software interrupts, not arbitrary-arrival hardware IRQ coverage.
- `system-matrix/result.json`: **76/76** existing system comparisons pass.
- `test_fp_memory_forward.py`: four source-transformation guard tests pass.

### Actual warm-loop result (four operands plus loop control)

| Operand / operation | Parent clocks | Candidate clocks |
| --- | ---: | ---: |
| m32 ADD, SUB, SUBR, MUL | 16 | 13 |
| Split-line m32 ADD | 16 | 13 |
| m64 ADD | 20 | 20 |
| Split-line m64 ADD | 21 | 21 |
| FIADD m16 / m32 | 36 | 36 |
| FLD m32 / FADDP | 23 or 24 | unchanged |
| FILD m64 / FADDP | 24 | 24 |

The positive cases use **18.75% fewer clocks** (23.08% greater throughput).
All layouts/AXI latencies agree; event-bearing tests also have no regression.
The unchanged wide forms still have operand-service overhead. The later
combination with [resident-window priming](FP_RESIDENT_PRIME.md) is recorded
separately below; these forwarding-only measurements are unchanged.

The **generic gate remains FAIL**, native exit 2 after 157.7 seconds, stable
pins: seven functional passes / 101 length-only failures; five unchanged
cycle-band failures (depadd, indepadd, dmiss, imiss, nearbr). All 108 comparison
reports were inspected; no earlier architectural mismatch is reported. No
terminal trimming, fabricated QEMU poststate, comparator change or relaxed
band was used. This is not a green gate or standard-suite acceptance.

## Combined arithmetic-only priming

The first combination, `ventium-fp-prime-forward.kLNvZRzY`, improves aligned
m32 arithmetic 13→12 clocks but **fails** its no-regression check: aligned
FLD/FADDP grows 23→24 clocks. Its failing receipt is retained, not accepted.

`prepare-fp-resident-prime.py --arith32` restricts cache-window capture to
single-beat m32 ADD/MUL/SUB/SUBR. It does not prime FLD, FILD, wide, split or
DIV operands. It retains the earlier descriptor-only query / checked-commit
separation, translation and segment permission checks, event exclusions and
ordinary S_FLOAD ownership. This is an instruction-class restriction, not a
guest or address-specific workaround. The source must contain the forwarding
implementation; both flags are recorded in the model profile.

Root: `/home/yukidama/external/tmp/ventium-fp-arith32-prime.avzY8Zt1`.

- Core model: `0e07298e84e59c66e4b7deca94c6d55f7416eedb62f7651b0a92390e78897eec`.
- Full-address user model:
  `f4c3e0a2f7ad4ae18ad7efe19c893f0edc5b43b2e200caa1e9e6aaf6aa425005`.
- Both native builds pass with unchanged pins and private header ownership.
- `matrix/result.json`: **88 measurements / 176 complete QEMU comparisons**.
  Aligned m32 arithmetic is **13→12 clocks** versus forwarding alone; all
  negative controls retain their previous timing, including FLD/FADDP.
  Composed with forwarding, **16→12 is 25% fewer clocks / 33.33% greater
  throughput** in this directed loop, not measured gameplay improvement.
- `events-period2/result.json`: **88 measurements / 176 complete QEMU
  comparisons**, with **eight real INT3 entries per fixture**, actual priming
  witnesses for each positive shape and no measured regression. An ordinary
  backedge separates interrupt-bearing bursts. At AXI latency 7 some shapes
  have only three/four prime witnesses and no steady timing gain; this is not
  a claim that every FP instruction primes after an interrupt.
- `system-matrix/result.json`: **76/76** complete system comparisons pass.
- `generic-user-r2-closed.json`: **FAIL**, native 2, unchanged pins. All 108
  reports were inspected: seven equivalent, 101 length-only failures; the same
  five cycle bands fail. No oracle, terminal records or bands were altered.

The earlier `events`, `events-warm` and `events-operand-warm` attempts remain
**coverage failures**: each closes 56 negative/control measurements but fails
16 positive shapes for missing real prime witnesses. Architectural comparisons
that reached the checker pass; this does not make those matrices pass. Adding
integer re-entry instructions did not resolve eligibility. Its precise cause
is not established. The period-two fixture is additional coverage, not a
replacement label for those failures or arbitrary-arrival hardware IRQ proof.

## Failed harness attempts retained

`leaf` refuses a missing frozen divider pathname before compilation.
`leaf-r2` expands the inlined reference helper into a 2,104,018-line C++
coroutine; the owned build scope is intentionally terminated (native 143).
Its peak reaches the fixed 16 GiB cap; **OOM and OOM-kill counters are zero**.
Guest services are untouched. `leaf-r3` refuses a wrong transformation-anchor
count before compilation. None is counted as a pass.

The final runner uses one combinational reference cone, sampled after settling
without advancing the DUT clock. Control/candidate builds then take
23.68/23.04 seconds and both native runs pass. It preserves every test case.

The first full matrix exceeds the fixed 128-task envelope while launching
32 multi-threaded QEMU guests. Native fork/exec failures remain FAIL in
`matrix/result.json`. The corrected runner prepares goldens with eight
workers, then runs **32 RTL workers** separately; no envelope was raised or
failed result reused. The fresh `matrix-r2` and `events` close successfully.

After verifying the failed native process was gone and no files were open,
251 rebuildable generated C++/object/archive/PCH files from `leaf-r2/control/obj`
were removed (**874,530,487 bytes**). Private SV, inputs, commands, logs,
receipts, headers, dependency files and accepted models remain. The retained
`failed-leaf-prune-{plan,closed}.json` names every target; rerunning the recorded
Verilator command regenerates the removed build products.

## Remaining acceptance

No full CoreMark, Win95, Quake or FPGA run contains this new forwarding flag.
The active cold guests are the earlier ownership-repaired model `4b5fb92f`.
The pre-repair combined model `cbdf278a` has separately completed both full
CoreMark seeds at **2.10736/2.11041 CM/MHz**, direct memory only. Those scores
cannot qualify this candidate or the FPGA cache/DDR implementation.

Required before promotion: resolve the generic gate, finish the standard
suite on the selected combined implementation, measure gameplay, and complete
whole-board synthesis/route/timing/deployment. Preserve UV + system fast path.
