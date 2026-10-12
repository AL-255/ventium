# Zero-C1 / BCD-sign FPGA implementation — October 10, 2026

Historical status at **21:33 UTC, October 10**: both current-candidate CoreMark seeds pass, but native
`impl_1` **failed routing because of congestion**. There is no new bitstream.
A separately bounded read-only failure-checkpoint diagnostic has closed;
this is not timing sign-off, a standard-suite pass or physical-board acceptance.

Latest verified gameplay is **0.49366456 U+V retirement-event IPC** on older
simulated `bfb867f7`, cycles **5,200,065,237–5,300,065,237**. All 41 consecutive
100M-clock windows from 1,200,065,237 average **0.498471873**; no earlier low
window is discarded. Both unmodified endpoint images were reviewed and source,
process, prefix-log and image hashes checked. This is not a full-demo result.
At that time candidate `2b4d7a48` had no gameplay IPC/FPS measurement. See the
October 11 follow-up below for newer evidence.

## Exact candidate and closed synthesis

The [zero-C1 and packed-sign repairs](../fp_shared/tb/ZERO_C1_BCD_SIGN.md) are
backported to full-PC model
`2b4d7a48453fb8f901730d70b5731d9fb6a5459a83fc36f69241f441a7ab298e`.
The FPGA export is source-matched to that model, not to arbitrary dirty files
in the current checkout. Manifest SHA-256:
`b28ce916c8ce276546ac85384dd4959452aad439a14e283d1b2339692465b603`.

Compared with the last synthesized code-payload export, exactly three RTL
files change: the shared FP top, x87 package and iterative BCD converter.
The 156 hardware defines, mapper, full P5 L1s, 256 KiB platform L2, posted-16
transport and UV/system/relocated fast load/store paths remain unchanged.
There is no guest-specific condition, additional pipeline cycle or slow-mode
acceptance fallback.

| Whole-design synthesis | Prior code-payload export | Repaired export | Change |
|---|---:|---:|---:|
| CLB LUTs | 196,627 | 195,617 | −1,010 (−0.514%) |
| Registers | 54,638 | 54,580 | −58 |
| Block RAM tiles | 277.5 | 277.5 | 0 |
| DSPs | 47 | 47 | 0 |

Native synthesis exited zero after **991.43 seconds**. The independent audit
rechecked **8,351 input pins**, all 190 exported payloads, the actual 156-define
native command, 148 native Verilog inputs and the checkpoint archive. Peak
scope memory was 8,589,901,824 bytes, peak swap 1,030,287,360 bytes, with no OOM
or resource-stop event. These are aggregate synthesis effects of the three-file
bundle, not isolated attribution to one edit or a gameplay speedup.

Synthesis DCP SHA-256:
`8147c20bac5205502b61fce9d86520fb8a3c08113dad4dd7f1c4f31ea3b038e0`.
The generated PS XDC retains one critical `create_clock` warning for an unknown
port/pin; it is recorded, not suppressed. Native post-synthesis inspection
loads the project's constraints and independently verifies both actual clocks.

## Frequency and structural evidence

The native read-only audit exited zero in **122.02 seconds**, rechecking 8,357
input pins, with no OOM, unresolved black boxes or MDRV/LUTLP structural errors.

- Constraints: **40 MHz core / 100 MHz PL**.
- Unplaced core setup-path estimate: **21.785543 MHz**, versus the parent's
  **22.799298 MHz**. The estimate worsened despite the LUT reduction.
- Setup slack **−20.902 ns**; hold slack **−0.101 ns**.
- Worst reported path: `eip_reg[0]` to `q_imul_imm_reg[0]/R`, 159 logic levels;
  45.592 ns data delay = 9.741 ns logic + 35.851 ns estimated routing.

This is not routed Fmax, measured silicon frequency, or a 40 MHz timing pass.
Physical implementation and original-workload testing remain necessary; the
user-authorized diagnostic 40 MHz build does not waive native bitstream DRC.

## Implementation handoff

After both preceding Vivado families had fully exited, the sole implementation
controller started at **20:35:09 UTC**. It opens the completed project without
resynthesis, source changes or `reset_run`. Native preflight confirmed
AltSpreadLogic_high placement, Default routing, no post-route physical
optimization and raw binary output. RuntimeOptimized opt omits the previously
crashing BRAM power optimization; clock checks precede the implementation
launch. Native `impl_1` launched at **20:36:03 UTC**; the 20:36:49 live check
confirmed the same process family, no OOM events and all **8,387 immutable
input pins unchanged**. The launcher passes 84 real-Tcl/stub cases, plus 11 profile cases.
Those tests validate launch policy, not place-and-route or CPU correctness.

