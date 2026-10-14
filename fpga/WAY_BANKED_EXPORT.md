# Way-banked tags + fetch-page cut: full-PC and FPGA export

October 14, 2026 UTC. **Unqualified timing candidate.** The source-matched
full-PC build, CPU-hierarchy hardware lint, 44 environment-store fault/retry
fixtures and both short CoreMark CRC controls pass. Full synthesis and its
matched native timing audit now close successfully: **34.495843251 MHz
unplaced**, versus **32.405457079 MHz** for the parent (**+6.45%**). Whole-chip
LUT usage falls **4.17%** and the tag-register inference regression is removed.
This still misses **40 MHz**; there is no new bitstream or board pass.
Canonical verification remains failed.

## Transfer and source identity

The [core report](../verif/l1/WAY_BANKED_CORE.md) describes the only two RTL
deltas: explicit per-way distributed tag memories and mathematically equivalent
fetch-fault page arithmetic. There is no new cycle, feature switch, global
stall or guest-specific behavior. Dirty root RTL was not overwritten.

Evidence root: `/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X`.
The full-PC source is `way-banked-soc-r1/source`, derived from
`fp-compare-soc-r1`. All **102 shared RTL files** match the checked core;
exactly `rtl/core/core.sv` and `rtl/mem/ven_l1d.sv` differ from that parent.
All **156 simulation definitions**, `cycle_mode=1`, UV/system/relocated fast
paths, full P5 caches, single-fill shim and posted-16 transport remain.

The private host compiled against this model's generated header and local
object. The **32-job** guarded build finished in **24.60 s**, native exit 0,
with source hashes unchanged. The existing **98 SoC structural warnings** are
unchanged, not waived or described as a full-SoC lint pass. Build affinity was
explicitly moved to CPUs0–9,12–31, leaving the existing CPU11 gameplay run free;
the original 10/2 GiB RAM/swap caps and native timeout remain.

Full-PC model SHA-256:
`810fca8a8f27298f190274a85d8bec7d6ccf785347edfaa0316f4662a43f4719`.
Owner `ventium-way-banked-soc-oct14-r1.service`, invocation
`e234a026f8da4ff58f3ce18afcb0753d`, is terminal MainPID0/exit0.

The FPGA freeze checks **170 shared HDL files**, 190 payload files, the exact
158-definition hardware profile and original 40/100 MHz clocks. Four transfer
tests reject absent, drifted, repeated or extra source changes and preserve
the full-source/profile/resource contracts. Manifest SHA-256:
`8f4cf7b06c4368cf888300300513a2835fe7bd678e192b48839bebdb00fe1523`.
The 158-definition Tcl source contract passes; qualification stays `UNQUALIFIED`.

## Closed regression controls

- Strict **CPU-hierarchy** hardware-profile lint passes all six hard structural
  classes in **3.83 s**. This is not full-SoC lint.
- **44 unchanged cold environment-store fixtures**, each at AXI latency 0/7,
  pass all **88 complete architectural QEMU comparisons** in **12.14 s**.
  Original bytes, fault order, native/guest exits, paired execution and real
  cache backing activity remain checked. The private environment-state oracle
  is retained; this does not promote it to canonical QEMU. The adapter test
  proves the complete fixture/execution/grading body is unchanged.
- Both **10-iteration short CoreMark seeds** cold-boot and pass the original
  CRCs, with actual V retirement. Performance ticks **4,767,218**, validation
  ticks **4,753,406**: both exactly equal the full-PC parent, **0% cycle gain**.
  They ran **214.91 / 209.25 s**, with observed CPU12 affinity, both native
  children reaped, 60,973,056-byte owner peak RAM and no OOM/swap allowance.
  The independent audit rechecks **21,218 input pins**, console CRCs, original
  disks/ROMs, exact command and native closure. These short runs are **not
  duration-valid scores**, full CoreMark validation or standard-suite acceptance.

