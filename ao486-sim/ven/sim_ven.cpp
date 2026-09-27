// sim_ven.cpp — Verilator co-sim harness for the Ventium core inside the ao486 SoC.
//
// The SoC (system.v built +VEN_CORE) instantiates ven_ao486_shim → ventium_top in
// place of the ao486 core; everything else in the SoC is unchanged. This harness is
// the same shape as the ao486 sim (drive the top-level SoC ports, model DDR, run the
// MiSTer HPS software as the PS via ps_shim/x86/ide) — minus every ao486-core-internal
// read (the Ventium core is observed via the vtm_retire DPI in vtm_dpi.cpp instead).
// Reuses ps_shim.cpp + support/x86/x86.cpp + ide.cpp verbatim. See VENTIUM_SWAP.md §7.

#include "Vsystem.h"
#include "Vsystem___024root.h"   // VGA plane-RAM/DAC frame capture
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <deque>
#include <vector>
#include "verilated_save.h"
#include "tlb_probe.h"
#include "perf_sample.h"
#include "l1_fill_probe.h"
#include "fp_async_probe.h"
#include "slow_decode_profile.h"
#include "vga_text_address.h"
#include "ide_checkpoint.h"
#include "rtc_rate.h"
#include "profile_code.h"
#include <cerrno>
#ifdef VEN_STATE_DELTA_HOST
#if !__has_include("ven_state_fields.inc")
#error "Generate the complete state observer with tools/build_state_delta.py"
#endif
#include "state_delta.h"
#define VEN_HAVE_STATE_DELTA 1
static StateDelta g_state_delta;
static bool g_delta_open = false;
#endif
static const char* g_delta_path = nullptr;
static uint64_t g_delta_start = 0, g_delta_cycles = 1000000;
static bool g_delta_armed = false;

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
// `--mem` constrains the physical DDR model *and* must be reflected in CMOS.
// Keep zero as the historical "leave x86_init's 16 MiB CMOS default alone".
static int      g_mem_mb = 0;
// Keep the legacy RTC default for reproducibility of existing native snapshots.
// New wall-time-correct measurements must explicitly pass --rate-rtc equal to
// --rate; --rate alone historically changed PIT timing but NOT RTC timing.
static uint32_t g_clock_rate = 4000000, g_rtc_rate = 80000, g_rate_vga = 90000000;
static int      g_l1dis = 0, g_l2dis = 0;
static uint64_t g_save_at = 0;                     // --save-at N: snapshot at cycle N (one-shot), then continue
static uint64_t g_save_every = 0;                  // --save-every N: re-snapshot every N cycles (cycle-stamped)
static uint64_t g_next_save = 0;                   // internal: next --save-every threshold
static const char *g_save_file = "ven_post.snap";  // --save-file FN (base name; --save-every appends .<cyc>)
static const char *g_restore_file = nullptr;        // --restore FN: load snapshot right after x86_init
static bool g_snapshot_v2 = false, g_save_stop = false;
static bool g_snapshot_v3 = false;
// Read-only, bounded pre-edge FSM diagnostic; not checkpointed guest state.
static uint64_t g_state_trace_start = 0, g_state_trace_cycles = 0;
// The IDE daemon's per-register/per-sector trace is useful for an ATA wedge,
// but thousands of host printf calls alter profiler wall time and can exhaust
// an attached terminal's output quota.  It has no simulated hardware effect;
// leave it off for normal runs and expose it explicitly for diagnosis.
bool g_ide_verbose = false;                          // --ide-verbose

// ---- vtm retire trace globals (defined in vtm_dpi.cpp) ------------------------
extern "C" { extern uint64_t g_vtm_retires; extern uint32_t g_vtm_eip,g_vtm_eflags,
    g_vtm_eax,g_vtm_esp,g_vtm_cr0,g_vtm_cr2,g_vtm_cr3; extern uint16_t g_vtm_cs;
    extern uint32_t g_vtm_ecx,g_vtm_edx,g_vtm_ebx,g_vtm_esi,g_vtm_edi; extern uint16_t g_vtm_ds,g_vtm_es;
    extern int g_vtm_dump; extern uint64_t g_vtm_dump_start; }

// Disk-read counter (bumped by ps/ide.cpp on each READ) — the COMMAND.COM open-failure point is
// reads=71; used below to auto-enable the per-retire register trace right before the open so the
// dir-search compare (and the flag/branch that mis-decides "not found") is captured.
volatile unsigned long g_disk_reads = 0;

// --open-trace: arms the July open-failure trace/memdump hooks (off by default —
// the 700k-retire register dump otherwise floods every disk-boot run).
static int g_open_trace = 0;
// Generic non-invasive core-breakpoint harness.  The RTL debug port already
// owns the halt/scan semantics; these options merely make it usable from a
// cold full-PC replay without adding another probe path.
static bool     g_ven_break_enable = false;
static bool     g_ven_break_armed  = false;
static bool     g_ven_break_seen   = false;
static bool     g_ven_break_mem_enable = false;
static uint32_t g_ven_break_eip    = 0;
static uint32_t g_ven_break_linear = 0;
static uint64_t g_ven_break_retire = 0;
// Optional persistent counterpart to the debugger's stderr report.  A long
// cold-boot diagnostic can be run under a supervisor whose captured stderr is
// not retained after the child exits; writing only this host-side observation
// keeps the debugger result reproducible without changing guest or RTL state.
static const char *g_ven_break_report_path = nullptr;
// Opt-in read-only page-walk observer.  This deliberately reads the generated
// model state rather than adding an RTL probe; it is for narrowing a cold-boot
// failure to the access that launched a walk.
static bool     g_ven_watch_walk_enable = false;
static uint32_t g_ven_watch_walk_eip = 0;
static bool     g_ven_watch_walk_active = false;
static unsigned g_ven_watch_walk_step = 8;
static unsigned g_ven_watch_walk_count = 0;
// Read-only TLB/path attribution for a cold whole-PC run.  It deliberately
// observes the generated model at the request edge instead of adding counters
// to RTL: this lets a profiler distinguish direct-map conflicts, dirty-bit
// rewrites, and architectural flushes before proposing a performance change.
static const char *g_ven_tlb_report_path = nullptr;
// Opt-in cumulative stall snapshots, independent of guest/frame timing.
static uint64_t g_ven_perf_every = 0, g_ven_perf_last = 0;
static SlowDecodeProfile g_slow_decode_profile;
static uint64_t g_ven_tlb_launch = 0, g_ven_tlb_i_nohit = 0;
static uint64_t g_ven_tlb_d_nohit = 0, g_ven_tlb_d_rewalk = 0;
static uint64_t g_ven_tlb_d_clean_rewalk = 0, g_ven_tlb_flush = 0;
static uint64_t g_ven_tlb_i_fill = 0, g_ven_tlb_d_fill = 0;
static uint64_t g_ven_tlb_d_fill_same = 0, g_ven_tlb_d_fill_conflict = 0;
static uint64_t g_ven_tlb_d_fill_invalid = 0;
static uint64_t g_ven_tlb_launch_state[128] = {};
static uint64_t g_ven_tlb_flush_state[128] = {};
static uint64_t g_ven_tlb_i_index[16] = {}, g_ven_tlb_d_index[16] = {};
// Exact linear-VPN histogram, allocated only with --ven-tlb-report.  All
// 32-bit linear pages fit in 8 MiB; no unbounded per-access trace or map.
// Counts aggregate CR3 contexts, so they identify hot addresses, not processes.
static std::vector<uint64_t> g_ven_tlb_d_pages;
// Bounded, read-only observer for the MiSTer L2 state machine.  This is for
// bridge/cache integration failures where an instruction-level stop can say
// only that the core is awaiting an I/D-side response.  It reads generated
// model state; it has no RTL or guest-state effect and is off by default.
static bool     g_ven_l2_watch_enable = false;
static uint64_t g_ven_l2_watch_start = 0;
static uint8_t  g_ven_l2_watch_last_state = 0xff;
static unsigned g_ven_l2_watch_events = 0;
// --rmtest: stop once the focused nested-IRQ ROM records success/failure and
// print its low-RAM witness counters. AO486_BIOS_DIR selects that test ROM.
static int g_rmtest = 0;
// --vgatext-every N: print an 80x25 character window from VGA plane 0 every N
// cycles, so boot/Quake progress is observable without a display.
extern "C" int ao486_peek_guest(unsigned int phys, void *dst, int nbytes);
static uint64_t g_vgatext_every = 0;
static uint64_t g_vgatext_next  = 0;
static void vgatext_dump() {
    if (!top) return;
    const auto *r = top->rootp;
    if (r->system__DOT__vga__DOT__attrib_graphic_mode) return;
    const unsigned start = r->system__DOT__vga__DOT__crtc_address_start;
    const unsigned stride = 2u * r->system__DOT__vga__DOT__crtc_address_offset;
    fprintf(stderr, "[VGATEXT @%llu start=%04x stride=%u; 80x25 character window]\n",
            (unsigned long long)main_time, start & 0xffffu, stride);
    for (int row = 0; row < 25; row++) {
        char line[81]; int e = 80;
        for (int col = 0; col < 80; col++) {
            const auto address = vga_text_address(
                uint16_t(start + r->system__DOT__vga__DOT__crtc_address_byte_panning
                         + unsigned(row) * stride + unsigned(col)),
                r->system__DOT__vga__DOT__crtc_address_doubleword,
                r->system__DOT__vga__DOT__crtc_address_byte,
                r->system__DOT__vga__DOT__crtc_address_bit0,
                r->system__DOT__vga__DOT__crtc_address_bit13,
                r->system__DOT__vga__DOT__crtc_address_bit14);
            unsigned char c = r->system__DOT__vga__DOT__plane_ram_0__DOT__mem[address];
            line[col] = (c >= 32 && c < 127) ? (char)c : ' ';
        }
        line[80] = 0; while (e > 0 && line[e-1] == ' ') e--; line[e] = 0;
        if (e > 0) fprintf(stderr, "  |%s\n", line);
    }
}

