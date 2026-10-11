# Combined timing-path candidate — October 11, 2026

**Private diagnostic candidate; no combined Fmax or FPGA acceptance yet.**
The requirement is **at least 40 MHz post-synthesis Fmax** with UV dual issue,
system/relocated fast pipeline and fast loads/stores retained. Best closed
isolated estimate is **26.01118 MHz**, not a 40 MHz pass or routed sign-off.

## Exact composition

The [builder](../verif/l1/build_timing_combo_core.py) starts from measured
write-direction core `1bfb1bb2` and changes only these three source files:

| Source | Change | Isolated evidence |
| --- | --- | --- |
| `core_mem_chain.svh` | Prepare address fields alongside descriptor validation; keep admission/permissions unchanged | 820 cold fixtures, FP fault checks; 26.01118 MHz (+6.89% vs parent) |
| `ven_l1d.sv` | Read/compare current and next tags in parallel, then select hit bits | 10 complete-cache configurations plus compiled defects; 820 cold core fixtures |
| `fpu_srt_div.sv` | Balanced CLZ plus initialize dead quotient throughout IDLE | Native arithmetic-engine A/B and negative controls; cold FP/memory/AGI and fault checks |

The builder reconstructs the exact source transformations, checks each against
its independently built component, and verifies every other source in those
closures equals the common parent. It retains all **150 core defines**, a
fresh model-local C++ harness/header dependency, and the same build command.
Three composition tests reject source drift and accidental reapplication.
No clock exceptions, cache reduction, pipeline serialization or extra cycle
are introduced. The separate measured frequency gains are **not additive**.

Evidence root:
`/home/yukidama/external/tmp/ventium-timing-combo.gs1URKae`.
Controller `ventium-timing-combo-core-oct11.service`, invocation
`a847bb99c5614d94844b9a345b42493b`, observes the exact SRT-IDLE canonical run,
then independently audits its closed evidence before one guarded build. It
does not suppress the canonical gate's existing failures or start Vivado.

The build now closes successfully in **25.39 seconds**, with all pins stable
and the private harness/header check passing. Combined model SHA:
`bdb364eb1eae5f714b35f415fdea9974ea7c517c3b15e1e132b465fd16d84c70`.
Closed generated compiler products are losslessly archived before tests;
the executable, model headers, harness object and complete source/evidence
remain available. This build result is not functional or timing acceptance.

## Verification and next measurement

[The integration checks](../verif/l1/run_timing_combo_checks.py) preserve the
original branch, held-request, memory, FP and AGI fixtures: **820 cold cases**,
AXI delays 0/7, full QEMU architectural comparison and complete A/B cycle
streams. The five matrices allocate **32 workers total**, bounded to CPUs
8–31, with per-service memory/time caps and a 4 GiB disk-reserve stop.
Focused FP fault checks and the unchanged canonical gate follow. Test plans
or successful component checks do not count as a combined-model pass.

The checks controller has closed, unit
`ventium-timing-combo-checks-oct11.service`, invocation
`4d6910c81ed04c09a4efb27c6b1940b7`. **All five matrices have now closed
successfully: 820 cold fixtures**, with complete QEMU state and full A/B
architectural/cycle comparisons. The 16 focused FP fault cases have also
closed successfully on both models (32 measurements, unchanged inputs).
Canonical verification closes with native exit **2** in **412.41 seconds**:
the QEMU gate remains **FAIL**, while all 20 cycle streams exactly match the
parent. Both models were then rerun on identical canonical inputs: all **108
functional streams / 80,800 complete records match**, including exact replay
of the original candidate traces, in **73.36 seconds**. No loader-stack
normalization, C1 mask, terminal truncation or cycle-band change was applied.
The checks controller therefore exits 1 for the red canonical gate, while
recording its directed and same-input regression checks as passed.

The [independent combined auditor](../verif/l1/audit_timing_combo_core.py) is
closed successfully behind that exact controller in
`ventium-timing-combo-audit-oct11.service`, invocation
`54a22c44d58d490296596c7f4d290bbd`. It independently reopens **438,312
architectural and 438,312 cycle records**, witnesses **117,436 paired V
retirements**, and checks the original canonical cycles, all same-input
functional traces and focused fault evidence. Its SHA-256 is
`5d859b5355bd59c3bb99c63862a6d4794a38b24998c896f6cb7d9aa8f77de498`.
Canonical-gate failure remains separate from these A/B regression results;
this is not a standard-suite or hardware pass.

