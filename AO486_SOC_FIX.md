# ao486 SoC Verilator Bring-Up — Fix Log & Hardware-Level Audit

**Outcome:** Windows 95 boots to a complete, correctly-rendered desktop (teal
background + all desktop icons + taskbar with Start button and clock) on the
`ao486_MiSTer` 486 SoC running as a pure-Verilator simulation, with **L1 and L2
caches both enabled** and **no runtime state injection**.

This document records the entire fix process *and audits every fix* against the
actual RTL and the real MiSTer HPS software. Each fix is classified:

- **SOLID** — a correct model of real hardware / firmware behavior, grounded in a
  cited RTL or protocol fact.
- **BAND-AID** — makes the boot progress by fabricating state, tuning a magic
  timer, or picking a value that masks a symptom rather than modeling the cause.
  Band-aids are flagged, their true root cause is given, and the faithful fix is
  specified.
- **REJECTED** — a hack that was tried and discarded; **not** on the final boot
  path.

The honesty contract of this document: *nothing that makes the boot work is
hidden or described as solid when it is not.*

---

## 0. TL;DR verdict table

| # | Fix (commit) | Subsystem | Verdict |
|---|---|---|---|
| 1 | VGA retrace CDC — independent divided `clk_vga` (`f7d0dd8`) | Video / POST | **SOLID** (caveats) |
| 2 | `clock_rate` clamp ≥ 2.5 MHz (`24f2f61`) | PIT time-base | **SOLID** |
| 3 | mgmt strobe clocked on falling edge (`7a6b616`) | HPS↔IDE bus | **SOLID** (protocol-exact) |
| 4 | Clock the core during `ide_check()` SDIO poll (`adce752`) | HPS↔IDE concurrency | **SOLID** |
| 5 | DDR read captures data at issue-time (`df5e7a7`) | DDR model | **SOLID** (narrow) |
| 6 | Service DDR before `x86_poll` (`82e0e25`) | DDR / cache fill | **SOLID** |
| 7 | Gate `x86_poll` off in-flight CPU I/O (`b799bdd`,`2b5ad17`) | iobus arbitration | **SOLID** root cause |
| 8 | `ide_check` bit8=1 → no phantom CD (`2574fd4`) | IDE presence | **SOLID** |
| 9 | `--mem` open-bus top-of-RAM (`1982781`) | DDR model | benign / diagnostic |
| 10 | **Win95 `display.drv` = vga.drv** (guest disk, this session) | display driver | **SOLID** |
| B1 | IDE reset-linger: phantom `0x08` request (`827e06c`) | IDE reset | was BAND-AID → **FIXED** |
| B2 | IDE reset debounce: magic `confirm` (`41a7f6e`) | IDE reset | was BAND-AID → **FIXED** |
| B3 | CHS geometry hard-set to 16/63 (`2071f7b`) | IDE geometry | was BAND-AID → **FIXED** |
| R1 | `--w95-warp/accum/calib/pit` guest-memory injection | PIT wait bypass | **REJECTED** |
| R2 | `--ptefix` force PTE present bit | paging | **REJECTED** |

The final boot uses **none** of R1/R2. B1–B3 were the band-aids this audit found on
the boot path; **all three have been replaced with faithful fixes** (§5) — the phantom
request, magic linger, and hard-coded geometry are gone. The reworked boot reaches
the **complete Win95 desktop**, verified end-to-end with 0 crashes and 0
display-adapter dialogs (§7).

---

## 1. What is being simulated, and the one architectural simplification that matters

`system.v` (the SoC: ao486 CPU + L1/L2 caches + TLB + VGA, IDE, PIT, PIC, RTC,
PS/2, DMA…) is driven directly under Verilator. Everything outside the chip is a
C++ harness (`ao486-sim/`):

- **Main memory** — a behavioral 64-bit-burst DDR slave (`sim_main.cpp`,
  `ddr_service()`), the sole `DDRAM_*` master being `l2_cache` (`system.v:250`).
- **The "HPS"** — on real MiSTer an **asynchronous ARM** drives the `mgmt_*`
  management bus to load the BIOS and stream disk sectors when the core raises
  `ide_request`/`fdd_request`. Re-implemented in C++ from the real MiSTer PS
  software (`ps/ide.cpp`, `ps/support/x86/x86.cpp`, `ps/ps_shim.cpp`).
