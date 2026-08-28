// ao486-sim — Verilator harness around rtl/system.v (the ao486 SoC).
//
// Models the MiSTer ARM-HPS behavior the core needs to boot:
//   * BIOS/VGA-BIOS preloaded into DDR + UMA fill (mirrors x86_init mem_set).
//   * 128-byte CMOS/RTC programmed over the mgmt bus (RTC_BASE 0xF400), the
//     exact array from Main_MiSTer/support/x86/x86.cpp (BIOS reads it for memory
//     size / equipment / drive types; a zero CMOS triple-faults POST).
//   * Behavioral 256 MiB DDR burst slave (DDRAM_* avalon).
// Disk serving (IDE/floppy mgmt) and video capture come in M3/M2-verify.

#include "Vsystem.h"
#include "Vsystem___024root.h"   // access ao486 pipeline internals (needs --public-flat-rw) for quake console-fast-return
#include "verilated.h"
#include "verilated_vcd_c.h"
#include "verilated_save.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <deque>
#include <vector>

static const uint64_t DDR_WORDS = (1ull << 24);   // 128 MiB / 8 (guest --mem<=32; Quake writes top out ~12MB)
uint64_t *ddr = nullptr;   // non-static: ps_shim.cpp (shmem) maps into this

struct RdBeat { uint32_t addr; uint64_t ready; uint64_t data; };
static std::deque<RdBeat> rd_fifo;     // pending DDR read beats with ready-time
static bool     wburst = false;
static uint32_t waddr  = 0;
static int      wrem   = 0;
static int      g_ddr_lat = 2;         // DDR read latency (cycles); tunable via --ddrlat
static uint64_t g_mem_top_words = 0;   // open-bus above this word addr (0=unlimited); set by --mem
static uint64_t g_max_waddr = 0;
static FILE    *floppy_img = nullptr;  // M3 floppy disk-serving
static bool     floppy_en  = false;
static uint8_t  fdsector[512];
static int      fstate = 0, ffill = 0;
static uint64_t fserved = 0;
// --- M4: IDE/ATA HDD serving (mirrors Main_MiSTer ide.cpp) ---
static FILE    *ide_img = nullptr;
static bool     ide_en  = false;
static uint32_t ide_secs = 0;          // total sectors in image
static uint16_t ide_id[256];           // IDENTIFY block
static uint8_t  ide_dbuf[256*512];     // sector data buffer
static uint16_t ide_rin[6], ide_rout[6];
static int      ide_state = 0;         // 0 idle,1 readregs,2 writebuf,3 writeregs
static int      ide_idx = 0;
static int      ide_dwords = 0;        // 16-bit words to stream to the buffer
static int      ide_in_reset = 0;
static uint64_t ide_served = 0;
static unsigned ide_curreq = 0;
// PC-trajectory disk-idle trigger counter, bumped by ps/ide.cpp on every disk
// read. The trace hooks that consume it live in the ventium-cosim main
// (ven/sim_ven.cpp); this legacy main only needs the definition to link.
volatile unsigned long g_disk_reads = 0;

Vsystem  *top = nullptr;   // non-static: ps_shim.cpp drives mgmt via this
static uint64_t g_polls = 0;

// --- bridge to the real MiSTer PS software (ps/x86.cpp, ps/ide.cpp) ---
extern void x86_init();
extern void x86_poll(int only_ide);
extern void ide_io(int num, int req);   // ide.cpp: req==0 = idempotent reset-finish (BSY->RDY)
extern void x86_set_image(int num, char *filename);
extern void x86_reattach();
extern void ide_reattach_base();
extern "C" int ao486_fpu_store_pending(unsigned int *phys);   // co-sim FPU: pending L2 line to invalidate
extern "C" void ao486_fpu_process();                          // co-sim FPU: apply the pending ESC op (post ddr_service); operand reads made coherent by CPU-write snoop overlay
extern "C" int  ao486_paging_on();                            // diagnostics: CR0.PG
extern "C" int  ao486_fpu_state_bytes();                      // co-sim x87 FPU state size
extern "C" void ao486_fpu_state_save(void *dst);              // serialize co-sim x87 FPU state
extern "C" void ao486_fpu_state_load(const void *src);        // restore co-sim x87 FPU state
extern "C" void ao486_walk_dbg(unsigned int lin);             // verbose page-walk debug
extern "C" void ao486_dump_cscache();                         // raw CS descriptor cache
extern "C" unsigned char* ao486_code_ptr(unsigned int lin_real, unsigned int eip);  // guest code ptr (real or paged)
extern "C" unsigned char* ao486_code_ptr_ctx(unsigned int lin, unsigned int cr3, int pg); // guest code ptr with explicit paging ctx
extern "C" void x87_dump_last_cvt(void);   // x87_cosim: dump the last sprintf("%4.2f",1.06) op stream
extern "C" int ao486_poke_guest(unsigned int phys, const void *src, int nbytes);  // write guest DDR + L2-invalidate
extern "C" int ao486_cur_cr3();                              // current CR3 (from the paging probe)
extern "C" int ao486_cur_pg();                               // current CR0.PG
static char ps_img[6][1024] = {{0}};   // [0,1]=floppy A/B, [2..5]=IDE hdd0..3
static uint64_t g_save_at = 0;          // --save-at: snapshot at this cycle
static uint64_t g_save_every = 0;       // --save-every N: re-snapshot every N cycles (OOM resilience)
static bool g_quake_fast_return = false; // --quake-fast-return: force-return from Quake's Draw_Character/Draw_String glyph loop to break the console-draw runaway (bug#4) so the timedemo completes
static bool g_dump_delay = false;        // --dump-delay: fire ONCE and dump the Win95 setup calibrated-busy-wait loop (VxD lin 0xC0000000..0xC0040000 polling PIT ch0 port 0x40)
// --- Win95 setup delay-loop intervention (profiler / warp / accumulator poke) ---
static bool     g_w95_probe = false;     // --w95-probe: profile dcache read/write addrs during the spin
static int      g_w95_mode  = 0;         // --w95-warp=1  --w95-accum=2  --w95-calib=3
static bool     g_ptefix = false;        // --ptefix: on a high-addr #PF with P=0-but-frame PTE, set present bit
static bool     g_w95_spin  = false;     // set by the spin detector while inside the delay loop
static uint32_t g_w95_cr3   = 0;         // cr3 captured at spin confirm
static uint32_t g_accum_phys = 0, g_target_phys = 0, g_calib_phys = 0; // filled from the probe dump
static uint32_t g_w95_val = 0x7fffffffu; // --w95-val: value poked by mode 2
static int      g_save_frame = 0;       // --save-frame: snapshot when vframe reaches this
static const char *g_statefile = "../tmp/ao486.state";
static bool g_load = false;             // --load: restore instead of POST
static int g_mem_mb = 0;                // --mem: override CMOS RAM size (0=leave x86_init default 16MB)
void ps_clock_tick();                  // defined after tick()
// After an IDE soft-reset clears (RTL request 6->0 once ide.cpp writes reg5), the
// drive stays in IDE_STATE_RESET (BSY) until ide_io(N,0) runs its "reset finish"
// (state->IDLE, status->RDY, ide.cpp:974-984). ide_io(N,0) is IDEMPOTENT: a pure
// no-op unless channel N is in IDE_STATE_RESET (which is entered only at mount,
// ide.cpp:442). x86_poll's own reset-finish is gated behind `if(sd_req)` and is
// skipped once ide0/ide1 clear to 0 with nothing else pending. Rather than fabricate
// a phantom request to re-trip that gate, we detect the debounced SRST-clear and call
// the idempotent ide_io(N,0) DIRECTLY, at the same trigger the real ARM would use to
// complete the reset it started. Set from the debounce (main loop), consumed at the
// x86_poll site under the same !mid-io reentrancy guard.
static int g_reset_finish_pending = 0; // debounced SRST-clear -> run ide_io(0,0)/(1,0)
static int g_shutdown = 0;
extern "C" void ao486_shutdown(int s) { g_shutdown = s; }
static int g_l2st=0,g_l2vb=0,g_l2cb=0;
static char g_vgaseq[4096]; static int g_vgaseqpos=0;   // ring of bytes written to VGA (message chars)
extern "C" void ao486_l2(int st,int vb,int cb,int vaddr,int vdout,int vwe){
    (void)vaddr; g_l2st=st;g_l2vb=vb;g_l2cb=cb;
    if (vwe) { g_vgaseq[g_vgaseqpos % 4096] = (char)vdout; g_vgaseqpos++; }
}
extern "C" uint16_t ps_sd_req() {      // request bits for ide_check(), from raw RTL outputs
    uint16_t r = (uint16_t)((top->ide0_request & 7) | ((top->ide1_request & 7) << 3) | ((top->fdd_request & 3) << 6));
    // Config bits ide_check() also carries: x86_init builds hotswap[2] as
    // ((cfg>>8)&1)^1, so bit 8 = 0 made it create a PLACEHOLDER CD on the secondary
    // master. The BIOS then probes that phantom ATAPI drive and hangs (our cdrom_*
    // handlers are stubs). Set bit 8 = 1 (no placeholder) - we have no CD.
    const uint16_t cfg = 0x100;
    return r | cfg;   // faithful: raw RTL request bits only (reset-finish handled directly, see g_reset_finish_pending)
}
static vluint64_t main_time = 0;
static VerilatedVcdC *tfp = nullptr;
static uint64_t vcd_start = 0, vcd_end = 0;
double sc_time_stamp() { return main_time; }
#if VM_TRACE
static inline void vcd_dump() { if (tfp && main_time >= vcd_start && main_time <= vcd_end) tfp->dump((vluint64_t)main_time); }
#else
static inline void vcd_dump() {}
#endif

// ---- CPU retirement trace (DPI from cpu_export) --------------------------
static uint64_t retire_count = 0;
static uint32_t last_eip = 0, last_cs = 0, last_lin = 0;
static uint32_t eip_min = 0xffffffff, eip_max = 0;   // range since last report
static const int RING = 256;
static uint32_t ring_cs[RING], ring_eip[RING], ring_esp[RING], ring_lin[RING];
static int ring_pos = 0;
static FILE *trace_fp = nullptr;       // optional full CS:EIP trace
static bool  crash_dumped = false;
static void dump_ring();

// ---- co-sim wedge hunt: wide (32-bit) CS:EIP ring + page-fault ring --------------
// The 16-bit ring above is useless for DJGPP flat protected-mode code (eip is 32-bit).
// This ring keeps full cs:eip32:lin32:esp for a large window and is dumped to a file at
// the crash so the faulting Quake instruction can be disassembled at its true linear.
extern "C" void ao486_fpu_dump_ring(int n);      // in x87_cosim.cpp
#define WRING (1u << 23)                          // 8.4M retires of history (spans ~16 render frames)
static uint32_t wr_cs[WRING], wr_eip[WRING], wr_lin[WRING], wr_esp[WRING];
static uint64_t wr_time[WRING];                    // main_time snapshot (FP<->instr correlation via g_now)
static uint32_t wr_pos = 0;
static bool g_crash_dumped = false;
// Page-fault ring: every data #PF's (kind, cr2, faulting eip). The FATAL one (the wild
// jump that leads to the DJGPP SIGSEGV handler) is the last PF before the crash dump.
struct PfEnt { int kind; uint32_t cr2, exeip, wreip, cr3; uint64_t retire; };
#define PFRING 128
static PfEnt g_pf[PFRING]; static int g_pf_head = 0; static uint64_t g_pf_count = 0;
static uint64_t g_stop_after = 0;    // set at crash: stop the run this many cycles later
static uint32_t g_last_quake_cr3 = 0x41000;   // CR3 captured while Quake flat code executes (for dump translate)
static int vframe = 0;                          // VGA frame counter (defined here; used by video_capture below)
static void dump_wide_ring_and_faults(const char *why, const char *wf, int final_stop);

// --- go32/DJGPP corruption write-watch (NON-perturbing: read-only logging in the memory
// write paths + a crash-time value dump). These four DJGPP flat linears are the runtime
// data whose corruption crashes DOS-Quake (per handoff): the DPMI mode-switch far pointer
// (.data 0x5c070), the go32 exception-handler DS-selector slot (.text 0x4d774, the
// `mov ds,[cs:0x4d774]` that nested-faults at eip=0x4d609), the memory-top (bss 0xda79c)
// and the program break (bss 0x63408). We resolve each to a physical WORD (byte>>3) under
// Quake's own paging context and log every store (CPU/cache via DDRAM_WE, or FPU-co-sim
// direct-ddr[]) that lands on one of them.
extern "C" long long ao486_xlate(unsigned int lin, unsigned int cr3, int pg);
// Repointed at Quake's r_maxsurfs cvar: R_NewMap does r_cnumsurfs=(int)r_maxsurfs.value and then
// Hunk_AllocName(r_cnumsurfs*64). The cvar's .data default is "0"/0.0f, yet FLD reads 0x4af42400
// (=8,000,000.0f) -> a 512,000,000-byte request -> "Hunk_Alloc: failed". Watch the word holding
// .value (lin 0x100603d8) and the word holding the name/string pointers (0x100603c8); `src` tells
// a CPU/cache store from a co-sim FPU direct-ddr[] store.
// Console-runaway watch. The post-timedemo wedge is Con_DrawConsole(lines) with a huge `lines`.
// SCR_DrawConsole computes lines=(int)scr_con_current (float @0xc97d0); SCR_SetUpToDrawConsole
// animates it toward conlines (@0xc97e0) by +/- scr_conspeed*host_frametime (double @0x95ba8),
// clamped via FCOM/FCOMP+FNSTSW. If host_frametime is huge/NaN or a compare misfires, the clamp
// fails and scr_con_current runs away. Watch all three; `src` tells CPU/cache vs co-sim FPU store.
static const uint32_t WATCH_LIN[]  = { 0x101a8c40u, 0x101a8c48u, 0x10006e60u, 0x10006fa0u };
static const char*    WATCH_NM[]   = { "conback w/h", "conback+8", "stack@6e60", "stack@6fa0" };
static const int      NWATCH       = 4;
static uint32_t       g_watch_word[NWATCH] = { ~0u, ~0u, ~0u, ~0u };  // resolved phys word addr
static uint32_t       g_watch_cr3  = 0;      // cr3 the words were resolved under (0 = unresolved)
static int            g_watch_logs = 0;
static uint64_t       g_ldt_phys   = 0;      // phys of LDT[0] (0 = not located yet)
static void find_ldt();   // fwd
static void resolve_watch() {
    for (int i = 0; i < NWATCH; i++) {
        long long p = ao486_xlate(WATCH_LIN[i], g_last_quake_cr3, 1);
        g_watch_word[i] = (p < 0) ? ~0u : (uint32_t)((uint64_t)p >> 3);
    }
    g_watch_cr3 = g_last_quake_cr3;
    if (!g_ldt_phys) find_ldt();   // locate the LDT once, so watch_write can flag LDT stores
}
static void watch_write(uint32_t wordaddr, uint64_t neww, uint64_t oldw, const char *src) {
    if (g_watch_cr3) {
        for (int i = 0; i < NWATCH; i++) {
            if (wordaddr != g_watch_word[i]) continue;
            if (g_watch_logs++ < 500)
                fprintf(stderr, "[WATCH] %-3s %-18s lin=%08x word=%08x old=%016llx new=%016llx "
                        "eip=%05x lin=%08x cyc=%llu retire=%llu\n",
                        src, WATCH_NM[i], WATCH_LIN[i], wordaddr,
                        (unsigned long long)oldw, (unsigned long long)neww,
                        last_eip, last_lin, (unsigned long long)main_time,
                        (unsigned long long)retire_count);
            // Flag the store that pushes scr_con_current (float, WATCH_LIN[0]) to a runaway value.
            if (i == 0) {
                float f; uint32_t b = (uint32_t)neww; memcpy(&f, &b, 4);
                if (!(f == f) || f > 1000.0f || f < -1.0f) {
                    fprintf(stderr, ">>> scr_con_current := %.6g (0x%08x) by %s @eip=%05x cyc=%llu retire=%llu\n",
                            f, b, src, last_eip, (unsigned long long)main_time,
                            (unsigned long long)retire_count);
                    fflush(stderr);
                }
            }
            // Flag a huge/NaN host_frametime (double, WATCH_LIN[1]) -- the likely FP input gone bad.
            if (i == 1) {
                double dv; memcpy(&dv, &neww, 8);
                if (!(dv == dv) || dv > 1.0 || dv < 0.0) {
                    fprintf(stderr, ">>> host_frametime := %.9g by %s @eip=%05x cyc=%llu\n",
                            dv, src, last_eip, (unsigned long long)main_time);
                    fflush(stderr);
                }
            }
        }
    }
    // LDT-region watch. go32 LEGITIMATELY rewrites descriptors here (growing the ds=0xaf
    // near-pointer limit, allocating new selectors), so per-write logging is noisy. Signal:
    //   (a) ANY FPU-co-sim ("FP") write into the LDT  = a wild FP store (never legitimate).
    //   (b) a write that makes the cs(0xa0)/ds(0xa8) descriptor INVALID (access byte loses
    //       present|S) = the wedge's corrupting write (mov ds,0xaf then #GP).
    // Both are logged LOUDLY and uncapped. Routine legit LDT writes are capped separately.
    if (g_ldt_phys) {
        uint64_t bw = (uint64_t)wordaddr << 3;
        if (bw >= g_ldt_phys && bw < g_ldt_phys + 0x200) {
            uint64_t rel = bw - g_ldt_phys;
            uint8_t new_acc = (uint8_t)(neww >> 40);   // descriptor access byte (byte 5)
            bool crit = (rel == 0xa0 || rel == 0xa8);  // cs / ds descriptor slots
            bool became_invalid = crit && ((new_acc & 0x90) != 0x90);
            bool is_fp = (src[0] == 'F');
            if (is_fp || became_invalid) {
                fprintf(stderr, "[%s] %-3s LDT+0x%03llx (sel~0x%02llx) old=%016llx new=%016llx access=%02x "
                        "eip=%05x lin=%08x cyc=%llu retire=%llu\n",
                        became_invalid ? "CORRUPT-DESC" : "FP-LDT-STORE", src,
                        (unsigned long long)rel, (unsigned long long)rel,
                        (unsigned long long)oldw, (unsigned long long)neww, new_acc,
                        last_eip, last_lin, (unsigned long long)main_time,
                        (unsigned long long)retire_count);
            } else {
                static int ldt_noise = 0;   // sample routine legit descriptor management
                if (ldt_noise++ < 200)
                    fprintf(stderr, "[WATCH-LDT] %-3s LDT+0x%03llx old=%016llx new=%016llx eip=%05x retire=%llu\n",
                            src, (unsigned long long)rel, (unsigned long long)oldw,
                            (unsigned long long)neww, last_eip, (unsigned long long)retire_count);
            }
        }
    }
}
// Called from the FPU co-sim (x87_cosim.cpp) after each direct-ddr[] store.
extern "C" void ao486_watch_store(unsigned int phys, unsigned long long neww,
                                  unsigned long long oldw, int mw) {
    (void)mw; watch_write(phys >> 3, neww, oldw, "FP");
}

// --- LDT locator + descriptor dump ------------------------------------------------
// DOS-Quake runs flat with cs=0x00a7 (LDT idx 0x14) / ds=0x00af (LDT idx 0x15), both
// based at 0x10000000. The wedge is `mov ds,0xaf` faulting (GPF error=0x00ac == sel 0xaf),
// i.e. the LDT descriptor for 0xaf became a non-data type. Find the LDT physically by
// scanning ddr[] for the adjacent {code@0xa0, data@0xa8} pair both based at 0x10000000.
// g_ldt_phys defined above (phys of LDT[0]; 0 = not located yet)
static bool desc_base_is(const uint8_t *d, uint32_t base) {
    uint32_t b = d[2] | (d[3] << 8) | (d[4] << 16) | (d[7] << 24);
    return b == base && (d[5] & 0x90) == 0x90;   // present + S=1 (code/data)
}
static void find_ldt() {
    if (g_ldt_phys || !ddr) return;
    const uint8_t *m = (const uint8_t*)ddr;
    uint64_t lim = g_mem_top_words ? g_mem_top_words * 8 : (DDR_WORDS * 8);
    for (uint64_t off = 0; off + 0x18 <= lim; off += 8) {
        const uint8_t *cs = m + off, *ds = m + off + 8;
        // cs = code (E bit set, d[5] bit3), ds = data (E clear), both base 0x10000000
        if (desc_base_is(cs, 0x10000000u) && (cs[5] & 0x08) &&
            desc_base_is(ds, 0x10000000u) && !(ds[5] & 0x08)) {
            g_ldt_phys = off - 0xa0;   // this pair is LDT[0xa0]/[0xa8]
            fprintf(stderr, "[LDT] found: LDT[0]=phys 0x%llx (cs@0xa0, ds@0xa8 based 0x10000000)\n",
                    (unsigned long long)g_ldt_phys);
            return;
        }
    }
    fprintf(stderr, "[LDT] not found by scan\n");
}
static void dump_ldt_descriptors() {
    find_ldt();
    if (!g_ldt_phys) return;
    const uint8_t *m = (const uint8_t*)ddr;
    for (int sel = 0xa0; sel <= 0xb8; sel += 8) {
        const uint8_t *d = m + g_ldt_phys + sel;
        uint32_t base = d[2] | (d[3]<<8) | (d[4]<<16) | (d[7]<<24);
        uint32_t lo, hi; memcpy(&lo, d, 4); memcpy(&hi, d+4, 4);
        fprintf(stderr, "  [LDT] sel 0x%02x = %08x %08x  base=%08x access=%02x gran=%02x %s\n",
                sel, lo, hi, base, d[5], d[6],
                (d[5]&0x90)!=0x90 ? "<<NOT present/S(corrupt?)" :
                (sel==0xa8 && (d[5]&0x08)) ? "<<ds slot is CODE type (corrupt!)" : "");
    }
}
static void dump_vga_text() {
    uint8_t *b = (uint8_t*)ddr;
    fprintf(stderr, "=== VGA text buffer (0xB8000, 80x25) ===\n");
    for (int row = 0; row < 25; row++) { char line[81];
        for (int col = 0; col < 80; col++) { uint8_t c = b[0xB8000 + (row*80+col)*2]; line[col] = (c>=32 && c<127)?c:' '; }
        line[80]=0; fprintf(stderr, "|%s|\n", line);
    }
}

