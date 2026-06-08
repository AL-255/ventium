# Ventium‑on‑KV260 — synthesis & timing rework backlog

Concrete RTL rework items discovered by the **synth‑fit probe** (Vivado 2025.2,
synth‑only, out‑of‑context, top = `core`, part `xck26-sfvc784-2LV-c`,
`+define+VTM_NO_DPI`, 100 MHz target clock). These are the things that must
change before the core closes timing / fits on the KV260 PL. Cross‑ref
`fpga/PLAN.md` §5. **To be dealt with later** — this is the backlog, not done work.

Reproduce: `vivado -mode batch -source fpga/scripts/synth_probe_core.tcl -notrace`
(reports land in `fpga/build/synthprobe_core/`).

Legend: **P0** = blocks timing closure / fit; **P1** = needed for hardware
function; **P2** = quality/cleanup.

---

## P0‑1 — x87 FDIV / FSQRT are single‑cycle combinational monsters
**Problem.** The 80‑bit x87 datapath is pure combinational `automatic` functions;
FDIV and FSQRT resolve a full divide/sqrt in **one clock**. The probe's RTL
component statistics make the cost explicit:

| Inferred operator | Count | Source |
|---|---|---|
| **256×256 multiplier** | 1 | `fx_isqrt` `r*r` (`fpu_x87_pkg.sv:682`) |
| **64×134 multipliers** | 8 | divide multiply‑back (`fx_div_exact`, `fpu_x87_pkg.sv:261-262`) |
| **256‑bit adders (3‑input)** | **126** | 128‑iteration unrolled restoring sqrt (`fx_isqrt`, `fpu_x87_pkg.sv:703-713`) |
| 128‑bit adders | 59 + | mantissa align/normalize (`fx_add`/`fx_round_pack`) |

This single combinational cone is why the probe's *synthesis* alone runs ~25+ min
and ~10 GB. It will not meet any useful Fmax (critical path is hundreds of LUTs
deep) and inflates area massively.

**Fix.** Convert FDIV and FSQRT to **multi‑cycle iterative FSM engines** (one
radix‑2/4 step per clock). The step bodies already exist:
* FDIV: the radix‑4 `fx_srt_div` (`fpu_x87_pkg.sv:356`, `NSTEP=36`) — register one
  step/clock instead of unrolling. (Preserves the optional FDIV‑bug erratum.)
* FSQRT: `fx_isqrt`'s per‑iteration body (`fpu_x87_pkg.sv:703-713`).
Drive the existing `fp_ready_cyc`/`fp_occ_pending` scoreboard
(`core.sv:722,4075`) from the engine's real `done` instead of the precomputed
`fp_lat/fp_occ` constants (`decode.sv:331-333`). Result write port:
`fpu_top` `we_top/top_data` (`fpu_top.sv:67-69`, written `core.sv:4084`).
**Keep `make m3` (x87 gate) bit‑exact after the rewrite.**

