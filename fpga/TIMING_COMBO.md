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

The checks controller is active, unit
`ventium-timing-combo-checks-oct11.service`, invocation
`4d6910c81ed04c09a4efb27c6b1940b7`. **All five matrices have now closed
successfully: 820 cold fixtures**, with complete QEMU state and full A/B
architectural/cycle comparisons. Focused FP fault checks are now running;
canonical verification and the independent combined audit are not yet closed.
After canonical closure, both models are also rerun on identical
canonical inputs to compare all 108 functional streams without hiding the
different loader stack addresses found in historical runs. Existing red QEMU
gate results remain red even if A/B regression checks pass.

The [independent combined auditor](../verif/l1/audit_timing_combo_core.py) is
queued behind that exact controller in
`ventium-timing-combo-audit-oct11.service`, invocation
`54a22c44d58d490296596c7f4d290bbd`. It will reopen all directed records, the
original canonical cycles and all same-input functional traces, while keeping
canonical-gate failure separate from A/B regression results. It does not launch
synthesis, routing, full-PC workloads or deployment.

Additional disk reserve is recovered by archiving only explicitly identified,
inactive generated compiler products from three old unit builds and five old
SoC builds (**604,397,863 +239,261,644 bytes**). Every archive is compared and
hashed before its loose members are removed; original binaries, headers,
sources, media, logs and traces remain, with extraction commands retained.
This does not yet provide the next synthesis's required disk admission margin.

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
