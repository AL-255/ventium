# Early bus-address default — October 15, 2026

**Directed checks and source transfer pass; canonical verification remains
red. Synthesized/unplaced estimate: 34.0495 MHz, below 40 MHz. Routed timing,
full-suite and board acceptance are not established.**

The last verified gameplay IPC is **0.50520554 total U+V**, model
`c7b95b78f47f5e709136f98230bdf33975cf8db0e925956b469649cbf6384afd`, cycles
5,600,065,237–5,700,065,237. It predates this candidate, whose gameplay IPC
and FPS are unmeasured. The live cold Quake run uses the preceding DECODE-bus
model, not this model, and is still in startup.

## Change and reason

The [preceding experiment](DECODE_BUS_PAYLOAD.md) regressed to
**33.603279680 MHz synthesized/unplaced**. Its mapped critical path still
crosses overlength-probe qualification and the final bus-address selector.
The 40 MHz constraint is not an achieved frequency.

`prepare_early_bus_payload.py` changes exactly one private frozen include:

```systemverilog
// Before: zero default, physical-state arms, then a late linear override.
bd_addr = 32'd0;
// ...
if (fe_translatable || state == S_DECODE) bd_addr = cur_lin;

// Candidate: early linear default, existing physical-state overrides only.
bd_addr = cur_lin;
// S_RMINT_RD, S_RMINT_PUSH, S_RMIRET, S_WALK, S_SMI_SAVE, S_RSM unchanged.
```

Request authorization, translation, fragment ownership, page/segment faults,
A20 order, data and strobes are unchanged. No added register, bubble, pairing
restriction, guest-specific check or save-state dependency. Strict waiting-x87
policy and all inherited FPREM repairs remain enabled. All 157 simulation /
159 hardware defines remain unchanged, including full P5 L1s and UV-fast mode.

For simulation, a complete copy of the predecessor bus driver asserts equal
controls every clock and equal pre/post-translation addresses on issued beats
or translated probes. It is excluded by `SYNTHESIS`, not additional hardware.
The local all-address proof assumes the documented active-owner invariants;
it is not advertised as a whole-core formal proof.

## Closed evidence

Root: `/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4`.
All successful rows retain stable input pins, waited native exits and receipts.

| Directory | Result | Scope |
|---|---|---|
| `early-bus-leaf-r1` | 294,912 native cases; Z3 `unsat`; four incorrect variants rejected | Actual translation/A20 equations; local assumptions only |
| `early-bus-core-r1` | Fresh 32-job build, 21.13 s | 195-source closure; 153 unchanged directed defines; private local harness object |
| `early-bus-boundary-r1` | 22 cold cases × delays 0/7; 21,832 candidate records / 4,968 V | Full QEMU and parent architectural comparisons; 44 probe witnesses; equal clocks |
| `early-bus-system-r1` | Five fixtures × delays 0/7/31; 30,141 records / 5,487 V | Bounded/relocated access, store fault/retry and invalid SS; equal parent traces/clocks |
| `early-bus-delivery-r2` | All 144 native executions pass, 75.17 s | Waiting-x87, FPREM underflow, #NM/#MF precedence and recovery; unchanged witnesses |
| `early-bus-func-r2` | 108/108 private-reference programs pass, 225.02 s | Existing comparison policy; not the canonical gate |
| `early-bus-matched-inputs-r1` | 108/108 complete architectural streams / 80,800 records equal, 26.28 s | Exact image and initial ESP; no normalization or added masks; 32 workers |
| `early-bus-physical-r2` | 36 native executions regraded; 158,511 candidate records / 888 V | Real INT/IRET, relocated IVT, SMM/RSM, original save-map/metadata witnesses; equal parent clocks and full traces |
| `early-bus-soc-r1` | Fresh full-PC build passes, 23.53 s | All 102 shared RTL files match directed model; 98 inherited structural warnings unchanged, not full-SoC lint |
| `early-bus-lint-r1` | Strict CPU-hierarchy lint passes, 3.88 s | Exact 159 hardware defines; all six structural error classes enforced |

