# Combined FP correctness / code-payload hardware candidate — October 10

Status at **19:22 UTC: UNQUALIFIED, not deployed**. The new full-PC model is
`4fb1bdaedb9f5afc06862a2872f1a07b5feade229da3e1c3127877e6ad8cf764`.
It combines the [FP correctness repairs](../fp_shared/tb/FP_CORRECTNESS_BUNDLE.md)
with the [tested code-buffer selector](../verif/l1/CODE_PAYLOAD.md). UV,
system/relocated fast paths, full P5 L1s, 256 KiB platform L2, posted-16
transport and the 40 MHz core / 100 MHz PL constraints remain enabled.

## Required physical-board acceptance

The October 10 user requirement explicitly includes **both Quake and Windows
95 on the FPGA**, not only in simulation. Before calling this work accepted:

- Deploy the exact candidate bitstream and matching host/debug software; record
  hashes, board identity, measured core clock and UV + fast-pipe/paired-execution
  evidence. No STEP, U-only or globally slow fallback may substitute for a pass.
- Cold boot Windows 95 to a clean desktop, then exercise keyboard/mouse input,
  menus and opening/closing a window. Retain before/after captures and error logs.
- Run the complete Quake timedemo on the board, retain the final timedemo result
  and full unmodified-frame capture, and report measured U+V gameplay IPC when
  the deployed debug ABI supports it. Label primary-only counters explicitly.
- Keep the canonical differential gates and complete simulation standard suite
  as separate requirements; neither substitutes for these physical tests.

**Both candidate FPGA tests are pending.** The older installed image and its
historical Quake capture do not qualify this source revision. The shared-load
C1 follow-up (`455f65c2` full-PC model) is not present in this document's frozen
`4fb1bdae` hardware export; its separate source bundle is recorded below.

The latest separately verified gameplay baseline is **0.53765810 U+V
retirement-event IPC**, `bfb867f7`, cycles **4,500,065,237–4,600,065,237**.
All 34 consecutive fixed-start windows average **0.496534277**; all earlier
sub-0.48 windows are retained. That older model scored **2.101890118 /
2.107616105 CM/MHz**. None of these measurements transfers to this candidate.

## Exact source and closed checks

All run roots below are under `/home/yukidama/external/tmp/`.

- Full-PC root: `ventium-code-payload-soc.1oJrvfzN`. Build closes native 0 in
  17.53 seconds; its private harness is compiled against its own generated
  header. All 102 intersecting core/shared-FP sources match directed model
  `1139570b`. The 98 inherited platform structural warnings remain.
- Frozen hardware root: `ventium-code-payload-fpga40.pBDLcAms`; manifest
  `115db49eb65ece8653dd944d5ca559c347ca7fe0a58b06c23b55fb06041f6408`.
  Parent is `ventium-high-window-fpga40.U9Ot5NLe`, manifest
  `705bde4e59bc5dd5b5342ddb240a03c9cc24734abf33742736d05cf819249e81`.
- [The freezer](freeze_code_payload_rk_candidate.py) admits exactly eight
  changed files: the seven FP correctness backports and `rtl/mem/ven_l1d.sv`.
  The only new define is `VEN_L1D_CODE_PAYLOAD_SELECT`. It checks **190
  payloads**, **154 native / 156 hardware defines**, 117 filelist units and
  49 include edges. All 170 non-wrapper compiled source payloads match the
  actual native build. No older FPGA source silently replaces a tested repair.
- Six host freezer tests and **61 actual Tcl source/profile checks** pass.
  Strict CPU-hierarchy hardware lint closes native 0 in 2.52 seconds with
  all six structural warning classes fatal, in
  `ventium-code-payload-hw-lint.P1kNBR6Z`, invocation
  `c5bbc8f4a5194d70bad21bce9af41885`. This is not whole-platform lint.
- Both own ten-iteration CoreMark diagnostics close native 0 with the exact
  reference CRCs and **4,767,218 / 4,753,406 ticks**. Independent audit checks
  6,797 source/input pins, native wait/EOF/reaping, actual V retirement and
  zero OOM. Retained owner: `39517701d182420d849eb93ea72ddee4`.
  These short runs are duration-invalid, not new qualified scores; they show
  **zero measured clock regression**, not an additional throughput gain.

The directed core has 2,656 complete QEMU architectural comparisons and
1,328 unchanged complete cycle-record pairs. Canonical `make verify` remains
FAIL (7/108 functional passes, 12/19 scored cycle failures); its 20 cycle
streams equal the parent. No golden, comparison mask or timing band changed.
The code/primary duplicate-residency leaf coverage gap remains explicit.

## Closed synthesis; active standard-suite work

The bounded synthesis-only run started at **18:48 UTC** and closed native 0
after **1,313.50 seconds**, with unchanged inputs and no OOM:
`ventium-code-payload-full-synth.dICMqhmp`, service
`ventium-code-payload-full-synth-oct10.service`, invocation
`f5a25cf3fd5247068d2ec027e9287a6b`; actual Vivado scope
`7b37c9a39c5b4701835b9538245b9318`. It cannot place, route or program the board.
The unchanged exclusive lock, one synthesis job, 8 GiB resident / 6 GiB swap
envelope, 30-minute cap, 12 GiB initial disk reserve and live OOM/resource
guards applied. Independent `audit.json` rechecks 7,157 input pins, actual
156 defines and native source closure. The candidate uses **196,627 LUTs,
54,638 registers, 277.5 BRAM tiles and 47 DSPs**, versus the parent's 196,505
LUTs, 54,610 registers and unchanged BRAM/DSP count. This is **not an area
improvement**. Peak resident usage was 8.00 GiB and swap 0.45 GiB.
There is one critical warning: a generated PS XDC `create_clock` targets an
unknown port/pin. The subsequent closed-DCP audit independently finds the
correct **40 MHz core / 100 MHz PL** clock objects, no black boxes and no
MDRV-1/LUTLP-1 structural errors. It does not waive the warning.

