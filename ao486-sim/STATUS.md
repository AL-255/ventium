# ao486 pure-Verilator SoC bring-up — STATUS

Living status doc for the ao486 → Verilator boot effort (north star: a working
ao486 SoC sim into which **Ventium** can later be dropped by swapping the CPU
core inside `system.v`). Updated per milestone.

- Submodule: `3rd-party/ao486_MiSTer` @ `e1bd767` ("Release 20260603").
- Host tool: Verilator 5.046. No Quartus (pure software sim). Target deploy
  later: **Xilinx Zynq UltraScale+** → memory primitives are behavioral SV
  (inferrable BRAM), not Altera megafunctions.
- All my code lives in the **parent repo** under `ao486-sim/` so the submodule
  stays pristine. Scratch/artifacts go in `./tmp` (gitignored), never `/tmp`.

## Architecture (what we found)

```
ao486.sv            MiSTer top: PLLs + sys/hps_io framework + DDR3 + HDMI.   <-- NOT used by us
  └─ system.v       THE SoC (our DUT): CPU + all PC peripherals.             <-- harness target
       ├─ ao486 (rtl/ao486)      486 CPU core: pipeline + caches(L1/L2) + TLB + memory/IO
       │     interface = avm_* (Avalon mem) + avalon_io_* (Avalon IO) + interrupt_*   <-- VENTIUM SWAP SEAM
       ├─ soc peripherals (rtl/soc): vga, floppy, ide, dma, pic, pit, ps2, rtc,
       │     joystick, uart(VHDL), sound(OPL3/SB), cdda, iobus
       └─ external interfaces:
            DDRAM_*        64-bit burst main memory   -> behavioral C++ DDR model
            mgmt_* + *_request   HPS management bus    -> behavioral C++ "HPS" (BIOS + disk images)
            video_*        digital RGB + sync          -> C++ framebuffer capture -> PPM/PNG
            ps2_kb*/ms*    PS/2                         -> C++ PS/2 device (keyboard injection)
            bootcfg/clock_rate/sound/uart...           -> tie-offs / clock gen
```

Key finding: **there is no existing full-SoC boot testbench.** The repo's
`sim/verilator/ao486` and `sim/iverilog/ao486_run` harnesses are **CPU-only**
(instantiate `ao486`, not `system`). On real MiSTer the ARM **HPS** drives the
`mgmt_*` bus to load the BIOS and stream floppy/IDE sectors when the core raises
`fdd_request`/`ide_request`. So the central engineering task is to
**re-implement the HPS-side mgmt behavior in C++** (BIOS load + disk serving).
Reference for the protocol: the RTL side (`rtl/soc/floppy.v`, `ide.v`, `rtc.v`
mgmt_* registers) and, if needed, `Main_MiSTer/support/ao486`.

## The Ventium swap seam (north star)
Inside `system.v`, the `ao486` instance exposes:
- `avm_*` — Avalon-MM master, 32-bit, burst (main memory + cache refill)
- `avalon_io_*` — Avalon-MM IO master, 16-bit addr (port I/O to peripherals)
- `interrupt_do/_vector/_done` — external interrupt acknowledge
Replacing ao486 with Ventium = present a module with this exact interface.
`SEAM.md` (M6) will pin the cycle-level contract.

## Build gap (from `verilator --lint-only` on system.v)
Authoritative compile list = the `.qip` files → **103 .v/.sv compile units**
(`./ao486-sim/rtl.f`). `rtl/ao486/autogen/*` are **include-fragments**, excluded
(real modules live in `pipeline/`, `memory/`). Missing modules to supply:

| missing module | used by | plan |
|---|---|---|
| `altsyncram` | l1_icache, l2_cache, simple_fifo_mlab | **behavioral SV** (DUAL/SINGLE_PORT, byteena) |
| `altdpram`   | simple_fifo_mlab | **behavioral SV** |
| `dpram`, `dpram_difclk` | vga.v, ide.v | **behavioral SV** dual-port RAM |
| `gh_uart_16550` (+19 `gh_*.vhd`) | uart.v | VHDL; UART not needed to boot → **stub** uart.v now, SV-rewrite later if a COM port is needed |
| `cpu_export` | pipeline.v:1419 | sim/debug export → **empty stub** (or `ifdef`-out) |
| Altera PLLs (pll.v/pll2.v) | ao486.sv only | **excluded** (clocks generated in C++ harness) |
| `bram.vhd` (VHDL) | (no instantiations found in RTL path) | drop unless elaboration needs it |

Behavioral models + stubs go in `ao486-sim/stubs/*.sv`. They are
Verilator-friendly **and** Xilinx-inferrable (good for the Zynq US+ target).

## Target images (in `ventium-refs/`)
- FreeDOS: `freedos/fd_hdd.img`, `freedos/fd_floppy.img`
- Quake:   `quake-dos/quake_hdd.img` (timedemo demo1)
- Win95:   `07-p5-emulation-harness/win95/win95-elt.img` (+ `win95.qcow2`)
- BIOS:    ao486 `releases/` boot ROMs (boot0/boot1) — to be located in M2.

## Milestones
- **M2 VIDEO SIGN-ON REACHED (key milestone):** Running with **L2 cache ON and only
  the buggy L1 icache disabled (`--no-l1`)** — correct (avoids the L1 handshake race)
  AND fast (L2 caches the BIOS). POST executes through video init and **renders VGA
  text output** to the captured framebuffer (`tmp/ao486_latest.png`). This is the
  working config for booting: `--no-l1 --ddrlat 1`, 4MB CMOS. POST then runs the big
  memory-clear memset (writes via L2, so DDR is quiet) and waits on the IDE
  (`ide0_request` asserted) for a boot device -> needs M3 disk-serving next.
- **M3 (next) — disk serving, protocol mapped:** Harness reads `fdd_request`/
  `ide0_request` directly (DUT outputs). Floppy is the simplest first boot
  (`fdd_io`, vs full IDE/ATA). FreeDOS floppy = `ventium-refs/freedos/fd_floppy.img`.
  Floppy mgmt map (rtl/soc/floppy.v; mgmt_address[3:0], drive=mgmt_address[7]):
    0=media present (and READ returns {drive, sd_sector[14:0]} = requested LBA),
    1=writeprotect, 2=cylinders, 3=sectors/track, 4=total sectors, 5=heads,
    0xF=sector FIFO (read/write the 512B via mgmt_address=0xF).
  HPS sequence (from Main_MiSTer/support/x86/x86.cpp fdd_io): one-time geometry
  setup (write regs 0..5 for a 1.44MB floppy: 80 cyl, 18 spt, 2 heads, 2880 secs);
  per request: read reg0 -> LBA, read sector from img, stream 512B to the 0xF FIFO.
  We drive mgmt_* directly (bypassing hps_io/SPI). Also set CMOS for floppy boot
  (0x10 fdd type, 0x14 bit0, boot seq 0x2D/0x3D). Then a long `--no-l1` run.
- **M3 FIXES (this session):** (1) floppy FIFO is **1 byte per mgmt transfer** (512),
  not 256 16-bit words — fixed boot-sector corruption; MEM@0x7C00 now = eb 3c 90 6d
  / sig 55 aa (valid). (2) Use **`--rate 2000000`** (PIT needs clock_rate>1.193MHz);
  at 1MHz a BIOS timer-wait spins forever at 0xFEF6C. With both fixes the boot gets
  PAST 0xFEF6C and keeps progressing (ddr_wr climbing). Run from `ao486-sim/` so the
  `../3rd-party` BIOS paths resolve. Working cmd:
  `./obj_dir/ao486sim --no-l1 --ddrlat 1 --rate 2000000 --floppy <img> --cycles N`.