static uint16_t guest_word(uint32_t phys) {
    uint8_t v[2] = {0, 0};
    ao486_peek_guest(phys, v, 2);
    return (uint16_t)(v[0] | ((uint16_t)v[1] << 8));
}

static void rmtest_dump() {
    fprintf(stderr,
            "[RMTEST] irq=%u sw_enter=%u sw_return=%u nested=%u bad=%u "
            "pop_return=%u pop_bad=%u pop_nested=%u main_bad=%u\n",
            guest_word(0x500), guest_word(0x502), guest_word(0x504),
            guest_word(0x506), guest_word(0x508), guest_word(0x50c),
            guest_word(0x50e), guest_word(0x512), guest_word(0x514));
}

// ---- VGA frame capture (ported from the legacy sim) ----------------------------
// Reads the displayed image straight out of the VGA plane RAM + DAC palette in the
// verilated model (mode 13h 320x200x256 chain-4; mode 12h 640x480x16 planar).
// --fb-every N: dump a numbered PPM every N cycles while in a graphics mode.
static uint64_t g_fb_every = 0;
static uint64_t g_fb_next  = 0;
static int      g_fb_n = 0;
static const char *g_fb_out = "/home/yukidama/external/ventium_run/ven_fb";   // --fb-out
static int in_graphics_mode() {
    auto *R = top->rootp;
    return R->system__DOT__vga__DOT__attrib_graphic_mode;
}
static void dump_fb_frame(int n) {
    auto *R = top->rootp;
    if (!R->system__DOT__vga__DOT__attrib_graphic_mode) return;
    int chain4 = R->system__DOT__vga__DOT__seq_access_chain4;
    int pel2   = R->system__DOT__vga__DOT__attrib_pelclock_div2;
    uint32_t start = R->system__DOT__vga__DOT__crtc_address_start & 0xffffu;
    char path[300];
    snprintf(path, sizeof path, "%s_%05d.ppm", g_fb_out, n);
    FILE *f = fopen(path, "wb"); if (!f) return;
    auto DAC = [&](uint8_t idx)->uint32_t { return R->system__DOT__vga__DOT__dac_ram__DOT__mem[idx]; };
    auto WR  = [&](uint32_t d){ fputc(((d>>12)&0x3f)*255/63, f); fputc(((d>>6)&0x3f)*255/63, f); fputc((d&0x3f)*255/63, f); };
    long nz = 0; const char *modestr;
    if (chain4 && pel2) {
        // mode 13h: 320x200x256 chain-4 doubleword: pixel N -> plane N&3, offset N&~3
        modestr = "13h-256";
        fprintf(f, "P6\n320 200\n255\n");
        for (int y = 0; y < 200; y++) for (int x = 0; x < 320; x++) {
            uint32_t off = start + (uint32_t)y * 320u + (uint32_t)x;
            uint32_t po = (off & ~3u) & 0xffffu; uint8_t idx;
            switch (off & 3u) {
                case 0:  idx = R->system__DOT__vga__DOT__plane_ram_0__DOT__mem[po]; break;
                case 1:  idx = R->system__DOT__vga__DOT__plane_ram_1__DOT__mem[po]; break;
                case 2:  idx = R->system__DOT__vga__DOT__plane_ram_2__DOT__mem[po]; break;
                default: idx = R->system__DOT__vga__DOT__plane_ram_3__DOT__mem[po]; break;
            }
            if (idx) nz++; WR(DAC(idx));
        }
    } else {
        // mode 12h: 640x480x16 planar (Win95 std VGA)
        modestr = "12h-16planar";
        int W = 640, H = 480;
        uint32_t stride = 2u * (R->system__DOT__vga__DOT__crtc_address_offset & 0x1ffu);
        if (stride == 0) stride = 80;
        fprintf(f, "P6\n%d %d\n255\n", W, H);
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
            uint32_t addr = (start + (uint32_t)y * stride + (uint32_t)(x >> 3)) & 0xffffu;
            int bit = 7 - (x & 7);
            int b0 = (R->system__DOT__vga__DOT__plane_ram_0__DOT__mem[addr] >> bit) & 1;
            int b1 = (R->system__DOT__vga__DOT__plane_ram_1__DOT__mem[addr] >> bit) & 1;
            int b2 = (R->system__DOT__vga__DOT__plane_ram_2__DOT__mem[addr] >> bit) & 1;
            int b3 = (R->system__DOT__vga__DOT__plane_ram_3__DOT__mem[addr] >> bit) & 1;
            int index = (b3 << 3) | (b2 << 2) | (b1 << 1) | b0;
            uint8_t pel6 = R->system__DOT__vga__DOT__internal_palette_ram__DOT__mem[index] & 0x3f;
            if (index) nz++; WR(DAC(pel6));
        }
    }
    fclose(f);
    fprintf(stderr, "[FBCAP] %s mode=%s chain4=%d pel2=%d start=%u nz=%ld\n", path, modestr, chain4, pel2, start, nz);
}

// ---- PS/2 keyboard injection (device->host, Set-2 scancodes) ------------------
// Ported from the legacy sim (sim_main.cpp): the 8042 (ps2.v) runs with
// translate=1, so we transmit Set-2 make/break codes and it translates to Set-1.
// Open-drain wired-AND against the host's release lines; one bit = 24 sys-cycles
// high then 24 low. Dormant unless --kb is given. Tokens: named keys
// (enter/esc/space/tab/arrows/backspace), or type:<text> for an ASCII string
// (lowercase letters, digits, and ./~-_ map directly).
static const char *g_kb_script = nullptr;
static uint64_t g_kb_start = 3000000;
static uint64_t g_kb_gap   = 6000000;
static std::vector<std::vector<uint8_t>> g_kb_events;
static size_t   g_kb_ev_idx = 0;
static uint64_t g_kb_next_ev = 0;
static bool     g_kb_started = false;
static uint64_t g_kb_base = 0;
static bool     g_kb_base_set = false;
static std::deque<uint8_t> g_kbfifo;
static int      g_kb_bits[11];
static int      g_kb_phase = -1;
static int      g_kb_sub = 0;
static int      g_kb_gapcnt = 0;

