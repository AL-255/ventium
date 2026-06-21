// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// sw/ps/ven_soc_app/ven_soc_app.c — F2 PS-side bring-up app for the KV260 Ventium SoC.
//
// Runs on the A53 (PetaLinux userspace). It is the real-HW analogue of the cosim's
// tb_main.cpp: it loads a program image into the reserved DDR carveout, drives the
// ven_soc_axil control slave to boot the core, then services the port-I/O bridge —
// emulating slow peripherals in software (here: a console UART + the isa-debug-exit
// port). The core runs in PL at speed; every IN/OUT stalls the core until this loop
// answers, so device latency is correctness-safe (the core parks in S_IO).
//
// F2 scope: boot + console output + clean exit. F3 (FreeDOS) adds PIT/PIC/IDE/keyboard
// device models + interrupt injection; F4 (Quake) adds the int-0x80 proxy + framebuffer.
//
// Build (PetaLinux/aarch64): make ; run as root (needs /dev/mem):  ./ven_soc_app prog.bin
//
// NOTE: untested on hardware — there is no board in the dev loop yet. The register
// protocol is the one the Verilator unit gate (run-soc-axil-gate.sh) proves.

#define _GNU_SOURCE 1
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <math.h>
#include <signal.h>
#include <sys/mman.h>
#include "ven_soc_regs.h"
#include "hid_kbd.h"
#include "ven_quake.h"
#include "ven_systrace.h"
#include "../../ps_periph/ven_periph.h"

// F3 PS-placed peripheral C models (sw/ps_periph/, same files the cosim gates
// prove bit-exact vs qemu-system) + their F3 extras.
ven_periph_t* ven_i8042_new(void);
ven_periph_t* ven_pic_new(void);
ven_periph_t* ven_vgaregs_new(void);
void          ven_pic_set_irq(ven_periph_t*, int irq, int level);
uint8_t       ven_pic_peek_vector(ven_periph_t*);
uint8_t       ven_pic_intack(ven_periph_t*);
const uint8_t* ven_vgaregs_dac(ven_periph_t*);
uint16_t ven_vgaregs_cursor(ven_periph_t*);
uint16_t ven_vgaregs_cursor_shape(ven_periph_t*);
// F-track FreeDOS stack: PIT (timer/IRQ0), RTC/CMOS, IDE/ATA disk.
ven_periph_t* ven_pit_new(void);
int           ven_pit_irq0_ticks(ven_periph_t*);
ven_periph_t* ven_rtc_new(void);
void          ven_rtc_set_extmem_kb(ven_periph_t*, uint32_t);  // F4A: seed >1MiB RAM
ven_periph_t* ven_ide_new(const char* disk_path);

static volatile uint32_t *g_reg;     // mmap'd AXI-Lite slave
static volatile uint8_t  *g_ddr;     // mmap'd DDR carveout

static inline uint32_t rd(uint32_t off)          { return g_reg[off >> 2]; }
static inline void     wr(uint32_t off, uint32_t v) { g_reg[off >> 2] = v; }

// ---- F4 FP-op trap (PS-trap FPATAN; +VEN_FPTRAP bitstream) -------------------
// The core has no HW transcendental engine (too big for the xck26), so on D9 F3
// FPATAN it stalls in S_FPTRAP_WAIT and exposes ST0/ST1 as 80-bit floatx80. The
// A53 reads them, computes atan2, and commits the floatx80 result. aarch64 long
// double is 128-bit quad (NOT floatx80), so convert the operands/result by hand.
// Quake's render path needs only ~double precision, which double carries exactly.
static double fx80_to_double(uint32_t w0, uint32_t w1, uint32_t w2) {
    int      sign = (w2 >> 15) & 1;
    int      exp  = w2 & 0x7FFF;
    uint64_t mant = ((uint64_t)w1 << 32) | w0;     // 64-bit significand, int bit @63
    double   val;
    if (exp == 0x7FFF) {                            // Inf / NaN
        val = (mant << 1) == 0 ? INFINITY : NAN;
    } else if (exp == 0 && mant == 0) {
        val = 0.0;
    } else {
        // value = mant * 2^(exp - 16383 - 63)  (mant carries the explicit integer bit)
        val = ldexp((double)mant, exp - 16383 - 63);
    }
    return sign ? -val : val;
}

static void double_to_fx80(double v, uint32_t *w0, uint32_t *w1, uint32_t *w2) {
    int sign = signbit(v) ? 1 : 0;
    if (sign) v = -v;
    uint32_t hi;            // word2: [15]=sign [14:0]=exp
    uint64_t mant;         // {w1,w0}
    if (v == 0.0)        { mant = 0;                       hi = 0; }
    else if (isinf(v))   { mant = 0x8000000000000000ull;   hi = 0x7FFF; }
    else if (isnan(v))   { mant = 0xC000000000000000ull;   hi = 0x7FFF; }
    else {
        int    e;
        double m = frexp(v, &e);          // v = m * 2^e, m in [0.5, 1)
        double scaled = ldexp(m, 64);     // m * 2^64 in [2^63, 2^64)
        mant = scaled >= 18446744073709551616.0 ? 0xFFFFFFFFFFFFFFFFull
                                                 : (uint64_t)scaled;
        int exp = e + 16382;              // expfield = e - 64 + 16383 + 63
        if      (exp <= 0)     { mant = 0; hi = 0; }            // underflow -> 0
        else if (exp >= 0x7FFF){ mant = 0x8000000000000000ull; hi = 0x7FFF; } // -> Inf
        else                     hi = (uint32_t)exp;
    }
    *w0 = (uint32_t)(mant & 0xFFFFFFFFu);
    *w1 = (uint32_t)(mant >> 32);
    *w2 = ((uint32_t)sign << 15) | hi;
}

// Service one pending FP trap: read ST0/ST1, compute, commit. Mirrors the syscall
// proxy ordering — write the 3 result words BEFORE the W1P commit (the core latches
// fptrap_result combinationally on the resp_valid clock).
static void service_fptrap(void) {
    uint32_t st[6];
    for (int i = 0; i < 6; i++) { wr(VEN_R_FPT_IDX, i); st[i] = rd(VEN_R_FPT_DATA); }
    double x = fx80_to_double(st[0], st[1], st[2]);   // ST0
    double y = fx80_to_double(st[3], st[4], st[5]);   // ST1
    double r = atan2(y, x);                            // FPATAN: ST1 <- atan2(ST1,ST0)
    uint32_t r0, r1, r2;
    double_to_fx80(r, &r0, &r1, &r2);
    wr(VEN_R_FPT_IDX, 0); wr(VEN_R_FPT_RES, r0);
    wr(VEN_R_FPT_IDX, 1); wr(VEN_R_FPT_RES, r1);
    wr(VEN_R_FPT_IDX, 2); wr(VEN_R_FPT_RES, r2);
    wr(VEN_R_FPT_CTRL, 1);                             // W1P commit -> core resumes
}

