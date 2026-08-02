// sim_ven.cpp — Verilator co-sim harness for the Ventium core inside the ao486 SoC.
//
// The SoC (system.v built +VEN_CORE) instantiates ven_ao486_shim → ventium_top in
// place of the ao486 core; everything else in the SoC is unchanged. This harness is
// the same shape as the ao486 sim (drive the top-level SoC ports, model DDR, run the
// MiSTer HPS software as the PS via ps_shim/x86/ide) — minus every ao486-core-internal
// read (the Ventium core is observed via the vtm_retire DPI in vtm_dpi.cpp instead).
// Reuses ps_shim.cpp + support/x86/x86.cpp + ide.cpp verbatim. See VENTIUM_SWAP.md §7.

#include "Vsystem.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <deque>
#include <vector>
#include "verilated_save.h"

// ---- shared model + guest memory (ps_shim.cpp maps into these) ----------------
Vsystem  *top = nullptr;                     // non-static: ps_shim drives mgmt via this
static const uint64_t DDR_WORDS = (1ull << 24);   // 128 MiB / 8
uint64_t *ddr = nullptr;                     // non-static: ps_shim (shmem) maps here
static vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

struct RdBeat { uint32_t addr; uint64_t ready; uint64_t data; };
static std::deque<RdBeat> rd_fifo;
static bool     wburst = false; static uint32_t waddr = 0; static int wrem = 0;
static int      g_ddr_lat = 2;
static uint64_t g_mem_top_words = 0, g_max_waddr = 0;
static uint32_t g_clock_rate = 4000000, g_rtc_rate = 80000, g_rate_vga = 90000000;
static int      g_l1dis = 0, g_l2dis = 0;
static uint64_t g_save_at = 0;                     // --save-at N: snapshot at cycle N (one-shot), then continue
static uint64_t g_save_every = 0;                  // --save-every N: re-snapshot every N cycles (cycle-stamped)
static uint64_t g_next_save = 0;                   // internal: next --save-every threshold
static const char *g_save_file = "ven_post.snap";  // --save-file FN (base name; --save-every appends .<cyc>)
static const char *g_restore_file = nullptr;        // --restore FN: load snapshot right after x86_init

// ---- vtm retire trace globals (defined in vtm_dpi.cpp) ------------------------
extern "C" { extern uint64_t g_vtm_retires; extern uint32_t g_vtm_eip,g_vtm_eflags,
    g_vtm_eax,g_vtm_esp,g_vtm_cr0,g_vtm_cr2,g_vtm_cr3; extern uint16_t g_vtm_cs;
    extern uint32_t g_vtm_ecx,g_vtm_edx,g_vtm_ebx,g_vtm_esi,g_vtm_edi; extern uint16_t g_vtm_ds,g_vtm_es;
    extern int g_vtm_dump; }

// Disk-read counter (bumped by ps/ide.cpp on each READ) — the COMMAND.COM open-failure point is
// reads=71; used below to auto-enable the per-retire register trace right before the open so the
// dir-search compare (and the flag/branch that mis-decides "not found") is captured.
volatile unsigned long g_disk_reads = 0;

// ---- PS-facing helpers ps_shim.cpp / x86.cpp expect --------------------------
static inline uint8_t *ddr_bytes() { return (uint8_t *)ddr; }
extern "C" int ao486_poke_guest(unsigned int phys, const void *src, int nbytes) {
    if (!ddr) return 0; memcpy(ddr_bytes() + (phys & (DDR_WORDS*8u - 1u)), src, nbytes); return 1;
}
extern "C" int ao486_peek_guest(unsigned int phys, void *dst, int nbytes) {
    if (!ddr) return 0; memcpy(dst, ddr_bytes() + (phys & (DDR_WORDS*8u - 1u)), nbytes); return 1;
}
// IDE/FDD request bits for ps_shim's ide_check() — raw RTL request lines + the
// cfg upper byte (bit8=1 => no phantom CD on the secondary master). Faithful: no
// fabricated phantom request (reset-finish is handled by the shim/ide model).
extern "C" uint16_t ps_sd_req() {
    uint16_t r = (uint16_t)((top->ide0_request & 7) | ((top->ide1_request & 7) << 3)
                          | ((top->fdd_request & 3) << 6));
    return r | 0x100;
}