| Receipt | SHA-256 |
| --- | --- |
| `way-banked-soc-r1/build-closed.json` | `ae7a7a678c31aac0bc361dd9b8a6a0c818d8f67b70f0faa0f74fbfefa6aba887` |
| `way-banked-lint-r1/closed.json` | `9e9f51c2f4465c3216270fcc2616e87ed8ea717661bede1b370565964b7ee716` |
| `way-banked-env-fault-r1/closed.json` | `cb9a53daf80417519bf749b9d8ea9ab8eecb263872266d5c48704cbd5fa05a0c` |
| `way-banked-soc-r1/coremark/audit.json` | `0905554a11b9b41dd5343202f65645c5b66fc69e9049637206b70342f7ed1777` |

## Closed synthesis, timing and remaining critical path

| Matched whole-chip result | Parent | Candidate | Change |
| --- | ---: | ---: | ---: |
| Synthesized, unplaced core estimate | 32.405457079 MHz | 34.495843251 MHz | +6.45% |
| CLB LUTs | 195,562 | 187,410 | −8,152 (−4.17%) |
| CLB registers | 60,184 | 55,006 | −5,178 (−8.60%) |
| BRAM tiles | 277.5 | 277.5 | 0 |
| DSPs | 47 | 47 | 0 |

These are the combined two-file change's results; they do not isolate each
change's contribution. The independent synthesis audit verifies **25,401
input pins**, 148 native `read_verilog` files, the exact 158 definitions, the
unchanged mapper and the two allowed source differences. Synthesis finishes
at **02:44:39 UTC**, native exit0, in **1,925.43 s**, with peak **8,589,926,400
bytes RAM / 1,025,347,584 bytes swap**, no OOM and no resource stop.

The whole-chip primitive inventory confirms **5,120 parent tag FDREs → zero**.
Each candidate tag way has **30 RAM64M8 macros**, represented by **240 RAMD64E
leaf cells**. Macro and leaf counts describe the same memories and must not be
added. This is direct whole-chip evidence, separate from the earlier isolated
L1 result of 48 macros per way and 40.84% module-LUT reduction.

The timing audit closes at **02:52 UTC**, native exit0, in **481.44 s**. It
rechecks **21,428 pins**, both original **25 ns / 10 ns** clocks, all 30 setup
and ten hold paths, zero unresolved black boxes and zero requested structural
DRC violations. Peak RAM is **4,822,577,152 bytes**, swap0, no OOM. The matching
PS-generated `create_clock` synthesis warning remains visible; the audit checks
the actual project clocks rather than treating that warning as a timing pass.

Worst setup slack is **−3.989 ns**, giving `1000 / (25 + 3.989)` MHz. The
worst path is now **EIP[0] → ESP[16]**, **100 logic levels**, data delay
**28.778 ns** (5.642 ns logic / 23.136 ns *estimated* interconnect). It runs
through decoded memory address/segment admission (`sys_fp_load_ok3`,
`fp_sys_bail`), store request, translation/cacheability, paired-write readiness,
memory ACK and integer commit. **19/30** worst paths name the admission/store
chain; **none** names the previous `fetch_overlength_probe` bottleneck.
Unplaced interconnect estimates are not measured routed congestion. Hold slack
is **−0.101 ns**; this is not routed setup or hold sign-off.

The next investigation is therefore fast-memory admission and completion,
not another speculative change to overlength-instruction probing. Preserve
bounded DS and flat DS/SS admission, byte/dword boundary behavior, precise
faults, held-request ownership and UV throughput. Factoring segment checks
ahead of late address selection needs equivalence and full-core tests before
another full synthesis; removing checks or forcing slow mode is not a fix.

