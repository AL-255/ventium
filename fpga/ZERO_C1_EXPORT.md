# Zero-C1 / BCD-sign FPGA implementation — October 10, 2026

Status at **21:21 UTC**: synthesis, the native clock/structural audit, placement
and both current-candidate CoreMark seeds are closed; native `impl_1` is routing.
This is **not** a
bitstream, timing sign-off, standard-suite pass or physical-board acceptance.

Latest verified gameplay is **0.49366456 U+V retirement-event IPC** on older
simulated `bfb867f7`, cycles **5,200,065,237–5,300,065,237**. All 41 consecutive
100M-clock windows from 1,200,065,237 average **0.498471873**; no earlier low
window is discarded. Both unmodified endpoint images were reviewed and source,
process, prefix-log and image hashes checked. This is not a full-demo result.
Candidate `2b4d7a48` has no gameplay IPC/FPS measurement.

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
controls. It is not in this export or active bitstream build. Mouse protocol
policy, loss-detectable CSR integration and physical UI qualification remain
open; these leaf tests do not close the mouse requirement.

## Retained evidence

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