static uint8_t ascii_to_set2(char c, int &ext) {
    ext = 0;
    if (c >= 'a' && c <= 'z') {
        static const uint8_t L[26] = {0x1C,0x32,0x21,0x23,0x24,0x2B,0x34,0x33,0x43,0x3B,
                                      0x42,0x4B,0x3A,0x31,0x44,0x4D,0x15,0x2D,0x1B,0x2C,
                                      0x3C,0x2A,0x1D,0x22,0x35,0x1A};
        return L[c - 'a'];
    }
    if (c >= '1' && c <= '9') { static const uint8_t D[9] = {0x16,0x1E,0x26,0x25,0x2E,0x36,0x3D,0x3E,0x46}; return D[c - '1']; }
    switch (c) {
        case '0': return 0x45; case ' ': return 0x29; case '.': return 0x49;
        case ',': return 0x41; case '/': return 0x4A; case '-': return 0x4E;
        case '=': return 0x55; case ';': return 0x4C; case '~': case '`': return 0x0E;
        case '_': return 0x4E;   /* shifted -: FreeDOS/Quake console treats it as - without shift */
    }
    return 0;
}
static void kb_push_key(uint8_t make, int ext) {
    std::vector<uint8_t> ev;
    if (ext) ev.push_back(0xE0); ev.push_back(make);
    if (ext) ev.push_back(0xE0); ev.push_back(0xF0); ev.push_back(make);
    g_kb_events.push_back(ev);
}
static void kb_build_events(const char *script) {
    char *dup = strdup(script); if (!dup) return;
    static const struct { const char *name; uint8_t make; int ext; } NAMED[] = {
        {"enter",0x5A,0},{"esc",0x76,0},{"space",0x29,0},{"tab",0x0D,0},
        {"backspace",0x66,0},{"up",0x75,1},{"down",0x72,1},{"left",0x6B,1},{"right",0x74,1},
    };
    for (char *tok = strtok(dup, ","); tok; tok = strtok(nullptr, ",")) {
        if (!strncmp(tok, "type:", 5)) {
            for (const char *p = tok + 5; *p; p++) {
                int ext; uint8_t m = ascii_to_set2(*p, ext);
                if (m) kb_push_key(m, ext);
            }
            continue;
        }
        for (auto &km : NAMED) if (!strcmp(tok, km.name)) { kb_push_key(km.make, km.ext); break; }
    }
    free(dup);
    fprintf(stderr, ">>> [kbinject] %zu key event(s) parsed from \"%s\"\n", g_kb_events.size(), script);
}
static void kb_load_byte(uint8_t b) {
    int par = 1; g_kb_bits[0] = 0;
    for (int k = 0; k < 8; k++) { int bit = (b >> k) & 1; g_kb_bits[1 + k] = bit; par ^= bit; }
    g_kb_bits[9] = par; g_kb_bits[10] = 1; g_kb_phase = 0; g_kb_sub = 0;
}
static void ps2_kb_drive() {
    if (!g_kb_script) return;
    if (!g_kb_base_set) { g_kb_base = main_time; g_kb_base_set = true; }
    if (!g_kb_started && main_time >= g_kb_base + g_kb_start) { g_kb_started = true; g_kb_next_ev = main_time; }
    if (g_kb_started && g_kb_ev_idx < g_kb_events.size() && main_time >= g_kb_next_ev
        && g_kbfifo.empty() && g_kb_phase < 0) {
        for (uint8_t b : g_kb_events[g_kb_ev_idx]) g_kbfifo.push_back(b);
        g_kb_ev_idx++; g_kb_next_ev = main_time + g_kb_gap;
        fprintf(stderr, ">>> [kbinject] event %zu/%zu queued @cyc=%llu\n",
                g_kb_ev_idx, g_kb_events.size(), (unsigned long long)main_time);
    }
    int dat = 1, clk = 1;
    if (g_kb_phase < 0) {
        if (!g_kbfifo.empty() && top->ps2_kbclk_out && top->ps2_kbdat_out) {
            if (++g_kb_gapcnt >= 80) { g_kb_gapcnt = 0; uint8_t b = g_kbfifo.front(); g_kbfifo.pop_front(); kb_load_byte(b); }
        }
    }
    if (g_kb_phase >= 0) {
        dat = g_kb_bits[g_kb_phase];
        clk = (g_kb_sub < 24) ? 1 : 0;
        if (++g_kb_sub >= 48) { g_kb_sub = 0; if (++g_kb_phase > 10) g_kb_phase = -1; }
    }
    top->ps2_kbclk_in = clk & (top->ps2_kbclk_out ? 1 : 0);
    top->ps2_kbdat_in = dat & (top->ps2_kbdat_out ? 1 : 0);
}

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
// Shared-FP signals do not exist in every elaboration. Match the optional
// generated-member convention used by perf_sample.h; -1 means unavailable.
template<class Root>
static auto state_trace_fp_response(const Root &r, int)
    -> decltype((void)r.system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__fp_shared_rsp_valid, int()) {
    return r.system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__fp_shared_rsp_valid;
}
template<class Root>
static int state_trace_fp_response(const Root &, long) { return -1; }
static void tick() {
#ifdef VEN_HAVE_STATE_DELTA
    if (g_delta_armed && !g_delta_open && main_time >= g_delta_start) {
        auto* r = top->rootp;
        auto& delta = g_state_delta;
#include "ven_state_fields.inc"
        delta.add("harness.retired", g_vtm_retires, "uint64_t");
        delta.open(g_delta_path, main_time, g_delta_cycles);
        g_delta_open = true;
    }
#endif
    set_clocks(0); top->eval();
    if (g_state_trace_cycles && main_time >= g_state_trace_start &&
        main_time - g_state_trace_start < g_state_trace_cycles) {
        const auto *r = top->rootp;
#define CORE_OBS(name) r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__##name
        fprintf(stderr, "VENSTATE cyc=%llu n=%llu state=%u eip=%08x fx=%u step=%u ack=%u addr=%08x we=%u rsp=%d\n",
                (unsigned long long)main_time, (unsigned long long)g_vtm_retires,
                (unsigned)CORE_OBS(state), CORE_OBS(eip),
                (unsigned)CORE_OBS(q_fxop), (unsigned)CORE_OBS(f_step),
                (unsigned)CORE_OBS(mem_ack), CORE_OBS(bd_addr),
                (unsigned)CORE_OBS(bd_we), state_trace_fp_response(*r, 0));
#undef CORE_OBS
        ven_l1_fill_probe(stderr, *r, main_time, 0);
        ven_fp_async_probe(stderr, *r, main_time, 0);
    }
    if (g_ven_perf_every && !top->reset)
        g_slow_decode_profile.observe(
            top->rootp->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__state,
            top->rootp->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__ibuf);
    set_clocks(1); step_vga_clock(); top->eval();
    ddr_service(); top->eval();
    main_time++;
#ifdef VEN_HAVE_STATE_DELTA
    if (g_delta_open) g_state_delta.sample(main_time);
#endif
}
void ps_clock_tick() { tick(); }   // ps_shim.cpp advances the RTL through this

// The packed debug contract is documented in ven_ao486_shim.sv.  Keep these
// helpers here, at the system boundary, rather than reaching into generated
// core hierarchy: this is the same interface used by the FPGA debugger.
static void ven_debug_drive() {
    memset(top->cpu_dbg_cmp, 0, sizeof(top->cpu_dbg_cmp));
    if (!g_ven_break_armed) return;
    // dbg_cmp[66]=breakpoint enable; dbg_cmp[98:67]=EIP.
    top->cpu_dbg_cmp[2] = 0x4u | (g_ven_break_eip << 3);
    top->cpu_dbg_cmp[3] = g_ven_break_eip >> 29;
}

static uint32_t ven_dbg_word(unsigned lsb) {
    const unsigned w = lsb >> 5, sh = lsb & 31u;
    uint32_t v = top->cpu_dbg_bus[w] >> sh;
    if (sh) v |= top->cpu_dbg_bus[w + 1] << (32u - sh);
    return v;
}