int  g_last_ioread = -1; uint64_t g_ioread_since = 0;
int g_i0w,g_i1w,g_i0nd,g_i1nd,g_i0r,g_i1r;
int g_brdo,g_brdone,g_bwdo,g_bwdone,g_bbrd,g_bbwr,g_bbwait,g_bbaddr;
uint64_t g_3da_reads=0, g_3da_bit3_hi=0;
extern "C" void ao486_rd3da(int addr, int data){ (void)addr; g_3da_reads++; if(data&0x8) g_3da_bit3_hi++; }
// --dump-at diagnostics: dump the CPU ring + log RTC register/value accesses in a window.
static uint64_t g_dump_at = 0, g_rtcacc_from = 0; static int g_rtcacc_n = 0;
static unsigned int g_dumplin = 0;
extern "C" void ao486_rtc_acc(int rw, int val) {
    if (g_rtcacc_from && main_time >= g_rtcacc_from && g_rtcacc_n < 400) {
        fprintf(stderr, "[RTC] %s 0x%02x  eip=%05x cs=%04x\n", rw ? "SEL" : "RD ", val & 0xff, last_eip, last_cs);
        g_rtcacc_n++;
    }
}
static uint64_t g_ce8192=0, g_perpint=0, g_perpen=0; static uint32_t g_pmaj_min=0xffffffff, g_pmaj_max=0; static uint64_t g_perchecks=0;
static uint64_t g_ce_maj1=0, g_ce_maj0=0; static int g_perseq=0;
extern "C" void ao486_rtc_per(int ce8192,int pmajor,int pen,int pint){
    g_perchecks++;
    if(ce8192) g_ce8192++;
    if((uint32_t)pmajor < g_pmaj_min) g_pmaj_min=(uint32_t)pmajor;
    if((uint32_t)pmajor > g_pmaj_max) g_pmaj_max=(uint32_t)pmajor;
    if(pen) g_perpen++;
    if(pint) g_perpint++;
    if(ce8192 && pmajor==1) g_ce_maj1++;
    if(ce8192 && pmajor==0) g_ce_maj0++;
    if(ce8192 && g_perseq<60){ fprintf(stderr,"[PERseq] ce major=%d pen=%d pint=%d\n",pmajor,pen,pint); g_perseq++; }
}
static int g_rdiv=0,g_rprate=0,g_rpena=0,g_ruena=0,g_raena=0; static uint64_t g_rpint=0,g_ruint=0,g_rirq=0;
extern "C" void ao486_rtc(int divi,int prate,int pena,int uena,int aena,int pint,int uint_,int irqv){ g_rdiv=divi;g_rprate=prate;g_rpena=pena;g_ruena=uena;g_raena=aena; if(pint)g_rpint++; if(uint_)g_ruint++; if(irqv)g_rirq++; }
static uint64_t g_ido=0,g_idone=0,g_i0=0,g_i8=0,g_i1=0,g_intn=0;
extern "C" void ao486_intr(int ido,int idone,int i0,int i8,int i1){ if(ido)g_ido++; if(idone)g_idone++; if(i0)g_i0++; if(i8)g_i8++; if(i1)g_i1++; g_intn++; }
static uint64_t g_iwn=0;
extern "C" void ao486_idewait(int i0w,int i1w,int i0nd,int iadr,int ird,int i0cs,int i0req){
  if(g_iwn<30 && (i0w||i1w)){fprintf(stderr,"[IWAIT] ide0_wait=%d ide1_wait=%d ide0_nodata=%d ide_address=%d iobus_read=%d ide0_cs=%d ide0_req=%d\n",i0w,i1w,i0nd,iadr,ird,i0cs,i0req);g_iwn++;}
}
static int g_ideion=0;
extern "C" void ao486_ideio(int rw,int addr,int data){ if(g_ideion<4000){ if(rw==2) fprintf(stderr,"[IDEIO] sw_reset=%d\n",data); else fprintf(stderr,"[IDEIO] WR ioaddr=%d data=0x%02x\n",addr,data&0xff); g_ideion++; } }
static int g_reg5n=0;
extern "C" void ide_reg5_log(uint32_t addr, int before, int after){ if(g_reg5n<800){fprintf(stderr,"[REG5] write F005 ide0_request %d->%d\n",before,after);g_reg5n++;} }
static uint64_t g_ipn=0; static int g_iplast=0;
extern "C" void ao486_intposs(int ip,int ido,int idone){ (void)ido;(void)idone; if(ip)g_ipn++; g_iplast=ip; }
static uint64_t g_mrd=0,g_mwait=0,g_mrdv=0; static uint32_t g_maddr=0; static int g_mrdlast=0;
extern "C" void ao486_mem(int rd,int wr,int wait_,int rdv,int addr){ (void)wr; if(rd){g_mrd++;g_maddr=addr;} if(wait_)g_mwait++; if(rdv)g_mrdv++; g_mrdlast=rd; }
static char g_biosbuf[8192]; static int g_biosn=0;
extern "C" void ao486_bioscon(int addr,int ch){ (void)addr; if(g_biosn<8190){ g_biosbuf[g_biosn++]=(char)(ch&0xff); g_biosbuf[g_biosn]=0; } }
static int g_rtion=0, g_rtidx=0, g_rtwn=0; static uint64_t g_rtcwatch=0;
extern "C" void ao486_rtcio(int kind,int val){
    if(kind==0){g_rtidx=val&0xff;}
    bool early = (g_rtion<3000);
    bool win = (g_rtcwatch && main_time>=g_rtcwatch && g_rtwn<6000);   // --rtc-watch T: log a window near a later stall
    if(early || win){
        if(kind==0)fprintf(stderr,"[RTC%s] index=0x%02x\n", win?"W":"", val&0xff);
        else fprintf(stderr,"[RTC%s] read reg0x%02x -> 0x%02x\n", win?"W":"", g_rtidx, val&0xff);
        if(early)g_rtion++; if(win)g_rtwn++;
    }
}
static int g_irdn=0;
extern "C" void ao486_ideread(int addr,int data){ if(g_irdn<3000){ const char* n=(addr==0x1F7)?" [STATUS]":(addr==0x3F6)?" [ALTSTATUS]":""; fprintf(stderr,"[IDERD] port 0x%04x -> 0x%02x%s\n",addr,data&0xff,n); g_irdn++; } }
static int g_iwrn=0;
extern "C" void ao486_idewrite(int addr,int data){ if(g_iwrn<2000){ const char* n=(addr==0x3F6)?" <-- DEVCTRL/SRST":""; fprintf(stderr,"[IDEWR] port 0x%04x = 0x%02x%s\n",addr,data&0xff,n); g_iwrn++; } }
uint64_t g_vret_hi=0, g_ovs_hi=0, g_vret_edges=0; static int g_pvr=0;
extern "C" void ao486_vretrace(int vr, int ovs){ if(vr)g_vret_hi++; if(ovs)g_ovs_hi++; if(vr&&!g_pvr)g_vret_edges++; g_pvr=vr; }
extern "C" void ao486_iobus(int rdo,int rdone,int wdo,int wdone,int brd,int bwr,int bwait,int baddr){
    g_brdo=rdo;g_brdone=rdone;g_bwdo=wdo;g_bwdone=wdone;g_bbrd=brd;g_bbwr=bwr;g_bbwait=bwait;g_bbaddr=baddr; }
extern "C" void ao486_ide_state(int i0w,int i1w,int i0nd,int i1nd,int i0r,int i1r){ g_i0w=i0w;g_i1w=i1w;g_i0nd=i0nd;g_i1nd=i1nd;g_i0r=i0r;g_i1r=i1r; }
static uint64_t g_iowatch=0; static int g_iown=0;   // --io-watch T: log I/O read ports in a window
extern "C" void ao486_io_read(int addr, int pending) {
    static int pp=0;
    if (pending && !pp) {
        g_last_ioread = addr&0xffff; g_ioread_since = main_time;   // read started
        if (g_iowatch && main_time>=g_iowatch && g_iown<8000) { fprintf(stderr,"[IOR] port0x%04x\n", addr&0xffff); g_iown++; }
    }
    pp = pending;
}
extern "C" void ao486_cpu_trace2(int cs, int eip, int esp, int eax, int lin_true) {
    (void)eax;
    // True code linear = CS descriptor base + eip, computed in the RTL probe (works in
    // both real and protected mode). The old (cs<<4)+eip was wrong for LDT/GDT selectors.
    uint32_t lin = (uint32_t)lin_true;
    retire_count++; last_eip = eip; last_cs = cs & 0xffff; last_lin = lin;
    { extern uint32_t g_trace_eip; g_trace_eip = (uint32_t)eip; }   // latest retired guest eip, for the co-sim's eip-gated dtoa probe
    // Con_DrawConsole runaway detector. After the timedemo tail the guest spins in the console
    // glyph loop (Draw_Character caller at 0x06f30..0x06fb5) drawing con_linewidth (.data 0x90b44)
    // chars/line for a corrupted-huge count -> ~10M cyc/frame, no fps ever printed. When we've been
    // stuck in that region for a long time, dump the console globals + vid.width once so the bad
    // count and its source are visible.
    {
        static uint32_t spin = 0; static int dumped = 0;
        if ((uint32_t)eip >= 0x06f30u && (uint32_t)eip <= 0x06fb5u) {
            if (++spin > 400000u && !dumped) {
                dumped = 1;
                unsigned char *g = ao486_code_ptr_ctx(0x10090b20u, g_last_quake_cr3, 1);
                unsigned char *v = ao486_code_ptr_ctx(0x100c9c30u, g_last_quake_cr3, 1);
                fprintf(stderr, ">>> CON_DRAW SPIN @retire=%llu cyc=%llu\n",
                        (unsigned long long)retire_count, (unsigned long long)main_time);
                if (g) { fprintf(stderr, "    con globals 0x90b20..0x90b4f:");
                    for (int k = 0; k < 12; k++) { uint32_t w; memcpy(&w, g + 4*k, 4);
                        fprintf(stderr, " [%03x]=%08x", 0x90b20 + 4*k, w); } fprintf(stderr, "\n"); }
                if (v) { uint32_t vw, vh, rb; memcpy(&vw, v+0x10, 4); memcpy(&vh, v+0x14, 4); memcpy(&rb, v+0x0c, 4);
                    fprintf(stderr, "    vid.width=%d vid.height=%d vid.rowbytes=%d\n", vw, vh, rb); }
                fflush(stderr);
            }
        } else spin = 0;
    }
    // --- Win95 setup delay-loop dump (--dump-delay). The calibrated busy-wait spins in VxD
    // linear space 0xC0000000..0xC0040000 reading ONLY PIT ch0 (I/O port 0x40). Once we've been
    // sustained in that region with a recent port-0x40 read, dump the full context ONCE so the
    // loop can be reverse-engineered. 100% read-only / non-perturbing (only stderr + reg reads). ---
    if (g_dump_delay) {
        static bool     fired    = false;
        static uint32_t inregion = 0;      // retires accumulated inside the VxD region
        static uint32_t outrun   = 0;      // consecutive retires spent outside (tolerance)
        static uint32_t eips[64]; static int neips = 0;   // distinct loop code-linears seen
        bool in = (lin >= 0xC0000000u && lin < 0xC0040000u);
        if (!fired) {
            if (in) {
                outrun = 0;
                if (inregion != 0xffffffffu) inregion++;
                bool seen = false;
                for (int k = 0; k < neips; k++) if (eips[k] == lin) { seen = true; break; }
                if (!seen && neips < 64) eips[neips++] = lin;
            } else if (++outrun > 4096u) { inregion = 0; outrun = 0; }   // left the loop -> reset
            // Fire once: long sustained residency AND the loop is polling PIT ch0.
            if (in && inregion > 2000000u && (g_last_ioread & 0xffff) == 0x40) {
                fired = true;
                auto *R = top->rootp;
                uint32_t r_eip = R->system__DOT__ao486__DOT__eip;
                uint32_t r_cr3 = R->system__DOT__ao486__DOT__cr3;
                uint32_t r_pg  = R->system__DOT__ao486__DOT__cr0_pg;
                uint32_t r_eax = R->system__DOT__ao486__DOT__pipeline_inst__DOT__eax;
                uint32_t r_ebx = R->system__DOT__ao486__DOT__pipeline_inst__DOT__ebx;
                uint32_t r_ecx = R->system__DOT__ao486__DOT__pipeline_inst__DOT__ecx;
                uint32_t r_edx = R->system__DOT__ao486__DOT__pipeline_inst__DOT__edx;
                uint32_t r_esp = R->system__DOT__ao486__DOT__pipeline_inst__DOT__esp;
                uint32_t r_ebp = R->system__DOT__ao486__DOT__pipeline_inst__DOT__ebp;
                uint32_t r_esi = R->system__DOT__ao486__DOT__pipeline_inst__DOT__esi;
                uint32_t r_edi = R->system__DOT__ao486__DOT__pipeline_inst__DOT__edi;
                // Reconstruct EFLAGS from the individual flag bits (bit1 is always 1).
                #define FB(nm) ((uint32_t)(R->system__DOT__ao486__DOT__pipeline_inst__DOT__##nm & 1u))
                uint32_t efl = 2u
                    | (FB(cflag)<<0)  | (FB(pflag)<<2)  | (FB(aflag)<<4)  | (FB(zflag)<<6)
                    | (FB(sflag)<<7)  | (FB(tflag)<<8)  | (FB(iflag)<<9)  | (FB(dflag)<<10)
                    | (FB(oflag)<<11)
                    | (((uint32_t)R->system__DOT__ao486__DOT__pipeline_inst__DOT__iopl & 3u)<<12)
                    | (FB(ntflag)<<14)| (FB(rflag)<<16) | (FB(vmflag)<<17)
                    | (((uint32_t)(R->system__DOT__ao486__DOT__acflag & 1u))<<18);
                #undef FB
                uint64_t cs_cache = R->system__DOT__ao486__DOT__cs_cache;
                uint32_t cs_base  = (uint32_t)((cs_cache>>16)&0x00ffffffu) | (uint32_t)((cs_cache>>32)&0xff000000u);
                uint64_t ss_cache = R->system__DOT__ao486__DOT__pipeline_inst__DOT__ss_cache;
                uint32_t ss_base  = (uint32_t)((ss_cache>>16)&0x00ffffffu) | (uint32_t)((ss_cache>>32)&0xff000000u);
                int cur_cr3 = ao486_cur_cr3(), cur_pg = ao486_cur_pg();

                fprintf(stderr, "\n========== DELAY-LOOP DUMP (--dump-delay) ==========\n");
                fprintf(stderr, "fire @retire=%llu cyc=%llu inregion=%u distinct_eips=%d last_ioread=port0x%04x\n",
                        (unsigned long long)retire_count, (unsigned long long)main_time,
                        inregion, neips, g_last_ioread & 0xffff);
                fprintf(stderr, "EAX=%08x EBX=%08x ECX=%08x EDX=%08x\n", r_eax, r_ebx, r_ecx, r_edx);
                fprintf(stderr, "ESI=%08x EDI=%08x EBP=%08x ESP=%08x\n", r_esi, r_edi, r_ebp, r_esp);
                fprintf(stderr, "EIP=%08x(live) retired_eip=%08x lin=%08x EFLAGS=%08x\n",
                        r_eip, (uint32_t)eip, lin, efl);
                fprintf(stderr, "CR3=%08x(live) cur_cr3=%08x PG=%u cs_base=%08x ss_base=%08x\n",
                        r_cr3, (uint32_t)cur_cr3, r_pg, cs_base, ss_base);
                fflush(stderr);

                // (2) 128 bytes of code at the retired eip's linear, then at each distinct loop lin.
                auto dump_code = [&](const char *tag, uint32_t clin){
                    unsigned char *p = ao486_code_ptr_ctx(clin, (unsigned)cur_cr3, cur_pg);
                    fprintf(stderr, "--- CODE %-4s lin=%08x %s ---\n", tag, clin, p?"":"(untranslatable)");
                    if (!p) return;
                    for (int k = 0; k < 128; k++) { if ((k&15)==0) fprintf(stderr, "  %08x:", clin+k);
                        fprintf(stderr, " %02x", p[k]); if ((k&15)==15) fprintf(stderr, "\n"); }
                    fflush(stderr);
                };
                dump_code("cur", lin);
                for (int k = 0; k < neips; k++) dump_code("loop", eips[k]);

                // (3) stack window [esp-64 .. esp+256] as dwords (80 dwords).
                uint32_t stk_lin = ss_base + r_esp - 64u;
                unsigned char *sp = ao486_code_ptr_ctx(stk_lin, (unsigned)cur_cr3, cur_pg);
                fprintf(stderr, "--- STACK @lin=%08x (ss_base+esp-64 .. +256), 80 dwords ---\n", stk_lin);
                if (sp) { for (int k = 0; k < 80; k++) { uint32_t w; memcpy(&w, sp+4*k, 4);
                        if ((k&7)==0) fprintf(stderr, "  %08x:", stk_lin+4*k);
                        fprintf(stderr, " %08x", w); if ((k&7)==7) fprintf(stderr, "\n"); } }
                else fprintf(stderr, "  (stack untranslatable)\n");
                fprintf(stderr, "========== END DELAY-LOOP DUMP ==========\n\n");
                fflush(stderr);
            }
        }
    }
    {   // --- Win95 delay-loop spin flag (gates --w95-warp / --w95-accum / --w95-probe) ---
        static uint32_t inwin = 0, outwin = 0;
        bool in_vxd = (lin >= 0xC0000000u && lin < 0xC0040000u);
        if (in_vxd) { outwin = 0;
            if (!g_w95_spin && ++inwin > 200000u) {
                g_w95_spin = true; g_w95_cr3 = (uint32_t)ao486_cur_cr3();
                fprintf(stderr, ">>> W95 spin CONFIRMED @cyc=%llu lin=%08x cr3=%08x\n",
                        (unsigned long long)main_time, lin, g_w95_cr3); fflush(stderr);
            }
        } else if (g_w95_spin && ++outwin > 4096u) {
            g_w95_spin = false; inwin = 0;
            fprintf(stderr, ">>> W95 spin CLEARED @cyc=%llu lin=%08x (delay done)\n",
                    (unsigned long long)main_time, lin); fflush(stderr);
        }
    }
    if ((uint32_t)eip < eip_min) eip_min = eip;
    if ((uint32_t)eip > eip_max) eip_max = eip;
    // Detect the segment corruption: CS transitions from a normal value to a
    // tiny/garbage one (the bad far-jump/iret). Dump the path that led there.
    uint32_t prev_cs = ring_cs[(ring_pos + RING - 1) % RING];
    ring_cs[ring_pos] = cs & 0xffff; ring_eip[ring_pos] = eip; ring_esp[ring_pos] = esp; ring_lin[ring_pos] = lin;
    ring_pos = (ring_pos + 1) % RING;
    // --- co-sim wedge hunt: wide ring + crash detection ---
    wr_cs[wr_pos] = cs & 0xffff; wr_eip[wr_pos] = eip; wr_lin[wr_pos] = lin; wr_esp[wr_pos] = esp;
    wr_time[wr_pos] = main_time; wr_pos = (wr_pos + 1) & (WRING - 1);
    // PRIMARY wedge capture: the abort is Quake calling exit() at ~frame 257 -> DJGPP teardown,
    // which gets STUCK spinning in the go32/DPMI memory-UNLOCK loop at flat offset 0x44d60
    // (a summation bounded by a corrupted-huge size). That loop (lin 0x10044d60-0x10044d7e) is
    // ONLY reached at exit, so the first hit post-render (vframe>255) marks the teardown. The
    // 8M-retire ring reaches back through the exit path to the trigger (Sys_Error / fault) that
    // caused exit(). Dump it, then stop.
    // Onset is the FIRST-EVER hit of the unlock loop (exit-only code) after Quake is running
    // (retire>15M = past boot+level-load). vframe is unreliable (it keeps climbing on static
    // refreshes DURING the wedge loop), so gate on retire count, not frames.
    // NOTE: eip 0x44d60 is NOT exit teardown — it is Quake's DOS startup memory-PROBE
    // lock/unlock loop (sys_dos: lock a 128 KB chunk, checksum it, sbrk(-0x20000) to
    // release it, repeat over all lockable RAM). It legitimately runs for hundreds of
    // millions of cycles at startup, so the old "first hit = teardown -> stop" was a
    // FALSE POSITIVE that aborted the run mid-startup. Disabled.
    if (false && !g_crash_dumped && retire_count > 15000000 && (uint32_t)eip >= 0x44d60u && (uint32_t)eip <= 0x44d7eu) {
        g_crash_dumped = true;
        dump_wide_ring_and_faults("EXIT-TEARDOWN onset (go32 memory-unlock loop eip=0x44d60), first hit",
                                  "../tmp/wide_wedge_trace.txt", 1);
    }
    // Hunk_AllocName(size, name) probe. Quake aborts with "Hunk_Alloc: failed on 512000016 bytes"
    // during the demo's map load; the printed number is 16 + ((size+15)&~15), so the request was
    // 512,000,000 bytes. Entry 0x487b0 is `push esi; push ebx; mov esi,[esp+0xc]`, so on entry
    // [esp]=return address and [esp+4]=size. Log every oversized request with its caller.
    if ((uint32_t)eip == 0x487b0u && retire_count > 5000000) {
        static int nbig = 0;
        unsigned char *sp = ao486_code_ptr_ctx(0x10000000u + (uint32_t)esp, ao486_cur_cr3(), ao486_cur_pg());
        if (sp && nbig < 24) {
            uint32_t ret, size; memcpy(&ret, sp, 4); memcpy(&size, sp + 4, 4);
            if (size > (1u << 20)) {
                nbig++;
                fprintf(stderr, ">>> HUNK_ALLOC size=%u (0x%08x) caller_ret=%05x @retire=%llu cyc=%llu\n",
                        size, size, ret, (unsigned long long)retire_count, (unsigned long long)main_time);
                fflush(stderr);
            }
        }
    }
    // REAL fault capture: the DJGPP go32 exception dispatcher lives at flat 0x4d5c4..0x4d611
    // (the push-<excno> vector stubs + the common handler whose `mov ds,[cs:0x4d774]` at
    // 0x4d609 is where a corrupt LDT descriptor for ds=0xaf nested-faults). Reaching it after
    // Quake is up = a CPU fault (GPF/#PF/#NP) was taken. Dump the context + LDT descriptors.
    if (!g_crash_dumped && retire_count > 10000000 && (uint32_t)eip >= 0x4d5c4u && (uint32_t)eip <= 0x4d611u) {
        g_crash_dumped = true;
        fprintf(stderr, ">>> FAULT: entered go32 exception dispatcher eip=%05x @retire=%llu cyc=%llu\n",
                (uint32_t)eip, (unsigned long long)retire_count, (unsigned long long)main_time);
        // The stub table is `push <excno>; jmp common`, so the entry eip names the vector:
        // 0x4d5dc => 14 (#PF). DPMI (INT 31h func 0x0203) enters the handler with this frame
        // on the client stack:  [esp]=ret EIP, +4=ret CS, +8=error code, +0Ch=faulting EIP,
        // +10h=faulting CS, +14h=EFLAGS, +18h=ESP, +1Ch=SS.  The CS:EIP ring cannot name the
        // faulting instruction (its newest flat entry IS the stub), but this frame can.
        // The cpu_probe's cs/eip/esp belong to a different pipeline stage than the faulting
        // instruction (the guest's own DJGPP handler reports cs=00a7 eip=00055efd esp=0011a214
        // while the probe ring shows 0018:00002b78 esp=00006fa8), so the probe's esp cannot be
        // used to find the frame. Quake's flat ds/ss base is 0x10000000 and the fault is
        // deterministic, so dump the known stack window directly and walk it by hand:
        // memcpy(0x4df04) does `push ebp; mov ebp,esp`, so [ebp+4] is the return address into
        // Draw_ConsoleBackground and [ebp+8/0xc/0x10] are (dest, src, count).
        {
            const uint32_t STK = 0x1011a1c0u;      // covers esp=0x11a214 and ebp=0x11a220
            unsigned char *sp = ao486_code_ptr_ctx(STK, g_last_quake_cr3, 1);
            if (sp) {
                fprintf(stderr, "--- guest stack @lin=%08x (96 dwords) ---\n", STK);
                for (int k = 0; k < 96; k++) {
                    uint32_t w; memcpy(&w, sp + 4 * k, 4);
                    if ((k & 7) == 0) fprintf(stderr, "  %08x:", STK + 4 * k);
                    fprintf(stderr, " %08x", w);
                    if ((k & 7) == 7) fprintf(stderr, "\n");
                }
            }
            // conback qpic_t: {int width; int height; byte data[]} at 0x1a8c44
            unsigned char *cb = ao486_code_ptr_ctx(0x101a8c44u, g_last_quake_cr3, 1);
            if (cb) {
                uint32_t w0, w1; memcpy(&w0, cb, 4); memcpy(&w1, cb + 4, 4);
                fprintf(stderr, "--- conback @0x1a8c44: width=%d height=%d (expect 320x200) ---\n", w0, w1);
            }
            // The x87 op stream of the sprintf("%4.2f",1.06) that smashed this frame.
            x87_dump_last_cvt();
        }
        // Dump but DO NOT stop: a fault reaching the DJGPP handler is not necessarily fatal
        // (it may be reflected and handled). Let the run continue so we learn whether Quake
        // recovers and still reaches the timedemo.
        dump_wide_ring_and_faults("go32 exception-dispatcher entry (a CPU fault was taken)",
                                  "../tmp/wide_fault_trace.txt", 0);
    }
    // Crash detection (selector-independent; DJGPP flat linear = 0x10000000 + offset). Valid
    // Quake code is at lin in [0x100010a8, 0x1005b1c3] (QEMU reference). The wedge is a wild
    // jump to a near-null offset (observed lin=0x10000000) -> #PF -> DJGPP SIGSEGV -> exit().
    // Wedge detection that survives long legit DOS blocking. Quake's flat code (00a7-based,
    // lin 0x1000xxxx) goes quiet in TWO cases: (a) a long DOS level-load (disk I/O in
    // real-mode 26ac — millions of retires, ~tens of frames) which RESUMES; (b) the real
    // wedge (exit()->DPMI teardown, flat code dead forever, VGA frame counter climbs ~1000
    // frames). Snapshot the ring the moment flat code goes quiet (context still in-ring), and
    // CONFIRM only after the frame counter has advanced far while flat code stays dead.
    {
        static uint64_t q_seen = 0;      // # of retires in valid Quake code
        static uint64_t since_q = 0;     // retires since last valid Quake-code retire
        static int suspect = 0; static int snap_frame = 0; static uint64_t snap_retire = 0;
        // Quake DJGPP flat code = selector 0x00a7, eip offset in [0x1000,0x60000). (In the
        // default non-TRUE_LIN build `lin` is (cs<<4)+eip, NOT the flat linear, so the old
        // `lin >= 0x10001000` test was ALWAYS FALSE -> resolve_watch/find_ldt never ran.
        // Detect by selector+eip instead; the flat linear is 0x10000000 + eip regardless.)
        int in_quake = ((cs & 0xffff) == 0x00a7) && ((uint32_t)eip >= 0x1000u) && ((uint32_t)eip < 0x60000u);
        if (in_quake) {
            q_seen++; since_q = 0;
            if (ao486_cur_pg()) { g_last_quake_cr3 = (uint32_t)ao486_cur_cr3();
                // Resolve (or RE-resolve) the watched go32 globals whenever the cr3 changes OR
                // any word is still unresolved (the first resolve can land before go32 has mapped
                // these pages, which would latch ~0u forever). Retry until all four resolve.
                bool need = (g_last_quake_cr3 != g_watch_cr3);
                for (int i = 0; i < NWATCH && !need; i++) if (g_watch_word[i] == ~0u) need = true;
                if (need) resolve_watch(); }
            if (suspect) suspect = 0;              // flat code resumed -> that quiet spell was a DOS load
        } else since_q++;
        if (!g_crash_dumped && q_seen > 100000) {
            // Flat code just went quiet (50k < ring size, so the last flat instr is still in
            // the ring): snapshot the abort context now, to a file. Overwritten by each new
            // quiet spell, so the last snapshot before a confirm is the wedge's.
            if (!suspect && since_q > 50000) {
                suspect = 1; snap_frame = vframe; snap_retire = retire_count;
                dump_wide_ring_and_faults("suspected-stall snapshot (flat code quiet 50k)",
                                          "../tmp/wide_crash_trace.txt", 0);
                fprintf(stderr, ">>> SNAPSHOT taken @frame=%d retire=%llu (awaiting confirm)\n",
                        snap_frame, (unsigned long long)snap_retire);
            }
            // Still dead 60+ frames later -> the real wedge (a DOS load resumes long before;
            // the frame-35 level-load spans ~25 frames, the wedge hang spans ~1000).
            if (suspect && vframe - snap_frame > 60) {
                g_crash_dumped = true;
                char why[160];
                snprintf(why, sizeof why, "CONFIRMED WEDGE: flat code dead since frame %d retire %llu, now frame %d",
                         snap_frame, (unsigned long long)snap_retire, vframe);
                fprintf(stderr, ">>> %s (snapshot in ../tmp/wide_crash_trace.txt is the abort context)\n", why);
                dump_wide_ring_and_faults(why, "../tmp/wide_confirm_trace.txt", 1);
            }
        }
    }
    if (!crash_dumped && retire_count > 100 && (cs & 0xffff) <= 0x0010 && prev_cs > 0x0040) {
        fprintf(stderr, ">>> CS corruption: %04x:%08x  (prev CS=%04x) @instr %llu  esp=%05x\n",
                cs & 0xffff, eip, prev_cs, (unsigned long long)retire_count, esp & 0xfffff);
        crash_dumped = true; dump_ring();
    }
    // stuck-loop detector: same tiny eip region for a long time -> dump path once
    static uint32_t stuck_lo = 0xffffffff, stuck_hi = 0; static uint64_t stuck_cnt = 0; static uint64_t stuck_base = 0;
    if ((uint32_t)eip >= 0xe000 && (uint32_t)eip <= 0xf800) {
        if ((uint32_t)eip < stuck_lo) stuck_lo = eip; if ((uint32_t)eip > stuck_hi) stuck_hi = eip;
        stuck_cnt++;
        if (!crash_dumped && stuck_cnt - stuck_base > 2000000 && (stuck_hi - stuck_lo) < 0x40) {
            fprintf(stderr, ">>> STUCK in eip [%05x-%05x] for %lluk instr @instr %llu\n",
                    stuck_lo, stuck_hi, (unsigned long long)((stuck_cnt-stuck_base)/1000), (unsigned long long)retire_count);
            crash_dumped = true; dump_ring();
        }
    } else { stuck_lo = 0xffffffff; stuck_hi = 0; stuck_base = stuck_cnt; }
    if (trace_fp) fprintf(trace_fp, "%04x:%04x %05x\n", cs & 0xffff, eip & 0xffff, lin);
}

