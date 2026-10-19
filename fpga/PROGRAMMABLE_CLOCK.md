# One image, runtime core-clock sweep

**Historical measurement/provenance report for `2886d24c`.** For the public
source build use [HOW_TO_RUN_FPGA.md](../HOW_TO_RUN_FPGA.md). The absolute run
paths and old build commands below describe retained original evidence, not
dependencies of the portable source release. They must not be relaunched as-is.

Status (2026-10-17): the congestion requirement is met. The repaired **40 MHz
programmable-clock image** routed in **489.481 s (8 m 09.481 s)**; the complete
resumed implementation/bitgen took **1,406.197 s (23 m 26 s)**, without another
synthesis or processor RTL change. All 224,107 routable nets are fully routed,
zero routing errors; no DRC errors/critical warnings, swap or OOM. The earlier
full-placement attempt exceeded five hours; reusing the verified parent's
physical layout resolved the routing-runtime problem.

The first programmable image routed in 9 m 22 s but failed physical PLL startup.
The clock-only power-sequence repair now **acquires lock on the board**, with
status `504c5499` (divide25, enabled, locked, safe, no error/reset/busy).
The physical CoreMark sweep is now closed: **52.6316 MHz is the highest tested
passing point**, with both standard seeds passing twice. The adjacent available
point, 55.5556 MHz, and 62.5 MHz failed. The board is restored to measured
**39.999820 MHz**, guest held reset, DDR drained, no trial workers running.
This repaired image was programmed once for the entire sweep, with **no
per-frequency images**. Earlier fixed-clock variant attempts were cancelled and
never deployed. Final STA remains **28.701817 MHz conditional worst-path
period budget**, setup −9.841 ns / hold +0.004 ns under the 40 MHz constraint:
not 40 MHz timing sign-off.

The physical fixed-40 MHz parallel-write parent passes both 2,000-iteration
CoreMark seeds, at 2.100118 / 2.106790 CM/MHz. Those passes do not qualify the new
clock image. Its CPU/cache sources are byte-identical to that frozen parent,
including all 159 defines and `cycle_mode(1'b1)`; the dirty CPU checkout is not
ingested. `prepared.json` inventories every frozen file and explicitly lists the
three integration edits and two new clock RTL files. The parent's old manifest
is retained as ancestry, not relabelled a new simulator or hardware pass.

Current verified **physical** gameplay IPC: **0.496499864 total U+V**, image
`2886d24c`, cycles **625,021,130,428–629,480,208,865**; primary/U alone is
0.383002768. The original cold FreeDOS/Quake timedemo completes **969 frames in
125.8 seconds, 7.7 FPS at measured 39.999826 MHz**, with a complete raw-color
movie and successful native closure. See the
[Oct17 Quake report](../docs/FPGA_QUAKE_TIMEDEMO_2026-10-17.md).
This replaces the older simulation baseline 0.490014174 (`b6b92dbf`,
1,100,065,247–3,100,065,247); CoreMark counters are not gameplay IPC.

## Physical CoreMark result

All runs use 4,000 iterations, the full 2 KiB dataset, both unmodified standard
seed configurations, and private-QEMU reference CRCs. Every passing trial has
≥10 seconds of independently clock-measured benchmark execution, exact final
ROM-glyph-decoded console output, five matching CRCs, native owner exit0, stable
input/image hashes and clean reset/drain closure. The failed trials retain exit1
and timeout evidence; they are not passes. No snapshots, STEP, debugger
breakpoints, U-only execution or slow-FSM fallback were used.

| Nominal core MHz (divider) | Measured MHz | Performance seed | Validation seed | CM/MHz, performance / validation |
|---|---|---|---|---|
| 40 (25) | 39.999820–39.999834 | PASS ×2 | PASS ×2 | 2.100127–2.100128 / 2.106796 |
| 50 (20) | 49.999784–49.999785 | PASS | PASS | 2.100127 / 2.106795 |
| **52.631579 (19)** | **52.631352–52.631358** | **PASS ×2** | **PASS ×2** | **2.100126 / 2.106794** |
| 55.555556 (18) | 55.555314 | TIMEOUT | Not run after failure | — |
| 62.5 (16) | 62.499732 | TIMEOUT | Not run after failure | — |

Chronology: pass both seeds at40, pass both at50, fail performance at62.5,
restore40/performance passes, fail performance at55.5556,
restore40/validation passes, then pass both seeds twice at52.6316. Each trial
cold-initializes the same image and resets/relocks its PLL through the mailbox.
The final mailbox change restores divide25, followed by a five-second held-reset
measurement and explicit posted-DDR drain verification (`50440003`). No PCAP
programming occurs between any of these trials or the final restoration.