static uint32_t ven_dbg_scan(unsigned sel) {
    // [106:100] is word 3, bits [10:4].  Preserve the breakpoint's upper EIP
    // bits and evaluate only the observer mux; no clock edge or RTL state move.
    const uint32_t ctrl = top->cpu_dbg_cmp[3] & 0x0fu;
    top->cpu_dbg_cmp[3] = ctrl | ((sel & 0x7fu) << 4);
    top->eval();
    const uint32_t v = ven_dbg_word(259);
    top->cpu_dbg_cmp[3] = ctrl;
    top->eval();
    return v;
}

static uint32_t ven_guest_rd32(uint32_t phys) {
    const uint32_t m = (uint32_t)(DDR_WORDS * sizeof(*ddr) - 1u);
    const uint8_t *p = ddr_bytes();
    phys &= m;
    return (uint32_t)p[phys] | ((uint32_t)p[(phys + 1u) & m] << 8) |
           ((uint32_t)p[(phys + 2u) & m] << 16) | ((uint32_t)p[(phys + 3u) & m] << 24);
}

static bool ven_page_translate(uint32_t cr3, uint32_t linear, uint32_t *phys) {
    const uint32_t pde = ven_guest_rd32((cr3 & 0xfffff000u) + ((linear >> 22) & 0x3ffu) * 4u);
    if (!(pde & 1u)) return false;
    if (pde & 0x80u) { *phys = (pde & 0xffc00000u) | (linear & 0x003fffffu); return true; }
    const uint32_t pte = ven_guest_rd32((pde & 0xfffff000u) + ((linear >> 12) & 0x3ffu) * 4u);
    if (!(pte & 1u)) return false;
    *phys = (pte & 0xfffff000u) | (linear & 0xfffu);
    return true;
}

static void ven_debug_report_break() {
    FILE *report = stderr;
    if (g_ven_break_report_path) {
        FILE *f = fopen(g_ven_break_report_path, "w");
        if (!f) {
            fprintf(stderr, "[VEN-BREAK] cannot open report %s\n", g_ven_break_report_path);
        } else {
            report = f;
        }
    }
    auto close_report = [&]() { if (report != stderr) fclose(report); };
    const uint32_t retired_eip = ven_dbg_word(2);
    const uint32_t eip = ven_dbg_scan(8);
    const uint32_t seg_cs_ss = ven_dbg_scan(10), seg_ds_es = ven_dbg_scan(11);
    const uint16_t cs = (uint16_t)seg_cs_ss;
    const uint32_t cr0 = ven_dbg_scan(13), cr2 = ven_dbg_scan(14), cr3 = ven_dbg_scan(15);
    const uint32_t cs_base = ven_dbg_scan(46);
    const uint32_t ss_base = ven_dbg_scan(47);
    const uint32_t ds_base = ven_dbg_scan(48);
    const uint32_t es_base = ven_dbg_scan(49);
    const uint32_t linear = cs_base + eip;
    const uint32_t eax = ven_dbg_scan(0), ecx = ven_dbg_scan(1);
    const uint32_t edx = ven_dbg_scan(2), ebx = ven_dbg_scan(3);
    const uint32_t esp = ven_dbg_scan(4), esi = ven_dbg_scan(6), edi = ven_dbg_scan(7);
    uint32_t phys = linear;
    const bool paged = cr0 & 0x80000000u;
    const bool mapped = !paged || ven_page_translate(cr3, linear, &phys);
    fprintf(report, "[VEN-BREAK] retire=%llu cs:eip=%04x:%08x (last-retired=%08x) cs_base=%08x cr0=%08x cr2=%08x cr3=%08x linear=%08x%s\n",
            (unsigned long long)g_vtm_retires, cs, eip, retired_eip, cs_base, cr0, cr2, cr3, linear,
            mapped ? "" : " UNMAPPED");
    fprintf(report, "[VEN-BREAK] eax=%08x ebx=%08x ecx=%08x edx=%08x esp=%08x esi=%08x edi=%08x ds_base=%08x\n",
            eax, ebx, ecx, edx, esp, esi, edi, ds_base);
    fprintf(report, "[VEN-BREAK] selectors cs=%04x ss=%04x ds=%04x es=%04x; ss_base=%08x es_base=%08x\n",
            (unsigned)seg_cs_ss & 0xffffu, (unsigned)(seg_cs_ss >> 16),
            (unsigned)seg_ds_es & 0xffffu, (unsigned)(seg_ds_es >> 16), ss_base, es_base);
    if (!mapped) { close_report(); return; }
    fprintf(report, "[VEN-BREAK] code phys=%08x:", phys);
    for (unsigned i = 0; i < 32; i++) {
        if (!(i & 15)) fprintf(report, "\n  ");
        fprintf(report, "%02x ", ddr_bytes()[(phys + i) & (DDR_WORDS * sizeof(*ddr) - 1u)]);
    }
    fprintf(report, "\n");
    if (g_ven_break_mem_enable) {
        uint32_t p = g_ven_break_linear;
        const bool ok = !paged || ven_page_translate(cr3, g_ven_break_linear, &p);
        fprintf(report, "[VEN-BREAK] probe linear=%08x%s", g_ven_break_linear,
                ok ? "" : " UNMAPPED");
        if (ok) fprintf(report, " phys=%08x value=%08x", p, ven_guest_rd32(p));
        fprintf(report, "\n");
    }
    close_report();
}

static void ven_debug_watch_walk() {
    if (!g_ven_watch_walk_enable || g_ven_watch_walk_count == 128) return;
    auto *r = top->rootp;
    // S_WALK is 40 for this elaborated KV260 profile.  Keep this observer
    // bounded and transition-based so a delayed PDE read emits one record.
    const bool hit = r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__state == 40
                  && r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__q_pc == g_ven_watch_walk_eip;
    const unsigned step = r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__walk_step;
    // A new step has just consumed the prior physical access.  Printing both
    // the latched entry and its table address lets a cold replay distinguish a
    // genuine demand-page miss from an incorrect walker address, without
    // changing a single RTL signal or guest-memory byte.
    if (hit && (!g_ven_watch_walk_active || step != g_ven_watch_walk_step)) {
        fprintf(stderr,
                "[VEN-WALK] n=%llu pc=%08x lin=%08x cur=%08x natural=%08x ret_state=%u step=%u d=%u w=%u usr=%u cr2=%08x pde@%08x=%08x pte@%08x=%08x str_dst=%08x esi=%08x edi=%08x ecx=%08x\n",
                (unsigned long long)g_vtm_retires, g_ven_watch_walk_eip,
                r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__walk_lin,
                r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__cur_lin,
                r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__cur_lin_nat,
                (unsigned)r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__walk_ret_state,
                step,
                (unsigned)r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__walk_set_dirty,
                (unsigned)r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__walk_is_write,
                (unsigned)r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__walk_usr_lat,
                r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__creg2,
                r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__walk_pde_addr,
                r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__walk_pde,
                r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__walk_pte_addr,
                r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__walk_pte,
                r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__str_store_addr,
                r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__gpr_o[6],
                r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__gpr_o[7],
                r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__gpr_o[1]);
        g_ven_watch_walk_count++;
    }
    g_ven_watch_walk_active = hit;
    g_ven_watch_walk_step = hit ? step : 8;
}

struct VenL2StreamWatch {
    unsigned fill = 0, rsp = 0, valid = 0, data = 0;
};

// Streaming L2 is optional. Detect its generated Verilator members at compile
// time so the default model builds, while stream-profile watches retain their
// response data without synchronizing a second C++ define with the RTL build.
template <typename Root>
static auto ven_l2_stream_watch(const Root *r)
    -> decltype(r->system__DOT__cache__DOT__scw_rsp_valid, VenL2StreamWatch{}) {
    return {unsigned(r->system__DOT__cache__DOT__scw_fill_count),
            unsigned(r->system__DOT__cache__DOT__scw_rsp_count),
            unsigned(r->system__DOT__cache__DOT__scw_rsp_valid),
            unsigned(r->system__DOT__cache__DOT__scw_rsp_data)};
}