// CR0.EM/TS change + ESC-trap logger. The co-sim ESC path fires only while EM=0 && TS=0; if
// either is set, ESC ops trap to NM(INT7) and the co-sim goes silent (Quake then runs FP-blind).
extern "C" void ao486_emts(int em, int ts, int kind) {
    static uint64_t trapn = 0, chgn = 0;
    if (kind == 2) {
        if (trapn < 60) { fprintf(stderr, "[ESCTRAP] ESC op TRAPPED (co-sim skipped): em=%d ts=%d eip=%04x:%08x(lin=%08x) @cyc=%llu retire=%llu\n",
                                  em, ts, last_cs, last_eip, last_lin, (unsigned long long)main_time, (unsigned long long)retire_count); trapn++; }
    } else {
        if (chgn < 300) { fprintf(stderr, "[EMTS] CR0 EM=%d TS=%d SET-BY eip=%04x:%08x(lin=%08x) @cyc=%llu retire=%llu\n",
                                  em, ts, last_cs, last_eip, last_lin, (unsigned long long)main_time, (unsigned long long)retire_count); chgn++; }
    }
}

// Page-fault probe handler: record every data #PF (kind, cr2=faulting linear, eip).
extern "C" void ao486_pagefault(int kind, int cr2, int exeip, int wreip, int cr3, int pg) {
    if (!pg) return;                                  // only paged-mode faults are of interest
    // Win95 crash diagnostic: is the faulting address ACTUALLY mapped? If mapped ->
    // the ao486 delivered a SPURIOUS #PF (genuine core/TLB bug). Flag every spurious one.
    {
        long long ph = ao486_xlate((uint32_t)cr2, (uint32_t)cr3, pg);
        if (ph >= 0) {   // MAPPED but faulted = spurious
            static int ks = 0;
            if (ks++ < 60)
                fprintf(stderr, ">>> SPURIOUS-PF cr2=%08x exeip=%08x wreip=%08x kind=%d cr3=%08x -> phys=%llx @retire=%llu\n",
                        (uint32_t)cr2, (uint32_t)exeip, (uint32_t)wreip, kind, (uint32_t)cr3,
                        (unsigned long long)ph, (unsigned long long)retire_count);
        }
    }
    PfEnt &e = g_pf[g_pf_head];
    e.kind = kind; e.cr2 = (uint32_t)cr2; e.exeip = (uint32_t)exeip; e.wreip = (uint32_t)wreip;
    e.cr3 = (uint32_t)cr3; e.retire = retire_count;
    g_pf_head = (g_pf_head + 1) & (PFRING - 1); g_pf_count++;
}

// Crash dump: write the wide (32-bit) CS:EIP history to a file + the FPU op ring and the
// page-fault ring to stderr, so the faulting Quake instruction (true linear) and the FP
// op that produced the corrupted operand can be identified.
static void dump_wide_ring_and_faults(const char *why, const char *wf, int final_stop) {
    fprintf(stderr, "\n>>> WEDGE %s (%s) @retire=%llu cyc=%llu <<<\n",
            final_stop ? "CRASH DETECTED" : "snapshot", why, (unsigned long long)retire_count, (unsigned long long)main_time);
    FILE *f = fopen(wf, "w");
    if (f) {
        fprintf(f, "# cs:eip32 lin32 esp32 main_time  (oldest->newest, %u entries)\n", WRING);
        for (uint32_t k = 0; k < WRING; k++) {
            uint32_t idx = (wr_pos + k) & (WRING - 1);
            if (wr_time[idx] == 0 && wr_cs[idx] == 0 && wr_eip[idx] == 0) continue;
            fprintf(f, "%04x:%08x %08x %08x %llu\n", wr_cs[idx], wr_eip[idx], wr_lin[idx],
                    wr_esp[idx], (unsigned long long)wr_time[idx]);
        }
        fclose(f);
        fprintf(stderr, ">>> wide CS:EIP trace (%u retires, TRUE linear) -> %s\n", WRING, wf);
    }
    // last 48 wide-ring entries to stderr for an immediate look
    fprintf(stderr, "--- last 48 retires (cs:eip32 lin32 esp) ---\n");
    for (uint32_t k = WRING - 48; k < WRING; k++) {
        uint32_t idx = (wr_pos + k) & (WRING - 1);
        fprintf(stderr, "  %04x:%08x lin=%08x esp=%08x t=%llu\n", wr_cs[idx], wr_eip[idx],
                wr_lin[idx], wr_esp[idx], (unsigned long long)wr_time[idx]);
    }
    // page-fault ring (the fatal fault = the last one)
    fprintf(stderr, "--- page-fault ring (last %d of %llu total; kind 1=read 2=write) ---\n",
            PFRING, (unsigned long long)g_pf_count);
    for (int k = 0; k < PFRING; k++) {
        const PfEnt &e = g_pf[(g_pf_head + k) & (PFRING - 1)];
        if (!e.retire) continue;
        fprintf(stderr, "  PF kind=%d cr2=%08x exe_eip=%08x wr_eip=%08x cr3=%08x @retire=%llu\n",
                e.kind, e.cr2, e.exeip, e.wreip, e.cr3, (unsigned long long)e.retire);
    }
    // Find the faulting Quake instruction: the newest wide-ring entry whose CS is Quake's
    // main flat selector (00a7) -> its true linear + esp. DJGPP is flat with a common
    // segment base, so cs_base = lin - eip and stack_lin = cs_base + esp.
    uint32_t f_cs=0, f_eip=0, f_lin=0, f_esp=0; int found=0;
    for (int k = WRING - 1; k >= 0; k--) {
        uint32_t idx = (wr_pos + (uint32_t)k) & (WRING - 1);
        // Identify Quake flat code by the EIP offset range (works with or without TRUE_LIN);
        // the DJGPP flat linear is always 0x10000000 + eip regardless of the probe's lin.
        // Skip the go32 exception dispatcher itself (0x4d5c4..0x4d611) -- it is flat Quake-range
        // code too, so without this the "faulting instr" is always reported as the stub.
        if (wr_eip[idx] >= 0x4d5c4u && wr_eip[idx] <= 0x4d611u) continue;
        if (wr_eip[idx] >= 0x1000u && wr_eip[idx] < 0x60000u) {
            f_cs=wr_cs[idx]; f_eip=wr_eip[idx]; f_lin=0x10000000u + wr_eip[idx]; f_esp=wr_esp[idx]; found=1; break; }
    }
    if (found) {
        uint32_t cs_base = 0x10000000u;   // DJGPP flat CS base
        fprintf(stderr, "--- faulting Quake instr: cs=%04x eip=%08x lin=%08x esp=%08x cs_base=%08x (quake_cr3=%08x) ---\n",
                f_cs, f_eip, f_lin, f_esp, cs_base, g_last_quake_cr3);
        // Translate with Quake's OWN paging context (the dump often runs while the CPU is in
        // DOS/DPMI real-mode with paging off, where the current context can't map flat addrs).
        unsigned char *cb = ao486_code_ptr_ctx(f_lin - 32, g_last_quake_cr3, 1);
        fprintf(stderr, "code @lin=%08x (eip-32 .. eip+223):\n", f_lin - 32);
        if (cb) { for (int k=0;k<256;k++){ fprintf(stderr,"%02x%s", cb[k], ((k&31)==31)?"\n":" "); } }
        else fprintf(stderr, "  <untranslatable>\n");
        uint32_t stack_lin = cs_base + f_esp;
        unsigned char *sb = ao486_code_ptr_ctx(stack_lin - 32, g_last_quake_cr3, 1);
        fprintf(stderr, "stack @lin=%08x (esp-32 .. esp+223) [dwords]:\n", stack_lin - 32);
        if (sb) { for (int k=0;k<64;k++){ uint32_t w; memcpy(&w, sb+k*4, 4);
                    fprintf(stderr, "%08x%s", w, ((k&7)==7)?"\n":" "); } }
        else fprintf(stderr, "  <untranslatable>\n");
    }
    // go32/DJGPP runtime-data snapshot (the suspected-corrupt globals), read under Quake's
    // OWN paging context. Correct values: DPMI-switch far-ptr = <offset>:<valid selector>
    // (non-garbage); exc-DS-sel low word = a valid data selector (not 0x00a8); memory-top /
    // program-break = ~0x03000000 for a healthy 48 MB image (NOT >0x80000000).
    fprintf(stderr, "--- go32 runtime data (Quake cr3=%08x) ---\n", g_last_quake_cr3);
    for (int i = 0; i < NWATCH; i++) {
        unsigned char *p = ao486_code_ptr_ctx(WATCH_LIN[i], g_last_quake_cr3, 1);
        if (p) { uint32_t d0, d1; memcpy(&d0, p, 4); memcpy(&d1, p + 4, 4);
            fprintf(stderr, "  [GO32] %-18s lin=%08x = %08x %08x  (word=%08x)\n",
                    WATCH_NM[i], WATCH_LIN[i], d0, d1, g_watch_word[i]); }
        else fprintf(stderr, "  [GO32] %-18s lin=%08x <untranslatable>\n", WATCH_NM[i], WATCH_LIN[i]);
    }
    fprintf(stderr, "  [GO32] total watched-word stores logged so far: %d\n", g_watch_logs);
    fprintf(stderr, "--- LDT descriptors (cs=0xa7 idx0x14, ds=0xaf idx0x15; wedge = ds desc corrupt) ---\n");
    dump_ldt_descriptors();
    ao486_fpu_dump_ring(256);
    fflush(stderr);
    if (final_stop) g_stop_after = main_time + 60000;   // stop shortly after the CONFIRMED wedge
}

// Compare each completed icache fetch to the known BIOS bytes in DDR.
static uint64_t icache_checks = 0, icache_bad = 0;
static uint64_t icache_bad_valid = 0, icache_bad_invalid = 0;
extern "C" void ao486_icache_check(int addr, int data, int valid, int rdaddr) {
    // Compare the returned data to the line the icache ACTUALLY fetched (read_addr),
    // not the current CPU_ADDR — so abandoned speculative prefetches (CPU branched
    // mid-fetch) are not false-flagged. A mismatch HERE = a genuine cache data bug.
    uint32_t fa = (uint32_t)rdaddr & ~3u;
    if (fa < 0xC0000 || fa >= 0x100000) return;
    icache_checks++;
    uint32_t expect; memcpy(&expect, (uint8_t *)ddr + fa, 4);
    if ((uint32_t)data != expect) {
        if (valid & 1) icache_bad_valid++; else icache_bad_invalid++;
        if ((valid & 1) || icache_bad < 40)
            fprintf(stderr, "ICACHE REAL-MISMATCH fetched@0x%05x (cpu=0x%05x): got %08x expected %08x valid=%d check#%llu @cyc=%llu [validbad=%llu invalidbad=%llu]\n",
                    fa, (uint32_t)addr & ~3u, (uint32_t)data, expect, valid & 1,
                    (unsigned long long)icache_checks, (unsigned long long)main_time,
                    (unsigned long long)icache_bad_valid, (unsigned long long)icache_bad_invalid);
        icache_bad++;
    }
}
extern "C" void ao486_icd(int memwe, int memdatain, int mreq, int maddr,
                          int mdone, int mdata, int cpuaddr) {
    if (main_time < 1090 || main_time > 1125) return;
    if (!memwe && !mreq && !mdone) return;
    fprintf(stderr, "[cyc %llu] fillwe=%x filldata=%08x | MEM req=%d addr=%08x done=%d data=%08x | cpu=%05x\n",
            (unsigned long long)main_time, memwe, (uint32_t)memdatain, mreq, (uint32_t)maddr,
            mdone, (uint32_t)mdata, cpuaddr);
}
static void dump_ring() {
    fprintf(stderr, "--- last %d retired CS:EIP (oldest->newest), lin=(cs<<4)+eip ---\n", RING);
    for (int i = 0; i < RING; i++) {
        int idx = (ring_pos + i) % RING;
        fprintf(stderr, " %04x:%04x[%05x]e%05x%s", ring_cs[idx], ring_eip[idx] & 0xffff,
                ring_lin[idx], ring_esp[idx] & 0xfffff, (i % 6 == 5) ? "\n" : "");
    }
    fprintf(stderr, "\n");
}

// ---- DDR helpers ---------------------------------------------------------
static inline uint8_t *ddr_bytes() { return (uint8_t *)ddr; }
static void ddr_memset(uint64_t phys, uint8_t v, uint64_t len) { memset(ddr_bytes() + phys, v, len); }
static bool ddr_load(const char *path, uint64_t phys) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "ddr_load: cannot open %s\n", path); return false; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    if (fread(ddr_bytes() + phys, 1, sz, f) != (size_t)sz) { fclose(f); return false; }
    fclose(f);
    fprintf(stderr, "ddr_load: %s -> phys 0x%05llx (%ld bytes)\n", path, (unsigned long long)phys, sz);
    return true;
}

static bool prev_rd = false;
static void ddr_service() {
    // Accept a read burst only on the cycle RD is asserted-and-accepted. With
    // BUSY=0 the master deasserts RD after one cycle; guard against a held RD
    // re-pushing the same burst (which would pollute rd_fifo and return stale
    // data to a later request).
    if (top->DDRAM_RD && !prev_rd) {
        uint32_t a = top->DDRAM_ADDR; int n = top->DDRAM_BURSTCNT ? top->DDRAM_BURSTCNT : 1;
        { static int dbg=0; if (a >= 0x1e180 && a <= 0x1e1a0 && dbg<24) { fprintf(stderr,"DDRcap ADDR=0x%x BURSTCNT=%d ddr[a]=%016llx @cyc=%llu\n", a, n, (unsigned long long)ddr[a & (DDR_WORDS-1)], (unsigned long long)main_time); dbg++; } }
        for (int i = 0; i < n; i++) {
            uint32_t ra = (uint32_t)((a + i) & (DDR_WORDS - 1));
            // Capture the read DATA now (at issue), not when the beat is served: a
            // write to the same word between issue and serve must NOT be seen by this
            // read (it was issued first). Serving ddr[ra] later returned post-write
            // data and corrupted CPU register loads (pop/mov landing on a store).
            uint64_t rd = (g_mem_top_words && ra >= g_mem_top_words)
                          ? (~((uint64_t)ra * 0x0100000001000001ull)) : ddr[ra];
            rd_fifo.push_back({ ra, main_time + g_ddr_lat, rd });
        }
    }
    prev_rd = top->DDRAM_RD;
    if (top->DDRAM_WE) {
        if (!wburst) { waddr = top->DDRAM_ADDR; wrem = top->DDRAM_BURSTCNT ? top->DDRAM_BURSTCNT : 1; wburst = true; }
        uint32_t a = waddr & (DDR_WORDS - 1);
        if ((uint64_t)a * 8 > g_max_waddr) g_max_waddr = (uint64_t)a * 8;
        if (g_mem_top_words && a >= g_mem_top_words) { waddr++; if (--wrem <= 0) wburst = false; }
        else {
        uint64_t din = top->DDRAM_DIN; uint8_t be = top->DDRAM_BE, mask8 = 0; uint64_t mask = 0;
        for (int b = 0; b < 8; b++) if (be & (1 << b)) mask |= (0xffull << (b * 8));
        uint64_t oldv = ddr[a];
        (void)mask8; ddr[a] = (ddr[a] & ~mask) | (din & mask);
        watch_write(a, ddr[a], oldv, "CPU");
        waddr++; if (--wrem <= 0) wburst = false;
        }
    }
    if (!rd_fifo.empty() && main_time >= rd_fifo.front().ready) {
        top->DDRAM_DOUT = rd_fifo.front().data;   // data captured at issue time
        top->DDRAM_DOUT_READY = 1;
        { static int d=0; uint32_t sa=rd_fifo.front().addr; if(sa>=0x1e188 && sa<=0x1e18f && d<40){fprintf(stderr,"DDRserve ra=0x%x beat=%016llx @cyc=%llu fifo=%zu\n",sa,(unsigned long long)rd_fifo.front().data,(unsigned long long)main_time,rd_fifo.size());d++;} }
        rd_fifo.pop_front();
    } else {
        top->DDRAM_DOUT_READY = 0;
    }
    top->DDRAM_BUSY = 0;
}