- **M3 PIPELINE WORKS END-TO-END (this session):** `--no-l1 --floppy fd_floppy.img`
  -> POST completes -> clears the screen -> the BIOS reads **3 floppy sectors** via
  the HPS model (`fserved=3`; the floppy.v DMA+IRQ6 completion handshake works, not
  just the FIFO fill). Then it HANGS in a tight BIOS loop at **0xFEF6C** (instr
  climbs, ddr_wr flat = a wait loop). Most likely a boot-menu/prompt waiting on a
  keypress or a timer tick the harness doesn't drive yet. NEXT for the DOS prompt:
  (1) PS/2 keyboard injection (drive ps2_kbclk/kbdat with a scancode); (2) verify
  the served LBAs/sector data are correct; (3) let it load the kernel. Run config:
  `./obj_dir/ao486sim --no-l1 --ddrlat 1 --rate 1000000 --floppy <img> --cycles N`.
- **M0 (done):** branch + submodule + survey + gap map + workspace scaffold.
- **M1 (done):** `system.v` elaborates (119 modules) and **runs** under the C++
  harness. Behavioral SV models (`stubs/sim_prims.sv`) + a behavioral DDR slave
  (`sim_main.cpp`). Reset bring-up over 400k cycles: CPU alive (DDR read+write
  traffic), and `ide0_request` already asserts (IDE raising HPS mgmt requests).
  Build: `cd ao486-sim && make`. Run: `make run`. No BIOS yet → CPU executes the
  zero-filled reset vector (lots of writes); that's expected pre-M2.
    - Harness files: `ao486-sim/{rtl.f, sim_main.cpp, Makefile, stubs/sim_prims.sv}`.
    - Clocks: M1 ties all domains (clk_sys/vga/audio/uart/mpu) to one clock.
    - DDR: 256 MiB, 64-bit-word burst, always-ready (BUSY=0) slave.
