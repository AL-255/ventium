# FPGA APR Strategy Comparison — 40 MHz Target (`xczu15eg-ffvb1156-2-i`)

> **Verified Gameplay IPC & Qualification Status:**
> - **Current board-qualified `main` release (`c0e3fe43`, 2026-11-14):**
>   **`0.515778001` total U+V IPC** (`0.397847833` primary/U-only IPC) across
>   physical DOS Quake interior gameplay cycles **`28,696,827,616–32,989,404,795`**
>   (`8.0 FPS` `demo1`, `969` frames / `121.2 s` at measured `39.999802 MHz`,
>   `161` defines, `cycle_mode=1` U/V + fast-pipe; counters include `REP`-element
>   retirement). Post-route slow-corner STA is signed off at **`40.264133 MHz`**
>   (`WNS = +0.164 ns`, `WHS = +0.010 ns`).
> - **Prior physical release baseline (`2886d24c`, 2026-10-17):**
>   `0.496499864` total U+V IPC (`0.383002768` primary/U-only) across cycles
>   `625,021,130,428–629,480,208,865` (`7.7 FPS` `demo1`; `-9.841 ns` WNS /
>   `28.702 MHz` post-route estimate).
> - **Isolated pre-RTL-relief APR sweep candidates (`experimental/uv-fast-ipc-apr`,
>   commits `a8e5d6bf`..`5c630403`):** **Gameplay IPC unmeasured** (never deployed
>   to hardware; pre-`c0e3fe43` `200`-file / `159`-define source freeze). No
>   Vivado/VRS worker remains active; do not restart background builds automatically.

This document summarizes both:
1. The **40.264 MHz STA-closed `c0e3fe43` release recipe** published on `main`, and
2. The **controlled fresh-source Vivado 2025.2 APR strategy sweep** on
   `experimental/uv-fast-ipc-apr` that isolated the winning `retime_muxf_route_first`
   flow prior to RTL congestion relief.

---

## 1. `main` Release Closure: Image `c0e3fe43` (`40.264133 MHz` STA Sign-Off)

Pairing the winning fresh-source **`retime_muxf_route_first`** implementation
recipe with targeted RTL fanout and mux-width reductions on the **161-define**
Tier-1 P54C profile (`fpga/known_good_c0e3fe43.json`) achieved full slow-corner
static timing closure at the `40.000 MHz` (`25.000 ns`) core clock constraint on
**RK-XCZU15EG-F** (`xczu15eg-ffvb1156-2-i`, Vivado **2025.2**):

### Winning Implementation Flow (`retime_muxf_route_first`)

- **Synthesis:** `synth_design -directive PerformanceOptimized -flatten_hierarchy rebuilt -global_retiming on`
  (`AUTO_INCREMENTAL_CHECKPOINT=0`, IP cache disabled, fresh source only).
- **Logic Optimization:** `opt_design -directive RuntimeOptimized` (retaining
  the BRAM power-opt crash workaround) followed immediately by explicit
  **`opt_design -muxf_remap`** to dissolve dense `MUXF7`/`MUXF8`/`MUXF9` trees
  into routable 6-LUTs before placement.
- **Placement & Routing:** `place_design -directive AltSpreadLogic_high` and
  `route_design -directive AlternateCLBRouting`, with standalone pre/post-route
  `phys_opt_design` disabled (`8` internal threads per stage, `-jobs 1`).

### Paired RTL Fanout & Congestion Cuts in `c0e3fe43`

1. **Explicit `pf_fill_addr_rep[0..3]` fanout tree replication**, eliminating the
   prior `3,024`-sink broadcast bottleneck (`1.238 ns` single-net delay in `2886d24c`).
2. **Narrow 32-byte `ic_res_line_base` pre-selection**, replacing wide 64-byte
   instruction-window mux cones inside `u_icache`.
3. **One-hot associative TLB hit-way factoring** (`VEN_ITLB_ASSOC_4WAY` + 4-way
   D-TLB) and **16-slot posted-DDR4 CAM read-after-write bypass**
   (`ven_ddram_axi_posted.sv`).

### Post-Route QoR Summary (`c0e3fe43` vs. `2886d24c`)