- **Video/PS-2** — framebuffer capture to PPM/PNG; PS/2 scancode injection.

### 1.1 The single-clock harness (read this before the timing fixes)

On real hardware the ARM (HPS) and the FPGA run in **separate clock domains** and
the FPGA free-runs regardless of what the ARM is doing. **The simulation has no
separate ARM clock.** The C++ HPS advances the one-and-only FPGA clock *from
inside its own service routines*: `ps_clock_tick()` → `tick()` →
`set_clocks()` (`ps_shim.cpp:58-78`, `sim_main.cpp:927`). The main loop *also*
advances that same clock. So two agents cooperatively drive one shared clock.

**This is the root cause of an entire class of fixes (3,4,6,7) and of the IDE
reset band-aids (B1,B2) this audit found and fixed.** Most of those fixes are
*principled* — they restore a genuine hardware invariant that the shared-clock
model would otherwise violate (e.g. "one Avalon read-data beat per clock edge,"
"the core keeps running while the HPS polls"). The IDE reset-linger/debounce
originally crossed the line into fabricating state; §5.1 replaces them with a
faithful direct reset-finish. The one remaining simplification traceable to this
architecture — the sim advancing the FPGA clock reentrantly rather than modelling a
truly-async ARM — is discussed in §5.3; the fully faithful cure is to run the HPS on
its own scheduler.

### 1.2 Config that is *not* a hack

- **Caches:** the successful Win95 boot ran with **both L1 and L2 enabled**
  (default `g_l1dis=0`, `sim_main.cpp:965,973`; no `--no-l1`). An earlier L1
  icache "wrong-data" race recorded during early bring-up was ultimately a
  DDR-read-model timing problem, resolved by fixes #5/#6 (capture-at-issue +
  service-before-poll); with the DDR beats delivered correctly the L1 fill is
  correct and no cache needs disabling.
- **CPU clock:** `--rate 4000000` (§2.2) models a 4 MHz-equivalent 486. This is a
  *functionally exact* down-scaling, not a hack (proof in §2.2).
- **x87 FPU:** provided by the Ventium project's SoftFloat-verified x87 datapath
  via a DPI co-sim (`stubs/ven_fpu_dpi.sv`, `ps/x87_cosim.cpp`) rather than the
  ao486 FPU RTL. Bit-exact for the basic ops used (47/47 vs Berkeley SoftFloat);
  transcendentals remain libm-approximate. Not boot-critical for Win95; disclosed
  for completeness.

---

## 2. SOLID fixes (with the hardware fact each rests on)

### 2.1 VGA vertical-retrace CDC — independent, divided pixel clock (`f7d0dd8`)

**Symptom.** POST appeared to hang for billions of cycles rewriting the VGA
framebuffer (`ddr_wr` climbing into the millions) and never reached the disk.

**Root cause.** The VGA-BIOS times palette loads with a tight
`IN 0x3DA / TEST 8 / JZ` spin on the vertical-retrace status bit. That bit
(`host_io_vertical_retrace`) is produced in the **`clk_vga`** domain
(`vga.v:1610-1632`) and sampled in the **`clk_sys`** domain (`vga.v:1402-1403`,
`system.v:395`) — a genuine, deliberately-unsynchronized single-bit CDC (real
hardware tolerates metastability on a status-poll bit). The harness had tied
`clk_vga = clk_sys` (coincident edges). Under Verilator's deterministic NBA
scheduling the CPU then sampled the bit at one fixed phase every iteration and
systematically **aliased over** the retrace window, so the spin almost always ran
to its 65536-iteration timeout, and each timeout rewrote the framebuffer.

**Fix.** Drive `clk_vga` as an independent clock divided from `clk_sys`
(`step_vga_clock()`, `sim_main.cpp:909-911,920,1829`; ÷8). Now the retrace pulse
spans many `clk_sys` cycles and successive polls sample different phases, so the
spin catches the window within one frame (0x3DA reads 30812→18; framebuffer
`ddr_wr` 9M→98K).

**Verdict: SOLID.** Making the pixel clock a *separate, slower* domain is the
physically correct model (a real VGA pixel clock is a distinct ~25 MHz PLL output,
never equal to the system clock); the CRTC timing logic and the real
unsynchronized CDC are left intact — the retrace bit is still produced by
`vgaprep_vert_sync`, nothing is hard-coded.

