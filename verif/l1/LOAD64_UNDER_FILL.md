# Resident wide operands during unrelated fills

Default-off `VEN_FP_LOAD64_UNDER_FILL`, tested in a private current-source
copy. Not promoted to a full-PC run or FPGA image. Latest verified gameplay is
**0.44439995 total U+V IPC**, `f780b331`, clocks **1.2B–1.3B**; that model
predates this change. The 0.48 target remains open.

## Change

An ordinary resident D read already captures a complete 32-byte line while an
independent fill is active. However, the m64 high-half provenance and response
predicates required `L1_IDLE`, discarding this usable transport width. The
recipe replaces only those two idle restrictions with a shared resident-context
predicate. It retains current hit/response identity, complete captured-line
provenance, byte extent/strobes, bank reservations, and reset/snoop/flush guards.
Partial fill-forward responses, the backing fill's owner, bypass/MMIO, streams,
and instruction-shaped requests do not gain a wide response. D fills require
a different set; separate I-buffer fills may overlap the same D set.

No new RAM port, register, cache capacity, backing request or speculative
architectural state is introduced. Disabled behavior retains the original
idle-only qualification. FPGA synthesis/timing of this change remains open.

## Evidence

Root: `external/tmp/ventium-load64-under-fill.5ShtP8JK`.
Parent: `d6d85104401ab79926da629fe8d0a476f11f8672b66461b40ce82e37c10dc37c`.
Candidate: `988c73909ad6285c0e1c966560e65b818696dc6b7ef3e1db4ce401200e67d618`.
Only `rtl/mem/ven_l1d.sv` differs in the frozen source copy; the build adds the
single feature flag. Native build exit0, private generated-header ownership,
stable input pins and six structural hard-error classes are checked.

- Two exact-change/drift/double-application recipe tests pass.
- `leaf-r1`: parent, disabled and enabled at reset seeds1/7/101, nine native
  runs. Each retains 150 memory-chain, 51 code-word, 659 D/I overlap and
  661 read-prime checks, then performs **621 new checks**. These include all
  eight held backing beats, every contained eight-byte offset, both allowed
  D/I fill/set relationships, narrow/cross-line exclusions, and reset/flush/
  snoop cancellation on capture and response edges. Enabled returns600 complete
  wide operands; controls return zero. Backing transaction ownership is unchanged.
- `negative-old`: the actual old cache with the new expectation fails all
  three seeds at the specific missing-high-half assertion, not compilation.
- `matrix-r2`: **36 complete programs × three AXI latency settings × two
  models =216 native core runs**, all passing. Covers every contained m64
  offset0–24, every insufficient-line tail25–31, m32 controls and an I-refill
  control. All architectural records, including terminal INT, match the
  separately qualified real-state preexit observer; its entire original prefix
  matches pinned QEMU exactly. Parent/candidate complete records also match.
  There are no dropped terminal records, additional field masks or direct
  writes to DUT state.
- The actual FPU-consumption counter, filtered to the source instruction,
  observes16 wide responses versus0 for every eligible D-fill case. At AXI0,
  the aligned test saves **32 clocks for16 operands**. Higher AXI latency still
  permits the wide responses, but the longer refill hides the total-cycle
  improvement. Negative controls retain exact clocks and response counts.
  These are microbenchmark results, **not gameplay IPC or a percentage gain**.
- Both short CoreMark seeds/all five CRCs pass on direct and AXI backends.
  Direct clocks4,821,818/4,815,105 and AXI5,241,661/5,235,140 are identical to
  the parent. Native exit0, reaped children, unchanged pins and zero OOM;
  supervisor `4035bc86e65044558d817ccdc89caa8f` closed successfully. These
  ten-iteration diagnostics do not qualify a CoreMark score.
- `source-faults-r1`: parent/candidate FADD, FLD and FILD sources straddling
  an unmapped page, with an older pending FDIV, pass full QEMU-system
  comparisons in functional and UV-fast modes. All six cases retain the
  complete 1,457/1,460-record fault-and-retry traces; no terminal trimming.
- `fill-edges-r2`: disabled/enabled × three reset seeds, **504 additional
  checks per run**, pass read-ahead captures and every coincident backing beat.
  The enabled case returns462 complete wide responses and explicitly checks
  42 critical-word exclusions. Each low-half owner/value and backing count
  remains correct. Candidate RTL is unchanged from the original prototype.
- Unmodified `make verify` remains **FAIL**:101 terminal-length mismatches
  and four existing hard cycle bands. Fresh same-input parent replay matches
  all108 complete architectural traces. This is not a generic-gate pass.

Failed attempts are retained. The first instruction-fill pilot never overlapped
the load with the fill and therefore proved no speedup. The D-fill fixture
establishes the required overlap. The first oracle pilot used unequal guest
environments and correctly rejected different initial ESP values; equal
environments fix the experiment without normalizing registers. The first full
matrix accidentally counted the warm-up operand; the corrected hardware counter
filters the actual source PC. Its32-worker attempt also reached the128-task
cgroup limit during QEMU spawning;16 workers passed, without raising the limit.
The first short CoreMark launch failed native-affinity admission before any DUT
ran; the retry explicitly binds CPUs4/5, preserving the full-seed CPUs2/3.

The first extra fill-edge test incorrectly required a wide response even on
the first critical-beat edge. Its diagnostic found the correct low and high
data, complete-line provenance and resident owner, but `early_armed=1` and
`early_match=0`: the existing global critical-word exclusion deliberately
suppresses the optional high-half valid. This is not data corruption. The
corrected test requires that exact exclusion in all42 first-beat cases; no
RTL guard was removed. Failed receipts, native diagnostics and the original
test body (`fill-edges-r1/original_load64_fill_edge_leaf.svh`) are preserved.

## Reproduction

The recipe is `prepare_load64_under_fill.transform(source_text)`; apply only
to a private source copy and preserve the exact source closure. `run.py` in the
evidence root records the leaf-runner adapter and all source hashes.

```sh
TMPDIR=/home/yukidama/external/tmp python3 -B verif/l1/test_load64_under_fill.py
# Within the bounded build scope, with untouched full-seed CPUs excluded:
python3 -B verif/l1/run_load64_under_fill.py \
  --parent PARENT_TB --candidate CANDIDATE_TB \
  --pinned PINNED_QEMU --observer QUALIFIED_PREEXIT_QEMU \
  --out FRESH_EXTERNAL_OUTPUT --jobs 16
```

Full standard-suite, gameplay and FPGA qualification remain mandatory before
promotion. This test does not replace the canonical differential gate.