static VenL2StreamWatch ven_l2_stream_watch(...) { return {}; }

static void ven_debug_watch_l2() {
    if (!g_ven_l2_watch_enable || main_time < g_ven_l2_watch_start ||
        g_ven_l2_watch_events == 256) return;
    auto *r = top->rootp;
    const uint8_t state = r->system__DOT__cache__DOT__state;
    const auto scw = ven_l2_stream_watch(r);
    // State transitions identify commands/fills.  The two valid signals add
    // the data-return events needed to distinguish a missing DDR beat from a
    // bridge that drops an otherwise valid streamed response.
    if (state != g_ven_l2_watch_last_state ||
        r->system__DOT__cache__DOT__ram_dout_ready ||
        scw.valid) {
        fprintf(stderr,
                "[VEN-L2] cyc=%llu ret=%llu state=%u wait=%u rd=%u burst=%u read=%07x ram=%07x fill=%u rsp=%u valid=%u data=%08x\n",
                (unsigned long long)main_time, (unsigned long long)g_vtm_retires,
                (unsigned)state, (unsigned)r->system__DOT__mem_waitrequest,
                (unsigned)r->system__DOT__cache__DOT__ram_rd,
                (unsigned)r->system__DOT__cache__DOT__ram_burstcnt,
                r->system__DOT__cache__DOT__read_addr,
                r->system__DOT__cache__DOT__ram_addr,
                scw.fill, scw.rsp, scw.valid, scw.data);
        g_ven_l2_watch_last_state = state;
        ++g_ven_l2_watch_events;
    }
}

static void ven_debug_watch_tlb() {
    if (!g_ven_tlb_report_path) return;
    auto *r = top->rootp;
    const unsigned state = r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__state;
    // This is sampled before tick().  `xlate_miss` is the exact combinational
    // admission predicate that the following core clock consumes; S_WALK then
    // makes the access non-translatable, so a walk contributes exactly once.
    if (r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__xlate_miss) {
        const unsigned index = (r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__cur_lin >> 12) & 15u;
        ++g_ven_tlb_launch;
        ++g_ven_tlb_launch_state[state];
        if (r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__cur_is_d) {
            if (g_ven_tlb_d_pages.empty()) g_ven_tlb_d_pages.resize(1u << 20);
            ++g_ven_tlb_d_pages[
                r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__cur_lin >> 12];
            const auto view = ven_tlb_probe(
                r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__cur_lin,
                r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__u_dtlb__DOT__tlb_val,
                r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__u_dtlb__DOT__tlb_vpn,
                r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__u_dtlb__DOT__tlb_dirty);
            ++g_ven_tlb_d_index[index];
            if (view.hit) {
                ++g_ven_tlb_d_rewalk;
                if (!view.dirty)
                    ++g_ven_tlb_d_clean_rewalk;
            } else {
                ++g_ven_tlb_d_nohit;
            }
        } else {
            ++g_ven_tlb_i_index[index];
            ++g_ven_tlb_i_nohit;
        }
    }
    if (r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__tlb_flush) {
        ++g_ven_tlb_flush;
        ++g_ven_tlb_flush_state[state];
    }
    // `tlb_fill_en` is consumed on this next core edge.  Observe its pre-edge
    // DTLB victim as well: this cross-checks launch->fill routing and tells a
    // real full-set collision from a mere empty-slot refill, without an RTL
    // counter or a different Verilator elaboration.
    if (r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__tlb_fill_en) {
        if (!r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__walk_for_d) {
            ++g_ven_tlb_i_fill;
        } else {
            ++g_ven_tlb_d_fill;
            const auto view = ven_tlb_probe(
                r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__walk_lin,
                r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__u_dtlb__DOT__tlb_val,
                r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__u_dtlb__DOT__tlb_vpn,
                r->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__u_dtlb__DOT__tlb_dirty);
            if (view.hit) {
                ++g_ven_tlb_d_fill_same;
            } else if (view.has_invalid) {
                ++g_ven_tlb_d_fill_invalid;
            } else {
                ++g_ven_tlb_d_fill_conflict;
            }
        }
    }
}

static void ven_debug_report_tlb() {
    if (!g_ven_tlb_report_path) return;
    FILE *f = fopen(g_ven_tlb_report_path, "w");
    if (!f) {
        fprintf(stderr, "[VEN-TLB] cannot open report %s\n", g_ven_tlb_report_path);
        return;
    }
    fprintf(f, "[VEN-TLB] cycles=%llu retires=%llu launches=%llu i_nohit=%llu d_nohit=%llu d_rewalk=%llu d_clean_rewalk=%llu flushes=%llu\n",
            (unsigned long long)main_time, (unsigned long long)g_vtm_retires,
            (unsigned long long)g_ven_tlb_launch, (unsigned long long)g_ven_tlb_i_nohit,
            (unsigned long long)g_ven_tlb_d_nohit, (unsigned long long)g_ven_tlb_d_rewalk,
            (unsigned long long)g_ven_tlb_d_clean_rewalk, (unsigned long long)g_ven_tlb_flush);
    fprintf(f, "[VEN-TLB] fills i=%llu d=%llu d_invalid=%llu d_same=%llu d_conflict=%llu\n",
            (unsigned long long)g_ven_tlb_i_fill, (unsigned long long)g_ven_tlb_d_fill,
            (unsigned long long)g_ven_tlb_d_fill_invalid,
            (unsigned long long)g_ven_tlb_d_fill_same,
            (unsigned long long)g_ven_tlb_d_fill_conflict);
    for (unsigned i = 0; i < 128; ++i) {
        if (g_ven_tlb_launch_state[i] || g_ven_tlb_flush_state[i])
            fprintf(f, "[VEN-TLB] state=%u launches=%llu flushes=%llu\n", i,
                    (unsigned long long)g_ven_tlb_launch_state[i],
                    (unsigned long long)g_ven_tlb_flush_state[i]);
    }
    for (unsigned i = 0; i < 16; ++i) {
        if (g_ven_tlb_i_index[i] || g_ven_tlb_d_index[i])
            fprintf(f, "[VEN-TLB] index=%u i_launches=%llu d_launches=%llu\n", i,
                    (unsigned long long)g_ven_tlb_i_index[i],
                    (unsigned long long)g_ven_tlb_d_index[i]);
    }
    struct HotPage { uint32_t vpn = 0; uint64_t count = 0; } hot[16];
    for (uint32_t vpn = 0; vpn < g_ven_tlb_d_pages.size(); ++vpn) {
        const uint64_t count = g_ven_tlb_d_pages[vpn];
        if (count <= hot[15].count) continue;
        unsigned slot = 15;
        while (slot && count > hot[slot - 1].count) {
            hot[slot] = hot[slot - 1];
            --slot;
        }
        hot[slot] = {vpn, count};
    }
    for (const auto& page : hot) {
        if (page.count)
            fprintf(f, "[VEN-TLB] hot-linear-page=%08x d_launches=%llu (all CR3 contexts)\n",
                    page.vpn << 12, (unsigned long long)page.count);
    }
    fclose(f);
}