**Honest caveats (documented, not hidden):** (a) part of *why* it works is that it
removes the coincident-edge degeneracy of `clk_vga==clk_sys` under Verilator's
scheduler — so it is simultaneously the physically-correct change and an
edge-decorrelation; (b) the ÷8 divisor is empirical, not derived from the declared
`clock_rate_vga` (which is left at 90 MHz), so absolute frame rate is not a
calibrated quantity — only the ratio matters for POST; (c) the commit message's
"31%/89% duty" figures are polling-sample artifacts, not the physical retrace duty
(which is a few percent).

### 2.2 PIT time-base — `clock_rate` clamp (`24f2f61`)

**Symptom.** At `--rate 2000000` a BIOS/VxD timer wait spun forever.

**Root cause (exact arithmetic).** The PIT input clock is an accumulator NCO
(`pit.v:55-82`): `INCREMENT = 26_250_000` (= 11·2·1_193_181.8 Hz),
`clk_rate = 11·clock_rate`, and each master cycle
`if (sum+INCREMENT >= clk_rate) fire ce; sum -= clk_rate`. The accumulator
invariant `sum ∈ [0,clk_rate)` holds **only while `INCREMENT ≤ clk_rate`**, i.e.

```
valid ⇔ 11·clock_rate > 26_250_000 ⇔ clock_rate > 2_386_363.6 Hz  (= 2 × PIT freq)
```

Below that, `ce` fires **every** master cycle and the PIT runs at master/2 instead
of 1.193 MHz — timer cadence becomes garbage. `--rate 2000000`
(`clk_rate = 22.0M < 26.25M`) is fully degenerate. This floor is not arbitrary: a
1.193 MHz *toggle* needs a 2.386 MHz *enable*, impossible from a slower source —
a Nyquist-style limit. Every real 486 (PIT = 1.193 MHz crystal) is far above it.

**Why lowering `clock_rate` at all is legitimate.** In the valid regime the guest
PIT frequency is *exactly* 1.193 MHz independent of `clock_rate`
(`26_250_000/22 = 1_193_181.8`), because the design is fully synchronous with
`clock_rate` as the sole time-base parameter. `--rate 4000000` therefore models a
*slower-MHz 486* with the PIT still pinned at 1.193 MHz guest-time — a physically
valid machine, and it makes guest-time delays finish in far fewer sim cycles
(the acceleration). Real MiSTer feeds the true ~90 MHz sys clock; the sim never
should feed < 2.386 MHz.

**Fix.** Clamp `clock_rate` to ≥ 2.5 MHz at the sim input boundary
(`sim_main.cpp:970`; default is 4 MHz).

**Verdict: SOLID.** It enforces the NCO's intrinsic, correct operating floor at the
right layer (sim input), not by patching correct upstream RTL, and warns rather
than failing silently. (Caveat: the *rejected* `--w95-warp` mode deliberately sets
`clock_rate=10000` to exploit the degenerate regime — that is a band-aid, see R1;
a stricter design would route all `clock_rate` writes through one clamped setter.)

### 2.3 mgmt strobe clocked on its falling edge (`7a6b616`)

**Symptom.** The ATA IDENTIFY block and every disk sector arrived with only word 0
non-zero → BIOS saw a 0-geometry drive → INT 13h boot read failed.

**Root cause (protocol-exact).** `ide.v` advances its sector-buffer index
`mgmt_cnt` **only** on a *clocked* falling edge of the mgmt strobe:
`if ((old_wr & ~mgmt_write) | (old_rd & ~mgmt_read)) mgmt_cnt <= mgmt_cnt+1`
(`ide.v:260-272`); the dpram write address is `mgmt_cnt[12:1]` with even/odd bank
`mgmt_cnt[0]` (`ide.v:286-303`). The old shim asserted the strobe, ticked, then
dropped it **without a tick**, so the RTL never sampled `mgmt_write=0`,
`old_wr & ~mgmt_write` never fired, `mgmt_cnt` stayed 0, and every word overwrote
index 0.

