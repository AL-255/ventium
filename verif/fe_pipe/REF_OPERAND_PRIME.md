# Reference operand resident priming — October 9

Private, default-off candidate **`VEN_REF_OPERAND_PRIME`**. Not a production
promotion, standard-suite pass, timing sign-off or FPGA measurement.
Verified gameplay remains **0.44004644 total U+V IPC**, read-prime `15f56054`,
clocks **1,200,012,763–1,300,012,763**. That model predates this candidate.
Full direct-memory CoreMark remains **2.107861982/2.110913372 CM/MHz** on
`cb4b2f84`, also predating it; the cache/DDR-backed 2.1 target remains open.

## Change and hardware cost

The checked reference-dispatch clock previously captured the instruction but
left its operand's resident D-cache read until S_LOAD/S_FLOAD. The candidate
lends that idle clock to the **existing resident-only next-read port** and
existing secondary DTLB query. It captures no architectural result and starts
no backing transaction. There is no extra SRAM port, cache, queue, decoder,
arithmetic unit or shortened MOVSX/IMUL execution occupancy.

The same reference decoder supplies EA, segment, width and complete checked
instruction bytes. The initial whitelist is read-only integer ALU/EXT/MULDIV/
IMUL2 dispatch, and scalar FIAR32/FCOM32/FCOM64. Established fast-descriptor
priming retains priority. Query selection is independent of ACK and cache
validity; only capture consumes the checked frontend/FSM permit. Permission,
segment extent, physical line extent, debug/event and invalidate guards remain.
The L1 accepts only a cacheable resident hit using its normal available port.

The following S_LOAD/S_FLOAD still owns translation, exact read strobes, page
fragments, faults, FPU command admission and execution. A word source borrows
a four-byte resident window only when all four bytes fit the segment/line;
its architectural request remains exactly two bytes. Misses and unavailable
ports retain the ordinary path. Simulation asserts both absence of a competing
owner and next-clock arrival at the exact captured PC/EA/segment/load state.

Synthesis adds selection/qualification logic around existing resources. The
three synthesis/DPI-guard lint profiles pass all six structural hard classes;
**routed area, congestion and frequency have not been measured**.

## Measured contribution

Same ordinary low-RAM 10-iteration CoreMark images, ELF and corrected standalone
store-policy driver as the parent. Both seeds pass all five CRC checks, native
exit0, genuine V retirement, zero actual faults and zero uncached bypass starts.
No trace, workload, clock, latency or cacheability workaround is used.

| Backend / seed | Parent clocks | Candidate clocks | Fewer clocks |
| --- | ---: | ---: | ---: |
| Direct / performance | 4,821,818 | 4,821,818 | 0% |
| Direct / validation | 4,815,105 | 4,815,105 | 0% |
| AXI0 / performance | 5,482,773 | **5,375,191** | **1.9622%** |
| AXI0 / validation | 5,474,040 | **5,369,188** | **1.9154%** |

Retirements remain 3,661,024 / 3,656,168 per seed. Throughput gains are
**2.0015% / 1.9528%** on this matched diagnostic. The resulting ratios
**1.860399 / 1.862479 CM/MHz are not accepted scores**: the only CoreMark error
is its insufficient-duration notice. This standalone AXI BFM retains line
replay and is not the full-PC L2/DDR path or physical board.

The rotating-four-resident-line microbenchmark deliberately exceeds the two
registered read-reuse windows. Representative flat, code offset17, aligned
operand, AXI0 steady-round results (four operand operations plus unchanged
loop/control work):

| Operand instruction | Parent → candidate clocks | Fewer clocks |
| --- | ---: | ---: |
| MOVSX byte or word | 23 → 19 | 17.39% |
| ADDW memory source | 19 → 15 | 21.05% |
| IMUL memory source | 51 → 47 | 7.84% |
| FIADD32 | 28 → 24 | 14.29% |
| FCOM32 / FCOM64 | 15 → 11 | 26.67% |
| FST32 / fast MOV read / fast store | unchanged | 0% |

Do not add these percentages together or project them onto gameplay. The
whole CoreMark program saves only the measured 107,582 / 104,852 clocks.

## Verification and receipts

Root: `external/tmp/ventium-ref-operand-prime-r3.aYGuJVza`.
Candidate native SHA256:
`12d078a7e2461c4f1c7f65b870fddc8f0caa5937b8a565b91569a70cf554ff48`.
Matched corrected-host parent:
`09aa12d9a1c0f6c5f13a88051c2e1efff45eb52d2c90d3fd076af277572fe856`.
The only profile addition is `VEN_REF_OPERAND_PRIME`; UV, relocated/system
fast pipeline, fast load/store and normal P5 cache geometry stay enabled.

