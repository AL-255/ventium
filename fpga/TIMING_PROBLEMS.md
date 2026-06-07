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
