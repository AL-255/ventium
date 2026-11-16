# Programmable Core Clock & Runtime MMCM DRP Controller

## Hardware & Qualification Status (`c0e3fe43`, 2026-11-14)

On **RK-XCZU15EG-F** (`xczu15eg-ffvb1156-2-i`, Vivado **2025.2**), board-qualified
release image **`c0e3fe43`** (`main`, 161 defines, `retime_muxf_route_first`,
`cycle_mode = 1'b1`) drives `clk_core` from a single UltraScale+ `MMCME4_ADV`
(`fpga/ven_programmable_clock.v`) managed by an always-on 100 MHz EMIO GPIO/DRP
controller (`fpga/ven_pll_ctrl.sv`).

- **Post-Route Static Timing Sign-Off (`N = 25`, `40.000 MHz` Boot Clock):**
  Closed at **`40.264133 MHz`** (`WNS = +0.164 ns`, `WHS = +0.010 ns`, `0`
  failing endpoints, `0` `>=85%` congestion hotspots, `171,819` LUTs, `30,703`
  CLBs; always-on `100.000 MHz` PS/HP0 AXI4 domain `WNS = +5.691 ns`).
- **Physical Standard Suite at `40.000 MHz` (`U/V + fast-pipe`):** Passes both
  4,000-iteration **CoreMark** seeds (`2.100128 / 2.106796 CM/MHz`), cold
  **Windows 95 OSR2** multi-application GUI with interactive PS/2 mouse/keyboard
  + clean shutdown, and cold **DOS Quake `timedemo demo1`** (**`8.0 FPS`**,
  `969` frames in `121.2 s` at measured `39.999802 MHz`).
- **Current Verified Physical Gameplay IPC:** **`0.515778001` total U+V IPC**
  (`0.397847833` primary/U-only IPC) on image **`c0e3fe43`** across interior
  Quake gameplay cycles **`28,696,827,616–32,989,404,795`** (counters include
  `REP`-element retirement). Prior release baseline `2886d24c` measured
  `0.496499864` total U+V / `0.383002768` primary/U across cycles
  `625,021,130,428–629,480,208,865` (`7.7 FPS`). Unmeasured rebuilds and
  post-freeze `experimental/uv-fast-ipc-apr` candidates do not inherit
  `c0e3fe43` qualification.

### Single-Image Runtime DRP Overclock Sweep (`c0e3fe43` vs. `2886d24c`)

All operating points below run on the **same programmed bitstream** via GPIO
mailbox divider switches without rebuilding, reprogramming, or altering PS
clocks or voltages:

| Divider `N` | Nominal Core Clock | Image `c0e3fe43` Physical Result (`40.264 MHz` STA) | Prior `2886d24c` Baseline (`28.702 MHz` STA est.) | Qualification Scope |
| ---: | ---: | --- | --- | --- |
| **25 (boot)** | **40.000 MHz** | **PASS — Full Standard Suite** (CoreMark ×2, cold Win95 GUI + shutdown, Quake `8.0 FPS` + gameplay) | CoreMark ×2 + Quake `7.7 FPS` (Win95 unqualified; `WNS = -9.841 ns`) | **Vivado 2025.2 slow-corner STA sign-off (`c0e3fe43`)** |
| **20** | **50.000 MHz** | Covered by higher Win95 + Quake passes | CoreMark ×2 PASS (`2.100127 / 2.106795 CM/MHz`) | Empirical single-board DRP point |
| **19** | **52.632 MHz** | Covered by higher Win95 + Quake passes | CoreMark ×2 PASS (max passing point on `2886d24c`) | Empirical single-board DRP point |
| **18** | **55.556 MHz** | Covered by higher Win95 + Quake passes | CoreMark TIMEOUT (`1.21M` U+V events) | Empirical single-board DRP point |
| **17** | **58.824 MHz** | **PASS (`+47.1%`)** — Cold Win95 OSR2 multi-app GUI + clean shutdown + Quake `demo1` + interactive `E1M1` | Untested (above `55.56 MHz` failure) | Empirical warm-die single-board pass (not STA) |
| **16** | **62.500 MHz** | **PASS (`+56.25%`)** — Cold FreeDOS + Quake `demo1` (**`11.6 FPS`** wall-clock) + interactive `E1M1` + clean DOS exit | CoreMark TIMEOUT (`886K` U+V events) | Empirical single-board Quake max (not STA) |
| **15** | **66.667 MHz** | Exceeds physical setup margin on this board | Untested | Above single-board silicon margin |