- `matrix-r1/result.json`: **1,200 complete QEMU architectural comparisons**
  plus 1,200 UV-cycle executions. Ten forms, flat/relocated clients, code
  offsets0/17/31, data offsets0/1/28/29/31, AXI latency0/7, parent/candidate.
  All whole-program and long-window nonregression checks pass; all 264
  eligible candidate rows actually prime. Excluded controls remain unchanged.
- `fault-r2/result.json`: **24 complete comparisons** plus cycle executions
  for FIAR32/FCOM32/64 missing-first/missing-second-page operands, an older FP
  divide, exact saved PC/CR2/FIP/FDP checks, page repair and genuine retry.
  Both models issue exactly nine complete source commands, never a partial one.
- `events-r2/result.json`: **12 complete comparisons** plus cycle executions
  across ordinary, TF, RF, TS and EM visits, exact #DB/#NM frames and recovery.
- `integer-fault-r4/result.json`: **24 complete comparisons** plus cycle runs
  for MOVSX byte/word and IMUL, absent operand pages and word/dword splits,
  older FP completion, saved fault frame, unchanged FIP/FDP and repaired retry.
- `system-matrix/result.json`: **76/76** broader system comparisons, full
  parent architectural parity and corresponding cycle-PC sequences.
- `hardware-lint/closed.json`: enabled, flag-disabled and board-address-profile
  synthesis/DPI guards pass IMPLICIT/PINMISSING/UNDRIVEN/MULTIDRIVEN/LATCH/
  UNOPTFLAT. This is not physical implementation qualification.
- `coremark-r1/closed.json`: four short diagnostics above, unchanged inputs,
  zero OOM and all children reaped. Scope `ventium-ref-prime-coremark-oct09`,
  invocation `b802c32eec0645529d8acf4353586401`, 2 GiB/no swap, CPUs2/3.
- `generic-closed.json`: **FAIL**, unchanged gate, native exit2: seven
  functional passes, 101 terminal-length mismatches and four hard cycle-band
  failures. `generic-parent-matched/closed.json` separately proves **all 108
  complete architectural sequences identical** on the exact ELF/ESP/backend.
  No golden fields, records, masks or cycle bands were relaxed.

Recipe: `prepare-ref-operand-prime.py` copies a pinned scalar-load-command
parent into a disjoint private tree; it changes only `core_mem_chain.svh` and
adds `core_ref_operand_prime.svh`. `run-ref-operand-prime.py` supplies the
fixed-work matrix; `run-ref-prime-fp-events.py` composes the unchanged complete
scalar or integer fault/debug comparisons. Five transformation/fixture unit
tests pass. `verif/bench/run-coremark-backend-diagnostic.py` makes the short
backend check reusable without a chain of private source adapters.

## Retained unsuccessful attempts

- Initial `ventium-ref-operand-prime.6aT3bzZn` build was rejected for a real
  query → cache-ready → snoop → frontend-valid → query combinational cycle.
  Frontend/event checks were moved to capture, not waived or disabled.
- R2 (`ventium-ref-operand-prime-r2.Cxeisc4G`) passes its 1,200-comparison
  matrix but primed only integer forms. The raw fast decoder does not mark
  these scalar x87 forms `is_fp`; R3 also recognizes their already checked
  reference-decoder handoff. No additional decoder is introduced.
- Integer fault R1 stopped during driver preparation. R2/R3 were rejected
  by **free QEMU**, before RTL comparison: the borrowed handler's FP probes
  clobbered the pointer whose preservation the new integer test asserted.
  The pinned QEMU `do_fldenv()` restores only CW/SW/tags, and its register
  FNSTSW translation does not suppress the generic FIP update. R4 reads TOP
  from the already captured FNSTENV status word and leaves the handler's FP
  pointers untouched. Exact old-pointer checks and post-retry divide-value
  checks remain; the full trace checks ST0 throughout. No RTL was changed to
  satisfy those fixture failures and no failed receipt was rewritten.

## Remaining acceptance

No full-PC executable or FPGA image contains this new candidate yet. The
existing combined-FP cold Quake/Win95 pair continues on `652de481`; its fixed
gameplay sample indices12/13 were declared before gameplay. Full current-seed
CoreMark correctness, complete Quake timedemo, clean Win95 desktop acceptance,
the unresolved mandatory generic gate and FPGA deployment remain open.
