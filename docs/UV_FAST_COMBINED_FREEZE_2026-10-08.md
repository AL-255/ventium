# Combined UV-fast FPGA source bundle — Oct 8, 2026

**Synthesis retry running, not deployed; not a completed Quake repair.** Candidate
gameplay IPC is unmeasured. Historical `53f129e9` measured **0.1659957781052303
primary/U-counter IPC**, not total U+V, in 127 qualified intervals with gaps
within cycles 8,721,490,845–19,169,282,165. It predates this candidate.

**New performance constraint:** the [working-set probe](../verif/fe_pipe/CAPACITY.md)
finds 32–33% extra warm-loop cycles above eight data pages versus a no-cut
UV-fast reference, with full QEMU equivalence and actual U/V pairs preserved.
Do not promote this frozen eight-entry cut as a performance repair based on
the earlier three/five-page tests. Synthesis continues unchanged as a physical
reference; a separately [banked replacement proposal](../verif/fe_pipe/banked/README.md)
passes leaf/parent checks but is not full-core or physically qualified.

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
logs are recoverable from `.jsonl.gz`; PCH files are rebuildable. This left only
approximately 3.2 GiB free, which proved insufficient for synthesis scratch.

## First whole-system synthesis: resource stop, not an RTL result

At approximately **2026-10-08 09:24 UTC (05:24 EDT)**, the native launcher began synthesis
only from this frozen bundle (`run_synthesis.py`, `synthesis-command.json`,
`synthesis-watch.jsonl` beside the inputs). One exclusive Vivado family, one
synthesis worker, **19 GiB resident / 8 GiB swap** caps and four-hour envelope.
The watcher stops on a 1,100 MiB disk reserve, low host RAM/swap, or scope memory
pressure; no browser termination or concurrent heavy build is used. Initial
owned scope invocation: `1c6e4eacb6de4cbfbca80859f1186f01`.

The previous comparable native synthesis took **2h 25m** and reported about
20 GB aggregate process memory; a ten-minute rerun would not be a realistic
completion plan. That is historical sizing evidence, not a candidate ETA or
guarantee.

The disk guard stopped this run after **889.092 seconds (14m49s)**, at the
start of timing optimization. Native exit **143**, wrapper exit **1**; input
hashes unchanged. Sampled free space fell to **985,300,992 bytes**, below the
1,100 MiB reserve. Peak cgroup memory **16,375,279,616 bytes**, swap **0**, all
OOM counters **0**. This was a disk-reserve stop, **not an OOM or demonstrated
RTL failure**. The process family was fully reaped; no completed DCP or
area/timing acceptance is claimed. `synthesis-closed.json` retains that result.

## Space recovery and separately named retry

`/home/yukidama/external/tmp/ventium-synth-space-recovery.yH9EtR/closed.json`
records **12,234,158,607 bytes (11.39 GiB)** reclaimed:

- Removed only the stopped run's enumerated `synth_1/.Xil` generated cache
  (1,062 files, 2,376,877,859 bytes). These files are rebuildable. Project,
  native logs, resource samples and frozen sources remain hash-identical.
- Losslessly gzip-compressed **180** closed owner traces, physical-route text
  records and historical PC logs/snapshots. Each archive was decompressed and
  SHA-256 checked before removing its original; individual receipts retain
  both hashes and sizes. These evidence files are recoverable from `.gz`.
- No source, VHD, movie, accepted executable or checkpoint content was discarded.
  The first cleanup preflight rejected unfamiliar Vivado suffixes before any
  deletion; the exact generated-file types were inspected before proceeding.

Fresh retry directory:
`/home/yukidama/external/tmp/ventium-uvfast-combined40-r2.SICmG1`.
Launched **2026-10-08 09:50:55 UTC**, scope invocation
`32d0aec64c6949d88779db0f89a7cead`. It references the **identical** 180-payload
manifest above; no RTL/define changes, no reuse of partial synthesis outputs.
Starting disk floor is now **12 GiB**, stop reserve **2 GiB**; one exclusive
Vivado family, 19 GiB memory / 8 GiB swap caps and four-hour envelope remain.
Its command, environment overrides, UTC timestamps, resource samples and input
pins are recorded independently. A live process is not a completed result.

This retry must close natively, retain input hashes, and have completed,
nonstale synthesis checked before any area/timing result is accepted.
Placement, routing, bitstream generation and board deployment have **not**
been launched for this source candidate.

## Board preparation: preserve image identity and debug ABI

Board cleanup receipts are under
`/home/yukidama/external/tmp/ventium-board-space-oct08.qMuMxb`.
Six enumerated duplicates were removed after matching host/board hashes and
checking no live process held them: three superseded firmware files, a copied
closed capture archive, its RAM dump and its private run VHD. All are recoverable
from retained host copies (RAM/VHD also verified within the archive). Board root
free space increased from **16 to 75 MiB**, tmpfs from **42 to 87 MiB**.
The deployed `1c8f20ac` image hash was unchanged; no clock, MMIO, guest execution
or FPGA programming was performed during cleanup.

The frozen `ven_mgmt_axil.v` advertises **DBG_EXEC_CAP=0x56450005 (ABI 5)**.
The deployed DCP-only observer ECO advertises ABI 9. Reusing the old
`prepare_full.py` / owner-scan watch scripts would incorrectly assume that the
new source bitstream contains those ECO-only observers. Do not do so: pin the
new bitstream identity and check capability **before any debug-control writes**.
The repository's base `ven_board_probe.py` supports ABI 5; the full cold-run
controller must use matching base debug operations, not ABI 9 register layouts.
The primary retirement counter remains **U-only**, not total U+V IPC.
