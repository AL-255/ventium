# One image, runtime core-clock sweep

Status (2026-10-16): controller implemented and unit-tested; one full **40 MHz**
synthesis/implementation is running. **Not yet deployed or physically qualified.**
There are no per-frequency builds in this flow. The earlier fixed-clock variant
attempts were cancelled and never deployed.

The physical fixed-40 MHz parallel-write parent passes both 2,000-iteration
CoreMark seeds, at 2.100118 / 2.106790 CM/MHz. Those passes do not qualify the new
clock image. Its CPU/cache sources are byte-identical to that frozen parent,
including all 159 defines and `cycle_mode(1'b1)`; the dirty CPU checkout is not
ingested. `prepared.json` inventories every frozen file and explicitly lists the
three integration edits and two new clock RTL files. The parent's old manifest
is retained as ancestry, not relabelled a new simulator or hardware pass.

Current verified gameplay baseline: **0.490014174 total U+V IPC**, simulation
executable `b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e`,
cycles **1,100,065,247–3,100,065,247**. It predates this candidate, which has no
gameplay measurement. CoreMark counters are not gameplay IPC.

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
  to `0xffff`, as required by XAPP888. Afterward it writes `0x0100` for this
  integer, zero-phase, no-fine-phase/no-spread-spectrum configuration before
  releasing reset, following current UG572's interpolator-enable rules. Both
  writes are checked on the documented `0x9999` readable-bit mask; reserved bits
  are not assumed readable. This controls internal interpolators, not voltage.
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
so BD inference cannot mistake it for a clock. It is the active corrected build,
owned by `ventium-programmable-clock-oct16-r3.service`, invocation
`fa0d86b28c7840e39ee050af6d348483`. There will be one completed image and one
deployment, with no frequency-specific synthesis/route/bitgen variants.
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

## Physical procedure (pending this image)

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
   guest reset does not clear the board's cumulative debug retirement counters.
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
retirement counters also survive, and each trial subtracts its own baseline.
This is a source-level reset-path check, not a substitute for passing both
physical seeds repeatedly on the new image.

CoreMark clock qualification is not standard-suite acceptance. Physical Win95
cold boot + interaction and a full Quake timedemo remain separate requirements
before claiming general FPGA acceptance of this new image.

Register reference: [AMD UG572 MMCM registers](https://docs.amd.com/r/en-US/ug572-ultrascale-clocking/MMCM-Registers)
and [DRP operation](https://docs.amd.com/r/en-US/ug572-ultrascale-clocking/Dynamic-Reconfiguration-Port).
The power-enable prerequisite is in [XAPP888, Power Group/Table14](https://docs.amd.com/api/khub/documents/ZY272QvKAP3T95qOg6QhDg/content).