The canonical `make verify` still closes **FAIL**, native make exit 2:
7 functional PASS / 101 FAIL: 90 are length-only differences; eleven also
report x87 status-field differences before the missing terminal record. The
comparator reports only the first field divergence, not every differing site.
All 20 cycle RTL streams are parent-identical; that does not make the legacy
cycle bands pass. No golden, mask or band changed.

Failed attempts are preserved, not counted as passes:

- Initial functional/delivery launches rejected incorrect CPU affinities before
  native execution. R2 uses each existing helper's required affinity.
- `early-bus-canonical-ab.json` rejects 46 comparisons with different initial
  ESP values from separately generated QEMU inputs. The new matched-input replay
  uses the candidate's exact flattened images and golden-derived ESP on the
  parent, comparing every architectural record without modification.
- Physical R1 stopped at the **parent's** five-million-cycle cap in latency-31
  SMM metadata testing, without guest completion. Only four missing native jobs
  were rerun with an eight-million-cycle / 180-second cap; all completed in
  6,040,521 cycles. R2 then independently regraded all 36 successful executions,
  including every original witness and native debug-exit 133. R1 remains failed.

`cycle_mode=1`, actual AXI service and paired V retirement are checked; no
debugger STEP or intended-V breakpoint is used. These counts are test coverage,
not gameplay IPC. The SMM tests are architectural witness tests, not fabricated
QEMU single-step comparisons.

## Identities and pending qualification

- Directed model: `c55b996c2c8309e2c152dbab2813a144e5e30db83df6acfa190425e94067b84f`.
- Full-PC model: `593833e1650b5869373abbd74debcc63d15ea53eca1aa87f62e833982ead2fe9`.
- Changed include: `1b67761e014321884d87099df3cc1c4b3d834b40acf83fb58cf6d68b02ead818`.
- FPGA manifest: `9ec9a00dc8a73884074f6ea5e01ba9925f3725bc90425693b974d38fc061e5e7`.

The export audits all 170 shared HDL inputs / 190 payloads, with just the one
changed include. The real Tcl source-contract test passes. The export remains
**UNQUALIFIED**; no bitstream has been programmed.

Two unchanged ten-iteration cold CoreMark controls closed successfully under
`ventium-branch-address-cm10-early-bus-oct15-r1.service`, invocation
`d4cc82539d604fea9270fe7cdbf1ca93`, on CPU12 with a 2 GiB / no-swap cap.
The independent audit passes, rechecking **13,909 source pins**, original media,
all five CRCs per seed, exact parent clocks, actual affinity and native closure.
Performance: **4,767,218 ticks / 1,055,307 V retirements**, 220.31 s.
Validation: **4,753,406 ticks / 1,054,254 V retirements**, 209.21 s.
Both are **0% cycle gain**, as expected; no OOM, both native exits zero, owner
exited / MainPID zero. These cannot establish a duration-valid score or
standard-suite pass; the guest's duration-error message is retained.

`fpga/prepare_early_bus_synthesis.py` prepares one matched diagnostic synthesis
and read-only clock audit; it launches neither. Exclusive ownership, native
wait/reaping, RAM/swap limits, host reserve and live disk floor are unchanged
from the closed predecessor. Host tests reject relaxed stops, fake success
and additional unreviewed RTL. No compiler/Vivado overlap is permitted.

The one synthesis started **19:33:54 UTC**, under
`ventium-early-bus-synth-oct15-r1.service`, invocation
`c9ed942f5ed347e1b7ebe52bfa6ecf9e`; owned Vivado scope invocation
`937415819ef841ab89274974aba0e4ec`. Admission observed 7,731,216,384 bytes free
external storage and 15,862,124,544 bytes available host RAM. Native scope caps
remain 8 GiB resident / 6 GiB swap, with a 13 GiB combined stop, 4 GiB disk
floor and 2 GiB host reserve. It is a matched `logic_only` diagnostic synthesis,
with unchanged 40 MHz core / 100 MHz PL constraints, not timing acceptance.