Each passing trial proves **>415 million fresh V-pipe retirements**, calculated
conservatively from that trial's U+V and bracketed primary/U deltas. Absolute
primary/U totals persist across guest reset; the core's U+V scan counter does
not. Comparing their absolute values across cold boots would be wrong.
The full **159-define** configuration is retained in
`programmable-clock-r3/prepared.json.hardware_defines` and
`programmable-clock-r3/source/defines.txt` (SHA256
`6928307f0b2dae602dffaf53c24ac5b3ed93e62210d211ede86f2ebedccb0032`). It includes
`VEN_SYS_FASTPATH`, `VEN_SYS_FASTPATH_RELOC`, `VEN_SYS_FASTLOAD_FLAT`,
`VEN_SYS_FASTLOAD_BOUNDED` and `VEN_SYS_FASTSTORE_FLAT`, with the frozen shim's
`.cycle_mode(1'b1)` connection. The clock-leaf replacement preserves that SoC
netlist, rather than rebuilding from the dirty checkout.

At62.5, retirement stopped at 886,313 total U+V events; the passive last-retired
EIP was `0x11066`, in `core_list_init`. At55.5556 it stopped at 1,212,459 events,
last-retired EIP `0x10ce3`, near `core_list_mergesort`'s trap path. These are live
monitor observations, not coherent fault-PC snapshots or proof of the failing
instruction. The core stopped advancing for ≥7,486,263,197 / 6,650,013,487 cycles,
respectively. PLL lock and clock-enable remained asserted without PLL error,
and no debugger halt/breakpoint was active. Both failures closed with guest
reset and actual DDR drain verified. Returning to40 recovered the workload.
This is a frequency-associated execution failure; distinguishing setup timing,
CDC/latency-sensitive races or another cause requires further diagnosis. No
processor fix or benchmark-specific workaround was made during the sweep.

**Scope:** 52.6316 MHz is a repeat-tested CoreMark point on this image/board,
not a proven absolute maximum, thermal-soak guarantee, or Quake/Win95 pass.
There is no available integer divider between it and the failed55.5556 point.
Frequencies above62.5, including71.4286, were not tested after these failures;
do not extrapolate the older image's70MHz behavior to this image. The ~31.6%
clock/throughput increase over40 is an overclock result, not a CPU-IPC fix.
The full standard suite remains unqualified for the programmable-clock image.

Evidence root:
`/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/coremark-pll-board-r2/`.
`closed.json` reconciles ten passed trials and two failed trials, their complete
retained-file hashes, exact firmware identity, final clock/reset/drain receipts
and the successful 8m09s route. Per-trial `*-audit.json` files retain counters,
CRCs, timings and native systemd invocation IDs; `*-failure-audit.json` files
retain failed results. `r5-n{16,18}-performance-live-state.json` contains the
additional strictly read-only live debug observations. Raw captures and logs
remain in each corresponding trial directory, both locally and on the board.

## Clock and safety contract

- PS reference and HP0/outer AXI remain **100 MHz**. The single MMCME4_ADV uses
  M=10, D=1, a fixed 1 GHz VCO, and boots with CLKOUT0 divide=25 (**40 MHz**).
- Only CLKOUT0's integer divider changes at runtime: 10..50, or 100..20 MHz.
  Useful points include divide20=50, divide16=62.5, divide15=66.6667,
  divide14=71.4286, divide13=76.9231, divide12=83.3333 MHz. These are actual
  nominal divider frequencies, not rounded claims of an exact 70 MHz clock.
- The new controller runs on the **always-on 100 MHz reference**. Its PS GPIO
  mailbox remains accessible while the controlled clock is gated or relocking.
  The existing AXI management bus itself uses the core clock and cannot serve
  as the PLL's recovery interface.
- Hardware requires guest reset plus real posted-DDR drain and no DDR fault,
  qualified for 32 reference clocks. An unsafe request is rejected without
  stopping the running guest. Software also stops the daemon and checks drain.
- A valid request gates the core clock, resets the MMCM, read-modify-writes DRP
  registers 0x08/0x09, verifies both readbacks, releases MMCM reset, waits for
  stable lock, then enables the clock and acknowledges. Only integer HIGH/LOW,
  EDGE and NOCOUNT fields change. Feedback, VCO, phase, lock/filter settings and
  voltage are untouched. Fractional/CDDC starting states are rejected.
- Before counter access it writes the UltraScale+ DRP power group at **0x27**
  to `0xffff`, as required by XAPP888. The Oct17 source correction keeps that
  value through relock and checks it again after counter readback. Both checks
  use the documented `0x9999` readable-bit mask; reserved bits are not assumed
  readable. This controls internal enables, not voltage. The superseded failed
  image instead wrote `0x0100` before relock; see the investigation below.
- Timeout, readback failure or loss of the safe-change interlock during a change
  leaves the clock gated and MMCM reset asserted. A later valid mailbox request
  can recover without reprogramming. PS reset explicitly rewrites divide25:
  asserting MMCM RST alone does **not** restore its DRP divider registers.