// ---- save/load state: snapshot the slow POST so debug iterations resume in seconds ----
// Captures harness time + Ventium retire count, the DDR array, the DDR-model read FIFO
// (addr+ready+data — the pop side returns the stored .data) and write-burst state, the
// VGA clock-divider phase/LCG, the Ventium x87 co-sim state (C-side, absent from the RTL),
// and the verilated SoC (top; needs --savable). The PS (ps_shim/x86/ide) disk is
// re-attached by x86_init before restore, so take the snapshot at a QUIESCENT point
// (POST done, no in-flight ide/fdd transaction) or PS-side transfer state would be lost.
static constexpr uint64_t SNAPSHOT_V2_MAGIC = 0x3250414e534e4556ull;
static constexpr uint64_t SNAPSHOT_V3_MAGIC = 0x3350414e534e4556ull;
extern uint8_t ide_buf[32 * 512];
extern void ps_checkpoint_spi(uint32_t words[3], bool restore);
extern bool x86_checkpoint_no_floppy();
static void checkpoint_fail(const char *reason) {
    fprintf(stderr, "SNAPSHOT-ERROR: %s\n", reason);
    std::exit(2);
}
static void checkpoint_config(uint32_t words[9]) {
    words[0] = g_clock_rate; words[1] = g_rtc_rate; words[2] = g_rate_vga;
    words[3] = g_mem_mb; words[4] = g_fpga_ddr; words[5] = g_ddr_lat;
    words[6] = g_vga_div; words[7] = g_vga_jit;
    words[8] = sizeof(ven_checkpoint::AtaState);
}
static void checkpoint_require_supported() {
    if (!x86_checkpoint_no_floppy() || g_kb_script || g_ven_break_enable || g_rmtest)
        checkpoint_fail("versioned snapshots require no floppy, keyboard script, breakpoint or RM test mode");
}
static void save_state(const char *fn) {
    ven_checkpoint::AtaState ata;
    if (g_snapshot_v2) {
        checkpoint_require_supported();
        if (!ven_checkpoint::capture_ata(ide_inst, ide_buf, ata))
            checkpoint_fail("unsupported ATA state or disk flush/position failure");
    }
    VerilatedSave os; os.open(fn);
    if (g_snapshot_v2) {
        const uint64_t magic = g_snapshot_v3 ? SNAPSHOT_V3_MAGIC : SNAPSHOT_V2_MAGIC;
        os.write(&magic, sizeof(magic));
        uint32_t config[9], spi[3]; checkpoint_config(config); ps_checkpoint_spi(spi, false);
        os.write(config, sizeof(config)); os.write(spi, sizeof(spi));
        if (g_snapshot_v3) {
            // ddr_service samples an edge, not a level. The FIFO alone cannot
            // tell whether an asserted DDRAM_RD has already been accepted.
            const uint32_t read_edge = prev_rd ? 1u : 0u;
            os.write(&read_edge, sizeof(read_edge));
        }
        os.write(&ata, sizeof(ata));
    }
    os.write(&main_time, sizeof(main_time));
    os.write(&g_vtm_retires, sizeof(g_vtm_retires));
    os.write(ddr, DDR_WORDS * sizeof(uint64_t));
    uint64_t n = rd_fifo.size(); os.write(&n, sizeof(n));
    for (auto &b : rd_fifo) { os.write(&b.addr, sizeof(b.addr)); os.write(&b.ready, sizeof(b.ready)); os.write(&b.data, sizeof(b.data)); }
    os.write(&wburst, sizeof(wburst)); os.write(&waddr, sizeof(waddr)); os.write(&wrem, sizeof(wrem));
    os.write(&g_vga_phase, sizeof(g_vga_phase)); os.write(&g_vga_lcg, sizeof(g_vga_lcg));
    os << *top;   // Ventium x87 state lives inside the RTL (no linked C-side FPU co-sim)
    os.close();
    fprintf(stderr, ">>> STATE SAVED to %s @cyc=%llu retires=%llu disk_reads_host=%lu\n", fn,
            (unsigned long long)main_time, (unsigned long long)g_vtm_retires, g_disk_reads);
}
static void load_state(const char *fn) {
    VerilatedRestore is; is.open(fn);
    uint64_t first; is.read(&first, sizeof(first));
    const bool v3 = first == SNAPSHOT_V3_MAGIC;
    const bool v2 = first == SNAPSHOT_V2_MAGIC || v3;
    if (v2 != g_snapshot_v2 || v3 != g_snapshot_v3)
        checkpoint_fail("snapshot format mismatch; select the matching --snapshot-v2 or --snapshot-v3");
    ven_checkpoint::AtaState ata;
    uint32_t spi[3]{};
    uint32_t read_edge = 0;
    if (v2) {
        checkpoint_require_supported();
        uint32_t saved[9], expected[9]; checkpoint_config(expected);
        is.read(saved, sizeof(saved));
        if (std::memcmp(saved, expected, sizeof(saved)))
            checkpoint_fail("clock/memory/DDR/VGA settings or ATA payload ABI mismatch");
        is.read(spi, sizeof(spi));
        if (v3) {
            is.read(&read_edge, sizeof(read_edge));
            if (read_edge > 1) checkpoint_fail("invalid DDR read-edge state");
        }
        is.read(&ata, sizeof(ata));
        if (spi[0] > 1 || spi[1] > 9) checkpoint_fail("invalid SPI checkpoint state");
        is.read(&main_time, sizeof(main_time));
    } else main_time = first;
    is.read(&g_vtm_retires, sizeof(g_vtm_retires));
    is.read(ddr, DDR_WORDS * sizeof(uint64_t));
    uint64_t n = 0; is.read(&n, sizeof(n)); rd_fifo.clear();
    for (uint64_t i = 0; i < n; i++) { RdBeat b; is.read(&b.addr, sizeof(b.addr)); is.read(&b.ready, sizeof(b.ready)); is.read(&b.data, sizeof(b.data)); rd_fifo.push_back(b); }
    is.read(&wburst, sizeof(wburst)); is.read(&waddr, sizeof(waddr)); is.read(&wrem, sizeof(wrem));
    is.read(&g_vga_phase, sizeof(g_vga_phase)); is.read(&g_vga_lcg, sizeof(g_vga_lcg));
    is >> *top;   // Ventium x87 state lives inside the RTL (no linked C-side FPU co-sim)
    is.close();
    if (v2) {
        if (!ven_checkpoint::restore_ata(ide_inst, ide_buf, ata))
            checkpoint_fail("ATA restore failed: incompatible disk mounts or seek failure");
        ps_checkpoint_spi(spi, true);
    }
    if (v3) prev_rd = read_edge != 0;
    else fprintf(stderr, "SNAPSHOT-WARNING: legacy snapshot omits DDR read-edge state; arbitrary replay is not validated\n");
    fprintf(stderr, ">>> STATE LOADED from %s @cyc=%llu retires=%llu\n", fn,
            (unsigned long long)main_time, (unsigned long long)g_vtm_retires);
}

// `--save-every` is expressed on the absolute simulation timeline.  A restore
// may jump main_time far beyond the threshold installed while parsing argv;
// move it to the next *future* period so the periodic-save block cannot write
// a full snapshot on every following tick while it catches up.
static void reschedule_periodic_save_after_restore() {
    if (!g_save_every) return;
    const uint64_t rem = main_time % g_save_every;
    const uint64_t delta = rem ? (g_save_every - rem) : g_save_every;
    g_next_save = main_time + delta;
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
    memset(top->cpu_dbg_cmp, 0, sizeof(top->cpu_dbg_cmp));
}

