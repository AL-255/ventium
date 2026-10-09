# L1 tag RAM compaction — October 9

Private, default-off `VEN_L1D_TAG_LUTRAM`; **not production or FPGA acceptance**.
Verified gameplay is **0.38588696 total U+V IPC**, XPM model `50f37229`, cycles
**1.2B–1.3B**, predating pop-drain, instruction-word reuse and this change.
Earlier complete direct-memory CoreMark is **2.10736/2.11041 CM/MHz** on
`e3dbf68a`; neither target is qualified on a newly deployed FPGA image.

## Hardware change

The tag payload had a bulk reset and two unpacked dimensions. Removing only
the reset did not infer RAM: Vivado explicitly ignored the RAM attribute and
retained all **5,120 tag flip-flops**. The successful revision also flattens
`dc_tag[set][way]` into `dc_tag[{set,way}]`, with one unpacked address dimension.
It is the same **128 sets × two ways × 20 tag bits**, with unchanged lookup
clients, fill-write edge, validity, LRU, poison and snoop rules. Only invalid
payload bits survive reset; validity still clears on the original reset edge.
Every consuming comparison remains qualified by its corresponding valid bit.

No extra cache capacity, architectural state, cycle, asynchronous data-SRAM
acknowledgement or workload-specific policy is introduced. Distributed RAM is
replicated by synthesis as needed for the existing independent tag lookups;
this trades additional LUTRAM for much less flip-flop/multiplexer logic.

`prepare_tag_lutram.py` modifies only `rtl/mem/ven_l1d.sv` in a fresh private
source copy. Disabling the feature restores the original source byte-for-byte.
It rejects changed lookup cardinality, ambiguous anchors and repeated application.

## Measured isolated physical result

Part `xczu15eg-ffvb1156-2-i`, Vivado 2025.2, complete word-reuse macro profile,
25 ns clock, identical zero-I/O-delay OOC constraints and route settings:

| Routed metric | Word-reuse parent | Flattened tag RAM |
| --- | ---: | ---: |
| Total LUTs, including LUTRAM | 22,051 | **13,014 (−40.98%)** |
| Flip-flops | 6,877 | **1,691 (−75.41%)** |
| LUTRAMs | 2,048 | 3,200 |
| Block RAM / DSP | 0 / 0 | 0 / 0 |
| Local setup estimate | 60.29 MHz | **67.39 MHz** |
| Setup slack at 25 ns | +8.414 ns | +10.160 ns |
| Hold slack | −0.080 ns | −0.080 ns |

These are **not CPU Fmax, full-chip area savings or timing sign-off**. External
OOC port locations are absent and hold remains negative. Synthesis alone uses
13,118 LUTs/1,691 FFs versus 22,202/6,877 in the parent. Tag-name primitive
inspection finds distributed RAM and **no tag-payload FFs**. The physical script
now fails explicitly if tag FFs remain or no RAM is inferred.

Parent: `external/tmp/ventium-code-word-physical-r2.MAXhpogR`.
Candidate: `external/tmp/ventium-tag-lutram-physical-r2.jPR5G8Ds`.
Both native exits are zero; candidate source pins stay stable, scope peak is
4,527,661,056 bytes, there is no resource stop, and Vivado closes with no orphan.
The first, non-inferred experiment is retained separately in
`ventium-tag-lutram-physical.2HY8BxlJ`: 20,537 routed LUTs, 6,863 FFs,
57.54 MHz local setup estimate, and 5,120 tag FFs. It is not the selected layout.

## Correctness evidence

Root: `external/tmp/ventium-tag-lutram.8O3cir5H`, source `candidate-r2`.

- Six source/index guards pass, including the complete 256-entry index bijection.
- `leaf-r3/closed.json`: control, default-off and enabled variants each pass
  randomized initialization seeds 1/7/101. Each runs the existing 150 accepted
  memory-chain requests, 51 instruction-word checks and **1,936 tag checks**.
  All variants/seeds take exactly **16,910 tag-test clocks and 5,376 backing
  transactions**, with identical data results.
- The tag test populates both ways in all 128 sets with set-dependent nonzero
  tags, then demands all 256 resident entries without backing traffic. It
  tests warm-reset payload retention with cleared validity, backing-memory
  mutation after reset, mandatory cold refill, full flush, and matching snoop
  or flush on every accepted D-fill beat, including tag installation.
- `coherence-r1/closed.json`: all nine unchanged code-buffer regression cases
  pass: control/off/on × hit-under-fill/paired-store/combined. U/V stores,
  crossing stores, mixed load/store pairing, instruction-data ownership,
  physical snoops, fill poison and cacheability remain covered.
- Six structural Verilator warning classes remain hard errors. No assertion,
  golden value or timing expectation is removed.
- `negative-r2/closed.json`: deliberate loss of a set-address bit fails the
  resident-hit check; deliberately retaining a valid bit on reset fails the
  invalidity check. Both mutants compile and fail natively, not by timeout.
- Full-core board model `9bcf2ad6` and full-address user model `1748a1e6` build
  with unique private host objects and matching generated-header dependencies.
  `system-matrix/result.json` passes all 76 parent/candidate system cases;
  all 76 corresponding full traces, including cycle fields, are identical.
  This covers 19 fixtures at AXI latency 0/7 in functional/cycle modes.
- `boundaries/result.json` passes all 64 instruction-boundary cases (all 32
  offsets at latency 0/7), with genuine V retirements and unchanged QEMU
  comparisons. Source pins remain stable for both matrices.
- The canonical generic gate closes **FAIL**, native 2: 7/108 functional cases
  pass and 101 retain the parent's terminal-record length mismatch. The same
  four hard cycle bands fail (`mb_depadd`, `mb_indepadd`, `mb_dmiss`, `mb_imiss`).
  No private pre-exit observer, comparator change or band waiver is enabled.
  This is not differential-gate acceptance despite the exact system parity.

The first negative launcher compared differently spelled symlink paths and
accidentally rebuilt the private positive object directory. Its expected mutant
binary was absent (exit 127), so it was rejected, not counted as a test pass.
The exact positive binary was reconstructed to its original SHA-256
`a4e83bdb9059fd20b7935cedebb385473650f12a2a4a2313aea03693792f7f5f`, and all three
seeds were rerun successfully (`leaf-r3/recovery.json`). R2 resolves output paths,
requires fresh mutant directories, and pins the positive executable before/after.
Canonical models and live guest runs were untouched. Historical recipe versions
are archived under `recipe-r1`/`recipe-r2` before subsequent test improvements.

## Reproduction and remaining gates

```sh
TMPDIR=/home/yukidama/external/tmp python3 -B verif/l1/test_tag_lutram.py
python3 -B verif/l1/prepare_tag_lutram.py \
  --source /path/to/frozen/word-reuse-source --out /path/to/fresh/candidate
# Through tools/build_scope.sh with the bounded ipc_parallel32 profile:
python3 -B verif/l1/run_tag_lutram.py \
  --control-source /path/to/frozen/word-reuse-source \
  --candidate-source /path/to/fresh/candidate \
  --profile /path/to/complete/word-reuse/defines.txt --out /path/to/fresh/leaf
```

Run `run_tag_lutram_coherence.py` for the retained coherence corpus. Run
`fpga/inspect_tag_lutram.tcl` only through the exclusive Vivado launcher with
bounded resources. Full-core board/user builds and the directed matrices above
are closed. Differential-gate acceptance, the complete standard suite, gameplay
improvement and whole-FPGA qualification remain open. The canonical generic
gate fails for both the word-reuse parent and this candidate; these results do
not waive or repair those failures.