The constraints remain 40 MHz. Successful overclock runs are empirical evidence,
not static timing sign-off or a guarantee for other workloads/temperatures.
Clock-derived platform timer rates also change with overclocking; this experiment
does not claim clock-independent peripheral calibration.

## Mailbox ABI1

The board's `zynqmp_gpio` chip has 78 MIO + 96 EMIO GPIOs. Vivado 2025.2's PS IP
exposes at most 95 EMIO lines in this configuration. Lower EMIO lines are already
kernel-owned LEDs; do not claim them. `ven_pll_clock.py` uses Linux GPIO line
handles, checks chip identity, and claims only these verified-unused lines:

| Direction | EMIO bits | GPIO chip offsets | Payload |
|---|---|---|---|
| PS → PL | 47:32 | 110..125 | 16-bit command |
| PL → PS | 94:64 | 142..172 | status bits30:0; bit31 is constant zero |

Command: bit15 request toggle, bits14:7 magic `0xc1`, bits6:0 divider.
Software first stages the acknowledged toggle with invalid magic, then stages
the payload, waits ≥1 ms, and finally changes only the request toggle. Payload
stays stable through ACK. This avoids synthetic requests even during GPIO
direction setup or non-atomic multi-line writes.

Status: bits31:16 `0x504c`; bits15:14 ABI1; bit13 MMCM-reset; bit12 safe;
bit11 ACK toggle; bit10 locked; bit9 error; bit8 busy; bit7 clock-enabled;
bits6:0 last successfully committed divider. A divider readback alone is not a
clock measurement. Check busy/error/lock/reset and measure actual core cycles.

## Verification and retained build

Run `TMPDIR=/home/yukidama/external/tmp bash fpga/test_programmable_clock.sh`.
It runs a DRP fault BFM and the installed AMD UNISIM MMCME4_ADV/BUFG models under
Icarus, without Vivado synthesis. Every divisor 10..50 is checked, including
actual output period. Coverage includes rejected running-guest requests,
invalid commands, delayed DRDY, DRP/lock timeout, both bad readbacks, safe loss
in every change phase, reset in every phase, stale requests across reset and
40 MHz restoration after an overclock. The fault BFM additionally enforces DRP
power-enable ordering and both power-register readbacks, which the vendor
behavioral model does not enforce. Final passing evidence:
`/home/yukidama/external/tmp/ventium-programmable-clock.OwfH6W`.

Host tooling tests:

```sh
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
  PYTHONPATH=fpga:fpga/board-tools python3 -B -m unittest \
  test_ven_board_debug_contract test_ven_pll_clock test_ven_cold_clock test_ven_coremark_clock_trial \
  test_coremark_clock_media test_coremark_clock_audit
```

The 44 tests pass. They include retained-counter handling and rejecting old
V-retirement history as evidence of pairing in a later trial. Cold preparation
must match the exact prior U count measured while reset was held; the original
fresh-image default still requires zero. Counters are never cleared to make
another seed look newly programmed.
The controller checks the always-on PLL status before opening management MMIO
(even opening it reads IDENT). Failed DRP cleanup first attempts safe GPIO-only
recovery to40; if the clock is unavailable and the interlock disallows recovery,
it skips management MMIO instead of hanging the APU. Recovery is recorded as a
failed trial, never a successful frequency point.
Both 4,000-iteration private-QEMU references also pass (native exit33):
performance CRCs `e9f5/e714/1fd7/8e3a/65c5`, validation
`18f2/e3c1/0747/8d84/5249`. Evidence: `coremark-pll-media-r1`; these are reference
correctness results, not FPGA scores.

Evidence root: `/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4`.
`programmable-clock-r1` is a retained **failed 25-second BD preflight**, not a
synthesis run: the PS IP clamped requested GPIO width96 to95 and the guard
rejected it before `launch_runs synth_1`. `programmable-clock-r2` corrected the
width but its synthesis was deliberately stopped after **920.8 seconds**, native
exit143, before implementation: a further reference-flow check found the missing
DRP power-group setup. The old simulation pass did not prove that requirement.
Its original pins stayed unchanged; logs and generated integration metadata are
retained. No r2 bitstream exists and no deployment occurred.

`programmable-clock-r3` adds that sequence and names the drain output `pll_safe`
so BD inference cannot mistake it for a clock. It is the corrected source build,
owned by `ventium-programmable-clock-oct16-r3.service`, invocation
`fa0d86b28c7840e39ee050af6d348483`. It was deliberately stopped on the user's
new under-four-hour requirement: elapsed **20,131.37 s**, native exit143,
`reason="controller signal"`, all input pins unchanged, **no bitstream**.
The scope is closed and no Vivado worker survived. The runtime sweep uses one
image rather than frequency-specific images. The first completed image's
startup failure requires a clock-only repair before that sweep can begin.
About 1.2 GiB of the closed r2 synthesis cache and obsolete cancelled-variant
physical dump was removed to retain the eight-GiB build admission reserve;
source freezes, reports, native logs and the original routed DCP remain.