> **STA vs. Empirical Overclocking:** Post-route static timing sign-off covers
> **`40.000 MHz` (`N = 25`) only**. Runtime DRP frequencies above `40 MHz`
> (`58.824 MHz`, `62.500 MHz`) are empirical single-board silicon measurements
> on `c0e3fe43`, not multi-board PVT guarantees. Core-clocked platform timers
> (`8254` PIT / peripheral ticks) scale proportionally with `CLKOUT0`.

---

## Clock Topology & Hardware Safety Interlock

- **Fixed VCO & Reference Domain:** ZynqMP PS `pl_clk0` and `S_AXI_HP0_FPD`
  remain fixed at **`100.000 MHz`**. `MMCME4_ADV` runs with
  `CLKFBOUT_MULT_F = 10`, `DIVCLK_DIVIDE = 1` (`1.0 GHz` VCO), and boots at
  `CLKOUT0_DIVIDE_F = 25` (`40.000 MHz`).
- **Integer Runtime Dividers:** Only `CLKOUT0`'s integer divider `N` (`10..50`,
  yielding `100.000..20.000 MHz` as `1000 / N` MHz) changes at runtime.
  Feedback, VCO, phase, lock/filter tables, and supply rails are untouched;
  fractional or CDDC states are rejected.
- **Always-On Control Plane:** `ven_pll_ctrl` runs on the ungated `100 MHz`
  reference clock and communicates over ZynqMP EMIO GPIO so PS software retains
  full visibility and recovery control while `clk_core` is gated or relocking.
  Never touch core-clocked AXI-Lite MMIO (`0xA000_0000`) while `clk_core` is
  stopped or unlocked.
- **Hardware Reset + Posted-DDR Drain Interlock (`pll_safe`):** A divider
  transition is admitted **only** when guest reset is held **and**
  `ven_ddram_axi_posted` reports true external DDR4 write-queue drain with zero
  sticky DDR fault continuously for **32 reference clocks**. Unsafe requests
  are rejected in hardware without stopping or glitching a running guest.
- **XAPP888 DRP Sequence (`ven_pll_ctrl.sv`):**
  1. Gate `clk_core` (`BUFGCE`) and assert `MMCME4_ADV.RST`.
  2. Write UltraScale+ DRP power group register **`0x27 = 0xFFFF`** and verify
     masked readback (`& 0x9999`), keeping `0xFFFF` enabled through relock per
     AMD XAPP888 / Clock Wizard `clk_wiz_v6_0`.
  3. Read-modify-write `CLKOUT0` DRP registers **`0x08` / `0x09`** (`HIGH_TIME`,
     `LOW_TIME`, `EDGE`, `NOCOUNT`) and verify exact readback of both words
     plus `0x27`.
  4. Release `MMCME4_ADV.RST`, wait for stable `LOCKED` within the `2^24`-cycle
     (`167.8 ms`) watchdog, then re-enable `BUFGCE` and toggle `ACK`.
  5. On timeout, readback mismatch, or loss of `pll_safe` mid-sequence,
     `clk_core` stays gated and `RST` stays asserted (`error = 1`); a later
     valid mailbox request (such as `--divider 25`) recovers cleanly without
     PCAP reprogramming. Fabric reset (`pl_resetn0`) explicitly rewrites
     `N = 25` via DRP because `MMCME4_ADV.RST` alone does not reset DRP RAM.

---

## EMIO GPIO Mailbox ABI 1

`zynqmp_gpio` exposes 78 MIO + 95 configured EMIO lines. Lower EMIO lines are
board-owned; `fpga/board-tools/ven_pll_clock.py` verifies chip identity and
claims only dedicated upper offsets:

| Direction | EMIO Slice | Linux `gpiochip` Offsets | Width / Encoding |
| --- | --- | --- | --- |
| **PS → PL Command** | `EMIO[47:32]` | `110..125` | `[15]` req toggle, `[14:7]` magic `0xC1`, `[6:0]` divider `N` (`10..50`) |
| **PL → PS Status** | `EMIO[94:64]` | `142..172` | `[30:16]` `0x504C` (`[31]` = `0`), `[15:14]` ABI `1`, `[13]` `mmcm_rst`, `[12]` `pll_safe`, `[11]` ack toggle, `[10]` `locked`, `[9]` `error`, `[8]` `busy`, `[7]` `clk_en`, `[6:0]` committed `N` |

To prevent spurious commands across non-atomic multi-line GPIO direction/value
setup, `ven_pll_clock.py` first matches `ack_toggle` with cleared magic, stages
`[14:0]`, waits `>= 1 ms`, and flips bit `15` last while keeping the payload
stable through `ack_toggle`. Healthy locked `40 MHz` idle status with
reset/drain held reads **`0x504C5499`**.

---

## Simulation & Host Tooling Verification

Run the standalone DRP fault-injection BFM + AMD UNISIM `MMCME4_ADV`/`BUFGCE`
sweep across all 41 dividers (`10..50`) and safety/error corners without Vivado:

```sh
TMPDIR=/home/yukidama/external/tmp bash fpga/test_programmable_clock.sh
```

Run the host controller, clock-admission, and trial-accounting unit tests:

```sh
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
  PYTHONPATH=fpga:fpga/board-tools python3 -B -m unittest \
  test_ven_board_debug_contract test_ven_pll_clock test_ven_cold_clock \
  test_ven_pll_reset_probe test_ven_coremark_clock_trial \
  test_coremark_clock_media test_coremark_clock_audit
```

---

## Repeatable Physical Clock-Change Procedure

1. **Quiesce & Drain First:** Stop any active guest daemon, assert guest reset,
   and verify external posted-DDR4 drain (`0x50440003`) before requesting a
   clock change. Program the raw bitstream once per image qualification; never
   reprogram between divider points.
2. **Inspect & Switch via GPIO Mailbox:**
   ```sh
   sudo python3 -B fpga/board-tools/ven_pll_clock.py                # read-only GPIO status
   sudo python3 -B fpga/board-tools/ven_pll_clock.py --divider 17   # switch to 58.824 MHz (reset+drain held)
   sudo python3 -B fpga/board-tools/ven_pll_clock.py --divider 25   # restore 40.000 MHz STA-signed-off clock
   ```
3. **Independently Measure Clock & Execute in `U/V + fast-pipe` Mode:** Before
   releasing guest reset, measure actual `clk_core` frequency over a 5-second
   window (`ven_cold_clock.py` at `40 MHz`, or `ven_coremark_clock_trial.py`
   across arbitrary dividers). Never treat the 7-bit divider echo alone as a
   frequency measurement or use 40 MHz-calibrated guest timer prints to score
   an overclock.
4. **Counter Epoch Accounting:** The debug aperture's cumulative **primary/U**
   retirement counter persists across guest resets, whereas the core's **total
   U+V** scan counter (`ventium_top.retire_n`, debug selectors `76/77`) clears
   on core reset. Always difference each counter against its own start-of-trial
   baseline within the same run, and prove fresh paired V-pipe retirements
   (`delta_uv > delta_u`) under `cycle_mode = 1`.
5. **Restore Baseline After Sweeps:** Always step back to `--divider 25`
   (`40.000 MHz`), verify `0x504C5499` + measured `~40.000 MHz` with guest reset
   held and posted DDR4 drained (`0x50440003`), and retain any failed
   high-frequency trial logs honestly.

References:
- [AMD UG572 UltraScale Architecture Clocking Resources (MMCM DRP)](https://docs.amd.com/r/en-US/ug572-ultrascale-clocking/Dynamic-Reconfiguration-Port)
- [AMD XAPP888 MMCM/PLL Dynamic Reconfiguration (Power Group `0x27`)](https://docs.amd.com/api/khub/documents/ZY272QvKAP3T95qOg6QhDg/content)
