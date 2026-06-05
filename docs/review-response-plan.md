# REVIEW_Jun5.md response plan — one-page index

Maps EACH finding in `REVIEW_Jun5.md` to its status (**DONE** this change set /
**SPEC'd-deferred**) and the doc or test that addresses it. "DONE" means an
artifact in the tree now closes or machine-checks the finding; "SPEC'd-deferred"
means a design spec exists and the work is tracked but intentionally not landed
(it perturbs calibrated cycle bands and needs new microbenchmarks).

This index is a doc; it touches no `rtl/` and no Makefile.

---

## Fidelity Limits (REVIEW §"Fidelity Limits")

| # | Finding | Status | Addressed by |
|---|---------|--------|--------------|
| 1 | "Full integer ISA" too broad; BCD/ASCII (`AAA/AAS/AAM/AAD/DAA/DAS`) and other opcodes HALT | **DONE** | `docs/isa-coverage.md` — machine-checkable family-by-family coverage matrix replacing the unqualified claim; derives the HALT/deferred set from the actual `d_unknown=1` decode paths in `core.sv`. README/sphinx claim re-worded to "broad IA-32/P54C subset with documented HALT gaps" (orchestrator-owned files). |
| 2 | x87 strong for covered operands, not complete P54C x87 (NaN/inf/denormal/non-default PC, transcendentals, BCD FP, env save/restore, unmasked exceptions deferred) | **DONE (boundary tests) + SPEC'd-deferred (completion)** | x87 boundary tests `verif/tests/tx_fcomnan`, `tx_fchs_fabs_special`, `tx_fxam`, `tx_const`, `tx_ctl`, `tx_deferred_halt` make the coverage boundary machine-checkable (incl. documented HALTs). Completion of the x87 surface remains deferred per `docs/m3-fpu-spec.md` §"deferred". |
| 3 | Cache/TLB deliberately approximate (D-cache timing-only, no data/MESI/writeback; TLB 16-entry direct-mapped, not P54C-shaped) | **SPEC'd-deferred** | `docs/cache-tlb-structural-spec.md` — documented P54C TLB org (split I/D, 4-way 32/64/8-entry, pseudo-LRU) + a P54C-shaped `tlb.sv` sketch + a D-cache data/MESI/writeback model sketch; cited to Dev Manual sec 2.5, Alpert/Avnon p.15, AP-500 p.3. Marked structural fidelity, multi-milestone, deferred. |
| 4 | Integrated bus is a protocol exerciser, not a faithful memory path (combinational back-side data; single non-burst cycles; burst/pipelined/locked/snoop/backoff standalone-only) | **DONE (honest scoping + SVA run) + SPEC'd-deferred (real data path)** | `rtl/bus/biu.sv` comments already scope it; the integrated-bus SVA corpus is run by the orchestrator-owned bus-SVA make command (promoted from the build-only `rtl-sva` per Recommended-Step 2). A faithful integrated data path is sequenced as a prerequisite for D-cache MESI/writeback in `docs/cache-tlb-structural-spec.md` §4 (item 5) and `docs/m5b-bus-spec.md`. |
| 5 | Some microarchitecture modeled by effect, not original structure (native `*`/`/`/`%`; slow-FSM pairable forms) | **DONE (inventory) + SPEC'd-deferred (conversions)** | Inventory: `docs/modeled-by-effect.md`. Conversions specced (not landed): see Actions table below. |

## Limit #5 Actions (REVIEW §"Actions to Address This")

| Action | Summary | Status | Doc / test |
|--------|---------|--------|-----------|
| 1 | "Modeled by effect" inventory | **DONE** | `docs/modeled-by-effect.md` |
| 2 | Prioritize by observable impact | **DONE** | `docs/modeled-by-effect.md` (priority ordering) + the per-family specs below |
| 3 | Microcode/useq layer for complex ops (MUL/IMUL/DIV/IDIV, PUSHA/POPA, CALL/RET, string) | **SPEC'd-deferred** | `docs/m5-div-spec.md` §3, `docs/m5-mul-spec.md` §3 (explicit micro-op sequencing). PUSHA/POPA/CALL/RET/string sequencing noted in `docs/modeled-by-effect.md`. |
| 4 | Iterative divider (P5 occupancy, EDX:EAX coupling, `#DE`) | **DONE (occupancy + EDX:EAX latency + `#DE`)** | DIV/IDIV charge the p5model occupancy (17/25/41 DIV, 22/30/46 IDIV) via a deferred penalty in `rtl/core/core_exec.svh`, gated by `mb_div8/16/32`+`mb_idiv32` (all PASS, abs-cyc within 10%); AND raise `#DE` (vector 0) on divide-by-zero + quotient-overflow, delivered through the IDT, gated by the system-mode `verif/sys/tests/pde` (per-record differential vs qemu-system, EQUIVALENT 78/78). Only a structural SRT datapath remains (no observable). |
| 5 | Staged multiply timing (~10cy, U-pipe, non-pairable) | **DONE (occupancy)** | MUL/IMUL (1-op K_MULDIV + 2/3-op K_IMUL2) charge p5model occ=10 via the deferred-penalty mechanism in `rtl/core/core_exec.svh`; gated by NEW bands `mb_mul`+`mb_imul2` in `verif/m5_metrics.py` (both PASS, abs-cyc +0.31%/+0.15%). Only a structural Booth/array multiplier remains (no observable). |
| 6 | Expand AP-500 fast-path coverage | **DONE (batches 1-4) + remaining forms need fast-path execution work** | Batches 1-2 (accumulator-imm32 ALU `05/0D/15/1D/25/2D/35/3D`; reg-form `81 /r` + `C7 /0` imm32; `D1` shift-by-1; near branches `E9`/`0F 8x` + `85` TEST-reg) now fast-pathed in `rtl/core/decode.sv` → they PAIR where they serialized; func byte-identical, gated by NEW `mb_accimm`+`mb_rmimm`+`mb_sh1`+`mb_nearbr` PAIR bands (pairing 50% / abs-cyc +0.35%). The byte forms (`04`/`A8`), PUSH/POP, and memory/store forms remain — they need fast-path EXECUTION (byte-width writeback / stores / ESP), not just decode; see `docs/fastpath-coverage-spec.md` §3. |
| 7 | Microbenchmarks for every structural change | **SPEC'd-deferred** | per-doc microbench tables: `mb_div*`/`mb_idiv*` (`m5-div-spec.md` §4), `mb_mul`/`mb_muldep` (`m5-mul-spec.md` §4), `mb_accimm`/`mb_pushpop`/`mb_callpair` (`fastpath-coverage-spec.md` §4) |
| 8 | Separate architectural from timing implementation | **SPEC'd-deferred** | `docs/m5-div-spec.md` §3.1, `docs/m5-mul-spec.md` §3.1 (native helper kept as primitive; timing path made explicit) |
| 9 | Document irreducible approximations ("effect-faithful"/"cycle-modeled") | **DONE** | `docs/modeled-by-effect.md` labels each entry; the per-family specs mark occupancy numbers "cycle-modeled" (p5model oracle, not silicon) |
| 10 | Gate progress incrementally | **SPEC'd-deferred (per-batch gates defined)** | each spec's RISK section requires `make verify` + the new cycle band + system gates if system-visible + lint + a progress note before the next batch |

## Overall Assessment & Recommended Next Steps (REVIEW §end)

| Item | Status | Addressed by |
|------|--------|--------------|
| Tighten public claims; coverage matrix + HALT/deferred list (Step 1) | **DONE** | `docs/isa-coverage.md`; README/sphinx re-wording (orchestrator-owned) |
| Promote integrated-bus SVA to a single build+run command (Step 2) | **DONE** | orchestrator-owned bus-SVA make command (Makefile); supersedes the build-only `rtl-sva` so it cannot be misread |
| Decide cache/TLB = structural vs timing fidelity (Step 3) | **SPEC'd-deferred** | `docs/cache-tlb-structural-spec.md` (structural path specced; current blocks labeled timing/correctness models everywhere until landed) |
| Focused tests for deferred x87 + BCD/ASCII, even if expected = documented HALT (Step 4) | **DONE** | `verif/tests/tx_deferred_halt` (+ the x87 boundary tests above) keep the coverage boundary machine-checkable; `docs/isa-coverage.md` enumerates the HALT set |

---

## Deferred-work doc set (this change's specs)

- `docs/m5-div-spec.md` — iterative DIV/IDIV (occupancy, EDX:EAX, `#DE`).
- `docs/m5-mul-spec.md` — staged MUL/IMUL timing.
- `docs/fastpath-coverage-spec.md` — AP-500 fast-path coverage gaps + batches.
- `docs/cache-tlb-structural-spec.md` — P54C TLB shape + D-cache MESI/writeback.
- `docs/review-response-plan.md` — this index.

All five are **specs only**: they change NO `rtl/` and NO Makefile. They exist so
the deferred microarchitecture-fidelity work is a tracked, incremental plan with
explicit per-batch gates, not an open-ended TODO.
