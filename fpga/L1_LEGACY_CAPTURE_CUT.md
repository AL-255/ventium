# Legacy L1 capture cofactor — 2026-10-10

Status: **private equivalence-tested RTL candidate; synthesis running, not a
40 MHz result** (22:56 UTC).
The full-core candidate is `de02d77f297f713adfc885c911006e7a7c427fa4113532183ba7e1160b3026a5`.
No architectural feature, cache geometry, fast path or accepted clock edge is
intentionally changed. No new FPGA image exists.

## Actual critical dependency and repair

The [prefix candidate's native timing audit](PREFIX_EX_REGONLY.md) found a
160-level path ending at `pipe_mem_v_hit_q`, with a **21.77 MHz unplaced
estimate**, not routed sign-off. Part of that path traverses next-read COMMIT
and returns through `pair_legacy_capture` to V-bank admission.

Checking the **actual hardware defines** narrows the earlier hypothesis:
`VEN_P54_DUAL_LOAD_PRIME` and `VEN_P54_REGMEM_PRIME` are absent in this raw-byte
profile. The offending dependency is still present through the generic
`do_rd_cap` mux, even though fresh legacy capture expressly requires both
`!mc_lookup_next` and `!stream_path`.

Let `M` be next-read lookup, `S` stream mode, `N` next-read capture, `T` stream
capture and `L` ordinary legacy capture. The old predicate includes:

```
!M && !S && other_guards && (M ? N : S ? T : L)
```

The new predicate uses `!M && !S && other_guards && L`. A new
`do_rd_cap_legacy` wire contains the **unchanged** legacy arm. The actual
`do_rd_cap` mux and every sequential capture/owner rule remain intact. Only
the two byte/dword legacy-pair predicate arms consume this cofactor directly.
This removes the explicit COMMIT-to-fresh-V dependency in RTL; only a new
mapped timing audit can establish whether it improves hardware timing.

[prepare_l1_legacy_capture_cut.py](../verif/l1/prepare_l1_legacy_capture_cut.py)
requires the exact source-qualified L1 SHA
`2c6821f396d081bf30916a7ad48505512aa3477f649cec2ce25f3e621d0a133b`.
It writes only a fresh private file and rejects parent drift or reapplication.
Existing frozen sources and the unrelated dirty checkout are not overwritten.

## Evidence so far

Scratch root: `/home/yukidama/external/tmp/ventium-l1-capture-cut.OzWa5vnV`.

- Four recipe tests pass, including guard/capture drift rejection.
- `leaf-r5` compares actual parent and candidate L1 modules on both the
  pre-acceptance and post-edge observations. It retains ordinary memory-chain
  tests, and adds **538 cases in each of two profiles**: the hardware feature
  set with simulation assertions enabled, and an additional prime/store-read
  profile. Each covers all U/V bank combinations, byte/dword extents,
  irrelevant next-request/commit toggles, same-bank rejection, held-response
  replacement rejection, standalone two-lane requests, snoop/flush cancellation,
  uncommitted lookahead and backing-stalled U-store/V-load requests.
- Native exits are 0, with **15,970 / 15,958** interface/control observations.
  Both deliberately incorrect mutants fail the equivalence checker: making
  fresh V depend on next COMMIT, and ignoring saved-window reuse exclusions.
- Earlier attempts are retained as failures, not passes: an inherited-FD
  admission-check error, the renamed reference module's end label, a fixture
  attempting to observe simulation counters under `SYNTHESIS`, and a mutation
  caught by the directed assertion before the first miter sample. The final
  miter adds a pre-edge sample; no RTL check is suppressed.

Full-core root: `/home/yukidama/external/tmp/ventium-l1-capture-core.smp3U8xg`.

- [The builder](../verif/l1/build_l1_legacy_capture_cut.py) derives exactly one
  RTL delta from the qualified prefix parent; all 154 feature defines remain
  unchanged. Native build exit 0, **12.46 seconds**. The private C++ host object
  and generated-header dependency belong to this model; no external VPATH
  object is reused.
- **384 cold paged prefix cases** pass against QEMU, with all parent/candidate
  states and retirement cycles identical, using both AXI latencies 0/7.
- [72 additional cold paged memory cases](../verif/l1/run_l1_capture_cut_system.py)
  cover six load/read-ALU/bank/split patterns, flat and relocated segments, and
  six instruction offsets. Both AXI latencies pass complete QEMU state checks;
  every parent/candidate record and retirement cycle matches. The candidate
  executes **1,500 actual V-memory retirements**. Same-bank and crossing V
  requests are explicitly required not to pair. No terminal record or paired-U
  state is removed, and no new comparison mask is added.

The actual-L1 under-fill miter also closes with native exit 0: **228,304
interface/control samples**, including instruction-word reuse, data hits during
instruction fill, and the optional prime-under-fill profile. All original
checks remain enabled; no DUT state is forced.

The unchanged canonical `make verify` remains **FAIL**, native make exit 2:
**7/108 functional passes**, with **12/19 scored cycle kernels** outside their
bands, unchanged from the parent. No golden, state mask or cycle band changed.
The first raw-file cycle audit reports a mismatch because trace headers name
different private image paths; its failed receipt is retained. An independent
audit verifies all input images are byte-identical, compares every parsed
architectural/cycle record, and checks headers after normalizing only that
known pathname. All 20 complete RTL cycle streams match the parent; this does
**not** turn the failing canonical gate into a pass.

The independent `audit.json` rechecks **6,452 input pins**, **198,816 identical
architectural records**, and **37,068 actual V retirements** (including the
1,500 memory retirements). Audit SHA-256:
`8e251658c11a20b2d422fc4297c1407fd41b7392836bd17fca7de3ca8cb45efd`.
Native completion receipts are preserved. Garbage-collected systemd unit
handles establish only that they are no longer live, not historical exit codes.
These directed results do not qualify the standard suite, board or timing.

## Source-matched FPGA synthesis

The full-PC model is
`467ff95f3b58a834a84e7287cb7adafb7a72afc43bcd0b6178a14bcef03c19c5`,
under `ventium-l1-capture-soc.NLtK13lC` in external scratch. Its only RTL change
from `cf1b3b0b` is the same L1 predicate. All **102 shared RTL inputs** match
the directed model; all 154 simulation defines and posted-16 transport remain
unchanged. Native build exit 0 in 14.36 s, private host-object/header ownership
checked. The inherited 98 platform structural warnings are not lint passes.
This model has no duration-valid CoreMark score, gameplay or Win95 acceptance
yet. Both short cold-boot CoreMark seeds now close with native exit 0 and
original CRCs, with **exactly unchanged parent clocks**:

| Seed (10 iterations) | Parent clocks | Candidate clocks | Actual V retirements |
| --- | ---: | ---: | ---: |
| Performance | 4,767,218 | 4,767,218 | 1,055,307 |
| Validation | 4,753,406 | 4,753,406 | 1,054,254 |

The independent `coremark/audit.json` rereads complete consoles, verifies the
real executable/argv/CPU-11 affinity, both reaped native children, original
disks/ROMs and **8,982 source pins**. No OOM; scope peak 123,510,784 bytes.
Controller invocation `227fde438bee451fbd8d7bf7cbd52ad6` is exited, native 0.
Audit SHA-256:
`a2b1599886d155d3dfe28502f5993aae4bcdc105f4d9dc5bea437391a5e4c144`.
This is **0% measured throughput change on the short workloads**, not a new
duration-valid CM/MHz score, full-suite pass or FPGA pass.

[The exporter](freeze_l1_capture_rk_candidate.py) freezes that model under
`ventium-l1-capture-fpga40.78luWDQ2`. Manifest SHA-256:
`4d52be937b4c582efb15a284ac525187023969efbc9fabd721d602a67dc5052f`.
Independent export audit rechecks **9,141 input pins**, 190 payloads, 117
filelist units and 49 include edges. The sole L1 delta has SHA-256
`11ed3337a28f0eebd546860ad2abad7996352036d2fc86c930b578009e0c42e0`.
All **156 hardware defines**, full P5 L1s, 256 KiB platform L2, posted-16,
UV/system/relocated fast paths and 40/100 MHz core/PL constraints are retained.
Four exporter tests pass; exact exported CPU-hierarchy lint passes with all
six structural warning classes as errors. This is not full-SoC lint or a
physical pass.

One full synthesis started at **22:56 UTC**, in
`ventium-l1-capture-full-synth.Ygy8gzTv`, controller
`ventium-l1-capture-full-synth-oct10.service`, invocation
`4fe094cfd4d242e7af4cefca7e2509de`. The verified native Vivado family belongs to
scope invocation `fadca26579dc49e4810c09847bcdc706`. It uses the parent's
unchanged logic-only mapping profile, one job, **8 GiB RAM / 6 GiB swap**, a
30-minute native deadline, and a 4 GiB runtime disk floor. Admission checks
10 GiB free and more than twice the parent's measured 1,227,014,144-byte disk
growth above that floor. No place/route or programming is started by this
controller. Completion, area and native-clock timing are still pending.

A retained coordinator now waits on that **exact live synthesis invocation**,
not a log timestamp: `ventium-l1-capture-audit-queue-oct10.service`, invocation
`a94c850c8cdd4cba8729fef1105ebded`. Only after successful native closure and
independent source/DCP auditing may it start the read-only clock audit under
`ventium-l1-capture-clock.c0os0diB`. It opens both original projects/synthesis
runs with their original XDC, compares the actual V-response capture endpoint
and overall core paths, and checks clock objects, black boxes and structural
DRC. It neither replaces a live Vivado family nor authorizes place/route or
deployment. Prepared scripts are pinned; no result is presumed from the queue.

## Resource handling and remaining work

Removed only **28 explicitly enumerated compiler PCH cache files** from closed
builds, recovering **2,428,850,176 allocated bytes** (2.26 GiB). The exact paths,
hashes and inode checks are in `pch-prune-plan.json` / `pch-prune-closed.json`
and `pch-prune2-plan.json` / `pch-prune2-closed.json` under the leaf root.
These caches are rebuildable; binaries, sources, dependency files, logs and
traces remain. No live guest media or run directory was deleted.

Next: close the bounded synthesis and compare the actual synthesized netlist
and area before another place/route. The target remains **at least 40 MHz
synthesized timing**, followed
by routed and physical validation in UV + fast-pipe mode. A constant-folding
argument is not a frequency measurement or a suite pass.

Latest verified gameplay baseline: **0.50499738 U+V retirement-event IPC**,
older model `bfb867f7`, cycles **5,600,065,237–5,700,065,237**. Its 45-window
gameplay mean is **0.500212996** and its completed original timedemo is
**7.73 FPS at modeled 40 MHz**. This capture-factored candidate has no gameplay
measurement. The last physical result remains `fe9f539d`: **0.167990963
primary/U-only counted IPC**, **3.36 FPS at approximately 40 MHz**; total U+V
is unavailable on that ABI.