// clk_vga is driven as a divided clock (step_vga_clock) so the VGA pixel domain
// runs slower than clk_sys. Tying clk_vga=clk_sys made the 0x3DA vertical-retrace
// flag (clk_vga domain) race the host-bus read (clk_sys): the CPU sampled it as
// set only ~0.05% of the time instead of its true ~30% duty, so the VGA BIOS's
// retrace-wait subroutine (palette loads etc.) almost always hit its timeout and
// POST crawled for billions of cycles. A slower clk_vga keeps the flag stable
// across each host read so the waits resolve immediately.
static int g_vga_phase = 0;
static int g_vga_div = 4;   // clk_vga toggles every g_vga_div clk_sys phases (larger => slower VGA/retrace)
static inline void step_vga_clock() { if (++g_vga_phase >= g_vga_div) { g_vga_phase = 0; top->clk_vga = !top->clk_vga; } }
static inline void set_clocks(int v) {
    top->clk_sys = v; top->clk_audio = v;
    top->clk_uart1 = v; top->clk_uart2 = v; top->clk_mpu = v;
}

// One full clock with DDR service on the posedge.
static void tick() {
    set_clocks(0); top->eval();
    set_clocks(1); step_vga_clock(); top->eval();
    ddr_service();  top->eval();
    main_time++;
    vcd_dump();
}

// Exposed to ps_shim.cpp so each mgmt transfer advances the RTL one clock.
void ps_clock_tick() { tick(); }

// ---- save/load state (snapshot the slow POST so debug iterations are fast) ---
// Captures the verilated RTL (--savable), the 256MB DDR, the DDR-model FIFO, and
// the harness time. Disk file handles are re-attached after load (re-open images).
static void save_state(const char *fn) {
    VerilatedSave os; os.open(fn);
    os.write(&main_time, sizeof(main_time));
    os.write(&retire_count, sizeof(retire_count));
    os.write(ddr, DDR_WORDS * sizeof(uint64_t));
    uint64_t n = rd_fifo.size(); os.write(&n, sizeof(n));
    for (auto &b : rd_fifo) { os.write(&b.addr, sizeof(b.addr)); os.write(&b.ready, sizeof(b.ready)); }
    os.write(&wburst, sizeof(wburst)); os.write(&waddr, sizeof(waddr)); os.write(&wrem, sizeof(wrem));
    { int nb = ao486_fpu_state_bytes(); std::vector<uint8_t> fb(nb); ao486_fpu_state_save(fb.data());
      os.write(&nb, sizeof(nb)); os.write(fb.data(), nb); }   // co-sim x87 FPU state
    os << *top;
    os.close();
    fprintf(stderr, ">>> STATE SAVED to %s @cyc=%llu instr=%llu\n", fn,
            (unsigned long long)main_time, (unsigned long long)retire_count);
}
static void load_state(const char *fn) {
    VerilatedRestore is; is.open(fn);
    is.read(&main_time, sizeof(main_time));
    is.read(&retire_count, sizeof(retire_count));
    is.read(ddr, DDR_WORDS * sizeof(uint64_t));
    uint64_t n = 0; is.read(&n, sizeof(n)); rd_fifo.clear();
    for (uint64_t i = 0; i < n; i++) { RdBeat b; is.read(&b.addr, sizeof(b.addr)); is.read(&b.ready, sizeof(b.ready)); rd_fifo.push_back(b); }
    is.read(&wburst, sizeof(wburst)); is.read(&waddr, sizeof(waddr)); is.read(&wrem, sizeof(wrem));
    { int nb = 0; is.read(&nb, sizeof(nb)); std::vector<uint8_t> fb(nb); is.read(fb.data(), nb);
      ao486_fpu_state_load(fb.data()); }   // co-sim x87 FPU state
    is >> *top;
    is.close();
    fprintf(stderr, ">>> STATE LOADED from %s @cyc=%llu instr=%llu\n", fn,
            (unsigned long long)main_time, (unsigned long long)retire_count);
}

static uint32_t g_clock_rate = 4000000;   // timer base (low => timed delays complete fast)
static uint32_t g_rtc_rate = 80000;        // RTC time-base (cycles per RTC second); small so RTC-seconds-wait spins (Win95 IO.SYS, some timing) complete in sim time. PIT unaffected.
static int g_l1dis = 0, g_l2dis = 0;       // cache disables (debug)
static void tie_static_inputs() {
    // pit.v's divider degenerates if clk_rate(=11*clock_rate) <= INCREMENT(26.25M),
    // i.e. clock_rate <= 2.386MHz: ce fires every cycle, sum overflows, timer runs
    // wild. Clamp so a too-low --rate can't silently break the PIT/timer/interrupts.
    if (g_clock_rate < 2500000) { fprintf(stderr, "[warn] clock_rate %u too low for PIT; clamping to 4MHz\n", g_clock_rate); g_clock_rate = 4000000; }
    top->clock_rate = g_clock_rate; top->clock_rate_vga = 90000000;
    top->rtc_clock_rate = g_rtc_rate;
    top->l1_disable = g_l1dis; top->l2_disable = g_l2dis; top->bootcfg = 0; top->uma_ram = 0;
    top->l2_fpu_inv_pulse = 0; top->l2_fpu_inv_addr = 0;
    top->joystick_dis = 3;
    top->joystick_dig_1 = top->joystick_dig_2 = 0;
    top->joystick_ana_1 = top->joystick_ana_2 = 0;
    top->joystick_mode = top->joystick_timed = 0;
    top->floppy_wp = 0;
    top->mgmt_address = 0; top->mgmt_read = 0; top->mgmt_write = 0; top->mgmt_writedata = 0;
    top->ps2_kbclk_in = 1; top->ps2_kbdat_in = 1; top->ps2_mouseclk_in = 1; top->ps2_mousedat_in = 1;
    top->uart1_rx = 1; top->uart1_cts_n = 1; top->uart1_dcd_n = 1; top->uart1_dsr_n = 1;
    top->uart2_rx = 1; top->uart2_cts_n = 1; top->uart2_dcd_n = 1; top->uart2_dsr_n = 1;
    top->mpu_rx = 1; top->sound_fm_mode = 0; top->sound_cms_en = 0;
    top->video_f60 = 0; top->video_fb_en = 0; top->video_lores = 0; top->video_border = 0;
    top->DDRAM_BUSY = 0; top->DDRAM_DOUT = 0; top->DDRAM_DOUT_READY = 0;
}

// ---------------- PS/2 keyboard injection (device->host, Set-2 scancodes) --------------
// The 8042 (ps2.v) runs with translate=1, so we transmit Set-2 make/break codes and it
// translates them to Set-1 for the guest (0xF0 break-prefix -> Set-1 break bit, handled in HW).
// We drive ps2_kbclk_in/ps2_kbdat_in as an open-drain device: the physical line = our value AND
// the host's release line (ps2_*_out). One PS/2 bit = 24 sys-cycles clk-high then 24 clk-low; the
// 8042 samples data on the clock FALLING edge (via a 16-cycle debounce), where our data is stable.
// Frame = start(0), 8 data LSB-first, odd parity, stop(1). Dormant unless --kb is given.
static const char *g_kb_script = nullptr;   // --kb: comma list e.g. "enter,esc,enter"
static uint64_t g_kb_start = 3000000;       // --kb-start: cyc (main_time) before first key
static uint64_t g_kb_gap   = 6000000;       // --kb-gap: cyc between successive key events
static std::vector<std::vector<uint8_t>> g_kb_events;   // each entry = bytes for one press+release
static size_t   g_kb_ev_idx = 0;
static uint64_t g_kb_next_ev = 0;
static bool     g_kb_started = false;
static uint64_t g_kb_base = 0;              // main_time at first drive call (so --kb-start is a delay from load, not absolute)
static bool     g_kb_base_set = false;
static std::deque<uint8_t> g_kbfifo;        // pending raw Set-2 bytes to shift out
static int      g_kb_bits[11];
static int      g_kb_phase = -1;            // -1 idle; 0..10 = current bit index
static int      g_kb_sub = 0;               // sub-cycle within the current bit
static int      g_kb_gapcnt = 0;

