# Front-end (fetch/translate) pipeline — design spec (+VEN_FE_PIPE)

## Why

The full-SoC KV260 build is **route-bound at ~41 MHz** on the **fetch front-end**, not
the memory subsystem (confirmed by the router congestion map: the level-6 hotspot is
`u_icache` 52–79 % + `u_uopcache`, at X≈13 Y≈112–127). The worst path is the
**architectural `eip` self-loop**:

```
eip ─▶ iTLB translate (hit_of: 16-entry vpn compare carry-chain, tlb.sv)
    ─▶ icache present-check (ic_present / walk_lin / pf_miss)
    ─▶ µop-cache slot read (store_slots / ic_age)
    ─▶ next-eip decision (decode length  OR  TLB-miss page-walk diversion)
    ─▶ eip
```

≈ **55 logic levels, 7.8 ns logic / 16 ns route (67 %)**. The logic depth is the same
as the 65 MHz OOC core — the in-context route is what's killing it — but the path is
also *deep*, so once the die fill is relieved (the `dcache_timing` removal, in flight)
the **next wall is this combinational fetch cone**. Breaking it is the structural fix.

## What is already pipelined (don't re-do)

- **`+VEN_IC_BRAM`** — the icache line read ports are REGISTERED (synchronous BRAM);
  content-addressed line buffers make sequential crossings bubble-free, and port-2b
  prefetches the BTB-predicted-taken target.
- **`+VEN_BTB_PIPE`** — the BTB *update* is registered (off the worst path).
- **`mispred_bubbles`** — the existing branch-mispredict flush-bubble counter (the
  current model of the P5 mispredict penalty).
- A **32-byte prefetch buffer** decouples byte-fetch from the 2-wide decode.

So the LINE READ is registered; the remaining ~55-level cone is the **translate +
present-check + next-eip decision** that runs combinationally in the S_PIPE issue clock.

## The cut — page-keyed registered micro-TLB (precise)

The deep cone is `cur_lin → {itlb,dtlb} hit_of (16-entry vpn carry-chain) → xlate_miss`
(`core.sv:4319`), and `xlate_miss` gates `issue_arm`/`eip`-advance/every S_PIPE arm.
Cut it by **registering the TLB lookup**, exploiting that translation is **per-4 KiB
page**: sequential fetch (and same-page data) reuses one registered translate.

Behind `+VEN_FE_PIPE`, add a **page-keyed translate register** per TLB:

```
fe_itlb_q {page[31:12], phys[31:12], hit}     // keyed on the FETCH page
fe_dtlb_q {page[31:12], phys[31:12], hit, dirty}   // keyed on the DATA page
```

* **registering clock:** when the current access's page (`cur_lin[31:12]`) differs from
  the matching `fe_*_q.page`, the combinational `*_lk_*` are sampled into `fe_*_q` and
  this clock is a **1-cycle bubble** (`fe_xlate_stall`) — the only added latency.
* **steady state:** when the page matches, `xlate_miss`/`mem_xlate` read `fe_*_q`
  (registered, fast) instead of the live `hit_of` — so the carry-chain compare leaves
  the issue path. Separate fetch vs data registers so fetch↔load interleaving on
  different pages does NOT thrash one shared register.

`xlate_miss` rewrite (FE_PIPE): `cur_is_d ? (!fe_dtlb_q.hit || (cur_is_w &&
!fe_dtlb_q.dirty)) : !fe_itlb_q.hit`, valid only when `fe_*_q.page==cur_lin[31:12]`
(else `fe_xlate_stall` re-registers). `mem_xlate` uses `fe_*_q.phys`. The page-walk
fill (`tlb_fill_*`) ALSO invalidates `fe_*_q` (force a re-register after a walk) so a
freshly-walked page is seen.

Net effect: a **1-cycle bubble only on page crossings** (rare — most fetch is
intra-page) + the registered translate. The hot intra-page fetch loses the `hit_of`
carry-chain from its critical path. This is contained to the TLB lookup — no prefetch-PC
decoupling needed for increment 1 (the icache line read is already registered by
`+VEN_IC_BRAM`).

> NOTE — SAFETY: a TLB-pipeline bug is *silent* (wrong physical page → data
> corruption, not a crash), so this is verified arch-bit-exact against QEMU on the
> paging-heavy gates (sys pseg/ppage/pfault, Quake) before it is trusted, and it is
> gated OFF by default.

## The fork that decides everything — cycle model

The change is **not cycle-neutral** (unlike FP_PIPE2 / the BCD ÷100): the +1
mispredict/fill latency shifts the cycle count of branch-heavy code. Two paths:

**(A) Cycle-faithful — model the PF stage in the oracle.** The real P5 *has* a PF→D1
fetch pipeline, so adding it is arguably *more* faithful. Update `p5trace.so` /
p5model to charge the +1 mispredict-redirect cycle, re-tune the M4/M5 bands
(`mb_brloop`/`mb_brrandom`/`mb_nearbr` move), and re-baseline. Cost: oracle work +
a full cycle re-verify (make verify, all bands, Quake lockstep). Benefit: the
FE_PIPE build stays cycle-accurate-by-contract.

**(B) Fmax-only build.** `+VEN_FE_PIPE` is an Fmax/area demonstrator (like
`+VEN_UOPCACHE` today): functionally bit-exact vs QEMU, but the cycle bands are
**not** claimed for it (the default build stays the cycle-accurate reference). Cost:
none to the verified core. Benefit: ships the Fmax now; cycle fidelity deferred.

> **Recommendation: (B) first.** The KV260 deployment build is already
> `+VEN_UOPCACHE` (a non-cycle-faithful demonstrator), so FE_PIPE rides the same
> contract — get the Fmax on the board, defer the oracle work to (A) if/when an
> on-silicon cycle-accurate mode is wanted. This keeps the default build untouched
> and the risk contained.

## Verification (both paths)

1. **Default build byte/cycle-identical** — all FE_PIPE logic under `ifndef`/`ifdef`
   `VEN_FE_PIPE`; `make verify` 77/77 unchanged.
2. **Functional (FE_PIPE on)** — `make verify` / m3 arch-state bit-exact vs QEMU
   (the +1 fetch latency changes *timing*, never results); Quake + sys lockstep
   EQUIVALENT.
3. **(A only)** the re-tuned M4/M5 cycle bands green against the updated oracle.
4. **Fmax** — re-synth + the full-SoC impl; confirm the eip cone leaves the worst-path.

## Increment plan

1. Gate + the `pf_xlate_q` register + the PF-stage translate (compile-clean, inert).
2. Decouple the prefetch PC; wire D1 to read `pf_xlate_q`; extend `mispred_bubbles`
   +1 on redirect under FE_PIPE.
3. Functional verify (step 1–2 above); iterate to bit-exact.
4. Synth/impl to confirm the Fmax gain; then (A) if cycle-faithful is wanted.