## P0‑2 — Integer DIV / IDIV are single‑cycle combinational dividers
**Problem.** `core_exec.svh:264-339` uses native `/` and `%` on operands up to
64‑bit (the 32‑bit form divides a 64‑bit `{EDX,EAX}` dividend) inside the
combinational exec arm — a very deep restoring‑divide array, almost certainly the
worst integer critical path.
**Fix.** Replace with a **sequential/iterative divider** (radix‑2/4, N cycles).
The latency budget is already modeled by `pending_mem_pen` occupancy — reuse it as
the engine's cycle count. Keep `make verify` (functional) green.
**Status:** **DONE + verified.** Engine `rtl/core/ven_idiv.sv` (magnitude
restoring, 2 steps/clk, sign‑fix, exact per‑width overflow/#DE) bit‑exact vs
native `/`/`%` over 80k vectors × 6 forms (`make verify-idiv` → IDIV‑GATE‑OK).
**Integrated** behind `+VEN_IDIV_ITER` (`S_DIV_BUSY` mirroring `S_FP_BUSY`, a
combinational driver feeding the engine from `gpr`/`srcv`, EAX/EDX + #DE commit on
`done`, occ residual DIV+1 / IDIV+6). Verified: default `make verify` 74/74 green;
`+VEN_IDIV_ITER` `make verify` 74/74 + **div cycle bands in‑band** (mb_div8 +5.45%,
div16 +0.13%, div32 +2.36%, idiv32 +2.12%, all <10%); `verify-sys` **`pde` #DE
EQUIVALENT**. _(Synth re‑probe with both engines running.)_

## P0‑3 — icache does not infer Block RAM (synthesizes to flip‑flops)
**Problem.** `rtl/mem/icache.sv` copies its entire 8 KB data array (and
tag/val/lru) to **combinational output ports** so the core spine can probe it
(`icache.sv:60,101-117`). Vivado therefore cannot infer BRAM and warns
*"Potential Runtime issue for 3D‑RAM `ic_data_o_reg` with 65536 registers"* /
`ic_data_reg` 65536 registers — i.e. the 8 KB cache became **~8,224 × 8‑bit
flip‑flops**. That blows the FF budget and the wide combinational fan‑out hurts
timing.
**Fix (DONE — behavior‑preserving refactor, NO pipeline change).** The synth
hierarchy showed `u_icache` = **309,018 LUTs = 75 % of the whole core** — so this
decides whether the core fits. The real cost was the **whole‑array combinational
dump** (`ic_data_o`) + the spine's **~12 full‑array byte muxes** (`ub[]`/`vb[]`).
Insight: a *registered* BRAM (the recon's plan) would force a fetch‑pipeline
stage, but **distributed RAM supports async read** — so the fix is just to narrow
the read. Replaced `ic_data_o` with a packed‑line array (`ic_line[set][way]`,
256‑bit) + **two addressed async line‑read ports** (the fetch window spans only 2
consecutive lines — A=`flin`'s line, B=next); `ic_byte` slices a byte from the
addressed line instead of muxing the whole array. **Same cycle, same data →
`make verify` bit‑exact + mb_imiss/dmiss CYCLE‑IDENTICAL (+0.03 %/+0.10 %,
unchanged).** `icache.sv` + `core.sv` (default path, no define). **Quake lockstep
1,000,000 insns EQUIVALENT** (deep fetch‑path guard).

**Measured (re‑probe, both engines + icache refactor):** total **CLB LUTs
411K → 181,772 (351 % → 155 %)** — a **56 %** drop; `u_icache` **309,018 →
78,804 LUTs (−75 %)**; F7/F8 muxes 196 %/190 % → 54 %/46 %. (First cut still
flip‑flops, BRAM=0 — the partial fill write blocked RAM inference; switched the
fill to a **full‑line read‑modify‑write** so `ic_line` infers distributed RAM,
which should free ~75 K more LUTs → core ≈ 106 K ≈ **fits the 117 K device**.
RMW `make verify` 74/74 + cycle‑identical; re‑probe confirming.)

**Final (flat `{set,way}` index + `(* ram_style="distributed" *)`):** Vivado now
infers **512× RAM256X1D distributed RAM** for `ic_line` (LUT‑as‑Memory 0 → 4,096),
**freeing the 71 K icache flip‑flops** (core FFs 93 K → 27.9 K). Total **CLB LUTs
411 K → 149,467 (351 % → 127.6 %)**, `u_icache` 309 K → **46,660** (LUTRAM + the
2‑port 256‑bit read mux). Verified: `make verify` 74/74 + mb_imiss/dmiss
cycle‑identical + Quake lockstep 1 M EQUIVALENT. _(The RMW attempt was a regression
and was reverted; the partial word write + ram_style hint is the keeper.)_

**Registered‑BRAM follow‑up — MEASURED & REJECTED (2026‑06‑07).** Tempting to push
`ic_line` into true RAMB36 to "free the 4,096 LUTRAM + the read mux" and pipeline
the async read off the worst path. Built a registered‑read variant
(`ram_style="block"`, `rd_lineA/B` clocked; the icache MODULE alone is probed by
`fpga/scripts/probe_icache_standalone.tcl`) and synthesised it standalone both
ways (the registered/`block` throwaway has since been removed — numbers below):

| standalone icache | async (keeper) | registered "BRAM" |
|---|---:|---:|
| Total LUTs | **10,712** | 11,004 (+292) |
| LUT as Memory | 4,096 | 4,096 (unchanged) |
| **RAMB36** | 0 | **0 — did NOT infer** |
| CLB Registers | 5,504 | 6,016 |

Two conclusions: **(1)** the `u_icache=45 K` in the full‑core hier report is a
`‑flatten_hierarchy rebuilt` ATTRIBUTION artifact (the core's same‑cycle decode
window folds into the instance) — the icache's intrinsic storage+read cost is only
~10.7 K. **(2)** BRAM will NOT infer for this array no matter the hint: Vivado
8‑7082 *"implemented as Block RAM but is better mapped onto distributed LUT RAM …
the depth (8 address bits) is shallow."* `ic_line` is **256 lines × 256 bits —
shallow‑and‑wide**, the textbook distributed‑RAM case; a RAMB36 (1 K+ deep) would
waste its depth. The registered read added flops and **zero** BRAM. So the
distributed‑RAM keeper is already optimal; a fetch‑pipeline stage would buy nothing
and risk the cycle bands. **icache→BRAM is closed.** The LUT levers are fpu_top
(58.6 K, P0‑4) and the integer/decode combinational logic, not the cache.

## Critical‑path investigation (after FPU/idiv/icache reworks — core at 149 K LUTs)
From `fpga/build/synthprobe_core_full/timing_paths.rpt` (WNS −59.4 ns ≈ 14.6 MHz):
1. **WORST (−59.4 ns, 182‑deep CARRY8):** `fx_fx_to_bcd` — the **FBSTP** (FP→packed
   BCD store), `for i<18: bcd[i*4+:4]=q%10; q=q/10;` (`fpu_x87_pkg.sv` ~1004) — 18
   **chained combinational divide‑by‑10** stages (+ `fx_to_int_ex` at the front).
   Path `fpr_reg → …mem_wdata… → smi_pending`. **A rare instruction dominating
   Fmax purely because it's combinational.** FIX: iterative (1 `/10`/clk, ~18 clk);
   it's already slow‑path (`S_FSTORE`), so multi‑cycle costs nothing.
   **✅ DONE (`+VEN_BCD_ITER`).** Engine `rtl/fpu/ven_bcd.sv` (IDLE does
   `fx_to_int_ex` + overflow check; RUN 2 `/10`/clk; FIN packs sign byte + flags);
   core runs it in `S_BCD_BUSY` before `S_FSTORE`, `fstore_val` reads `fbcd_result_q`.
   Verified bit‑exact: `make verify-bcd` 40k BCD‑GATE‑OK; default `make verify`
   74/74; `+VEN_BCD_ITER` `make m3` 74/74 incl. `tx_bcd_st`/`tx_bcd_ld` (FBSTP/FBLD).
2. **#2 (−28 ns, 67 CARRY8 + DSP):** the iterative sqrt engine's FIN tail
   `rsq = root*root` (256×256 mult) + round (`fpu_sqrt_iter.sv`). FIX (1‑line,
   bit‑exact): the loop already has the remainder `p_reg`; `p_reg!=0` ⟺ not a
   perfect square, so drop `r*r` entirely → removes the DSP mult + this path.
   **✅ DONE.** `fpu_sqrt_iter.sv` FIN now `r_final = (rem!=0) ? (root|1) : root`
   (the registered 256‑bit remainder) — the 256×256 mult is gone (synth DSP
   **320 → 95**, −70%). Bit‑exact (`make m3 +VEN_SRT_ITER` 74/74, `tx_sqrt` PASS).
3. **#3+ (the P0‑4 tier):** the still‑combinational **`fx_add`/`fx_mul`** (FADD/
   FMUL) + `fx_to_int_ex` (FIST) / `fx_bcd_to_fx` (FBLD, 18× ×10). Pipeline/iterate.

Order of attack: FBSTP iterative (biggest single win) → sqrt FIN (free) → FADD/
FMUL pipeline (P0‑4) → re‑probe. _Investigated 2026‑06‑06; #1+#2 done 2026‑06‑07._

### After FBSTP→ven_bcd (`+VEN_BCD_ITER`) + sqrt‑FIN `r*r` removal — all engines
Re‑probe `fpga/scripts/synth_probe_core_bcd.tcl` (`+define {VTM_NO_DPI VEN_SRT_ITER
VEN_IDIV_ITER VEN_BCD_ITER}`). Reports: `fpga/build/synthprobe_core_bcd/`.

| Resource | Baseline | full (pre‑BCD) | **+BCD +sqrtFIN** | total Δ |
|---|---:|---:|---:|---:|
| **CLB LUTs** | 606,150 (518%) | 149,467 (127.6%) | **130,222 (111.2%)** | **−79%** |
| &nbsp;&nbsp;LUT as logic | 606,150 | 145,371 | **126,126 (107.7%)** | |
| &nbsp;&nbsp;LUT as memory | 0 | 4,096 | 4,096 (icache LUTRAM) | |
| **CARRY8** | 24,860 (170%) | 5,218 (35.6%) | **3,585 (24.5% ✅)** | −86% |
| **DSP48E2** | 401 | 320 | **95 (7.6%)** | −76% (sqrt 256² gone) |
| CLB Registers | 91,979 (39%) | 27,863 (11.9%) | **28,152 (12.0% ✅)** | −69% |
| F7 / F8 Muxes | 114K/56K (195%/190%) | — | **16,284/7,065 (27.8%/24.1% ✅)** | |
| Block RAM | 0 ⛔ | 0 ⛔ | **0 ⛔** (icache still LUTRAM) | |
| Worst path | 275.9 ns / 2090 lvl | 68.3→**59.4 ns** / 182 CARRY8 | **26.7 ns / 108 lvl (27 CARRY8)** | −90% |
| Est. Fmax | ~3.6 MHz | ~14.6 MHz | **~37.5 MHz** | **10.4×** |

Both rare‑but‑combinational monsters (FBSTP BCD chain, sqrt `r*r`) are gone; the
core now **nearly fits** (LUT 111%, CARRY8 24%, FF 12%, DSP 7.6%, F7/F8 ~25%).
The new worst path is the fetch→FP chain ending at `u_fpu_state/fpr_reg`.
_Captured 2026‑06‑07._

### After P0‑4 = f_eval CONSOLIDATION — **CORE FITS (91.7%)** ✅
P0‑4 was originally "pipeline FADD/FMUL," but per‑function area probes
(`fpga/scripts/probe_fp_fn.tcl`) overturned that premise: each FP fn is tiny
(`fx_add` 2.9K, `fx_mul` 1.9K, `fx_round` 1.3K) — pipelining wouldn't shrink area
(it adds flops) and the −16.7 ns path is a serial CHAIN (icache read → dispatch →
`fx_add` → fpr), not `fx_add` alone (which closes at ~−3.9 ns standalone). The
REAL FP hog: **`f_eval` was instantiated 5× in core.sv** — the four S_FEXEC arith
commit arms (FX_AR_ST0_STI / STI_ST0 / M32M64 / I16I32) each built a FULL
add/mul/round cone, then the outputs were muxed (compute‑then‑mux). Fix
(behaviour‑preserving, DEFAULT, no define): mux the **operands** per `q_fxop`
(reusing the `s_fa/s_fb` the SRT‑eligibility block already computed) → call
`f_eval` **ONCE** (mux‑then‑compute). The four arms just route the shared `s_arf`
to their write port; the fast‑arm `fp_arf` (decode‑time operands) is left as the
one separate eval.

| Resource | +BCD +sqrtFIN | **+ f_eval consolidate** | Δ |
|---|---:|---:|---:|
| **CLB LUTs** | 130,222 (111.2%) | **107,418 (91.7% ✅ FITS)** | **−22,804** |
| &nbsp;&nbsp;LUT as logic | 126,126 | **103,322 (88.2%)** | −22,804 |
| `u_fpu_state` (FP datapath) | 58,618 | **33,856** | **−24,762 (−42%)** |
| **CARRY8** | 3,585 (24.5%) | **2,611 (17.8%)** | −27% |
| DSP48E2 / FF | 95 / 28,152 | 95 / 28,085 | ~same |
| Worst path | 26.7 ns | **24.2 ns / 101 lvl (33 CARRY8)** | −9% |
| Est. Fmax | ~37.5 MHz | **~41.2 MHz** | +10% |

**The core now fits the XCK26 (107,418 / 117,120 = 91.7% LUTs)** — from 518 %
(5.2× over) at the start of the fpga effort to fitting, all bit‑exact. Verified:
lint clean ×3 configs; default `make verify` **75/75 + every cycle band unchanged**
(FP CPI 2.985/1.152 identical → the refactor is cycle‑neutral); iter `make m3`
**75/75** incl. tx_addsub/muldiv/chain/sqrt/bcd. New worst path: still the fetch→FP
chain `eip_reg → u_icache async read → fp_ready_cyc → fx_add/fx_mul →
u_fpu_state/fpr_reg[0][76]` (101 lvl). Headroom now exists; further area/Fmax
candidates: consolidate `apply_cmp`×6 / `fcom_codes`×6 the same way; the integer
datapath. _Captured 2026‑06‑07._

## P0‑4 — FMUL is a single‑cycle 64×64 multiply + 128‑bit normalize
**Problem.** `fx_mul` does a 64×64→128 multiply (`fpu_x87_pkg.sv:217`) plus a
128‑bit MSB‑find + round in the **same clock** (probe shows the 64×134 / 32×32
multipliers). Maps to DSP cascades but the combined path is long.
**Fix.** **Pipeline** FMUL (2–3 stages, DSP48E2‑mapped) feeding `fp_top_data`;
update the scoreboard `done`. Lower priority than FDIV/FSQRT but needed at speed.

---

## P1‑1 — No real memory subsystem; core assumes same‑cycle combinational ack
**Problem.** The only memory port (`mem_*`, `core.sv:173-179`) is served by the
C++ `MemModel` (combinational, same‑cycle ack). The dual‑issue **fast path** reads
`mem_rdata` combinationally the same clock (`core_fastpath.svh`,
`core_bus_driver.svh:23`), so it *requires* a same‑cycle ack. Real PS‑DDR over
AXI has multi‑cycle, variable latency → the core would stall or mis‑pipeline.
**Fix.** Build **`ventium_l1_axi`** (PLAN §5.2): an L1 cache (BRAM/URAM) giving
**same‑cycle ack on hit** and AXI4 bursts on miss, with CDC core↔AXI clock, the
x86‑phys→reserved‑DDR base remap, and A20. Connect to `S_AXI_HPC0` (coherent).
This is the linchpin — it satisfies the fast‑path assumption *and* hides DDR
latency. (The D‑cache today is timing‑only with **no data array** — its registers
are even optimized away: probe warns *"Unused sequential element … removed"* at
`dcache_timing.sv:68` — so real load data must come from the L1/AXI path.)

## P1‑2 — IDE `disk[]` array cannot be implemented as memory
**Problem.** `ven_ide.sv:323` `disk[0:DISK_SECTORS*512-1]` (64 KB = 524,288 bits)
cannot be inferred as block RAM (multi‑port writes + the `$readmemh` init) and is
too large to dissolve into FFs — hard synth **ERROR** on the full‑SoC probe.
**Fix.** Replace the on‑chip `disk[]` with a **DDR‑backed disk** (PLAN §5.5): the
PS loads the FreeDOS+Quake image into a DDR sub‑region; `ven_ide` PIO/DMA reads
issue AXI reads there (PIO mux `ven_ide.sv:414`, DMA copy `:469-470`, write commit
`:566-567`). Scale `DISK_SECTORS`/geometry/OOR checks; verify multi‑sector PIO.

## P1‑3 — No clocking/reset infra; device tick params tuned for sim
**Problem.** `ventium_soc` has only a bare `clk` + sync `rst_n`; no MMCM/PLL, no
reset synchronizer. PIT/RTC/ACPI tick divisors are sim placeholders
(PIT `TICK_DIV=1024`, ACPI `CLK_HZ=33 MHz` default) — IRQ0/PM rates would be wrong
on a real fabric clock.
**Fix.** Add MMCM (core clock + AXI clock) + reset sync; retune `ven_pit`
`TICK_DIV/TICK_INC` for 1.193182 MHz, `ven_rtc` for 1 Hz, `ven_acpipm` `CLK_HZ`
to the real fabric frequency, from the chosen Fmax.

---

## P2‑1 — Vivado‑vs‑Verilator cleanliness  *(ALREADY FIXED — recorded for context)*
The Verilator sweep missed constructs Verilator accepts but Vivado synth rejects.
Fixed (behavior‑preserving, Verilator still green); keep an eye out for more:
* bit‑select on a function‑call result `f(x)[i]` → bind to a temp
  (`ventium_x87_pkg.sv` `fx_is_snan`; `core_exec.svh` `K_BITTEST`).
* `input logic` ports under `` `default_nettype none `` → `input wire logic`
  (33 ports across `ventium_soc/ven_pic/ven_i8042/ven_rtc/ven_port92`).
* variable‑bound loops Vivado can't unroll → constant bound + runtime guard
  (BSF/BSR `core_exec.svh`; 8259 priority `while`→`for` `ven_pic.sv`).

## P2‑2 — `+define+VTM_NO_DPI` required for synthesis
The DPI retire imports/calls are guarded; the synth flow must define
`VTM_NO_DPI` (and leave `VEN_IDE_DISK_HEX`/`M7_PROXY_DEBUG` undefined). Done in
the probe scripts; carry into the real build.

## P2‑3 — Unused retire/observation ports
Many `retire_*` outputs are driven by constants in OOC (probe warnings). On the
real top, replace the DPI retire path with the AXI‑Lite arch‑state peek
(PLAN §5.3) or tie off cleanly.

---

## Final utilization / Fmax  (core‑only OOC synth, as‑is, no rework)
Probe completed (synth ≈ 3 h wall on this box; ~11 GB peak). Reports in
`fpga/build/synthprobe_core/{util,timing_summary,timing_paths}.rpt`.

**Utilization vs `xck26` (XCK26 ZU5EV) — the as‑is core does NOT fit:**

| Resource | Used | Available | Util |
|---|---:|---:|---:|
| **CLB LUTs** | **606,150** | 117,120 | **517.6 %**  ⛔ (5.2× over) |
| &nbsp;&nbsp;LUT as logic | 606,150 | 117,120 | 517.6 % |
| &nbsp;&nbsp;LUT as memory | 0 | 57,600 | 0 % |
| CLB Registers (FF) | 91,979 | 234,240 | 39.3 % ✅ |
| **CARRY8** | **24,860** | 14,640 | **169.8 %** ⛔ |
| F7 / F8 Muxes | 114,517 / 55,783 | 58,560 / 29,280 | 195 % / 190 % ⛔ |
| DSP48E2 | 401 | 1,248 | 32.1 % ✅ |
| **Block RAM** | **0** | 144 | **0 %** ⛔ (caches mapped to LUT/FF, not BRAM) |
| URAM | 0 | 64 | 0 % |

**Timing @ 100 MHz target (10 ns):** **WNS = −265.9 ns**, 164,548 failing
endpoints, TNS −946,534 ns. Worst path **data delay 275.9 ns**, **2,090 logic
levels (CARRY8 = 1,823)**, ending at `u_fpu_state/fpr_reg[*][78]` →
**effective Fmax ≈ 3.6 MHz** for that path.

**Interpretation (verdict locked):**
* The blowup is the **combinational arithmetic**: a single ~1,800‑deep carry
  chain into the FPU register file = the unrolled FSQRT/FDIV (P0‑1) and the
  combinational integer divide (P0‑2). This one class of logic causes both the
  517 % LUT/170 % CARRY8 overflow **and** the ~3.6 MHz path.
* **BRAM = 0**: the caches/arrays mapped to LUT/FF instead of block RAM (P0‑3,
  P1‑2) — so the 18 Mb URAM + 144 BRAM are entirely free for the rework to use.
* **FF (39 %) and DSP (32 %) fit comfortably** — the device is big enough; the
  problem is purely the un‑pipelined combinational style.
* Therefore P0‑1…P0‑4 (iterative dividers/sqrt, pipelined FMUL, BRAM caches) are
  not optional polish — they are what makes the core *fit at all* and reach a
  usable Fmax. Re‑run this probe after each to track LUT% and WNS down.

_Baseline captured 2026‑06‑06 (Vivado 2025.2, `core` OOC, `+define+VTM_NO_DPI`)._

### After P0‑1 (iterative FPU: FDIV/FSQRT engines + cone removal, `+VEN_SRT_ITER`)
Re‑probe `fpga/scripts/synth_probe_core_iter.tcl` (`+define {VTM_NO_DPI VEN_SRT_ITER}`).
Reports: `fpga/build/synthprobe_core_iter/`.

| Resource | Baseline | **Iterative FPU** | Δ |
|---|---:|---:|---:|
| CLB LUTs | 606,150 (518%) | **425,526 (363%)** | −30% |
| **CARRY8** | 24,860 (170% ⛔) | **7,677 (52% ✅)** | **−69%, now fits** |
| DSP48E2 | 401 (32%) | 320 (26%) | −20% (256×256 mult gone) |
| CLB Registers | 91,979 (39%) | 93,117 (40%) | ~same |
| Worst path | 275.9 ns / 2090 lvl (1823 CARRY8) | **87.8 ns / 667 lvl (585 CARRY8)** | −68% |
| Est. Fmax | ~3.6 MHz | **~11.4 MHz** | **3.2×** |

The unrolled FSQRT/FDIV carry chain is gone; functional bit‑exactness held
(`make m3 +VEN_SRT_ITER` 74/74, `make verify`/`m3` default green). The new worst
path (585‑deep CARRY8, 87.8 ns) was the combinational integer DIV/IDIV (P0‑2). LUTs
still 363% (integer divide + FF‑mapped icache). _Captured 2026‑06‑06._

### After P0‑2 (iterative integer divider, `+VEN_IDIV_ITER`) — both engines
Re‑probe `fpga/scripts/synth_probe_core_full.tcl` (`+define {VTM_NO_DPI
VEN_SRT_ITER VEN_IDIV_ITER}`). Reports: `fpga/build/synthprobe_core_full/`.

| Resource | Baseline | FPU‑only | **+ integer div** | total Δ |
|---|---:|---:|---:|---:|
| CLB LUTs | 606,150 (518%) | 425,526 (363%) | **411,396 (351%)** | −32% |
| **CARRY8** | 24,860 (170% ⛔) | 7,677 (52%) | **5,323 (36% ✅)** | **−79%** |
| DSP48E2 | 401 | 320 | 320 | −20% |
| Worst path | 275.9 ns / 2090 lvl | 87.8 ns / 667 lvl | **68.3 ns / 291 lvl (174 CARRY8)** | −75% |
| Est. Fmax | ~3.6 MHz | ~11.4 MHz | **~14.6 MHz** | **4.1×** |

The 585‑deep integer‑divide carry chain is gone (verified bit‑exact: default green;
`+VEN_IDIV_ITER` `make verify` 74/74 + div bands in‑band + `verify-sys` `pde` #DE
EQUIVALENT). **The new worst path (174‑deep CARRY8, 68.3 ns) is now an FPU path**
(`u_fpu_state/fpr_reg` → `smi_pending`) — the still‑combinational **FADD/FMUL/
compare** logic (P0‑4). LUTs are still 351% because the **icache is FF/LUT‑RAM‑
mapped, BRAM=0** (P0‑3) and the F7/F8 muxes (196%/190%) come from the same
whole‑array combinational read. Next biggest wins: **P0‑3 (icache→BRAM)** for LUTs
and **P0‑4 (pipeline FMUL/FADD)** for the remaining carry path. _Captured 2026‑06‑06._

## P0‑5 — FP execute PIPELINE (+VEN_FP_PIPE) + the ROUTING‑BOUND finding
After the f_eval consolidation (core fits, 91.7 % LUT, ~37.5 MHz synth / ~33 MHz
post‑place), the worst path was the same‑cycle FP execute: fetch/decode →
`f_eval` (fx_add/fx_mul) → `fpr`, ~24–30 ns. `fx_add` alone is ~14 ns of LOGIC, so
NO single‑cycle FP execute can clear 66 MHz — it must be pipelined. The scoreboard
already models fadd latency = **3**, so a 2‑stage execute fits the modeled window
and keeps BOTH FP cycle bands.

**Built (3 commits, all bit‑exact + cycle‑accurate, behind +VEN_FP_PIPE so default
is byte‑identical):**
* **Foundation** (`fb507aa`): 2‑stage split of fx_add/fx_mul/f_eval at the shared
  `fx_round_pack` boundary (fx_*_s1 front / f_eval_s2 back, fx_pipe_t carrier).
  `verif/fppipe` gate: f_eval_s2(f_eval_s1)==f_eval over 1 M vectors.
* **Fast arm** (`117c73d`): cycle‑mode S_PIPE FK_ARITH defers — capture operands at
  issue, commit one clock later via a new ABSOLUTE‑indexed `we_wabs` port on
  fpu_top; a S_PIPE read‑hazard bubble (`fp_pipe_rd_haz`) stalls a same‑clock
  reader of the in‑flight target. Validated by **cycle‑mode verify**.
* **Slow arm** (`5d3e524`): S_FEXEC memory‑operand arith. **KEY:** the differential
  harness in FUNCTIONAL mode (what `make m3` uses, and where ALL FP ops take the
  slow FSM) checks arch state AT RETIRE — so the slow arm can NOT defer (the
  deferred write lands one clock after retire → stale check). It uses a new
  **S_FEXEC_EX** state that commits (we_wabs) AND retires in the SAME clock.
  Validated by **functional m3**.

**Verified:** default `make verify` 75/75 (unaffected); +VEN_FP_PIPE `make m3`
75/75 + `make verify` 75/75 + mb_faddchain CPI 2.989 + mb_fpindep 1.152 (both
bands). The deferred single‑eval also CUT AREA: **LUT 91.7 % → 82.85 %**, CARRY8
2,611 → 2,268.

**Synth (15 ns target):** WNS −6.7 ns → **~46 MHz** (was ~33 baseline). Failing
endpoints 71 K → 9.7 K.

**Post‑place (the real number) — ROUTING‑BOUND at ~34.7 MHz.** WNS −13.8 ns /
28.8 ns, but **64 % of that is ROUTING (18.5 ns)**. All top worst paths are
`f_mem80 → fpr` — the FP **loads** (FLD/FILD/**FBLD** `fx_bcd_to_fx`, the deepest,
NOT pipelined) — and the 18.5 ns routing is because the core fills 82.85 % of the
device so OOC placement spreads `f_mem80`/`fpr` far apart. **The wall is now
congestion/placement, not logic depth** — pipelining FBLD would cut its ~10 ns
logic but leave the ~18 ns routing. To clear 66 MHz: (a) drive util down toward
~60–70 % (the deferred apply_cmp×6 / fcom_codes×6 consolidations, integer‑datapath
trims) so placement is compact, and/or (b) floorplan/Pblock the FP datapath; THEN
(c) pipeline FBLD via an iterative `ven_bcd_to_fp` engine (the load‑side twin of
ven_bcd) for the last logic tier. _Captured 2026‑06‑07._

## P0‑6 — iterative FBLD + BTB‑update pipeline → the ROUTING wall (synth 33→59.5 MHz)
After P0‑5 (FP execute pipeline), the worst paths were the FP LOADS (`f_mem80 → fpr`,
dominantly FBLD `fx_bcd_to_fx`) then the branch predictor.

* **Iterative FBLD** (`75a1c0c`, `rtl/fpu/ven_bcd_to_fp.sv`, +VEN_BCD_ITER): the
  load‑side twin of ven_bcd — accumulates 18 BCD digits MSD‑first, two *10/clk
  (~9 clk), S_FBLD_BUSY pushes+retires same‑clock (functional‑safe). Gate
  `make verify-fbld` bit‑exact. **Removing the FBLD cone jumped synth 46 → ~58 MHz**;
  all remaining worst paths became the BTB, NOT FP — the FP datapath is fully off
  the critical path.

* **BTB‑update pipeline** (`ab3001e`, +VEN_BTB_PIPE): a 3‑agent investigation found
  BRAM is the WRONG fix for the `eip → btb_ctr_reg` path: the BTB is 64‑deep
  (shallow → won't infer BRAM, like icache) AND only 13 of its 63 levels (21%) are
  the BTB — the other 50 (79%) are the upstream `eip → icache → decode → issue_arm`
  front‑end gate, which can't be deferred (single‑cycle dual‑issue). The cycle‑safe
  lever: register the BTB resolve inputs so the counter UPDATE (a state side‑effect;
  predict reads PRE‑update state) leaves the issue_arm net. Cycle‑neutral
  (mb_brloop/brrandom abscyc IDENTICAL to baseline). **Synth 58 → 59.5 MHz.**

**The ROUTING wall (definitive).** The new worst path is the **EIP self‑update loop**
(`eip_reg → eip_reg`, the fetch→decode→PC‑advance loop): 16.8 ns, but **logic only
6.0 ns (36 %) / routing 10.8 ns (64 %)**. The LOGIC is done — 6 ns closes at
~166 MHz. The remaining gap to 66 MHz is **pure routing/congestion**: the core fills
the device (OOC, no floorplan) so `eip` + fanout spread far apart. Every cone this
session (FP pipe, FBLD, BTB) drove logic depth down successfully; there is no logic
cone left to cut. **To reach 66 MHz the lever is now PLACEMENT, not RTL** —
floorplan/Pblock the front‑end + FP datapaths into compact regions and/or close
timing during full‑SoC integration with real clocking constraints. Synth Fmax
journey this session: 3.6 → 14.6 → 37.5 → 46 → 58 → **59.5 MHz**. _Captured 2026‑06‑07._

## Floorplan / route attempt — the OOC core-only flow is CONGESTION-BOUND (2026‑06‑07)
With the logic optimized (worst‑path logic 6 ns), tried to close the routing gap
via place+route + floorplanning (`fpga/scripts/impl_route_fppipe.tcl`, VEN_PBLOCK):
* Placed Fmax (ExtraTimingOpt): **~42.5 MHz** (no Pblock) → **~44.2 MHz** (soft
  Pblock compaction) — floorplanning helps placement only marginally (+1.7 MHz).
* **Full ROUTE does NOT converge at 82.85 % util** — both Explore and the default
  route directive timed out (>90–100 min). The device‑filling core is
  congestion‑bound; the router can't close it and the placed→routed gap means the
  real number is lower still.
**Conclusion:** floorplanning alone can't fix a device‑filling core (no room to
compact). The lever to 66 MHz is **LOWER UTIL** — drive 82.85 % → ~70 % via the
deferred behaviour‑preserving consolidations (apply_cmp×6 / fcom_codes×6, like the
f_eval win) so the design is routable AND routes short — and/or close timing at
full‑SoC integration with the core as one floorplanned block + real MMCM clocking.
The RTL logic‑side Fmax work is COMPLETE. _Captured 2026‑06‑07._

## Congestion analysis & better floorplanning (2026‑06‑07) — root cause = icache MUXF
Why the OOC route won't converge: `report_design_analysis -congestion` on the
placed best‑config DCP shows **level‑5 congestion that is 99 % `u_icache`** in a
band (≈X9‑23, Y161‑205), and the congested cells are **58‑67 % MUXF (F7/F8)** —
the icache's wide SAME‑CYCLE read‑mux trees (the decode‑window byte muxes ub/vb +
ic_present/ic_hit_way at many positions, all slicing the 256‑bit lines). Every
module is already spread FULL‑DIE (u_icache X=0..60 Y=0..239), so there is nothing
to compact — a Pblock can't help.

Congestion‑driven impl (`fpga/scripts/impl_floorplan.tcl`:
`place_design -directive AltSpreadLogic_high` + `route_design -directive
AlternateCLBRouting`, 22 ns meetable clock):
* **Placement MET timing** at 22 ns (WNS +0.501 ns, 0 failing) — AltSpreadLogic
  beat the timing‑directive place (which was −0.570 ns), and spread the LUTRAM
  (4‑13 % → 31‑40 %).
* **But congestion stayed level‑5/6** — AltSpreadLogic cannot spread the F7/F8
  MUXF (they are architecturally bound to their LUTs). The router reported
  *"Estimated routing congestion level 6"*.

**Conclusion:** floorplanning/placement directives have hit their ceiling — the
congestion is an RTL/architectural property of the icache's same‑cycle multi‑
position decode‑window read (the 12 byte windows + the 2‑port 256‑bit line mux),
NOT a placement problem. The real congestion lever is RTL: narrow that read (fewer
combinational read positions / a fetch‑buffer stage), which is the same
front‑end‑pipelining class flagged for the eip loop — or close timing at full‑SoC
integration where the core is one floorplanned block. _Captured 2026‑06‑07._

## P0‑7 — narrow icache rd_lineB (+VEN_IC_NARROWB) → SYNTH 59.5→64.1 MHz, placed wall holds
The straddle line `rd_lineB` is only ever sliced by `ic_byte` at LOW byte positions:
the fast‑path window reads `ub[i]=byte(flin+i)` (i≤5) and `vb[i]=byte(flin+u_d.len+i)`
(u_d.len≤6, i≤5), so the worst‑case straddle byte is `flin[4:0]=31 + len 6 + i 5 −
32 = position 10`. Behind `+VEN_IC_NARROWB` (rtl/mem/icache.sv) we drive only the
LOW 128 bits of `rd_lineB` and tie the high 128 to 0, so Vivado prunes HALF of that
256‑deep distributed‑RAM read port. The pruned high bytes are NEVER sliced → fetched
bytes BIT‑IDENTICAL (verified `make verify` + `make m3` cycle‑identical; mb_imiss
+0.03 % noise).

Measured (best config + `+VEN_IC_NARROWB`, 15 ns OOC, `synth_paths_narrowb.tcl`):
* **LUT as memory 4096 → 3072** (‑1024, the dropped high‑128 LUTRAM); **MUXF7 16235
  → 14457, MUXF8 7147 → 6202** (‑12 %).
* **Synth WNS −1.808 → −0.587 ns ⇒ 59.5 → 64.1 MHz.** The icache is now OFF the
  synth critical path — the worst synth cone is the FP deferred‑commit
  `fpp_a_reg[68] → u_fpu_state/fpr_reg[*][78]` (15.584 ns, logic 6.75 / route 8.83).
* **Placed Fmax UNCHANGED — 47.6 MHz** (WNS −6.008 @ 15 ns, AltSpreadLogic_high) and
  **congestion still level‑5 / 99 % u_icache, MUXF 58‑62 %.** Narrowing rd_lineB cut
  the read‑port WIDTH (the synth win) but not the 256:1 read‑mux DEPTH, and the
  binding cone is the irreducible `rd_lineA` 256:1 read (every byte position 0..31 of
  line A is reachable depending on `flin[4:0]`, so it can't be statically narrowed
  like the straddle line).

**Read‑narrowing is now exhausted at the PLACED level.** The remaining levers, in
order of fidelity‑safety:
1. **Full‑SoC context (recommended, no fidelity risk):** OOC places the device‑filling
   core (76 % LUTs) with the icache MUXF crammed into one band and nowhere to spread.
   In the full SoC the PS owns most peripherals/L1 backing, the core is one
   floorplanned region with slack around it, and the MUXF congestion relaxes. The
   README already commits the 66 MHz closure to integration. _This does not require
   any RTL change._
2. **Microarchitectural fetch pipeline (BRAM + registered read):** move the L1 data
   array to BRAM (RAMB, 144 free, currently 0) with a SYNCHRONOUS read — this
   dissolves the MUXF congestion entirely (MUXF→0). The cost is +1 fetch‑latency
   cycle, so the fast path must register the fetched window and the cycle oracle
   (p5trace) must model the prefetch‑stage latency. This is arguably MORE faithful to
   the real P5 (which pipelines PF→D1) than the current same‑cycle async read, but it
   is a substantial change: restructure the fast path + re‑verify EVERY cycle band.
   The same‑cycle‑ack distributed‑RAM contract (fpga/L1_AXI_DESIGN.md §1) was chosen
   for simplicity; this is the one place where breaking it buys real Fmax.

A barrel‑shift restructure of the ub/vb byte windows was analysed and REJECTED: a
shared 12‑byte aligned window is itself 12×32:1 (the shift) PLUS 6×7:1 (the vb
extract) = MORE MUXF than the current 12×32:1 independent selects. The 12 byte
windows for 12 needed bytes are already minimal. _Captured 2026‑06‑07._

## P0‑8 — icache → BRAM + registered‑line prefetch fetch front‑end (+VEN_IC_BRAM)
Lever #2 of P0‑7, BUILT. The P0‑3 "registered‑BRAM" rejection was wrong on two counts
it never tried: (a) a RAMB has only 2 ports but `ic_line` needs 2 reads + 1 write, so
the store must be REPLICATED (`ic_line_a`/`ic_line_b`, one per read port, both written
identically); (b) the variable‑offset 32‑bit fill write must use the CANONICAL
byte‑write‑enable idiom or Vivado emulates the partial write with one narrow RAM per
2 bits (the 8‑6841 / 16×‑tile blowup). With both fixed, the standalone icache infers
clean BRAM:

| standalone icache | async (keeper) | BRAM bad‑write | **BRAM byte‑enable** |
|---|---:|---:|---:|
| CLB LUTs | 10,712 | 8,877 | **6,720** (−37 %) |
| LUT as Memory | 4,096 | 2,048 | **0** |
| MUXF7 | 4,163 | 2,854 | **2,052** (−51 %) |
| MUXF8 | 1,906 | 1,069 | **693** (−64 %) |
| RAMB tiles | 0 | 128 (88 %) | **5 (3.5 %)** |

The MUXF read‑mux congestion ROOT is dissolved (MUXF8 −64 %, LUTRAM→0) for **5 BRAM
tiles** — leaving 139 for the D‑cache + AXI FIFOs.

**The fetch front‑end (the hard part — keeping it cycle‑exact).** BRAM mandates a
SYNCHRONOUS read, so `rd_lineA/B` are valid the clock AFTER the address. A naive
registered read would add +1 cycle to EVERY fetch (≈12 % IPC, breaks every band). Two
mechanisms keep it bubble‑free:
* **Content‑addressed line buffers.** The spine registers the read ADDRESS as a tag
  (`rdA_set_q`/`rdB_set_q`) in lock‑step with the icache's registered data, and
  `ic_byte` selects whichever buffer's tag matches the needed set. Because buffer B
  reads flin's NEXT line every clock, a sequential line‑crossing finds the new current
  line ALREADY in buffer B → **zero bubble** (every straight‑line band stays perfect).
  A new `ic_fetch_ready` gate stalls one clock only when the needed line is resident
  but not yet buffered.
* **BTB‑predicted‑target prefetch (2b).** A redirect to an un‑buffered line costs the
  one residual bubble — which showed up ONLY on tight pairing loops whose back‑edge
  jumps to a now‑evicted loop top (`mb_accimm/rmimm/sh1` at +20 %; big loops like
  `mb_nearbr` amortised it to +3 %). Fixed by repurposing the straddle read port to
  prefetch the predicted‑taken TARGET line (gated on `!ic_win_straddle`, so the read
  port is free) — the line is buffered before the back‑edge, so the redirect costs no
  bubble. This is literally the real P5's BTB‑driven prefetch.

**Verified (all behind `+VEN_IC_BRAM`, default build byte‑identical):**
* `make verify`: **functional 75/75 bit‑exact** + **all 20 cycle bands PASS** —
  including `mb_accimm/rmimm/sh1` (+20 % → **+0.39 %** after 2b), branches
  (`mb_brloop` +0.23 %, `mb_brrandom` +1.85 %), and `mb_imiss` +3.97 % (the +1
  buffer‑fill clock after S_PF, well within the 10 % band).
* **Quake 300,000‑insn lockstep EQUIVALENT** (deep fetch‑path: real branch/loop/
  straddle/redirect patterns, RTL bit‑exact vs QEMU).
* Default build (no define): `make verify` 75/75 byte‑identical — fully gated/removable.

**PLACED PAYOFF — MEASURED, and it does NOT break the wall (the key finding).**
Full‑core synth+place (`synth_paths_icbram.tcl`, 15 ns, AltSpreadLogic_high):

| full core | narrowB (best) | +VEN_IC_BRAM |
|---|---:|---:|
| F7 / F8 Muxes | 14457 / 6202 | **14478 / 5715** (≈unchanged) |
| LUT as Memory | 3072 | **0** |
| RAMB36 tiles | 0 | **5** |
| CLB LUTs | 90,060 (76.9 %) | **96,787 (82.6 %)** ↑ |
| Synth WNS @15ns | −0.587 (64.1 MHz) | **−4.136 (52.3 MHz)** ↓ |
| **Placed WNS @15ns** | −6.008 (**47.6 MHz**) | **−5.523 (48.7 MHz)** |
| **Placed congestion** | L5, 99 % u_icache, MUXF 58‑62 % | **L5, 98 % u_icache, MUXF 68 %** |

The standalone icache MUXF dropped 51‑64 % (P0‑3‑style probe), but in the FULL CORE
F7/F8 barely move and **the placed congestion wall is UNCHANGED** (still level‑5, still
≈98 % "u_icache", MUXF if anything denser). Placed Fmax 47.6 → 48.7 MHz = within noise.
Synth Fmax REGRESSED (64→52) and LUTs grew (+6.7 K) from the front‑end logic, which
inflated the FP‑commit path's route.

**Root‑cause correction (the lesson):** the "99 % u_icache MUXF" congestion was the
`‑flatten_hierarchy rebuilt` ATTRIBUTION ARTIFACT — it folds the SPINE's
variable‑length‑decode **byte‑window muxes** (`ub`/`vb`, 12×32:1 selecting instruction
bytes at any `flin[4:0]`) into the `u_icache` instance. Proof: the standalone icache
has F7=2,052, the full core F7=14,478 — so ≈12.4 K F7 muxes live in the SPINE decode,
not the cache. Moving the icache STORAGE to BRAM removes the LUTRAM read mux (a
minority) but leaves the byte‑window MUXF — the real congestion mass — untouched.

**Verdict on the lever:** `+VEN_IC_BRAM` is a fully‑validated, removable option that
does NOT improve OOC placed Fmax. It is KEPT (not default, not in the best config)
because it (a) proves a registered‑read L1 fetch pipeline is BIT‑EXACT +
CYCLE‑ACCURATE — directly de‑risking the L1/AXI subsystem's registered‑read D‑cache —
and (b) trades 3,072 LUTRAM for 5 BRAM tiles, useful if a future floorplan is
LUT/LUTRAM‑bound. The REAL congestion lever is the byte‑window decode MUXF, which is
fundamental to the single‑cycle x86 fast‑path decoder: relieving it needs a
DECODE‑STAGE pipeline (register `ub`/`vb`, decode next clock — another cycle‑model
change, same class as this fetch pipeline) OR the full‑SoC floorplan (core no longer
device‑filling), which the README already commits the 66 MHz closure to.
_Captured 2026‑06‑07._

## P0‑9 — alternative Vivado synth/APR strategy sweep: does any directive break the wall?
Question: can a DIFFERENT Vivado strategy reach 66 MHz with NO RTL change? A 6‑agent
workflow (`wf_8911a8b0`) enumerated ~10 UNTRIED strategies, de‑duped against every prior
attempt, and ranked them into an experiment matrix; the top candidates were then tested
EMPIRICALLY at a MEETABLE clock with a FULL route — not the 15 ns placed estimate.

**The methodology correction (the big finding).** Every prior Fmax number — including the
README's "placed ≈ 47.6 MHz" — is a PLACER ESTIMATE at 15 ns. A full ROUTE shows the
MUXF‑dense design does NOT route legally there; the placer is satisfied but the router
physically cannot complete:

| flow | clock | placer WNS (est MHz) | ROUTE result |
|---|---:|---|---|
| default | 15 ns | −6.0 (47.6) | estimate only (README number) |
| default | 18 ns | — | **FAILED — 15,971 node overlaps** |
| AltSpreadLogic_high + AggressiveExplore | 18 ns | — | **FAILED — 4,524 overlaps** |
| **+ opt_design −muxf_remap** | 18 ns | — | **ROUTED, WNS −10.6 ns = 35 MHz** |
| AltSpreadLogic_high + AggressiveExplore | 20 ns | −0.52 (48.7) | **FAILED — 9,459 overlaps** |
| AltSpreadLogic_high + AggressiveExplore | 21 ns | +0.04 (47.6) | **FAILED — 15,110 overlaps** |
| AltSpreadLogic_high + AlternateCLBRouting | 22 ns | +0.517 (46.5, placement MET) | **FAILED — 6,651 signals / 11,905 overlaps** |
| AltSpreadLogic_high + AggressiveExplore (24/26 ns) | 24-26 ns | — | inconclusive — route thrashed >2 h, killed (AggressiveExplore worsened congestion) |

**Findings:**
1. **No directive breaks the wall.** The MUXF‑dense design will not route legally at the
   clock the placer estimates (47–49 MHz) — placed estimates are optimistic by several MHz
   vs the real routed number. Even AltSpreadLogic_high (the routability lever, which cut
   overlaps 15,971→4,524 at 18 ns) cannot make a tight clock route.
2. **`opt_design −muxf_remap` (the panel's rank‑1 lever) REGRESSES to 35 MHz.** It demotes
   the F7/F8 byte‑window muxes to LUT3 trees — which ARE routable (the ONLY flow that
   routed at 18 ns) — but (a) the LUT mux trees add logic depth (worst path 28 ns) and
   (b) the congestion just MOVES from MUXF to LUT (level‑6, 95 % LUT in the band). This is
   the definitive proof that the density is intrinsic to the byte‑window mux FABRIC, not
   to the MUXF resource: you cannot remap your way out of it.
3. The synth‑side MUXF reducers (`-directive AlternateRoutability`, `BLOCK_SYNTH.
   MUXF_MAPPING 0`) are the same MUXF→LUT trade and were not expected to differ.

**Conclusion (definitive).** No Vivado synth/place/route strategy reaches 66 MHz. The
congestion is an architectural property of the single‑cycle x86 byte‑window decoder
(12×32:1 muxes over 256‑bit lines), dense whether mapped to MUXF or LUT. The honest
ROUTED Fmax is **below the ~46–49 MHz placer estimate**: the best (narrowB) config
PLACES MET at 22 ns (46.5 MHz) but does NOT route legally at 18–22 ns (the router
gives up with thousands of congestion overlaps); the ONLY legally‑routed result in the
entire sweep was `‑muxf_remap` at **35 MHz**. So the real OOC routable Fmax is ≈
**35–42 MHz** (a relaxed clock or the muxf_remap LUT trade), NOT the 46–49 MHz placed
estimate. The only real
levers are: (a) **RTL** — pipeline/register the byte‑window alignment so the decode is
multi‑cycle, not one combinational 12×32:1 fold (a cycle‑model change, the same class as
the validated `+VEN_IC_BRAM` fetch pipeline); or (b) a lower‑utilization device / a manual
in‑context floorplan. CAVEAT on the "full‑SoC closes 66 MHz" hope: the core fills 76‑82 %
of the PL die regardless of OOC vs in‑context, so full‑SoC integration does NOT by itself
relax the byte‑window congestion — OOC whole‑die place already gives it maximum spreading
room. _Captured 2026‑06‑08._

## P0‑10 — decode‑stage pipeline (+VEN_DEC_PIPE) BUILT, MEASURED, REVERTED
Lever (a) from P0‑9 — pipeline the byte‑window alignment so the 12×32:1 mux leaves the
combinational eip cone. Designed by a 6‑agent workflow (decoupled PF→D1→D2 + a byte‑aligned
prefetch queue), built incrementally + gated: fp_len length‑only sub‑decoder (proven
fp_len==fp_decode.len over all 131,072 (b0,b1,cyc)); a 32‑byte sliding‑window prefetch queue
(8:1 word‑select fill, mirror‑verified iq==ic_byte over make verify + Quake 200k); then the
CUT — re‑source ub/vb from the queue. **Functionally bit‑exact (make verify 75/75, no hang,
queue == icache).** But the OOC SYNTH probe (+VEN_IC_BRAM +VEN_DEC_PIPE, 18 ns) was a clear
NEGATIVE:
* **MUXF went UP, not down: F7 14,457 → 17,342, F8 6,202 → 7,066; LUTs 76.9 % → 87.9 %.**
* **Synth WNS −7.0 ns @ 18 ns ⇒ ~40 MHz (worse than narrowB 64.1).** Worst path =
  `eip_reg → iq_reg` (the prefetch FILL), 24.9 ns / 95 logic levels.

Two findings: **(1)** the byte‑alignment mux is CONSERVED — re‑sourcing ub/vb removes the old
12×32:1 but ADDS the queue slide barrel‑shift + the extract + the word‑prefetch, which sum to
MORE MUXF. Aligning 12 bytes from a 32‑position window is a ~12×32:1 mux no matter the phrasing
(shift / circular‑extract / original); pipelining RELOCATES it (off the critical path → better
LOGIC Fmax) but does NOT reduce its DENSITY, which is the congestion. **(2)** the shadow shortcut
(queue slide derived from the live `flin`=eip) put the whole fill cone ON the eip path → the
`eip→iq` 95‑level path; a true decoupled `pfpc` (the full D1/D2 `dpc` restructure) would fix that
LOGIC path but still not the congestion. So the decode‑pipe cannot break the wall; **REVERTED**
(commits cce408b/7ea0464/6eff7f9/1397db0 undone). This is the THIRD independent confirmation —
after the tooling sweep (P0‑9) and BRAM (P0‑8) — that the x86 byte‑window decode MUXF density is
the architectural OOC floor (~45 MHz). The genuine remaining levers are a fundamentally
different front‑end (a PRE‑DECODED / µop instruction cache — predecode once at fill, the textbook
x86 Fmax fix), a faster/bigger device, or accept ~45 MHz. _Captured 2026‑06‑08._

## P0‑11 — PREDECODE‑ON‑FILL µop‑cache (+VEN_UOPCACHE): MUXF drops for the FIRST time, but OOC congestion holds (DIFFUSE)
The textbook fix P0‑10 pointed at, and the user's P5‑decode insight (predecode prefixes ~1 byte/cycle,
pipeline the SIB length decode). Built behind `+VEN_UOPCACHE` (default build byte‑identical): a new
`rtl/mem/uopcache.sv` runs the EXISTING `decode` leaf on the multi‑cycle line fill — decoding the
FIXED bottom 6 bytes of a `residual` register and SHIFTING it right by the decoded `len` each cycle
(a ≤48‑bit barrel shift, never a flin‑indexed 32:1 byte select) — and stores fixed‑width `fpd_t`
per SLOT + a byte→slot map in a registered‑read (BRAM) store. The fast path then DELETES the twelve
32:1 byte selects (the `ub[]/vb[]` gather, core.sv:2930‑31) and reads `u_d = slots[slot(flin)]` via
an ~8:1 slot mux; because predecode CHAINED the boundaries, `v_d` is literally U's NEXT slot, so the
`flin+lenU` V‑base serialization is gone too. `br_taken` (the only flag‑dependent field) is re‑evaluated
from the stored `cc` against live `eflags` (as the V path already does). Synth probe (`synth_paths_uopcache.tcl`,
+VEN_IC_BRAM +VEN_UOPCACHE, 15 ns OOC):
* **MUXF7 14,457 → 11,291 (−22 %), MUXF8 6,202 → 4,152 (−33 %) — the FIRST EVER MUXF REDUCTION**
  (P0‑3/8/9/10 all CONSERVED it). Confirms: DELETING the gather (vs relocating) does reduce MUXF.
  LUT flat (76.9 → 76.5 %), FF +1 %, +40 BRAM tiles (URAM still 0 — store can move to the 64 idle URAMs).
* **Synth WNS −2.783 @ 15 ns ⇒ 56 MHz** — but the worst path is `fpp_b_reg → u_fpu_state/fpr_reg`,
  the SAME x87 FP‑mantissa CARRY8 chain that was narrowB's 64.1 ceiling (P0‑7). Logic 6.56 ns ≈ unchanged;
  the +2.4 ns is the FP path's synth ROUTE ESTIMATE drifting with the added BRAM/store cells. **The byte
  gather was the CONGESTION limiter, never the synth‑Fmax limiter (the FP datapath is).**
* **Placed congestion UNCHANGED — level‑5, u_icache 97 %, MUXF 59‑63 %** (vs narrowB level‑5/99 %/58‑62 %).

Why removing the BIGGEST single contributor didn't move OOC congestion — a per‑hierarchy MUXF attribution
(`probe_muxf_attrib.tcl` flatten none + `probe_muxf_buckets.tcl` name buckets) shows the remaining 11,291 F7
is **DIFFUSE across the coupled front‑end**, no single dominant structure:
**BTB 2,592 (23 %, a FF‑array combinational 64:1 lookup mux — the icache‑BRAM pattern, untouched) ·
icache 2,060 (18 %) · core‑inline "other"/issue 2,880 (25 %) · slow‑path ibuf decoder ≥1,444 (13 %) ·
the new fast‑slot read 1,147 (10 %) · ALU 89 · FP 268.** Every front‑end block hangs off `eip`/`flin`,
so the **OOC placer (no PS8 anchor, no floorplan) smears the whole cluster into one clock region** →
the band re‑saturates from whatever's left after any single lever. **FOURTH confirmation** the OOC wall
is robust to front‑end MUXF removal, now with the mechanism: it is DIFFUSE + PLACEMENT‑COUPLED, not one
mux tree. Implications: (1) piecemeal RTL MUXF removal has hit diminishing returns — slow‑decode (13 %,
riskiest) won't clear it; the BTB (23 %, clean RAM‑conversion) is the best remaining RTL target. (2) The
cure for diffuse‑coupled congestion is FLOORPLAN / IN‑CONTEXT place (spread the cluster across regions
near PS8 — the brainstorm rank‑2, also the real‑chip number we must measure to ship). The µop‑cache is
KEPT (non‑default, the first MUXF win + textbook fix) pending verify‑hardening. _Captured 2026‑06‑08._

## P0‑13 — FP datapath AREA: −9,635 LUT (−10.7 % of the core), bit‑exact
The FP datapath was ~⅓ of the core (NOT half): inline `f_eval` arith ≈ 11,043 LUT (measured by stubbing
`f_eval` to passthrough → the synth delta) + the dedicated modules (u_bcd 5,320, u_sqrt_iter 3,289,
u_fpu_state 3,138, u_srt_div 1,521, u_bcd2fp 1,080) + inline compares/conv. The 64×64 mantissa multiply
is **already in DSP** (16 of the 31 DSP48s; `use_dsp` was a no‑op — the rest are integer MUL/IMUL), so the
multiply was never the LUT cost. The 128‑bit `f_eval` add/round width is load‑bearing (bit‑exact x87
cancellation + denormal normalize) → mostly irreducible. Two SAFE bit‑exact wins (µop‑cache config,
flatten none, `probe_lut_quick.tcl`):
* **`fx_to_int_ex` 128→64‑bit (fpu_x87_pkg.sv): −8,636 LUT.** The conversion value is a 64‑bit mantissa
  shifted by ≤63, so `big`/`fpart`/`half`/`ish`'s high 64 bits are ALWAYS zero — narrowing them drops
  *no* information. The function is duplicated across FIST_M16/M32/M64 + fx_to_int_errata + ven_bcd
  (FBSTP), so the narrowing halved the 128‑bit barrel shifter in EVERY instance at once. The single
  biggest area win of the session.
* **shared‑round f_eval split (+VEN_FP_PIPE deferred commit, core.sv): −999 LUT.** The full `f_eval`
  builds `fx_add`'s AND `fx_mul`'s `fx_round_pack` cones; the verified `f_eval_s2(f_eval_s1(...))` split
  muxes the two fronts → one shared round_pack. Guarded on +VEN_SRT_ITER (div is engine‑routed there, so
  s1's div‑default‑0 is unreachable; without it the full f_eval is kept).

**89,634 → 79,999 LUT** (µop‑cache config); the SAME win lands in narrowb/default (the conversion is in
the default build via FIST). Verified bit‑exact: `make verify` 75/75 + cycle bands + m3 75/75 + verify‑bcd
+ verify‑fbld + verify‑fppipe (1M vectors). Default build affected (fx_to_int_ex) but byte‑equivalent in
behaviour. NEGATIVE follow‑up (TRIED, REVERTED): merging the three per‑width FIST conversions
(M16/M32/M64) into ONE runtime‑width `fx_to_int_ex` call REGRESSED +8,809 LUT (79,999→88,808) — a runtime
`width` defeats the constant‑folding of each conversion's range‑check that makes the three constant‑width
calls cheap; KEEP them separate. _Captured 2026‑06‑08._

## P0‑14 — FULL APR ROUTE: the µop‑cache ROUTES at 15 ns where narrowb cannot (corrects P0‑11)
A full synth→place→**route** run of both configs at a 15 ns target (`apr_run.tcl`, post FP‑area win)
delivered the first clean ROUTED number — and a correction to P0‑11. The placer's *congestion‑level*
metric is a coarse estimate that stayed **level‑5 for BOTH** configs (which is why P0‑11 concluded "the
µop‑cache doesn't move OOC congestion"); the **router is the real judge**, and it tells a different story:
* **narrowb+FP @ 15 ns: does NOT route** — the router stalls at Phase‑5 global iteration 1 with
  **42,392 nodes‑with‑overlaps** (congestion it cannot resolve). Placed 46.0 MHz, but unroutable at 15 ns.
* **+VEN_UOPCACHE+FP @ 15 ns: ROUTES CLEAN — 0 failed nets, routed WNS −4.354 ns ⇒ 51.7 MHz routed.**
  The router drove overlaps to 0 by iteration ~8. The lower byte‑window MUXF (F7 14,311→11,101,
  F8 6,216→4,181) gives the router the channels it lacked under narrowb.

So the µop‑cache (P0‑11) + the FP‑area win (P0‑13) **broke the OOC routing wall**: the design routes
legally OOC for the first time, at **51.7 MHz** (vs the prior ~35–42 MHz *estimate* for the unroutable
narrowb). The earlier "MUXF removal doesn't help congestion" reading was an artifact of trusting the
placer's level metric over an actual route. **The route is the judge.** Remaining gap to 66 MHz is now
plausibly closable by in‑context place + floorplan (P0‑12) on top of the µop‑cache — once it is
verify‑hardened (the `uop_ready` stall + branch‑into‑middle re‑predecode are still unbuilt). Util:
narrowb 93,883 LUT (80.2 %) / µop‑cache 79,442 (67.8 %); both bit‑exact for the FP changes (`make verify`
75/75), µop‑cache front‑end functional‑hardening pending. _Captured 2026‑06‑08._