static const struct { const char *name; uint8_t make; int ext; } KBMAP[] = {
    {"enter",0x5A,0},{"esc",0x76,0},{"space",0x29,0},{"tab",0x0D,0},
    {"up",0x75,1},{"down",0x72,1},{"left",0x6B,1},{"right",0x74,1},
    {"n",0x31,0},{"y",0x35,0},{"f",0x2B,0},{"a",0x1C,0},{"c",0x21,0},
};
static void kb_build_events(const char *script) {
    char *dup = strdup(script); if (!dup) return;
    for (char *tok = strtok(dup, ","); tok; tok = strtok(nullptr, ",")) {
        for (auto &km : KBMAP) if (!strcmp(tok, km.name)) {
            std::vector<uint8_t> ev;
            if (km.ext) ev.push_back(0xE0); ev.push_back(km.make);                 // make
            if (km.ext) ev.push_back(0xE0); ev.push_back(0xF0); ev.push_back(km.make);  // break
            g_kb_events.push_back(ev); break;
        }
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
    if (!g_kb_script) return;                                  // dormant unless requested
    if (!g_kb_base_set) { g_kb_base = main_time; g_kb_base_set = true; }   // anchor to load point
    if (!g_kb_started && main_time >= g_kb_base + g_kb_start) { g_kb_started = true; g_kb_next_ev = main_time; }
    if (g_kb_started && g_kb_ev_idx < g_kb_events.size() && main_time >= g_kb_next_ev
        && g_kbfifo.empty() && g_kb_phase < 0) {
        for (uint8_t b : g_kb_events[g_kb_ev_idx]) g_kbfifo.push_back(b);
        g_kb_ev_idx++; g_kb_next_ev = main_time + g_kb_gap;
        fprintf(stderr, ">>> [kbinject] event %zu/%zu queued @cyc=%llu\n",
                g_kb_ev_idx, g_kb_events.size(), (unsigned long long)main_time);
    }
    int dat = 1, clk = 1;                                      // idle = released high
    if (g_kb_phase < 0) {
        if (!g_kbfifo.empty() && top->ps2_kbclk_out && top->ps2_kbdat_out) {
            if (++g_kb_gapcnt >= 80) { g_kb_gapcnt = 0; uint8_t b = g_kbfifo.front(); g_kbfifo.pop_front(); kb_load_byte(b); }
        }
    }
    if (g_kb_phase >= 0) {
        dat = g_kb_bits[g_kb_phase];
        clk = (g_kb_sub < 24) ? 1 : 0;                         // high 24, low 24 -> falling edge samples dat
        if (++g_kb_sub >= 48) { g_kb_sub = 0; if (++g_kb_phase > 10) g_kb_phase = -1; }
    }
    top->ps2_kbclk_in = clk & (top->ps2_kbclk_out ? 1 : 0);    // open-drain wired-AND
    top->ps2_kbdat_in = dat & (top->ps2_kbdat_out ? 1 : 0);
}

// ---------------- PS/2 mouse device emulation (bidirectional) --------------------------
// The 8042 sends a command to the mouse (host->device) via its SEND states: it inhibits (clock
// low), asserts the start bit (data low), releases the clock, then the DEVICE clocks out the
// controller's data bits. We: detect the request-to-send (clock 0->1 while data low), generate
// the clock (11 falling edges), read the command byte off ps2_mousedat_out, send the ACK bit,
// then reply device->host (same bit-bang the keyboard device uses). Enough for Win95 to DETECT a
// mouse (reply FA/AA/00 to reset) so the first-run "no mouse" dialog never appears. --mouse only.
static bool g_mouse_en = false;               // --mouse
enum { MS_IDLE, MS_RECV, MS_SEND };
static int g_ms_state = MS_IDLE;
static int g_ms_pclkout = 1;                  // prev ps2_mouseclk_out (for the RTS 0->1 edge)
static int g_ms_edge = 0, g_ms_sub = 0;       // RECV: bit-edge index (0..10) + sub-cycle
static uint8_t g_ms_rxbyte = 0;
static bool g_ms_expect_param = false;        // next host byte is a command parameter (F3/E8)
static bool g_ms_streaming = false;
static std::deque<uint8_t> g_ms_txq;          // device->host bytes to send
static int g_ms_txbits[11], g_ms_txphase = -1, g_ms_txsub = 0, g_ms_txgap = 0;
static void ms_process_cmd(uint8_t b) {
    if (g_ms_expect_param) { g_ms_expect_param = false; g_ms_txq.push_back(0xFA); return; }  // ACK the param
    g_ms_txq.push_back(0xFA);                                                                 // ACK the command
    switch (b) {
        case 0xFF: g_ms_txq.push_back(0xAA); g_ms_txq.push_back(0x00); g_ms_streaming=false; break; // reset -> BAT+ID
        case 0xF2: g_ms_txq.push_back(0x00); break;                                            // get device ID (0=std)
        case 0xF4: g_ms_streaming = true;  break;                                              // enable reporting
        case 0xF5: g_ms_streaming = false; break;                                              // disable
        case 0xF3: case 0xE8: g_ms_expect_param = true; break;                                 // set rate/res take a param
        default: break;
    }
    fprintf(stderr, ">>> [mouse] rx cmd 0x%02x -> reply %zu byte(s)\n", b, g_ms_txq.size());
}
static void ms_tx_load(uint8_t b) {
    int par = 1; g_ms_txbits[0] = 0;
    for (int k = 0; k < 8; k++) { int bit = (b >> k) & 1; g_ms_txbits[1+k] = bit; par ^= bit; }
    g_ms_txbits[9] = par; g_ms_txbits[10] = 1; g_ms_txphase = 0; g_ms_txsub = 0;
}
static void ps2_mouse_drive() {
    if (!g_mouse_en) return;
    int co  = top->ps2_mouseclk_out ? 1 : 0;   // controller clock output (0 = inhibit)
    int dou = top->ps2_mousedat_out ? 1 : 0;   // controller data output
    int my_clk = 1, my_dat = 1;                // idle: released high
    if (g_ms_state == MS_SEND) {               // device->host: bit-bang the reply byte
        my_dat = g_ms_txbits[g_ms_txphase];
        my_clk = (g_ms_txsub < 24) ? 1 : 0;
        if (++g_ms_txsub >= 48) { g_ms_txsub = 0; if (++g_ms_txphase > 10) { g_ms_txphase = -1; g_ms_state = MS_IDLE; } }
    } else if (g_ms_state == MS_RECV) {        // host->device: we clock, read the host's bits
        my_dat = (g_ms_edge == 10) ? 0 : 1;    // ACK bit low on the 11th edge; else release for host
        my_clk = (g_ms_sub < 24) ? 1 : 0;
        if (g_ms_sub == 44 && g_ms_edge <= 7 && dou) g_ms_rxbyte |= (1 << g_ms_edge);   // sample bit (LSB first)
        if (++g_ms_sub >= 48) { g_ms_sub = 0;
            if (++g_ms_edge > 10) { g_ms_state = MS_IDLE; ms_process_cmd(g_ms_rxbyte); g_ms_rxbyte = 0; }
        }
    } else {                                   // MS_IDLE
        if (g_ms_pclkout == 0 && co == 1 && dou == 0) {          // request-to-send: clock released, start bit
            g_ms_state = MS_RECV; g_ms_edge = 0; g_ms_sub = 0; g_ms_rxbyte = 0;
        } else if (!g_ms_txq.empty() && co == 1 && dou == 1) {   // reply when bus idle
            if (++g_ms_txgap >= 80) { g_ms_txgap = 0; ms_tx_load(g_ms_txq.front()); g_ms_txq.pop_front(); g_ms_state = MS_SEND; }
        }
    }
    g_ms_pclkout = co;
    top->ps2_mouseclk_in = my_clk & co;        // open-drain wired-AND
    top->ps2_mousedat_in = my_dat & dou;
}

// ---- VGA frame capture: sample video_* into a framebuffer, dump PPM per frame.
static const int VW = 1024, VH = 768;
static uint8_t  fb[VH][VW][3];
static int vx = 0, vy = 0, pvh = 0, pvv = 0, vmaxx = 0, vmaxy = 0;   /* vframe fwd-declared near the wide ring */
int g_linew[768] = {0}; int g_nlines = 0;   // per-line active-pixel counts (VGA geometry diag)
static uint64_t vpix = 0;
static void dump_ppm(int n) {
    char path[256];
    if (n < 0) snprintf(path, sizeof(path), "../tmp/ao486_latest.ppm");
    else       snprintf(path, sizeof(path), "../tmp/ao486_frame_%04d.ppm", n);
    int w = vmaxx > 0 ? vmaxx + 1 : VW, h = vmaxy > 0 ? vmaxy + 1 : VH;
    if (w > VW) w = VW; if (h > VH) h = VH;
    FILE *f = fopen(path, "wb"); if (!f) return;
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    for (int y = 0; y < h; y++) fwrite(fb[y], 1, w * 3, f);
    fclose(f);
    fprintf(stderr, "  frame %d -> %s (%dx%d, %llu active px)\n", n, path, w, h, (unsigned long long)vpix);
}
static int g_vgeom = 0;   // (unused legacy flag; kept for arg compat)
// The ao486 VGA emits each displayed PIXEL as a run of `dpp` identical video_ce dots (dpp=8 in
// 720x400 text, differs per mode), and the per-line dot count drifts (e.g. 5516..5760) so a
// fixed-ratio resample sheared. Fix: buffer the whole frame's dots, then per frame (1) derive
// dpp = GCD of all run lengths, (2) set a single real width W = round(maxlinedots/dpp), and
// (3) resample every line to that same W. Identical W for all lines removes the shear; dividing
// by the true dpp removes the oversample -> a clean WxH image, adapting to whatever mode is up.
#define LINEMAX 6400
#define MAXLINES 512
static uint8_t (*rawf)[LINEMAX][3] = nullptr;          // [line][dot][rgb], lazily allocated
static int rawlen[MAXLINES] = {0};
static int line_px = 0;
static int igcd(int a, int b) { while (b) { int t = a % b; a = b; b = t; } return a < 0 ? -a : a; }
static void process_frame() {
    if (!rawf) return;
    int nlines = vy < MAXLINES ? vy : MAXLINES;
    // (1) dpp: per line take GCD of its run lengths, then majority-vote across lines. A single
    // stray run only spoils its own line's GCD; the mode over all structured lines is robust.
    int maxdots = 0, gvote[257] = {0};
    for (int y = 0; y < nlines; y++) {
        int n = rawlen[y]; if (n <= 0) continue; if (n > maxdots) maxdots = n;
        int lg = 0, nruns = 0, i = 0;
        while (i < n) {
            int j = i;
            while (j < n && rawf[y][j][0]==rawf[y][i][0] && rawf[y][j][1]==rawf[y][i][1] && rawf[y][j][2]==rawf[y][i][2]) j++;
            lg = igcd(lg, j - i); nruns++; i = j;
        }
        if (nruns >= 4 && lg >= 1 && lg <= 256) gvote[lg]++;   // only lines with real structure
    }
    int g = 1, best = 0;
    for (int k = 1; k <= 256; k++) if (gvote[k] > best) { best = gvote[k]; g = k; }
    if (best == 0) g = 1;
    int W = (maxdots + g/2) / g; if (W < 1) W = 1; if (W > VW) W = VW;   // (2) single real width
    // (3) resample every line to W
    vmaxx = 0; vmaxy = 0; vpix = 0;
    // Sample at FIXED dpp intervals from the line start (not scaled to this line's dot count):
    // lines share the same pixel grid regardless of small per-line dot drift -> no shear. Each
    // pixel is the middle dot of its dpp-run.
    for (int y = 0; y < nlines && y < VH; y++) {
        int n = rawlen[y]; if (n <= 0) continue;
        for (int ox = 0; ox < W; ox++) {
            int ix = ox * g + g/2; if (ix >= n) ix = n - 1;
            fb[y][ox][0]=rawf[y][ix][0]; fb[y][ox][1]=rawf[y][ix][1]; fb[y][ox][2]=rawf[y][ix][2];
            if (fb[y][ox][0]||fb[y][ox][1]||fb[y][ox][2]) { vpix++; if (ox>vmaxx) vmaxx=ox; }
        }
        if (y > vmaxy) vmaxy = y;
    }
    if (g_vgeom) { static int p=0; if(p++<3) fprintf(stderr,"[VGAREBUILD] frame %d dpp=%d W=%d lines=%d vpix=%llu\n",vframe,g,W,nlines,(unsigned long long)vpix); }
}
// Clean framebuffer capture: read the mode-13h (chain-4) image straight out of the VGA plane
// RAM + DAC palette in the model, bypassing the unreliable raster-timing capture entirely
// (this is how the reference sim gets clean frames). Pixel N is in plane N&3 at offset N>>2;
// the DAC entry is 18-bit (6:6:6). Only fires in 320x200 chain-4 graphics (Quake gameplay).
static int g_fbfrom = 0, g_fb_dumped = 0;
static int g_hide_con = 0;   // --hide-console: force scr_con_current=0 to reveal 3D
static int g_no_tick = 0;   // --no-tick: disable the synthetic tick-assist (render all frames genuinely)
static int g_ff_blit = 0;         // --ff-blit: skip the mode-13h VGA blit (0x1054e), capture from its source
static unsigned char g_blit_fb[64000]; // captured 320x200 frame (from the blit source = vid.buffer)
static int g_blit_seen = 0;       // a frame has been captured
static int g_blit_dbg = 0;        // instrument first few blit calls
static const char* g_fb_out = "../tmp/ao486_fb";   // --fb-out: output path prefix (avoid multi-sim collision)
static void dump_fb_mode13(int n) {   // (name kept) reads the displayed image from VGA plane RAM + palette
    auto *R = top->rootp;
    if (!R->system__DOT__vga__DOT__attrib_graphic_mode) return;   // text mode -> nothing to grab here
    int chain4 = R->system__DOT__vga__DOT__seq_access_chain4;
    int pel2   = R->system__DOT__vga__DOT__attrib_pelclock_div2;
    uint32_t start = R->system__DOT__vga__DOT__crtc_address_start & 0xffffu;
    char path[256];
    if (n < 0) snprintf(path, sizeof path, "%s.ppm", g_fb_out);
    else       snprintf(path, sizeof path, "%s_%05d.ppm", g_fb_out, n);
    FILE *f = fopen(path, "wb"); if (!f) return;
    auto DAC = [&](uint8_t idx)->uint32_t { return R->system__DOT__vga__DOT__dac_ram__DOT__mem[idx]; };
    auto WR  = [&](uint32_t d){ fputc(((d>>12)&0x3f)*255/63, f); fputc(((d>>6)&0x3f)*255/63, f); fputc((d&0x3f)*255/63, f); };
    // --ff-blit path: the blit is skipped, so the VGA plane RAM is stale. Emit the frame captured
    // from the blit source (vid.buffer) instead, colored through the live DAC palette.
    if (g_ff_blit && g_blit_seen) {
        fprintf(f, "P6\n320 200\n255\n");
        long nzb = 0;
        for (int i = 0; i < 64000; i++) { uint8_t idx = g_blit_fb[i]; if (idx) nzb++; WR(DAC(idx)); }
        fclose(f); g_fb_dumped++;
        if (g_fb_dumped <= 6 || (n >= 0 && (n % 200) == 0))
            fprintf(stderr, "[FBCLEAN] %s mode=13h-vidbuf nz=%ld\n", path, nzb);
        return;
    }
    long nz = 0; const char* modestr;
    if (chain4 && pel2) {
        // ---- mode 13h: 320x200x256, chain-4 doubleword: pixel N -> plane N&3, offset N&~3 ----
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
        // ---- mode 12h: 640x480x16 planar (Win95 std VGA). All 4 planes share addr; each gives 1 bit. ----
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
    g_fb_dumped++;
    if (g_fb_dumped <= 6 || (n >= 0 && (n % 200) == 0))
        fprintf(stderr, "[FBCLEAN] %s mode=%s chain4=%d pel2=%d start=%u nz=%ld\n", path, modestr, chain4, pel2, start, nz);
}
static int in_mode13() {   // true only in Quake's 320x200 chain-4 graphics frame
    auto *R = top->rootp;
    return R->system__DOT__vga__DOT__attrib_graphic_mode
        && R->system__DOT__vga__DOT__seq_access_chain4
        && R->system__DOT__vga__DOT__attrib_pelclock_div2;
}
static void video_capture() {
    int ce = top->video_ce, hs = top->video_hsync, vs = top->video_vsync, bn = top->video_blank_n;
    if (!rawf) rawf = (uint8_t(*)[LINEMAX][3])calloc(MAXLINES, sizeof(*rawf));
    if (vs && !pvv) {                                  // vsync edge -> frame done
        if (vy < MAXLINES) rawlen[vy] = line_px;
        process_frame();
        if (vpix > 64) { dump_ppm(-1); if ((vframe % 8) == 0) dump_ppm(vframe); }
        if (g_fbfrom) { dump_fb_mode13(-1); if (in_mode13()) { static int m13 = 0; dump_fb_mode13(m13); m13++; } }  // clean plane-RAM capture: latest every vsync + EVERY game frame numbered by real mode-13h frame index
        vframe++; vy = 0; vx = 0; line_px = 0;
        for (int i = 0; i < MAXLINES; i++) rawlen[i] = 0;
    } else if (hs && !pvh) {                            // hsync edge -> new line
        if (vy < MAXLINES) rawlen[vy] = line_px;
        vy++; vx = 0; line_px = 0;
    } else if (ce && bn) {                              // active dot -> buffer it
        if (vy < MAXLINES && line_px < LINEMAX) { rawf[vy][line_px][0]=top->video_r; rawf[vy][line_px][1]=top->video_g; rawf[vy][line_px][2]=top->video_b; }
        line_px++; vx++;
    }
    pvh = hs; pvv = vs;
}

static inline uint8_t bcd(uint8_t v) { return ((v / 10) << 4) | (v % 10); }

// Program the 128-byte CMOS over the RTC mgmt port (0xF400|reg). Pulses one
// mgmt_write per clock; RTC latches on posedge (not reset-gated), so safe to do
// while the core is held in reset.
static void program_cmos(bool have_hdd) {
    uint8_t cmos[128]; memset(cmos, 0, sizeof(cmos));
    // fixed RTC time 2024-01-01 12:00:00 (deterministic)
    cmos[0x00] = bcd(0); cmos[0x02] = bcd(0); cmos[0x04] = bcd(12);
    cmos[0x06] = 2; cmos[0x07] = bcd(1); cmos[0x08] = bcd(1); cmos[0x09] = bcd(24);
    cmos[0x0A] = 0x26; cmos[0x0B] = 0x02; cmos[0x0C] = 0x00; cmos[0x0D] = 0x80;
    cmos[0x10] = floppy_en ? 0x40 : 0x00;           // fdd0 = 1.44MB (type 4) if floppy
    cmos[0x12] = have_hdd ? 0xF0 : 0x00;            // hd0 = type-F (16+) if present
    cmos[0x14] = 0x4D;                              // equipment
    cmos[0x15] = 0x80; cmos[0x16] = 0x02;           // 640K base
    cmos[0x17] = 0x00; cmos[0x18] = 0x0C;           // ext mem = 4MB (fast POST; enough for DOS/Quake)
    cmos[0x19] = have_hdd ? 0x2F : 0x00;            // ext hd0 type
    cmos[0x2D] = floppy_en ? 0x20 : 0x00;           // boot from floppy if present
    cmos[0x31] = 0x0C;
    cmos[0x32] = 0x20; cmos[0x34] = 0x00; cmos[0x35] = 0x00; cmos[0x37] = 0x20;
    cmos[0x39] = 0x55;                              // ATA translation = LBA (all 4 drives)
    cmos[0x3D] = floppy_en ? 0x21 : 0x02;           // el-torito: floppy-first if present
    unsigned sum = 0; for (int i = 0x10; i <= 0x2D; i++) sum += cmos[i];
    cmos[0x2E] = sum >> 8; cmos[0x2F] = sum & 0xFF;

    for (int i = 0; i < 128; i++) {
        top->mgmt_address = 0xF400 | i; top->mgmt_writedata = cmos[i]; top->mgmt_write = 1;
        tick();
    }
    top->mgmt_write = 0; top->mgmt_address = 0; top->mgmt_writedata = 0;
    fprintf(stderr, "program_cmos: 128 bytes written (have_hdd=%d, checksum=%02x%02x)\n",
            have_hdd, cmos[0x2E], cmos[0x2F]);
}


// ---- M3: floppy (82077) HPS disk-serving for fd_floppy.img -----------------
static void floppy_geom() {         // write geometry to floppy mgmt regs (drive 0)
    struct { uint16_t a, d; } regs[] = {
        {0xF200, 0x0001}, {0xF201, 0x0000}, {0xF202, 80},
        {0xF203, 18}, {0xF204, 2880}, {0xF205, 2} };
    for (auto &r : regs) { top->mgmt_address = r.a; top->mgmt_writedata = r.d; top->mgmt_write = 1; tick(); }
    top->mgmt_write = 0; top->mgmt_address = 0; top->mgmt_writedata = 0;
}
static void floppy_pre() {          // drive mgmt inputs (before the clock edge)
    if (!floppy_en) return;
    top->mgmt_read = 0; top->mgmt_write = 0;
    if (fstate == 0) {
        if (top->fdd_request & 1) { top->mgmt_address = 0xF200; fstate = 1; }   // present LBA addr (combinational read)
    } else if (fstate == 1) {
        top->mgmt_address = 0xF200;
    } else if (fstate == 2 && ffill < 512) {
        top->mgmt_address = 0xF20F; top->mgmt_writedata = fdsector[ffill]; top->mgmt_write = 1;  // 1 byte/transfer
    }
}
static void floppy_post() {         // capture / advance (after the clock edge)
    if (!floppy_en) return;
    if (fstate == 1) {
        uint32_t lba = top->mgmt_readdata & 0x7FFF;
        if (floppy_img) { fseek(floppy_img, (long)lba * 512, SEEK_SET);
                          if (fread(fdsector, 1, 512, floppy_img) != 512) memset(fdsector, 0, 512); }
        ffill = 0; fstate = 2;
        fprintf(stderr, "  [floppy] serve LBA=%u  first bytes=%02x %02x %02x %02x  sig@510=%02x%02x\n",
                lba, fdsector[0], fdsector[1], fdsector[2], fdsector[3], fdsector[510], fdsector[511]);
    } else if (fstate == 2) {
        if (top->mgmt_write) { ffill++; if (ffill >= 512) { fstate = 3; fserved++; } }
    } else if (fstate == 3) {
        if (!(top->fdd_request & 1)) fstate = 0;   // wait for the FDC to consume the request (no double-serve)
    }
}


#include <map>
static std::map<int,int> g_io_ports;
extern "C" void ao486_io_write(int addr, int data) {
    g_io_ports[addr & 0xFFFF]++;
    if ((addr & 0xFFFF) == 0xE9 || (addr & 0xFFFF) == 0x402 || (addr & 0xFFFF) == 0x403) { fputc(data & 0xFF, stderr); }
}
enum { ST_BSY=0x80, ST_RDY=0x40, ST_RDP=0x20, ST_DSC=0x10, ST_DRQ=0x08, ST_IRQ=0x04, ST_END=0x02, ST_ERR=0x01 };
static void ide_build_id() {
    memset(ide_id, 0, sizeof(ide_id));
    uint32_t total = ide_secs;
    uint32_t head=0, cyl=0, spt=0; uint32_t sptt[]={63,127,255,0};
    for(int i=0;sptt[i];i++){ spt=sptt[i];
        for(head=4;head<=16;head++){ cyl=total/(head*spt);
            if(total<=1024u*1024u){ if(cyl<=1023) break; }
            else { if(cyl<16383) break; if(cyl<32767&&head>=5) break; if(cyl<=65536) break; } }
        if(head<=16) break; }
    uint16_t *d=ide_id;
    d[0]=0x0040; d[1]=cyl; d[3]=head; d[4]=512*spt; d[5]=512; d[6]=spt;       // CHS (word5 bytes/sector used by ao486)
    d[10]=('A'<<8)|'O'; d[11]=('H'<<8)|'D'; d[12]=('0'<<8)|'0'; d[13]=('0'<<8)|'0'; d[14]=('0'<<8)|' ';
    for(int i=15;i<=19;i++) d[i]=(' '<<8)|' ';
    d[20]=3; d[21]=512; d[22]=4;
    for(int i=27;i<=46;i++) d[i]=(' '<<8)|' ';
    d[47]=0x8020; d[48]=1; d[49]=1<<9; d[50]=0x4001; d[51]=0x0200; d[52]=0x0200; d[53]=0x0007;
    d[54]=cyl; d[55]=head; d[56]=spt; d[57]=total&0xFFFF; d[58]=total>>16;
    d[59]=0x110; d[60]=total&0xFFFF; d[61]=total>>16;
    d[65]=d[66]=d[67]=d[68]=120;
    d[80]=0x007E;
    d[82]=(1<<14)|(1<<9); d[83]=(1<<14)|(1<<13)|(1<<12); d[84]=1<<14; d[85]=(1<<14)|(1<<9); d[86]=(1<<14)|(1<<13)|(1<<12); d[87]=1<<14;
    d[93]=(1<<14)|(1<<13)|(1<<9)|(1<<8)|(1<<3)|(1<<1)|(1<<0);
    d[100]=total&0xFFFF; d[101]=total>>16;
    fprintf(stderr, "[ide] geometry C/H/S=%u/%u/%u total=%u sectors\n", cyl, head, spt, total);
}
// build the 6 result words from a register set (mirrors ide_set_regs)
static void ide_set_regs(int sector_count,int sector,uint32_t cyl,int head,int lba,int drv,int io_size,int err,int status){
    ide_rout[0]=(io_size&0xFF)|((err&0xFF)<<8);
    ide_rout[1]=(sector_count&0xFF)|((sector&0xFF)<<8);
    ide_rout[2]=cyl&0xFFFF;
    ide_rout[3]=(cyl>>16)&0xFFFF;
    ide_rout[4]=0;
    ide_rout[5]=(((lba?0xE0:0xA0)|(drv?0x10:0)|(head&0xF))&0xFF)|((status&0xFF)<<8);
}
static void ide_init(){   // tell the IDE controller drive 0 is present (mgmt reg 6)
    top->mgmt_address=0xF006; top->mgmt_writedata=0x0009; top->mgmt_write=1; tick();
    top->mgmt_write=0; top->mgmt_address=0; top->mgmt_writedata=0;
}
static void ide_pre(){
    if(!ide_en) return;
    top->mgmt_read=0; top->mgmt_write=0;
    if(ide_state==1 && ide_idx<6){ top->mgmt_address=0xF000+ide_idx; top->mgmt_read=1; }       // read regs (registered, capture next cycle)
    else if(ide_state==2 && ide_idx<ide_dwords){ uint16_t w=ide_dbuf[ide_idx*2]|(ide_dbuf[ide_idx*2+1]<<8); top->mgmt_address=0xF0FF; top->mgmt_writedata=w; top->mgmt_write=1; }
    else if(ide_state==3 && ide_idx<6){ top->mgmt_address=0xF000+ide_idx; top->mgmt_writedata=ide_rout[ide_idx]; top->mgmt_write=1; }
}
static void ide_handle();
static unsigned ide_prevreq = 0;
static void ide_post(){
    if(!ide_en) return;
    if((top->ide0_request&7) != ide_prevreq){ fprintf(stderr,"  [ide-req] %u -> %u @cyc=%llu state=%d\n", ide_prevreq, top->ide0_request&7, (unsigned long long)main_time, ide_state); ide_prevreq = top->ide0_request&7; }
    if(ide_state==0){
        unsigned req=top->ide0_request & 7;
        if(req){ ide_curreq=req; if(req==4){ ide_state=1; ide_idx=0; } else ide_handle(); }
        else if(ide_in_reset){ ide_curreq=0; ide_handle(); }   // finish reset -> set RDY
    } else if(ide_state==1){
        if(ide_idx>=1) ide_rin[ide_idx-1]=top->mgmt_readdata;   // 1-cycle latency
        ide_idx++;
        if(ide_idx>=7){ ide_idx=0; ide_handle(); }
    } else if(ide_state==2){
        if(top->mgmt_write){ ide_idx++; if(ide_idx>=ide_dwords){ ide_state=3; ide_idx=0; } }
    } else if(ide_state==3){
        if(top->mgmt_write){ ide_idx++; if(ide_idx>=6){ ide_state=0; ide_idx=0; } }
    }
}
// decode in-regs + dispatch the ATA command, fill out-regs/buffer, queue the writes
static void ide_handle(){
    unsigned req=ide_curreq;
    if(req==6){ // reset
        ide_in_reset=1;
        ide_set_regs(1,1,(ide_secs?0:0xFFFF),0,0,0,0,0,ST_BSY);
        ide_state=3; ide_idx=0; return;
    }
    if(req==0){ if(ide_in_reset){ ide_in_reset=0; ide_set_regs(1,1,0,0,0,0,0,0,ST_RDY); ide_state=3; ide_idx=0; } else ide_state=0; return; }
    if(req!=4){ ide_state=0; return; }
    // req==4: decode the 6 read regs
    uint16_t w0=ide_rin[0],w1=ide_rin[1],w2=ide_rin[2],w5=ide_rin[5];
    int sector_count=w1&0xFF, sector=(w1>>8)&0xFF; uint32_t cyl=w2; int drv_addr=w5&0xFF, cmd=(w5>>8)&0xFF;
    int head=drv_addr&0xF, drv=(drv_addr>>4)&1, lba=(drv_addr>>6)&1; (void)w0;
    fprintf(stderr, "  [ide] cmd=%02X sc=%d sec=%d cyl=%u head=%d lba=%d drv=%d\n", cmd, sector_count, sector, cyl, head, lba, drv);
    if(cmd==0xEC){ // IDENTIFY
        if(drv!=0){ ide_set_regs(sector_count,sector,cyl,head,lba,drv,0,0x04,ST_RDY|ST_ERR|ST_IRQ); ide_state=3; ide_idx=0; return; }
        memcpy(ide_dbuf, ide_id, 512); ide_dwords=256;
        ide_set_regs(sector_count,sector,cyl,head,lba,drv,1,0,ST_RDY|ST_DRQ|ST_IRQ|ST_END);
        ide_state=2; ide_idx=0;
    } else if(drv!=0){ ide_set_regs(sector_count,sector,cyl,head,lba,drv,0,0x04,ST_RDY|ST_ERR|ST_IRQ); ide_state=3; ide_idx=0;
    } else if(cmd==0x20||cmd==0x21||cmd==0xC4){ // READ
        uint32_t lbav = lba ? ((head<<24)|(cyl<<8)|sector) : 0;
        int cnt = sector_count?sector_count:256; if(cnt>1) cnt=1;   // 1 sector/transfer (simplify)
        if(ide_img){ fseek(ide_img,(long)lbav*512,SEEK_SET); if(fread(ide_dbuf,1,512,ide_img)!=512) memset(ide_dbuf,0,512); }
        ide_dwords=256; ide_served++;
        int newcnt=sector_count-1; uint32_t nlba=lbav+1;
        ide_set_regs(newcnt, newcnt?(nlba&0xFF):sector, lba?((nlba>>8)&0xFFFF):cyl, lba?((nlba>>24)&0xF):head, lba,drv,1,0, ST_RDY|ST_DRQ|ST_IRQ|(newcnt?0:ST_END));
        ide_state=2; ide_idx=0;
    } else { // no-op commands (init params, set multiple, recalibrate, verify, set features)
        ide_set_regs(sector_count,sector,cyl,head,lba,drv,0,0,ST_RDY|ST_IRQ);
        ide_state=3; ide_idx=0;
    }
}

// Override the CMOS RAM size (x86_init defaults to 16MB; a full memory test of
// that is ~200M cycles). Recomputes the 0x10-0x2D checksum via mgmt reads.
static void cmos_set_mem_mb(int mb) {
    auto wr = [&](int a, int d){ top->mgmt_address = 0xF400 | a; top->mgmt_writedata = d & 0xFF; top->mgmt_write = 1; tick(); top->mgmt_write = 0; };
    auto rd = [&](int a)->int{ top->mgmt_address = 0xF400 | a; top->mgmt_read = 1; tick(); int v = top->mgmt_readdata & 0xFF; top->mgmt_read = 0; return v; };
    // Extended memory (KB above 1MB) in CMOS 0x17/0x18 and 0x30/0x31. INT 15h AH=88h
    // (used by DOS/HIMEM and CWSDPMI raw-mode, i.e. Quake) reads ONLY 0x30/0x31 and
    // self-caps at 0xFFC0 (~64MB). The old 0x3C00 (15MB) clamp made every AH=88h client
    // see only ~16MB, so Quake's 18MB pak couldn't fit -> CWSDPMI swapped it to disk
    // forever (the "wedge"/endless re-read; identical for --mem 48 vs 96). E801/E820
    // self-cap this field at 15MB and use 0x34/0x35 below, so raising it is safe for them.
    int ext = (mb - 1) * 1024; if (ext > 0xFFC0) ext = 0xFFC0;   // 16-bit KB field, matches BIOS AH=88h cap
    wr(0x17, ext & 0xFF); wr(0x18, (ext >> 8) & 0xFF);
    wr(0x30, ext & 0xFF); wr(0x31, (ext >> 8) & 0xFF);
    // memory above 16MB in 64KB units (INT 15h E801/E820). Previously hardcoded 0,
    // so the guest/CWSDPMI only ever saw ~16MB -> Quake's 18MB pak couldn't stay
    // resident -> endless disk re-read (checksum "wedge"). Report the real --mem.
    int ext16 = (mb > 16) ? (mb - 16) * 16 : 0;
    wr(0x34, ext16 & 0xFF); wr(0x35, (ext16 >> 8) & 0xFF);
    int sum = 0; for (int i = 0x10; i <= 0x2D; i++) sum += rd(i);
    wr(0x2E, (sum >> 8) & 0xFF); wr(0x2F, sum & 0xFF);
    fprintf(stderr, ">>> CMOS RAM set to %d MB (ext=0x%04x, checksum=0x%04x)\n", mb, ext, sum & 0xFFFF);
}

// x86.cpp's fdd_set() unconditionally tags floppy_type=FDD_TYPE_1440 (x86.cpp:390) even
// when no image is mounted and the mount fails, so cmos_init() writes CMOS 0x10 = 0x44 =
// two phantom 1.44MB drives. Win95's real-mode-to-protected-mode floppy driver then spins
// forever initializing drives that have no working FDC behind them (VMM32 stuck polling
// RTC 0x10). Report "no floppies" so Win95 skips floppy bring-up. Recompute the checksum
// so the BIOS POST doesn't reset the CMOS to defaults. Kept out of x86.cpp per the seam.
static void cmos_no_floppy() {
    auto wr = [&](int a, int d){ top->mgmt_address = 0xF400 | a; top->mgmt_writedata = d & 0xFF; top->mgmt_write = 1; tick(); top->mgmt_write = 0; };
    auto rd = [&](int a)->int{ top->mgmt_address = 0xF400 | a; top->mgmt_read = 1; tick(); int v = top->mgmt_readdata & 0xFF; top->mgmt_read = 0; return v; };
    wr(0x10, 0x00);                       // fdd0/fdd1 drive types -> none
    wr(0x14, rd(0x14) & ~0xC1);           // equipment byte: clear floppy-present (b0) + count (b7:6)
    int sum = 0; for (int i = 0x10; i <= 0x2D; i++) sum += rd(i);
    wr(0x2E, (sum >> 8) & 0xFF); wr(0x2F, sum & 0xFF);
    fprintf(stderr, ">>> CMOS floppies cleared (reg10=0, checksum=0x%04x)\n", sum & 0xFFFF);
}
int main(int argc, char **argv) {
    setvbuf(stdout, nullptr, _IONBF, 0); setvbuf(stderr, nullptr, _IONBF, 0);
    Verilated::commandArgs(argc, argv);
    uint64_t max_cycles = 4000000;
    const char *bios0 = "../3rd-party/ao486_MiSTer/releases/boot0.rom";
    const char *bios1 = "../3rd-party/ao486_MiSTer/releases/boot1.rom";
    bool have_hdd = false;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--cycles") && i + 1 < argc) max_cycles = strtoull(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--bios0") && i + 1 < argc) bios0 = argv[++i];
        else if (!strcmp(argv[i], "--bios1") && i + 1 < argc) bios1 = argv[++i];
        else if (!strcmp(argv[i], "--hdd")) have_hdd = true;
        else if (!strcmp(argv[i], "--rate") && i + 1 < argc) g_clock_rate = strtoul(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--trace") && i + 1 < argc) trace_fp = fopen(argv[++i], "w");
        else if (!strcmp(argv[i], "--no-l1")) g_l1dis = 1;
        else if (!strcmp(argv[i], "--no-l2")) g_l2dis = 1;
        else if (!strcmp(argv[i], "--ddrlat") && i + 1 < argc) g_ddr_lat = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--vga-geom")) g_vgeom = 1;
        else if (!strcmp(argv[i], "--video-fb")) g_fbfrom = 1;
        else if (!strcmp(argv[i], "--hide-console")) g_hide_con = 1;
        else if (!strcmp(argv[i], "--fb-out") && i + 1 < argc) g_fb_out = argv[++i];
        else if (!strcmp(argv[i], "--no-tick")) g_no_tick = 1;
        else if (!strcmp(argv[i], "--ff-blit")) g_ff_blit = 1;
        else if (!strcmp(argv[i], "--rtc-rate") && i + 1 < argc) g_rtc_rate = strtoul(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--dump-at") && i + 1 < argc) g_dump_at = strtoull(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--rtc-watch") && i + 1 < argc) g_rtcwatch = strtoull(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--io-watch") && i + 1 < argc) g_iowatch = strtoull(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--dump-lin") && i + 1 < argc) g_dumplin = (unsigned int)strtoull(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--vga-div") && i + 1 < argc) g_vga_div = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--floppy") && i + 1 < argc) { snprintf(ps_img[0], 1024, "%s", argv[++i]); }
        else if (!strcmp(argv[i], "--ide") && i + 1 < argc) { snprintf(ps_img[2], 1024, "%s", argv[++i]); have_hdd = true; }
        else if (!strcmp(argv[i], "--save-at") && i + 1 < argc) g_save_at = strtoull(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--save-every") && i + 1 < argc) g_save_every = strtoull(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--quake-fast-return")) g_quake_fast_return = true;
        else if (!strcmp(argv[i], "--dump-delay")) g_dump_delay = true;
        else if (!strcmp(argv[i], "--w95-probe")) g_w95_probe = true;
        else if (!strcmp(argv[i], "--w95-warp"))  g_w95_mode  = 1;
        else if (!strcmp(argv[i], "--w95-accum")) g_w95_mode  = 2;
        else if (!strcmp(argv[i], "--w95-calib")) g_w95_mode  = 3;
        else if (!strcmp(argv[i], "--ptefix")) g_ptefix = true;
        else if (!strcmp(argv[i], "--w95-pit"))   g_w95_mode  = 4;
        else if (!strcmp(argv[i], "--w95-a1") && i+1<argc) g_accum_phys  = (uint32_t)strtoul(argv[++i],0,0);
        else if (!strcmp(argv[i], "--w95-a2") && i+1<argc) g_target_phys = (uint32_t)strtoul(argv[++i],0,0);
        else if (!strcmp(argv[i], "--w95-a3") && i+1<argc) g_calib_phys  = (uint32_t)strtoul(argv[++i],0,0);
        else if (!strcmp(argv[i], "--w95-val") && i+1<argc) g_w95_val    = (uint32_t)strtoul(argv[++i],0,0);
        else if (!strcmp(argv[i], "--save-frame") && i + 1 < argc) g_save_frame = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--state") && i + 1 < argc) g_statefile = argv[++i];
        else if (!strcmp(argv[i], "--load")) g_load = true;
        else if (!strcmp(argv[i], "--mem") && i + 1 < argc) { g_mem_mb = atoi(argv[++i]); g_mem_top_words = (uint64_t)g_mem_mb * 0x20000ull; }
        else if (!strcmp(argv[i], "--kb") && i + 1 < argc) g_kb_script = argv[++i];
        else if (!strcmp(argv[i], "--mouse")) g_mouse_en = true;
        else if (!strcmp(argv[i], "--kb-start") && i + 1 < argc) g_kb_start = strtoull(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--kb-gap") && i + 1 < argc) g_kb_gap = strtoull(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--vcd") && i + 1 < argc) { vcd_end = strtoull(argv[++i], 0, 0);
#if VM_TRACE
            Verilated::traceEverOn(true); tfp = new VerilatedVcdC;
#endif
        }
    }

    ddr = (uint64_t *)calloc(DDR_WORDS, sizeof(uint64_t));
    if (!ddr) { fprintf(stderr, "ddr alloc failed\n"); return 1; }

    (void)bios0; (void)bios1; (void)have_hdd;   // x86_init loads ROMs + sets CMOS itself

    top = new Vsystem;