- **M2 (in progress):** BIOS preload done — `boot0.rom`→phys 0xF0000, `boot1.rom`
  →0xC0000, written straight into `ddr[]` (HPS-into-DDR3 model). Confirmed the CPU
  **fetches & executes the BIOS** (reads from 0xC0000–0xFFFFF; reset vector linear
  0xFFFF0 = CS F000:FFF0). It then derails back into low memory — expected, because
  POST needs the **HPS mgmt configuration** the real firmware does at startup. NEXT
  (the core HPS-model work):
    1. RTC/CMOS init over mgmt addr 0xF4xx (BIOS reads CMOS for mem size / boot
       order / equipment — without valid CMOS it triple-faults).
    2. IDE (0xF0xx) + floppy (0xF2xx) geometry + sector serving on `*_request`.
    3. Video-output capture (`video_*` → PPM) for POST sign-on (legacy text @
       0xB8000 lives inside vga.v, not DDR — capture rendered pixels). Reference:
       rtl/soc/{rtc,ide,floppy}.v mgmt regs (+ Main_MiSTer/support/ao486 if needed).

  PROGRESS / KEY FINDINGS:
  - HPS model implemented from Main_MiSTer/support/x86/x86.cpp: UMA 0xFF fill +
    ROM load + the exact 128-byte CMOS array, programmed over the RTC mgmt port
    (0xF400|reg, one write/clk). Zero CMOS was triple-faulting POST.
  - Observability: cpu_export un-stubbed -> DPI `ao486_cpu_trace(eip,esp,eax)` so
    the harness tracks instruction retirement + EIP range (build `+define+AO486_TRACE_EIP`).
    VGA frame capture -> `../tmp/ao486_frame_*.ppm`.
  - TRACTABILITY (critical): with `clock_rate`=90MHz the RTL RTC/PIT burn ~90M
    cycles per emulated second, so BIOS timed delays + the memory test are
    astronomically long. Fix: feed a LOW `clock_rate` (timers tick fast). PIT needs
    `clock_rate > 1.193MHz`, so ~2-4MHz is the sweet spot (`--rate`). Keep
    `clock_rate_vga`=90MHz for the pixel divider. Also declare **16MB** RAM in CMOS
    (enough for DOS/Quake/Win95) to shrink the POST memory test ~16x.
  - With those, POST advances past the RTC-time loop, through the memory test,
    to instr~634k where it **crashes**: jumps into the F000 zero-padding with a
    trashed stack (esp=5), NOP-slides eip 0xFF36->0xFFD4, then hangs in an
    exception loop at 0xFFD4. ps2_reset_n never asserts (not a kbd-reset path).
    Added: ps2_reset_n->reset feedback (mirrors ao486.sv) and a 96-deep EIP ring
    buffer (`dump_ring`). The crash origin is before the ring window — a
    post-memory-test corruption (A20 / protected->real return / extended-mem DDR
    class). NEXT: capture the ring at the moment eip first enters the padding
    (detect the non-sequential jump) to get the faulting call site; and/or verify
    the DDR model against >1MB access patterns. This needs CS:EIP-level tracing.

  CS:EIP TRACE TOOL (done, per user direction): a `cpu_probe` module is `bind`-ed
  into the ao486 `pipeline` (no submodule edits) and exports CS:EIP+esp at retire
  via DPI (`ao486_cpu_trace2`). The harness keeps a 256-deep CS:EIP ring, an
  optional full trace file (`--trace`), and auto-dumps the path on CS corruption.
  `lin=(cs<<4)+eip`; cross-reference with `ndisasm -b16 -o <lin> boot0.rom`.
  FOUND with it: the crash is at **instr ~293** (very early, NOT after a mem test
  — the later "mem-test writes" were the already-crashed CPU). The BIOS calls a
  memset routine (0xE0BD/0x0666/0x10AA: `les di,[bp+6]; mov al,[bp+4]; rep stosb`),
  then a `ret` pops a zeroed stack and control jumps to **0000:0004** (CS clobbered
  to 0). Signature = a memset writing to the WRONG location (segment / A20 / addr
  handling) that zeroes the stack return addresses. NEXT: trace the memset call
  args (es:di, count) vs. where the writes actually land in DDR; check A20/segment
  base handling on that store path. This is now a tractable, well-instrumented hunt.

  *** CRUCIAL FINDING: THE CACHE DATA IS CORRECT AT THE CRASH ***
  Re-checking CPU_DATA against the line the icache ACTUALLY fetched (read_addr)
  instead of the branched CPU_ADDR: there are ZERO genuine data mismatches at the
  crash (cyc ~1121). Every line the icache fetches contains the right BIOS bytes.
  The earlier "mismatches" were BENIGN abandoned speculative prefetches (the core
  branched mid-fetch). The first REAL cache-data error (got=0 for a fetched BIOS
  line) is at cyc ~19947 — long AFTER the crash. Implications:
   - My behavioral RAM models (altsyncram/altdpram/L2) are essentially correct;
     this was NOT a RAM-data bug, which is why none of the read-timing tweaks
     mattered.
   - The crash is a CORE<->ICACHE TIMING/PROTOCOL race: the icache asserts
     CPU_DONE/VALID for a prefetch the core abandoned (CPU_ADDR moved on), and the
     core consumes that stale-but-internally-correct data as its current fetch ->
     executes a wrong instruction -> CS corruption. Caches change the fetch TIMING,
     not the data. (Also a separate, later got=0 cache bug at ~cyc 20k to chase.)
   - NEXT: focus on the CPU_DONE/CPU_VALID handshake timing vs CPU_ADDR. Verify
     whether the Verilator eval ordering (clock/inputs) makes the core advance
     CPU_ADDR before CPU_DONE, or makes the icache assert DONE a cycle early for an
     abandoned fetch. This is an eval-model / handshake-timing issue, not a data
     model bug — a different (and likely smaller) fix than chasing the RAMs.

  CACHE BUG — earlier hypothesis (core/icache prefetch race, now refined above):
  - icache_dprobe (bound into l1_icache, dumps MEM_REQ/ADDR/DATA/DONE + the fill
    + CPU_ADDR in a cycle window) shows the exact mechanism at the first mismatch
    (cyc ~1121): the L1 issues MEM_REQ for line 0xF0680 (a speculative prefetch
    past a memset `ret`); mid-fetch the core BRANCHES and CPU_ADDR moves to 0xF090C;
    the 0xF0680 data arrives and the icache asserts CPU_DONE — but the core now
    associates that data with 0xF090C. (Confirmed: the wrong bytes `8a1b74c0` live
    at ROM 0x68c, i.e. the 0xF0680 line, not 0xF090C.)
  - Tried and did NOT fix it: edge-detected DDR read accept, DDR read latency
    (8/12), and registered (vs 0-cycle) DDR response. So it is NOT raw memory
    timing. read_addr IS latched per-request in the icache (l1_icache.v:170), so
    the fill tags the fetched line correctly — the issue is the core changing
    CPU_ADDR before CPU_DONE for an abandoned speculative prefetch.
  - OPEN QUESTION / next step: some of these mismatches are likely BENIGN (the core
    discards the stale abandoned-prefetch response); the real crash is the subset
    where a wrong fetched instruction is actually RETIRED. Correlate the icache
    checker with the retire trace (exe_eip_final) to isolate the executed-wrong
    fetch, then determine whether it's (a) my behavioral RAM/DDR still off in this
    exact scenario, or (b) a CPU_ADDR-hold protocol detail the core needs that the
    Verilator eval ordering perturbs. Caches-off remains correct (740k+ instr).
  - Tooling added this pass: VCD dump (`--vcd N`), icache output checker, icache
    internals probe, DDR read latency (`g_ddr_lat`) + edge-detect + registered
    response. All committed.

  CACHE BUG ROOT-CAUSE (earlier, snoop hypothesis — DISPROVEN: SNOOP we=0 at the
  corruption; it is the fill of an abandoned prefetch, see above):
  - icache_probe (bound into l1_icache, compares CPU_DATA vs known BIOS bytes in
    DDR) shows: first 17 fetches byte-correct, then fetch #18+ returns wrong data
    — `got=00000000` on several BIOS lines, 2-byte-shifted on others.
  - The l1_icache FIFO is the SNOOP fifo (`data={snoop_be,snoop_data,snoop_addr}`),
    i.e. the coherence path: every CPU/DMA memory write snoops the icache and can
    UPDATE a cached line (self-modifying-code coherence; line ~164
    `memory_be<=Fifo_dout[61:58]`). The BIOS memsets write ZEROS to low memory →
    each is a snoop with data=0 → a mishandled snoop writes 0 into BIOS *code*
    lines → `got=0` fetch -> crash. Perfectly fits "17 correct, then wrong once
    memsets start."
  - RULED OUT: altsyncram read style (registered-output AND spec-literal
    reg-addr/comb-output give identical mismatches) and altdpram read-during-write
    (plain and write-through bypass identical). So it is NOT the RAM read timing;
    it is the snoop update path (snoop fifo data/addr handling or the coherence
    write) interacting with the behavioral RAMs.
  - DEFINITIVE NEXT STEP: VCD around the first snoop/fetch-#18 (snoop_addr/data/we,
    Fifo_dout, update_tag_addr, memory_we/be/datain, addr_b) to see the exact wrong
    write into the cache. Then fix the one model/timing detail. Unblocks fast POST.

  CACHE-MODEL BUG (earlier notes, superseded by the snoop finding above):
  - Decisive isolation via `--no-l1/--no-l2`: with caches OFF the CPU runs cleanly
    to 740k+ instructions (POST executes); with the **L1 instruction cache ON** it
    crashes at instr ~293 (L2 irrelevant). So my behavioral L1 RAM model feeds the
    icache wrong data. Caches-off "works" but is far too slow for a full boot
    (uncached rep-stos memclear of RAM = millions of DDR round-trips).
  - Diagnosis done: `altsyncram` passes a standalone unit test (`test/tb_mem.sv`:
    write/read, 1-cycle latency, back-to-back pipelined reads all correct). Ruled
    OUT: UNOPTFLAT/comb-loops (none in cache), byteena lane-swap (memory_be[3:0] ok;
    per-way memory_we[i] indexed explicitly), read-during-write collision (both a
    registered-output and a reg-addr/comb-output variant crash identically).
  - The trace signal currently bound (`pipeline.eip`) is the PREFETCH pointer
    (fetch-width-dependent), so cache-vs-nocache trace diffs are noisy. NEXT STEP:
    bind the *retire/commit* EIP (architectural, from the writeback stage) instead,
    then diff cache-on vs cache-off to pin the first wrong instruction; or
    instrument the icache data output directly vs boot0.rom. That converts this
    into an exact fix. Fixing the L1 model unblocks fast POST -> the OS boots.
  - Real stub bug fixed along the way: uart/mpu `readdata` was undriven
    (`always @(*)` empty sensitivity) -> now `assign readdata = 0`.

  SCOPE REALITY (honest): full POST -> FreeDOS -> Quake -> Win95 is a large,
  multi-session bring-up. Each OS boot is 100Ms-billions of cycles (minutes-to-
  hours of wallclock at ~0.3M cyc/s), and each blocker (this crash, then kbd/IDE/
  floppy HPS serving, video mode-set, then the OS boots) needs iterative HW
  debugging. The foundation (M0/M1 + a running SoC with deep observability) is
  solid; the remaining work is real engineering time, not a quick fix.
  - NOTE on scale: cycle-accurate Verilator of a 486 is ~0.2-0.5M cyc/s here; full
    OS boots are 100Ms-billions of cycles. Sim-speed work (‑‑threads, trace off)
    and the low `clock_rate` trick are essential; runtimes will be minutes-to-hours
    per scenario.
