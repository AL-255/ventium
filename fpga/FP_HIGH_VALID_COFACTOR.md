# Wide FP response qualification — October 12

**Leaf/cache and directed whole-core checks pass; canonical verification remains
FAIL. PC transfer, frozen CPU lint and both short CoreMark preflights pass;
synthesis and its source audit pass; native timing comparison is running.
No new Fmax, standard-suite or physical FPGA acceptance.** The target
remains **at least 40 MHz post-synthesis Fmax**, UV+fast, full P5 caches.

The live synthesis also exposed an independent
[DMA generated-scope wiring defect](DMA_DECLARATION_ORDER.md). Its focused
four-state fix is now in the canonical platform overlay, **not in this frozen
timing candidate**. Carry and requalify it in the next source-matched PC/FPGA
revision before claiming final physical acceptance.

The [paired-read experiment](PAIR_NOW_READ_COMPLETION.md) regresses from
30.676729 to 29.953572 MHz. All 30 worst reported paths traverse next-read
lookup, read/code ACK qualification and wide FP validity before the FPU bank
clock enable (113 logic levels). The best parent checkpoint is retained.
This experiment continues from the paired-read candidate to cut that newly
measured dependency; it is not a claim that the isolated paired-read change
improved timing. Compare eventual timing against the best parent too.

## Change and safety boundary

The [exact-source recipe](../verif/l1/prepare_fp_high_valid_cofactor.py) changes
three files in a new private derivative, never an existing frozen export:

- `ven_l1d.sv`: qualify high-word validity with existing current-address tag
  results and primary/shadow saved-line identities. Factor common residency,
  reset, cacheability, snoop, flush, stream, early-response and extent guards
  out of the reuse terms. The complete read owner already implies the read ACK.
  Under these guards, lookahead exclusion is exactly
  `!(c_next_req && rd_match)`; idle priming requires `!c_req` and cannot apply.
- `ventium_l1_axi.sv`: remove the duplicate local ACK check from high-valid.
  Keep request/reset/access-denial/DMA-drain and whole-operand cacheability
  qualification. The L1 contract above still guarantees an acknowledged read.
- `core.sv`: use the guaranteed wide response without re-entering the ACK mux;
  retain final-fragment suppression, whole-page extent, debug, fault and owner
  checks. Factor command completion into ordinary acknowledged final beats OR
  an already-qualified wide take. Narrow and second-beat commands still require
  their original ACK. Nothing broadens their eligibility.

No feature flag, register, SRAM port, cache capacity, request, architectural
ACK, operand data or pipeline cycle is added/changed. All original response
equations remain as simulation assertions at each affected layer. Another
assertion checks the internal high-valid → acknowledged-read contract even
outside an FP consumer. No retirement masks, changed goldens or workload
special cases are introduced.

The mathematical argument is binary combinational equivalence under the
existing internal response contract, **not** arbitrary four-state equivalence
or a full-core temporal proof. Unsupported feature combinations retain their
existing elaboration failures. Sequential and ISA checks remain necessary.

## Closed checks

