# Combined FP correctness / code-payload hardware candidate — October 10

Status at **18:57 UTC: UNQUALIFIED, not deployed**. The new full-PC model is
`4fb1bdaedb9f5afc06862a2872f1a07b5feade229da3e1c3127877e6ad8cf764`.
It combines the [FP correctness repairs](../fp_shared/tb/FP_CORRECTNESS_BUNDLE.md)
with the [tested code-buffer selector](../verif/l1/CODE_PAYLOAD.md). UV,
system/relocated fast paths, full P5 L1s, 256 KiB platform L2, posted-16
transport and the 40 MHz core / 100 MHz PL constraints remain enabled.

The latest separately verified gameplay baseline is **0.46555093 U+V
retirement-event IPC**, `bfb867f7`, cycles **4,300,065,237–4,400,065,237**.
All 32 consecutive fixed-start windows average **0.494922360**; the last two
are below 0.48 and are retained. That older model scored **2.101890118 /
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

## Active native work; not completed results

One bounded synthesis-only run started at **18:48 UTC**:
`ventium-code-payload-full-synth.dICMqhmp`, service
`ventium-code-payload-full-synth-oct10.service`, invocation
`f5a25cf3fd5247068d2ec027e9287a6b`; actual Vivado scope
`7b37c9a39c5b4701835b9538245b9318`. It cannot place, route or program the board.
The unchanged exclusive lock, one synthesis job, 8 GiB resident / 6 GiB swap
envelope, 30-minute cap, 12 GiB initial disk reserve and live OOM/resource
guards apply. Parent synthesis was 196,505 LUTs and **21.362 MHz unplaced
estimate**. There is no new frequency or utilization result yet.

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

Preflight reclaimed **1,416,501,961 bytes** by losslessly archiving twenty
closed-build PCHs and 303 regenerable model C++ files. Each archive was
byte-compared before loose files were removed; original RTL, executables,
headers, objects, logs, media and results remain. Per-root archive receipts
include hashes and restore commands. A legacy failed-run target with changed
input pins was refused and left untouched. The disk reserve was not lowered.

The [additional pre-exit functional diagnostic](../verif/qemu-trace/PREEXIT_OBSERVER.md)
compares all 80,800 records: 98 programs pass, ten remain failing. Native x87
and independent expected C1 agree with RTL at the ten first-divergence sites,
but the remaining full differences and canonical acceptance remain open.