The guard allows one Vivado family, one implementation job, **16 GiB RAM /
6 GiB swap**, a 21 GiB combined early-stop threshold, 2 GiB live host/disk
reserves and six hours for native implementation. The RAM budget exceeds the
prior completed bank64 implementation's 10.64 GB observed peak; admission
requires 18 GiB available RAM and 8 GiB free swap. Mutable project run metadata
is distinguished from immutable source/constraint/synthesis-DCP pins.

At 20:54 the same implementation family is live in placement, using about
8.62 GB of cgroup memory and zero swap. The four current-candidate native
simulators and the older retained timedemo are also confirmed live. No new
implementation or simulator was launched in this follow-up.

The read-only post-route auditor is prepared separately. Its 23 host policy
checks pass, and invoking its controller now correctly refuses with
`NOT LAUNCHED: implementation has not closed`; no second Vivado starts.
It pins the exact implementation invocation, requires native completion and
unchanged sources/image artifacts, then inspects route state, both clock
domains, setup/hold, exceptions, DRC and CDC. The previous controller's
`cgroup.procs` disappearance race is handled by polling the same process again.
Preparation and mock tests are not native routed-design acceptance.

Placement subsequently completed successfully in **26m22s** with zero native
errors, but emitted `Place 46-14` high-congestion warning. Estimated long-wire
congestion spans 64×64 regions north/south; global north/south/west spans 32×32.
The placed global WNS is −23.907 ns, but that summary alone does not identify
a qualified same-clock path, so it is not converted into a claimed Fmax.
Constraints remain **40 MHz core / 100 MHz PL**; the earlier audited unplaced
core-path estimate is **21.786 MHz**, not physical frequency or routed closure.
The same implementation continues through post-placement physical optimization.
The prepared read-only auditor now also requires an actual spatial congestion
report; all 23 helper-policy tests still pass. No timing exception, source edit
or replacement implementation was used to respond to this warning.

### Native route failure — 21:27 UTC

The implementation closed with native exit **1** after **3,118.35 seconds**.
`Route 35-3` reports global congestion **level 6**, followed by `Route 35-4445`
terminating initial routing. No bit/bin or native success marker exists.
Immutable inputs remain unchanged; peak scope memory is **9,611,210,752 bytes**,
zero swap, no resource-stop/controller failure and zero observed OOM events.
This is a genuine routability failure, not an observation timeout or OOM.

The router reports **900,666 node overlaps**, despite its zero failed-net
counter. That zero must not be treated as successful routing. Global vertical /
horizontal utilization is 31.97% / 25.37%, while local east/west demand reaches
106.05% / 104.95%; global averages conceal the local routing pressure.

| Router hotspot | INT tile bounds | Reported maximum congestion |
|---|---|---:|
| North, 32×32 | X11Y253–X42Y284 | 93.37% |
| South, 64×64 | X2Y244–X65Y307 | 92.55% |
| East, 16×16 | X32Y260–X47Y275 | 106.05% |
| West, 64×64 | X0Y228–X63Y291 | 104.95% |

The saved `rk_ao486_bd_wrapper_routed_error.dcp` is 77,129,851 bytes, SHA-256
`5fc8f33a131453e9c9b564d18e80d3306d607d810de95d4b0185d4db37477a00`.
Closure SHA-256:
`29306781803ff6e1a7bae5990d58121e5b439263f74221a778a40151f9544dda`.
Requested clocks remain **40 MHz core / 100 MHz PL**; this failed, overlapping
route provides no qualified routed Fmax. The earlier unplaced core estimate
was **21.786 MHz**, not a physical frequency measurement.

After the original family fully exited, a read-only diagnostic opened this
exact error checkpoint under a fresh exclusive family. It requests route,
clock, timing, congestion, high-fanout, hierarchical utilization and hotspot
occupant reports. It does not optimize, route, alter constraints or emit a
bitstream. Native limit: ten minutes, 12 GiB/no swap with earlier resource
guards. Root: `ventium-zero-c1-route-failure.uCrakmCQ`; controller invocation
`1e5d49b232f446dbb990e39062909622`, Vivado family
`f343a5ce6eb94dd78aa8b072faa81aa4`. This is diagnosis before choosing a fix,
not another implementation attempt. The successful-route auditor remains
unlaunched and must not accept this checkpoint as a routed design.