| Metric (`xczu15eg-ffvb1156-2-i`, Vivado 2025.2) | `c0e3fe43` (`main` Release) | `2886d24c` (Prior Baseline) | Delta |
| --- | ---: | ---: | ---: |
| **Core Clock Constraint (`mmcm_clk`)** | `25.000 ns` (`40.000 MHz`) | `25.000 ns` (`40.000 MHz`) | — |
| **Post-Route Core WNS / WHS** | **`+0.164 ns` / `+0.010 ns`** | `-9.841 ns` / `+0.004 ns` | **`+10.005 ns` WNS** |
| **Post-Route Core Fmax (STA Budget)** | **`40.264133 MHz` (SIGNED OFF)** | `28.701817 MHz` (failing STA) | **`+40.28%`** |
| **Failing Endpoints (Setup / Hold / CDC)** | **`0 / 0 / 0`** | Failing core setup | Closed |
| **CLB LUTs Used** | **`171,819 / 341,280` (`50.35%`)** | `186,086` (`54.53%`) | `-14,267` LUTs |
| **Occupied CLB Sites** | **`30,703 / 42,660` (`71.97%`)** | `33,528` (`78.59%`) | `-2,825` CLBs |
| **CLB Registers (FFs)** | **`39,520 / 682,560` (`5.79%`)** | `55,190` (`8.09%`) | `-15,670` FFs |
| **BRAM36 Tiles / DSP48E2 Slices** | `277.5` (`37.30%`) / `47` (`1.33%`) | `277.5` / `47` | `0` / `0` |
| **Routable Nets Connected** | `216,790 / 216,790` (`0` errors) | `224,099 / 224,099` (`0` errors) | `100%` legal |
| **Final `>=85%` Congestion Windows** | **`0` hotspots** | Regional `u_icache` peak `90.37%` | **100% cleared** |
| **Global Routing Utilization (V / H)** | **`22.45%` / `21.05%`** | `28.32%` / `27.54%` | `-5.87%` / `-6.49%` |
| **Worst Core Setup Data Delay** | **`24.522 ns`** (`6.836` logic + `17.686` route, `76` levels) | `34.711 ns` (`89` levels) | `-10.189 ns` |

- **Worst `c0e3fe43` Setup Path:** `u_core/q_pc_reg[2]/C` &rarr;
  `u_l1axi/u_l1d/u_pair_return/data_q_reg[1][21]/D` (`+0.164 ns` slack).
- **PS / AXI `clk_pl_0` (`100.000 MHz`, `10.000 ns`):** `WNS = +5.691 ns`, all
  10 Gray-code CDC bus-skew constraints passing.
- **Reference Hashes & Floorplans:** Raw bitstream
  `c0e3fe43b2b7ce88e013df107be94d56c0fcfcae626ce4c262975fba92dcc3b7`, routed
  checkpoint `2bd41907b5f87343078d47d1a62895129dcf511a804442c5e876cf9d2f9ce44b`.
  See [`PUBLIC_FPGA_RELEASE_2026-11-14.md`](PUBLIC_FPGA_RELEASE_2026-11-14.md)
  and [`FPGA_PHYSICAL_MAP_2026-11-14.md`](FPGA_PHYSICAL_MAP_2026-11-14.md).

---

## 2. Isolated Fresh-Source APR Strategy Sweep (`experimental/uv-fast-ipc-apr`)

Before the RTL fanout cuts in `c0e3fe43`, a controlled Vivado 2025.2 strategy
matrix was executed on `experimental/uv-fast-ipc-apr` (commits through
`a8e5d6bf`..`5c630403`) to measure how much setup margin APR directives alone
could recover on an **unchanged 200-file / 159-define pre-relief RTL freeze**
(`cycle_mode=1`, `25.000 ns` core / `10.000 ns` AXI constraints, zero checkpoint
reuse).

### Execution Safeguards & Early Rejected Flows

All runs launched exclusively via `fpga/run_vivado_exclusive.sh`
(`fpga/run_fresh_strategy.py` + `fpga/fresh_strategy.tcl` + independent
`fpga/audit_fresh_result.py`) under `/home/yukidama/external/tmp` with uncapped
RAM/swap (`MemoryMax=infinity` per Oct 19 host policy), `TasksMax=256`, `3h50m`
implementation deadline, and `8h` whole-run guard:

1. **Incremental Checkpoint Flows Rejected (`aggressive-r1..r3`):** Re-opening
   `2886d24c`'s routed checkpoint without `-force_incr -directive TimingClosure`
   was a `642 ms` policy no-op because Vivado inherited the prior
   `RuntimeOptimized` `-10.018 ns` WNS target; checkpoint-based ECO trials were
   retired in favor of reproducible fresh-source builds.