`run_programmable_clock_build.py` uses the mandatory exclusive Vivado launcher,
one worker, 20 GiB RAM / 8 GiB swap limits, a six-hour bound, live 4 GiB disk and
2 GiB host RAM/swap stop floors. Fresh source/launcher pins and native results
are recorded; no automatic retry or deployment occurs. The unchanged previous
implementation profile is retained, including RuntimeOptimized opt_design.
New board helpers and 4,000-iteration media are staged separately at
`/dev/shm/ventium-coremark-clock-stage.3gpcEfvD`; the old passing evidence is not
overwritten. Host evidence will be retained in `coremark-pll-board-r1`.

### Congestion diagnosis and physical-layout retry

The original route used `AltSpreadLogic_high` placement and default routing,
just like its fixed-clock parent. It did not fail from OOM: its OOM counters
remained zero. Peak scope RAM was 9,568,305,152 bytes; later host activity caused
up to 2,721,914,880 bytes of swap. The router remained CPU-active. Merely waiting
longer is not the selected response to the user's new runtime requirement.

The native reports and read-only checkpoint audit show:

| Measure | Fixed-40 parent | Programmable r3 |
|---|---:|---:|
| Placed LUTs | 185,922 | 186,075 |
| Placed registers | 54,769 | 54,919 |
| Occupied CLBs | 33,510 (78.55%) | 34,247 (80.28%) |
| Initial global/short congestion level | 6 | 6 |
| Initial timing-congestion level | 6 | 7 |
| Cumulative route time at end of Global Iteration 1 | 45 m 19 s | 4 h 17 m 20 s |
| Overlaps at that point | 0 | 628 |

r3's second iteration subsequently reported **193,450 overlaps**. The earlier
628 count was not a measure of total work remaining.

`audit_programmable_congestion.tcl` reads the parent's routed DCP and r3's
post-place-physopt DCP without modifying either. It maps native routing-tile
hotspot rectangles to their actual placed cells, using tile/site queries rather
than assuming routing coordinates equal slice coordinates. In the sampled
short-route hotspot rectangle **X4..47, Y272..320**:

- I-cache primitives increased from **16,157 to 20,058** (+24.144%).
- The I-cache occupies **89.361%** of the candidate's 22,446 primitives there,
  versus 71.145% of the parent's 22,710 primitives in the same rectangle.
- No clock-controller cells appear in that rectangle.
- The whole I-cache remains **44,931 LUTs, 10,783 registers and eight BRAM36s**
  in both inspected checkpoints. Its RTL and resource implementation did not
  grow. Total placed LUT growth for the complete design is only **0.0823%**.

This supports a **placement-sensitive I-cache connectivity bottleneck**, not a
large area cost from the programmable PLL. Cell counts alone are not routing
utilization; the native congestion report supplies that separate evidence.
The broader south hotspot contains 80,851 candidate primitives, including
50,185 I-cache and 9,548 register-file primitives. The candidate's sampled east
hotspot grows from 2,075 to 3,213 primitives, chiefly register-file/core/cache
logic. Global control sets grow only from 2,448 to 2,456.

Audit evidence: `programmable-clock-congestion-r1`, unit
`ventium-programmable-congestion-oct16-r1.service`, invocation
`e1426f5f04774e348c2e2c907ab834f1`; native exit0, **110.21 s**, input pins
unchanged, no swap/OOM. It retains per-cell TSVs, per-hierarchy region counts,
clock/utilization/control-set reports and hashes. The exact reference DCP SHA256
is `c932cefb2909e0934c83d105fc8aaebc3e51beb0c2b899b43738462eb54d76a5`.

The selected retry is `launch_programmable_incremental.tcl`, guarded by
`run_programmable_incremental.py`, with current output `programmable-clock-reuse-r2`:

1. Open **r3's existing optimized netlist**, including its implementation XDCs.
   No synthesis, source substitution, cache resizing or CPU change.
2. Import only matching physical placement/routes from the verified parent with
   `read_checkpoint -incremental -force_incr -directive RuntimeOptimized`. Do not use
   `-auto_incremental`, which can choose a full implementation instead.
3. Require at least **95% matched primitive cells** and **90% reused placements**
   both before and after incremental placement. Abort on insufficient reuse;
   do not silently perform another full placement experiment.
4. Keep 40 MHz core / 100 MHz AXI constraints and the M10/D1/divide25 MMCM
   contract. Preserve the reference setup target rather than asking a
   timing-closure directive to rip up the entire old solution.
5. Cap the **whole native invocation at 13,800 s (3 h 50 min)**, with one worker,
   12 GiB RAM / 4 GiB swap, and the existing live disk/host-memory guards.
   Record route wall time independently and reject any result at or above four
   hours. Require all routable nets routed, zero routing errors and no DRC
   errors/critical warnings before accepting the products.