### Closed failure-checkpoint diagnosis — 21:32 UTC

The read-only native diagnostic exits zero in **219.32 seconds**, all 18
requested reports present, **8,393 pins independently rehashed**, no OOM,
4,738,441,216-byte observed scope peak and no swap. The diagnostic succeeding
does not turn the failed implementation into a pass. Closure SHA-256:
`ff7e0d361a1591988cd84dd4e97bad5e79faa33d215532bec57ae6c3593e9916`.

Native route-state queries say fully placed, **not fully routed**, partially
routed. `report_route_status` finds **228,422 unrouted nets and only four fully
routed nets**, explaining why the earlier router's zero failed-net count was
not a closure result. The report header nevertheless says `Design State:
Routed`; that header is not a substitute for actual route-status checks.

The same-clock core setup path is now
`seg_base_reg[0][3]/C -> q_imm_reg[24]/CE`, **138 logic levels**, 48.334 ns data
delay (9.985 ns logic + 38.349 ns estimated/partial-route delay). The path-local
setup estimate is **20.594 MHz** under a 25 ns requirement, slack −23.557 ns;
it is **not a routed Fmax or measured board clock**. Core hold slack is
−0.125 ns. The actual constraints remain 40/100 MHz.

The netlist path traverses U/prefix decode, V branch prediction, speculative
memory-chain address/TLB qualification, L1 pair readiness, store snoop,
REP continuation/writeback control and prefix-EX admission. This identifies a
cross-subsystem combinational dependency to investigate; it does not prove the
whole path is simultaneously sensitizable by a legal instruction. No false
path was added to hide it. Replacing `next_eip` with `q_pc + q_len` is **not** a
fix: the source already makes exactly that assignment at `core.sv:4021`.

Physical CLB occupancy corroborates where to inspect first:

| Hotspot | Primitive occupants with rebuilt `u_icache` parent | All primitive occupants | Share |
|---|---:|---:|---:|
| North | 13,078 | 13,471 | 97.08% |
| South | 36,016 | 46,483 | 77.48% |
| East | 4,490 | 4,600 | 97.61% |
| West | 34,376 | 43,158 | 79.65% |

These are **netlist-name/placement groups**, not a claim that the original
I-cache RTL owns all those cells: flattened/rebuilt names also contain core
decode, memory-chain and writeback logic. The regions overlap and cannot be
summed as separate design area. High-fanout data/address nets include cache
address arithmetic at **3,031 / 3,014 sinks**, `rpc_use` at 2,417 / 2,356 and
V-query address bits at 1,849 / 1,848. The 31,468-sink reset is already on a
BUFGCE and should not be confused with those fabric data nets.

Next repair priorities, **proposed, not implemented or performance-qualified**:

1. Trace the reported address/window cones back to raw-byte gathering and
   bank/residency selectors. Share/bank local selection and precompute from
   existing registered ownership where equivalent, rather than replicating
   thousands of dynamic selects. Retain full P5 caches and UV/fast mode.
2. Separate state-local admission from unrelated speculative-memory readiness.
   Prove the relevant owner exclusions before factoring the long
   memory-chain → store-snoop → REP/writeback → prefix-EX path. Do not blindly
   register snoops, drop same-cycle invalidation, or add timing exceptions.
3. Microtest cross-line fetch, cache collisions, paired stores/loads, SMC,
   prefix/AGI and asynchronous FP overlap for each factored cone; compare
   CoreMark cycles before choosing another synthesis/implementation. Any
   pipeline change needs measured CPI cost, not just smaller LUT counts.

The unchanged source-matched guests continue while this evidence guides the
next RTL work. There is no replacement implementation or board deployment.

## Current-candidate standard suite

Four native simulation processes were admitted with the exact `2b4d7a48`
binary, original guest inputs and no snapshots. Each has one actual CPU,
2 GiB memory, zero swap and 128-task limits. Both CoreMark seeds are now
independently audited passes; the two cold guests remain live:

| Component | CPU | Retained service | Invocation |
|---|---:|---|---|
| CoreMark 900-iteration performance seed | 3 | `ventium-zero-c1-cm900-perf-oct10` | `2688053c729440a1b1876a88e331c239` |
| CoreMark 900-iteration validation seed | 9 | `ventium-zero-c1-cm900-valid-oct10` | `8b59dd9aaf98462abc05f9a570f34181` |
| Original Quake demo1 cold run | 4 | `ventium-zero-c1-quake-oct10` | `6f9c33893388476bb57d8af5ecbe36b6` |
| Win95 standard-VGA cold boot | 6 | `ventium-zero-c1-win95-oct10` | `1b54d788f50948ceb71e5f7524566c16` |

Each CoreMark seed has the authorized 60-minute limit and requires original
CRCs plus a completed, valid-duration console result. The long guest services
retain their bounded three-day envelope; startup is not gameplay acceptance.

At 21:21 both 900-iteration CoreMark closures passed the independent
`audit_soc_seed.py` checks: native exit zero, EOF, all children reaped, matching
original CRCs, complete console, actual V retirement, no OOM and **7,989 input
pins rehashed per seed**. Wall times were 52m24s / 51m23s, within the cap.

| Current `2b4d7a48` seed | Guest TSC clocks | Guest seconds at 40 MHz | CM/MHz |
|---|---:|---:|---:|
| Performance | 428,186,037 | 10.704650925 | **2.101890118** |
| Validation | 427,022,738 | 10.675568450 | **2.107616105** |

Both counts exactly match the qualified parent: **0% CoreMark throughput
change**, so these x87 repairs preserve this measured performance rather than
adding a claimed speedup. This closes the current candidate's simulated
CoreMark component, not Quake, Win95, the canonical gate or physical acceptance.
Audit SHA-256 values, performance / validation respectively:
`c4ce0c9bb147dabd85c14d5b61c34693fb16baa3782ac1d4d48c06725576e501` /
`e8bf53716679c5847b0882a28662999cf1cc5a09a5bb0aa40ce6665d2aa01b11`.
Receipts are under `ventium-zero-c1-soc.FTbYSn0L/coremark-900-{performance,validation}/`.

After the new guests' actual identities were checked, the two superseded
`4fb1bdae` cold runs received graceful host stop requests. Both native children
exited zero and were reaped; logs, disk copies and captures remain. Old Quake
is incomplete (its checker correctly reports FAIL), and old Win95 is
CLOSED_UNQUALIFIED with no terminal error, not desktop acceptance. The older
`bfb867f7` timedemo continues separately; it was not stopped or transferred to
the repaired candidate's result ledger.

**Still required:** completed current-candidate suite, canonical differential
gate repair (still FAIL: 7/108 functional passes, 12/19 scored cycle failures),
finished route/DRC/image audit, and physical FPGA Quake plus Win95 desktop/UI
testing in UV+fast mode. No masks, goldens or cycle bands were changed.

## Physical-board preparation and remaining UI gap

The posted-write-safe daemon is installed under the new name
`/tmp/ao486/ao486d.posted-safe-oct08`, root-owned mode 0555; the older daemon
was not replaced. Installed SHA-256 is
`085c629bf84039f0dfd1983b9909026f0e18a811cf43730b68fb9d74357ee4d3`.
All 42 qualified host inputs and 13 uploaded runtime helpers were rehashed.
The native `--ident` check reports `A0486501`, `CTRL=1`, and guest DDR
**unmapped**. The root reservation check confirms the exact non-reusable,
`no-map` 0x60000000–0x6fffffff aperture on boot
`2861e4e8-cd4c-48cd-9f44-7f7d8a991ebb`. No new bitstream, guest launch, clock
write or guest-DDR write occurred. IDENT does not exercise posted-drain startup.

The original standard-VGA Win95 cold seed is now staged at
`/dev/shm/ventium-win95-seed.BWUtOXfR/win95-standard-vga.raw`, root-owned mode
0444 beneath a root-owned 0555 directory. Host and board SHA-256 match:
`37f5db14225f753aa357e321606e75273726fe330a2b7bcd954a61f9337b1a56`.
Sparse transfer preserves all 2,147,483,648 logical bytes while allocating only
95,862,784 board bytes; 335,159,296 tmpfs bytes remain free. Do not attach this
pristine seed writable: create a separately pinned sparse run copy first.
Neither staging nor a matching disk hash is Win95 boot acceptance.