`ventium-early-bus-timing-chain-oct15-r1.service`, invocation
`5d95f371f0744f728fbcd877fbe38f41`, observes only that exact synthesis owner.
After successful waited closure and independent synthesis audit, it may launch
the prepared read-only clock audit. It cannot start another synthesis, route,
or deploy. Six host tests check this sequence and its inherited owner/wait
logic, including changed invocation, failure, exit races and deadline handling.
Both stages have now closed successfully, and their owners are exited with
MainPID zero. Synthesis finished at **20:09:28 UTC** (2,133.78 s); its independent
audit rechecked 14,302 pins and 148 native HDL read inputs. Peak resident memory
was 8,306,110,464 bytes, peak swap 1,538,007,040 bytes, with no OOM or resource stop.

The clock audit finished at **20:17:21 UTC**, 465.32 s, under
`ventium-early-bus-clock-oct15-r1.service`, invocation
`338bee7f4f4449aba2345dfa484e38ae` (scope
`d4657c8a9a1a4a0492b7c649be868466`). Its separate audit rechecked 14,306 pins,
unchanged clock constraints and waited native exit zero; peak RAM was
4,689,469,440 bytes, no swap/OOM. The sequence's closed receipt also passes.

| Synthesized/unplaced metric | Preceding DECODE payload | Early bus payload |
|---|---:|---:|
| Core frequency estimate | 33.603279680 MHz | **34.049507985 MHz** |
| Core setup slack at 40 MHz | -4.759 ns | -4.369 ns |
| LUTs | 187,508 | 187,708 |
| Flip-flops | 54,985 | 54,980 |

The estimate improves **1.32793%**, with 200 additional LUTs (+0.1067%);
277.5 BRAMs and 47 DSPs remain. This is not a routed or physical frequency.
Core hold slack is -0.101 ns. One inherited PS constraint warning remains;
the independent audit verifies the actual core/PL clocks. No black boxes or
new structural errors were found. Reports are retained in
`early-bus-synthesis-r1` and `early-bus-clock-r1`; no further Vivado is active.

The new worst path has **100 logic levels**, from `q_pc_reg[0]` to
`int_err_reg[*]/CE`: 29.072 ns data delay, including 23.270 ns estimated routing.
All 30 sampled setup paths start at `q_pc_reg[0]`; 17 end at `int_err` enables
and 13 at `int_ret_eip` enables. The traced chain crosses demand-fetch width,
fragment read strobes, route denial, store-pair readiness and memory ACK before
the interrupt enable. It no longer justifies targeting the old late address
selector. A separate private demand-width experiment removes request
authorization from the *payload calculation*, while retaining issued widths,
page clipping and all request/fault authorization. Its qualification must stand
on its own; these results do not qualify that new candidate.

While synthesis ran, four unused PCH compiler caches from the two **closed**
early-bus builds were removed, reclaiming **377,648,739 bytes (360 MiB)**.
Both build owners were exited/MainPID zero. The cleanup checked for open
handles and explicit pins in retained evidence before unlinking, and rechecked
the preserved executables and build receipts afterward. No source, generated
header/dependency, executable, trace or log was removed. The caches are
regenerable; `closed-early-pch-prune-oct15.json` records exact paths and hashes.

A further storage-only cleanup archives **1,525 architectural traces** from the
closed September 20 window-keep, fast-EXT and FP-system experiments. Their
994,542,731 logical bytes are preserved in the **23,468,460-byte** lossless
`legacy-closed-traces-oct15.tar.zst` under the evidence root above. Every archive
member was hashed against its original before removing the loose traces;
all non-trace files, binaries, source inputs and historical failed verdicts
remain unchanged. No current run was touched. The adjacent plan, verified and
closed JSON receipts give exact members, hashes and the restore command.
Archive SHA-256:
`3b0cc136b4d40e01ef06a4ffef85923868dd4baa1ae37c5a5e4c19f9979fbddf`.

Still required: canonical gates green, valid CoreMark score and full correctness
seeds, gameplay measurement, complete simulated standard suite, timing closure,
and physical Win95 cold desktop/UI plus full Quake timedemo on the exact
candidate in UV-fast mode. Diagnostic success is not a substitute.