// x86_init() seeds CMOS for its default 16 MiB configuration.  The DDR model's
// `--mem` aperture alone is not visible to DOS, HIMEM, or CWSDPMI, so a larger
// physical model without this update can make a guest needlessly swap.  This is
// the same generic CMOS contract used by the legacy ao486 harness: conventional
// extended-memory fields cover up to the AH=88h limit and 0x34/0x35 describe
// memory above 16 MiB for E801/E820 consumers.  Recompute the standard checksum
// after all fields change.
static void cmos_set_mem_mb(int mb) {
    auto wr = [&](int a, int d) {
        top->mgmt_address = 0xF400 | a;
        top->mgmt_writedata = d & 0xFF;
        top->mgmt_write = 1;
        tick();
        top->mgmt_write = 0;
    };
    auto rd = [&](int a) -> int {
        top->mgmt_address = 0xF400 | a;
        top->mgmt_read = 1;
        tick();
        int v = top->mgmt_readdata & 0xFF;
        top->mgmt_read = 0;
        return v;
    };

    // KB above 1 MiB.  AH=88h exposes a 16-bit field and therefore caps at
    // 0xFFC0 KiB; E801/E820 use the separate field below for the remainder.
    int ext = (mb - 1) * 1024;
    if (ext > 0xFFC0) ext = 0xFFC0;
    wr(0x17, ext & 0xFF); wr(0x18, (ext >> 8) & 0xFF);
    wr(0x30, ext & 0xFF); wr(0x31, (ext >> 8) & 0xFF);

    // 64 KiB units above 16 MiB, used by E801/E820.
    int ext16 = (mb > 16) ? (mb - 16) * 16 : 0;
    wr(0x34, ext16 & 0xFF); wr(0x35, (ext16 >> 8) & 0xFF);

    int sum = 0;
    for (int i = 0x10; i <= 0x2D; i++) sum += rd(i);
    wr(0x2E, (sum >> 8) & 0xFF); wr(0x2F, sum & 0xFF);
    fprintf(stderr, ">>> CMOS RAM set to %d MB (ext=0x%04x, checksum=0x%04x)\n",
            mb, ext, sum & 0xFFFF);
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
        else if (!strcmp(argv[i], "--rate-rtc")) {
            if (i+1 == argc || !ven_parse_rtc_rate(argv[++i], g_rtc_rate)) {
                fprintf(stderr, "--rate-rtc requires decimal Hz in [8192, 268427264]\n");
                return 2;
            }
        }
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
        else if (!strcmp(argv[i], "--mem") && i+1<argc) {
            g_mem_mb = atoi(argv[++i]);
            g_mem_top_words = (uint64_t)g_mem_mb * 0x20000ull;
        }
        else if (!strcmp(argv[i], "--ide") && i+1<argc) ide_path = argv[++i];
        else if (!strcmp(argv[i], "--ven-break-eip") && i+1<argc) {
            g_ven_break_enable = true; g_ven_break_eip = strtoul(argv[++i], 0, 0);
        }
        else if (!strcmp(argv[i], "--ven-break-retire") && i+1<argc) {
            g_ven_break_retire = strtoull(argv[++i], 0, 0);
        }
        else if (!strcmp(argv[i], "--ven-break-report") && i+1<argc) {
            g_ven_break_report_path = argv[++i];
        }
        else if (!strcmp(argv[i], "--ven-tlb-report") && i+1<argc) {
            g_ven_tlb_report_path = argv[++i];
        }
        else if (!strcmp(argv[i], "--ven-perf-every") && i+1<argc) {
            g_ven_perf_every = strtoull(argv[++i], 0, 0);
        }
        else if (!strcmp(argv[i], "--ven-state-start") && i+1<argc) {
            g_state_trace_start = strtoull(argv[++i], 0, 0);
        }
        else if (!strcmp(argv[i], "--ven-delta-out") && i+1<argc) g_delta_path = argv[++i];
        else if (!strcmp(argv[i], "--ven-delta-start") && i+1<argc) g_delta_start = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--ven-delta-cycles") && i+1<argc) g_delta_cycles = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--ven-state-cycles") && i+1<argc) {
            g_state_trace_cycles = strtoull(argv[++i], 0, 0);
            if (g_state_trace_cycles > 1000000) {
                fprintf(stderr, "--ven-state-cycles must be <= 1000000\n");
                return 2;
            }
        }
        else if (!strcmp(argv[i], "--ven-break-linear") && i+1<argc) {
            g_ven_break_mem_enable = true; g_ven_break_linear = strtoul(argv[++i], 0, 0);
        }
        else if (!strcmp(argv[i], "--ven-watch-walk-eip") && i+1<argc) {
            g_ven_watch_walk_enable = true; g_ven_watch_walk_eip = strtoul(argv[++i], 0, 0);
        }
        else if (!strcmp(argv[i], "--ven-l2-watch")) g_ven_l2_watch_enable = true;
        else if (!strcmp(argv[i], "--ven-l2-watch-start") && i+1<argc) {
            g_ven_l2_watch_enable = true; g_ven_l2_watch_start = strtoull(argv[++i], 0, 0);
        }
        // Emit a bounded retire trace.  --vtm-dump-start is an absolute
        // post-reset retire number, so a narrow window can be captured without
        // emitting the entire cold boot before it.
        else if (!strcmp(argv[i], "--vtm-dump") && i+1<argc) g_vtm_dump = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--vtm-dump-start") && i+1<argc) g_vtm_dump_start = strtoull(argv[++i], 0, 0);
        // clk_vga divider: clk_vga toggles every g_vga_div ticks. The 0x3DA vertical-
        // retrace flag lives in the clk_vga domain; if it races the clk_sys host-bus read
        // the CPU never samples the toggle and the VGA-BIOS retrace poll (boot1.rom
        // 0xC066d) spins forever. Tunable so the Ventium io cadence can be de-aliased.
        else if (!strcmp(argv[i], "--vga-div") && i+1<argc) g_vga_div = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--vga-jit") && i+1<argc) g_vga_jit = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--save-at") && i+1<argc) g_save_at = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--save-every") && i+1<argc) { g_save_every = strtoull(argv[++i], 0, 0); g_next_save = g_save_every; }
        else if (!strcmp(argv[i], "--save-file") && i+1<argc) g_save_file = argv[++i];
        else if (!strcmp(argv[i], "--snapshot-v2")) g_snapshot_v2 = true;
        else if (!strcmp(argv[i], "--snapshot-v3")) { g_snapshot_v2 = true; g_snapshot_v3 = true; }
        else if (!strcmp(argv[i], "--save-stop")) g_save_stop = true;
        else if (!strcmp(argv[i], "--restore") && i+1<argc) g_restore_file = argv[++i];
        else if (!strcmp(argv[i], "--ide-verbose")) g_ide_verbose = true;
        else if (!strcmp(argv[i], "--open-trace")) g_open_trace = 1;
        else if (!strcmp(argv[i], "--rmtest")) g_rmtest = 1;
        else if (!strcmp(argv[i], "--kb") && i+1<argc) g_kb_script = argv[++i];
        else if (!strcmp(argv[i], "--kb-start") && i+1<argc) g_kb_start = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--kb-gap") && i+1<argc) g_kb_gap = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--vgatext-every") && i+1<argc) g_vgatext_every = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--fb-every") && i+1<argc) g_fb_every = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--fb-out") && i+1<argc) g_fb_out = argv[++i];
    }
    fprintf(stderr, ">>> sim_ven: vga_div=%d vga_jit=%d clock_rate=%u\n", g_vga_div, g_vga_jit, g_clock_rate);
    fprintf(stderr, ">>> timebase: pit_rate=%u rtc_rate=%u vga_rate=%u\n",
            g_clock_rate, g_rtc_rate, g_rate_vga);
    if (g_rtc_rate != g_clock_rate)
        fprintf(stderr, "[warn] RTC timebase differs from core/PIT by %.6gx; "
                "this is not a hardware-equivalent timing profile. "
                "For a NEW cold run use --rate-rtc equal to --rate. "
                "Native restores must retain their saved configuration.\n",
                double(g_clock_rate) / g_rtc_rate);
    if (g_save_stop && (!g_save_at || g_save_every))
        checkpoint_fail("--save-stop requires --save-at and excludes --save-every");
    if (g_kb_script) kb_build_events(g_kb_script);

    top = new Vsystem;
    if (g_delta_path) {
#ifndef VEN_HAVE_STATE_DELTA
        checkpoint_fail("state-delta requires generated observer; see docs/STATE_DELTA.md");
#endif
        if (!g_delta_cycles || g_delta_cycles > 1000000)
            checkpoint_fail("state-delta cycle count must be 1..1000000");
    }
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
    if (g_mem_mb > 0) cmos_set_mem_mb(g_mem_mb);
    top->reset = 0;
    // Resume a prior POST snapshot: x86_init has re-attached the disk; load_state now
    // overwrites DDR + RTL + FIFO + FPU + time with the snapshot (must be QUIESCENT).
    if (g_restore_file) {
        load_state(g_restore_file);
        reschedule_periodic_save_after_restore();
        // Optional, const snapshot-memory observation; never arms a hardware
        // breakpoint, changes guest state, or evaluates the DUT an extra time.
        if (const char* text = std::getenv("VEN_PROFILE_CODE_EIP")) {
            char* end=nullptr;
            errno=0;
            const unsigned long long offset=std::strtoull(text,&end,0);
            if (errno || !*text || *text=='-' || *end || offset>UINT32_MAX)
                checkpoint_fail("invalid VEN_PROFILE_CODE_EIP");
            const auto& root=*top->rootp;
#define CODE_REG(name) root.system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__##name
            if (!CODE_REG(a20_r)) checkpoint_fail("code observation requires A20 enabled");
            std::fprintf(stderr,"[CODE-CONTEXT] cs=%04x base=%08x limit=%08x cr0=%08x cr3=%08x cr4=%08x\n",
                unsigned(CODE_REG(seg_sel)[0]),unsigned(CODE_REG(seg_base)[0]),
                unsigned(CODE_REG(seg_limit)[0]),unsigned(CODE_REG(creg0)),
                unsigned(CODE_REG(creg3)),unsigned(CODE_REG(creg4)));
            ven_profile_code::dump(stderr,ddr_bytes(),DDR_WORDS*sizeof(*ddr),
                CODE_REG(seg_base)[0],CODE_REG(seg_limit)[0],CODE_REG(creg0),
                CODE_REG(creg3),CODE_REG(creg4),uint32_t(offset));
#undef CODE_REG
        }
    }
    fprintf(stderr, ">>> ventium-soc: reset released; running up to %llu cycles\n",
            (unsigned long long)cycles);

    uint64_t last_report = 0;
    g_delta_armed = g_delta_path != nullptr;
    while (main_time < cycles && !Verilated::gotFinish()) {
        if (g_ven_break_enable && !g_ven_break_armed &&
            g_vtm_retires >= g_ven_break_retire) {
            g_ven_break_armed = true;
            ven_debug_drive();
            fprintf(stderr, ">>> VEN breakpoint armed: eip=%08x after retire=%llu\n",
                    g_ven_break_eip, (unsigned long long)g_vtm_retires);
        }
        ven_debug_watch_tlb();
        tick();
        ven_debug_watch_walk();
        ven_debug_watch_l2();
        if (g_ven_break_armed && !g_ven_break_seen &&
            ((top->cpu_dbg_bus[8] >> 2) & 1u)) {
            g_ven_break_seen = true;
            ven_debug_report_break();
            break;
        }
        if (g_rmtest) {
            auto *R = top->rootp;
            if (R->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__rm_read_armed
                && R->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__mem_ack) {
                fprintf(stderr,
                        "[RMREAD] cyc=%llu state=%u step=%u addr=%08x data=%08x cs:eip=%04x:%08x\n",
                        (unsigned long long)main_time,
                        (unsigned)R->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__state,
                        (unsigned)R->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__int_step,
                        R->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__bd_addr,
                        R->system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__mem_rdata,
                        g_vtm_cs, g_vtm_eip);
            }
        }
        // Serve disk/floppy mgmt requests exactly like the ao486 sim.
        if (top->ide0_request || top->ide1_request || top->fdd_request) x86_poll(0);
        // IDE RESET-FINISH: the FPGA daemon calls ide_io(0,0) UNCONDITIONALLY every iteration
        // (board_shim.cpp:553) — ide_io(num,0) transitions the IDE from RESET->IDLE (status=RDY).
        // The request-gated x86_poll path above can MISS this (a reset that raises no mgmt request
        // leaves the IDE stuck in RESET -> BIOS never detects the drive -> INT19 boot fails -> HALT).
        // ide_io(n,0) is a no-op unless state==RESET, so calling it every tick is safe.
        { extern void ide_io(int, int); ide_io(0, 0); ide_io(1, 0); }
        ps2_kb_drive();   // inject queued keystrokes (no-op unless --kb given)
        if (g_vgatext_every && main_time >= g_vgatext_next) {
            g_vgatext_next = main_time + g_vgatext_every;
            vgatext_dump();
        }
        if (g_fb_every && main_time >= g_fb_next) {
            g_fb_next = main_time + g_fb_every;
            if (in_graphics_mode()) dump_fb_frame(g_fb_n++);
        }
        if (g_rmtest && !(main_time % 10000)) {
            const uint16_t sw_return = guest_word(0x504);
            const uint16_t pop_return = guest_word(0x50c);
            const uint16_t bad = guest_word(0x508);
            const uint16_t pop_bad = guest_word(0x50e);
            const uint16_t main_bad = guest_word(0x514);
            if ((sw_return == 256 && pop_return == 256) || bad || pop_bad || main_bad) {
                rmtest_dump();
                break;
            }
        }
        // OPEN-FAILURE TRACE: the failed COMMAND.COM open is at reads=71. Enable the per-retire
        // register trace (vtm_retire -> stderr) once reads>=66 so the IO.SYS dir-search/open decision
        // is captured with full register/flag state. Auto-off after a bounded window so the log stays
        // finite (the open + a few idle cycles is enough).
        static int trace_armed = 0;
        if (g_open_trace && g_disk_reads >= 66 && !trace_armed) {
            trace_armed = 1;
            g_vtm_dump_start = g_vtm_retires;
            g_vtm_dump = 700000;   // vtm_retire decrements this once per retire -> a BOUNDED, contiguous
                                   // 700k-retire trace covering reads 66->71 (the open) + the error path.
            fprintf(stderr, ">>> TRACE ON at reads=%lu retires=%llu cs=%04x:eip=%08x\n",
                    g_disk_reads, (unsigned long long)g_vtm_retires, g_vtm_cs, g_vtm_eip);
        }
        // OPEN-FAILURE MEMORY DUMP (one-shot, reads>=70): scan guest RAM for the "COMMAND COM" root-dir
        // entry (is IO.SYS's in-memory dir intact?) and for the target FCB name IO.SYS parsed (is the
        // path-parse correct?). Distinguishes a corrupt dir buffer / mis-parsed name from a compare bug.
        static int memdump_done = 0;
        if (g_open_trace && !memdump_done && g_disk_reads >= 70 && ddr) {
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
        if (g_save_at && main_time >= g_save_at) {
            save_state(g_save_file); g_save_at = 0;
            // Stop before any more guest clocks or disk writes. The caller can
            // now copy/hash the flushed disk into the immutable snapshot bundle.
            if (g_save_stop) break;
        }
        // Periodic cycle-stamped snapshots (--save-every) — captures POST progress even
        // when the exact completion cycle is unknown; resume from the furthest post-POST one.
        if (g_save_every && main_time >= g_next_save) {
            char fn[300]; snprintf(fn, sizeof fn, "%s.%llu", g_save_file, (unsigned long long)main_time);
            save_state(fn); g_next_save += g_save_every;
        }
        // Periodic progress: the Ventium retire trace (eip/cs from vtm_retire).
        if (g_ven_perf_every && main_time - g_ven_perf_last >= g_ven_perf_every) {
            g_ven_perf_last = main_time;
            g_slow_decode_profile.report(stderr, main_time);
            if (!ven_perf_sample(stderr, *top->rootp, main_time, g_vtm_retires, 0)) {
                fprintf(stderr, "[VEN-PERF] unavailable: build with +define+VEN_PERF_PROFILE\n");
                g_ven_perf_every = 0;
            }
        }
        if (main_time - last_report >= 500000) {
            last_report = main_time;
            fprintf(stderr, "[%10llu] retires=%llu cs=%04x:eip=%08x cr0=%08x cr3=%08x eflags=%08x\n",
                    (unsigned long long)main_time, (unsigned long long)g_vtm_retires,
                    g_vtm_cs, g_vtm_eip, g_vtm_cr0, g_vtm_cr3, g_vtm_eflags);
        }
    }
    fprintf(stderr, ">>> done: cyc=%llu retires=%llu last cs=%04x:eip=%08x\n",
            (unsigned long long)main_time, (unsigned long long)g_vtm_retires, g_vtm_cs, g_vtm_eip);
    ven_debug_report_tlb();
    if (g_ven_perf_every && main_time != g_ven_perf_last) {
        ven_perf_sample(stderr, *top->rootp, main_time, g_vtm_retires, 0);
        g_slow_decode_profile.report(stderr, main_time);
    }
    if (g_rmtest) rmtest_dump();
#ifdef VEN_HAVE_STATE_DELTA
    if (g_delta_armed && !g_state_delta.complete()) checkpoint_fail("incomplete state-delta capture");
#endif
    top->final(); delete top; free(ddr);
    return 0;
}