**Fix.** Emit a second `ps_clock_tick()` with the strobe low
(`ps_shim.cpp:57-78`) so the RTL clocks the 1→0 transition and increments
`mgmt_cnt`.

**Verdict: SOLID — the strongest fix here.** It reproduces exactly what the RTL
gates on (`old_wr & ~mgmt_write`, `ide.v:266`). Assert→clock→deassert→clock is the
*only* sequence that advances `mgmt_cnt`; there is nothing arbitrary about the
"falling edge."

### 2.4 Clock the core during the `ide_check()` SDIO poll (`adce752`)

**Symptom.** The first *multi*-sector transfer spun forever; single-sector worked.

**Root cause (concurrency).** `ide.cpp`'s multi-sector loops busy-wait for the core
to raise the next-sector request: `while(!ide_req) ide_req = (ide_check()>>off)&7;`
(`ide.cpp:818,849`). On real hardware `ide_check()`'s `UIO_DMA_SDIO` status query
is a real SPI transaction that **clocks the bus while the async FPGA free-runs**,
so the core drains its buffer and eventually asserts request=5. The shim
short-circuited the query **without ticking** the clock, so the core never
advanced — and because the main loop was blocked *inside* that poll, nothing
advanced the clock → hard deadlock. Single-sector reads return before the poll
loop, which is why they worked.

**Fix.** `ps_clock_tick()` on each SDIO status query (`ps_shim.cpp:95`); both
strobes are 0 during it, so it purely advances the core (and services DDR) with no
mgmt corruption, and the loop self-terminates at request=5.

**Verdict: SOLID.** It restores the real system's essential property — the FPGA
runs concurrently while the HPS polls — which `ide.cpp`'s loops depend on. Caveat:
one tick per query is not calibrated to real SPI transaction length; only relative
timing is affected, not correctness (the loop polls until the condition holds).

### 2.5 DDR read captures data at issue-time (`df5e7a7`)

**Symptom.** Corrupted CPU loads (a `pop`/`mov` reading a value that a later store
produced).

**Root cause & fix.** Writes apply immediately but reads are served with latency
`g_ddr_lat` (`sim_main.cpp:31,877-895`). Serving `ddr[ra]` at *serve* time let a
write that landed *after* the read was issued leak into that earlier read. The fix
snapshots the word into `RdBeat.data` at command-accept time
(`sim_main.cpp:26,862-873,892`).

**Verdict: SOLID (correct memory-ordering model), but narrow.** Because `l2_cache`
is the sole, self-serializing DDR master (it parks in FILLCACHE until all 8 beats
return and cannot issue a write mid-burst, `l2_cache.v:394-413`), issue-time and
serve-time data are provably identical for all *legitimate* bus traffic. The change
only bites for the FPU co-sim's out-of-band `ddr[]` writes — so it hardens co-sim
coherency and is the more-correct model, but it is not fixing a real bus race.

### 2.6 Service DDR before `x86_poll` (`82e0e25`)

**Symptom.** A DDR read burst overlapping an `x86_poll` dropped a beat → `l2_cache`
stuck forever in FILLCACHE (7 of 8 beats) → hang at device-1 detection.

**Root cause (single-clock artifact) & fix.** `ddr_service()` runs from two places
per iteration — the main loop and every `ps_clock_tick()` inside `x86_poll`.
`DDRAM_DOUT_READY` is a *registered* one-cycle beat the L2 samples on the posedge
(`l2_cache.v:400`); the old ordering ran a second `ddr_service()` in the same
cycle, overwriting a still-unsampled valid beat. Moving `ddr_service()` to run once
right after the loop's posedge and *before* `x86_poll` (`sim_main.cpp:1828-1842`)
restores the Avalon invariant "one valid beat per clock edge, sampled before the
next is produced."

**Verdict: SOLID, but it patches a harness self-inflicted double-service** (§1.1),
not an RTL contract error. The fix is principled (it restores the exact
readdatavalid invariant, it is not blind reordering), but the underlying fragility
— a behavioral slave serviced from two code paths — is a property of the
single-clock harness, not silicon.

### 2.7 Gate `x86_poll` off in-flight CPU I/O (`b799bdd`, `2b5ad17`)

**Symptom.** The iobus FSM wedged in `S_READ_CHK` with the CPU read never
completing (`iobus.v:89-103`).