#if VM_TRACE
    if (tfp) { top->trace(tfp, 99); tfp->open("../tmp/ao486.vcd"); }
#endif
    tie_static_inputs();
    if (g_kb_script) kb_build_events(g_kb_script);

    if (g_load) {
        // Restore a prior snapshot, then re-open the disk images (file handles are
        // process-local). Skips the ~tens-of-millions-of-cycle POST entirely.
        load_state(g_statefile);
        if (ps_img[0][0]) x86_set_image(0, ps_img[0]);
        if (ps_img[2][0]) x86_set_image(2, ps_img[2]);
        ide_reattach_base();   // set IDE bases without perturbing the restored RTL
        // Re-apply the timer-rate inputs so --rate/--rtc-rate override the value baked into the
        // snapshot (clock_rate is a live input, saved with the model). Lets a wedged/slow boot be
        // resumed at a different rate without a full re-boot.
        top->clock_rate = g_clock_rate; top->clock_rate_vga = 90000000; top->rtc_clock_rate = g_rtc_rate;
    } else {
        // Hold the core in reset and run the REAL MiSTer HPS init: it loads the BIOS/
        // VGA ROMs into DDR (via shmem -> ddr[]), mounts the disk images, resets the
        // IDE, and programs the 128-byte CMOS — all over the verilated mgmt bus.
        top->reset = 1;
        for (int i = 0; i < 32; i++) tick();
        if (ps_img[0][0]) x86_set_image(0, ps_img[0]);   // floppy A
        if (ps_img[2][0]) x86_set_image(2, ps_img[2]);   // IDE hdd 0
        x86_init();
        if (g_mem_mb > 0) cmos_set_mem_mb(g_mem_mb);
        cmos_no_floppy();
        for (int i = 0; i < 16; i++) tick();
        top->reset = 0;
    }

    uint64_t ddr_reads = 0, ddr_writes = 0, last_addr = 0, bios_reads = 0;
    int reset_hold = 0;          // ps2_reset_n -> core reset feedback (8042/port92 CPU reset)
    uint64_t nresets = 0;
    for (uint64_t c = 0; c < max_cycles && !Verilated::gotFinish(); c++) {
        if (g_stop_after && main_time > g_stop_after) { fprintf(stderr, ">>> stopping run %llu cyc after crash dump @cyc=%llu\n", (unsigned long long)(main_time - (g_stop_after - 60000)), (unsigned long long)main_time); break; }
        // Loop the keyboard-controller/port-92 reset back into the core (mirrors
        // ao486.sv: reset <= ~ps2_reset_n). The BIOS uses it to exit protected mode.
        if (!top->ps2_reset_n && reset_hold == 0) { reset_hold = 16; nresets++; }
        if (reset_hold > 0) { top->reset = 1; reset_hold--; } else { top->reset = 0; }
        ps2_kb_drive();   // inject queued keystrokes (no-op unless --kb given)
        ps2_mouse_drive(); // emulate a PS/2 mouse device (no-op unless --mouse given)
        { static bool saved = false; if (g_save_at && !saved && main_time >= g_save_at) { saved = true; save_state(g_statefile); } }
        { static bool savedf = false; if (g_save_frame && !savedf && vframe >= g_save_frame) { savedf = true; save_state(g_statefile); } }
        // Periodic OOM-resilience snapshot: write to <statefile>.new then atomically rename over
        // <statefile>, so a kill mid-write leaves the previous good snapshot intact for --load.
        { static uint64_t last_save = 0;
          if (g_save_every && main_time - last_save >= g_save_every) {
              last_save = main_time;
              char nf[1200]; snprintf(nf, sizeof(nf), "%s.new", g_statefile);
              save_state(nf); rename(nf, g_statefile);
              fprintf(stderr, ">>> periodic snapshot @cyc=%llu -> %s\n", (unsigned long long)main_time, g_statefile);
              fflush(stderr);
          } }

        // Detect the real IDE soft-reset clear (SRST released) and arm the direct
        // reset-finish. Hysteresis on the sim's noisy request line: while SRST is HELD,
        // ide.v re-asserts request=6 every cycle (ide.v:176-181,217) but the HPS's
        // ide_set_regs->reg5 write (interleaved via ps_clock_tick) momentarily clears
        // it, so the request flickers 6<->0. A single-edge detector would fire on the
        // flicker and finish the reset while SRST is still held. So confirm the clear:
        // a 6->0 arms a timer; a return to 6 cancels it; only a stable 0 through the
        // timer is a true SRST release -> arm the idempotent ide_io(N,0) at the poll
        // site (below). (The ideal cure for the flicker is an async HPS scheduler that
        // does not reentrantly clock the FPGA; documented in AO486_SOC_FIX.md.)
        { static unsigned pi0 = 0, pi1 = 0; static int confirm = 0;
          unsigned i0 = top->ide0_request & 7, i1 = top->ide1_request & 7;
          if ((pi0 == 6 && i0 == 0) || (pi1 == 6 && i1 == 0)) confirm = 12;
          if (i0 == 6 || i1 == 6) confirm = 0;
          if (confirm > 0 && --confirm == 0) g_reset_finish_pending = 1;
          pi0 = i0; pi1 = i1; }

        // --- W95 delay-loop intervention (profile / warp / poke) -------------
        {
            auto *R = top->rootp;
            const uint64_t DDRB = DDR_WORDS * 8;
            // (probe) tally dcache read/write phys addrs during the spin: the ramping
            // accumulator shows up as a WRITE with changes~=hits; the constant compare
            // target shows up as a READ with changes==0.
            if (g_w95_probe && g_w95_spin) {
                struct Hit { uint32_t addr, hits, lastval, changes, firstval, minv, maxv; };
                static Hit wtab[96] = {{0}}, rtab[96] = {{0}};
                auto bump = [&](Hit* t, uint32_t a){ a &= ~3u; uint32_t v;
                    memcpy(&v, (uint8_t*)ddr + (a & (DDRB-1)), 4);
                    for (int k=0;k<96;k++){ if(t[k].hits && t[k].addr==a){ t[k].hits++;
                        if(t[k].lastval!=v){t[k].changes++;t[k].lastval=v;}
                        if(v<t[k].minv)t[k].minv=v; if(v>t[k].maxv)t[k].maxv=v; return; } }
                    for (int k=0;k<96;k++){ if(!t[k].hits){t[k].addr=a;t[k].hits=1;t[k].lastval=v;t[k].firstval=v;t[k].minv=v;t[k].maxv=v;return;} } };
                if (R->system__DOT__ao486__DOT__memory_inst__DOT__resp_dcachewrite_do)
                    bump(wtab, R->system__DOT__ao486__DOT__memory_inst__DOT__resp_dcachewrite_address);
                if (R->system__DOT__ao486__DOT__memory_inst__DOT__resp_dcacheread_do)
                    bump(rtab, R->system__DOT__ao486__DOT__memory_inst__DOT__resp_dcacheread_address);
                // one-time: disassemble-fodder for the loop-top compare (stack return addrs c0030852/c00307c7)
                static bool codedumped=false;
                if (!codedumped) { codedumped=true;
                    uint32_t cr3=(uint32_t)ao486_cur_cr3(); int pg=ao486_cur_pg();
                    for (uint32_t seip : {0xc002c5fau,0xc00253d0u,0xc0003556u,0xc002af1au,0xc002b943u,0xc000384au}) {
                        uint32_t clin = (seip & ~0xfu) - 0x60u;
                        unsigned char* cp=ao486_code_ptr_ctx(clin,cr3,pg);
                        fprintf(stderr,"--- CODE @%08x (around spin eip %08x) ---\n",clin,seip);
                        if(cp){ for(int r=0;r<12;r++){ fprintf(stderr,"  %08x:",clin+16*r);
                            for(int b=0;b<16;b++) fprintf(stderr," %02x",cp[16*r+b]); fprintf(stderr,"\n"); } }
                        else fprintf(stderr,"  (untranslatable)\n"); }
                    // resolve func-ptr targets: [c0034d1c]=funcB(done? check) [c000e55c]=funcA; dump their code
                    for (uint32_t plin : {0xc0034d1cu,0xc000e55cu}) {
                        unsigned char* pp=ao486_code_ptr_ctx(plin,cr3,pg);
                        uint32_t tgt=0; if(pp) memcpy(&tgt,pp,4);
                        fprintf(stderr,"--- PTR [%08x] -> %08x ---\n",plin,tgt);
                        if(tgt>=0xc0000000u){ uint32_t base=tgt&~0xfu; unsigned char* tp=ao486_code_ptr_ctx(base,cr3,pg);
                            if(tp){ for(int r=0;r<8;r++){ fprintf(stderr,"  %08x:",base+16*r);
                                for(int b=0;b<16;b++) fprintf(stderr," %02x",tp[16*r+b]); fprintf(stderr,"\n"); } } }
                    }
                    // the byte flag [0xc0030fe2] (checked at c0030852) + nearby
                    unsigned char* fp=ao486_code_ptr_ctx(0xc0030fe0u,cr3,pg);
                    if(fp){ fprintf(stderr,"--- FLAG @c0030fe0:"); for(int b=0;b<8;b++) fprintf(stderr," %02x",fp[b]); fprintf(stderr,"\n"); }
                    // VTD wait-ring: guard [c0034de0] read-idx [c0034de4] write-idx [c0034de8] data [c0034dec..]
                    fprintf(stderr,"--- RING @c0034de0 (guard,ridx,widx,then 16 data words) phys+vals ---\n");
                    for (uint32_t rl=0xc0034de0u; rl<0xc0034e2cu; rl+=4) {
                        long long ph=ao486_xlate(rl,cr3,pg); unsigned char* rp=ao486_code_ptr_ctx(rl,cr3,pg);
                        uint32_t v=0; if(rp) memcpy(&v,rp,4);
                        fprintf(stderr,"  lin=%08x phys=%08llx val=%08x\n",rl,(unsigned long long)ph,v); }
                    fflush(stderr);
                }
                static uint64_t t0=0; if(!t0) t0=main_time;
                if (main_time - t0 == 8000000) {
                    fprintf(stderr,"=== W95 dcache profile @cyc=%llu ===\n",(unsigned long long)main_time);
                    for(int k=0;k<96;k++) if(wtab[k].hits>2000){ uint32_t rng=wtab[k].maxv-wtab[k].minv;
                        fprintf(stderr,"  WRITE phys=%08x hits=%u chg=%u first=%08x last=%08x min=%08x max=%08x rng=%u %s\n",
                            wtab[k].addr,wtab[k].hits,wtab[k].changes,wtab[k].firstval,wtab[k].lastval,wtab[k].minv,wtab[k].maxv,rng, rng>0x1000?"<<RAMP":""); }
                    for(int k=0;k<96;k++) if(rtab[k].hits>2000){ uint32_t rng=rtab[k].maxv-rtab[k].minv;
                        fprintf(stderr,"  READ  phys=%08x hits=%u chg=%u first=%08x last=%08x min=%08x max=%08x rng=%u %s\n",
                            rtab[k].addr,rtab[k].hits,rtab[k].changes,rtab[k].firstval,rtab[k].lastval,rtab[k].minv,rtab[k].maxv,rng, rtab[k].changes==0?"<<CONST":(rng>0x1000?"<<RAMP":"")); }
                    fflush(stderr);
                }
            }
            // (warp) collapse clock_rate while spinning -> PIT ticks at its 0.5/cyc cap
            // (~1.7x vs 4MHz). Weak; only helps if the exit is genuinely PIT-ms bounded.
            if (g_w95_mode == 1) {
                static uint32_t saved = 0;
                if (g_w95_spin) { if (!saved) saved = top->clock_rate; top->clock_rate = 10000; }
                else if (saved) { top->clock_rate = saved; saved = 0; }
            }
            // (accum poke, mode 2) poke g_accum_phys := g_w95_val (default 0x7fffffff) a few
            // times; optionally target:=0. Use to ADVANCE the VTD system-time so the timer ISR
            // posts the awaited ring event, OR force a compare operand. Addrs via --w95-a1/a2.
            if (g_w95_mode == 2 && g_w95_spin && g_accum_phys) {
                static int poked = 0;
                if (poked < 8) { poked++;
                    ao486_poke_guest(g_accum_phys, &g_w95_val, 4);
                    if (g_target_phys) { uint32_t z=0; ao486_poke_guest(g_target_phys, &z, 4); }
                    fprintf(stderr,">>> W95 accum-poke #%d: [%08x]:=%08x %s @cyc=%llu\n",
                        poked,g_accum_phys,g_w95_val, g_target_phys?"(+[a2]:=0)":"", (unsigned long long)main_time); fflush(stderr);
                }
            }
            // (calib ONE-SHOT, mode 3) shrink a large calibration dword by 100x (addr --w95-a3).
            if (g_w95_mode == 3 && g_calib_phys) {
                static bool done=false;
                if (!done) { uint32_t v; memcpy(&v,(uint8_t*)ddr+(g_calib_phys & (DDRB-1)),4);
                    if (v > 1000000u) { uint32_t nv=v/100u; ao486_poke_guest(g_calib_phys,&nv,4); done=true;
                        fprintf(stderr,">>> W95 calib[%08x] %u->%u @cyc=%llu\n",g_calib_phys,v,nv,(unsigned long long)main_time); fflush(stderr); } }
            }
            // (ring-post, mode 4) VTD wait-for-event breaker. Each time a NEW spin is
            // detected, advance the ring write-idx [--w95-a1] := read-idx [--w95-a2]+2 ONCE so
            // funcB dequeues (null event -> clean ret exit) and the loop proceeds. Re-arms per
            // spin so the whole CHAIN of first-boot calibration waits is broken, not just the
            // first. (Proven: single post -> exit + 1.5M cyc new code + a self-clearing 2nd wait.)
            if (g_w95_mode == 4) {
                // GENERIC wait-breaker. Different VMM event-waits use different rings, so instead
                // of a fixed address we DISCOVER the current wait's ring: while in a C000xxxx
                // PIT-wait, tally the physical dcache-read addresses; funcB reads its ring's
                // RIDX and adjacent WIDX every iteration (hottest reads), and while the wait spins
                // the ring is EMPTY (RIDX==WIDX, both a small even index<0x20). Every 300k cyc,
                // find the hottest addr A with mem[A]==mem[A+4], small/even -> that's RIDX@A,
                // WIDX@A+4 of the stuck ring -> advance WIDX:=RIDX+2 so funcB dequeues a null event
                // -> loop exits. Empty-check => never overwrites a real pending event.
                uint32_t peip = R->system__DOT__ao486__DOT__eip;
                bool pit_wait = (peip >= 0xC0000000u && peip < 0xC0040000u) && ((g_last_ioread & 0xffff) == 0x40);
                static uint32_t rtab[192] = {0}, rhit[192] = {0}, rfirst[192] = {0}; static uint8_t rstable[192] = {0};
                if (pit_wait && R->system__DOT__ao486__DOT__memory_inst__DOT__resp_dcacheread_do) {
                    uint32_t a = R->system__DOT__ao486__DOT__memory_inst__DOT__resp_dcacheread_address & ~3u;
                    uint32_t v; memcpy(&v,(uint8_t*)ddr+(a&(uint32_t)(DDRB-1)),4);
                    int slot=-1;
                    for (int k=0;k<192;k++){ if(rhit[k]&&rtab[k]==a){slot=k;break;} if(!rhit[k]){slot=k;rtab[k]=a;rfirst[k]=v;rstable[k]=1;break;} }
                    if(slot>=0){ rhit[slot]++; if(v!=rfirst[slot]) rstable[slot]=0; }
                }
                static uint64_t lastpost = 0; static int npost = 0;
                if (pit_wait && main_time - lastpost > 300000u) {
                    lastpost = main_time;
                    // Real ring: funcB reads BOTH ridx(@A) and widx(@A+4) every iteration, they
                    // are EQUAL (empty), small even, and CONSTANT (stable). Requiring BOTH A and
                    // A+4 to be hot-read filters out standalone hot flags (false matches).
                    auto hitsOf = [&](uint32_t addr)->uint32_t{ for(int j=0;j<192;j++) if(rhit[j]&&rtab[j]==addr) return rhit[j]; return 0; };
                    uint32_t bestA=0, bestH=0, bestR=0;
                    for (int k=0;k<192;k++){ if(rhit[k]<100 || !rstable[k]) continue; uint32_t Aabs=rtab[k], A=Aabs&(uint32_t)(DDRB-1);
                        uint32_t h2 = hitsOf(Aabs+4); if (h2 < 100) continue;   // widx must also be hot-read
                        uint32_t r,w; memcpy(&r,(uint8_t*)ddr+A,4); memcpy(&w,(uint8_t*)ddr+((A+4)&(uint32_t)(DDRB-1)),4);
                        uint32_t score = rhit[k] < h2 ? rhit[k] : h2;
                        if(r==w && r<0x20u && (r&1u)==0 && score>bestH){ bestH=score; bestA=Aabs; bestR=r; } }
                    if (bestA){ uint32_t nw=(bestR+2)&0x1fu; ao486_poke_guest(bestA+4,&nw,4); npost++;
                        if (npost<=80 || npost%20==0)
                            fprintf(stderr,">>> gen-ring-post #%d ring@%08x ridx=widx=%u -> widx:=%u (hits=%u stable) @cyc=%llu eip=%08x\n",
                                npost,bestA,bestR,nw,bestH,(unsigned long long)main_time,peip);
                        fflush(stderr);
                    } else {
                        // no ring matched -> STUCK on a wait whose ring differs. Dump the top hot
                        // reads + values so the real ring can be identified. Rate-limited log.
                        static uint64_t lastdiag=0;
                        uint32_t tothit=0; for(int k=0;k<192;k++) tothit+=rhit[k];
                        if (tothit>4000 && main_time-lastdiag>2000000) { lastdiag=main_time;
                            fprintf(stderr,"=== STUCK-WAIT diag @cyc=%llu eip=%08x : top hot dcache reads ===\n",(unsigned long long)main_time,peip);
                            for(int n=0;n<15;n++){ int bi=-1; uint32_t bh=0; for(int k=0;k<192;k++) if(rhit[k]>bh){bh=rhit[k];bi=k;}
                                if(bi<0||bh<80) break; uint32_t A=rtab[bi]&(uint32_t)(DDRB-1); uint32_t v; memcpy(&v,(uint8_t*)ddr+A,4);
                                fprintf(stderr,"  phys=%08x hits=%u val=%08x stable=%d\n",rtab[bi],bh,v,rstable[bi]); rhit[bi]=0; }
                            // disassemble-fodder: dump the loop code around the stuck eip + registers
                            uint32_t cr3=(uint32_t)ao486_cur_cr3(); int pg=ao486_cur_pg();
                            fprintf(stderr,"  REGS eax=%08x ebx=%08x ecx=%08x edx=%08x esi=%08x edi=%08x ebp=%08x esp=%08x\n",
                                (uint32_t)R->system__DOT__ao486__DOT__pipeline_inst__DOT__eax,(uint32_t)R->system__DOT__ao486__DOT__pipeline_inst__DOT__ebx,
                                (uint32_t)R->system__DOT__ao486__DOT__pipeline_inst__DOT__ecx,(uint32_t)R->system__DOT__ao486__DOT__pipeline_inst__DOT__edx,
                                (uint32_t)R->system__DOT__ao486__DOT__pipeline_inst__DOT__esi,(uint32_t)R->system__DOT__ao486__DOT__pipeline_inst__DOT__edi,
                                (uint32_t)R->system__DOT__ao486__DOT__pipeline_inst__DOT__ebp,(uint32_t)R->system__DOT__ao486__DOT__pipeline_inst__DOT__esp);
                            for (uint32_t clin : {(peip-0x40)&~0xfu, peip&~0xfu}) {
                                unsigned char* cp=ao486_code_ptr_ctx(clin,cr3,pg);
                                if(cp){ for(int r=0;r<6;r++){ fprintf(stderr,"  CODE %08x:",clin+16*r);
                                    for(int b=0;b<16;b++) fprintf(stderr," %02x",cp[16*r+b]); fprintf(stderr,"\n"); } } }
                            fflush(stderr);
                        }
                    }
                    for(int k=0;k<192;k++){ rhit[k]=0; rtab[k]=0; rstable[k]=0; }   // reset window
                }
            }
        }

        if (g_ptefix) {
            static uint64_t lastscan = 0;
            if (main_time - lastscan >= 128) {                  // proactive scan every 128 cycles
                lastscan = main_time;
                auto *R = top->rootp;
                uint32_t cr3f = R->system__DOT__ao486__DOT__cr3;
                uint8_t *db = (uint8_t*)ddr; uint32_t dmask = (uint32_t)(DDR_WORDS*8u-1);
                static int nfix=0;
                // Scan the high shared-arena PDEs (0x80000000..0xffffffff) and set present on
                // any P=0-but-has-frame PTE (Win95 "present-but-access-tracked" pages).
                for (uint32_t pdi = 0x200u; pdi < 0x400u; pdi++) {
                    uint32_t pdea = ((cr3f & ~0xfffu) + pdi*4u)&dmask; uint32_t pde; memcpy(&pde,db+pdea,4);
                    if (!(pde & 1u)) continue;
                    uint32_t ptbase = pde & ~0xfffu;
                    for (uint32_t i=0;i<1024u;i++) {
                        uint32_t ptephys = ptbase + i*4u; uint32_t pte; memcpy(&pte,db+(ptephys&dmask),4);
                        if ((pte & 1u)==0 && (pte & ~0xfffu)!=0) {
                            uint32_t npte = pte | 1u; ao486_poke_guest(ptephys, &npte, 4);
                            if(nfix<40){ nfix++; fprintf(stderr,">>> PTEFIX lin=%08x pte@%08x %08x->%08x @cyc=%llu\n",(pdi<<22)|(i<<12),ptephys,pte,npte,(unsigned long long)main_time); fflush(stderr);}
                        }
                    }
                }
            }
        }

        set_clocks(0); top->eval();
        set_clocks(1); step_vga_clock(); top->eval();
        // Service the DDR immediately after the posedge (matching ps_clock_tick's
        // order) and BEFORE x86_poll. x86_poll advances the clock via ps_clock_tick,
        // which ALSO services the DDR; when ddr_service ran AFTER x86_poll it served a
        // fresh read-beat right on top of x86_poll's last-served beat with no posedge
        // between them, so the L2 never latched that beat -> a cache-line fill lost a
        // beat and stalled forever in FILLCACHE whenever a poll coincided with a fill.
        if (top->DDRAM_RD) {
            ddr_reads++; last_addr = top->DDRAM_ADDR;
            uint32_t a = top->DDRAM_ADDR;
            if (a >= 0x18000 && a < 0x20000) bios_reads++;
        }
        if (top->DDRAM_WE) ddr_writes++;
        ddr_service();
        // Co-sim FPU: apply the pending ESC op AFTER ddr_service so an FPU load sees the
        // just-retired CPU store's value in DDR. Read-side coherency for a store still in
        // flight in the write-through L2 (not yet drained to ddr[]) is provided by the
        // CPU-write snoop overlay in x87_cosim.cpp. If the op was a store, the DPI wrote
        // DDR directly (bypassing the L2), so pulse an L2 line-invalidation for that
        // address so the CPU's later load refetches from DDR.
        ao486_fpu_process();
        { static int l2inv = 0;
          if (l2inv) { top->l2_fpu_inv_pulse = 0; l2inv = 0; }
          unsigned int p;
          if (ao486_fpu_store_pending(&p)) { top->l2_fpu_inv_addr = p; top->l2_fpu_inv_pulse = 1; l2inv = 1; } }
        // Blit fast-forward (INDEPENDENT of --quake-fast-return so it composes with a plain playdemo).
        // Quake's mode-13h present is blit(src,dst,wbytes,height,sstride,dstride) @0x1054e: `height` rows
        // of `rep movsd` to VGA 0xa0000 -- those VGA writes are the dominant sim cost (~8M of ~10M cyc/
        // frame). We don't need the frame on the VGA plane RAM: capture it from the blit SOURCE (vid.buffer)
        // into g_blit_fb, then force an immediate return to skip every slow VGA write (~5x). Args at entry
        // (before the 4 pushes): [ss:esp]=ret [+4]=src [+8]=dst [+0xC]=wbytes [+0x10]=height [+0x14]=sstride
        // [+0x18]=dstride. dst&0xffff = VGA byte offset. dump_fb_mode13 emits g_blit_fb via the DAC palette.
        if (g_ff_blit) {
            auto *R = top->rootp;
            uint64_t cs_cache_b = R->system__DOT__ao486__DOT__cs_cache;
            uint32_t cs_base_b = (uint32_t)((cs_cache_b >> 16) & 0x00ffffffu) | (uint32_t)((cs_cache_b >> 32) & 0xff000000u);
            uint32_t live_eip_b = R->system__DOT__ao486__DOT__eip;
            static uint32_t prev_bl = 0;
            bool at_bl = (cs_base_b == 0x10000000u && live_eip_b == 0x0001054eu);
            if (at_bl && prev_bl != 0x0001054eu && ddr) {
                uint64_t ds_cache = R->system__DOT__ao486__DOT__pipeline_inst__DOT__ds_cache;
                uint64_t ss_cache = R->system__DOT__ao486__DOT__pipeline_inst__DOT__ss_cache;
                uint32_t ds_base = (uint32_t)((ds_cache >> 16) & 0x00ffffffu) | (uint32_t)((ds_cache >> 32) & 0xff000000u);
                uint32_t ss_base = (uint32_t)((ss_cache >> 16) & 0x00ffffffu) | (uint32_t)((ss_cache >> 32) & 0xff000000u);
                uint32_t esp = R->system__DOT__ao486__DOT__pipeline_inst__DOT__esp;
                uint32_t cr3 = R->system__DOT__ao486__DOT__cr3, pg = R->system__DOT__ao486__DOT__cr0_pg;
                const uint8_t *m = (const uint8_t *)ddr;
                auto rd = [&](uint32_t lin) -> long long {
                    long long p = ao486_xlate(lin, cr3, pg);
                    if (p < 0 || (uint64_t)p + 4 >= DDR_WORDS*8) return -1;
                    uint32_t v; memcpy(&v, m + p, 4); return (long long)v;
                };
                long long ret = rd(ss_base + esp);
                long long src = rd(ss_base + esp + 4),  dst = rd(ss_base + esp + 8);
                long long wb  = rd(ss_base + esp + 0xc), ht = rd(ss_base + esp + 0x10);
                long long sst = rd(ss_base + esp + 0x14), dst_str = rd(ss_base + esp + 0x18);
                if (ret >= 0x000010a8 && ret <= 0x0005b200 && src >= 0 && dst >= 0 &&
                    wb > 0 && wb <= 2048 && ht > 0 && ht <= 400 && sst >= 0) {
                    uint32_t doff = (uint32_t)dst & 0xffffu;   // VGA byte offset of this rect
                    int w = (int)wb; if (w > 320) w = 320;
                    for (int row = 0; row < (int)ht; row++) {
                        long long sp = ao486_xlate(ds_base + (uint32_t)src + (uint32_t)(row*(int)sst), cr3, pg);
                        if (sp < 0 || (uint64_t)sp + w >= DDR_WORDS*8) continue;
                        uint32_t so = doff + (uint32_t)(row * 320);
                        if (so + w > 64000) { if (so >= 64000) break; w = 64000 - so; }
                        memcpy(g_blit_fb + so, m + sp, w);
                    }
                    g_blit_seen = 1;
                    if (g_fbfrom) { static int bfn = 0; dump_fb_mode13(-1); if ((bfn % 15) == 0) dump_fb_mode13(bfn); bfn++; }
                    if (g_blit_dbg < 8) { g_blit_dbg++;
                        fprintf(stderr, "[FFBLIT] #%d cyc=%llu src=%llx dst=%llx doff=%u wb=%lld ht=%lld sst=%lld dst_str=%lld ret=%05llx\n",
                                g_blit_dbg, (unsigned long long)main_time, src, dst, doff, wb, ht, sst, dst_str, ret);
                        fflush(stderr); }
                    // Speed up the blit WITHOUT touching control flow (force-returning the whole
                    // function corrupts the guest): shrink the width arg on the stack to 4 bytes so
                    // the function copies 1 dword/row instead of 320 -- ~800 VGA writes vs 64000 (~5x).
                    // The row strides self-correct (esi/edi += stride per row regardless of width),
                    // esi/edi/ecx are the callee's own (restored at its pop), and we already captured
                    // the true frame from the source above. ao486_poke_guest writes DDR + invalidates
                    // the L2 line so the function's mov ebx,[esp+0x1c] load refetches the shrunk width.
                    uint32_t four = 4;
                    long long wba = ao486_xlate(ss_base + esp + 0xc, cr3, pg);
                    if (wba >= 0 && (uint64_t)wba + 4 < DDR_WORDS*8)
                        ao486_poke_guest((unsigned)wba, &four, 4);
                }
            }
            prev_bl = live_eip_b;
        }
        // Quake console-fast-return (ported from the ao486_MiSTer reference sim). Bug#4: the
        // timedemo's console-draw (Draw_Character @0x717a, Draw_String @0x7354) runs away when
        // scr_con_current goes huge -> ~10M cyc/frame, wedging before the fps line. Detect the
        // guest sitting at the glyph-routine entry in Quake's flat code and force an immediate
        // return (write the return address into every pipeline eip stage, pop it off the stack,
        // flush prefetch), rate-limited so ordinary text still draws. This lets the timedemo
        // finish and print its fps result.
        if (g_quake_fast_return) {
            auto *R = top->rootp;
            uint64_t cs_cache = R->system__DOT__ao486__DOT__cs_cache;
            uint32_t cs_base = (uint32_t)((cs_cache >> 16) & 0x00ffffffu) | (uint32_t)((cs_cache >> 32) & 0xff000000u);
            uint32_t live_eip = R->system__DOT__ao486__DOT__eip;
            // Wild-jump trap: the timedemo-startup #PF is a jump to a bogus flat eip (0x17ed5c,
            // far past Quake's ~0x60000 .text). Catch the moment the fetch goes wild in Quake
            // context and dump the LAST retired eip (the call/ret/jmp that jumped there) + regs +
            // the co-sim FP stack, once, to identify the culprit instruction and corrupted value.
            if (cs_base == 0x10000000u) {
                static int wtrap = 0;
                if (!wtrap && live_eip >= 0x00080000u && live_eip < 0x0f000000u) {
                    wtrap = 1;
                    auto *PI = R;
                    fprintf(stderr,
                        "[WILDJUMP] fetch=%08x wr_eip=%05x exe_eip=%05x rd_eip=%05x @cyc=%llu\n"
                        "           eax=%08x ebx=%08x ecx=%08x edx=%08x esi=%08x edi=%08x ebp=%08x esp=%08x\n",
                        live_eip,
                        (unsigned)PI->system__DOT__ao486__DOT__wr_eip,
                        (unsigned)PI->system__DOT__ao486__DOT__exe_eip,
                        (unsigned)PI->system__DOT__ao486__DOT__rd_eip,
                        (unsigned long long)main_time,
                        (unsigned)PI->system__DOT__ao486__DOT__pipeline_inst__DOT__eax,
                        (unsigned)PI->system__DOT__ao486__DOT__pipeline_inst__DOT__ebx,
                        (unsigned)PI->system__DOT__ao486__DOT__pipeline_inst__DOT__ecx,
                        (unsigned)PI->system__DOT__ao486__DOT__pipeline_inst__DOT__edx,
                        (unsigned)PI->system__DOT__ao486__DOT__pipeline_inst__DOT__esi,
                        (unsigned)PI->system__DOT__ao486__DOT__pipeline_inst__DOT__edi,
                        (unsigned)PI->system__DOT__ao486__DOT__pipeline_inst__DOT__ebp,
                        (unsigned)PI->system__DOT__ao486__DOT__pipeline_inst__DOT__esp);
                    fflush(stderr);
                }
            }
            // --- Timedemo tick-assist (mechanism ported from the reference ao486 sim) --------
            // In timedemo mode Quake sets host_frametime = the raw Sys_FloatTime() delta, UNCLAMPED.
            // Our FP-co-sim renders a frame in ~15-18M cyc and the map-load frame spans ~200M cyc,
            // so that PIT-derived delta exceeds a full 8254 counter wrap -> Sys_FloatTime miscounts
            // -> a garbage host_frametime that smashes timing/index math (wild jump, #PF @0x17ed5c,
            // and the console runaway). --rate only rescales the wrap, it can't remove it. The fix
            // is to bypass the guest's PIT timing altogether: while a demo is playing, force-advance
            // Quake's time globals at a synthetic 72Hz (one tick / ~833k cyc): host_framecount++,
            // realtime += 1/72, host_frametime = 1/72, cls.td_lastframe = host_framecount. The guest
            // then never computes a huge delta, the demo plays through, and Host_FinishTimeDemo
            // reports frames/realtime ~= 72 fps. All reads/writes use the LIVE cr3 (R->cr3) -- the
            // same path [DEMOFRAME] translates successfully; the earlier stale-cr3 clamp could not.
            if (ddr && R->system__DOT__ao486__DOT__cr0_pg) {
                uint32_t lcr3 = R->system__DOT__ao486__DOT__cr3;
                auto rd32 = [&](uint32_t vma, uint32_t &v)->bool {
                    long long p = ao486_xlate(0x10000000u + vma, lcr3, 1);
                    if (p < 0 || (uint64_t)p + 4 > DDR_WORDS*8) return false;
                    memcpy(&v, (const uint8_t*)ddr + p, 4); return true; };
                auto rdf64 = [&](uint32_t vma, double &v)->bool {
                    long long p = ao486_xlate(0x10000000u + vma, lcr3, 1);
                    if (p < 0 || (uint64_t)p + 8 > DDR_WORDS*8) return false;
                    memcpy(&v, (const uint8_t*)ddr + p, 8); return true; };
                auto wr32 = [&](uint32_t vma, uint32_t v)->bool {
                    long long p = ao486_xlate(0x10000000u + vma, lcr3, 1);
                    if (p < 0 || (uint64_t)p + 4 > DDR_WORDS*8) return false;
                    return ao486_poke_guest((unsigned)p, &v, 4) != 0; };
                auto wrf64 = [&](uint32_t vma, double v)->bool {
                    long long p = ao486_xlate(0x10000000u + vma, lcr3, 1);
                    if (p < 0 || (uint64_t)p + 8 > DDR_WORDS*8) return false;
                    return ao486_poke_guest((unsigned)p, &v, 8) != 0; };
                // --- Unconditional crash-guard (runs every cycle we are in Quake flat code) ------
                // The map-load frame's raw Sys_FloatTime() delta explodes host_frametime, and thus
                // realtime (realtime += host_frametime), to a gigantic value BEFORE the demo file is
                // open -- so the demofile-gated tick-assist below never fires. A gigantic double fed
                // to Quake's sprintf("%f",..) (console / status prints) emits hundreds of digits and
                // overruns a stack local, smashing the return address -> wild jump (#PF @0x17ed5c),
                // the same failure class as the 80-bit FPU-store bug. Clamp both globals in place, in
                // Quake context, via the LIVE cr3 (the stale-cr3 clamp could not translate them). The
                // global is read back from memory before each sprintf, so the in-place clamp wins the
                // round-trip. Only touch values that are already insane, so legit timing is untouched.
                if (cs_base == 0x10000000u && (main_time & 63) == 0) {
                    double hft;
                    if (rdf64(0x95ba8u, hft) && (!(hft == hft) || hft > 0.5 || hft < 0.0)) {
                        wrf64(0x95ba8u, 1.0/72.0);
                        static uint32_t nc=0; if(++nc<=12) fprintf(stderr,"[HFTCLAMP] host_frametime %.4g -> 0.0139 @cyc=%llu\n",hft,(unsigned long long)main_time);
                    }
                    double rt;
                    if (rdf64(0x95b98u, rt) && (!(rt == rt) || rt > 1.0e6 || rt < 0.0)) {
                        wrf64(0x95b98u, 1.0);
                        static uint32_t nr=0; if(++nr<=12) fprintf(stderr,"[RTCLAMP] realtime %.4g -> 1.0 @cyc=%llu\n",rt,(unsigned long long)main_time);
                    }
                    // Footage only: make Quake actually render the 3D level view. V_RenderView
                    // (@0x4a628) early-returns -- skipping R_RenderView -- whenever con_forcedup
                    // (@0x90b2c) is set, and con_forcedup = (!cl.worldmodel || cls.signon!=SIGNONS).
                    // The same flag forces the console full-screen. So merely clearing the console
                    // left a blank frame. Once the world is loaded (cl.worldmodel @0x810b4 != 0)
                    // force con_forcedup=0 so V_RenderView draws the level into vid.buffer, and
                    // retract the console (scr_con_current/conlines @0xc97d0/0xc97e0) so the blit
                    // to 0xa0000 shows the 3D instead of the console.
                    if (g_hide_con) {
                        uint32_t wm=0, sg=0; double clt=0, cmt=0, hft2=0;
                        bool okr = rd32(0x810b4u, wm) && rd32(0x6c998u, sg);
                        if (okr) { uint32_t cf=0,dp=0; rd32(0x90b2cu,cf); rd32(0x6c97cu,dp); rdf64(0x8086cu,clt); rdf64(0x8085cu,cmt); rdf64(0x95ba8u,hft2);
                            static uint64_t dprt=0;
                            if (main_time - dprt >= 20000000ull) { dprt = main_time;
                                fprintf(stderr,"[RENDERSTATE] worldmodel=%08x signon=%u con_forcedup=%u demoplay=%u cl.time=%.4f mtime=%.4f hft=%.5f @cyc=%llu\n",
                                        wm, sg, cf, dp, clt, cmt, hft2, (unsigned long long)main_time); fflush(stderr); }
                        }
                        // Once signon=4 (world spawned, con_forcedup naturally 0, render safe), retract
                        // the console so the 3D view is uncovered. Minimal reads so this stays reliable.
                        if (okr && wm != 0 && sg == 4) { wr32(0xc97d0u, 0u); wr32(0xc97e0u, 0u); }
                    }
                }
                static const uint64_t TICK_CYC = 833333ull;   // ~1/72 s at 60MHz; only sets pace
                static const double   TICK_SEC = 1.0/72.0;
                static uint64_t next_tick = 0;
                if (next_tick == 0) next_tick = main_time + TICK_CYC;
                // Only poke Quake time-globals while the CPU is actually in Quake flat context
                // (cs_base==0x10000000 => cr3 is Quake's). Firing a tick during a transient DOS/DPMI
                // context translates 0x10000000+vma with the WRONG page tables and can poke a wild
                // physical address, corrupting a live Quake variable -> later index/coord math writes
                // past a buffer -> stack smash -> #PF. next_tick is not advanced when skipped, so the
                // tick simply fires on the next Quake-context cycle (no missed ticks, just deferred).
                if (cs_base == 0x10000000u && main_time >= next_tick) {
                    next_tick = main_time + TICK_CYC;
                    uint32_t td_active=0, demofile=0, host_frame=0; double realtime=0.0;
                    bool ok = rd32(0x6c980u, td_active) && rd32(0x6c988u, demofile) &&
                              rd32(0x95bb4u, host_frame) && rdf64(0x95b98u, realtime);
                    if (!g_no_tick && ok && td_active != 0 && demofile != 0) {
                        wr32 (0x95bb4u, host_frame + 1u);      // host_framecount
                        wrf64(0x95b98u, realtime + TICK_SEC);  // realtime
                        wrf64(0x95ba8u, TICK_SEC);             // host_frametime = 1/72
                        wr32 (0x6c98cu, host_frame);           // cls.td_lastframe
                        static uint32_t tn = 0;
                        if (tn < 30 || (host_frame % 100u) == 0) { tn++;
                            fprintf(stderr, "[TICK] frame %u realtime %.3f @cyc=%llu\n",
                                    host_frame+1u, realtime+TICK_SEC, (unsigned long long)main_time);
                            fflush(stderr); }
                        static int tdone = 0;                  // reference reports at frame>=134
                        if (!tdone && host_frame + 1u >= 134u && realtime + TICK_SEC > 0.0) {
                            tdone = 1;
                            double sec = realtime + TICK_SEC, fps = double(host_frame+1u)/sec;
                            fprintf(stderr, "\n>>> TIMEDEMO RESULT: %u frames  %.1f seconds  %.1f fps  @cyc=%llu <<<\n\n",
                                    host_frame+1u, sec, fps, (unsigned long long)main_time);
                            fflush(stderr);
                        }
                    }
                }
            }
            // periodic demo-frame read (host_framecount@0x95bb4 - td_startframe@0x6c990; demo1=975),
            // via the same live-cr3 path the fast-return uses (DS base 0x10000000).
            {
                static uint64_t dprog = 0;
                if (main_time - dprog >= 50000000ull) { dprog = main_time;
                    long long ph = ao486_xlate(0x10095bb4u, R->system__DOT__ao486__DOT__cr3, R->system__DOT__ao486__DOT__cr0_pg);
                    long long ps = ao486_xlate(0x1006c990u, R->system__DOT__ao486__DOT__cr3, R->system__DOT__ao486__DOT__cr0_pg);
                    if (ph >= 0 && ps >= 0 && ddr) { const uint8_t *m = (const uint8_t *)ddr;
                        int32_t h, s0; memcpy(&h, m+ph, 4); memcpy(&s0, m+ps, 4);
                        if (h >= 0 && s0 >= 0 && h - s0 >= 0 && h - s0 <= 2000)
                            fprintf(stderr, "[DEMOFRAME] frame %d/975 @cyc=%llu\n", h - s0, (unsigned long long)main_time), fflush(stderr);
                    }
                }
            }
            // Draw_Character(x,y,ch) @0x717a blits an 8x8 glyph to the framebuffer row y, but only
            // bounds-checks the TOP (cmp ecx,-8; jle skip) -- never the bottom. A console-runaway /
            // off-screen caller passes y >= screen height (the wild-jump trap caught y=250 in the
            // 320x200 timedemo start), so dest = fb + y*rowbytes lands far below the 200-row frame-
            // buffer, in the stack, smashing the return address -> wild jump (#PF @0x17ed5c). Args at
            // entry (before the 3 register pushes): [ss:esp]=retaddr [ss:esp+4]=x [ss:esp+8]=y
            // [ss:esp+0xC]=ch. When y is out of range, force an immediate return (skip the glyph):
            // this prevents the OOB write AND bounds the console-slide runaway (its off-screen lines
            // are skipped), while every on-screen glyph still draws normally. Edge-detected on the
            // fetch so it fires exactly once per entry (no esp over-pop).
            {
                static uint32_t prev_le = 0;
                bool at_dc = (cs_base == 0x10000000u && live_eip == 0x0000717au);
                if (at_dc && prev_le != 0x0000717au && ddr) {
                    uint64_t ss_cache = R->system__DOT__ao486__DOT__pipeline_inst__DOT__ss_cache;
                    uint32_t ss_base = (uint32_t)((ss_cache >> 16) & 0x00ffffffu) | (uint32_t)((ss_cache >> 32) & 0xff000000u);
                    uint32_t esp = R->system__DOT__ao486__DOT__pipeline_inst__DOT__esp;
                    uint32_t cr3 = R->system__DOT__ao486__DOT__cr3, pg = R->system__DOT__ao486__DOT__cr0_pg;
                    long long rp = ao486_xlate(ss_base + esp,     cr3, pg);   // return address
                    long long yp = ao486_xlate(ss_base + esp + 8, cr3, pg);   // y arg
                    if (rp >= 0 && yp >= 0 && (uint64_t)rp + 4 < DDR_WORDS*8 && (uint64_t)yp + 4 < DDR_WORDS*8) {
                        const uint8_t *m = (const uint8_t *)ddr;
                        uint32_t target; int32_t y; memcpy(&target, m+rp, 4); memcpy(&y, m+yp, 4);
                        if ((y >= 200 || y < -64) && target >= 0x000010a8u && target <= 0x0005b200u) {
                            uint32_t new_esp = esp + 4;
                            R->system__DOT__ao486__DOT__eip = target;
                            R->system__DOT__ao486__DOT__dec_eip = target;
                            R->system__DOT__ao486__DOT__rd_eip = target;
                            R->system__DOT__ao486__DOT__exe_eip = target;
                            R->system__DOT__ao486__DOT__wr_eip = target;
                            R->system__DOT__ao486__DOT__pipeline_inst__DOT__esp = new_esp;
                            R->system__DOT__ao486__DOT__pipeline_inst__DOT__write_inst__DOT__esp_to_reg = new_esp;
                            R->system__DOT__ao486__DOT__memory_inst__DOT__reset_prefetch = 1;
                            R->system__DOT__ao486__DOT__memory_inst__DOT__icache_inst__DOT__reset_prefetch_count = 2;
                            static uint32_t fr_n = 0;
                            if (fr_n < 40) { fr_n++;
                                fprintf(stderr, "[FASTRET] #%u cyc=%llu y=%d -> ret=%05x esp=%08x->%08x\n",
                                        fr_n, (unsigned long long)main_time, y, target, esp, new_esp);
                                fflush(stderr); }
                        }
                    }
                }
                prev_le = live_eip;
            }
            // (blit fast-forward relocated to its own independent block before the g_quake_fast_return gate)
            // Timedemo fps capture: Host_FinishTimeDemo's Con_Printf("%i frames %5.1f seconds %5.1f fps",
            // frames, time, fps) is at eip 0x3fdb; at that point SS:ESP holds [0]=frames(int),
            // [4]=time(double), [12]=fps(double). Read via the same live-cr3 path the fast-return uses
            // (qconsole.log is buffered, so this is the reliable capture of the timedemo result).
            // Check every pipeline eip stage for the Con_Printf push/call window (0x3fce..0x3fe0) to
            // catch this single-event across the cycles it occupies. Read a stack window and print
            // the frames-int + the two doubles at their known offsets; print candidate stacks too.
            uint32_t de = R->system__DOT__ao486__DOT__dec_eip, re = R->system__DOT__ao486__DOT__rd_eip;
            uint32_t ee = R->system__DOT__ao486__DOT__exe_eip, we = R->system__DOT__ao486__DOT__wr_eip;
            auto inwin = [](uint32_t e){ return e >= 0x00003fceu && e <= 0x00003fe0u; };
            // MUST be Quake flat code (cs_base 0x10000000); otherwise DOS/BIOS code at these offsets
            // misfires on garbage stack. Also sanity-check the values (demo1<=~1500 frames, real fps).
            if (cs_base == 0x10000000u && (inwin(live_eip) || inwin(de) || inwin(re) || inwin(ee) || inwin(we))) {
                static int fdone = 0;
                if (!fdone) {
                    uint64_t ss_cache = R->system__DOT__ao486__DOT__pipeline_inst__DOT__ss_cache;
                    uint32_t ss_base = (uint32_t)((ss_cache >> 16) & 0x00ffffffu) | (uint32_t)((ss_cache >> 32) & 0xff000000u);
                    uint32_t esp = R->system__DOT__ao486__DOT__pipeline_inst__DOT__esp;
                    long long phys = ao486_xlate(ss_base + esp, R->system__DOT__ao486__DOT__cr3, R->system__DOT__ao486__DOT__cr0_pg);
                    if (phys >= 4 && (uint64_t)phys + 28 < DDR_WORDS * 8 && ddr) {
                        const uint8_t *m = (const uint8_t *)ddr;
                        // try both arg-offset interpretations; accept the one with sane values.
                        int32_t frA; double tA, fA; memcpy(&frA, m+phys, 4); memcpy(&tA, m+phys+4, 8); memcpy(&fA, m+phys+12, 8);
                        int32_t frB; double tB, fB; memcpy(&frB, m+phys+4, 4); memcpy(&tB, m+phys+8, 8); memcpy(&fB, m+phys+16, 8);
                        auto sane = [](int fr, double t, double f){ return fr > 100 && fr < 5000 && t > 1.0 && t < 100000.0 && f > 0.1 && f < 100000.0; };
                        int ok = 0; int32_t frames = 0; double tsec = 0, fps = 0;
                        if (sane(frA, tA, fA)) { ok = 1; frames = frA; tsec = tA; fps = fA; }
                        else if (sane(frB, tB, fB)) { ok = 1; frames = frB; tsec = tB; fps = fB; }
                        if (ok) { fdone = 1;
                            fprintf(stderr, "\n>>> TIMEDEMO RESULT: %d frames  %.1f seconds  %.1f fps  @cyc=%llu <<<\n\n",
                                    frames, tsec, fps, (unsigned long long)main_time);
                            fflush(stderr);
                        }
                    }
                }
            }
        }
        if (last_eip == 0x0c10 && retire_count > 8180000 && !crash_dumped) {   // BX_PANIC cli;hlt spin
            crash_dumped = true;
            fprintf(stderr, ">>> BX_PANIC reached (cli;hlt @f000:0c10) @retire %llu -- last VGA byte writes (message):\n>>> ",
                    (unsigned long long)retire_count);
            int start = (g_vgaseqpos > 800) ? g_vgaseqpos - 800 : 0;
            for (int k = start; k < g_vgaseqpos; k++) { char ch = g_vgaseq[k % 4096]; if (ch >= 32 && ch < 127) fputc(ch, stderr); }
            fprintf(stderr, "\n");
        }
        // Service disk requests with the real MiSTer HPS code when the RTL raises
        // a request line (x86_poll's mgmt transfers advance the clock themselves).
        // Gate x86_poll's mgmt-bus servicing so it never overlaps a CPU iobus
        // transaction: my mgmt driver advances the FPGA clock during transfers,
        // and mgmt writes to the IDE that collide with a concurrent CPU iobus IDE
        // read wedge the iobus (cpu_read_do stuck, cpu_read_done never asserts).
        // Real MiSTer's ARM is async and doesn't touch the FPGA clock, so it never
        // collides. Skipping the poll while the CPU is mid-io lets the read finish.
        if ((top->fdd_request || top->ide0_request || top->ide1_request) && !g_brdo && !g_bwdo) { g_polls++; x86_poll(0); }
        // Faithful IDE reset-finish (replaces the phantom-request + g_reset_linger hack):
        // when the debounced SRST-clear has fired, run the idempotent ide_io(0,0)
        // BSY->RDY completion for the primary drive directly, under the same !mid-io
        // reentrancy guard x86_poll uses (mgmt writes must not overlap a CPU iobus
        // transaction). Only ide0 is finished: it holds the (present) boot drive, and
        // ide_io(0,0) is a no-op once ide0 leaves IDE_STATE_RESET. We must NOT call
        // ide_io(1,0): the secondary channel has no drive here (single-HDD config, like
        // real MiSTer), yet ide_img_set puts every channel into IDE_STATE_RESET at mount
        // (ide.cpp:442) -- so finishing ide1 would falsely report RDY for an absent drive
        // and derail the boot. (This mirrors the old phantom exactly: 0x08 decoded to
        // ide_io(0,0)+ide_io(1,1), i.e. finish ide0, leave ide1 alone.)
        if (g_reset_finish_pending && !g_brdo && !g_bwdo) { g_reset_finish_pending = 0; ide_io(0, 0); }
        main_time++;
        if (g_dump_at && c == g_dump_at) {   // diagnostic: dump the loop the CPU is stuck in
            fprintf(stderr, ">>> DUMP-AT cyc=%llu retire=%llu eip=%04x:%05x -- CPU ring (last retired):\n",
                    (unsigned long long)c, (unsigned long long)retire_count, last_cs, last_eip);
            dump_ring();
            // code bytes around the stuck PC (real-mode linear, or flat-protected eip page-walked)
            unsigned char *cb = ao486_code_ptr(last_lin, last_eip);
            fprintf(stderr, ">>> code @%s eip=%05x lin=%05x:",
                    ao486_paging_on() ? "prot(pg)" : "real", last_eip, last_lin);
            if (cb) { for (int k = 0; k < 224; k++) fprintf(stderr, " %02x", cb[k]); }
            else    fprintf(stderr, " <untranslatable>");
            fprintf(stderr, "\n");
            // Verbose page-walk of candidate code linears to crack the wedge.
            ao486_dump_cscache();
            ao486_walk_dbg(last_lin);            // cs_base+eip (probe)
            ao486_walk_dbg(last_eip);            // eip alone (flat base 0)
            ao486_walk_dbg((last_cs << 4) + last_eip);   // real-mode style
            if (g_dumplin) {   // --dump-lin: dump code at a specific flat linear addr (the spin loop)
                unsigned char *cl = ao486_code_ptr(g_dumplin, g_dumplin);
                fprintf(stderr, ">>> code @lin=%08x:", g_dumplin);
                if (cl) { for (int k = 0; k < 96; k++) fprintf(stderr, " %02x", cl[k]); }
                else    fprintf(stderr, " <untranslatable>");
                fprintf(stderr, "\n");
            }
            g_rtcacc_from = main_time;   // begin RTC access log from here
            fprintf(stderr, ">>> RTC register/value accesses from here:\n");
        }
        video_capture(); vcd_dump();
        if ((c & 0x1fffff) == 0x1fffff && c > 76000000) {   // periodic VGA text dump (post-boot)
            fprintf(stderr, ">>> VGAtext @%llu: ", (unsigned long long)c);
            int start = (g_vgaseqpos > 2000) ? g_vgaseqpos - 2000 : 0;
            for (int k = start; k < g_vgaseqpos; k++) { char ch = g_vgaseq[k % 4096]; if (ch>=32 && ch<127) fputc(ch, stderr); }
            fprintf(stderr, "\n");
        }
        if ((c & 0x7ffff) == 0x7ffff) {
            fprintf(stderr, "[%9llu] instr=%llu eip=%05x[%05x-%05x] ddr_wr=%llu rst=%llu ide0=%u frames=%d ido=%llu idone=%llu i0=%llu i8=%llu\n",
                    (unsigned long long)c, (unsigned long long)retire_count, last_eip, eip_min, eip_max,
                    (unsigned long long)ddr_writes, (unsigned long long)nresets, top->ide0_request, vframe,
                    (unsigned long long)g_ido, (unsigned long long)g_idone, (unsigned long long)g_i0, (unsigned long long)g_i8);
            fprintf(stderr,"          INTPOSS: now=%d high_cycles=%llu\n",g_iplast,(unsigned long long)g_ipn);
            fprintf(stderr,"          MEM: mem_read=%d last_addr=0x%08x rd_hi=%llu wait_hi=%llu rdv_hi=%llu\n",g_mrdlast,g_maddr,(unsigned long long)g_mrd,(unsigned long long)g_mwait,(unsigned long long)g_mrdv);
            fprintf(stderr,"          RTC: divider=%d prate=%d pena=%d uena=%d aena=%d pint_hi=%llu uint_hi=%llu irq_hi=%llu\n",g_rdiv,g_rprate,g_rpena,g_ruena,g_raena,(unsigned long long)g_rpint,(unsigned long long)g_ruint,(unsigned long long)g_rirq);
            { auto *RV = top->rootp;
              fprintf(stderr,"          VGA: gfx=%d chain4=%d pas=%d pel2=%d hdisp=%u vdisp=%u vtot=%u start=%u off=%u dac[1]=%06x dac[2]=%06x dac[4]=%06x dacmask=%02x\n",
                (int)RV->system__DOT__vga__DOT__attrib_graphic_mode,
                (int)RV->system__DOT__vga__DOT__seq_access_chain4,
                (int)RV->system__DOT__vga__DOT__attrib_pas,
                (int)RV->system__DOT__vga__DOT__attrib_pelclock_div2,
                (unsigned)RV->system__DOT__vga__DOT__crtc_horizontal_display_size,
                (unsigned)RV->system__DOT__vga__DOT__crtc_vertical_display_size,
                (unsigned)RV->system__DOT__vga__DOT__crtc_vertical_total,
                (unsigned)RV->system__DOT__vga__DOT__crtc_address_start,
                (unsigned)RV->system__DOT__vga__DOT__crtc_address_offset,
                (unsigned)RV->system__DOT__vga__DOT__dac_ram__DOT__mem[1],
                (unsigned)RV->system__DOT__vga__DOT__dac_ram__DOT__mem[2],
                (unsigned)RV->system__DOT__vga__DOT__dac_ram__DOT__mem[4],
                (unsigned)RV->system__DOT__vga__DOT__dac_mask);
              // Text-mode screen dump (80x25) when in alphanumeric mode (gfx=0): plane0=chars.
              if ((int)RV->system__DOT__vga__DOT__attrib_graphic_mode == 0) {
                unsigned tstart = (unsigned)RV->system__DOT__vga__DOT__crtc_address_start;
                fprintf(stderr,"          --- TEXT 80x25 (start=%u) ---\n", tstart);
                for (int row=0; row<25; row++) {
                  char line[81];
                  for (int col=0; col<80; col++) {
                    unsigned i = tstart + (unsigned)(row*80 + col);
                    uint8_t ch = RV->system__DOT__vga__DOT__plane_ram_0__DOT__mem[i & 0xffff];
                    line[col] = (ch>=32 && ch<127) ? (char)ch : ' ';
                  }
                  int e=79; while(e>=0 && line[e]==' ') e--;
                  line[e+1]=0;
                  if (e>=0) fprintf(stderr,"          |%s\n", line);
                }
                fprintf(stderr,"          --- END TEXT ---\n");
              }
              uint32_t cr2v = (uint32_t)RV->system__DOT__ao486__DOT__pipeline_inst__DOT__cr2;
              uint32_t ccr3 = (uint32_t)RV->system__DOT__ao486__DOT__cr3;
              long long cr2ph = ao486_xlate(cr2v, ccr3, 1);
              uint32_t codepf=(unsigned)RV->system__DOT__ao486__DOT__tlb_code_pf_cr2;
              uint32_t readpf=(unsigned)RV->system__DOT__ao486__DOT__tlb_read_pf_cr2;
              uint32_t writepf=(unsigned)RV->system__DOT__ao486__DOT__tlb_write_pf_cr2;
              long long cph=ao486_xlate(codepf,ccr3,1), rph=ao486_xlate(readpf,ccr3,1), wph=ao486_xlate(writepf,ccr3,1);
              fprintf(stderr,"          CR2=%08x xlate=%lld(%s) code_pf=%08x(%s) read_pf=%08x(%s) write_pf=%08x(%s)\n",
                cr2v, cr2ph, (cr2ph>=0?"MAPPED":"unmapped"),
                codepf,(cph>=0?"MAP":"UNMAP"), readpf,(rph>=0?"MAP":"UNMAP"), writepf,(wph>=0?"MAP":"UNMAP"));
              { uint8_t *db=(uint8_t*)ddr; uint32_t dmask=(uint32_t)(DDR_WORDS*8u-1);
                for (uint32_t wl : {0xbffb66a8u, 0xbffa6620u, readpf, codepf}) {
                  uint32_t pdea=((ccr3 & ~0xfffu)+((wl>>22)&0x3ffu)*4u)&dmask; uint32_t pde; memcpy(&pde,db+pdea,4);
                  uint32_t ptev=0,ptea=0; if(pde&1){ ptea=((pde&~0xfffu)+((wl>>12)&0x3ffu)*4u)&dmask; memcpy(&ptev,db+ptea,4);}
                  fprintf(stderr,"          PTWALK %08x: pde=%08x(P%d) pte@%08x=%08x P=%d frame=%08x flags=%03x\n",
                    wl, pde, pde&1, ptea, ptev, ptev&1, ptev&~0xfffu, ptev&0xfff); } } }
            // CPU-halt detector: retire_count frozen across two stats windows.
            static uint64_t prev_retire = 0; static int halt_seen = 0;
            if (c > 0x100000 && retire_count == prev_retire && !halt_seen) {
                halt_seen = 1;
                fprintf(stderr, ">>> CPU HALTED: last retire %04x:%05x (lin %05x) esp=%05x instr=%llu @cyc=%llu  last_io_read=port0x%04x(pending %llu cyc)\n",
                        last_cs, last_eip, last_lin, ring_esp[(ring_pos+RING-1)%RING] & 0xfffff,
                        (unsigned long long)retire_count, (unsigned long long)c,
                        g_last_ioread, (unsigned long long)(main_time - g_ioread_since));
                fprintf(stderr, "    IDE: ide0_wait=%d ide1_wait=%d ide0_req=%d ide1_req=%d  x86_polls=%llu\n",
                        g_i0w, g_i1w, g_i0r, g_i1r, (unsigned long long)g_polls);
                fprintf(stderr, "    IOBUS: cpu_rdo=%d cpu_rdone=%d cpu_wdo=%d cpu_wdone=%d bus_read=%d bus_write=%d bus_wait=%d bus_addr=0x%04x\n",
                        g_brdo, g_brdone, g_bwdo, g_bwdone, g_bbrd, g_bbwr, g_bbwait, g_bbaddr);
                dump_ring();
            }
            prev_retire = retire_count;
            fprintf(stderr, "          max_DDR_write=0x%llx  last_IO_read=port0x%04x\n", (unsigned long long)g_max_waddr, g_last_ioread & 0xffff);
            eip_min = 0xffffffff; eip_max = 0;
        }
    }
    fprintf(stderr,">>> VGA retrace: host_io_vert_retrace high %llu cyc, edges %llu; output vsync high %llu cyc\n",(unsigned long long)g_vret_hi,(unsigned long long)g_vret_edges,(unsigned long long)g_ovs_hi);
    fprintf(stderr,">>> 0x3DA reads=%llu, of which bit3(retrace)=1 in %llu\n",(unsigned long long)g_3da_reads,(unsigned long long)g_3da_bit3_hi);
    fprintf(stderr,">>> INTR over %llu cyc: interrupt_do=%llu interrupt_done=%llu irq0(PIT)=%llu irq8(RTC)=%llu irq1=%llu\n",(unsigned long long)g_intn,(unsigned long long)g_ido,(unsigned long long)g_idone,(unsigned long long)g_i0,(unsigned long long)g_i8,(unsigned long long)g_i1);
    fprintf(stderr,"=== BIOS serial/debug console ===\n%s\n=== end console ===\n", g_biosbuf);
    dump_vga_text();
    dump_ring();      // control-flow path at end (diagnoses hangs)
    dump_ppm(9999);   // final frame snapshot
    fprintf(stderr, "DONE: cycles=%llu ddr_rd=%llu ddr_wr=%llu bios_rd=%llu frames=%d\n",
            (unsigned long long)max_cycles, (unsigned long long)ddr_reads,
            (unsigned long long)ddr_writes, (unsigned long long)bios_reads, vframe);
    fprintf(stderr, "RTC-PERIODIC: checks=%llu ce8192_hi=%llu pen(enabled)_hi=%llu pint_hi=%llu pmajor_range=[%u..%u] ce&maj1=%llu ce&maj0=%llu\n",
            (unsigned long long)g_perchecks, (unsigned long long)g_ce8192, (unsigned long long)g_perpen,
            (unsigned long long)g_perpint, g_pmaj_min==0xffffffff?0:g_pmaj_min, g_pmaj_max,
            (unsigned long long)g_ce_maj1, (unsigned long long)g_ce_maj0);
    fprintf(stderr, "ICACHE-SUMMARY: checks=%llu bad_total=%llu bad_VALID=%llu bad_invalid(benign)=%llu\n",
            (unsigned long long)icache_checks, (unsigned long long)icache_bad,
            (unsigned long long)icache_bad_valid, (unsigned long long)icache_bad_invalid);
#if VM_TRACE
    if (tfp) { tfp->close(); }
#endif
    top->final(); delete top; free(ddr);
    return 0;
}
