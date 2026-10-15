# Boundary-fetch extent isolation — October 15, 2026

Private candidate from the retained **36.591166892 MHz synthesized/unplaced**
prefix-payload parent. No frequency gain, routed result, production RTL change,
standard-suite pass or FPGA acceptance is claimed. Neither rejected decoder
selection nor response-kind factoring is inherited.

## Change

The parent's 93-level worst path crosses late `d_fetch_need`, fetch size and
generic fragment crossing before cache-response selection and U/V writeback.
Boundary-fetch beats already clamp their size to the bytes remaining in the
current page. The actual bus driver's `S_FETCH` arm is unconditionally read-only.
Therefore their generic `fx_cross` predicate is always false, including idle
zero-byte beats. They need no second page-fragment calculation.

[The exact one-file recipe](prepare_fetch_fragment_extent.py) uses the existing
pre-fetch `cur_data_size` tap for that calculation and explicitly selects false
for `S_FETCH && sfetch_boundary`. All other states retain their original crossing
calculation; **non-boundary fetches are also unchanged**, without assuming a
reachable `fetch_word` range. The actual fetch size, request strobes, address,
page/CS authorization, overlength-fault probe, fragment sequencing and ACK
equations do not change. No cycle, register, queue or feature switch is added.
An unsynthesized assertion checks the new crossing predicate against the
original expression on every active core clock.

## Closed evidence

Scratch root: `/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X`.

- Three [recipe/proof tests](test_fetch_fragment_extent.py) pass. Two-state
  bit-vector inequality is UNSAT for all offsets, five-bit counts, data widths
  and request/direction controls. Removing the fetch exclusion, forcing data
  width four, or removing the original page clamp each produces SAT. This is
  an arithmetic contract, not sequential whole-core formal proof or X/Z proof.
- [Actual source-extracted RTL](run_fetch_fragment_extent.py) passes
  **8,529,920 cases in each of two demand-fetch profiles** (17,059,840 total).
  Each observes 2,976 nonzero edge fetches, 4,390,912 idle fetches and 2,224 data
  crossings. Both deliberately broken RTL variants fail in each profile.
  Native closure: 9.284 s, 201,723,904-byte peak, no OOM; exact source pins and
  CPU13–16 affinity retained. Owner `ventium-fetch-fragment-leaf-oct15-r5.service`,
  invocation `605c5cd902444705a33b0984e83213d4`.
- [Full-core build](build_fetch_fragment_core.py): 195 frozen sources, only
  `core.sv` changed, unchanged 152 definitions, UV/system/relocated fast paths,
  full caches, `--assert`, and `AXI_LINE_REPLAY=0`. The unique host object uses
  this model's generated header. Guarded 32-job build closes in **20.56 s**.
  Model SHA-256:
  `0698ce2f2e0de10ec1952704b63b40fd70fc8cbb682171d5ed83cade6e612c6c`.
- The [installed cache repair](../lib/GOLDEN_CACHE_PREEXIT.md#production-installation--october-15)
  is recorded separately as an exact qualified tooling delta. Old input
  receipts are not rewritten. Three transfer/adapter tests pass.
- Original 22-case boundary corpus: **176 RTL executions / 88 complete QEMU
  comparisons**, 21,832 candidate records, 4,968 V retirements and 44 required
  probe witnesses. All state/cycle A/B comparisons pass in **26.31 s**.
- Five cold system/fault fixtures, both models at AXI delay0/7/31: **30 native
  executions pass** in 25.52 s, with identical full state/cycles. No STEP,
  pairing disable, slow-mode workaround or snapshot was used.
- Canonical `make verify` closes **FAIL**, native make exit2, in **399.38 s**:
  **7 functional PASS / 101 FAIL**. All 20 cycle streams remain parent-identical.
  No timing band, reference binary, mask or instruction limit was changed.
- Private-oracle functional run closes **FAIL: 107/108**, not a corpus pass.
  Its `t_fastmem` golden actually contains `t_faststack`'s instructions while
  labelling itself `t_fastmem`. This is a newly observed golden-connection
  ownership defect, described below; the failed run is retained verbatim.

Leaf R1 rejects a misspelled build profile; R2 rejects a missing `.scope` suffix,
both before native tests. R3/R4 fail a required coverage counter: the initial
task-based fixture did not drive fetch controls as intended in generated code.
R5 sets controls on every sample and places the settle delay explicitly in the
stimulus loop. No DUT expression or expected result was relaxed. Coverage and
negative controls are necessary: old/new equality alone was insufficient.

## Newly exposed verification race

`fetch-fragment-func-r1` has a native, unmasked failure at record0 of
`t_fastmem`: expected EBP equals ESP, while the actual first instruction only
sets EDI. The golden's bytes start `89e5545883e810...`, exactly the adjacent
`t_faststack` ELF, not the requested `t_fastmem` ELF. It continues to its cap
384 rather than the target's 201 records. Both compiled images are retained.

The worker assigns adjacent TCP ports and retries failed golden generation on
`PORT+1`. Port41345, assigned to `t_fastmem`, was observed occupied by Steam;
port41346 belongs to the adjacent `t_faststack` job. The producer connects to
whatever answers that port without proving ownership by its launched QEMU.
The mislabeled program is confirmed; the exact first-attempt error is not
retained because the worker overwrites its retry log. Do not claim that missing
diagnostic was observed or erase/relabel the contaminated golden as a pass.

Before another qualifying run, reproduce the foreign-QEMU attachment and use
a private per-process transport with peer-PID validation. A different arbitrary
port is not a general fix. Production `gen_trace.py` is unchanged at this entry.

Key closure hashes:

| Artifact | SHA-256 |
|---|---|
| `fetch-fragment-leaf-r5/closed.json` | `c521a2ef21d288398b6b70b3015a284b5e54615b4232ff366ba2fc1fcd07c11e` |
| `fetch-fragment-core-r1/build-closed.json` | `6bea87731add27f60e16bef3cd0bffcf359b6faf9415e181512ae92b362906d4` |
| `fetch-fragment-core-r1/verify-closed.json` | `7152577e2971a2531be53ad6d0df5c2f12212b33e473c4c82e107b217ee137bc` |
| `fetch-fragment-func-r1/closed.json` | `76e246f6e723a59378c9655f88143524b721e29e7993b2520e00ffd06febb14d` |
| `fetch-fragment-fetch-r1/closed.json` | `c780491ad79cb96dc0c956999ef52363dbf271fc698bbe6eefe0f71607078d90` |

Current candidate gameplay is **unmeasured**. Latest verified gameplay remains
**0.50520554 total U+V IPC**, older model `c7b95b78`, cycles
**5,600,065,237–5,700,065,237**, predating this candidate. The physical board is
unchanged, and existing-image Doom still has no valid gameplay FPS.