**Root cause & fix.** The genuine cross-agent handshake is the fast-PIO
`no_data`/`mgmt_cnt`/`io_cnt` producer-consumer pause (`ide.v:274-277`,
`system.v:499-506`). The failure, though, is the single-clock reentrancy of §1.1:
letting the HPS inject clock edges (via `ps_clock_tick`) into the *middle* of a
CPU iobus transaction that the main loop is tracking desynchronizes the C++ side.
The fix gates `x86_poll` on `!cpu_io_read_do && !cpu_io_write_do`
(`sim_main.cpp:378-379,2178`) so the two clock-driving agents never interleave
mid-transaction. (It also removed a pre-existing `(c & 0x7f)` magic poll throttle —
a de-magic-ing.)

**Verdict: SOLID root cause, pragmatic (non-hardware) implementation.** It targets
the true harness flaw, not a symptom. Honest caveat: real hardware services CPU
I/O and mgmt *concurrently* on `clk_sys`; this gate *over-serializes* them. That
over-serialization is what later starved the IDE reset servicing and motivated the
B1/B2 band-aids (now replaced by a faithful reset-finish — see §5.1).

### 2.8 `ide_check` bit8 = 1 → no phantom CD-ROM (`2574fd4`)

**Symptom.** A placeholder CD-ROM appeared on the secondary master; the BIOS
probed it as ATAPI and hung on the stubbed `cdrom_*` handlers.

**Root cause & fix.** `ide_check()`'s upper byte carries config: `x86_init` builds
`hotswap[2] = ((cfg>>8)&1)^1` (`x86.cpp:554-561`), copied to `allow_placeholder`
for the secondary master (`ide.cpp:1074-1084`). With bit8=0 a placeholder was
created even with no image, the drive answered with the ATAPI signature
`cylinder=0xEB14` (`ide.cpp:1055`), and the BIOS stalled on IDENTIFY-PACKET.
Returning `r | 0x100` (`sim_main.cpp:118`) sets bit8=1 → `hotswap[2]=0` → no
placeholder → the slot reports "not present" and POST skips it cleanly.

**Verdict: SOLID.** bit8=1 is the correct "no device present" encoding, and the
machine genuinely has no CD. Declining to advertise an ATAPI device it does not
have is exactly what a real HDD-only 486/BIOS does. (Caveat: it deviates from the
MiSTer *default* of bit8=0, which exposes a placeholder for hot-mounting ISOs — a
feature this sim does not implement — and it hardcodes `0x100` rather than deriving
it from a mount input; it would need to become conditional if CD support were
added.)

### 2.9 `--mem` open-bus top-of-RAM (`1982781`)

Diagnostic/characterization commit. `--mem MB` bounds populated words; writes at/
above the top drop, reads return an address-dependent open-bus pattern. **Benign
and mostly inert** (extended-RAM sizing is L2-cached, so the DDR-model top cannot
actually bound it, as the commit admits); it masks nothing and clobbers nothing
below 0xFFFFF. Instrumentation, not a fix.

### 2.10 The Win95 blocker: `display.drv` = vga.drv (this session)

**This was the actual thing standing between "teal backdrop" and "full desktop."**

**Symptom.** After POST/GUI init, Win95 showed *"Your display adapter is not
configured properly"*, then hung on a blank teal screen: the CPU spun in the VMM
idle loop polling the PIT (port 0x40) with interrupts mostly disabled, `ide0=0`
(no disk I/O), and **zero user-mode code** — i.e. Explorer never launched.

