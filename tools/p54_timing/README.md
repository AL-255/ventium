# P54 AP-500 Pairing & Issue-Byte Analysis Tools (`tools/p54_timing/`)

This directory provides offline instruction-stream pairing bounds and verified
issue-byte provenance checkers for P5/P54C dual-issue studies (`U/V + fast-pipe`).

> **Qualification Context (`c0e3fe43`, 2026-11-14):** Offline AP-500 matching
> bounds (`is_full_gameplay_bound: false`, `is_cycle_forecast: false`) are
> static pairing-opportunity upper bounds, never cycle projections or gameplay
> IPC measurements. Current verified physical DOS Quake gameplay IPC on
> **RK-XCZU15EG-F** release image **`c0e3fe43`** (`161` defines, `40.264133 MHz`
> STA-signed-off, `cycle_mode = 1'b1`) is **`0.515778001` total U+V**
> (`0.397847833` primary/U-only, counters include `REP`-element retirement)
> across cycles **`28,696,827,616–32,989,404,795`**.

---

## Components

1. **`pair_bound.py` (AP-500 Adjacent Pairing Bound):**
   - Consumes one JSON object per completed x86 instruction instance (`Insn`
     fields; optional `data_bank`) and computes the maximum non-overlapping
     adjacent U+V pairs using rules transcribed from Intel AP-500 (241799-001,
     §§5.5–5.6).
   - `instance` distinguishes a `REP` instruction from individual element
     iterations; `boundary_after` prevents pairing across control transfers or
     architectural events; `data_bank` counts diagnostic P54 L1D bank conflicts
     (bits `4:2`), where pairing remains legal while V stalls for bank service.
   - Rejects missing required fields; never fabricate missing operands or memory
     addresses from retire PCs alone.

2. **`validate_fast_bytes.py` (`S_PIPE` Verified Byte Provenance):**
   - Validates `<prefix>.fast_issue_bytes.tsv` emitted by
     `tools/state_delta_analyze.cpp` (when supplied an exact-build
     `fpd_layout.tsv`).
   - Each exported row corresponds to an `S_PIPE` U/V retirement backed by a
     verified physical I-cache tag, selected way, and BRAM return buffer (`owner`
     distinguishes fresh descriptors from registered memory owners whose saved PC
     matches the live PC; page-crossing spans are excluded).
   - Cross-checks `legacy_ordinal` against binary retirement records
     (`final_registered_retire` at the window edge) and independently decodes
     every byte span with Capstone under the recorded `mode16` code-size bit.

3. **`analyze_fast.py` (Contiguous-Span Pairing Classifier):**
   - Decodes verified `<prefix>.fast_issue_bytes.tsv` rows (`--legacy-retire-events N`)
     with Capstone, maps explicit/implicit GPR and flag uses onto AP-500 classes,
     and runs `pair_bound.py` strictly inside contiguous verified ordinal runs
     (ordinal gaps, PC discontinuities, and control transfers terminate a chain).
   - Uses reconstructed 32-bit integer linear EA bits `4:2` (`data_bank`,
     page-invariant under 4 KiB paging) to classify `reg/reg`, `reg/mem`,
     `mem/reg`, and `mem/mem` opportunities without claiming cache hits, access
     widths, or saved EX cycles.

4. **`merge_verified.py` (Slow-Path Candidate Byte Filter):**
   - Filters `<prefix>.slow_candidate_bytes.tsv` (`q_pc/q_len/ibuf` candidates,
     where certain FPU/microsequencer states may hold stale `q_len`) by
     requiring both a matching retire-observation PC and an exact
     single-instruction Capstone decode, emitting `<prefix>.verified_issue_bytes.tsv`
     in ordinal order with explicit rejection counts.

---

## Scratch Rules & Unit Tests

Write all intermediate `.tsv`/`.json` analysis outputs under
`/home/yukidama/external/tmp` with explicit `TMPDIR` (never in `$HOME` or repo
root). Run the full unit test suite with:

```sh
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
  python3 -B -m unittest discover -s tools/p54_timing -v
```