2. **`ExtraNetDelay_high` + Standalone `phys_opt_design` Rejected
   (`performance-r4`, `routability-r4`, `performance-bounded-r1`):**
   - `Performance_NetDelay_high`-style trials (`ExtraNetDelay_high` placement +
     `phys_opt_design -directive AggressiveExplore` + `NoTimingRelaxation`
     routing) exhausted the `3h50m` implementation budget before routing
     (`45m45s` of critical-cell replication improved estimated WNS by only
     `0.011 ns`).
   - Bounded explicit physical optimization
     (`phys_opt_design -fanout_opt -placement_opt -restruct_opt -equ_drivers_opt`,
     `performance-bounded-r1`) gained only `0.094 ns` estimated WNS over
     `57m50s` and triggered a Vivado 2025.2 `SIGSEGV` inside
     `DcpWriter::exportXdef` (`libxv_constraints.so`) when writing `physopt.dcp`.
     Disabling standalone `phys_opt_design` (`route-first` flow) eliminated both
     the runtime blowup and the checkpoint serializer crash.
3. **Unremapped `PerformanceOptimized` Failed Routing Legality
   (`performance-route-first-r1`, `performance-retime-routability-route-first-r1`):**
   - `PerformanceOptimized` synthesis improved unplaced core timing
     (`38.068–38.445 MHz` vs. `34.457 MHz` for `AlternateRoutability`) and cut
     LUTs (`185,897` vs. `194,049`), but emitted **`17,814` `MUXF7` + `6,840`
     `MUXF8` + `96` `MUXF9`** primitives (`15.3x` the `AlternateRoutability`
     MUXF count).
   - Dense MUXF packing created `462–609` high-pin-utilization CLBs and
     saturated local `u_icache` routing (`99.99%` South congestion / `21,350`
     overlapping nodes under `NoTimingRelaxation`; still `96.30%` East /
     `93.03%` South and `2,294` illegal overlaps even with `AltSpreadLogic_high`
     + `AlternateCLBRouting`).
   - Inserting **`opt_design -muxf_remap`** (`24,750` &rarr; `2,400` MUXFs,
     `+21,440` 6-LUTs pre-place) completely restored 100% legal routing in
     `40m30s` while preserving `PerformanceOptimized` synthesis depth.

### Matched Fresh-Source Strategy Matrix (159-Define Pre-Relief Freeze)

| Strategy ID | Synthesis (`rebuilt`) | Pre-Place `opt_design` | Placement | Routing | Legal Route? | Core WNS / WHS (`25 ns`) | Conditional Core Est. | Disposition |
| --- | --- | --- | --- | --- | :---: | ---: | ---: | --- |
| `performance-route-first` | `PerformanceOptimized`, retime off | `RuntimeOptimized` | `AltSpreadLogic_medium` | `NoTimingRelaxation` | **NO** (`21,350` overlaps) | — | Illegal route | Rejected (local `MUXF` pin saturation) |
| `routability-route-first` | `AlternateRoutability`, retime off | `RuntimeOptimized` | `AltSpreadLogic_high` | `AlternateCLBRouting` | Yes (`253,747` nets) | `-7.228 ns` / `+0.010 ns` | `31.028919 MHz` | Superseded |
| `routability-retime-route-first` | `AlternateRoutability`, retime **on** | `RuntimeOptimized` | `AltSpreadLogic_high` | `AlternateCLBRouting` | Yes (`253,658` nets) | `-4.160 ns` / `0.000 ns` | `34.293553 MHz` | Superseded (`+10.52%`, `42m42s` route) |
| `routability-retime-remap-route-first` | `AlternateRoutability`, retime **on** | `+ -resynth_remap` | `AltSpreadLogic_high` | `AlternateCLBRouting` | Yes (`254,014` nets) | `-6.329 ns` / `+0.011 ns` | `31.919308 MHz` | Rejected (`-6.92%` vs. control) |
| `performance-retime-routability-route-first` | `PerformanceOptimized`, retime **on** | `RuntimeOptimized` (no MUXF remap) | `AltSpreadLogic_high` | `AlternateCLBRouting` | **NO** (`2,294` overlaps) | — | Illegal route | Rejected (`17.8k` `MUXF7` / `6.8k` `MUXF8`) |
| **`performance-retime-muxf-route-first`** | `PerformanceOptimized`, retime **on** | **`+ -muxf_remap`** | **`AltSpreadLogic_high`** | **`AlternateCLBRouting`** | **Yes (`266,839` nets)** | **`-2.983 ns` / `+0.011 ns`** | **`35.735983 MHz`** | **Accepted APR baseline (`a8e5d6bf`)** |
| `performance-retime-muxf-timing-route-first` | `PerformanceOptimized`, retime **on** | `+ -muxf_remap` | `ExtraTimingOpt` | `AlternateCLBRouting` | Yes (`266,730` nets) | `-3.406 ns` / `+0.001 ns` | `35.203830 MHz` | Rejected (`-1.49%`, `+669` CLBs, `7f0b22e8`) |
| `performance-retime-muxf-explore-route-first` | `PerformanceOptimized`, retime **on** | `+ -muxf_remap` | `AltSpreadLogic_high` | `Explore` | Yes (`266,839` nets) | `-2.983 ns` / `+0.011 ns` | `35.735983 MHz` | Neutral (bit-identical `7de7faf7`, `270fdd45`) |
| `performance-retime-muxf-aggressive-remap` | `PerformanceOptimized`, retime **on** | `+ -muxf_remap` + `-aggressive_remap` | `AltSpreadLogic_high` | `AlternateCLBRouting` | Cancelled in synth | — | Tool-probed only | Stopped cleanly at user conclusion (`5c630403`) |