Evidence root: `/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.

1. [Native source-extracted test](../verif/l1/test_fp_high_valid_cofactor.py),
   `fp-high-valid-leaf-r3`: **509,600 comparisons**, 45,128 valid high responses
   (27,148 primary / 17,980 shadow), 34,905 wide takes, plus narrow/second-beat
   commands and 20,873 excluded lookaheads. Five separately compiled mutations
   fail natively: lost next-owner exclusion, residency, full-line provenance,
   extent, and missing narrow-command ACK. Runtime **12.71 s**; invocation
   `7c28a348679c404e80a63cc120300509`. Earlier r1/r2 are retained failed test
   harness preparations (spacing extraction and declarations), not RTL passes.
2. [All-bit contract proof](../verif/l1/prove_fp_high_valid_cofactor.py),
   `fp-high-valid-proof-r1`: all four changed outputs are equivalent in the
   abstract binary model; local and seam high-valid both imply read ACK.
   All six counterexample queries are UNSAT; all five mutation queries are SAT.
   Addresses/offsets are bit-vectors, and registered ownership is unconstrained.
   Invocation `9cb9f423b80a415998f141472644f4d1`. The proof is paired with actual
   extracted-source simulation; it does not model reachability or execution.
3. [Full-profile cache miter](../verif/l1/run_fp_high_valid_cache.py),
   `fp-high-valid-cache-r1`: two actual 128-set, two-way banked caches receive
   identical public traffic. **737,677 both-edge comparisons** cover outputs,
   control state, all data banks, tags, valid bits and LRU. **66,339 valid high
   words** independently match backing memory, including all legal unaligned
   offsets, shadow/primary overlap, partial captured banks, line boundaries,
   invalidation and rejected lookahead. The lost-next-owner mutation fails
   natively. No internal state is forced. Runtime **16.38 s**; invocation
   `deb59f492e704bf49c446365d6510aa8`.
4. [Whole-core build](../verif/l1/build_fp_high_valid_core.py),
   `fp-high-valid-core-r1`: native zero in **20.68 s**, unchanged input pins,
   **195 files / 152 identical definitions**, exactly the three intended RTL
   deltas. The unique C++ harness has a local object and verified matching
   generated-header dependency. All six structural lint classes remain errors.
   Model SHA-256:
   `ca23313603a8a34e4d3c76688b6d4f5c63d0339cb578ecf7b544d9be188eef8c`.
   Invocation `de2e514a391f4f35ade19aad4f4aafa3`.

## Whole-core results and retained failures

The first unchanged full FP matrix, `fp-high-valid-fp-r1`, closes **FAIL** in
31.02 seconds: 32 concurrent fixtures exceed the fixed 128-task envelope when
QEMU starts its helper threads. Native logs show `EAGAIN`/failed QEMU startup;
308 measurements complete, but this is not a matrix pass. Invocation
`de716da6b8bc409db60ac12b75d9747b`. Its failed evidence is retained.

The complete retry passes in **67.88 seconds** with **eight concurrent fixtures**,
without changing cases, comparisons, timeouts or RTL, under the same 16 GiB /
128-task guard (`ventium-fp-high-valid-fp-r2-oct12`, invocation
`4de0443618f64fefb57e4d42582c53e8`). All **384 fixtures / 1,536 measurements /
208,128 candidate architectural records** pass full QEMU comparison and exact
parent/candidate cycles, with **768 actual V retirements**. Compiler fan-out
remains 32. Every trace is independently re-compared before lossless archival
to `closed-fp-high-valid-fp-text.tar.gz` (487,072,544 → 29,385,640 bytes).

Canonical `make verify` closes **7 PASS / 101 FAIL**, native make exit 2;
invocation `e013e606f3be4d8baaa3b7b3b5d69bf4`. All 20 cycle streams match the
parent, with unchanged source pins, goldens, masks and bands. Matching the
parent does **not** waive those failures.

The [follow-on driver](../verif/l1/run_fp_high_valid_regressions.py) closes all
12 phases in **605.02 seconds**, invocation
`4bb5fe0c82a44819b8615ff107f54666`, in `fp-high-valid-regressions-r2`:

| Check | Complete coverage | Candidate records |
| --- | --- | ---: |
| FP operand boundaries | offsets 0, 1, 24, 25, 29, 4093; two instruction alignments, relocations and AXI latencies | 11,904 |
| FP faults | 16 fixtures × two models; full UV comparison, #NM/#PF priority, pending FP and relocated segments | 23,585 |
| Integer | 256 fixtures / 1,024 measurements | 169,472 |
| Paged memory | 72 fixtures / 288 measurements | 31,392 |
| Held read | 48 cases | 9,200 |
| Branch/priming | 640 fixtures / 2,560 measurements | 353,920 |
| Same-input canonical replay | 108 programs; identical initial ESP and complete state/cycles | 80,800 |

The first follow-on attempt is retained as **FAIL** in
`fp-high-valid-regressions-r1`: its outer fault-phase limit of 180 seconds
expired after 22 successful native runs at ~7.9 seconds each. The original
fixed-port gate serializes 32 runs. The retry changes only that batch limit to
420 seconds, not the 90-second individual watchdog, cases, RTL or comparison
rules; all 32 pass in **259.68 seconds**. It is not an RTL failure or a waived
test. Boundary positives require actual wide takes; line/page-crossing controls
require zero. Functional/U-only fault controls are diagnostic, not acceptance.

## PC/hardware transfer and remaining work

[PC admission](build_fp_high_valid_soc.py) rechecks every closed matrix and its
pins, all three exact transformations, **102 shared RTL sources**, **156
unchanged definitions**, and posted-16 transport. The
[hardware export](freeze_fp_high_valid_rk_candidate.py) additionally rejects
missing/extra deltas and requires all **170 common HDL inputs / 190 payloads /
158 hardware definitions**, with unchanged filelist closure and Tcl contract.
The [synthesis preparation](prepare_fp_high_valid_synthesis.py) retains the
closed single-Vivado lifecycle, mapper, memory/disk guards and 40/100 MHz clocks.
Its source audit compares against PAIR-NOW-READ; its timing audit independently
compares against the **better 30.676729 MHz MEMDIV-QUERY checkpoint**.
Four scheduling, four export-scope and four controller-derivation tests pass.

The PC build closes native zero in **23.69 seconds**, invocation
`7d2dab4b797e481ca7d7ca72babf660e`, with unchanged pins and its unique C++ harness
dependency checked against the actual generated headers. Model SHA-256:
`07b59e2059a985764fe7bc9ce99ebde0530acf96e8d6dfed1e83258db1178541`.
The inherited **98 full-SoC structural warnings** remain; this is not a clean
full-SoC lint result. The export closes with manifest SHA-256
`98c7d92a830568b0aa08417b2ad2444df5b14789e92d86e497cae05552d42887`.
The unchanged strict CPU-hierarchy lint passes in **3.78 seconds**, invocation
`4bb32c02aa074456b6d704f54f505e34`; all six structural warning classes remain
errors and the 158 hardware definitions are checked exactly.

The original two short CoreMark seed preflights close **PASS**, invocation
`7a81001e15664b778e632b692f44bc24`. Both cold boot unchanged disks through the
real posted-16 RTL bridge and match all five reference CRCs. Benchmark ticks
remain **4,767,218 / 4,753,406**; actual V retirements are
**1,055,307 / 1,054,254**. Native runtimes are **208.33 / 208.50 seconds**.
The independent audit rechecks **3,484 source/input pins**, native argv,
actual CPU affinity, complete consoles, ownership/reaping and zero OOM events.
Neither a duration-valid score nor the full standard suite is claimed.
[The timing coordinator](run_fp_high_valid_timing.py)
can adopt only the exact launched synthesis invocation; it never restarts a
failed run and records the 40 MHz threshold separately from audit success.

Closed integer, memory and branch traces were independently re-compared against
QEMU and the parent before archival: **789,258,716 → 74,543,568 bytes**, all
30,048 members hash-verified, `closed-fp-high-valid-regression-text.tar.gz`.
Compiled models, sources, pins, receipts and fault traces stay unpacked.
Restore these streams with `tar -xzf closed-fp-high-valid-regression-text.tar.gz
-C /home/yukidama/external/tmp` from the evidence root. Disposable closed-build
PCH files and historical timing/branch text are also retained in verified
archives; no DCP or model binary was removed.

The first synthesis-controller admission stops **before launching Vivado**:
free space exceeds 6 GiB but fails the additional twice-parent-growth reserve.
The retained failure is `fp-high-valid-synthesis-r1/admission-failed-r1.json`,
invocation `b21090b465ca4835ba73020673bbed8b`. The unchanged rule requires
**7,208,493,056 bytes**, based on **1,456,762,880 bytes** of measured parent
growth plus the 4 GiB live floor. It is not weakened. Separate cleanup removes
**40 obsolete compiler-cache archives / 955,356,712 bytes**, after checking
their PCH-only contents, no live users and no current pins. These old cache
archive bytes are not recoverable, but the compiler caches are regenerable;
`obsolete-pch-prune-{plan,closed}.json` records exact targets. All actual
source/model/trace/checkpoint evidence remains. New candidate PCH archives are
retained. Earlier lossless cleanup in this round recovered **2,373,542,373
bytes** and remains reversible.

The same unchanged controller is explicitly retried after that terminal
pre-launch failure and additional cleanup. It admits at **7,541,096,448 free
bytes** and launches the single native Vivado family at **15:50:21 UTC**:
controller invocation `af417b8fd0ce45cabd18a926c3a041f2`, scope invocation
`6152d90e3fcb4d86b1634897cf7dde71`, **3,872 pinned inputs**, 8 GiB resident /
6 GiB swap caps and unchanged live reserve guards. The synthesis coordinator
is `ventium-fp-high-valid-synth-oct12`; the independently queued timing audit
is `ventium-fp-high-valid-timing-queue-oct12`, invocation
`3762068731c449f7ad25d7502e2289e6`. No route or deployment is launched.

Synthesis now closes native zero in **1,940.26 seconds**, with unchanged inputs,
no OOM events and no resource stop. Peak resident memory is **8,291,155,968
bytes** and peak swap **2,199,810,048 bytes** (separate peaks, not a simultaneous
sum). The independent closure audit checks all **3,872 pins**, 158 definitions
and 148 native read-Verilog files. The inherited PS8 XDC `create_clock` unknown
pin warning remains; it is not silently waived as timing success. The queued
native timing audit checks the actual 100 MHz PL / 40 MHz core clocks and
compares the better MEMDIV-QUERY checkpoint. It is now live as
`ventium-fp-high-valid-clock-oct12`, invocation
`ff925880906346c49c3d9f34891206cb`.

While waiting, the [read-ACK absorption analysis](../verif/l1/READ_ACK_ABSORPTION.md)
passes abstract and source-extracted checks. This is an unqualified private
derivative, not a change to this frozen run or a measured timing improvement.

Then require >=40 MHz synthesized Fmax, routed closure and physical UV-fast
Windows 95 cold desktop/UI and original FreeDOS Quake full timedemo validation,
as well as the full standard suite and differential gates. A running synthesis
or completed audit alone does not prove the frequency requirement.

Gameplay baseline: **0.51030715 total U+V simulated retirement-event IPC**,
older build `2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. This candidate
has no gameplay measurement; the baseline is not physical FPGA IPC.
