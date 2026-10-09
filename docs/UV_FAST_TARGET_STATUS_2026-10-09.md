# UV-fast performance target status — October 9

Acceptance remains **open**. U/V, relocated fast pipeline and fast load/store
paths stay enabled. No U-only/STEP/global-slow fallback, guest modification or
snapshot is used for the current cold full-PC runs.

| Requirement | Verified result | Remaining |
| --- | --- | --- |
| CoreMark ≥2.1 CM/MHz | Earlier full direct-memory seeds: **2.107362733 / 2.110412585**, correct CRCs | Full latest-candidate seeds running; not a DDR/cache/FPGA score |
| Quake ≥0.48 total U+V IPC | **0.38776687**, `c90d8fc0`, 1.2–1.3B clocks | Below target; later candidates not measured |
| Standard suite | Cold Win95/Quake candidates are running | Latest full seeds, clean desktop and complete timedemo |
| FPGA | Old image still deployed | Selected source, full timing/resource qualification and deployment |

The CoreMark model is `e3dbf68a7229a8f6c79e5999aba3a77520e94545205fd89f7b1c11b53c5de9f4`;
receipts are in `external/tmp/ventium-fp-prime-fill-coremark.cw0NJAWN/full-r4`.
The newer direct-memory short runs check CRC/state equality, not a full score.
Do not transfer the old full score to a new binary. The 60-minute full-seed
limit still applies; the optional 75-minute request has not been answered.

Latest full seeds run from `external/tmp/ventium-short-ifill-coremark.qQqbebWo/full-r2`
on CPUs16/17, model `c93ae26b`, invocation
`2034f3eec45a4ab6830530d668a3baf9`. Before launch, both short seeds passed
CRC, exact whole-model/mapped-RAM host-optimization equivalence and negative
controls. They save 96 clocks versus the prior RTL; the first stale
parent-clock expectation failed and is retained. Full correctness/score remains
pending; the host optimization never skips a clock edge or changes guest state.

Four cold full-PC guests remain active: code-word and combined-candidate
Quake/Win95 pairs. Superseded XPM/pop pairs closed normally, with native exit
zero, reaped children and no OOM. Those incomplete timedemos remain FAIL and
the Win95 runs CLOSED_UNQUALIFIED; no suite acceptance is inferred.

The new gameplay audit is
`external/tmp/ventium-pop-gameplay-audit.yXwJVMHF/audit.json`:
38,776,687 total retirements (28,797,950 U + 9,978,737 V) / 100M clocks.
Exact endpoints were visually checked and source/runtime/native identity pins
rechecked. This is the pop-drain/XPM model, not the later code-word, tag,
data-under-I-fill or short-x87 candidates. A completed window is not a completed
timedemo. The earlier XPM window was 0.38588696; equal cycle windows need not
cover precisely the same scene progress.

## Fixes and evidence

- [Last-response FP pop admission](../verif/fe_pipe/FP_POP_DRAIN.md): removes
  response-accounting delay without crossing an unfinished stack mutation.
  Resident load/pop microloops: **23→20 clocks**. Gameplay measured above.
- [Registered instruction-word reuse](../verif/l1/CODE_WORD_REUSE.md): avoids
  recapturing instruction bytes already in a registered, physically tagged
  staging line. Directed staged reads **36→18 clocks**; instruction-miss kernel
  **66,330→52,260 clocks**. Cold full-PC candidate running, not yet measured.
- [Tag LUTRAM](../verif/l1/TAG_LUTRAM.md): preserves reset validity/ownership,
  removes reset from invalid payload, flattens indexing. Isolated routed leaf
  **22,051→13,014 LUTs; 6,877→1,691 FFs**. This is not full-chip utilization
  or CPU timing. Local setup estimate **67.385 MHz**, hold still −0.080 ns.
- [Data hits during instruction fill](../verif/l1/DATA_UNDER_IFILL.md): uses
  independent D banks through the existing registered owner path. **640**
  directed held reads finish in two clocks; 76 system/64 boundary cases pass.
  No gameplay or FPGA timing result yet.
- [Exact short x87 byte capture](../verif/fe_pipe/FP_SHORT_WINDOW.md): retains
  ordinary decoder/exception/execution decisions and removes unused suffix
  fetches. 288 full QEMU comparisons, 492 predicate checks, fault/debug and
  CPU-store SMC tests pass. Selected loops lose 5–6 clocks per iteration;
  these are not gameplay gains. Combined model `05611d6c` has fresh cold
  Quake/Win95 qualification runs, not yet measured or accepted.

## Gates that must not be hidden

Canonical UV-fast/AXI `make verify` is still failing: historical runs show
101 user terminal-record mismatches and four hard cycle-band failures. The
separate pre-exit observer is diagnostic and still has two x87 discrepancies;
neither it nor passing directed tests replaces a green differential gate.
No trace trimming, new exception masks, widened cycle bands or oracle-state
fabrication is accepted. These fixes are not declared complete.

Next: finish candidate gameplay measurement; qualify the combined candidate
with architectural fault/SMC tests, resolve the generic gate, then complete
the full standard suite and FPGA deployment. Keep each measured binary,
source closure, settings and native receipts separate.