### Four-Domain Clock Summary of Accepted `35.736 MHz` APR Baseline (`7de7faf7`)

| Clock Domain Pair | Constraint | Setup Slack | Hold Slack | Status |
| --- | ---: | ---: | ---: | --- |
| **Core &rarr; Core** (`mmcm_clk`) | `25.000 ns` | `-2.983 ns` | `+0.011 ns` | `35.735983 MHz` conditional (`53,608` setup endpoints) |
| **AXI &rarr; AXI** (`clk_pl_0`) | `10.000 ns` | `+6.013 ns` | `+0.019 ns` | Met |
| **Core &rarr; AXI** (`5 ns` CDC) | `5.000 ns` | `+1.244 ns` | `+0.443 ns` | Met (`10/10` Gray bus-skew passing, min `+9.321 ns`) |
| **AXI &rarr; Core** (`5 ns` CDC) | `5.000 ns` | `+1.427 ns` | `+1.893 ns` | Met |

### Why Pure-APR Permutations Plateaued at `35.736 MHz` Before RTL Relief

1. **`ExtraTimingOpt` Placement Degraded Wire Delay (`35.204 MHz` vs. `35.736 MHz`):**
   Despite identical synthesis/post-MUXF netlists (`7765fc10`) and a tighter
   slice-grid Manhattan span on the worst path (`712` vs. `755`),
   `ExtraTimingOpt` expanded occupied CLBs (`35,703` [`83.69%`] vs. `35,034`
   [`82.12%`]), reintroduced placer high-congestion warnings (`64×64` South
   long-wire region), and **increased** worst-path interconnect delay
   (`21.311 ns` vs. `20.825 ns`).
2. **`Explore` Routing Produced an Identical Image (`35.736 MHz`):** On the
   matched `AltSpreadLogic_high` placement, `route_design -directive Explore`
   produced the exact same `timing.tsv` and programming binary SHA-256
   (`7de7faf730a31b41eee6c7750b0e849f7cf23eef761d71a4126d5c9bcf3ce88c`) as
   `AlternateCLBRouting`.
3. **Critical-Path Structure Required RTL Fanout/Mux Cuts for 40 MHz:** In the
   retained `35.735983 MHz` (`2h03m21s` total, `202,114` LUTs, `55,213` FFs,
   `35,034` CLBs) routed checkpoint, all 20 top failing paths originated at
   `q_pc[1]` and shared a `14.754 ns` leading prefix (`27.882 ns` total =
   `7.057 ns` logic + `20.825 ns` [`74.7%`] wire across `84` levels; `60.44%`
   of wire delay on fanout `1–4` nets and `19.08%` on fanout `128+` broadcast
   nets). The isolated APR campaign concluded cleanly at the user-accepted
   **`35.736 MHz`** strategy milestone (`5c630403`, cancelling the just-launched
   `-aggressive_remap` trial cleanly with zero orphan Vivado/VRS workers), and
   the winning **`retime_muxf_route_first`** recipe was then applied to the
   fanout-relieved `c0e3fe43` RTL to close **`40.264133 MHz` STA** in Section 1.

---

## 3. Verification & Constraint Integrity Notes

- **XDC Exception Scope Verified:** Inspection of all generated XDC archives
  confirmed zero CPU multicycle, clock-group, case-analysis, or disable-timing
  waivers (`37` vendor CDC/reset false paths and `10` XPM Gray-pointer
  `set_max_delay` / `set_bus_skew` rules confined strictly to AXI SmartConnect,
  width/clock converter, and reset IP; the legacy `FPATAN` multicycle XDC is
  excluded).
- **Tooling Regression Suite:** `120` fresh-flow/path/closure-audit tests and
  `26` systemd scope/resource-policy tests verify exclusive Vivado lock
  inheritance (`fpga/run_vivado_exclusive.sh`), thread-count readback,
  `clk_pl_0` vs. `mmcm_fb` clock disambiguation, and complete post-route
  DRC/CDC/timing coverage.