static bool ddr_load(const char *path, uint64_t phys) {
    FILE *f = fopen(path, "rb"); if (!f) { fprintf(stderr, "ddr_load: cannot open %s\n", path); return false; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    if (fread(ddr_bytes() + phys, 1, sz, f) != (size_t)sz) { fclose(f); return false; }
    fclose(f); fprintf(stderr, "ddr_load: %s -> phys 0x%05llx (%ld bytes)\n", path, (unsigned long long)phys, sz);
    return true;
}

// ---- DDR-slave model + clock driving (verbatim from the proven ao486 sim) -----
// g_fpga_ddr (env FPGA_DDR): mimic the FPGA's ven_ddram_axi bridge instead of the
// idealized golden model, to reproduce on-hardware-only mem-path derails:
//   1 = assert DDRAM_BUSY while a read/write is in flight (ven_ddram_axi: BUSY=st!=IDLE);
//   2 = also stretch to HP0-like latency + inter-beat gaps.
int g_fpga_ddr = 0;
static bool prev_rd = false;
static uint32_t g_wbase_dbg = 0, g_wcnt_dbg = 0;   // [DDRWTSS] current DDR write-burst base/count
static void ddr_service() {
    if (top->DDRAM_RD && !prev_rd) {
        uint32_t a = top->DDRAM_ADDR; int n = top->DDRAM_BURSTCNT ? top->DDRAM_BURSTCNT : 1;
        for (int i = 0; i < n; i++) {
            uint32_t ra = (uint32_t)((a + i) & (DDR_WORDS - 1));
            uint64_t rd = (g_mem_top_words && ra >= g_mem_top_words)
                          ? (~((uint64_t)ra * 0x0100000001000001ull)) : ddr[ra];
            uint64_t lat = (g_fpga_ddr >= 2) ? (uint64_t)(18 + i * 2) : (uint64_t)g_ddr_lat;
            rd_fifo.push_back({ ra, main_time + lat, rd });
        }
    }
    prev_rd = top->DDRAM_RD;
    if (top->DDRAM_WE) {
        if (!wburst) { waddr = top->DDRAM_ADDR; wrem = top->DDRAM_BURSTCNT ? top->DDRAM_BURSTCNT : 1; wburst = true; g_wbase_dbg = waddr; g_wcnt_dbg = wrem; }
        uint32_t a = waddr & (DDR_WORDS - 1);
        if ((uint64_t)a * 8 > g_max_waddr) g_max_waddr = (uint64_t)a * 8;
        if (g_mem_top_words && a >= g_mem_top_words) { waddr++; if (--wrem <= 0) wburst = false; }
        else {
            uint64_t din = top->DDRAM_DIN; uint8_t be = top->DDRAM_BE; uint64_t mask = 0;
            for (int b = 0; b < 8; b++) if (be & (1 << b)) mask |= (0xffull << (b * 8));
            // [DDRSIG] Broad hunt: catch the FIRST appearances of the 0x11b354 pointer signature
            // (low 16 bits 0xb354, bytes 54 b3) written to LOW memory (<0x400000) — reveals the whole
            // propagation chain of the ring-3 buffer-end value into the handler's data structures, so
            // we find the true cross-domain ENTRY point without hop-by-hop rebuilds.
            // [DDR2FF5A] full write history of the esi-load source word (0x2ff58..0x2ff5f, word 0x5feb):
            // does 0x2ff5a EVER get written 0x11b354, and by what (burst vs single)?
            if (a == (0x2ff58u >> 3)) {
                static int ff5a_n = 0;
                if (ff5a_n < 40) { ff5a_n++;
                    uint64_t nv = (ddr[a] & ~mask) | (din & mask);
                    unsigned val = (unsigned)((nv >> 16) & 0xffffffffu);  // bytes 0x2ff5a..0x2ff5d
                    fprintf(stderr, "[DDR2FF5A] word0x5feb <- din=%016llx be=%02x -> [0x2ff5a]=%08x | burst_base_word=%08x cnt=%u t=%llu\n",
                            (unsigned long long)din, be, val, g_wbase_dbg, g_wcnt_dbg, (unsigned long long)main_time);
                }
            }
            {
                static int ddrsig_n = 0;
                if (ddrsig_n < 60 && (a*8u) < 0x400000u) {
                    uint64_t nv = (ddr[a] & ~mask) | (din & mask);
                    // detect the FULL 32-bit pointer 0x11b354 at byte offset 0/2/4 within the word,
                    // but only if THIS beat actually wrote into that span (mask covers a byte of it).
                    for (int off = 0; off <= 4; off += 2) {
                        unsigned v = (unsigned)((nv >> (off*8)) & 0xffffffffu);
                        uint64_t spanmask = 0xffffffffull << (off*8);
                        if (v == 0x0011b354u && (mask & spanmask)) {
                            unsigned addr = a*8u + off;
                            ddrsig_n++;
                            fprintf(stderr, "[DDRSIG] 0x11b354 @phys=%08x (word=%08x off=%d) din=%016llx be=%02x | burst_base_word=%08x cnt=%u t=%llu\n",
                                    addr, a, off, (unsigned long long)din, be, g_wbase_dbg, g_wcnt_dbg, (unsigned long long)main_time);
                            break;
                        }
                    }
                }
            }
            // [VEN-TBL5C] full write history of the Quake function-pointer table entry[0] @ linear 0x1005c000
            // = physical 0x15b000 = DDR word 0x2b600 (bytes 0..3). Reveals whether it is EVER populated with a
            // non-zero pointer (never-written => population missing; written-then-zeroed => a bad store).
            if (a == (0x15b000u >> 3) && (be & 0x0f)) {
                static int tbl_n = 0;
                if (tbl_n < 40) { tbl_n++;
                    uint64_t nv = (ddr[a] & ~mask) | (din & mask);
                    fprintf(stderr, "[VEN-TBL5C] [0x1005c000/phys0x15b000] <- %08x (din=%016llx be=%02x) burst_base=%08x cnt=%u t=%llu\n",
                            (unsigned)(nv & 0xffffffffu), (unsigned long long)din, be, g_wbase_dbg, g_wcnt_dbg, (unsigned long long)main_time);
                }
            }
            ddr[a] = (ddr[a] & ~mask) | (din & mask);
            waddr++; if (--wrem <= 0) wburst = false;
        }
    }
    if (!rd_fifo.empty() && main_time >= rd_fifo.front().ready) {
        top->DDRAM_DOUT = rd_fifo.front().data; top->DDRAM_DOUT_READY = 1; rd_fifo.pop_front();
    } else top->DDRAM_DOUT_READY = 0;
    // Golden model: BUSY never asserts. FPGA (ven_ddram_axi): BUSY = (st != IDLE), i.e. asserted
    // from the RD/WE accept until the whole burst has drained. Reproduce that when g_fpga_ddr.
    top->DDRAM_BUSY = g_fpga_ddr ? (uint8_t)(!rd_fifo.empty() || wburst) : 0;
}

static int g_vga_phase = 0, g_vga_div = 4;
static int g_vga_jit = 1;              // 1 = jitter the clk_vga period (default on), 0 = off
static uint32_t g_vga_lcg = 0x1234567u;
// The 0x3DA vertical-retrace flag lives in the clk_vga domain; the VGA-BIOS retrace poll
// (boot1.rom 0xC066d) samples it via the CPU io path. With a FIXED clk_vga divider the
// CPU's io-read cadence phase-LOCKS to clk_vga and can alias to always sample the flag in
// its non-retrace window -> the poll spins forever (a per-poll-instance hang that merely
// shifts with --vga-div). Jittering the clk_vga period by a deterministic ±1 (LCG, so it
// is reproducible) breaks the phase-lock: the sampling phase drifts through the whole
// frame within one 65536-iteration poll, so the retrace-high window is always eventually
// caught. The VGA CRTC counts clk_vga EDGES (not their spacing), so jittered edge timing
// leaves frame geometry / retrace duration unchanged. Toggle off with --vga-jit 0.
static inline void step_vga_clock() {
    int extra = 0;
    if (g_vga_jit) { g_vga_lcg = g_vga_lcg * 1103515245u + 12345u; extra = (g_vga_lcg >> 30) & 1; }
    if (++g_vga_phase >= g_vga_div + extra) { g_vga_phase = 0; top->clk_vga = !top->clk_vga; }
}
static inline void set_clocks(int v) { top->clk_sys=v; top->clk_audio=v; top->clk_uart1=v; top->clk_uart2=v; top->clk_mpu=v; }
static void tick() {
    set_clocks(0); top->eval();
    set_clocks(1); step_vga_clock(); top->eval();
    ddr_service(); top->eval();
    main_time++;
}
void ps_clock_tick() { tick(); }   // ps_shim.cpp advances the RTL through this

// ---- save/load state: snapshot the slow POST so debug iterations resume in seconds ----
// Captures harness time + Ventium retire count, the DDR array, the DDR-model read FIFO
// (addr+ready+data — the pop side returns the stored .data) and write-burst state, the
// VGA clock-divider phase/LCG, the Ventium x87 co-sim state (C-side, absent from the RTL),
// and the verilated SoC (top; needs --savable). The PS (ps_shim/x86/ide) disk is
// re-attached by x86_init before restore, so take the snapshot at a QUIESCENT point
// (POST done, no in-flight ide/fdd transaction) or PS-side transfer state would be lost.
static void save_state(const char *fn) {
    VerilatedSave os; os.open(fn);
    os.write(&main_time, sizeof(main_time));
    os.write(&g_vtm_retires, sizeof(g_vtm_retires));
    os.write(ddr, DDR_WORDS * sizeof(uint64_t));
    uint64_t n = rd_fifo.size(); os.write(&n, sizeof(n));
    for (auto &b : rd_fifo) { os.write(&b.addr, sizeof(b.addr)); os.write(&b.ready, sizeof(b.ready)); os.write(&b.data, sizeof(b.data)); }
    os.write(&wburst, sizeof(wburst)); os.write(&waddr, sizeof(waddr)); os.write(&wrem, sizeof(wrem));
    os.write(&g_vga_phase, sizeof(g_vga_phase)); os.write(&g_vga_lcg, sizeof(g_vga_lcg));
    os << *top;   // Ventium x87 state lives inside the RTL (no linked C-side FPU co-sim)
    os.close();
    fprintf(stderr, ">>> STATE SAVED to %s @cyc=%llu retires=%llu\n", fn,
            (unsigned long long)main_time, (unsigned long long)g_vtm_retires);
}
static void load_state(const char *fn) {
    VerilatedRestore is; is.open(fn);
    is.read(&main_time, sizeof(main_time));
    is.read(&g_vtm_retires, sizeof(g_vtm_retires));
    is.read(ddr, DDR_WORDS * sizeof(uint64_t));
    uint64_t n = 0; is.read(&n, sizeof(n)); rd_fifo.clear();
    for (uint64_t i = 0; i < n; i++) { RdBeat b; is.read(&b.addr, sizeof(b.addr)); is.read(&b.ready, sizeof(b.ready)); is.read(&b.data, sizeof(b.data)); rd_fifo.push_back(b); }
    is.read(&wburst, sizeof(wburst)); is.read(&waddr, sizeof(waddr)); is.read(&wrem, sizeof(wrem));
    is.read(&g_vga_phase, sizeof(g_vga_phase)); is.read(&g_vga_lcg, sizeof(g_vga_lcg));
    is >> *top;   // Ventium x87 state lives inside the RTL (no linked C-side FPU co-sim)
    is.close();
    fprintf(stderr, ">>> STATE LOADED from %s @cyc=%llu retires=%llu\n", fn,
            (unsigned long long)main_time, (unsigned long long)g_vtm_retires);
}

static void tie_static_inputs() {
    if (g_clock_rate < 50000) { fprintf(stderr, "[warn] clock_rate too low; clamping to 4MHz\n"); g_clock_rate = 4000000; }  // TEMP: allow low rates to mimic FPGA high-CPI interrupt density
    top->clock_rate = g_clock_rate; top->clock_rate_vga = g_rate_vga; top->rtc_clock_rate = g_rtc_rate;
    top->l1_disable = g_l1dis; top->l2_disable = g_l2dis; top->bootcfg = 0; top->uma_ram = 0;
    top->l2_fpu_inv_pulse = 0; top->l2_fpu_inv_addr = 0;
    top->joystick_dis = 3; top->joystick_dig_1 = top->joystick_dig_2 = 0;
    top->joystick_ana_1 = top->joystick_ana_2 = 0; top->joystick_mode = top->joystick_timed = 0;
    top->floppy_wp = 0;
    top->mgmt_address = 0; top->mgmt_read = 0; top->mgmt_write = 0; top->mgmt_writedata = 0;
    top->ps2_kbclk_in = 1; top->ps2_kbdat_in = 1; top->ps2_mouseclk_in = 1; top->ps2_mousedat_in = 1;
    top->uart1_rx = 1; top->uart1_cts_n = 1; top->uart1_dcd_n = 1; top->uart1_dsr_n = 1;
    top->uart2_rx = 1; top->uart2_cts_n = 1; top->uart2_dcd_n = 1; top->uart2_dsr_n = 1;
    top->mpu_rx = 1; top->sound_fm_mode = 0; top->sound_cms_en = 0;
    top->video_f60 = 0; top->video_fb_en = 0; top->video_lores = 0; top->video_border = 0;
    top->DDRAM_BUSY = 0; top->DDRAM_DOUT = 0; top->DDRAM_DOUT_READY = 0;
}

// PS entry points (support/x86/x86.cpp)
extern void x86_init();
extern void x86_poll(int only_ide);

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (const char *e = getenv("FPGA_DDR")) { g_fpga_ddr = atoi(e); fprintf(stderr, "[FPGA_DDR=%d] ven_ddram_axi-like DDRAM (BUSY + %s)\n", g_fpga_ddr, g_fpga_ddr>=2?"HP0 latency/gaps":"golden latency"); }
    uint64_t cycles = 200000000; const char *ide_path = nullptr;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--cycles") && i+1<argc) cycles = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--rate") && i+1<argc) g_clock_rate = strtoul(argv[++i], 0, 0);
        // clock_rate_vga gates ce_video (pixel advance rate = pixclk/clock_rate_vga per clk_vga
        // edge). LOWER it (≤ pixclk ~25MHz) → ce_video fires every edge → frames + vertical
        // retrace come much more often → the retrace-synced VGA-BIOS POST completes far faster.
        // Safe with the sticky-retrace latch (which removes the fast-clk_vga CDC race).
        else if (!strcmp(argv[i], "--rate-vga") && i+1<argc) g_rate_vga = strtoul(argv[++i], 0, 0);
        // l2_disable: force every access to fetch from the backing (no L2 caching). For
        // touch-once POST accesses the L2 fill/FSM can cost more than a direct DDR fetch;
        // routing (DDR/VGA-aperture/BIOS-shadow) is preserved (l2_cache.v force_fetch|DISABLE).
        else if (!strcmp(argv[i], "--l2dis") && i+1<argc) g_l2dis = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--l1dis") && i+1<argc) g_l1dis = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--ddrlat") && i+1<argc) g_ddr_lat = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--mem") && i+1<argc) g_mem_top_words = (uint64_t)atoi(argv[++i]) * 0x20000ull;
        else if (!strcmp(argv[i], "--ide") && i+1<argc) ide_path = argv[++i];
        else if (!strcmp(argv[i], "--vtm-dump") && i+1<argc) g_vtm_dump = atoi(argv[++i]);
        // clk_vga divider: clk_vga toggles every g_vga_div ticks. The 0x3DA vertical-
        // retrace flag lives in the clk_vga domain; if it races the clk_sys host-bus read
        // the CPU never samples the toggle and the VGA-BIOS retrace poll (boot1.rom
        // 0xC066d) spins forever. Tunable so the Ventium io cadence can be de-aliased.
        else if (!strcmp(argv[i], "--vga-div") && i+1<argc) g_vga_div = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--vga-jit") && i+1<argc) g_vga_jit = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--save-at") && i+1<argc) g_save_at = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--save-every") && i+1<argc) { g_save_every = strtoull(argv[++i], 0, 0); g_next_save = g_save_every; }
        else if (!strcmp(argv[i], "--save-file") && i+1<argc) g_save_file = argv[++i];
        else if (!strcmp(argv[i], "--restore") && i+1<argc) g_restore_file = argv[++i];
    }
    fprintf(stderr, ">>> sim_ven: vga_div=%d vga_jit=%d clock_rate=%u\n", g_vga_div, g_vga_jit, g_clock_rate);

    top = new Vsystem;
    ddr = (uint64_t *)calloc(DDR_WORDS, sizeof(uint64_t));
    tie_static_inputs();

    // Reset: hold the SoC in reset a few clocks (the shim cold-resets Ventium at
    // F000:FFF0 real mode on rst release, boot_mode=1 tied inside the shim).
    top->reset = 1;
    for (int i = 0; i < 16; i++) tick();
    // Attach the --ide image as HDD0 (num=2 => hdd_set(0)) BEFORE x86_init so its ide_reset
    // picks up the geometry — mirrors board_shim. Lets the cosim COLD-BOOT a disk (vs restore).
    if (ide_path) { extern void x86_set_image(int, char*); x86_set_image(2, (char*)ide_path);
                    fprintf(stderr, ">>> cosim: mounting HDD0 %s\n", ide_path); }
    // PS init: load BIOS ROMs into DDR, program CMOS, attach the disk image.
    x86_init();
    top->reset = 0;
    // Resume a prior POST snapshot: x86_init has re-attached the disk; load_state now
    // overwrites DDR + RTL + FIFO + FPU + time with the snapshot (must be QUIESCENT).
    if (g_restore_file) load_state(g_restore_file);
    fprintf(stderr, ">>> ventium-soc: reset released; running up to %llu cycles\n",
            (unsigned long long)cycles);

    uint64_t last_report = 0;
    while (main_time < cycles && !Verilated::gotFinish()) {
        tick();
        // Serve disk/floppy mgmt requests exactly like the ao486 sim.
        if (top->ide0_request || top->ide1_request || top->fdd_request) x86_poll(0);
        // IDE RESET-FINISH: the FPGA daemon calls ide_io(0,0) UNCONDITIONALLY every iteration
        // (board_shim.cpp:553) — ide_io(num,0) transitions the IDE from RESET->IDLE (status=RDY).
        // The request-gated x86_poll path above can MISS this (a reset that raises no mgmt request
        // leaves the IDE stuck in RESET -> BIOS never detects the drive -> INT19 boot fails -> HALT).
        // ide_io(n,0) is a no-op unless state==RESET, so calling it every tick is safe.
        { extern void ide_io(int, int); ide_io(0, 0); ide_io(1, 0); }
        // OPEN-FAILURE TRACE: the failed COMMAND.COM open is at reads=71. Enable the per-retire
        // register trace (vtm_retire -> stderr) once reads>=66 so the IO.SYS dir-search/open decision
        // is captured with full register/flag state. Auto-off after a bounded window so the log stays
        // finite (the open + a few idle cycles is enough).
        static int trace_armed = 0;
        if (g_disk_reads >= 66 && !trace_armed) {
            trace_armed = 1;
            g_vtm_dump = 700000;   // vtm_retire decrements this once per retire -> a BOUNDED, contiguous
                                   // 700k-retire trace covering reads 66->71 (the open) + the error path.
            fprintf(stderr, ">>> TRACE ON at reads=%lu retires=%llu cs=%04x:eip=%08x\n",
                    g_disk_reads, (unsigned long long)g_vtm_retires, g_vtm_cs, g_vtm_eip);
        }
        // OPEN-FAILURE MEMORY DUMP (one-shot, reads>=70): scan guest RAM for the "COMMAND COM" root-dir
        // entry (is IO.SYS's in-memory dir intact?) and for the target FCB name IO.SYS parsed (is the
        // path-parse correct?). Distinguishes a corrupt dir buffer / mis-parsed name from a compare bug.
        static int memdump_done = 0;
        if (!memdump_done && g_disk_reads >= 70 && ddr) {
            memdump_done = 1;
            uint8_t *g = (uint8_t*)ddr;
            static const uint8_t cc[11] = {0x43,0x4F,0x4D,0x4D,0x41,0x4E,0x44,0x20,0x43,0x4F,0x4D}; // "COMMAND COM"
            fprintf(stderr, ">>> MEMDUMP at reads=%lu\n", g_disk_reads);
            int nf=0;
            for (uint32_t a=0x400; a<0x200000 && nf<8; a++) {
                if (g[a]==cc[0] && !memcmp(g+a,cc,11)) {
                    uint16_t cl=g[a+26]|(g[a+27]<<8); uint32_t sz=g[a+28]|(g[a+29]<<16); (void)sz;
                    fprintf(stderr, "  RDMEM 'COMMAND COM' @%06x attr=%02x cluster=%u\n", a, g[a+11], cl);
                    nf++;
                }
            }
            if (!nf) fprintf(stderr, "  RDMEM: no intact 'COMMAND COM' dir entry -> dir buffer corrupt\n");
            // dump the search-TARGET FCB name (ss:0x54b = lin ~0x11DB) vs the dir ENTRY (0x3154). If the
            // target != "COMMAND COM", the path->FCB name build is buggy (string op); else the compare is.
            auto dumpr=[&](const char*tag,uint32_t a){ fprintf(stderr,"  %s @%05x: ",tag,a);
                for(int k=0;k<16;k++)fprintf(stderr,"%02x ",g[a+k]); fprintf(stderr," | ");
                for(int k=0;k<16;k++){uint8_t c=g[a+k];fprintf(stderr,"%c",(c>=32&&c<127)?c:'.');} fprintf(stderr,"\n"); };
            for (uint32_t base=0x11C0; base<=0x1210; base+=16) dumpr("TARGET-area", base);
            dumpr("ENTRY 3154", 0x3154);
            // dump the COMMAND.COM disk BUFFER DATA (ds:0x1904 = 0x49C4) — should be "MZ..." if LBA 193472
            // was read; stale/zeros if the read never happened; something else => wrong-LBA read.
            for (uint32_t base=0x49C0; base<0x4A40; base+=32) {
                fprintf(stderr, "  BUFDATA@%05x: ", base);
                for (int k=0;k<32;k++) fprintf(stderr, "%02x", g[base+k]);
                fprintf(stderr, " | ");
                for (int k=0;k<32;k++){uint8_t c=g[base+k]; fprintf(stderr,"%c",(c>=32&&c<127)?c:'.');}
                fprintf(stderr, "\n");
            }
            // dump the FULL IO.SYS SYSINIT code segment (cs=0756 -> lin 0x7560..0x17560, 64KB) so the
            // open-completion / cluster-read path can be disassembled offline.
            for (uint32_t base=0x7560; base<0x17560; base+=64) {
                fprintf(stderr, "  SEG0756@%05x:", base);
                for (int k=0;k<64;k++) fprintf(stderr, "%02x", g[base+k]);
                fprintf(stderr, "\n");
            }
            // also scan for the parsed name variants (case/format bugs): "COMMAND" (7) anywhere
            static const uint8_t c7[7] = {0x43,0x4F,0x4D,0x4D,0x41,0x4E,0x44};
            int n7=0;
            for (uint32_t a=0x400; a<0x40000 && n7<12; a++) {
                if (g[a]==c7[0] && !memcmp(g+a,c7,7)) {
                    fprintf(stderr, "  NAME 'COMMAND' @%06x next8: ", a);
                    for (int k=7;k<19;k++) fprintf(stderr,"%02x", g[a+k]);
                    fprintf(stderr, " ascii:");
                    for (int k=0;k<19;k++){uint8_t c=g[a+k]; fprintf(stderr,"%c",(c>=32&&c<127)?c:'.');}
                    fprintf(stderr, "\n"); n7++;
                }
            }
        }
        // One-shot POST snapshot for fast debug-iteration resume (--save-at).
        if (g_save_at && main_time >= g_save_at) { save_state(g_save_file); g_save_at = 0; }
        // Periodic cycle-stamped snapshots (--save-every) — captures POST progress even
        // when the exact completion cycle is unknown; resume from the furthest post-POST one.
        if (g_save_every && main_time >= g_next_save) {
            char fn[300]; snprintf(fn, sizeof fn, "%s.%llu", g_save_file, (unsigned long long)main_time);
            save_state(fn); g_next_save += g_save_every;
        }
        // Periodic progress: the Ventium retire trace (eip/cs from vtm_retire).
        if (main_time - last_report >= 500000) {
            last_report = main_time;
            fprintf(stderr, "[%10llu] retires=%llu cs=%04x:eip=%08x cr0=%08x cr3=%08x eflags=%08x\n",
                    (unsigned long long)main_time, (unsigned long long)g_vtm_retires,
                    g_vtm_cs, g_vtm_eip, g_vtm_cr0, g_vtm_cr3, g_vtm_eflags);
        }
    }
    fprintf(stderr, ">>> done: cyc=%llu retires=%llu last cs=%04x:eip=%08x\n",
            (unsigned long long)main_time, (unsigned long long)g_vtm_retires, g_vtm_cs, g_vtm_eip);
    top->final(); delete top; free(ddr);
    return 0;
}