- **M2:** C++ HPS model loads BIOS; CPU runs POST; VGA text capture shows sign-on.
- **M3:** floppy+IDE image serving + PS/2 keyboard → FreeDOS prompt.
- **M4:** Quake timedemo → frames + FPS line.
- **M5:** Win95 → desktop screenshot.
- **M6:** per-scenario commands, README, `SEAM.md`.

## Decisions applied
- Drive `system.v` directly; bypass `ao486.sv`/`hps_io` entirely.
- Behavioral SV for all memory primitives (no Altera megafunctions) — per Zynq target.
- VHDL: rewrite→SV only where on the boot path; UART stubbed for now.

## *** FreeDOS BOOTS (this session) ***
With L1 disabled / L2 on + the floppy disk-serving model, FreeDOS boots end-to-end:
BIOS POST -> video -> INT 19h -> bootloader (boot sector @0x7C00, verified
eb3c906d/55aa) -> kernel + system files loaded from fd_floppy.img (299 sectors,
LBA 0-9 boot/FAT then 19-301 kernel/COMMAND.COM) -> kernel executes and renders a
full boot log to the VGA screen (tmp/ao486_dos3.png). Three fixes made it work:
(1) floppy FIFO = 1 byte/transfer (512), (2) --rate 2000000 (PIT >1.193MHz),
(3) no-double-serve guard (wait for fdd_request to clear). This is the first OS
booting in the pure-Verilator ao486 SoC. Run:
  cd ao486-sim && ./obj_dir/ao486sim --no-l1 --ddrlat 1 --rate 2000000 \
     --floppy ../ventium-refs/freedos/fd_floppy.img --cycles 400000000
