# Resident read during the paid AGI clock — October 9

Private, default-off prototype. **Not production, standard-suite or FPGA
qualification.** Verified gameplay remains **0.44004644 total U+V IPC** on
`15f56054`, clocks **1,200,012,763–1,300,012,763**, predating this candidate.
The full direct-memory CoreMark baseline exceeded 2.1 CM/MHz, but this newer
cache-backed candidate has only short diagnostic measurements, not a score.

## Change and ownership

`VEN_RAW_AGI_PRIME` lends the existing resident-only D-cache read port to the
current U load during its required P54 address-generation interlock. The
previous clock's register write is already committed; the ordinary U AGU
supplies the new address. The interlock still consumes its whole clock,
retires nothing and creates no memory owner or external transaction. The
following normal load owns translation, exact width, faults and retirement.

`prepare-agi-resident-prime.py` modifies only the private
`core_mem_chain.svh` arbitration and adds `core_agi_resident_prime.svh`.
There is no new SRAM port, cache, decoder, queue or arithmetic unit. Query
selection does not consume ACK, ready or frontend-valid signals. Capture
requires the existing checked live boundary, normal system eligibility,
resident DTLB permission, same-line/segment extent and no event, debug,
snoop, fragment or competing owner. Only simple byte/dword reads qualify;
stores, stack, word/extension, FP and branch forms do not. A miss or rejection
leaves the original path intact.

Assertions check that an accepted hint has no simultaneous request, register
write, retirement, translation mutation or FP command, and that the following
clock retains the same PC in S_PIPE with no active memory owner. AGI timing is
not deleted or hidden from the accounting.

## Measured result

Evidence root: `external/tmp/ventium-agi-prime.Fn1fJVfX`.
Candidate user model:
`d2a117e79037bba3c54f6e44e80861a7fb3126c680218b4de0709fe0c2e602fe`.
Matched reference-prime parent:
`12d078a7e2461c4f1c7f65b870fddc8f0caa5937b8a565b91569a70cf554ff48`.
Both retain UV, checked system/relocated fast paths, fast loads/stores,
assertions and the corrected full-address standalone store-policy harness.

Short ordinary low-RAM CoreMark, ten iterations, zero added AXI latency:

| Seed | Parent clocks | AGI-prime clocks | Fewer clocks | Throughput gain |
| --- | ---: | ---: | ---: | ---: |
| Performance | 5,375,191 | 5,264,309 | 2.06285% | 2.10630% |
| Validation | 5,369,188 | 5,257,586 | 2.07856% | 2.12269% |

Ratios **1.899584542 / 1.902013586 CM/MHz are not valid full-run scores**.
All five CRCs match for each seed. Direct-memory clocks remain exactly
4,821,818 / 4,815,105. All four native exits are zero, real V retirement is
witnessed, actual fault counts are zero, inputs are stable and children are
reaped with zero OOM. Only the expected insufficient-duration notice appears.
Receipt: `coremark-r1/closed.json`; successful service
`ventium-agi-prime-coremark-r2-oct09` is closed/inactive.

Performance-seed D-pipe waiting falls **458,247→347,115 clocks**, while paid
AGI clocks remain **165,244→165,245**. This is overlapping cache preparation
with existing required work, not deleting P54 timing. Together with preceding
reference priming, cache-backed short performance/validation throughput is
4.14991% / 4.11698% above scalar-load-command model `09aa12d9`. That is neither
a gameplay gain nor a prediction for physical DDR.

## Checks completed

- `matrix-r2`: **1,200 complete QEMU comparisons**, each also run in UV cycle
  mode. Ten instruction/control shapes, flat/relocated paging, code byte
  0/17/31, data byte 0/1/28/29/31, AXI0/7 and both models. Every run includes
  64 genuine V-pair witnesses. All whole-program and warm-window comparisons
  are nonregressing; 240 candidate rows actually accept loop-local hints.
  Four distinct operand values expose stale prior-writer addresses. Base,
  scaled-index and self-overwriting destination forms pass. Split-line dword,
  unrelated-register, store, word and extension controls do not prime.