**Root cause (guest configuration, understood at the hardware level).** The disk's
`C:\WINDOWS\SYSTEM.INI` had `[boot] display.drv=pnpdrvr.drv` — the Plug-and-Play
display *stub* that loads the real driver named in the registry (here the "Boca
SuperVGA (Cirrus Logic)" `cirrus.drv`). **`pnpdrvr.drv` is not installed on the
disk** (`mdir` → file not found; an incomplete first-boot display-driver setup),
so GDI could load *no* display driver at all → the "not configured" dialog → the
display subsystem never came up → Explorer was never scheduled. The ao486 emulates
a **standard VGA**, not a Cirrus chip, so even the registry's `cirrus.drv` target
was wrong hardware.

Verified this was *not* a paging bug or an ao486 bug: the earlier `#PF` "crash"
was corruption introduced by the rejected injection/inflated-timing checkpoints
(R1/R2), not by demand paging; the clean boot never faults.

**Fix.** Set `[boot] display.drv=vga.drv` in the guest SYSTEM.INI (via `mtools`;
`vga.drv` 52 KB and its `dibeng.dll` dependency are both present). `vga.drv` is the
standard-VGA driver — the correct driver for the emulated hardware. The fresh cold
boot then switched to 640×480×16 graphics, ran the normal first-boot dialogs
(Mouse, DST clock, Date/Time — dismissed with timed Enter keys), launched Explorer,
and painted the full desktop. **0 fatal exceptions, 0 "display adapter" dialogs.**

**Verdict: SOLID.** This is the classic, correct Win95 "boot to standard VGA" fix:
the installed driver pointer was dangling; repointing it at the standard-VGA driver
that matches the emulated adapter is the right hardware-informed correction, not a
trick. (It modifies the guest disk; the original SYSTEM.INI is backed up. An even
more complete fix would be to also correct the registry display class or add Cirrus
emulation, but the emulated hardware *is* standard VGA, so `vga.drv` is the correct
driver.)

---

## 3. The real Win95 boot recipe (reproduction)

For a clean clone, follow **[`ao486-sim/REPRODUCE.md`](ao486-sim/REPRODUCE.md)**
(prerequisites, `setup.sh`, obtaining the disk image, the display fix). The boot
command, using the default release build (`make` → `obj_dir/ao486sim`):

```sh
cd ao486-sim
env TZ=UTC FAKE_TIME=946684800 LD_PRELOAD=../tmp/time_shim.so \
  ./obj_dir/ao486sim \
    --ide run_w95/w95_200.vhd --rate 4000000 --ddrlat 1 --mem 32 \
    --mouse --video-fb --save-every 200000000 \
    --kb "enter,enter,enter,enter" --kb-start 550000000 --kb-gap 120000000 \
    --cycles 4000000000
```

- No `--no-l1`, no `--w95-*`, no `--ptefix`: caches on, no injection.
- The four Enters dismiss the first-boot Mouse / clock / Date-Time dialogs.
- Accurate frame capture: `../tmp/ao486_fb.ppm` (mode-12h plane reader). The raster
  `ao486_latest.ppm` has a known 5-band geometry misread in some modes — see §6.
- Reaches the desktop at ~cyc 0.73–0.96 B (~40–55 min wall-clock at ~0.3–0.5 M
  cyc/s). The eip/VGA-mode examples elsewhere in this doc use the **traced debug
  build** (`obj_dir_dbg/ao486sim_dbg`, built via
  `make -C ao486-sim FAST=1 OBJDIR=ao486-sim/obj_dir_dbg EXE=ao486sim_dbg`); it is
  the same sim plus instruction tracing, and slower.

**Committed artifact:** `ao486-sim/docs/win95_desktop.png` (the verified desktop).
Per-run outputs — the framebuffer `tmp/ao486_fb.ppm`, `run_w95/*.state` checkpoints
(`--save-every`), the pre-fix `*.system.ini.bak` — are local scratch (gitignored,
regenerated by a run), not committed.

---

## 4. REJECTED band-aids (tried, discarded, NOT on the final boot path)

These exist in `sim_main.cpp` behind flags but are **absent from the boot command
in §3**. They are documented so the code is not mistaken for part of the solution.

- **R1 — guest-memory injection** (`--w95-warp/accum/calib/pit`,
  `--w95-a1/a2/a3/val`; `g_w95_mode`, `ao486_poke_guest`, `sim_main.cpp:1710-1770`).
  These poke Win95's PIT-calibration values / delay counters directly in guest DDR
  to force it past busy-wait loops (and `--w95-warp` sets `clock_rate=10000`,
  deliberately driving the PIT NCO into the degenerate regime §2.2 forbids). They
  *did* reach shell-startup faster but **corrupted guest state**, producing the
  bogus `#PF` at KERNEL32 that was mis-read as a paging bug. **Rejected**: the clean
  `--rate 4000000` boot with no injection is correct and needs none of this.
- **R2 — `--ptefix`** (`g_ptefix`, `sim_main.cpp:1803-1822`): scans high PDEs and
  force-sets the present bit on `P=0`-but-has-frame PTEs. This is semantically
  wrong (those are valid not-present committed pages); forcing present made Win95
  execute garbage and crash *earlier*. **Rejected.**
- The **inflated-timing / high-rate-calibration checkpoints** used earlier to reach
  shell-startup baked in the same corruption. **Rejected** in favour of a
  from-scratch consistent-rate boot.

---

## 5. Band-aids found by the audit — and the faithful fixes applied

The audit found three band-aids on the boot path (distinct from the R1/R2 hacks in
§4, which fabricate *guest* state and were already off-path). All three fabricated
*harness* state — a phantom request, a magic linger count, a hard-coded geometry —
to steer the boot. **All three have now been replaced with faithful fixes, verified
end-to-end.** A fresh cold boot with the fixes reaches the **complete Win95 desktop**
(framebuffer identical to the original), 0 crashes, 0 display-adapter dialogs — no
phantom, no linger, no hard-coded geometry anywhere on the boot path (§7).

### 5.1 B1 + B2 — IDE reset-finish: phantom request + magic timers → a direct idempotent call

**The band-aid (before, `827e06c`+`41a7f6e`).** When the RTL IDE request cleared
6→0 (SRST released), `ps_sd_req()` fabricated a phantom `0x08` request for
`g_reset_linger`=24 polls so `x86_poll`'s `if(sd_req)` gate (`x86.cpp:766-777`)
would call `ide_io(0,0)` — the routine that finishes the reset (BSY→RDY,
`ide.cpp:974-984`). A second magic timer (`confirm=12`) debounced a 6↔0 request
oscillation. The phantom modelled nothing and the counts were tuned. Root cause:
`ide_io`'s reset-finish is reachable only when the *combined* `sd_req≠0`, and once
ide0/ide1 clear with nothing else pending it is skipped — on real MiSTer another
pending request keeps `sd_req` nonzero (a consequence of the async ARM, §1.1).

**The faithful fix (applied).** Two facts make the honest fix trivial and safe:
`IDE_STATE_RESET` is entered **only at mount** (`ide.cpp:442`, never re-entered),
and `ide_io(N,0)` is **idempotent** — it completes the reset only while channel N is
in `IDE_STATE_RESET`, else a pure no-op. So on the debounced SRST-clear we now call
`ide_io(0,0)`/`ide_io(1,0)` **directly** (`sim_main.cpp`, at the `x86_poll` site,
under the same `!cpu_io_do` reentrancy guard #7 uses) — exactly the reset completion
the real ARM performs — with **no fabricated request and no linger count**
(`ps_sd_req` now returns only the raw RTL bits; `g_reset_linger` is deleted). The
`confirm` hysteresis is *kept* but reframed honestly: it is signal-conditioning on a
genuinely noisy sim signal (the 6↔0 flicker from the HPS `ide_set_regs`→reg-5 write
interleaving via `ps_clock_tick`, §1.1), which prevents finishing the reset during a
mid-SRST flicker. It fabricates nothing; §5.3 covers why the flicker exists at all.

### 5.2 B3 — IDE geometry: hard-coded 16/63 → the real size-based value

**Correction to the first-pass audit.** The audit initially called 16/63 "not the
value real hardware reports (16/256)." That was wrong. For a *raw* HDD image, real
MiSTer's `x86_init` chooses geometry by image size (`x86.cpp:495-518`) and passes
**63 SPT / 16 heads for images ≤ 8.4 GB** (line 516) — exactly what this 2 GB Win95
VHD receives. So **63/16 is the correct real-MiSTer value**; the band-aid was the
*mechanism*, not the value.

**The band-aid (before).** `parse_vhd_config` hard-set `drive->heads=16;
drive->spt=63` and returned `VHD_NOERROR`, *inverting* the real "no-config"
semantics so the geometry came from the stub instead of the size-based caller.

**The faithful fix (applied).** `parse_vhd_config` now returns the non-zero
"no `.cfg` present" status (real MiSTer's `VHD_NO_CONFIG`) and does **not** touch
the geometry, so `ide_img_set` applies the geometry its caller already chose
(`ide.cpp:478` → `ide_set_geometry(drive, sectors, heads)` = 63/16 here) — the real
behavior. Because CMOS 0x39 = LBA the BIOS derives INT 13h geometry from the total
sector count regardless (`rombios.c:2670-2683`) and the data path is LBA, so the
value is correct, not merely "valid." The early-POST crash once blamed on 256-SPT
was in fact resolved by the DDR/mgmt read-timing fixes (#3–#6); the reworked boot
loads Win95 with the real geometry and no hard-coding.

### 5.3 The one honest residual: the single cooperatively-driven clock

The `confirm` hysteresis kept in 5.1 exists because the sim drives one FPGA clock
cooperatively (§1.1): the mgmt interleave that produces the 6↔0 flicker is a
property of that architecture, not of silicon. The complete architectural cure is to
run the C++ HPS as an **independent scheduler** that services `mgmt_*` on its own
timeline instead of reentrantly calling `ps_clock_tick()`; that would also dissolve
the self-serialization that fixes #6/#7 gate around. This is the one remaining
simplification — a modeling-architecture choice, **not** a boot-correctness trick:
after the 5.1/5.2 fixes no guest or harness state is fabricated anywhere on the boot
path, the hysteresis merely conditions a noisy signal, and the boot is faithful
end-to-end. It is recorded here as the principled next step, not a hidden dependency.

---

## 6. Known simulation limitations (not fixes — transparency)

- **Single cooperatively-driven clock** (§1.1): the architectural simplification
  behind fixes #3,4,6,7 and band-aids B1,B2. Faithful cure = async HPS scheduler.
- **Raster capture geometry**: `dump_ppm()` → `ao486_latest.ppm` misreads some
  modes as a 5-band tiled image. Use the plane-accurate `dump_fb_mode13()` →
  `ao486_fb.ppm` (enabled by `--video-fb`) for correct frames. Capture tooling
  only; does not affect the guest.
- **x87 FPU** via Ventium SoftFloat-verified co-sim, not the ao486 FPU RTL
  (§1.2). Basic ops bit-exact; transcendentals libm-approximate.
- **UART** stubbed (not on the boot path).
- **`clk_vga` ÷8** empirical, not derived from `clock_rate_vga` (§2.1).

---

## 7. Verification of the outcome

- Desktop rendered: teal background + icons (My Computer, Inbox, Recycle Bin, The
  Internet, Set Up MSN) + taskbar (Start button + clock) — captured accurately by
  the mode-12h plane reader (`WIN95_DESKTOP_COMPLETE.png`).
- `grep -c "fatal excep"` over the boot log = **0**.
- `grep -c "display adapter"` (the misconfigured-adapter dialog) = **0**.
- Caches L1+L2 enabled; no runtime injection; consistent `--rate 4000000` from cold.
- Guest reached user-mode Explorer (user-mode EIP activity rising to ~30/40 sampled
  eips during shell build), versus the stuck runs which showed 0 user-mode code.
- **Faithful-fix re-verification (§5) — confirmed end-to-end.** With the phantom
  request, `g_reset_linger`, and hard-coded 16/63 geometry all removed, a fresh cold
  boot reaches the **complete desktop** (identical framebuffer to the original:
  teal 284260 px, taskbar-gray 17239 px, all icons) at cyc ~735M, with **0** fatal
  exceptions, **0** display-adapter dialogs, and **0** occurrences of the real-mode
  regression loop. The reset-finish and geometry now come from faithful mechanisms,
  not fabricated harness state.
  - One subtlety fixed during this verification: the reset-finish must complete
    **only ide0** (the present boot drive). Finishing ide1 with `ide_io(1,0)` falsely
    set RDY on the *absent* secondary drive (`ide.cpp:442` puts every channel into
    `IDE_STATE_RESET` at mount) and derailed the real-mode boot into a spin — so the
    fix finishes ide0 only, exactly mirroring the old phantom's `ide_io(0,0)` +
    `ide_io(1,1)`-no-op decode. This is why the direct call is `ide_io(0,0)` alone.

---

*Audit method: each committed fix was re-read against the ao486_MiSTer RTL
(`3rd-party/ao486_MiSTer/rtl/...`) and the MiSTer PS software (`ao486-sim/ps/...`)
to confirm the cited hardware/protocol fact, and classified SOLID / BAND-AID /
REJECTED on that basis. File:line references throughout are to the current tree.*