| Closure/audit | SHA-256 |
| --- | --- |
| `way-banked-synthesis-r1/closed.json` | `c7eee4177c831b7b5f9e88517d535325a261722d547bb47e9dc0de460d908f4c` |
| `way-banked-synthesis-r1/audit.json` | `34d8aac8d7d1af8ac88455cdc38097b4bc70871682ca0006b7f4f39156b48371` |
| `way-banked-clock-r1/closed.json` | `32dd3b2ddd164a53b1b483b9269891cbc24efa17d50d17c9dc6c1cf16b7d5a3e` |
| `way-banked-clock-r1/audit.json` | `84236ff645b1d829c2af5c727128bd8766c98ef60d89b62e1a8afbe8e91f70ca` |

## Resource guards and launch provenance

`prepare_way_banked_synthesis.py` derives fresh controllers from the closed
parent. Four tests preserve the native stop/reap lifecycle, admission section,
read-only timing Tcl, 40 MHz clock and full proof checks; deliberate clock and
disk-floor relaxations are rejected. The unchanged single Vivado-family launcher
is used. **No placement, routing, programming or clock write is authorized by
this diagnostic controller.**

Owner `ventium-way-banked-synth-oct14-r1.service`, invocation
`c622e8db1a894ed79714ff63514d5909`, owned scope
`c484c829b2ec466b8387102d8e8d965e`. Actual native driver and synthesis-child
affinities were observed as CPUs16–19. Limits remain **8 GiB RAM / 6 GiB swap**,
13 GiB combined early stop, 2 GiB host RAM/swap floors, 4 GiB disk floor,
45-minute native limit and 48 tasks. Initial free disk was **7,558,447,104 bytes**,
above both 6 GiB and twice the measured 1,456,762,880-byte parent growth above
the 4 GiB floor. No guard was lowered to admit this run.

The synthesis was followed by the bounded sequencer
`ventium-way-banked-timing-sequencer-oct14-r1.service`, invocation
`9907a645f50f48c1b7cc1f90f2e29fb2`. It waited for that exact live owner to close
successfully, ran the unchanged synthesis audit, then launched the already
prepared read-only timing controller and checked its closure. It cannot retry
synthesis, relax the native guards, route or program the FPGA. Its script and
receipts are `finish_way_banked_timing.py` and `way-banked-sequencer-*.json`
under the evidence root. It and both native owners are terminal MainPID0 / exit0;
no Vivado remains. Timing owner invocation is
`548d453ee73540d1b981312254ae695c`, scope
`9e644d31741747138a95a4bae45a3208`. Sequencer closure SHA-256:
`40c11cd138d8132c8bf716393362cb37dfa67a8c726da9f6d48c22711b9e68af`.

To reach admission, ten superseded Oct10/11 **diagnostic synthesis DCPs** were
removed, freeing **1,800,063,540 bytes**. Each exact target's historical audit
hash, regular-file inode, naturally closed owner invocation and absence of
open handles were verified. **23,919 protected pins remain unchanged**;
current/immediate-parent DCPs, deployed images, source trees, reports, logs,
simulators, media and captures remain. Removed DCPs are regenerable from those
sources, but **not byte-recoverable**. No directory was recursively deleted.
Targets are listed in `superseded-oct10-dcp-plan.json`, SHA-256
`58aeb7270256cd1aa743a418f42eb1cd81b196e30bcf6c9bd44362f9be331cb9`;
closure SHA-256 is `8bf5661ab20340dc7580d8a0bfd717678379cd67b0b8fc6beae1f85e914f29d5`.

Still required: **>=40 MHz synthesized Fmax**, routed timing, a green canonical gate, duration-valid
performance and the entire standard suite, then physical UV-fast Win95 cold
desktop plus keyboard/mouse interaction and complete Quake timedemo.

Latest verified gameplay baseline is **0.50607097 total U+V IPC**, older
FP-repair simulation `c7b95b78`, cycles **1,300,065,237–1,400,065,237**
([counter evidence](FP_REPAIR_EXPORT.md)). This candidate is gameplay-unmeasured.
The existing physical `fe9f539d` image still fails Doom startup; no Doom FPS or
new FPGA acceptance is implied by these simulation results.