**Mouse UI coverage is currently impossible on this wrapper.** The frozen
`flow/src/rk_ao486_system_pl.v:427` ties both PS/2 mouse inputs high and leaves
the host outputs disconnected. Keyboard scan codes do have an ordinary serial
8042/IRQ1 path. The simulator's opt-in bidirectional mouse is external device
emulation; it is not present in the FPGA netlist. Keyboard-driven menu/window
tests may proceed after boot, but must not be labelled mouse coverage or a
complete keyboard/mouse UI pass. A real device path must be connected and
tested through the normal 8042/IRQ12 interface; guest-memory cursor injection,
disk patches or suppressed no-mouse dialogs would not fix this omission.

An [unintegrated bidirectional byte transport](PS2_DEVICE.md) now passes 98
directed tests against this export's actual 8042 at two clocks, plus negative
controls. A general hosted mouse policy subsequently passes 14 protocol tests,
three deliberately broken-policy controls, and 19 commands / 46 delivered
bytes through that actual 8042 at both 3.125/40 MHz. Neither component is in this
export or active bitstream build. Loss-detectable CSR integration, the PS-side
input service and physical UI qualification remain open; these microtests do
not close the mouse requirement or modify the frozen processor candidate.

## Retained evidence

Follow-up, 21:50 UTC: [register-only prefix factoring](PREFIX_EX_REGONLY.md)
now has 663,700 actual-include equivalence checks and 384 cold QEMU system
cases, with identical A/B architectural and retirement-cycle streams. A
second read-only failed-checkpoint inspection confirms that the redundant
EA/GPR-writeback dependency survived mapping on the reported critical cone.
Follow-up, 22:10 UTC: its full-PC derivative `cf1b3b0b`, source-matched FPGA
export and strict CPU lint now pass their own audits. Both short CoreMark
seeds retain the parent's exact clocks/CRCs; they are not valid-duration scores.
Its full synthesis closes at 22:18 UTC: **191,887 LUTs**, down **3,730 (1.91%)**
from this parent, with unchanged BRAM/DSP counts. The 22:28 read-only comparison
shows the prefix path improving from **21.79 to 26.31 MHz estimated**, while
the overall worst path remains **21.77 MHz estimated**, now ending at V-load
owner capture. These are unplaced estimates, not sign-off or measured frequency.
No new bitstream exists; the linked record identifies the next control-path fix.
This older frozen export remains unchanged. The canonical differential gate
still fails, and physical acceptance remains open. See the linked factoring
record for exact identities and the active synthesis controller.

All roots below are under `/home/yukidama/external/tmp/`:

- `ventium-zero-c1-fpga40.rQeGd6ln`: exported sources, manifest and source audit.
- `ventium-zero-c1-full-synth.yROXoFK0`: `closed.json`, `audit.json`, native
  synthesis log/utilization/DCP; controller invocation
  `f79381ce96f14bc484ad5f1aecee40ff`, scope
  `a817c07da12249cdbf45e8b4726a24a6`.
- `ventium-zero-c1-clock-audit.QVKu9JRQ`: `closed.json`, `audit.json`, raw
  timing/clock/DRC reports; controller `41bee39021fb46278aa5c19adc15313b`,
  scope `bc9a0189f3ab4d9988fd3a5d3f6deca6`.
- `ventium-zero-c1-implementation.a46AcL5o`: reviewed admission, controller,
  profile tests, command, input hashes and live watcher; controller
  `7647dd64f8bc4f51a30813a237686330`, scope
  `fd455804d1f64e3fbca170bb79e67ceb`. Do not launch another Vivado family
  while this owner is alive.
- `ventium-zero-c1-soc.FTbYSn0L`: both `coremark-900-*` runs,
  `quake-cold-zero-c1-oct10.1`, `win95-cold-zero-c1-oct10.1`, their native
  admission receipts and `superseded-cold-request.json`.
- `ventium-store-admit-gameplay-r21.7wFYXH7w/audit.json`: the newer 41-window
  gameplay audit; the r20 receipt remains unchanged historical evidence.
- `ventium-zero-c1-board-stage.xm2KcqY7`: native `ident.txt`, root
  `memory.json`, `staging-audit.json`, `win95-seed-audit.json` and their auditors.
- `ventium-zero-c1-routed-audit.2ND1JB6w`: prepared read-only post-route
  audit, exact-owner controller, native-Tcl host policy tests and manifest.
  It is not automatically queued and has not run Vivado.

