# Way-banked tags + fetch-page cut: full-PC and FPGA export

October 14, 2026 UTC. **Unqualified timing candidate.** The source-matched
full-PC build, CPU-hierarchy hardware lint, 44 environment-store fault/retry
fixtures and both short CoreMark CRC controls pass. A single guarded full
synthesis started at **02:12:34 UTC**; no new Fmax, bitstream or board pass
exists yet. The unchanged parent estimates **32.405457079 MHz unplaced**, below
the required 40 MHz. Canonical verification remains failed.

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

## Live synthesis and resource limits

`prepare_way_banked_synthesis.py` derives fresh controllers from the closed
parent. Four tests preserve the native stop/reap lifecycle, admission section,
read-only timing Tcl, 40 MHz clock and full proof checks; deliberate clock and
disk-floor relaxations are rejected. The unchanged single Vivado-family launcher
is used. **No placement, routing, programming or clock write is authorized by
this diagnostic controller.**

Owner `ventium-way-banked-synth-oct14-r1.service`, invocation
`c622e8db1a894ed79714ff63514d5909`, owns scope
`c484c829b2ec466b8387102d8e8d965e`. Actual native driver and synthesis-child
affinities were observed as CPUs16–19. Limits remain **8 GiB RAM / 6 GiB swap**,
13 GiB combined early stop, 2 GiB host RAM/swap floors, 4 GiB disk floor,
45-minute native limit and 48 tasks. Initial free disk was **7,558,447,104 bytes**,
above both 6 GiB and twice the measured 1,456,762,880-byte parent growth above
the 4 GiB floor. No guard was lowered to admit this run.

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

Still required: closed synthesis and matched native timing audit, **>=40 MHz
synthesized Fmax**, routed timing, a green canonical gate, duration-valid
performance and the entire standard suite, then physical UV-fast Win95 cold
desktop plus keyboard/mouse interaction and complete Quake timedemo.

Latest verified gameplay baseline is **0.51027341 total U+V IPC**, older
FP-repair simulation `c7b95b78`, cycles **1,200,065,237–1,300,065,237**
([counter evidence](FP_REPAIR_EXPORT.md)). This candidate is gameplay-unmeasured.
The existing physical `fe9f539d` image still fails Doom startup; no Doom FPS or
new FPGA acceptance is implied by these simulation results.