The first reuse attempt launched as `ventium-programmable-reuse-oct16-r1.service`, invocation
`808780de602e4e30b36603cf1c995608`, using committed implementation scripts
`e2ad22ae`. Its source/physical-input hashes and live resource records are in
`programmable-clock-reuse-r1/{started.json,watch.jsonl}`. It closed after **50.04 s**
with native exit1 and unchanged inputs, before placement or routing. Vivado
reported `Constraints 18-6519`: reference WNS -9.841 ns is below its -1 ns
incremental threshold. Despite omitting `-auto_incremental`, the tool switched
to full implementation. The explicit reuse guard stopped that fallback:
**97.199448% matched**, **0% reused** of 295,049 primitives.

r2 explicitly adds `-force_incr`, as recommended by the native diagnostic and
[AMD's documented override](https://docs.amd.com/r/en-US/Vivado-Design-Suite-User-Guide-Implementation-UG904/Further-Options?contentId=0boU4mD1KVUZkTYtvKq6kw).
This selects the incremental algorithm; it does not waive the independent
95%/90% reuse thresholds, routing/DRC gates, unchanged clock constraints,
runtime/resource limits, or the absence of STA sign-off. The prior native
diagnostic and closure are hashed inputs to the next attempt. No second
full-placement or synthesis run occurred in r1.

r2 completed as `ventium-programmable-reuse-oct16-r2.service`, invocation
`2eb46d56f5df421694a34f5bcefc0317`, using scripts committed as `a217a092`.
The actual physical import replays all 162 reference physical optimizations.
The initial independent primitive-cell gate passes: 295,409 primitives,
**97.205569% matched / 99.496969% reused placements**. The native reuse report
has **0.17% wholly unreused nets** and **0.01% partially reused nets**. This
is import evidence, not completed routing or a hardware pass. Incremental
placement subsequently completed in **7 m 46 s** with zero warnings/errors,
preserving the same **99.496969%** primitive-placement reuse. Both 40/100 MHz
clock guards pass after placement. Routing started at Unix milliseconds
`1792208801317` and completed after **561,805 ms**. Native `route_design`
finished successfully with zero errors/critical warnings. The final route
report has **224,099 / 224,099 routable nets connected, zero routing errors**.
The router retained **223,286 fully reused nets (99.64%)** and rerouted 807;
its initial overlap sequence was **117 → 17 → 5 → 0**. This meets the user's
strict under-four-hour routing requirement.

Final occupied CLBs are **33,528 (78.59%)**, compared with r3's 34,247 (80.28%)
and the parent's 33,510 (78.55%). The final DRC has no errors/critical warnings;
DSP pipelining and unused vendor-IP net warnings remain visible. Final timing
reports preserve **40 MHz core / 100 MHz AXI** constraints and give a
**28.701817 MHz conditional core-period budget**, setup -9.841 ns / hold
+0.004 ns, identical to the parent's final estimate. This is **not** 40 MHz
STA sign-off. The router's intermediate -10.018 ns estimate is superseded by
the explicit post-route timing report. The always-on 100 MHz domain has setup
+5.935 ns / hold +0.012 ns; the two cross-clock setup minima are +0.113 and
+1.187 ns. The core's negative slack does not explain a pre-guest lock timeout.

Native exit is zero, input pins and all product hashes were independently
rechecked, peak scope RAM was 7,828,574,208 bytes, and scope swap/OOM were zero.
The scope and controller are closed; no Vivado process remains from this run.

| Product | SHA256 |
|---|---|
| `build/ventium_programmable_clock_40.bit` | `c1786ad0824b92f437c4eb7326577633653ddd3e03eda3b5a6fea4d01f6ceab2` |
| `build/ventium_programmable_clock_40.bin` | `b9cd2144880c9bdf5f85988801fb4c45f9d59eda15e6d6105dac329c81778a45` |
| `build/routed.dcp` | `602323bae23a5c22c746c10fd62f7ed8bee51923432586fb6ccc6c2338d46ebc` |

The additional eleven host tests pass (55 including the existing host suite).
They check partial routes, routing/DRC errors, wrong clocks, insufficient reuse,
duplicate counters, the strict runtime boundary and the native Tcl reuse-JSON
format. These tests do not qualify an FPGA image. Implementation passed its
routing/product gates; physical clock qualification has **not** passed.

AMD references: [incremental flow](https://docs.amd.com/r/2025.2-English/ug908-vivado-programming-debugging/Using-Incremental-Compile?contentId=LhXjyw_bq5zL1yBpwdGDlw),
[reuse object properties](https://docs.amd.com/r/2023.2-English/ug904-vivado-implementation/Object-Properties),
[RuntimeOptimized versus TimingClosure](https://docs.amd.com/r/2024.2-English/ug904-vivado-implementation/Incremental-Directives?contentId=GHAkvNCSWOZrYoe0PqJ2sg).

### First deployment: lock-acquisition failure

After guest reset and posted-DDR drain, the raw binary was installed as
`/lib/firmware/ventium_programmable_clock_40_oct16_reuse2.bit.bin`. Its board hash
matches the table above. The normal board loader returned zero and FPGA manager
reported `operating`. That confirms programming, **not a working core clock**.
The old fixed-clock firmware and accepted evidence were preserved.

The first GPIO-only status was `0x504c6219`: error, not busy, reset asserted,
clock gated, unlocked, divider25. No core-clocked MMIO (including IDENT) or
guest daemon was opened afterward: those accesses can hang when this clock
is stopped. Board Linux still reports the PS reference at approximately
99,999,999 Hz.

`board-tools/ven_pll_reset_probe.py` performs a narrowly guarded, same-image
whole-fabric reset diagnostic, not a normal clock-sweep operation. Generated
PS HDL explicitly maps `pl_resetn0` to EMIO95, Linux GPIO offset173. The helper
claims only that unused line, requires the pinned failed image/status and no
daemon, and releases reset even if the held-reset witness fails. It does not
reprogram or access management MMIO. Four host tests cover its safeguards.

Two probes failed identically; the second retained transitions:

| Time after reset release | Status | Meaning |
|---|---|---|
| Before release | `504c6119` | Controller reset reached; busy, MMCM reset asserted |
| 105.9 microseconds | `504c4119` | All DRP writes/readback checks completed; reset released, waiting for lock |
| 168.153 milliseconds | `504c6219` | Lock-wait timeout; reset reasserted and output remains gated |

The timeout matches 2^24 reference cycles (167.772 ms). This localizes failure
to lock acquisition, not a stuck DRP response or failed readback. It does not
yet identify the analog/configuration cause. The vendor behavioral-model pass
was insufficient to prove physical startup. Current investigation compares
the synthesized feedback path and DRP sequence against the vendor flow; no
processor change or speculative full synthesis has been launched.

Evidence: `coremark-pll-board-r1/{program.log,pll-initial.json,
preprogram-quiesce.json,pll-reset-probe-r1.json,pll-reset-probe-r2.json}` under
the evidence root. No new gameplay or CoreMark score exists for this image.

### Oct17 power-sequence correction (not yet physically verified)

Review of AMD's installed Vivado 2025.2 reference implementations found no
post-configuration write of `0x0100`. Clock Wizard's
`data/ip/xilinx/clk_wiz_v6_0/ttcl/mmcm_pll_drp_v.ttcl` programs the power group
to all ones, completes its counter/filter sequence, and releases reset. The
MMCM path in `data/embeddedsw/XilinxProcessorIPLib/drivers/vphy_v1_15/src/
xvphy_mmcme4.c`, `XVphy_MmcmWriteParameters`, likewise leaves it enabled.

The local controller had introduced an additional full-word restore inferred
from UG572's documented interpolator fields. That was not a saved original
register value and did not follow the shipped reconfiguration sequence.
The narrow correction retains `0xffff` through lock, leaving counter values,
feedback, clock gating, timeout and safe-change checks unchanged. This is a
reference-flow correction and a leading fault hypothesis, **not yet proof of
the physical failure's cause**. No processor/cache source is changed.

New BFM assertions reject any power write other than `0xffff`, and separately
inject failure into the first and final power readbacks. All 41 dividers,
safe-loss/reset phases and the AMD behavioral period checks pass in
`/home/yukidama/external/tmp/ventium-programmable-clock.AkDdO8`. Running the new
BFM against the old controller fails at the forbidden restore (native exit1,
`old-power-mutant.log`). The 59 host tests also pass. None replaces silicon
qualification; deployment remains the original failed image until a scoped
clock-only repair has been built and its products checked.

The read-only routed-leaf audit completed in **125.224 s**, native exit0,
unchanged input hashes, no swap/OOM (`programmable-clock-netlist-audit-r3`).
The feedback BUFGCE is permanently enabled in both parent and candidate;
both MMCMs resolve to `COMPENSATION=BUF_IN`. Input, feedback and DRP clocks
are connected as intended. This rejects the simple gated-feedback deadlock
hypothesis; it does not prove analog lock. Earlier audit r1 was deliberately
stopped after an over-broad constant-net traversal; r2 failed on a report
API expecting one object. Neither modified or programmed a checkpoint.

The first repair preflight (`programmable-clock-power-repair-r1`, owner
`ventium-clock-power-repair-oct17-r1b.service`, invocation
`6cb3cc1e57064fb592a1f1a7b60b5ffa`) verified strict replacement and identical
122-module SoC exports, SHA256
`4b04a2a4babfc433e07a0f0f6c1858de0add1e8eb680b51a9d5495572a3ceb05`.
It then stopped before placement because the Icarus child inherited Vivado's
older `libstdc++`; native exit1 after 100.085 s, inputs unchanged. The child
wrapper now clears `LD_LIBRARY_PATH`/`LD_PRELOAD`, leaving Vivado's own runtime
untouched. The repaired synthesized netlist passes all 41 divider periods,
power-write checks, unsafe-command rejection and reset restoration, both from
a normal shell and with the vendor library path deliberately injected.

The second preflight (`programmable-clock-power-repair-r2`, invocation
`d72b5f73f4ba429f9924362b80dc62f3`) passed the native netlist simulation but
stopped before placement because the service PATH did not contain `rg` for
the final success-marker check. It closed at 105.091 s, native exit1, unchanged
pins. The marker check now uses system `grep`; the full wrapper passes under
`env -i PATH=/usr/bin:/bin` with the vendor library path injected.

The third preflight (`programmable-clock-power-repair-r3`, invocation
`231b6c58b6eb4585b54d16664980e436`) passed both the unchanged-SoC and native
clock-netlist gates. It stopped at the raw primitive matching gate, before
placement: **97.288945% raw matched / 99.586013% placements reused**. That
99%-raw-match threshold was inappropriate for this checkpoint's primitive
object accounting: the prior successful route already had the same discrepancy.
The native canonical table independently reports **99.96% cells matched /
99.97% cells reused**, and **99.97% nets matched / 99.91% nets reused**. Native
exit1, 285.239 s, unchanged pins, no swap/OOM; retain this as a failed preflight,
not a routing failure or a completed implementation.

`programmable-clock-power-repair-r4`, owner
`ventium-clock-power-repair-oct17-r4.service`, invocation
`62b4ab21ab7c40038a434273c7bd56ec`, resumes r3's **verified `replaced.dcp`**.
It verifies all prior products and frozen source hashes, reruns SoC equality
and the clock-netlist test, and does not repeat synthesis. Gates now explicitly
distinguish the two metrics: raw primitive matching ≥95%, actual primitive
placement reuse ≥99%, and **native canonical cell/net matching and reuse each
≥99.5%**, before and after placement. Missing/duplicate rows, impossible
percentages and missing-design totals are regression-tested (67 host tests
total). This is not permission to fall back to full placement.

r4 subsequently closed at **695.597 s**, native exit1, unchanged pins: placement
completed, but the canonical reuse parser did not handle Vivado's post-placement
addition of an **Initial Reuse** column. The actual current reuse remained
**99.97% cells / 99.91% nets**. This was a host parser failure, not poor reuse or
a router failure; routing did not start. Peak RAM 6.52 GiB, swap 279.1 MiB,
no OOM. No placed checkpoint was saved by that version of the script.

`programmable-clock-power-repair-r5`, owner
`ventium-clock-power-repair-oct17-r5.service`, invocation
`fe03a34d61cb4862851efe5d13667774`, resumes r4's pinned pre-placement replacement
without synthesis or RTL changes. The parser now recognizes the two exact
native headers and reads **Current Reuse** by column name; both initial and
current percentages remain subject to the same threshold. Regressions include
a falling current-reuse value despite a passing initial value, malformed headers,
and column-count mismatches (71 host tests pass). The flow now saves `placed.dcp`
immediately after placement, before report parsing. No repair-image routing or
hardware pass is claimed by these preflights.

The initial 10-GiB-RAM admission attempt
was rejected before Vivado started; the admitted run uses an **8 GiB RAM /
4 GiB swap** cap and retains two GiB of host headroom at admission. Live
two-GiB host RAM/swap and four-GiB disk stop floors remain. Its entire native
run is bounded to 3 h 50 min, with no frequency variants or CPU synthesis.

Only the small clock leaf is synthesized (12 s), then inserted into the
existing routed checkpoint through a **strict port match**. Vivado optimized
the original 95-bit GPIO boundary to eight divider/lock bits and six control
bits; the adapter is derived from that exported netlist, not guessed. All
16,384 dynamic status combinations round-trip through the adapter test.
Before implementation, the flow requires identical before/after logical SoC
exports, including every attribute and statement (only comments/blank lines
are omitted from the comparison). It also tests the actual synthesized leaf
with AMD primitive models. The separate raw/canonical reuse gates above
are required before and after placement. The same netlist test is repeated
after routing; complete routes, DRC, clocks, runtime and product-hash checks
remain mandatory. The old routed leaf fails the new power-sequence regression
as expected. No repair-image
hardware result is claimed until deployment and CoreMark qualification.

### Repaired implementation closure and deployment

`programmable-clock-power-repair-r5/closed.json`: native exit0, passed, all input
pins unchanged; independent rehash of every pinned source and generated product
also passed. Whole run 1,406.196775 s, route 489.481 s. Peak cgroup memory
7,334,637,568 bytes, no swap or OOM. The placed checkpoint is retained. Native
post-placement cell reuse is 99.97%, net reuse 99.91%; actual router fully reused
223,933 nets (99.93%). Both pre-place and post-route exported clock netlists pass
all 41 frequencies and reset/interlock/power-sequence tests. The 122-module
SoC logical export remains identical across the clock-leaf replacement.

Artifact SHA256:

- `.bit`: `217cb6f1548a4b710a8f1f44d9fe9f58999c868e4f320f462be13156a3c0f21d`
- raw `.bin`: `2886d24c5f9c84219f54e23a4766cfb7106f2999d28e794a0fd00256fd60cc52`
- routed DCP: `b38e8bd49d8327eb6497146016e252703f9e90235957e903ec85f932fec41d17`

The board firmware is
`/lib/firmware/ventium_programmable_clock_40_oct17_power_r5.bit.bin`.
Programming and initial GPIO status are retained under
`coremark-pll-board-r2/{power-r5-program.log,power-r5-pll-initial.json}` in the
evidence root. The prior failed image never enabled its core clock; its earlier
DDR-drain receipt and unchanged board boot ID were checked, and no core-clocked
MMIO was accessed while its PLL was stopped. The repaired image was programmed
once, then its healthy GPIO status was required before starting CoreMark.
This is physical confirmation that retaining the full power-enable word fixes
the observed startup failure; overclock/standard-suite acceptance is separate.

## Physical procedure (repeatable clock qualification)

1. Verify native completion, output/source hashes, routed clocks, route and DRC
   reports. Retain setup/hold failures honestly; overclock tests do not waive them.
2. Stop the board daemon, hold guest reset and drain DDR. Program the new raw
   binary **once**, retain the programming receipt and image hash. Do not
   reprogram between seeds or frequencies.
3. On the matching image, `sudo python3 ven_pll_clock.py` reads status only.
   After reset/drain, `sudo python3 ven_pll_clock.py --divider 14` requests
   71.4286 MHz; `--divider 25` restores 40 MHz. No PS PL0 or voltage changes.
4. Use `ven_coremark_clock_trial.py run --pll-divider N --expected-mhz F ...`.
   It changes the PLL with reset/drain held, independently measures the clock
   over five seconds, cold-initializes memory/BIOS/media, runs normally in
   UV+fast mode, records passive counters and exact ROM-glyph-decoded video,
   and returns to guest reset/drained state. It does **not** program the FPGA.
5. Use both 4,000-iteration standard seeds, keeping the full 2 KiB dataset.
   This gives ≥10 real seconds even near 100 MHz; do not use the port's printed
   40 MHz-calibrated seconds to grade an overclock. Generate same-iteration
   private-QEMU CRC references with `prepare_coremark_clock_media.py
   --iterations 4000`. Record actual physical duration from raw TSC ticks and
   independently measured frequency, all five CRCs, lock, temperature and
   unperturbed U+V execution. The audit subtracts each trial's counter baseline;
   guest reset does not clear the board's cumulative **primary/U** counter.
   The core's total-U+V scan counter does reset; never subtract these two
   absolute counters across cold boots. The audit subtracts each one's own
   first observation within the current trial before comparing their deltas.
6. Start with both seeds at 40 MHz on this image, step upward, then repeat/refine
   the boundary. Stop at the first failed point, restore40 via the same mailbox,
   and rerun a baseline to distinguish persistent damage/state from a frequency
   failure. Retain failed results; do not bypass an interlock or use slow/U-only
   execution to manufacture a pass.

Repeated cold boots do not require PCAP to invalidate the cache path. In the
frozen source, the management reset drives `soc_reset = rst | ~core_reset_n |
dbg_frozen`, then `system.reset` and the ao486 L2's `RESET`. Its reset edge starts
a complete tag/LRU initialization walk, and `CPU_BUSY` blocks requests through
both reset stages and `START`. Thus the five-second held-reset clock measurement
also leaves ample time for that walk before the daemon rewrites guest RAM.
The posted-DDR transport deliberately survives guest reset: software and the
PLL interlock require its actual completion/drain, not cancellation. Debug
primary/U debug retirement counter also survives, whereas `ventium_top.retire_n`
(total U+V) clears with core reset. Each trial subtracts its own counter baselines.
This is a source-level reset-path check, not a substitute for passing both
physical seeds repeatedly on the new image.

CoreMark clock qualification is not standard-suite acceptance. The subsequent
[physical Quake timedemo at 40 MHz](../docs/FPGA_QUAKE_TIMEDEMO_2026-10-17.md)
passes; physical Win95 cold boot + interaction remains unqualified for this
image. Quake was not tested at the higher CoreMark-qualified clocks.

Register reference: [AMD UG572 MMCM registers](https://docs.amd.com/r/en-US/ug572-ultrascale-clocking/MMCM-Registers)
and [DRP operation](https://docs.amd.com/r/en-US/ug572-ultrascale-clocking/Dynamic-Reconfiguration-Port).
The power-enable prerequisite is in [XAPP888, Power Group/Table14](https://docs.amd.com/api/khub/documents/ZY272QvKAP3T95qOg6QhDg/content).