- Representative flat byte17/aligned loops: four writer→read pairs plus loop
  control improve **15→11 clocks** for MOV32, MOV8, ADD32, XOR32 and scaled
  index; self-overwriting destination improves **18→14**. Ordinary no-AGI,
  store, word and extension controls retain 10/12/19/23 clocks respectively.
  These are directed loops, not gameplay.
- `fault-r1`: **24 complete QEMU comparisons plus cycle runs**, byte/dword/ADD
  reads after an actual address writer. Missing first and split second page,
  older FP divide, exact #PF PC/CR2, prior FP pointers/value, PTE repair and
  restart all pass. No comparator masks or expected faults are broadened.
- `events-r2`: **24 complete comparisons plus cycle runs** for byte/dword/ADD,
  ordinary, TF/RF and TS/EM visits, AXI0/7 and cache-enabled/disabled controls.
  The address writer's exact #DB frame and DR6 are checked. Integer loads
  correctly do not raise #NM for TS/EM. Eligible candidates show six hints
  per trace mode; cache-disabled controls show zero. No debugger STEP mode.
- `system-matrix`: **76/76** broader system checks, complete QEMU state and
  complete matched-parent architectural parity.
- `hardware-lint/closed.json`: enabled, disabled and board synthesis/DPI
  configurations pass all six structural hard-error classes. Not timing,
  utilization or routing sign-off.
- 28 priming recipe/driver unit tests pass, including six new fail-closed
  anchor, pin, fixture and oracle-composition tests.

The mandatory unmodified generic gate remains **FAIL**: 7/108 functional
passes, 101 existing terminal-length mismatches, and four existing hard cycle
bands (`mb_depadd`, `mb_indepadd`, `mb_dmiss`, `mb_imiss`). Fresh same-input
parent replays match **all 108 complete architectural sequences**. This is
nonregression, not permission to call the gate green.

## Reproduction and retained failed attempts

`build-started.json` contains the exact guarded command and input hashes;
`build-closed.json` checks its private generated header and native executable.
Generate a disjoint copy of the qualified reference-prime source using
`prepare-agi-resident-prime.py --source SOURCE --out NEW_SOURCE`, then add only
`+define+VEN_RAW_AGI_PRIME` to that parent's profile. Do not overwrite the
canonical model. The three new `run-agi-*.py` drivers accept `--control`,
`--candidate`, and a fresh external `--out` directory. Run them inside the
existing capped `ipc_parallel32` scope; the boundary runner uses 32 RTL workers.
The reusable CoreMark diagnostic is `verif/bench/run-coremark-backend-diagnostic.py`.

Failed attempts remain explicitly failed:

- The initial service invocation used a relative script path and exited before
  starting a model. The correctly bounded absolute-path service is separate.
- `matrix-r1` rejected 360 zero-AGI controls because its parser expected every
  bucket row. `core.sv` intentionally omits zero-valued buckets. R2 requires
  the profile section, rejects duplicate rows and handles a missing AGI row
  as zero; all full-state and nonregression checks remain. All cases reran.
- `events-r1` passes its architectural comparisons but fails the mandatory
  actual-hint witness: the inherited fixture left reset CR0.CD/NW set. R2
  explicitly tests both cached positives and cache-disabled negative controls.
  No RTL change was made to make a cache-disabled hint succeed.
- First archive preflight refused traces younger than five minutes, before
  changing any trace. The later closed R1 archive verifies each decompressed
  SHA256 before removing the raw copy, preserving all other file hashes.
  **2,340 traces / 1,100,840,960 bytes recovered**; manifests/receipt are in
  `failed-matrix-archive-r2`. Restore with `zstd -d -k -- EXACT_FILE.vtrace.zst`.
  Passing R2 traces, sources, models and live runs are untouched.

## Still required

Resolve the generic gate, complete both full CoreMark seeds and cache-backed
score, Win95 desktop acceptance, original DOS Quake timedemo and the fixed
gameplay measurement; then qualify the FPGA implementation. The earlier
combined model `652de481` cold pair continues independently and does not
contain these latest priming changes. No new cold pair or Vivado run was
launched for this experiment. Neither requested performance target is claimed
for this candidate.