Additional disk reserve is recovered by archiving only explicitly identified,
inactive generated compiler products from three old unit builds and five old
SoC builds (**604,397,863 +239,261,644 bytes**). Every archive is compared and
hashed before its loose members are removed; original binaries, headers,
sources, media, logs and traces remain, with extraction commands retained.
That recovery alone did not provide the next synthesis's disk admission margin.

A further **838,350,773 bytes** from 23 old core builds and **2,263,075,277
bytes** from 65 explicitly selected inactive compiler directories are now
recoverably archived. The latter receipt is
`inactive-compiler-recovery/closed.json` under this candidate; every archive
has a hash, verified member list and extraction command. Binaries, headers,
harness objects and pinned evidence remain. Available external space after
this recovery is **7,872,401,408 bytes**, before the upcoming PC build; synthesis
will recheck admission rather than assume this remains available.

## Source-matched PC build and FPGA export

[The PC builder](build_timing_combo_soc.py) preserves the write-direction
parent's 154 simulation definitions and posted-16 transport, copying only the
three checked RTL deltas. It checks all 102 shared directed-model RTL sources
and creates a private model-local harness/header dependency. Its build is
completed behind the exact combined audit, in
`ventium-timing-combo-soc-oct11.service` (invocation
`3beff80ade054820bbb86dd5463aa511`), native exit 0 in **33.51 seconds**.
All source pins and the private harness/header check pass; the inherited
98 SoC structural warnings are unchanged, not waived as a full-SoC lint pass.
PC model SHA-256:
`c1161b0b665d6e3fafa03523df79a9a55f5ca0e042f197677096524c14fdd816`.

[The exporter](freeze_timing_combo_rk_candidate.py) preserves the 190-payload,
156-definition hardware profile and exact three-file change. Six contract
tests pass, including rejection of altered bytes or a same-content replacement
inode. The exporter no longer retains the entire inherited evidence content
in RAM: the preceding MC export had **2,541,230,779 bytes** of input files.
It retains their hash, size and file identity, still reopening and hashing
every input before publication. This reduces export memory use without
weakening source stability checks; it does not alter synthesized RTL.

The bounded preparation queue runs both unchanged short CoreMark seeds,
exports the source closure and performs
strict CPU-hierarchy lint. These short seeds must retain their original CRCs
and 4,767,218 / 4,753,406 cycle counts; they are not the long standard suite.
One synthesis and subsequent original-clock timing audit are queued behind
successful preparation, with the same exclusive Vivado guard, matched
logic-only mapper, 8 GiB RAM / 6 GiB swap caps, 30-minute synthesis limit,
and live host/disk reserves. Nothing in these queues authorizes routing or
deployment. Native results and actual Fmax remain pending.

The first export attempt correctly refused one newly inherited audit-script
alias before copying any payload. The exact pinned
`ventium-parallel-tags.EjloHRba/audit_closed.py` alias was inspected and added
to the existing explicit alias list; arbitrary symlinks remain forbidden.
The failed script/log/receipts remain. Preparation R2 observes the **same**
CoreMark invocation `e0f7ebd766494fe3842d86e3f2285092`, without restarting it;
it does not rebuild the model or alter any RTL/guest input.

Before the next synthesis: finish combined verification, source-match the
full-PC model/export, retain original CoreMark CRC/cycle checks, and recover
enough external-disk reserve. Use one exclusive Vivado family with original
40/100 MHz constraints. Record actual mapped area and Fmax; parallel tag reads
can replicate memory, and the new worst path may differ. Placement/routing and
physical Windows/Quake testing remain separate acceptance requirements.

Canonical verification currently remains **FAIL**; the original long standard
suite and physical acceptance are not closed by these directed checks.
Gameplay baseline: **0.51030715 total U+V IPC**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. This combined candidate is gameplay-unmeasured.