## October 11: cold Windows run stopped by its log budget

The `2b4d7a48` Windows simulation is **terminal FAIL, not desktop acceptance**.
Unit `ventium-zero-c1-win95-oct10.service`, invocation
`1b54d788f50948ceb71e5f7524566c16`, exits 2 at **04:04:44 UTC** after
7 h 34 min. Its collector reports `evidence log exceeded 67108864-byte budget`
and terminates the native simulator with SIGTERM (exit -15). It records no
terminal-error signature, no host-stop request and no OOM. The source/media
pins remain unchanged. Repeated guest fault diagnostics filled the capture;
this closure alone does not establish a guest crash or a clean run.

All 34 frames, the partial log, private disk and failed closure are retained
under `win95-cold-zero-c1-oct10.1`. The final log is incomplete, so neither
previous desktop images nor its 3.826B-clock progress qualify the run. A future
collector must preserve bounded, loss-detectable evidence for long runs;
silently raising/removing the cap or ignoring the failed closure is not a fix.
No replacement Windows run is launched in this follow-up.

October 12 clarification from the retained bytes: the dominant vector-6 site
must not be labeled a newly discovered CPU #UD loop. `boot0.rom` at offset
`0xfb17` contains `63 38 6c 6c`, matching the logged instruction bytes.
`FCB2:2FF7`, `FCBF:2F27` and `FCC5:2EC7` all resolve to `0xFFB17` under V86
addressing. These are the same ROM-ARPL callback aliases already diagnosed with
actual pre-fault VM state and acknowledged return operands in
[the earlier Win95 investigation](../docs/WIN95_ABLATION_2026-09-28.md).
Microsoft's archived [KB71264](https://ftp.zx.net.nz/pub/archive/ftp.microsoft.com/MISC/KB/en-us/71/264.HTM)
documents Windows' use of permanently available ROM instructions as system
breakpoints. This evidence supports the callback interpretation, not a blanket
assertion that every exception is benign.

A fresh read-only scan of this run finds 513,810 complete vector-6 records
including `ibuf`; 513,053 have a ROM byte `0x63` matching the logged opcode,
across 17 aliases of `0xFFB17`. This stricter count is **not** directly comparable
to the earlier partial-record regex count. Interleaving and the incomplete log
still prevent exhaustive fault classification; this diagnostic also lacks a
same-record VM bit. Log SHA-256:
`e03e3f9de57efff8dd9ebc0a2b57f0e183c0293ba4d8efffe4a0ff5ebef48b9e`;
ROM SHA-256:
`dca915c5483793a710ee118c5232aad01ef3191bea7d50c2befb1a47d2dd26a3`.
The actual collector failure remains unchanged: incomplete capture and forced
termination after prolonged desktop idle. Do not suppress these records, alter
the guest breakpoint setting, or count the old run as accepted. For the next
cold candidate run, inspect the desktop promptly, perform ordinary UI input,
capture its response, and request owned graceful closure while the evidence
budget remains intact. No new guest run or acceptance waiver is made here.

Newer verified gameplay baseline: **0.51030715 total U+V IPC** on `2b4d7a48`,
cycles **1,200,065,237–1,300,065,237**, from the first predeclared 100M-clock
window (`ventium-zero-c1-gameplay-first.OAQbYerX/audit.json`). It is not a
full-timedemo average. All newer timing derivatives are gameplay-unmeasured.

### Closed-frame diagnosis and acceptance-checker repair

The October 11 read-only follow-up rechecks the failed supervisor invocation,
absent native/owner PIDs, all 34 raw frame hashes and the retained log hash.
Direct inspection of unmodified pixels shows the desktop in frame 3 (near
800M clocks), followed by the readable Welcome window in frame 4 (near 900M).
Frame 4 remains byte-identical through frame 19; frames 20–33 are another
identical group with the taskbar clock advanced. This is **visual evidence of
boot progress, not successful closure, human acceptance or UI interaction**.

At frame 4 the log is only 4,451,811 bytes; the run then continues to
3,826,565,475 clocks before exhausting its cap. At least 514,916 complete
diagnostic records report vector 6 at `fcb2:00002ff7`. Interleaved output prevents
treating this regex count as a complete fault trace. The retained desktop and
absence of a detected terminal signature do not prove every guest fault benign.
The next run should inspect its desktop promptly, exercise normal input, and
request owned graceful closure; indefinitely waiting at the desktop is not
additional boot verification. No guest patch, log suppression, cap increase or
replacement run was made here.