Remaining toward the stated goal: reach the interactive DOS prompt (PS/2 key
injection if it waits on input), then Quake (IDE/ATA serving + a Quake disk),
then Win95 (much larger). Each is a long unattended run.

## NEXT: IDE/ATA serving for Quake (and Win95) — protocol located
Quake (`ventium-refs/quake-dos/quake_hdd.img`, 64MB, bootable, auto-runs timedemo)
and Win95 boot from HDD = need IDE serving (more than the floppy fdd_io). Reference:
`tmp/Main_MiSTer/ide.cpp` (`ide_io` @968, `ide_get_regs`/`ide_set_regs` @138/161,
`handle_hdd`, `ide_send_data`/`ide_recv_data`). IDE0_BASE=0xF000, mgmt regs 0-5:
  reg0 R:{features,use_fast,io_done}; regs encode LBA (sector+cylinder+head),
  sector_count, cmd, drv via a 6-word ide_get_regs(mgmt addr 0..5); reg5 = control
  (status/irq/request-clear); a dpram buffer (io_buf) carries 512B sector data.
Harness plan (mirror the floppy model): watch ide0_request[2:0]; on req==6 do the
ATA reset regs; on req==4 read regs, dispatch the ATA command — minimally IDENTIFY
(0xEC) + READ SECTORS (0x20/0x24/0xC4): compute LBA, read from the .img, write
sectors to io_buf, set status (RDY|DRQ|IRQ), clear request via reg5. Then boot
quake_hdd.img -> it auto-runs the timedemo. Win95 = same IDE path + win95-elt.img +
hours of sim. This is the substantial remaining chunk; floppy fdd_io is the proven
template.