// VEN_DBG=1: print the retire trajectory + status/last-io every ~250 ms so a
// silent stall (status=0, retire frozen) is visible (no CPU_HUNG is raised).
static long dbg_now_ms(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

// VEN_DBG_CORE: dump the on-die debug/trace unit (committed regs + FSM state +
// fault + freeze snapshot + perf counters + the last-N retired-PC ring). On a
// freeze this shows the INSTRUCTION TRAIL into the derail — what took a faithful
// sim to find. No-op on a non-DBG_CORE bitstream (R_DBG_CAP != magic).
static void dbg_dump_core(void) {
    uint32_t cap = rd(VEN_R_DBG_CAP);
    if (cap != VEN_DBG_CAP_MAGIC) {
        fprintf(stderr, "ven_dbg: no on-die debug unit (cap=0x%08x; rebuild bitstream DBG_CORE=1)\n", cap);
        return;
    }
    int depth = (int)(cap & 0xFFFF);
    uint32_t st = rd(VEN_R_DBG_STATE);
    uint64_t cyc = ((uint64_t)rd(VEN_R_DBG_PERF_CYCHI) << 32) | rd(VEN_R_DBG_PERF_CYCLO);
    uint64_t ret = ((uint64_t)rd(VEN_R_DBG_PERF_RETHI) << 32) | rd(VEN_R_DBG_PERF_RETLO);
    fprintf(stderr,
        "\n=== VEN_DBG core state ===\n"
        " EIP=%08x CS=%04x ESP=%08x EFLAGS=%08x\n"
        " FSM=0x%02x mode=%s%s vec=0x%02x  io=%d hung=%d frozen=%d\n"
        " fault_pc=%08x CR0=%08x  halted=%d\n",
        rd(VEN_R_DBG_EIP), rd(VEN_R_DBG_CS) & 0xFFFF, rd(VEN_R_DBG_ESP), rd(VEN_R_DBG_EFLAGS),
        st & 0x3F, (st & 0x40) ? "PE" : "real", (st & 0x80) ? "+PG" : "", (st >> 8) & 0xFF,
        (st >> 16) & 1, (st >> 17) & 1, (st >> 18) & 1,
        rd(VEN_R_DBG_FAULT_PC), rd(VEN_R_DBG_CR0), rd(VEN_R_DBG_RUNCTL) >> 8 & 1);
    {   // patchable opcode-hook: most-recent captured instruction (e.g. the faulting divide)
        uint32_t hm = rd(VEN_R_DBG_HOOK_META);
        fprintf(stderr, " hook: seq=%u eip=%08x EDX:EAX=%08x:%08x opB=%08x (op=%u w=%u cs=%04x)\n",
            rd(VEN_R_DBG_HOOK_SEQ) & 0xFF, rd(VEN_R_DBG_HOOK_EIP),
            rd(VEN_R_DBG_HOOK_OPAHI), rd(VEN_R_DBG_HOOK_OPALO), rd(VEN_R_DBG_HOOK_OPB),
            (hm >> 24) & 0xFF, hm & 0x7, (hm >> 8) & 0xFFFF);
    }
    if (st & (1u << 18)) {
        uint32_t fs = rd(VEN_R_DBG_FROZEN_ST);
        fprintf(stderr, " FROZEN snapshot: EIP=%08x FSM=0x%02x vec=0x%02x\n",
                rd(VEN_R_DBG_FROZEN_EIP), fs & 0x3F, (fs >> 8) & 0xFF);
    }
    fprintf(stderr, " perf: cyc=%llu retired=%llu stall=%u io=%u irq=%u CPI=%.2f\n",
            (unsigned long long)cyc, (unsigned long long)ret, rd(VEN_R_DBG_PERF_STALL),
            rd(VEN_R_DBG_PERF_IO), rd(VEN_R_DBG_PERF_IRQ),
            ret ? (double)cyc / (double)ret : 0.0);
    int n = (int)((rd(VEN_R_DBG_TRACE_IDX) >> 8) & 0x3F);
    if (n > depth) n = depth;
    fprintf(stderr, " PC ring (newest first, %d of %d):\n", n, depth);
    for (int i = 0; i < n; i++) {
        wr(VEN_R_DBG_TRACE_IDX, (uint32_t)i);
        (void)rd(VEN_R_DBG_TRACE_PC);          // flush the 1-clock BRAM read latency
        uint32_t pc = rd(VEN_R_DBG_TRACE_PC), aux = rd(VEN_R_DBG_TRACE_AUX);
        fprintf(stderr, "  [-%2d] %04x:%08x  fsm=0x%02x\n", i, aux & 0xFFFF, pc, (aux >> 16) & 0x3F);
    }
    // Instruction bytes at the halt sites (g_ddr=carveout, real-mode phys=cs*16+eip).
    // devmem of the reserved carveout fails under strict-devmem, but g_ddr is mapped.
    if (g_ddr) {
        uint32_t dcs = rd(VEN_R_DBG_CS) & 0xFFFF;
        uint32_t sites[3] = { rd(VEN_R_DBG_EIP), rd(VEN_R_DBG_FAULT_PC), rd(VEN_R_DBG_FROZEN_EIP) };
        const char* nm[3] = { "eip", "fault_pc", "frozen_eip" };
        for (int s = 0; s < 3; s++) {
            uint32_t ph = ((uint32_t)(dcs*16 + sites[s])) & (uint32_t)(VEN_CARVEOUT_SIZE - 1);
            fprintf(stderr, " bytes @%-10s %04x:%08x:", nm[s], dcs, sites[s]);
            for (int b = 0; b < 16; b++) fprintf(stderr, " %02x", g_ddr[(ph + b) & (VEN_CARVEOUT_SIZE-1)]);
            fprintf(stderr, "\n");
        }
    }
    // F4 AXI read-beat ring (DDR addr+data of recent accepted read beats; under
    // --golden-l1 every load misses L1 -> AXI, so this captures the loop's reads).
    int rn = (int)(rd(VEN_R_DBG_RD_COUNT) & 0x3F);
    if (rn > depth) rn = depth;
    fprintf(stderr, " AXI read-beat ring (newest first, %d of %d):\n", rn, depth);
    for (int i = 0; i < rn; i++) {
        wr(VEN_R_DBG_TRACE_IDX, (uint32_t)i);
        (void)rd(VEN_R_DBG_RD_ADDR);   // flush the 1-clock BRAM read latency
        uint32_t a = rd(VEN_R_DBG_RD_ADDR), d = rd(VEN_R_DBG_RD_DATA);
        fprintf(stderr, "  rd[-%2d] addr=%08x data=%08x\n", i, a, d);
    }
    fflush(stderr);
}

// Halt the core at the next instruction boundary, dump full forensic state
// (PC ring + AXI read-beat ring are stable only when frozen), then resume.
// Triggered by SIGUSR2 — used to snapshot the FreeDOS SYSINIT loop's reads.
static void dbg_halt_dump_resume(void) {
    if (rd(VEN_R_DBG_CAP) != VEN_DBG_CAP_MAGIC) { dbg_dump_core(); return; }
    wr(VEN_R_DBG_RUNCTL, 0x1);                       // halt_req
    int parked = 0;
    for (int i = 0; i < 100000; i++)
        if ((rd(VEN_R_DBG_RUNCTL) >> 8) & 1) { parked = 1; break; }
    fprintf(stderr, "\n[FORENSIC] core %s\n", parked ? "halted" : "NOT halted (timeout)");
    dbg_dump_core();
    wr(VEN_R_DBG_RUNCTL, 0x0);                        // resume
}

// ---- F4 (--quake) state ------------------------------------------------------
// Userspace Quake via the int-0x80 proxy (needs a +VEN_PS_PROXY bitstream): the
// core stalls in S_SYSCALL_WAIT on each cd80; this app reads {nr,args} from the
// 0x40-0x6C syscall window, emulates the i386 Linux call (ven_quake.*), writes
// the kernel memory effects into the carveout, then commits the response.
static int          g_quake     = 0;     // --quake <image.json>
static int          g_cycle     = 0;     // --cycle: set MODE.CYCLE (dual-issue / fast uopcache fetch path)
static const char  *g_qimage    = 0;     // the gen_trace.py --image-out JSON
static const char  *g_video_out = 0;     // --video <out.p5q>: capture the P5Q1 stream
static const char  *g_vga_dump  = 0;     // --vga-dump <out.ppm>: mode-13h framebuffer snapshot
static const char  *g_vidpath   = "/p5q_video_capture";  // $P5Q_VIDEO sentinel (match the image)
static uint32_t      g_brk      = 0x0a000000u;  // --brk: initial break (run-quake-fb computes it)
static int           g_video_fd = -1;
// On-die single-step debug (VEN_DBG_CORE): --bp <eip> sets a HW breakpoint; on the
// halt, --steps <n> single-steps n instructions dumping EIP/CS/FSM each — to walk a
// fetch/control-flow bug instruction-by-instruction on real silicon.
static uint32_t      g_bp        = 0;
static int           g_bp_set    = 0;
static uint32_t      g_steps     = 80;
// --peek <gaddr>: after staging, hexdump the carveout (what the core fetches) at the
// folded guest address — to tell a staging error from a fetch-read bug. Does not run.
static uint32_t      g_peek      = 0;
static int           g_peek_set  = 0;
// --poke <gaddr> <hexbytes>: after staging, OVERWRITE the carveout at the folded guest
// address with the given bytes (a controlled instruction stream), then run/single-step.
// Software-only (g_ddr mmap, like --peek) — used to probe the L1AXI fetch/decode on
// silicon with a known pattern (e.g. NOP runs / repeated `8b 42 04` across a line edge).
static uint32_t      g_poke      = 0;
static int           g_poke_set  = 0;
static uint8_t       g_poke_buf[512];
static int           g_poke_len  = 0;
// --flush-each-step: pulse FLUSH_REQ (L1 invalidate) before every single-step, so each
// fetch MISSES and refills from DDR — removes the --poke staleness confound (the PS write
// is not snooped) and isolates a unified-L1 set-eviction / cross-line refill bug.
static int           g_flush_step = 0;
static int           g_golden_l1  = 0;     // --golden-l1: MODE.GOLDEN_L1 (flush L1 each access; diag)

// ---- F3 (--dos) state --------------------------------------------------------
static int           g_dos = 0;          // --dos: i8042/PIC/VGA models + IRQ inject
static uint32_t      g_extmem_kb = 0;    // --extmem-kb N: seed CMOS RAM-size >1MiB (F4A DOS Quake)
static ven_periph_t *g_i8042, *g_pic, *g_vga, *g_pit, *g_rtc, *g_ide;
static int           g_dac_dirty = 0;    // guest wrote the DAC -> re-export
static const char   *VGA_DAC_EXPORT = "/dev/shm/ven_vga_dac";

// --- live VGA display: kms-draw runs alongside the app by default (--dos) ------
// User directive: kms-draw is a default companion of ven_soc_app so the board's
// monitor shows the guest VGA the moment it renders. ./kms-draw --vga13 reads the
// live mode-13h framebuffer (carveout+0xA0000) + exported DAC and blits it
// integer-scaled to the panel. Suppress with --no-kms.
static pid_t         g_kms_pid = -1;
static int           g_no_kms  = 0;
static void spawn_kms(void) {
    if (g_no_kms || g_kms_pid > 0) return;
    if (access("./kms-draw", X_OK) != 0) {
        fprintf(stderr, "ven_soc: ./kms-draw not executable — no live display "
                        "(build it, or pass --no-kms to silence)\n");
        return;
    }
    pid_t pid = fork();
    if (pid == 0) {                         // child becomes the display
        execl("./kms-draw", "kms-draw", "--vga13", (char *)NULL);
        perror("execl kms-draw"); _exit(127);
    }
    if (pid > 0) { g_kms_pid = pid;
        fprintf(stderr, "ven_soc: live display: kms-draw --vga13 (pid %d)\n", pid); }
    else perror("fork kms-draw");
}
static void stop_kms(void) {
    if (g_kms_pid > 0) { kill(g_kms_pid, SIGTERM); g_kms_pid = -1; }
}

// export the live 6-bit DAC for the fb_vnc daemon (768 bytes, atomic-enough:
// readers tolerate a torn palette for one frame).
static void export_dac(void) {
    int fd = open(VGA_DAC_EXPORT, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    if (write(fd, ven_vgaregs_dac(g_vga), 768) != 768) { /* best effort */ }
    close(fd);
}

// VGA text-buffer snapshot: decode the 80x25 color-text page at core-physical
// 0xB8000 (carveout+0xB8000; ven_l1d is write-through so DDR is current). Each
// cell is {char, attr}; we print the chars. SIGTERM/SIGINT (e.g. from `timeout`)
// dumps the live console then exits — the only way to SEE the SeaBIOS/FreeDOS
// screen on a headless board without a VGABIOS-driven framebuffer path. Async-
// signal use is best-effort diagnostic (g_ddr is a stable mmap).
static void vga_textdump(void) {
    if (!g_ddr) return;
    const volatile uint8_t *t = g_ddr + 0x000B8000;
    fprintf(stderr, "\n===== VGA text @0xB8000 (80x25) =====\n");
    int any = 0;
    for (int row = 0; row < 25; row++) {
        char line[81];
        for (int col = 0; col < 80; col++) {
            uint8_t c = t[(row*80 + col)*2];
            line[col] = (c >= 32 && c < 127) ? (char)c : ' ';
        }
        line[80] = 0;
        int n = 80; while (n > 0 && line[n-1] == ' ') line[--n] = 0;
        if (n) { fprintf(stderr, "%2d|%s\n", row, line); any = 1; }
    }
    if (!any) fprintf(stderr, "(text buffer all-blank)\n");
    fprintf(stderr, "=====================================\n");
    fflush(stderr);
}

// VGA GRAPHICS (mode-13h 320x200x8) snapshot: the DOS framebuffer at core-physical
// 0xA0000 (carveout+0xA0000; ven_l1d write-through => DDR current) + the 6-bit DAC
// palette -> a P6 PPM. This is how we SEE/retrieve a DOS Quake frame on a headless
// board (the only graphics path besides the fb_vnc daemon). Reports the non-zero
// pixel count so a blank vs rendered screen is obvious. --vga-dump <file>.
static void vga_gfxdump(void) {
    if (!g_ddr || !g_vga || !g_vga_dump) return;
    const volatile uint8_t *fb = g_ddr + 0x000A0000;     // mode-13h linear framebuffer
    const uint8_t *dac = ven_vgaregs_dac(g_vga);          // 768 bytes = 256 * {R,G,B} 6-bit
    FILE *f = fopen(g_vga_dump, "wb");
    if (!f) { perror(g_vga_dump); return; }
    fprintf(f, "P6\n320 200\n255\n");
    long nz = 0; int histtop = 0; long histmax = 0; long hist[256]; for (int i=0;i<256;i++) hist[i]=0;
    for (int i = 0; i < 320*200; i++) {
        uint8_t idx = fb[i];
        hist[idx]++;
        if (idx) nz++;
        unsigned char r = (unsigned char)(dac[idx*3+0] << 2);
        unsigned char g = (unsigned char)(dac[idx*3+1] << 2);
        unsigned char b = (unsigned char)(dac[idx*3+2] << 2);
        fputc(r, f); fputc(g, f); fputc(b, f);
    }
    fclose(f);
    for (int i=0;i<256;i++) if (hist[i]>histmax) { histmax=hist[i]; histtop=i; }
    fprintf(stderr, "ven_soc: VGA gfx mode13 @0xA0000 -> %s  (%ld/64000 non-zero px; "
            "dominant idx=%d count=%ld)\n", g_vga_dump, nz, histtop, histmax);
    fflush(stderr);
}

// Clean AXI teardown: assert CTRL.SHUTDOWN so ven_axi_master refuses NEW transactions
// and drains any in-flight one, then poll STATUS.AXI_IDLE. Leaving the PL here means a
// subsequent `xmutil unloadapp` removes the overlay while the PL→PS AXI master is
// protocol-clean (no outstanding AW/W/AR) — an outstanding burst at teardown is what
// wedges the PS interconnect/DDR and can hang the host. core_run is preserved (NOT
// dropped — dropping it would reset ven_axi_master mid-handshake and strand a beat).
// No-op on a non-shutdown-capable bitstream (AXI_IDLE just never deviates).
static void ven_shutdown_quiesce(void) {
    stop_kms();                                 // tear down the live display child
    if (!g_reg) return;
    uint32_t keep = rd(VEN_R_CTRL) & (VEN_CTRL_CORE_RUN | VEN_CTRL_IRQ_EN);
    wr(VEN_R_CTRL, keep | VEN_CTRL_SHUTDOWN);
    for (int i = 0; i < 5000; i++) {            // up to ~5 ms for in-flight to drain
        if (rd(VEN_R_STATUS) & VEN_ST_AXI_IDLE) break;
        usleep(1);
    }
    fprintf(stderr, "ven_soc: AXI quiesced (STATUS=0x%x) — safe to unloadapp\n",
            rd(VEN_R_STATUS));
}
// Async-signal-safe request flags: the handlers ONLY set these; the main loop does
// the actual stdio work (systrace_dump/vga_textdump/snapshot), so a signal arriving
// while the main thread holds the stdio lock can never deadlock — critical for
// SIGUSR1, which is meant to be sent repeatedly to probe a LIVE, still-running board.
static volatile sig_atomic_t g_term_req = 0;
static volatile sig_atomic_t g_snap_req = 0;
static volatile sig_atomic_t g_fdump_req = 0;
static void on_term(int sig) { (void)sig; g_term_req = 1; }   // SIGTERM/SIGINT: dump + exit
static void on_snap(int sig) { (void)sig; g_snap_req = 1; }   // SIGUSR1: live snapshot (no exit)
static void on_fdump(int sig){ (void)sig; g_fdump_req = 1; }  // SIGUSR2: halt + forensic dump + resume

// --- console / device emulation (the part that grows for F3/F4) --------------
// F2: a tiny UART. OUT to 0x3F8 (COM1 THR) or 0xE9 (debug) -> stdout. IN from the
// COM1 LSR (0x3FD) returns "THR empty, data ready" so a UART-poll loop proceeds.
// F3 (--dos): the dual-8259 PIC, the i8042 and the VGA register file route to
// their sw/ps_periph C models first; everything else keeps the F2 behavior.

// --dos port routing: 1 if the port belongs to a PS-placed C model.
static ven_periph_t* dos_model_of(uint16_t port) {
    if (!g_dos) return 0;
    if (port == 0x60 || port == 0x64)                  return g_i8042;
    if (port == 0x20 || port == 0x21 ||
        port == 0xA0 || port == 0xA1 ||
        port == 0x4D0 || port == 0x4D1)                return g_pic;
    if (port >= 0x3B0 && port <= 0x3DF)                return g_vga;
    if (port >= 0x40 && port <= 0x43)                  return g_pit;   // 8254 PIT
    if (port == 0x70 || port == 0x71)                  return g_rtc;   // RTC/CMOS
    if ((port >= 0x1F0 && port <= 0x1F7) || port == 0x3F6) return g_ide;  // IDE/ATA
    return 0;
}

// ---- Soft VGA: A53-side INT 10h (VGABIOS) for DOS Quake ---------------------
// The vgabios-stdvga option ROM is unusable on Ventium (no PCI std-vga device: its
// init far-call hangs SeaBIOS / reboot-loops). Instead the PS *is* the VGABIOS: a
// 93-byte in-guest stub installed at C000:0 (IVT[0x10] -> it, after POST) saves
// regs to C000:0x100 and OUTs the VGA-trap port; we service the call here. Mode-13h
// pixels land at 0xA0000 (captured by --vga-dump / kms-draw --vga13); the palette
// comes via the DAC ports (g_vga) or AH=10/AL=12. --soft-vga enables it.
#define VGA_STUB_SEG   0xC000u
#define VGA_STUB_PHYS  0xC0000u
#define VGA_REGBUF     (VGA_STUB_PHYS + 0x100u)   // AX@+0 BX@+2 CX@+4 DX@+6 SI@+8 DI@+a BP@+c ES@+e DS@+10
#define VGA_TRAP_PORT  0x02E0u
static const uint8_t g_vga_stub[] = {
    0x2e,0xa3,0x00,0x01, 0x2e,0x89,0x1e,0x02,0x01, 0x2e,0x89,0x0e,0x04,0x01,
    0x2e,0x89,0x16,0x06,0x01, 0x2e,0x89,0x36,0x08,0x01, 0x2e,0x89,0x3e,0x0a,0x01,
    0x2e,0x89,0x2e,0x0c,0x01, 0x2e,0x8c,0x06,0x0e,0x01, 0x2e,0x8c,0x1e,0x10,0x01,
    0xba,0xe0,0x02, 0xee,
    0x2e,0xa1,0x00,0x01, 0x2e,0x8b,0x1e,0x02,0x01, 0x2e,0x8b,0x0e,0x04,0x01,
    0x2e,0x8b,0x16,0x06,0x01, 0x2e,0x8b,0x36,0x08,0x01, 0x2e,0x8b,0x3e,0x0a,0x01,
    0x2e,0x8b,0x2e,0x0c,0x01, 0x2e,0x8e,0x06,0x0e,0x01, 0x2e,0x8e,0x1e,0x10,0x01,
    0xcf
};
static int g_soft_vga = 0, g_vga_installed = 0, g_post_done = 0;

static inline uint16_t gr16(uint32_t p){ return (uint16_t)(g_ddr[p] | (g_ddr[p+1] << 8)); }
static inline void     gw16(uint32_t p, uint16_t v){ g_ddr[p]=(uint8_t)v; g_ddr[p+1]=(uint8_t)(v>>8); }

static void install_soft_vga(void) {
    for (size_t i = 0; i < sizeof(g_vga_stub); i++) g_ddr[VGA_STUB_PHYS + i] = g_vga_stub[i];
    gw16(0x40, 0x0000);            // IVT[0x10].offset
    gw16(0x42, VGA_STUB_SEG);      // IVT[0x10].segment
    __sync_synchronize();
    wr(VEN_R_CTRL, VEN_CTRL_CORE_RUN | VEN_CTRL_FLUSH_REQ);   // invalidate the core's L1/I$
    fprintf(stderr, "ven_soc: soft-VGA INT10h installed (stub@C000:0, trap port 0x%x)\n", VGA_TRAP_PORT);
}

static void vga_set_mode13(void) {
    g_ddr[0x449] = 0x13;           // BDA video mode = 13h
    gw16(0x44a, 40); gw16(0x44c, 0);   // BDA columns / page size
    g_ddr[0x462] = 0; g_ddr[0x487] = 0x60;   // active page / VGA mode flags (graphics)
}

// Service one trapped INT 10h call (regs in the C000:0x100 buffer; result written back).
static unsigned long g_vga_calls = 0;
static void vga_int10_service(void) {
    uint16_t ax = gr16(VGA_REGBUF+0), bx = gr16(VGA_REGBUF+2),
             cx = gr16(VGA_REGBUF+4), dx = gr16(VGA_REGBUF+6),
             es = gr16(VGA_REGBUF+0x0e);
    uint8_t  ah = (uint8_t)(ax >> 8), al = (uint8_t)ax;
    if (g_vga_calls++ < 64 || (ah != 0x0E))
        fprintf(stderr, "soft-vga: int10 #%lu ax=%04x bx=%04x cx=%04x dx=%04x\n",
                g_vga_calls, ax, bx, cx, dx);
    switch (ah) {
        case 0x00:                                  // set video mode
            if (al == 0x13) vga_set_mode13(); else g_ddr[0x449] = al;
            break;
        case 0x02:                                  // set cursor position (DH=row DL=col)
            gw16(0x450, dx);
            break;
        case 0x03:                                  // get cursor -> DX=pos, CX=shape
            dx = gr16(0x450); cx = gr16(0x460);
            break;
        case 0x0E: {                                // teletype: write AL, advance cursor (page 0)
            uint8_t ch = al;
            uint16_t cur = gr16(0x450);
            uint8_t col = (uint8_t)cur, row = (uint8_t)(cur >> 8);
            uint8_t cols = (uint8_t)gr16(0x44a); if (!cols) cols = 80;
            if      (ch == 0x0D) col = 0;
            else if (ch == 0x0A) row++;
            else if (ch == 0x08) { if (col) col--; }
            else {
                uint32_t v = 0xB8000u + ((uint32_t)row*cols + col)*2u;
                g_ddr[v] = ch; g_ddr[v+1] = 0x07;
                if (++col >= cols) { col = 0; row++; }
            }
            if (row >= 25) {                        // scroll up one line
                uint32_t w = (uint32_t)cols*2u, b = 0xB8000u;
                for (uint32_t i = 0; i < w*24u; i++) g_ddr[b+i] = g_ddr[b+w+i];
                for (uint32_t i = 0; i < cols;  i++) { g_ddr[b+w*24u+i*2]=' '; g_ddr[b+w*24u+i*2+1]=0x07; }
                row = 24;
            }
            gw16(0x450, (uint16_t)(((uint16_t)row << 8) | col));
            break; }
        case 0x0F:                                  // get mode -> AL=mode AH=cols BH=page
            ax = (uint16_t)(((uint16_t)(uint8_t)gr16(0x44a) << 8) | g_ddr[0x449]);
            bx = (uint16_t)(bx & 0x00ff);
            break;
        case 0x10:                                  // palette / DAC
            if (al == 0x12) {                       // set block: ES:DX -> (R,G,B) table, BX start, CX count
                uint32_t tbl = ((uint32_t)es << 4) + dx;
                g_vga->io_write(g_vga, 0x3C8, (uint8_t)bx);
                for (uint16_t i = 0; i < cx; i++) {
                    g_vga->io_write(g_vga, 0x3C9, g_ddr[tbl + i*3 + 0]);
                    g_vga->io_write(g_vga, 0x3C9, g_ddr[tbl + i*3 + 1]);
                    g_vga->io_write(g_vga, 0x3C9, g_ddr[tbl + i*3 + 2]);
                }
                g_dac_dirty = 1;
            }
            break;
        case 0x1A:                                  // get display combination code -> VGA color
            if (al == 0x00) { ax = 0x001A; bx = (uint16_t)((bx & 0xff00) | 0x08); }
            break;
        case 0x4F:                                  // VBE: leave AX=0x4Fxx (!=0x004F) -> unsupported
        default:                                    // -> Quake falls back to mode 13h
            break;
    }
    gw16(VGA_REGBUF+0, ax); gw16(VGA_REGBUF+2, bx);
    gw16(VGA_REGBUF+4, cx); gw16(VGA_REGBUF+6, dx);
}

static int service_out(uint16_t port, uint32_t val) {
    if (g_soft_vga && port == VGA_TRAP_PORT) { vga_int10_service(); return 0; }
    ven_periph_t* m = dos_model_of(port);
    if (m) {
        m->io_write(m, port, (uint8_t)(val & 0xFF));
        if (port == 0x3C8 || port == 0x3C9) g_dac_dirty = 1;  // DAC write -> export
        if (port == 0x3D5 || port == 0x3B5) {  // CRTC data: keep BDA text cursor synced
            uint16_t loc  = ven_vgaregs_cursor(m);        // char offset cr[0x0E:0x0F]
            uint16_t sh   = ven_vgaregs_cursor_shape(m);  // {end cr[0x0B], start cr[0x0A]}
            uint16_t cols = gr16(0x44a); if (!cols) cols = 80;
            gw16(0x450, (uint16_t)(((loc/cols) << 8) | (loc % cols))); // 0x450=col,0x451=row
            g_ddr[0x461] = (uint8_t)(sh & 0xff);          // cursor start scanline + enable
            g_ddr[0x460] = (uint8_t)((sh >> 8) & 0xff);   // cursor end scanline
        }
        return 0;
    }
    switch (port) {
        case 0x00E9:                       // bochs/qemu debug console
        case 0x0402:                       // SeaBIOS debug port (CONFIG_DEBUG_IO_PORT) — POST log
        case 0x03F8: putchar((int)(val & 0xFF)); fflush(stdout); return 0;
        case 0x00F4: return 1;             // isa-debug-exit -> stop the run
        default:     return 0;             // ignore unmodeled OUTs (F3 fills these in)
    }
}
// I/O-read histogram — find which device a hang spins on (e.g. the go32 stub
// polling the IDE). Dumped on SIGTERM/exit via io_hist_dump(). Diagnostic-only.
static uint64_t g_io_in_hist[0x10000];
static void io_hist_dump(void) {
    fprintf(stderr, "=== I/O read histogram (top ports) ===\n");
    for (int top = 0; top < 16; top++) {
        uint32_t bp = 0; uint64_t bc = 0;
        for (int p = 0; p < 0x10000; p++) if (g_io_in_hist[p] > bc) { bc = g_io_in_hist[p]; bp = (uint32_t)p; }
        if (!bc) break;
        fprintf(stderr, "  port 0x%04x : %llu reads\n", bp, (unsigned long long)bc);
        g_io_in_hist[bp] = 0;
    }
}
static uint32_t service_in(uint16_t port, uint8_t size) {
    g_io_in_hist[port]++;
    ven_periph_t* m = dos_model_of(port);
    if (m) {
        if (size >= 2 && m->io_read16) return m->io_read16(m, port);  // IDE data port (0x1F0)
        return m->io_read(m, port);        // byte-wide devices
    }
    switch (port) {
        case 0x03FD: return 0x60;          // COM1 LSR: THR-empty | TSR-empty
        case 0x03F8: return 0x00;          // COM1 RBR: no input byte
        default:     return 0xFF;          // unmodeled IN -> all-ones (F3 fills these in)
    }
}

int main(int argc, char **argv) {
    // positional args exactly as F2 (<program.bin> [load_off] [entry] [esp]);
    // flags may appear anywhere: --sys, --dos, --kbd <evdev-path>.
    const char *img = 0, *kbd_path = 0, *bios = 0, *disk = 0, *vgabios = 0;
    uint32_t pos[3] = {0x0, 0x0, 0x000FFFF0};    // load_off, entry, esp
    int      npos = 0, sysmode = 0, i;
    for (i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "--sys")) sysmode = 1;
        else if (!strcmp(argv[i], "--dos")) g_dos   = 1;
        else if (!strcmp(argv[i], "--soft-vga")) g_soft_vga = 1;   // PS-side INT10h VGABIOS (DOS Quake)
        else if (!strcmp(argv[i], "--no-kms")) g_no_kms = 1;        // suppress the default live kms-draw display
        else if (!strcmp(argv[i], "--extmem-kb") && i + 1 < argc) g_extmem_kb = strtoul(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--kbd")  && i + 1 < argc) kbd_path = argv[++i];
        else if (!strcmp(argv[i], "--bios") && i + 1 < argc) bios = argv[++i];  // SeaBIOS image
        else if (!strcmp(argv[i], "--vgabios") && i + 1 < argc) vgabios = argv[++i]; // VGA option ROM @0xC0000
        else if (!strcmp(argv[i], "--disk") && i + 1 < argc) disk = argv[++i];  // IDE disk image
        else if (!strcmp(argv[i], "--quake")   && i + 1 < argc) { g_quake = 1; g_qimage = argv[++i]; }
        else if (!strcmp(argv[i], "--video")   && i + 1 < argc) g_video_out = argv[++i];
        else if (!strcmp(argv[i], "--vga-dump")&& i + 1 < argc) g_vga_dump  = argv[++i];
        else if (!strcmp(argv[i], "--vidpath") && i + 1 < argc) g_vidpath   = argv[++i];
        else if (!strcmp(argv[i], "--brk")     && i + 1 < argc) g_brk = strtoul(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--bp")      && i + 1 < argc) { g_bp = strtoul(argv[++i], 0, 0); g_bp_set = 1; }
        else if (!strcmp(argv[i], "--steps")   && i + 1 < argc) g_steps = strtoul(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--flush-each-step")) g_flush_step = 1;
        else if (!strcmp(argv[i], "--golden-l1")) g_golden_l1 = 1;   // diag: flush L1 each access
        else if (!strcmp(argv[i], "--peek")    && i + 1 < argc) { g_peek = strtoul(argv[++i], 0, 0); g_peek_set = 1; }
        else if (!strcmp(argv[i], "--poke")    && i + 2 < argc) {
            g_poke = strtoul(argv[++i], 0, 0); g_poke_set = 1;
            const char *hx = argv[++i]; g_poke_len = 0;     // pairs of hex digits, no spaces
            while (hx[0] && hx[1] && g_poke_len < (int)sizeof(g_poke_buf)) {
                char b[3] = { hx[0], hx[1], 0 };
                g_poke_buf[g_poke_len++] = (uint8_t)strtoul(b, 0, 16);
                hx += 2;
            }
        }
        else if (!strcmp(argv[i], "--cycle")) g_cycle = 1;   // MODE.CYCLE = dual-issue/fast-fetch path
        else if (!img)      img = argv[i];
        else if (npos < 3)  pos[npos++] = strtoul(argv[i], 0, 0);
    }
    if (!img && !bios && !g_quake) {
        fprintf(stderr, "usage: %s <program.bin> [load_off] [entry] [esp] [--sys] [--dos]\n"
                        "       [--kbd /dev/input/eventN] [--bios seabios.bin --disk hd.img]\n"
                        "       [--quake image.json [--video out.p5q] [--vidpath /p5q_video_capture]\n"
                        "        [--brk 0x...]]  (--quake needs a +VEN_PS_PROXY bitstream)\n", argv[0]);
        return 2;
    }
    if (bios) sysmode = 1;   // a BIOS boots from the reset vector F000:FFF0
    uint32_t load_off = pos[0], entry = pos[1], esp = pos[2];

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem"); return 1; }
    g_reg = mmap(0, VEN_HPM0_SIZE,     PROT_READ|PROT_WRITE, MAP_SHARED, fd, VEN_HPM0_BASE);
    g_ddr = mmap(0, VEN_CARVEOUT_SIZE, PROT_READ|PROT_WRITE, MAP_SHARED, fd, VEN_CARVEOUT_BASE);
    if (g_reg == MAP_FAILED || g_ddr == MAP_FAILED) { perror("mmap"); return 1; }
    signal(SIGTERM, on_term); signal(SIGINT, on_term);   // dump the VGA screen on stop
    signal(SIGUSR1, on_snap);                            // live (non-exiting) proxy snapshot
    signal(SIGUSR2, on_fdump);                           // halt + forensic dump (read-beat ring) + resume
    systrace_init();                                     // F4 syscall observability (env-gated)

    uint32_t ident = rd(VEN_R_IDENT);
    if (ident != VEN_IDENT_MAGIC) { fprintf(stderr, "bad IDENT 0x%08x (slave not present?)\n", ident); return 1; }

    // hold the core in reset (CORE_RUN=0 by default at slave reset), stage the image.
    wr(VEN_R_CTRL, 0);                                   // ensure CORE_RUN=0
    if (g_quake) {
        // F4: stage the Quake process image into the carveout + build the syscall
        // emulator. The image's regions are written via the g_ddr-backed MemModel,
        // and entry/esp come from its reset regs (the core boots in USER mode at
        // the ELF entry with the pre-baked argv/envp stack).
        uint32_t q_eip = 0, q_esp = 0;
        if (ven_quake_init(g_ddr, (uint32_t)(VEN_CARVEOUT_SIZE - 1), g_qimage,
                           g_vidpath, g_brk, &q_eip, &q_esp) != 0) {
            fprintf(stderr, "ven_soc: --quake image load failed (%s)\n", g_qimage);
            return 1;
        }
        __sync_synchronize();                            // flush the staged image to DRAM
        entry = q_eip; esp = q_esp;
        if (g_video_out) {
            g_video_fd = open(g_video_out, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (g_video_fd < 0) perror(g_video_out);
        }
        fprintf(stderr, "ven_soc: quake staged; entry=0x%x esp=0x%x brk=0x%x [user+proxy]\n",
                entry, esp, g_brk);
        if (g_poke_set) {     // OVERWRITE the staged carveout with a controlled pattern
            volatile uint8_t *pk = g_ddr + (g_poke & (VEN_CARVEOUT_SIZE - 1));
            for (int b = 0; b < g_poke_len; b++) pk[b] = g_poke_buf[b];
            __sync_synchronize();
            fprintf(stderr, "ven_soc: --poke guest 0x%08x  %d bytes:", g_poke, g_poke_len);
            for (int b = 0; b < g_poke_len; b++) fprintf(stderr, " %02x", g_poke_buf[b]);
            fprintf(stderr, "\n");
        }
        if (g_peek_set) {     // dump the staged carveout (what the core fetches) + exit
            const volatile uint8_t *pk = g_ddr + (g_peek & (VEN_CARVEOUT_SIZE - 1));
            fprintf(stderr, "ven_soc: --peek guest 0x%08x (carveout offset 0x%08x):\n",
                    g_peek, g_peek & (uint32_t)(VEN_CARVEOUT_SIZE - 1));
            for (int rr = 0; rr < 4; rr++) {
                fprintf(stderr, "  %08x:", g_peek + rr * 16);
                for (int cc = 0; cc < 16; cc++) fprintf(stderr, " %02x", pk[rr * 16 + cc]);
                fprintf(stderr, "\n");
            }
            ven_shutdown_quiesce();
            return 0;
        }
    } else if (bios) {
        // FreeDOS: stage the SeaBIOS image at the low shadow (0xE0000) AND the
        // top-of-4G shadow, which the L1/AXI ADDR_MASK wrap folds to carveout offset
        // 0x0FFE0000 (phys 0xFFFE0000 & 0x0FFF_FFFF). SeaBIOS runs its 32-bit POST from
        // the high shadow; both copies must be present. The disk is served by the IDE
        // model from --disk (NOT staged into RAM). Boot from the reset vector.
        FILE *f = fopen(bios, "rb");
        if (!f) { perror(bios); return 1; }
        static uint8_t biosbuf[131072];                  // 128 KiB BIOS region
        size_t bn = fread(biosbuf, 1, sizeof(biosbuf), f);
        fclose(f);
        memcpy((void *)(g_ddr + 0x000E0000), biosbuf, bn);   // low shadow 0xE0000-0xFFFFF
        memcpy((void *)(g_ddr + 0x0FFE0000), biosbuf, bn);   // wrapped 4G-top shadow
        __sync_synchronize();
        fprintf(stderr, "ven_soc: staged %zu-byte BIOS at 0xE0000 + 0x0FFE0000 (4G alias); disk=%s\n",
                bn, disk ? disk : "(none)");
        // VGA option ROM @ 0xC0000: SeaBIOS scans 0xC0000 for a 0x55AA option ROM
        // during POST and far-calls its init -> installs INT 10h video so SeaBIOS +
        // FreeDOS console text renders into the 0xB8000 text buffer (visible via the
        // ven_vgaregs model + ven_fb_vnc). Without it INT 10h is a no-op and the
        // screen stays blank even though the guest boots. Staged low only (the ROM
        // scan reads physical 0xC0000, not the 4G shadow).
        if (vgabios) {
            FILE *vf = fopen(vgabios, "rb");
            if (!vf) { perror(vgabios); return 1; }
            static uint8_t vbuf[131072];         // VGA option ROM (<=128 KiB) at 0xC0000
            size_t vn = fread(vbuf, 1, sizeof(vbuf), vf);
            fclose(vf);
            memcpy((void *)(g_ddr + 0x000C0000), vbuf, vn);
            __sync_synchronize();
            fprintf(stderr, "ven_soc: staged %zu-byte VGA BIOS at 0xC0000\n", vn);
        }
    } else {
        FILE *f = fopen(img, "rb");
        if (!f) { perror(img); return 1; }
        size_t n = fread((void *)(g_ddr + load_off), 1, VEN_CARVEOUT_SIZE - load_off, f);
        fclose(f);
        __sync_synchronize();                            // flush the image to DRAM before run
        fprintf(stderr, "ven_soc: loaded %zu bytes at carveout+0x%x; entry=0x%x esp=0x%x %s\n",
                n, load_off, entry, esp, sysmode ? "[system]" : "[user]");
    }

    // F3 (--dos): instantiate the PS-placed peripheral C models + the keyboard.
    if (g_dos) {
        g_i8042 = ven_i8042_new();
        g_pic   = ven_pic_new();
        g_vga   = ven_vgaregs_new();
        g_pit   = ven_pit_new();                         // 8254 timer (IRQ0)
        g_rtc   = ven_rtc_new();                          // RTC/CMOS (RAM-size, time)
        if (g_extmem_kb) {                                 // F4A: DOS Quake needs >1MiB RAM
            ven_rtc_set_extmem_kb(g_rtc, g_extmem_kb);
            fprintf(stderr, "ven_soc: CMOS extmem seeded = %u KB (%u MiB total)\n",
                    g_extmem_kb, 1 + g_extmem_kb / 1024);
        }
        g_ide   = ven_ide_new(disk);                      // IDE/ATA disk (INT13 source)
        if (hid_kbd_open(kbd_path) < 0)
            fprintf(stderr, "ven_soc: --dos without a keyboard (display only)\n");
        export_dac();                                    // publish the reset palette
    }

    // boot config: route memory via L1/AXI (mode 2) + IN/OUT via the io bridge.
    // --dos additionally sets SOCEN: it ungates the core's external-interrupt
    // divert (and selects the qemu-system CPUID arm the FreeDOS golden used).
    wr(VEN_R_INTR, VEN_INTR_INTA_SEEN);  // clear any leftover injection from a prior run
    wr(VEN_R_INTR, 0);                    // (else a stale ASSERT|vec derails the fresh core)
    // clear any leftover DBG run-control from a prior --bp/single-step run, else a
    // stale halt_req/bp_en parks the freshly-booted core (retired stays 0).
    if (rd(VEN_R_DBG_CAP) == VEN_DBG_CAP_MAGIC) {
        wr(VEN_R_DBG_RUNCTL, 1u << 3);   // W1P bp_clr (release a latched breakpoint)
        wr(VEN_R_DBG_RUNCTL, 0);         // clear halt_req + bp_en
        wr(VEN_R_DBG_BP_ADDR, 0);
    }
    wr(VEN_R_INIT_EIP, entry);
    wr(VEN_R_INIT_ESP, esp);
    // F4 (--quake): user mode + int-0x80 proxy, memory via L1/AXI. No IO bridge
    // (userspace issues no IN/OUT), no SOCEN, no BOOT_SYS. Otherwise the F2/F3
    // boot mode (L1AXI + IO bridge + optional system/SOCEN).
    if (g_quake) {
        wr(VEN_R_MODE, VEN_MODE_L1AXI | VEN_MODE_PROXY | (g_cycle ? VEN_MODE_CYCLE : 0));
    } else {
        wr(VEN_R_MODE, VEN_MODE_L1AXI | VEN_MODE_COSIM
                     | (sysmode    ? VEN_MODE_BOOT_SYS  : 0)
                     | (g_dos      ? VEN_MODE_SOCEN     : 0)
                     | (g_golden_l1? VEN_MODE_GOLDEN_L1 : 0));
    }
    // --bp: arm the on-die HW breakpoint BEFORE releasing the core, so it halts the
    // first time the PC reaches g_bp (needs a VEN_DBG_CORE bitstream).
    if (g_bp_set) {
        if (rd(VEN_R_DBG_CAP) != VEN_DBG_CAP_MAGIC)
            fprintf(stderr, "ven_soc: --bp needs a DBG_CORE bitstream (cap=0x%x)\n", rd(VEN_R_DBG_CAP));
        wr(VEN_R_DBG_BP_ADDR, g_bp);
        wr(VEN_R_DBG_RUNCTL, 1u << 2);                   // bp_en
        fprintf(stderr, "ven_soc: HW breakpoint armed @ 0x%08x; will single-step %u\n", g_bp, g_steps);
    }
    wr(VEN_R_CTRL, VEN_CTRL_CORE_RUN);                   // release reset -> run
    {   // arm the patchable opcode-capture hook (default 0x3 = enable + DIV/IDIV class;
        // override via VEN_HOOK). DBG-only; harmless no-op on a non-DBG bitstream.
        const char* h = getenv("VEN_HOOK");
        wr(VEN_R_DBG_HOOK_CFG, h ? (uint32_t)strtoul(h, 0, 0) : 0x3u);
    }
    if (g_dos) spawn_kms();                              // default live VGA display (--no-kms to suppress)

    // service loop (F2: poll; F3+ can switch to the GIC interrupt on irq_out).
    uint64_t serviced = 0;
    uint64_t fptraps  = 0;           // F4 FP-op traps (FPATAN) serviced
    uint32_t intr_shadow = 0;        // last R_INTR value we wrote (vector|assert)
    uint32_t housekeep   = 0;
    static int  dbg = -1;
    static long dbg_last = 0;
    if (dbg < 0) dbg = getenv("VEN_DBG") ? 1 : 0;
    for (;;) {
        // service deferred signal requests in NORMAL context (stdio-safe): SIGTERM
        // dumps + quiesces + exits; SIGUSR1 prints a non-destructive live snapshot.
        if (g_term_req) { systrace_dump("term"); io_hist_dump(); vga_textdump(); vga_gfxdump(); ven_shutdown_quiesce(); _exit(0); }
        if (g_snap_req) { g_snap_req = 0; systrace_snapshot(); io_hist_dump();
                          memset(g_io_in_hist, 0, sizeof(g_io_in_hist));   // window the histogram
                          dbg_dump_core(); vga_gfxdump(); }
        if (g_fdump_req) { g_fdump_req = 0; dbg_halt_dump_resume(); }
        // --bp single-step trace: when the core halts at the HW breakpoint, walk the
        // trajectory instruction-by-instruction (the on-silicon fetch/control-flow trace
        // for a bug the sim can't reproduce). Each step: RUNCTL halt_req+step (0x3) ->
        // execute exactly one instruction -> re-park; then read the committed EIP/FSM.
        if (g_bp_set && (rd(VEN_R_DBG_RUNCTL) & (1u << 8))) {
            fprintf(stderr, "\n=== BP HIT @ 0x%08x — single-stepping %u instructions ===\n", g_bp, g_steps);
            for (uint32_t s = 0; s < g_steps; s++) {
                if (g_flush_step) wr(VEN_R_CTRL, VEN_CTRL_CORE_RUN | VEN_CTRL_FLUSH_REQ); // L1 invalidate
                wr(VEN_R_DBG_RUNCTL, (1u << 0) | (1u << 1));     // halt_req + W1P step (exec 1)
                int rehalt = 0;
                for (int g = 0; g < 4000000; g++) { if (rd(VEN_R_DBG_RUNCTL) & (1u << 8)) { rehalt = 1; break; } }
                uint32_t eip = rd(VEN_R_DBG_EIP), cs = rd(VEN_R_DBG_CS) & 0xffff;
                uint32_t dst = rd(VEN_R_DBG_STATE), esp = rd(VEN_R_DBG_ESP);
                fprintf(stderr, "[step %3u] %04x:%08x ESP=%08x FSM=0x%02x%s\n",
                        s, cs, eip, esp, dst & 0x3f, rehalt ? "" : "  <NO-REHALT: S_HALT/wedge>");
                if (!rehalt) { fprintf(stderr, "  core stopped re-parking (likely S_HALT) — done\n"); break; }
            }
            fprintf(stderr, "=== single-step trace done ===\n");
            dbg_dump_core();
            break;
        }
        uint32_t st = rd(VEN_R_STATUS);
        // F4 no-progress watchdog: fire if neither syscalls nor retire advance for
        // SYS_TIMEOUT_MS (a wedged proxy handshake / stuck core). Only when enabled,
        // so the per-iteration retire reads stay off the production hot path.
        if (g_quake && !g_bp_set && systrace_watchdog_enabled()) {
            uint32_t wlo = rd(VEN_R_RETIRE_LO);                       // read LO first (snapshots HI)
            uint64_t wret = ((uint64_t)rd(VEN_R_RETIRE_HI) << 32) | wlo;
            if (systrace_watchdog(ven_quake_syscalls(), wret, !!(st & VEN_ST_SYS_PEND))) {
                systrace_dump("watchdog"); dbg_dump_core();
                fprintf(stderr, "ven_soc: watchdog fired — stopping\n");
                break;
            }
        }
        if (dbg) {
            long now = dbg_now_ms();
            if (now - dbg_last >= 250) {
                dbg_last = now;
                uint32_t lo = rd(VEN_R_RETIRE_LO), hi = rd(VEN_R_RETIRE_HI);
                fprintf(stderr, "[dbg t=%ldms] retire=0x%x%08x st=0x%x ioaddr=0x%x iostat=0x%x intr=0x%x io=%llu\n",
                        now, hi, lo, st, rd(VEN_R_IO_ADDR), rd(VEN_R_IO_STATUS), rd(VEN_R_INTR),
                        (unsigned long long)serviced);
                if (g_quake)
                    fprintf(stderr, "[dbg t=%ldms] quake:%s\n", now,
                            systrace_heartbeat(ven_quake_video_total(), ven_quake_syscalls()));
                // silent-stall auto-dump: if retire is frozen for ~2.5s, dump the
                // on-die debug unit ONCE (the PC ring shows the trail into the stall).
                static uint64_t last_ret = 0; static int stall_n = 0, dumped = 0;
                uint64_t cur = ((uint64_t)hi << 32) | lo;
                if (cur == last_ret) { if (++stall_n == 10 && !dumped) { dbg_dump_core(); dumped = 1; } }
                else { stall_n = 0; dumped = 0; last_ret = cur; }
            }
        }
        if (st & VEN_ST_CPU_HUNG) { fprintf(stderr, "\nven_soc: CPU HUNG (bus_err=%d) after %llu io\n",
                                            !!(st & VEN_ST_BUS_ERR), (unsigned long long)serviced);
                                    systrace_dump("cpu-hung"); dbg_dump_core(); break; }
        if (st & VEN_ST_IO_REQ) {
            uint32_t ios  = rd(VEN_R_IO_STATUS);
            uint16_t port = (uint16_t)rd(VEN_R_IO_ADDR);
            if (ios & VEN_IO_IS_WRITE) {
                uint32_t v = rd(VEN_R_IO_WDATA);
                // soft-VGA install trigger: the first ATA READ-SECTORS (0x20) command to
                // the IDE cmd port = the boot sector load = POST is done + 0xC0000 is free.
                if (g_soft_vga && port == 0x1F7 && (v & 0xFF) == 0x20) g_post_done = 1;
                if (dbg) fprintf(stderr, "[io %llu] OUT 0x%03x = 0x%x\n",
                                 (unsigned long long)serviced, port, v);
                if (service_out(port, v)) {              // out 0xf4 -> done
                    wr(VEN_R_IO_CTRL, VEN_IO_ACK | VEN_IO_IRQ_CLR);
                    fprintf(stderr, "\nven_soc: isa-debug-exit after %llu io\n", (unsigned long long)serviced);
                    break;
                }
            } else {
                uint32_t rv = service_in(port, (uint8_t)rd(VEN_R_IO_SIZE));
                if (dbg) fprintf(stderr, "[io %llu] IN  0x%03x -> 0x%x\n",
                                 (unsigned long long)serviced, port, rv);
                wr(VEN_R_IO_RDATA, rv);
            }
            wr(VEN_R_IO_CTRL, VEN_IO_ACK | VEN_IO_IRQ_CLR);   // release the stalled core
            serviced++;
        }
        // soft-VGA: install the INT 10h stub + IVT[0x10] once POST is done (first ATA read).
        if (g_soft_vga && g_post_done && !g_vga_installed) { install_soft_vga(); g_vga_installed = 1; }

        // ---- F4 int-0x80 syscall proxy (the PS *is* the Linux kernel) ----------
        // The core stalls in S_SYSCALL_WAIT on a cd80; read {nr,args}, emulate the
        // syscall against the carveout (kernel memory effects land in g_ddr), then
        // post RET/GS and W1P SYS_CTRL.RESP_VALID to release the core. ORDERING is
        // the contract: stage DDR (incl. a flush of the core's L1) BEFORE commit,
        // and write RET/GS BEFORE SYS_CTRL (the core latches eax/gs on resp_valid).
        if (g_quake && (st & VEN_ST_SYS_PEND)) {
            uint32_t nr  = rd(VEN_R_SYS_NR);
            uint32_t ebx = rd(VEN_R_SYS_ARG0), ecx = rd(VEN_R_SYS_ARG1), edx = rd(VEN_R_SYS_ARG2);
            uint32_t esi = rd(VEN_R_SYS_ARG3), edi = rd(VEN_R_SYS_ARG4), ebp = rd(VEN_R_SYS_ARG5);
            // torn-read-free: read RETIRE_LO FIRST (it snapshots HI in the RTL), then HI.
            uint32_t rlo = rd(VEN_R_RETIRE_LO);
            uint64_t cyc = ((uint64_t)rd(VEN_R_RETIRE_HI) << 32) | rlo;
            struct ven_sys_result r;
            ven_quake_service(nr, ebx, ecx, edx, esi, edi, ebp, cyc, &r);
            __sync_synchronize();                            // make the DDR writes visible
            // invalidate the core's L1 (PS writes bypass it; ven_l1d is write-through
            // for PS reads but the core may hold a stale line of a written buffer).
            wr(VEN_R_CTRL, VEN_CTRL_CORE_RUN | VEN_CTRL_FLUSH_REQ);
            wr(VEN_R_SYS_RET, r.eax);
            wr(VEN_R_SYS_RESUME, 0);                         // the core derives resume EIP
            uint32_t sysctrl = VEN_SYS_RESP_VALID;
            if (r.apply_gs) { wr(VEN_R_SYS_GS, r.gs_base); sysctrl |= VEN_SYS_APPLY_GS; }
            wr(VEN_R_SYS_CTRL, sysctrl);                     // commit -> release S_SYSCALL_WAIT
            // commit-verify (SYS_COMMIT_VERIFY=1): SYS_PEND must clear after RESP_VALID;
            // if it doesn't, the W1P pulse was dropped or the core is stuck in
            // S_SYSCALL_WAIT — pinpoints a handshake fault on brand-new proxy RTL.
            if (systrace_commit_verify_enabled()) {
                int cleared = 0;
                for (int v = 0; v < 256; v++)
                    if (!(rd(VEN_R_STATUS) & VEN_ST_SYS_PEND)) { cleared = 1; break; }
                if (!cleared) {
                    fprintf(stderr, "\nven_soc: COMMIT NOT ACKED — SYS_PEND stuck after RESP_VALID "
                            "(%s eax=0x%x sys_status=0x%x)\n",
                            ven_quake_nr_name(nr), r.eax, rd(VEN_R_SYS_STATUS));
                    systrace_dump("commit-not-acked"); dbg_dump_core(); break;
                }
            }
            if (g_video_fd >= 0) {                           // stream captured frames to file
                static uint8_t vbuf[65536]; uint32_t got;
                while ((got = ven_quake_video_drain(vbuf, sizeof(vbuf))) > 0)
                    if (write(g_video_fd, vbuf, got) != (ssize_t)got) { /* best effort */ }
            }
            // observability: record the syscall into the ring/histogram + tee guest stdout.
            uint32_t sysargs[6] = { ebx, ecx, edx, esi, edi, ebp };
            int stflags = systrace_record(nr, sysargs, r.eax, r.unsupported,
                                          ven_quake_syscalls(), cyc);
            systrace_tee_stdout();
            if (dbg && (serviced % 2000 == 0))
                fprintf(stderr, "[sys %llu] %s eax=0x%x%s\n", (unsigned long long)serviced,
                        ven_quake_nr_name(nr), r.eax, r.apply_gs ? " +gs" : "");
            serviced++;
            if (stflags & SYSTRACE_LIVELOCK) {     // ADVISORY (opt-in SYS_LIVELOCK_N) — never abort
                fprintf(stderr, "\nven_soc: LIVELOCK SUSPECTED — %s repeated identically past the "
                        "SYS_LIVELOCK_N threshold (#%llu); advisory, run continues\n",
                        ven_quake_nr_name(nr), (unsigned long long)serviced);
                systrace_dump("livelock-suspected");
            }
            if (r.unsupported) { fprintf(stderr, "\nven_soc: UNSUPPORTED syscall %s (nr=%u, #%llu)\n",
                                         ven_quake_nr_name(nr), nr, (unsigned long long)serviced);
                                 systrace_dump("unsupported"); dbg_dump_core(); break; }
            if (r.should_exit) { fprintf(stderr, "\nven_soc: guest exit(%d) after %llu syscalls\n",
                                         r.exit_code, (unsigned long long)serviced);
                                 systrace_dump("exit"); break; }
        }

        // ---- F4 FP-op trap (PS-trap FPATAN; +VEN_FPTRAP bitstream) ------------
        // On D9 F3 the core stalls exposing ST0/ST1; the A53 computes atan2 and
        // commits. The window reads 0 on a non-FPTRAP bitstream (default case), so
        // the poll is inert there. Gated on g_quake (only Quake issues FPATAN).
        if (g_quake && (rd(VEN_R_FPT_STAT) & VEN_FPT_STAT_ACTIVE)) {
            service_fptrap();
            fptraps++;
        }

        // ---- F3 interrupt pump (the PS *is* the PIC + keyboard) ---------------
        if (g_dos) {
            uint32_t seam, desired;
            static int pit_pending = 0;
            // 1. USB keyboard -> scancode FIFO -> i8042 OBF (one byte at a time)
            hid_kbd_poll();
            hid_kbd_pump(g_i8042);
            // 2. PIT IRQ0 on WALL-CLOCK (must fire even while the core is HLT-waiting for
            //    the timer — a retire-paced tick deadlocks, since a HLT freezes the retire
            //    count below the threshold). ~18.2 Hz; the ISR is ~us of a 55 ms period so
            //    the mainline is never starved. The PIC-programmed gate (step 5) blocks the
            //    pre-pic_setup vector-0 that would otherwise derail early POST.
            if (ven_pit_irq0_ticks(g_pit) > 0) pit_pending = 1;
            // 3. drive the 8259 IR lines: IRQ0 (timer), IRQ1 (kbd), IRQ14 (IDE)
            ven_pic_set_irq(g_pic, 0,  pit_pending);
            ven_pic_set_irq(g_pic, 1,  g_i8042->irq(g_i8042));
            ven_pic_set_irq(g_pic, 14, g_ide->irq(g_ide));
            // 4. INTA boundary: the core took our injection -> intack the PIC model
            //    (ISR set/IRR clear, the RTL ven_pic inta path); clear the serviced
            //    source's latch (IRQ0 re-arms on the next tick).
            seam = rd(VEN_R_INTR);
            if (seam & VEN_INTR_INTA_SEEN) {
                uint8_t vec = ven_pic_intack(g_pic);
                if (vec == 0x08) pit_pending = 0;        // IRQ0 (PIC base 0x08) serviced
                wr(VEN_R_INTR, VEN_INTR_INTA_SEEN);      // W1C (and deassert)
                intr_shadow = 0;
            }
            // 5. mirror the PIC INT level + vector into the seam — but ONLY once the PIC
            //    is programmed (vector >= 0x08). An unprogrammed PIC (early POST, ICW2=0)
            //    would present vector 0; injecting that derails the core. Gate it off.
            uint8_t pv = ven_pic_peek_vector(g_pic);
            desired = (g_pic->irq(g_pic) && pv >= 0x08) ? (VEN_INTR_ASSERT | pv) : 0;
            if (desired != intr_shadow) { wr(VEN_R_INTR, desired); intr_shadow = desired; }
            // 6. periodic: publish the DAC for the fb_vnc daemon
            if ((++housekeep & 0xFFFF) == 0 && g_dac_dirty) { export_dac(); g_dac_dirty = 0; }
        }
        // (no busy-spin throttle here; F3 sleeps on the GIC irq via UIO instead.)
    }
    if (g_dos) { if (g_dac_dirty) export_dac(); hid_kbd_close(); }
    if (g_quake) {
        if (g_video_fd >= 0) {                           // flush any tail frames + close
            static uint8_t vbuf[65536]; uint32_t got;
            while ((got = ven_quake_video_drain(vbuf, sizeof(vbuf))) > 0)
                if (write(g_video_fd, vbuf, got) != (ssize_t)got) { /* best effort */ }
            close(g_video_fd);
        }
        fprintf(stderr, "ven_soc: quake done — %llu syscalls, %llu fpatans, %llu P5Q1 bytes captured%s\n",
                (unsigned long long)ven_quake_syscalls(),
                (unsigned long long)fptraps,
                (unsigned long long)ven_quake_video_total(),
                g_video_out ? "" : " (no --video; not written)");
        systrace_dump("done");          // final syscall histogram + ring (if VEN_SYS_RING)
    }
    ven_shutdown_quiesce();        // leave the PL→PS AXI clean for xmutil unloadapp
    return 0;
}
