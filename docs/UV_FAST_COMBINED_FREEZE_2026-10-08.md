# Combined UV-fast FPGA source bundle — Oct 8, 2026

**Synthesis running, not deployed; not a completed Quake repair.** Candidate
gameplay IPC is unmeasured. Historical `53f129e9` measured **0.1659957781052303
primary/U-counter IPC**, not total U+V, in 127 qualified intervals with gaps
within cycles 8,721,490,845–19,169,282,165. It predates this candidate.

The [payload candidate](UV_FAST_L1_PAYLOAD_2026-10-08.md) is now frozen for
whole-core hardware analysis without silently reverting its translation module
or fast-mode definitions. The original parent-shape checks remain mandatory.
`fpga/freeze_rk_candidate.py` adds one explicit, hash-pinned optional bundle:

- `--fe-dtlb-source` plus `--fe-dtlb-sha256`: exactly
  `ventium/rtl/core/ven_fe_dtlb.sv`.
- Exactly `VEN_FE_PIPE`, `VEN_FE_DTLB_MULTI`, `VEN_FE_DTLB_PERM`, before the
  unchanged three hardware-only definitions. No arbitrary extra defines/files.
- Explicit pinned replacements for `core.sv` and `rtl_ven_core.f`, with the
  new child listed once before its parent. Memory-chain and already-extended
  parents are refused; no source discovery or symlink traversal.

Without this option the existing 179-payload / 110-definition behavior remains.
With it the output is 180 payloads / 113 hardware definitions (110 simulator
definitions plus SYNTHESIS/VTM_NO_DPI/XPM). Neither profile inherits acceptance.
`VEN_FE_PIPE` is the experimental translation cut, not the ordinary system fast
pipeline; absence of this experiment does not itself mean slow execution.

## Actual frozen inputs

`/home/yukidama/external/tmp/ventium-uvfast-combined40.mk3SAw/inputs`

- Manifest SHA-256:
  `44ef2fe10930fd30f3675cb7330eaf79833e3a33c2fc9c0e4581d5c7ac975511`.
- Defines SHA-256:
  `f27559562bdbeaa168857545267590bf1c3b90c2f2ade5b9adc5170d978b0fe9`.
- Parent: `fpga40-srtctrl.3M3DsT`, explicitly **historical ancestry only**.
- Seven source/filelist replacements, matching the tested payload model:
  `core.sv`, `core_fastpath.svh`, `core_gpr_wb.svh`, `uv_common.sv`,
  `ventium_alu_pkg.sv`, `ven_l1d.sv`, `rtl_ven_core.f`.
- One additional replacement: current FPGA launcher with mandatory UV-fast
  guards. One added source: `ven_fe_dtlb.sv`. Remaining **171** payloads are
  byte-identical to the parent. Target remains **40 MHz**.

`freeze-audit-r2.json` independently verifies every payload's hash/size, both
filelists' complete source closure, the exact tested simulator definition
sequence, and absent current-model/PASS claims. SoC/user model source and native
binary/object/dependency receipts also verify. No dirty checkout RTL is silently
substituted for those tested sources.

## Closed host tests and honest limits

- Freeze helper: **48 tests pass**, including partial options, incorrect hashes,
  missing integration/filelist, duplicate/reordered child, symlink/out-of-root
  sources, incompatible definitions, and source mutation during copying.
- Current combined launch profile: **25 static guard checks pass**; original
  profile: **20 pass**. Both reject disabled fast-path knobs and nonconstant,
  commented-out, duplicate or zero `cycle_mode` connections.
- The first freeze driver stopped after native freeze success because the
  static Tcl test hard-coded 110 definitions. That failed log is retained.
  The revised test accepts only the exact 113-definition extension and rejects
  partial/reordered bundles; the separate read-only R2 audit closes successfully.
- The first host-unit invocation exposed symlink ancestors in the test scratch
  path. Test fixtures now canonicalize their temporary root, ensuring negative
  cases reach their intended checks. Production no-symlink checks are unchanged.

These are provenance/launch checks, **not FPGA elaboration or CPU correctness**.
The [generic AXI UV-fast gate remains red](UV_FAST_VERIFY_BACKEND_2026-10-08.md).
Whole-core timing/area, both CoreMark seeds, Win95 desktop, and original cold
40 MHz UV-fast Quake timedemo/movie are still required. No slow/U-only control,
private ROM or saved-state success substitutes for those outcomes.

Before larger work, cleanup recovered **2,090,944,181 bytes (1.95 GiB)**: six
enumerated closed-build GCC PCH caches were removed, and 32 closed diagnostic
owner logs were gzip-compressed losslessly. Each compressed log expands to its
original SHA-256; per-file receipts are beside `cleanup-closed.json`. Sources,
binaries, object/dependency receipts and original failed results remain. The
logs are recoverable from `.jsonl.gz`; PCH files are rebuildable. External free
space is approximately 3.2 GiB, so larger runs still need a disk guard.

## Whole-system synthesis launched

At approximately **2026-10-08 05:24 UTC**, the native launcher began synthesis
only from this frozen bundle (`run_synthesis.py`, `synthesis-command.json`,
`synthesis-watch.jsonl` beside the inputs). One exclusive Vivado family, one
synthesis worker, **19 GiB resident / 8 GiB swap** caps and four-hour envelope.
The watcher stops on a 1,100 MiB disk reserve, low host RAM/swap, or scope memory
pressure; no browser termination or concurrent heavy build is used. Initial
owned scope invocation: `1c6e4eacb6de4cbfbca80859f1186f01`.

The previous comparable native synthesis took **2h 25m** and reported about
20 GB aggregate process memory; a ten-minute rerun would not be a realistic
completion plan. That is historical sizing evidence, not a candidate ETA or
guarantee. This run must close natively, retain input hashes, and have completed,
nonstale synthesis checked before any area/timing result is accepted. Placement,
routing, bitstream generation and board deployment have **not** been launched.
