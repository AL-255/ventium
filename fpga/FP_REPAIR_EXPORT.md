# General repair transfer to the FPGA candidate

October 13, 2026. **Unqualified candidate; not deployed.** This transfers the
tested general processor repairs onto the performance/timing candidate without
changing U/V issue, system/relocated fast paths, full P5 L1 geometry, single-fill
ao486 policy, posted-16 transport, or the 40/100 MHz clock constraints.

## What changed

The full-PC parent already contains the [LMSW](../verif/sys/lmsw/README.md),
[obsolete-x87](../verif/sys/obsolete_fp/README.md), and
[segment-extent](../verif/segment_extent/README.md) repairs. Four further files
are composed byte-for-byte from the tested core:

- `core.sv`: real/V86 environment-mode connection.
- `ven_fp_top.sv`: saved FP-pointer restoration, real/V86 save layout, and
  instruction-owned FRNDINT C1/exception commits.
- `ven_fp_misc.sv` and `fpu_x87_pkg.sv`: full-precision, unsigned-magnitude
  FRNDINT rounding with precise special-value and exception behavior.

See the [restore](../verif/sys/fp_env_restore/README.md),
[store](../verif/sys/fp_env_store/README.md), and
[FRNDINT](../verif/sys/frndint/README.md) test reports for exact scope and open
corners. These are ISA repairs, not Doom/Quake workarounds. No extra global
serialization, slow-mode fallback or guest-code patch is introduced.

The last synthesized endpoint-map image predates all these repairs. Its FPGA
derivative therefore changes **eight** payloads, including the five LMSW core
files. All **170 shared native HDL inputs** match the full-PC export; the
complete freeze retains **190 payloads**, 117 filelist units, 49 include edges,
158 hardware defines and 156 simulator defines. The four-file PC transfer
matches all **102 common RTL files** against the tested directed core.

## Closed verification

- Private-host/header full-PC build: native exit 0, **24.28 s**, all inputs
  unchanged. The existing **98 platform structural warnings remain**; this is
  not a whole-SoC lint pass.
- Hardware-profile CPU-hierarchy lint: native exit 0, **3.88 s**; all six hard
  structural classes enabled. No waiver or feature switch was added.
- Five transfer/freezer tests and three synthesis-controller tests pass,
  including drift/reapplication rejection, exact delta sets, preserved guard
  lifecycle and mutation checks against enlarged limits/timeouts.
- Both **10-iteration CoreMark smoke seeds** pass reference CRCs. The
  independent audit rechecks **17,019 inputs**, exact native CPU11 affinity,
  source/model/media identity, terminal owner and child reaping, with no OOM.

| Seed | Parent ticks | Candidate ticks | Actual V retirements |
| --- | ---: | ---: | ---: |
| Performance | 4,767,218 | 4,767,218 | 1,055,307 |
| Validation | 4,753,406 | 4,753,406 | 1,054,254 |

**Measured CoreMark throughput change: 0%.** These short runs are not valid
performance scores or full standard-suite qualification. The shared core's
[private-reference functional corpus](../verif/l1/CYCLE_BACKEND_PROFILE.md)
passes 108/108 programs (80,800 records, 30,134 V retirements), including the
board's single-fill policy. Existing stack masks remain; only 105 programs
pass completely unmasked. Canonical-oracle promotion, failing cycle bands and
remaining system/fault discrepancies are not waived.

## Synthesis and remaining acceptance

One guarded synthesis was launched under
`ventium-fp-repair-synth-oct13.service`, invocation
`c6d4e5049a16454496b2f0ecd0902a24`. It retains the matched Default logic-only
mapper, fixed 40 MHz core constraint, exclusive Vivado family, 8 GiB RAM /
6 GiB swap caps, measured-growth disk admission and live 4 GiB disk stop floor.
**No new Fmax result yet.** The matched endpoint parent estimates
**35.056967572 MHz**, below the 40 MHz requirement. Neither an unplaced estimate
nor a 40 MHz constraint establishes routed timing or physical operation.

`prepare_fp_repair_synthesis.py` generates, but does not launch, the matched
synthesis and read-only timing controllers. Their independent audits must
close after the same native invocations; failed or resource-stopped runs may
not be replaced by a successful launcher receipt. Implementation and board
programming are not performed by these controllers.

Still required: >=40 MHz synthesized Fmax, implementation/timing checks,
duration-valid >=2.1 CoreMark/MHz, complete CoreMark correctness seeds, Win95
cold desktop plus UI interaction, full Quake timedemo, and physical FPGA
Win95/Quake validation in UV-fast mode. The installed `fe9f539d` image is
unchanged; its [Doom startup failure](../docs/FPGA_DOOM_2026-10-13.md) remains.

## Reproducible identities

Evidence root: `/home/yukidama/external/tmp/ventium-fp-repair-transfer.a8nzrjHu`.

| Artifact | SHA-256 |
| --- | --- |
| `soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted` | `c7b95b78f47f5e709136f98230bdf33975cf8db0e925956b469649cbf6384afd` |
| `fpga-r1/input-manifest.json` | `bf2a944dc6aedaa7ec406fdf5c5607c54d707b8cb04fa25ad88b6ba74fac9b93` |
| `soc-r1/coremark/audit.json` | `0d5166bc36cc1f0d58133f8279f623702c33aa502ff7d4d13a4e9644d9be2f69` |

The CoreMark owner is terminal, invocation
`c65abc7c1e764fef9e364fd0074eada9`, MainPID 0 / native exit 0.
`build_fp_repair_soc.py` and `freeze_fp_repair_rk_candidate.py` reject unknown
parent hashes and compare the exact source closure; they do not overwrite the
unrelated dirty root RTL. The isolated repair recipes remain the source of
each delta.

For build space, **246 inactive metadata files** were gzip-compressed with
full decompressed SHA checks, freeing **1,608,589,312 bytes**; use `gzip -dk`
on the exact archive listed in `metadata-archive-closed.json` before historical
re-audits. **Eleven obsolete PCH-only archives**, 529,537,483 bytes, were pruned
after checking all members and retained matching generated headers. They are
regenerable compiler caches, not byte-recoverable archives. A mixed archive
containing traces was rejected and retained. Current input pins, sources,
models, media, DCPs and all failure evidence are preserved. Failed cleanup
attempts stopped before deletion and remain separate from successful receipts.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**; it predates this candidate and is not a physical
FPGA or Doom measurement. The >=0.48 Quake target still needs this candidate's
own gameplay evidence and an error-free completed timedemo.