## M4 IDE/ATA state (end of this session) — full detection reached, panics post-IDENTIFY
`--ide <hdd.img>` serving is implemented in sim_main.cpp (ide_init/ide_pre/ide_post/
ide_handle/ide_build_id) mirroring Main_MiSTer ide.cpp. Progress this session — 6
distinct bugs found+fixed, in order:
  1. reset-finish: handle req==0 after req==6 so the drive leaves BSY -> RDY.
  2. present bit: write mgmt reg6=0x0009 (ide_init) so the BIOS probes the drive.
  3. drive-1 absent: return ABRT (err 0x04) for drv!=0 instead of phantom IDENTIFY.
  4. register decode: 6-word get/set at mgmt 0xF000-5 (1-cycle read latency handled).
  5. IDENTIFY block: replaced with the VERBATIM ide.cpp identify[256] (word5=512
     bytes/sector is "used by ao486"; calc_geometry C/H/S=520/4/63 for the 64MB img).
  6. data buffer: 256 words to mgmt 0xF0FF (base+255), io_buf0/1 alternation verified.
RESULT: BIOS does reset(6->0) -> present -> IDENTIFY (cmd=EC) to drv0 (data) AND drv1
(ABRT) -> then PANICS: a Bochs-BIOS 'print string; cli; hlt' routine at 0xFBF0-0xFC10.
The on-screen panic message is the key, but the VGA capture is garbled on this run
(vertical streaks, not the FreeDOS-style text) — capture misalignment to fix first.
Candidate panics (from BIOS strings): "ata_is_ready returned %d" (DRQ not clearing
after the IDENTIFY data phase) or "Unsupported sector size %u". NEXT: (a) fix/ös the
VGA capture for this mode OR add a DPI probe to dump the VGA text buffer to read the
exact panic; (b) most likely fix is the post-IDENTIFY data-phase status (ensure DRQ
clears / io_done) so ata_is_ready passes; (c) then the boot-sector READ (cmd 0x20)
should fire (ide_served>0) and DOS+Quake load. Run:
  ./obj_dir/ao486sim --no-l1 --ddrlat 1 --rate 2000000 --ide ../ventium-refs/quake-dos/quake_hdd.img --cycles N