Read-only audit root `ventium-code-payload-clock-audit.VcZc4b4c`, invocation
`85290e96be854cfbafbce0deb77559e9`, closes native 0 in 134.36 seconds, with
7,163 checked input pins and no OOM. Estimated unplaced frequency improves
from **21.362 to 22.799 MHz** (setup -18.861 ns, hold -0.101 ns). The worst
path now runs from EIP to `gpr_reg[4][8]/D`, through 154 logic levels:
43.650 ns total, 9.909 ns logic plus 33.741 ns estimated routing. **This is
neither routed 40 MHz sign-off nor measured hardware frequency.** No placement,
routing, bitstream or board programming was performed. The report-only run
used a 4 GiB initial disk reserve (previous equivalent reports occupied 57 MiB)
and unchanged 2 GiB live stop; the synthesis admission remains 12 GiB.

The candidate's own cold standard-suite components are now running, without
snapshots, guest patches, STEP or pairing suppression:

| Service suffix (all `ventium-code-payload-*.service`) | CPU | Invocation |
|---|---:|---|
| `quake-oct10` | 5 | `9c464fc1072e48079303a02d08a756e6` |
| `win95-oct10` | 8 | `94d522274d3e4b5f890d84f487a08915` |
| `cm900-perf-oct10` | 3 | `ca4f6bbae6de49229e655460a6d05034` |
| `cm900-valid-oct10` | 9 | `a527e202872346f494241737b978fada` |

Actual native executable, command line, source hashes and affinity are
recorded, not inferred from unit properties. Each process is limited to one
CPU, 2 GiB RAM, no swap and 128 tasks. CoreMark is capped at 60 minutes per
seed and must report 900 iterations, all CRCs and >=10 guest seconds. These
are **pending runs**, not suite passes or gameplay measurements. The older
baseline timedemo continues independently.

Preflight reclaimed **1,416,501,961 bytes** by losslessly archiving eighteen
closed-build PCHs and 303 regenerable model C++ files. Each archive was
byte-compared before loose files were removed; original RTL, executables,
headers, objects, logs, media and results remain. Per-root archive receipts
include hashes and restore commands. A legacy failed-run target with changed
input pins was refused and left untouched. The disk reserve was not lowered.

The [additional pre-exit functional diagnostic](../verif/qemu-trace/PREEXIT_OBSERVER.md)
compares all 80,800 records: 98 programs pass, ten remain failing. Native x87
and independent expected C1 agree with RTL at the ten first-divergence sites,
but the remaining full differences and canonical acceptance remain open.

An independently reproduced [host disk-write visibility bug](../ao486-sim/ven/DISK_WRITE_VISIBILITY.md)
was repaired after this candidate was frozen. That host-only repair is not
retroactively included in these running binaries or claimed as an RTL gain.

## Shared-load C1 follow-up: source export, not FPGA acceptance

The separately built full-PC model
`455f65c2d69c7bc041c5e10236d1f277b35c74819297b8a3e0e85806a4023811`
includes the [FLD/FILD/constant-load C1 repair](../fp_shared/tb/FLD_C1.md)
and host disk-write flush. Its own short CoreMark audit passes both original
CRC sets at exactly **4,767,218 / 4,753,406 ticks**, unchanged from the parent:
**0% measured throughput change**. Native processes exited zero and were
reaped; 7,314 input pins were rechecked, with no OOM. Ten iterations are not
a duration-qualified score or a standard-suite pass.

`freeze_fld_c1_rk_candidate.py` exports this model against the exact parent
manifest, refusing profile drift or any hardware-source change other than
the tested `fp_shared/ven_fp_top.sv` hash. It retains **190 payloads, 156
hardware defines, 170 non-wrapper compiled-source matches, 117 filelist
units and 49 include edges**. The 40 MHz core / 100 MHz PL constraints,
P5 L1s, 256 KiB platform L2 and posted-16 transport are unchanged. The
host-only flush does not become an FPGA RTL delta.

Evidence under `/home/yukidama/external/tmp/`:

- `ventium-fld-c1-soc.Ggbyni4b/{build-closed.json,coremark/audit.json}`.
- `ventium-fld-c1-fpga40.STbXY3lg/{input-manifest.json,audit.json}`;
  manifest SHA-256
  `941c2bc788714125fa64e08a45f12ad65416f035fe20f06da316b2ccec8b248c`.
- `ventium-fld-c1-hw-lint.XdixoAJt/closed.json`: strict CPU-hierarchy
  hardware lint exits zero in 2.3569 seconds with stable inputs and all six
  structural classes fatal. This is not whole-platform lint or synthesis.

The actual wrapper Tcl contract passes 61 checks. Ten exporter unit tests
(four new and six inherited parent tests) also pass. The exporter requires
canonical input/output paths and a fresh empty external output directory;
its `--help` lists the required parent, simulation and build-receipt hashes.

The newest model has **no gameplay measurement, complete standard-suite pass,
synthesis, routed bitstream or physical Quake/Win95 acceptance**. The latest
verified gameplay remains the older `bfb867f7` result above, not a result for
this follow-up. The canonical differential failures remain open.