Evidence: `ventium-win95-closed-inspect.0VYl7Pqt/inspection.json`, SHA-256
`7a9fcf693b8339a23c00be9d2ef66e468ee933f1cafff788ad26aa46a74c79a4`.
Lossless PNG previews are separate from the unchanged raw PPMs and are not
substituted for acceptance witnesses.

The [closed-run checker](../tools/check_win95_standard_closed.py) also had stale
host assumptions: 32 tasks, the old `obj1-speed-q16` build layout and 1 MiB
receipt bounds (this failed run's before receipt alone is 1,678,842 bytes).
Explicit schema 4, `board-posted16-40mhz-parentpolicy`, now supports the reviewed
model-local layout, exactly 128 startup tasks and bounded 4 MiB expectation/
before/result metadata. Old profiles retain their old limits. Commands,
40/40/80 MHz clocks, one-CPU quota, 2 GiB memory/zero swap, **64 MiB raw log
limit**, cold-state checks, source pins, native wait, failure rejection and
separate human visual authority remain unchanged. Full source/build provenance
still needs review before producing an expectation; the checker does not
qualify a build recipe or permit dropping pins to fit the metadata bound.

**78 host-only tests pass**: 40 closed-Windows checker tests plus 38 existing
collector tests, including negative closure, truncated capture, altered input,
resource, metadata-bound and manual-review cases. They do not run a guest.
Results: `checker-collector-tests-r5.log` in the inspection root. An earlier
combined test invocation failed one existing fixture's symlink-versus-canonical
path expectation; rerunning with the canonical external TMPDIR passes without
changing the collector. The Windows test fixture now resolves its temporary
path explicitly, so negative tests reach their intended checks.

This repair cannot rehabilitate the SIGTERM/log-budget failure. A fresh,
cleanly closed candidate run, UI interaction, complete standard suite and
physical FPGA acceptance are still required. The separate 40 MHz timing
synthesis remains the primary implementation work; its frozen inputs are not
changed by this host-checker repair.

## October 11: original cold Quake timedemo completed

The older `2b4d7a48` simulation now has a **completed Quake component PASS**:
the original DOS Quake `demo1` reports **969 frames /125.3 seconds /7.7 FPS**
at the simulated **40 MHz** core rate. This is not a physical-board result,
a newer timing candidate's pass, or the whole standard suite. The Windows
closure above remains failed.

`ventium-zero-c1-quake-oct10.service`, invocation
`6f9c33893388476bb57d8af5ecbe36b6`, closes native zero at **12:15:41 UTC** after
56,743.20 host seconds. The closed collector records actual child wait, pipe
EOF, equal captured/persisted byte counts (2,008,293), no capture error, and
absence of the process group. The separate resource receipt reports no OOM.

The follow-up independently reruns `tools/check_quake_timedemo.py check` on
the stopped private disk and complete log. It again passes: fresh QCONSOLE
result, exactly 969 frames, consistent printed FPS/time, original cold reset,
no restored snapshot, no detected terminal error, and **11,572 complete
progress records**, ending at **5,791,550,827 clocks**. All **7,970** retained
input hashes are also rechecked successfully. No guest rerun or replacement
of the previous receipts is involved.

Evidence root: `ventium-zero-c1-soc.FTbYSn0L/quake-cold-zero-c1-oct10.1/`
under external scratch. SHA-256:

- Supervisor result: `e8bc0ddbc06dbc9095bbde593da23788388fab6f9f416a9789b98cc1c3591ecf`
- Native result: `27ac3781c8105af1f2cabe18428497d947c961b86e62c4eeeba90cfb6ea60bb4`
- Complete log: `8ad0d44792331db13fb0d0be6b974318127a811a41e3967e736c91c84cd77449`
- Closed guest disk: `6d36358611c1ce3b08d6ca8edaa358ff0099fd17037f155a09f9be7c5f85e4d1`

Verified gameplay IPC remains **0.51030715 total U+V retirement events/clock**
on this same build over **1,200,065,237–1,300,065,237**. It is a bounded gameplay
window, whereas 7.7 FPS is the complete timedemo result; do not equate their
measurement intervals or call that IPC a full-demo average. The fragment and
descriptor-width successors have no gameplay measurement or FPGA acceptance.
