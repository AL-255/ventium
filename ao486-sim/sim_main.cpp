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
#include "verilated.h"
#include "verilated_vcd_c.h"
#include "verilated_save.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <deque>

static const uint64_t DDR_WORDS = (1ull << 25);   // 256 MiB / 8
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

Vsystem  *top = nullptr;   // non-static: ps_shim.cpp drives mgmt via this
static uint64_t g_polls = 0;

// --- bridge to the real MiSTer PS software (ps/x86.cpp, ps/ide.cpp) ---
extern void x86_init();
extern void x86_poll(int only_ide);
extern void x86_set_image(int num, char *filename);
extern void x86_reattach();
extern void ide_reattach_base();
static char ps_img[6][1024] = {{0}};   // [0,1]=floppy A/B, [2..5]=IDE hdd0..3
static uint64_t g_save_at = 0;          // --save-at: snapshot at this cycle
static const char *g_statefile = "../tmp/ao486.state";
static bool g_load = false;             // --load: restore instead of POST
static int g_mem_mb = 0;                // --mem: override CMOS RAM size (0=leave x86_init default 16MB)
void ps_clock_tick();                  // defined after tick()
// After an IDE soft-reset clears (request 6->0 once ide.cpp writes reg5), the drive
// stays BSY until ide_io(0,0)/ide_io(1,0) runs its "reset finish" (sets RDY). But
// x86_poll only calls ide_io when sd_req!=0, and once ide0/ide1 clear to 0 there may
// be no other request to keep it polling (real MiSTer's floppy keeps one pending).
// So after a request drops 6->0, linger a phantom request on the OTHER channel (req
// code 1 = no-op in ide_io) so x86_poll still calls ide_io(0,0)/(1,0) to finish the reset.
int g_reset_linger = 0;                // set by main loop on a 6->0 request transition
extern "C" uint16_t ps_sd_req() {      // request bits for ide_check(), from raw RTL outputs
    uint16_t r = (uint16_t)((top->ide0_request & 7) | ((top->ide1_request & 7) << 3) | ((top->fdd_request & 3) << 6));
    if (r == 0 && g_reset_linger > 0) { g_reset_linger--; return 0x08; } // phantom ide1 req -> x86_poll still calls ide_io(0,0) (reset finish)
    return r;
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
static int g_rtion=0, g_rtidx=0;
extern "C" void ao486_rtcio(int kind,int val){ if(kind==0){g_rtidx=val&0xff;} if(g_rtion<3000){ if(kind==0)fprintf(stderr,"[RTC] index=0x%02x\n",val&0xff); else fprintf(stderr,"[RTC] read reg0x%02x -> 0x%02x\n",g_rtidx,val&0xff); g_rtion++; } }
static int g_irdn=0;
extern "C" void ao486_ideread(int addr,int data){ if(g_irdn<3000){ const char* n=(addr==0x1F7)?" [STATUS]":(addr==0x3F6)?" [ALTSTATUS]":""; fprintf(stderr,"[IDERD] port 0x%04x -> 0x%02x%s\n",addr,data&0xff,n); g_irdn++; } }
static int g_iwrn=0;
extern "C" void ao486_idewrite(int addr,int data){ if(g_iwrn<2000){ const char* n=(addr==0x3F6)?" <-- DEVCTRL/SRST":""; fprintf(stderr,"[IDEWR] port 0x%04x = 0x%02x%s\n",addr,data&0xff,n); g_iwrn++; } }
uint64_t g_vret_hi=0, g_ovs_hi=0, g_vret_edges=0; static int g_pvr=0;
extern "C" void ao486_vretrace(int vr, int ovs){ if(vr)g_vret_hi++; if(ovs)g_ovs_hi++; if(vr&&!g_pvr)g_vret_edges++; g_pvr=vr; }
extern "C" void ao486_iobus(int rdo,int rdone,int wdo,int wdone,int brd,int bwr,int bwait,int baddr){
    g_brdo=rdo;g_brdone=rdone;g_bwdo=wdo;g_bwdone=wdone;g_bbrd=brd;g_bbwr=bwr;g_bbwait=bwait;g_bbaddr=baddr; }
extern "C" void ao486_ide_state(int i0w,int i1w,int i0nd,int i1nd,int i0r,int i1r){ g_i0w=i0w;g_i1w=i1w;g_i0nd=i0nd;g_i1nd=i1nd;g_i0r=i0r;g_i1r=i1r; }
extern "C" void ao486_io_read(int addr, int pending) {
    static int pp=0;
    if (pending && !pp) { g_last_ioread = addr&0xffff; g_ioread_since = main_time; }   // read started
    pp = pending;
}
extern "C" void ao486_cpu_trace2(int cs, int eip, int esp, int eax) {
    (void)eax;
    uint32_t lin = ((uint32_t)(cs & 0xffff) << 4) + (uint32_t)eip;   // real-mode linear
    retire_count++; last_eip = eip; last_cs = cs & 0xffff; last_lin = lin;
    if ((uint32_t)eip < eip_min) eip_min = eip;
    if ((uint32_t)eip > eip_max) eip_max = eip;
    // Detect the segment corruption: CS transitions from a normal value to a
    // tiny/garbage one (the bad far-jump/iret). Dump the path that led there.
    uint32_t prev_cs = ring_cs[(ring_pos + RING - 1) % RING];
    ring_cs[ring_pos] = cs & 0xffff; ring_eip[ring_pos] = eip; ring_esp[ring_pos] = esp; ring_lin[ring_pos] = lin;
    ring_pos = (ring_pos + 1) % RING;
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
// Compare each completed icache fetch to the known BIOS bytes in DDR.
static uint64_t icache_checks = 0, icache_bad = 0;
extern "C" void ao486_icache_check(int addr, int data, int valid, int rdaddr) {
    // Compare the returned data to the line the icache ACTUALLY fetched (read_addr),
    // not the current CPU_ADDR — so abandoned speculative prefetches (CPU branched
    // mid-fetch) are not false-flagged. A mismatch HERE = a genuine cache data bug.
    uint32_t fa = (uint32_t)rdaddr & ~3u;
    if (fa < 0xC0000 || fa >= 0x100000) return;
    icache_checks++;
    uint32_t expect; memcpy(&expect, (uint8_t *)ddr + fa, 4);
    if ((uint32_t)data != expect) {
        if (icache_bad < 20)
            fprintf(stderr, "ICACHE REAL-MISMATCH fetched@0x%05x (cpu=0x%05x): got %08x expected %08x check#%llu @cyc=%llu\n",
                    fa, (uint32_t)addr & ~3u, (uint32_t)data, expect,
                    (unsigned long long)icache_checks, (unsigned long long)main_time);
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
        (void)mask8; ddr[a] = (ddr[a] & ~mask) | (din & mask);
        waddr++; if (--wrem <= 0) wburst = false;
        }
    }
    if (!rd_fifo.empty() && main_time >= rd_fifo.front().ready) {
        top->DDRAM_DOUT = rd_fifo.front().data;   // data captured at issue time
        top->DDRAM_DOUT_READY = 1; rd_fifo.pop_front();
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
static inline void step_vga_clock() { if (++g_vga_phase >= 4) { g_vga_phase = 0; top->clk_vga = !top->clk_vga; } }
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
    is >> *top;
    is.close();
    fprintf(stderr, ">>> STATE LOADED from %s @cyc=%llu instr=%llu\n", fn,
            (unsigned long long)main_time, (unsigned long long)retire_count);
}

static uint32_t g_clock_rate = 4000000;   // timer base (low => timed delays complete fast)
static int g_l1dis = 0, g_l2dis = 0;       // cache disables (debug)
static void tie_static_inputs() {
    // pit.v's divider degenerates if clk_rate(=11*clock_rate) <= INCREMENT(26.25M),
    // i.e. clock_rate <= 2.386MHz: ce fires every cycle, sum overflows, timer runs
    // wild. Clamp so a too-low --rate can't silently break the PIT/timer/interrupts.
    if (g_clock_rate < 2500000) { fprintf(stderr, "[warn] clock_rate %u too low for PIT; clamping to 4MHz\n", g_clock_rate); g_clock_rate = 4000000; }
    top->clock_rate = g_clock_rate; top->clock_rate_vga = 90000000;
    top->l1_disable = g_l1dis; top->l2_disable = g_l2dis; top->bootcfg = 0; top->uma_ram = 0;
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

// ---- VGA frame capture: sample video_* into a framebuffer, dump PPM per frame.
static const int VW = 1024, VH = 768;
static uint8_t  fb[VH][VW][3];
static int vx = 0, vy = 0, pvh = 0, pvv = 0, vframe = 0, vmaxx = 0, vmaxy = 0;
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
static void video_capture() {
    int ce = top->video_ce, hs = top->video_hsync, vs = top->video_vsync, bn = top->video_blank_n;
    if (vs && !pvv) {                                  // vsync edge -> frame done
        if (vpix > 64) { dump_ppm(-1); if ((vframe % 64) == 0) dump_ppm(vframe); }  // -1 = latest non-blank
        vframe++; vy = 0; vx = 0; vmaxx = vmaxy = 0; vpix = 0;
    } else if (hs && !pvh) {                            // hsync edge -> new line
        vy++; vx = 0;
    } else if (ce && bn) {                              // active pixel
        if (vy < VH && vx < VW) {
            fb[vy][vx][0] = top->video_r; fb[vy][vx][1] = top->video_g; fb[vy][vx][2] = top->video_b;
            if (vx > vmaxx) vmaxx = vx; if (vy > vmaxy) vmaxy = vy;
            if (top->video_r || top->video_g || top->video_b) vpix++;
        }
        vx++;
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
    int ext = (mb - 1) * 1024; if (ext > 0x3C00) ext = 0x3C00;   // KB above 1MB, 16-bit field caps at 15MB
    wr(0x17, ext & 0xFF); wr(0x18, (ext >> 8) & 0xFF);
    wr(0x30, ext & 0xFF); wr(0x31, (ext >> 8) & 0xFF);
    wr(0x34, 0); wr(0x35, 0);
    int sum = 0; for (int i = 0x10; i <= 0x2D; i++) sum += rd(i);
    wr(0x2E, (sum >> 8) & 0xFF); wr(0x2F, sum & 0xFF);
    fprintf(stderr, ">>> CMOS RAM set to %d MB (ext=0x%04x, checksum=0x%04x)\n", mb, ext, sum & 0xFFFF);
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
        else if (!strcmp(argv[i], "--floppy") && i + 1 < argc) { snprintf(ps_img[0], 1024, "%s", argv[++i]); }
        else if (!strcmp(argv[i], "--ide") && i + 1 < argc) { snprintf(ps_img[2], 1024, "%s", argv[++i]); have_hdd = true; }
        else if (!strcmp(argv[i], "--save-at") && i + 1 < argc) g_save_at = strtoull(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--state") && i + 1 < argc) g_statefile = argv[++i];
        else if (!strcmp(argv[i], "--load")) g_load = true;
        else if (!strcmp(argv[i], "--mem") && i + 1 < argc) { g_mem_mb = atoi(argv[++i]); g_mem_top_words = (uint64_t)g_mem_mb * 0x20000ull; }
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

    if (g_load) {
        // Restore a prior snapshot, then re-open the disk images (file handles are
        // process-local). Skips the ~tens-of-millions-of-cycle POST entirely.
        load_state(g_statefile);
        if (ps_img[0][0]) x86_set_image(0, ps_img[0]);
        if (ps_img[2][0]) x86_set_image(2, ps_img[2]);
        ide_reattach_base();   // set IDE bases without perturbing the restored RTL
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
        for (int i = 0; i < 16; i++) tick();
        top->reset = 0;
    }

    uint64_t ddr_reads = 0, ddr_writes = 0, last_addr = 0, bios_reads = 0;
    int reset_hold = 0;          // ps2_reset_n -> core reset feedback (8042/port92 CPU reset)
    uint64_t nresets = 0;
    for (uint64_t c = 0; c < max_cycles && !Verilated::gotFinish(); c++) {
        // Loop the keyboard-controller/port-92 reset back into the core (mirrors
        // ao486.sv: reset <= ~ps2_reset_n). The BIOS uses it to exit protected mode.
        if (!top->ps2_reset_n && reset_hold == 0) { reset_hold = 16; nresets++; }
        if (reset_hold > 0) { top->reset = 1; reset_hold--; } else { top->reset = 0; }
        { static bool saved = false; if (g_save_at && !saved && main_time >= g_save_at) { saved = true; save_state(g_statefile); } }

        // Detect the *real* IDE soft-reset clear so x86_poll runs ide_io(0,0)/(1,0)
        // (reset finish -> RDY). While SRST is HELD, ide.v re-asserts request=6 every
        // cycle and ide_set_regs clears it, so the request oscillates 6<->0 - we must
        // NOT treat that as a clear (it would flood the phantom and prematurely finish
        // the reset). Debounce: a 6->0 arms a confirm timer; if request goes back to 6
        // (still in reset) cancel it; only if it stays 0 through the timer is it a real
        // SRST clear -> linger. See ps_sd_req for the phantom that keeps ide_io running.
        { static unsigned pi0 = 0, pi1 = 0; static int confirm = 0;
          unsigned i0 = top->ide0_request & 7, i1 = top->ide1_request & 7;
          if ((pi0 == 6 && i0 == 0) || (pi1 == 6 && i1 == 0)) confirm = 12;
          if (i0 == 6 || i1 == 6) confirm = 0;
          if (confirm > 0 && --confirm == 0) g_reset_linger = 24;
          pi0 = i0; pi1 = i1; }

        set_clocks(0); top->eval();
        set_clocks(1); step_vga_clock(); top->eval();
        // Service disk requests with the real MiSTer HPS code when the RTL raises
        // a request line (x86_poll's mgmt transfers advance the clock themselves).
        // Gate x86_poll's mgmt-bus servicing so it never overlaps a CPU iobus
        // transaction: my mgmt driver advances the FPGA clock during transfers,
        // and mgmt writes to the IDE that collide with a concurrent CPU iobus IDE
        // read wedge the iobus (cpu_read_do stuck, cpu_read_done never asserts).
        // Real MiSTer's ARM is async and doesn't touch the FPGA clock, so it never
        // collides. Skipping the poll while the CPU is mid-io lets the read finish.
        if ((top->fdd_request || top->ide0_request || top->ide1_request || g_reset_linger > 0) && !g_brdo && !g_bwdo) { g_polls++; x86_poll(0); }
        if (top->DDRAM_RD) {
            ddr_reads++; last_addr = top->DDRAM_ADDR;
            uint32_t a = top->DDRAM_ADDR;
            if (a >= 0x18000 && a < 0x20000) bios_reads++;
        }
        if (top->DDRAM_WE) ddr_writes++;
        ddr_service();           // DDR response registered: applied at next edge (physical, no 0-cycle path)
        main_time++;
        video_capture(); vcd_dump();
        if ((c & 0x7ffff) == 0x7ffff) {
            fprintf(stderr, "[%9llu] instr=%llu eip=%05x[%05x-%05x] ddr_wr=%llu rst=%llu ide0=%u frames=%d ido=%llu idone=%llu i0=%llu i8=%llu\n",
                    (unsigned long long)c, (unsigned long long)retire_count, last_eip, eip_min, eip_max,
                    (unsigned long long)ddr_writes, (unsigned long long)nresets, top->ide0_request, vframe,
                    (unsigned long long)g_ido, (unsigned long long)g_idone, (unsigned long long)g_i0, (unsigned long long)g_i8);
            fprintf(stderr,"          INTPOSS: now=%d high_cycles=%llu\n",g_iplast,(unsigned long long)g_ipn);
            fprintf(stderr,"          MEM: mem_read=%d last_addr=0x%08x rd_hi=%llu wait_hi=%llu rdv_hi=%llu\n",g_mrdlast,g_maddr,(unsigned long long)g_mrd,(unsigned long long)g_mwait,(unsigned long long)g_mrdv);
            fprintf(stderr,"          RTC: divider=%d prate=%d pena=%d uena=%d aena=%d pint_hi=%llu uint_hi=%llu irq_hi=%llu\n",g_rdiv,g_rprate,g_rpena,g_ruena,g_raena,(unsigned long long)g_rpint,(unsigned long long)g_ruint,(unsigned long long)g_rirq);
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
#if VM_TRACE
    if (tfp) { tfp->close(); }
#endif
    top->final(); delete top; free(ddr);
    return 0;
}
