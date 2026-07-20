// x87_cosim.cpp — co-simulated x87 FPU for the ao486 core.
//
// The ao486 has no hardware FPU: its ESC opcodes (0xD8-0xDF) are decoded and then
// trapped (INT 7) or NOP'd. This module implements the x87 in software so the RTL can
// forward each ESC op here (via a DPI-C hook) and get correct results, letting DOS
// Quake (a DJGPP program that needs the FPU) run.
//
// Key idea: the sim host is x86-64, whose `long double` is the SAME 80-bit extended
// format as the guest x87 stack registers. So we hold ST(0..7) as host long doubles and
// let the host FPU do the math — near bit-exact, including 80-bit intermediate precision.
//
// Memory operands: the harness resolves the effective address to a guest-physical byte
// pointer (into the behavioral DDR) and passes it in. Loads read through that pointer;
// stores write through it. The harness is responsible for cache coherency (see the RTL
// integration: FPU data accesses go through the CPU's own load/store path, or the dcache
// is kept coherent with DDR for the operand).
//
// Register/flag side effects the RTL must apply from the returned x87_result:
//   * FNSTSW AX / FSTSW AX  -> write status word to AX          (res.write_ax)
//   * FLD/FST etc.          -> nothing extra
// FCOM-family set only the x87 status word (C0..C3); code reads it back via FNSTSW AX.

#include <stdint.h>
#include <string.h>
#include <math.h>
#include <fenv.h>
#include <stdio.h>

static uint64_t g_fpu_ops = 0;   // debug: count of ESC ops forwarded to the model
static int      g_fnstsw_dbg = 0;

// DEBUG: log transcendental (still-libm) op firings to decide whether they fire
// before the DOS-Quake wedge (eip ~0x45xxx-0x5b1c3). Correlate [TRSC] lines'
// position in the run log against the eip-locked status lines.
static uint64_t g_trsc_tot = 0;
#include <stdlib.h>
static int fpu_dbg() { static int d=-1; if(d<0) d = getenv("VEN_FPU_DBG")?1:0; return d; }
static void trsc_log(const char* nm) {
    g_trsc_tot++;
    if (fpu_dbg() && (g_trsc_tot <= 60 || (g_trsc_tot % 50000) == 0))
        fprintf(stderr, "[TRSC] %-7s #%llu (fpu_ops=%llu)\n",
                nm, (unsigned long long)g_trsc_tot, (unsigned long long)g_fpu_ops);
}

// ---- x87 architectural state ------------------------------------------------
static long double ST[8];        // physical registers (rotated by TOP)
static int      TOP    = 0;      // 3-bit stack top pointer
static uint16_t CW     = 0x037F; // control word (default: round-nearest, 64-bit, all masked)
static uint16_t SW     = 0x0000; // status word
static uint16_t TW     = 0xFFFF; // tag word (2 bits/reg: 11=empty)

// ---- save/restore of the co-sim FPU state -----------------------------------
// The RTL snapshot (save_state) does NOT capture this C-side x87 state; without it
// a restored run diverges the moment Quake next touches the FPU. Serialize it too.
extern "C" int  ao486_fpu_state_bytes() { return (int)(sizeof(ST)+sizeof(TOP)+sizeof(CW)+sizeof(SW)+sizeof(TW)); }
extern "C" void ao486_fpu_state_save(void *dst) {
    uint8_t *p=(uint8_t*)dst;
    memcpy(p,ST,sizeof(ST)); p+=sizeof(ST);
    memcpy(p,&TOP,sizeof(TOP)); p+=sizeof(TOP);
    memcpy(p,&CW,sizeof(CW)); p+=sizeof(CW);
    memcpy(p,&SW,sizeof(SW)); p+=sizeof(SW);
    memcpy(p,&TW,sizeof(TW));
}
extern "C" void ao486_fpu_state_load(const void *src) {
    const uint8_t *p=(const uint8_t*)src;
    memcpy(ST,p,sizeof(ST)); p+=sizeof(ST);
    memcpy(&TOP,p,sizeof(TOP)); p+=sizeof(TOP);
    memcpy(&CW,p,sizeof(CW)); p+=sizeof(CW);
    memcpy(&SW,p,sizeof(SW)); p+=sizeof(SW);
    memcpy(&TW,p,sizeof(TW));
}

// tag values
#define TAG_VALID 0
#define TAG_ZERO  1
#define TAG_SPEC  2
#define TAG_EMPTY 3

// Mirror the guest x87 rounding-control (CW bits 10-11) onto the host FPU so both the
// long-double arithmetic and the lrint-based integer stores round identically:
//   00 nearest, 01 down, 10 up, 11 toward-zero (truncate).
static void apply_rounding() {
    switch ((CW >> 10) & 3) {           // SSE side (used by llrintl integer stores)
        case 0: fesetround(FE_TONEAREST);  break;
        case 1: fesetround(FE_DOWNWARD);   break;
        case 2: fesetround(FE_UPWARD);     break;
        case 3: fesetround(FE_TOWARDZERO); break;
    }
    // long double arithmetic runs on the host x87; mirror the guest's RC (bits 11-10)
    // AND precision-control (bits 9-8) into the host x87 control word so results are
    // bit-exact — including Quake's software renderer, which sets PC=24-bit. Without
    // matching PC the co-sim keeps 64-bit precision and float compares in Quake's inner
    // loops never converge (deterministic wedge). Rounds the mantissa but keeps the
    // 80-bit exponent range (unlike a float cast, which would clamp to +/-inf).
#if defined(__x86_64__) || defined(__i386__)
    unsigned short hcw;
    __asm__ __volatile__ ("fnstcw %0" : "=m" (hcw));
    hcw = (unsigned short)((hcw & ~0x0F00u) | (CW & 0x0F00u));   // guest RC(11-10)+PC(9-8)
    __asm__ __volatile__ ("fldcw %0" : : "m" (hcw));
#endif
}

static inline int    st_idx(int i)      { return (TOP + i) & 7; }
static inline long double& st(int i)    { return ST[st_idx(i)]; }
static inline int    tag_of(int phys)   { return (TW >> (phys*2)) & 3; }
static inline void   set_tag(int phys,int t){ TW = (uint16_t)((TW & ~(3u<<(phys*2))) | ((unsigned)t<<(phys*2))); }

// compute the tag for a value the way the 387 does
static int classify(long double v) {
    if (v == 0.0L) return TAG_ZERO;
    if (isnan(v) || isinf(v) || !isfinite(v)) return TAG_SPEC;
    // denormals/unsupported also SPEC; good enough here
    return TAG_VALID;
}

// SW top field (bits 11-13) mirrors TOP; keep it in sync when we hand SW out.
// ES (error-summary, bit7) and B (busy, bit15) reflect ONLY unmasked pending exceptions
// (CW bits0-5 are the exception masks, 1=masked). Recompute them at read time so FNSTSW is
// correct after any FLDCW/FNCLEX/FNINIT changes the mask. On a real 387/486, masked
// exceptions (e.g. the PE/inexact set by nearly every op) do NOT summarize to ES; the
// previous code latched ES for masked exceptions, so Quake (CW=0x037F, all masked) saw a
// stuck FPU-error state and spun forever in its FNSTSW poll before the render loop.
static inline uint16_t status_word() {
    uint16_t s = (uint16_t)((SW & ~0x3800u) | ((TOP & 7) << 11));
    s &= ~0x8080u;                                          // clear ES(7) + B(15)
    if ((s & 0x003f) & ~(CW & 0x003f)) s |= 0x8080u;        // set only if an UNMASKED exception is pending
    return s;
}

// status condition codes C0(0x0100) C1(0x0200) C2(0x0400) C3(0x4000)
#define C0 0x0100
#define C1 0x0200
#define C2 0x0400
#define C3 0x4000
static inline void clear_cc() { SW &= ~(C0|C1|C2|C3); }

// stack ops
static uint64_t g_push_ovf = 0;   // diagnostic: pushes that clobber a non-empty register
static uint64_t g_np = 0, g_npop = 0;   // total pushes / pops (leak = np>npop)
// ring buffer of recent (op<<8)|modrm to find the missing-pop that fills the stack
static uint16_t g_op_ring[128]; static unsigned g_op_ring_i = 0;
// detect an FP value that has blown up (Quake coords are ~+/-4096; anything >1e10 or inf/nan is corruption)
extern uint32_t g_trace_eip;   // fwd (defined ~line 876) so huge_check can tag the storing instruction
static void huge_check(long double v, const char* where) {
    if (!fpu_dbg()) return;
    if (isinf(v) || isnan(v) || fabsl(v) > 1e4L) {
        static uint64_t hc = 0;
        if ((++hc & (hc-1)) == 0 || hc <= 120) {
            fprintf(stderr, "[HUGE] %s v=%.4Le #%llu eip=%05x recent ops:", where, v, (unsigned long long)hc, (unsigned)g_trace_eip);
            for (int k=0;k<16;k++){ unsigned idx=(g_op_ring_i-16+k)&127; fprintf(stderr," %02x:%02x",g_op_ring[idx]>>8,g_op_ring[idx]&0xff); }
            fprintf(stderr, "\n"); fflush(stderr);
        }
    }
}
static int g_depth = 0, g_maxd = 0;   // net push-pop since start; leaking op sets new maxima
static void push(long double v) {
    g_np++;
    if (fpu_dbg()) { g_depth++;
        if (g_depth == 400 || g_depth == 800) {   // dump a clean leak window (op:modrm, oldest->newest)
            fprintf(stderr, "[LEAKWIN] depth=%d recent 64 ops:\n", g_depth);
            for (int k=0;k<64;k++){ unsigned idx=(g_op_ring_i-64+k)&127;
                fprintf(stderr," %02x:%02x", g_op_ring[idx]>>8, g_op_ring[idx]&0xff);
                if((k&15)==15) fprintf(stderr,"\n"); }
            fprintf(stderr,"\n"); fflush(stderr); }
        if (g_depth > g_maxd) g_maxd = g_depth; }
    int nt = (TOP - 1) & 7;
    if (tag_of(nt) != TAG_EMPTY) {      // x87 stack OVERFLOW (real 387 raises IE + writes indefinite)
        if (++g_push_ovf <= 24)
            fprintf(stderr, "[XOVF] stack overflow #%llu: TOP=%d->%d TW=%04x np=%llu npop=%llu\n",
                    (unsigned long long)g_push_ovf, TOP, nt, TW, (unsigned long long)g_np, (unsigned long long)g_npop);
        if (g_push_ovf == 1 && fpu_dbg()) {   // dump the op sequence that filled the stack
            fprintf(stderr, "[XOVF] recent ops (oldest->newest), format op:modrm :\n");
            for (int k = 0; k < 48; k++) {
                unsigned idx = (g_op_ring_i - 48 + k) & 127;
                fprintf(stderr, " %02x:%02x", g_op_ring[idx] >> 8, g_op_ring[idx] & 0xff);
                if ((k & 15) == 15) fprintf(stderr, "\n");
            }
            fprintf(stderr, "\n"); fflush(stderr);
        }
    }
    TOP = nt;
    ST[TOP] = v;
    set_tag(TOP, classify(v));
}
static long double pop() {
    g_npop++;
    if (fpu_dbg()) g_depth--;
    long double v = ST[TOP];
    set_tag(TOP, TAG_EMPTY);
    TOP = (TOP + 1) & 7;
    return v;
}
static void set_st(int i, long double v) { huge_check(v, "set_st"); int p = st_idx(i); ST[p] = v; set_tag(p, classify(v)); }

// ============================================================================
// Bit-exact ventium x87 FPU datapath (rtl/fpu/fpu_x87_pkg.sv + ventium_x87_pkg)
// via the DPI export module ao486-sim/stubs/ven_fpu_dpi.sv. These functions are
// the SAME combinational reference the ventium core uses and that verif/fpu87
// gates bit-exact vs Berkeley SoftFloat (47/47) — replacing the old host
// long double/libm math whose ULP/denormal/NaN divergences wedged DOS-Quake.
//
// floatx80 (80b) is passed split as {se[15:0]=v[79:64], sig[63:0]=v[63:0]}. The
// host `long double` IS the 80-bit extended format, so its low 10 bytes ARE the
// floatx80 bits — convert by plain memcpy (no rounding, no host-x87 round-trip).
//
// The PC-mirroring host FLDCW hack in apply_rounding() is now unnecessary for
// these ops (fx_* take pc directly); it is retained only for the libm-based
// transcendentals (FSIN/FCOS/F2XM1/FYL2X/FPATAN/FPTAN/FSINCOS/FPREM/FSCALE),
// which remain APPROXIMATE (multi-cycle RTL modules, not DPI-able functions).
// ============================================================================
#include "svdpi.h"
#include "Vsystem__Dpi.h"

// QEMU-8.2-faithful softfloat x87 transcendentals (F2XM1/FPATAN/FYL2X/FYL2XP1).
// These replace the host libm (expl/logl, atan2l, log2l) whose ULP/cancellation
// divergences from QEMU drift DOS-Quake's timedemo off the (passing) QEMU
// trajectory until a value blows the stack. FSIN/FCOS/FPTAN/FSINCOS stay on host
// double math (see below) because QEMU computes THOSE with host glibc `double`.
#include "x87_trans_qref.h"

// QEMU forces floatx80_precision_x (64-bit) for the softfloat transcendentals,
// regardless of the guest PC. The qref port evaluates its polynomials in host
// `long double` (the x87 registers), so the host x87 must be in 64-bit precision
// + round-nearest before the call — otherwise Quake's PC=24 software renderer
// (apply_rounding mirrored PC=24 onto the host x87) would round the Horner
// intermediates to single precision and wreck the result. The final RC-honored
// rounding is done in software inside qref (via the rc arg), so only PC/RNE here.
static inline void qref_host_prec64() {
    fesetround(FE_TONEAREST);                 // SSE + x87 RC = round-to-nearest
#if defined(__x86_64__) || defined(__i386__)
    unsigned short cw = 0x037F;               // x87 CW: mask all, PC=64-bit, RC=RNE
    __asm__ __volatile__("fldcw %0" : : "m"(cw));
#endif
}
static const long double X87_MAXTAN = 9223372036854775808.0L;   // 2^63 (QEMU MAXTAN)

static void ven_scope() {
    static int done = 0; if (done) return;
    const char* cand[] = { "TOP.system.u_ven_fpu_dpi", "TOP.u_ven_fpu_dpi",
                           "system.u_ven_fpu_dpi", nullptr };
    for (int i = 0; cand[i]; i++) { svScope s = svGetScopeFromName(cand[i]);
        if (s) { svSetScope(s); done = 1; return; } }
    done = 1;   // last resort: export may resolve the unique scope itself
}
static inline void ld_bits(long double x, unsigned long long* sig, unsigned short* se) {
    unsigned char b[sizeof(long double)]; memcpy(b, &x, sizeof(x));
    memcpy(sig, b, 8); memcpy(se, b + 8, 2);
}
static inline long double bits_ld(unsigned long long sig, unsigned short se) {
    unsigned char b[sizeof(long double)]; memset(b, 0, sizeof b);
    memcpy(b, &sig, 8); memcpy(b + 8, &se, 2);
    long double x; memcpy(&x, b, sizeof x); return x;
}
// Read ST(i) as a SOURCE operand with x87 stack-underflow semantics: reading a register
// tagged EMPTY (tag=11) is a stack fault -> raise IE (invalid-operation, sticky; masked at
// Quake's CW=0x037F so it silently continues), clear C1 (C1=0 marks underflow, not overflow),
// and return the x87 QNaN INDEFINITE (ffff:c000000000000000). The old code returned whatever
// STALE long double was still sitting in the physically-popped register (e.g. 0, or a wrong
// exponent like 0001:87ae...), so DJGPP's cvt/dtoa — which detects the end of digit
// generation via the underflow/indefinite — never terminated, spilling a 36-digit string that
// overflowed Draw_ConsoleBackground's stack (`lines`) and #GP'd the conback blit at 0x55efd.
static inline long double rd_st(int i) {
    int p = st_idx(i);
    if (tag_of(p) == TAG_EMPTY) {
        SW |= 0x0001;          // IE (stack fault / invalid operation)
        SW &= ~0x0200;         // C1 = 0  (underflow, per Intel SDM)
        return bits_ld(0xC000000000000000ull, 0xFFFFu);   // QNaN indefinite
    }
    return ST[p];
}
static inline unsigned char rc_bits() { return (unsigned char)((CW >> 10) & 3); }
static inline unsigned char pc_bits() { return (unsigned char)((CW >> 8)  & 3); }
static inline void or_arith_flags(unsigned char f) {   // {ie,ze,oe,ue,pe}=bits4..0
    if (f & 0x10) SW |= 0x0001; if (f & 0x08) SW |= 0x0004;
    if (f & 0x04) SW |= 0x0008; if (f & 0x02) SW |= 0x0010;
    if (f & 0x01) SW |= 0x0020;
}
static inline void or_ouf_flags(unsigned char f) {     // {oe,ue,pe}=bits2..0 (FST)
    if (f & 0x04) SW |= 0x0008; if (f & 0x02) SW |= 0x0010;
    if (f & 0x01) SW |= 0x0020;
}
// Bit-exact FADD/FMUL/FSUB(4)/FSUBR(5)/FDIV(6)/FDIVR(7) via ventium f_eval.
static long double ven_arith(int sub, long double a, long double b) {
    ven_scope();
    unsigned long long as, bs, rs; unsigned short ae, be, re; unsigned char fl = 0;
    ld_bits(a, &as, &ae); ld_bits(b, &bs, &be);
    ven_feval((unsigned char)sub, as, ae, bs, be, rc_bits(), pc_bits(), &rs, &re, &fl);
    or_arith_flags(fl);
    return bits_ld(rs, re);
}

// ---- memory operand conversions (guest little-endian) -----------------------
// FLD m32/m64: exact widening float32/float64 -> floatx80 via ventium fx_from_f*.
static long double ld_f32(const uint8_t* m){ ven_scope(); unsigned int u; memcpy(&u,m,4);
    unsigned long long rs; unsigned short re; ven_from_f32(u,&rs,&re); return bits_ld(rs,re); }
static long double ld_f64(const uint8_t* m){ ven_scope(); unsigned long long u; memcpy(&u,m,8);
    unsigned long long rs; unsigned short re; ven_from_f64(u,&rs,&re); return bits_ld(rs,re); }
static long double ld_f80(const uint8_t* m){ long double x; memcpy(&x,m,10); return x; } // host long double is 80-bit (10 significant bytes)
// FILD: signed int -> floatx80 is EXACT via the host cast (== fx_from_int).
static long double ld_i16(const uint8_t* m){ int16_t v; memcpy(&v,m,2); return (long double)v; }
static long double ld_i32(const uint8_t* m){ int32_t v; memcpy(&v,m,4); return (long double)v; }
static long double ld_i64(const uint8_t* m){ int64_t v; memcpy(&v,m,8); return (long double)v; }

// FST m32/m64: RC-honored narrowing floatx80 -> float32/float64 via ventium fx_to_f*_ex.
static void st_f32(uint8_t* m,long double x){ ven_scope(); huge_check(x,"st_f32");
    unsigned long long s; unsigned short e; ld_bits(x,&s,&e);
    unsigned int f=0; unsigned char fl=0; ven_to_f32(s,e,rc_bits(),&f,&fl);
    or_ouf_flags(fl); memcpy(m,&f,4); }
static void st_f64(uint8_t* m,long double x){ ven_scope(); huge_check(x,"st_f64");
    unsigned long long s; unsigned short e; ld_bits(x,&s,&e);
    unsigned long long f=0; unsigned char fl=0; ven_to_f64(s,e,rc_bits(),&f,&fl);
    or_ouf_flags(fl); memcpy(m,&f,8); }
static void st_f80(uint8_t* m,long double x){ memcpy(m,&x,10); }
// FIST/FISTP: RC-honored floatx80 -> signed int via ventium fx_to_int_ex.
// flags: bit0=invalid(#IA), bit1=inexact(#PE).
static void st_int(uint8_t* m,long double x,int width){ ven_scope();
    unsigned long long s; unsigned short e; ld_bits(x,&s,&e);
    unsigned long long v=0; unsigned char fl=0; ven_to_int(s,e,(unsigned char)width,rc_bits(),&v,&fl);
    if (fl & 1) SW |= 0x0001; if (fl & 2) SW |= 0x0020;
    memcpy(m,&v,width/8); }
static void st_i16(uint8_t* m,long double x){ st_int(m,x,16); }
static void st_i32(uint8_t* m,long double x){ st_int(m,x,32); }
static void st_i64(uint8_t* m,long double x){ st_int(m,x,64); }

// ---- result the RTL may need to apply back to the CPU -----------------------
struct x87_result {
    int      write_ax;      // 1 => write status word into AX (FNSTSW AX)
    uint16_t ax_value;      // the status word
    int      mem_write;     // bytes written to the operand pointer (store ops)
};

// arithmetic helpers with the eight ALU ops (D8/DC group index). The op index is
// the x87 group field (0 add,1 mul,4 sub a-b,5 subr b-a,6 div a/b,7 divr b/a),
// which is EXACTLY the `sub` encoding ventium f_eval expects, so we forward it
// straight through. 2/3 (FCOM/FCOMP) are compares handled by do_compare().
static long double alu(int op, long double a, long double b) {
    if (op == 2 || op == 3) return a;
    return ven_arith(op, a, b);        // bit-exact via ventium f_eval
}
// FCOM/FUCOM: bit-exact condition codes {C3,C2,C0} via ventium fcom_codes
// (unordered=111 on any NaN, +0==-0 equal).
static void do_compare(long double a, long double b) {
    ven_scope();
    clear_cc();
    unsigned long long as, bs; unsigned short ae, be; unsigned char codes = 0;
    ld_bits(a, &as, &ae); ld_bits(b, &bs, &be);
    ven_fcom(as, ae, bs, be, &codes);
    if (codes & 0x4) SW |= C3;
    if (codes & 0x2) SW |= C2;
    if (codes & 0x1) SW |= C0;
}

// FPU environment save/restore (32-bit protected-mode layout, 28-byte env):
//   [0]=CW [4]=SW [8]=TW [12..27]=FIP/FCS/FOO/FOS (not modeled -> 0).
static void store_env(uint8_t* m) {
    m[0]=CW&0xff; m[1]=CW>>8; m[2]=m[3]=0;
    uint16_t sw = status_word(); m[4]=sw&0xff; m[5]=sw>>8; m[6]=m[7]=0;
    m[8]=TW&0xff; m[9]=TW>>8; m[10]=m[11]=0;
    for (int k=12;k<28;k++) m[k]=0;
}
static void load_env(const uint8_t* m) {
    CW = (uint16_t)(m[0] | (m[1]<<8));
    uint16_t sw = (uint16_t)(m[4] | (m[5]<<8));
    SW  = (uint16_t)(sw & ~0x3800u);   // TOP lives in the SW image; keep it separate here
    TOP = (sw >> 11) & 7;
    TW  = (uint16_t)(m[8] | (m[9]<<8));
    apply_rounding();
}

// ---- main dispatch ----------------------------------------------------------
// op   : ESC opcode byte 0xD8..0xDF
// modrm: the ModRM byte
// mem  : pointer to the operand in guest memory (valid when modrm<0xC0), else NULL
// Returns the side effects for the RTL to apply.
extern "C" x87_result x87_execute(uint8_t op, uint8_t modrm, uint8_t* mem) {
    x87_result r; r.write_ax = 0; r.ax_value = 0; r.mem_write = 0;
    g_op_ring[g_op_ring_i++ & 127] = (uint16_t)((op << 8) | modrm);
    // Count UNHANDLED ops that should change the stack (fall to default:break = silent NOP):
    // FFREEP DF C0-C7, FXTRACT/FPREM1/FDECSTP/FINCSTP D9 F4-F7, FBSTP DF /6.
    if (fpu_dbg()) {
        static uint64_t unh[16] = {0};
        int k = -1;
        if (op==0xDF && modrm>=0xC0 && modrm<=0xC7) k=0;                 // FFREEP
        else if (op==0xD9 && modrm==0xF4) k=1;                            // FXTRACT
        else if (op==0xD9 && modrm==0xF5) k=2;                            // FPREM1
        else if (op==0xD9 && modrm==0xF6) k=3;                            // FDECSTP
        else if (op==0xD9 && modrm==0xF7) k=4;                            // FINCSTP
        else if (op==0xDF && modrm<0xC0 && ((modrm>>3)&7)==6) k=5;        // FBSTP m80
        if (k>=0) { const char* nm[]={"FFREEP","FXTRACT","FPREM1","FDECSTP","FINCSTP","FBSTP"};
            if ((++unh[k] & (unh[k]-1))==0) fprintf(stderr,"[UNH] %s op=%02x modrm=%02x count=%llu\n",nm[k],op,modrm,(unsigned long long)unh[k]); }
    }
    int reg  = (modrm >> 3) & 7;   // opcode extension / group index
    int rm   = modrm & 7;          // ST(i) selector for register form
    int ismem = (modrm < 0xC0);
    // Operand address unmapped / outside the modeled DDR (mem==NULL): on real hardware
    // this would #PF; here just skip the access so we never dereference NULL.
    if (ismem && !mem) return r;
    // Track x87 exception flags via the host FPU: clear host flags, run the op, then OR
    // the raised exceptions into the (sticky) status word. The FPU capability probe checks
    // these (e.g. ZE after 1/0), and code paths branch on the status word.
    feclearexcept(FE_ALL_EXCEPT);
    apply_rounding();   // re-assert guest RC+PC on the host x87 before this op's arithmetic
                        // (host CW could have been perturbed since the last FLDCW)

    switch (op) {
    // ---- D8: FADD/FMUL/FCOM/FSUB/FDIV  m32real | ST(i) --------------------
    case 0xD8: {
        long double b = ismem ? ld_f32(mem) : rd_st(rm);
        if (reg == 2 || reg == 3) { do_compare(rd_st(0), b); if (reg==3) pop(); }
        else set_st(0, alu(reg, rd_st(0), b));
        break;
    }
    // ---- DC: same ops, m64real | ST(i) (dest ST(i) for register form) ----
    case 0xDC: {
        if (ismem) {
            long double b = ld_f64(mem);
            if (reg == 2 || reg == 3) { do_compare(rd_st(0), b); if (reg==3) pop(); }
            else set_st(0, alu(reg, rd_st(0), b));
        } else {
            // register form: dest = ST(i), src = ST(0); FSUB/FSUBR/FDIV/FDIVR reversed
            int o = reg;
            if (o==4) o=5; else if (o==5) o=4; else if (o==6) o=7; else if (o==7) o=6;
            // DC /2,/3 register form is FCOM/FCOMP ST(i): it compares ST(0) against ST(i),
            // and FCOMP must pop. Operands were reversed (inverting C0) and the pop was
            // missing, so every FCOMP ST(i) leaked an x87 stack slot.
            if (reg == 2 || reg == 3) { do_compare(rd_st(0), rd_st(rm)); if (reg == 3) pop(); }
            else set_st(rm, alu(o, rd_st(rm), rd_st(0)));
        }
        break;
    }
    // ---- DE: FIADD.. m16int | FADDP.. ST(i),ST(0) then pop ----------------
    case 0xDE: {
        if (ismem) {
            long double b = ld_i16(mem);
            if (reg == 2 || reg == 3) { do_compare(rd_st(0), b); if (reg==3) pop(); }
            else set_st(0, alu(reg, rd_st(0), b));
        } else {
            if (modrm == 0xD9) { do_compare(rd_st(0), rd_st(1)); pop(); pop(); break; } // FCOMPP: ST(0) vs ST(1) (operands were reversed -> C0 inverted -> printf %f rounded 1.06 up to "1.07")
            int o = reg; if (o==4) o=5; else if (o==5) o=4; else if (o==6) o=7; else if (o==7) o=6;
            set_st(rm, alu(o, rd_st(rm), rd_st(0)));
            pop();
        }
        break;
    }
    // ---- D9: FLD/FST/FSTP m32real, FLDCW/FSTCW, and reg-form specials ------
    case 0xD9: {
        if (ismem) {
            switch (reg) {
                case 0: push(ld_f32(mem)); break;                 // FLD m32
                case 2: st_f32(mem, rd_st(0)); r.mem_write=4; break; // FST m32
                case 3: st_f32(mem, rd_st(0)); r.mem_write=4; pop(); break; // FSTP m32
                case 4: load_env(mem); break;                          // FLDENV
                case 5: CW = (uint16_t)(mem[0] | (mem[1]<<8)); apply_rounding(); break; // FLDCW
                case 6: store_env(mem); r.mem_write=28; break;         // FSTENV
                case 7: mem[0]=CW&0xff; mem[1]=CW>>8; r.mem_write=2; break; // FSTCW
                default: break;
            }
        } else {
            switch (modrm) {
                case 0xC0: case 0xC1: case 0xC2: case 0xC3:
                case 0xC4: case 0xC5: case 0xC6: case 0xC7: push(rd_st(rm)); break; // FLD ST(i)
                case 0xC8: case 0xC9: case 0xCA: case 0xCB:
                case 0xCC: case 0xCD: case 0xCE: case 0xCF: {                    // FXCH ST(i)
                    long double t = rd_st(0); set_st(0, rd_st(rm)); set_st(rm, t); break; }
                case 0xD0: break;                                  // FNOP
                case 0xE0: set_st(0, -rd_st(0)); break;            // FCHS
                case 0xE1: set_st(0, fabsl(rd_st(0))); break;      // FABS
                case 0xE4: do_compare(rd_st(0), 0.0L); break;      // FTST
                case 0xE5: {                                       // FXAM
                    clear_cc(); long double v=st(0);
                    if (tag_of(st_idx(0))==TAG_EMPTY) SW|=(C3|C0);
                    else if (isnan(v)) SW|=C0;
                    else if (isinf(v)) SW|=(C2|C0);
                    else if (v==0.0L)  SW|=C3;
                    else               SW|=C2;
                    if (signbit(v)) SW|=C1;
                    break; }
                case 0xE8: push(1.0L); break;                      // FLD1
                case 0xE9: push(3.321928094887362347870319429L); break; // FLDL2T (log2 10)
                case 0xEA: push(1.442695040888963407359924681L); break; // FLDL2E (log2 e)
                case 0xEB: push(3.141592653589793238462643383L); break; // FLDPI
                case 0xEC: push(0.301029995663981195213738895L); break; // FLDLG2 (log10 2)
                case 0xED: push(0.693147180559945309417232121L); break; // FLDLN2 (ln 2)
                case 0xEE: push(0.0L); break;                      // FLDZ
                case 0xF0: { trsc_log("F2XM1"); qref_host_prec64();                        // F2XM1 (2^x-1), QEMU softfloat
                    set_st(0, qref::qf2xm1(st(0), rc_bits())); } break;
                case 0xF1: { trsc_log("FYL2X"); qref_host_prec64();                         // FYL2X: ST1*log2(ST0), then pop
                    long double v = qref::qfyl2x(st(1), st(0), rc_bits()); set_st(1, v); pop(); } break;
                case 0xF2: { trsc_log("FPTAN"); long double x = st(0);                       // FPTAN: tan(double), push 1.0
                    if (fabsl(x) >= X87_MAXTAN) { SW |= C2; }                                // out of range: C2=1, ST0 kept
                    else { set_st(0, (long double)tan((double)x)); push(1.0L); SW &= ~C2; } } break;
                case 0xF3: { trsc_log("FPATAN"); qref_host_prec64();                         // FPATAN: atan2(ST1,ST0), then pop
                    long double v = qref::qfpatan(st(1), st(0), rc_bits()); set_st(1, v); pop(); } break;
                case 0xF9: { trsc_log("FYL2XP1"); qref_host_prec64();                        // FYL2XP1: ST1*log2(ST0+1), then pop
                    long double v = qref::qfyl2xp1(st(1), st(0), rc_bits()); set_st(1, v); pop(); } break;
                case 0xF8: { trsc_log("FPREM"); long double a=st(0),b=st(1); set_st(0, fmodl(a,b)); SW&=~C2; } break; // FPREM
                case 0xFA: {                                       // FSQRT (bit-exact fx_sqrt)
                    ven_scope();
                    unsigned long long s, rs; unsigned short e, re; unsigned char fl = 0;
                    ld_bits(rd_st(0), &s, &e);
                    ven_fsqrt(s, e, rc_bits(), pc_bits(), &rs, &re, &fl);
                    set_st(0, bits_ld(rs, re));
                    if (fl & 4) { clear_cc(); SW |= C2; }          // neg/-0 radicand
                    if (fl & 1) SW |= 0x0001;                      // IE
                    if (fl & 2) SW |= 0x0020;                      // PE
                    break; }
                case 0xFB: { trsc_log("FSINCOS"); long double x = st(0);                     // FSINCOS: sin/cos(double)
                    if (fabsl(x) >= X87_MAXTAN) { SW |= C2; }                                // out of range: C2=1, ST0 kept
                    else { double xd=(double)x; set_st(0,(long double)sin(xd)); push((long double)cos(xd)); SW &= ~C2; } } break;
                case 0xFC: {                                       // FRNDINT (bit-exact)
                    ven_scope();
                    unsigned long long s, rs; unsigned short e, re; unsigned char pe = 0;
                    ld_bits(rd_st(0), &s, &e);
                    ven_frndint(s, e, rc_bits(), pc_bits(), &rs, &re, &pe);
                    set_st(0, bits_ld(rs, re));
                    if (pe) SW |= 0x0020;                          // PE
                    break; }
                case 0xFD: { trsc_log("FSCALE"); long double sc=st(1); set_st(0, st(0)*powl(2.0L, truncl(sc))); } break; // FSCALE
                case 0xFE: { trsc_log("FSIN"); long double x = st(0);                       // FSIN: sin(double), QEMU-style
                    if (fabsl(x) >= X87_MAXTAN) { SW |= C2; }                                // out of range: C2=1, ST0 kept
                    else { set_st(0, (long double)sin((double)x)); SW &= ~C2; } } break;
                case 0xFF: { trsc_log("FCOS"); long double x = st(0);                       // FCOS: cos(double), QEMU-style
                    if (fabsl(x) >= X87_MAXTAN) { SW |= C2; }                                // out of range: C2=1, ST0 kept
                    else { set_st(0, (long double)cos((double)x)); SW &= ~C2; } } break;
                default: break;
            }
        }
        break;
    }
    // ---- DD: FLD/FST/FSTP m64real, FSTSW m2byte, reg FFREE/FST/FSTP/FUCOM --
    case 0xDD: {
        if (ismem) {
            switch (reg) {
                case 0: push(ld_f64(mem)); break;                 // FLD m64
                case 2: st_f64(mem, rd_st(0)); r.mem_write=8; break; // FST m64
                case 3: st_f64(mem, rd_st(0)); r.mem_write=8; pop(); break; // FSTP m64
                case 4: load_env(mem); for(int k=0;k<8;k++) ST[k]=ld_f80(mem+28+k*10); break;    // FRSTOR
                case 6: store_env(mem); for(int k=0;k<8;k++) st_f80(mem+28+k*10, ST[k]);          // FSAVE
                        r.mem_write=108; TOP=0; CW=0x037F; SW=0; TW=0xFFFF; apply_rounding(); break;
                case 7: { uint16_t s=status_word(); mem[0]=s&0xff; mem[1]=s>>8; r.mem_write=2; } break; // FSTSW
                default: break;
            }
        } else {
            switch (reg) {
                case 0: set_tag(st_idx(rm), TAG_EMPTY); break;    // FFREE
                case 2: set_st(rm, rd_st(0)); break;              // FST ST(i)
                case 3: set_st(rm, rd_st(0)); pop(); break;       // FSTP ST(i)
                case 4: do_compare(rd_st(0), rd_st(rm)); break;   // FUCOM
                case 5: do_compare(rd_st(0), rd_st(rm)); pop(); break;  // FUCOMP
                default: break;
            }
        }
        break;
    }
    // ---- DB: FILD/FIST/FISTP m32int, FLD/FSTP m80, FINIT/FCLEX -------------
    case 0xDB: {
        if (ismem) {
            switch (reg) {
                case 0: push(ld_i32(mem)); break;                 // FILD m32
                case 1: st_i32(mem, rd_st(0)); r.mem_write=4; pop(); break; // FISTTP (trunc) ~ treat as store+pop
                case 2: st_i32(mem, rd_st(0)); r.mem_write=4; break; // FIST m32
                case 3: st_i32(mem, rd_st(0)); r.mem_write=4; pop(); break; // FISTP m32
                case 5: push(ld_f80(mem)); break;                 // FLD m80
                case 7: st_f80(mem, rd_st(0)); r.mem_write=10; pop(); break; // FSTP m80
                default: break;
            }
        } else {
            switch (modrm) {
                case 0xE2: SW &= ~0xFF; break;                    // FNCLEX (clear exceptions)
                case 0xE3: TOP=0; CW=0x037F; SW=0; TW=0xFFFF; apply_rounding(); break; // FNINIT
                default: break; // FCMOVcc/FCOMI/FUCOMI: uncommon in Quake
            }
        }
        break;
    }
    // ---- DF: FILD/FISTP m16int, FILD/FISTP m64int, FNSTSW AX ---------------
    case 0xDF: {
        if (ismem) {
            switch (reg) {
                case 0: push(ld_i16(mem)); break;                 // FILD m16
                case 2: st_i16(mem, rd_st(0)); r.mem_write=2; break; // FIST m16
                case 3: st_i16(mem, rd_st(0)); r.mem_write=2; pop(); break; // FISTP m16
                case 5: push(ld_i64(mem)); break;                 // FILD m64
                case 7: st_i64(mem, rd_st(0)); r.mem_write=8; pop(); break; // FISTP m64
                default: break;
            }
        } else {
            if (modrm == 0xE0) { r.write_ax = 1; r.ax_value = status_word(); } // FNSTSW AX
        }
        break;
    }
    // ---- DA: FIADD.. m32int | FUCOMPP ------------------------------------
    case 0xDA: {
        if (ismem) {
            long double b = ld_i32(mem);
            if (reg == 2 || reg == 3) { do_compare(rd_st(0), b); if (reg==3) pop(); }
            else set_st(0, alu(reg, rd_st(0), b));
        } else if (modrm == 0xE9) { do_compare(rd_st(0), rd_st(1)); pop(); pop(); } // FUCOMPP
        break;
    }
    default: break;
    }
    // Fold host-FPU exceptions into the sticky x87 status word — but ONLY for the ops
    // still computed with host libm (the transcendentals: F2XM1/FYL2X/FPTAN/FPATAN/
    // FPREM/FSINCOS/FSCALE/FSIN/FCOS). Every other op now goes through the bit-exact
    // ventium DPI, which sets its OWN architectural flags (ven_arith IE/ZE/OE/UE/PE,
    // st_int IE/PE, FSQRT IE/PE, FRNDINT PE, FST OE/UE/PE). For those ops the blanket
    // host fold is not only redundant, it is WRONG: host x87 raises a spurious FE_INVALID
    // whenever classify()'s `v==0.0L` compare (or a long-double load) touches an
    // UNSUPPORTED 80-bit encoding — e.g. an unnormal (exp!=0, J-bit=0) or SNaN that DOS-
    // Quake holds in a register. Pure moves (FLD/FST/FSTP/FLD ST(i)/FXCH) NEVER raise IE
    // on a real 387/486, so folding that host FE_INVALID set a bogus IE (-> ES whenever
    // the guest CW leaves IE unmasked, e.g. CW=0x037a), perturbing Quake's FNSTSW poll.
    int host_fold = (op == 0xD9 && (modrm==0xF0||modrm==0xF1||modrm==0xF2||modrm==0xF3||
                                    modrm==0xF8||modrm==0xF9||modrm==0xFB||modrm==0xFD||
                                    modrm==0xFE||modrm==0xFF));
    if (host_fold) {
        int exc = fetestexcept(FE_DIVBYZERO | FE_INVALID | FE_OVERFLOW | FE_UNDERFLOW | FE_INEXACT);
        if (exc & FE_INVALID)   SW |= 0x0001;   // IE
        if (exc & FE_DIVBYZERO) SW |= 0x0004;   // ZE
        if (exc & FE_OVERFLOW)  SW |= 0x0008;   // OE
        if (exc & FE_UNDERFLOW) SW |= 0x0010;   // UE
        if (exc & FE_INEXACT)   SW |= 0x0020;   // PE
    }
    // ES (bit7, error summary) and B (bit15, busy) are asserted ONLY when an UNMASKED
    // exception is pending: the low 6 CW bits are the masks (1=masked). A masked
    // exception still sets its sticky flag (bits 0-5) but leaves ES clear so the FPU
    // silently continues. Quake runs with everything masked (CW=0x037F), so the old
    // unconditional `if (SW & 0x3f) SW |= ES` made every masked PE/UE/IE look like an
    // unmasked fault, wedging its FNSTSW error-poll loop forever. Recompute ES per op
    // from (pending & ~mask) so masked exceptions no longer raise it.
    if ((SW & 0x003f) & ~(CW & 0x003f)) SW |= 0x8080;   // ES + B on any UNMASKED exception
    else                                SW &= ~0x8080;
    return r;
}

// ---- harness glue: DPI entry points called from the RTL ---------------------
// The behavioral DDR (guest physical memory) lives in sim_main.cpp.
extern uint64_t *ddr;
static const uint64_t DDR_BYTES = (1ull << 27);   // 128 MiB (must match sim_main.cpp DDR_WORDS)
// go32-corruption write-watch hook (defined in sim_main.cpp).
extern "C" void ao486_watch_store(unsigned int phys, unsigned long long neww,
                                  unsigned long long oldw, int mw);

// 32-bit paging walk: linear -> physical. When paging is off, physical == linear.
// Handles 4KB and 4MB (PSE) pages. Falls back to identity on a not-present entry.
static uint64_t translate(uint32_t lin, uint32_t cr3, int pg) {
    if (!pg) return lin;
    const uint8_t *m = (const uint8_t*)ddr;
    uint32_t pde_a = (cr3 & 0xFFFFF000u) + ((lin >> 22) & 0x3FF) * 4u;
    if (pde_a + 4 > DDR_BYTES) return lin;
    uint32_t pde; memcpy(&pde, m + pde_a, 4);
    if (!(pde & 1)) return lin;
    if (pde & 0x80) return (pde & 0xFFC00000u) | (lin & 0x003FFFFFu);   // 4MB page
    uint32_t pte_a = (pde & 0xFFFFF000u) + ((lin >> 12) & 0x3FF) * 4u;
    if (pte_a + 4 > DDR_BYTES) return lin;
    uint32_t pte; memcpy(&pte, m + pte_a, 4);
    if (!(pte & 1)) return lin;
    return (pte & 0xFFFFF000u) | (lin & 0xFFFu);
}

// Paging state, captured every cycle by a separate always-on probe (CR3/CR0.PG live in
// a different pipeline module than the FPU operand address, so we snapshot them here
// rather than thread them through the per-op hook).
static uint32_t g_cr3 = 0; static int g_cr0pg = 0;
extern "C" void ao486_paging(int cr3, int pg) { g_cr3 = (uint32_t)cr3; g_cr0pg = pg ? 1 : 0; }

// ---- read-side memory coherency for FPU operands --------------------------------
// The co-sim reads FPU operands DIRECTLY from the behavioral DDR image. The ao486 L2 is
// WRITE-THROUGH (every CPU store asserts DDRAM_WE; the L2 "dirty" bit means invalid, not
// modified), so ddr[] IS the authoritative copy — but a store from a just-retired prior
// instruction (e.g. `mov [m],cx ; FLDCW [m]`, or `FSTP [m] ; ... ; FLD [m]`) is still in
// flight in the CPU write path (avalon_mem -> interconnect -> write-through L2 ->
// DDRAM_WE -> ddr_service) and only lands in ddr[] a few cycles later. Reading the
// operand the instant the ESC op retires therefore returns STALE bytes (measured: an
// FLD m80 operand's own bytes change ~2-3 cycles after the retire).
//
// Fix: a memory-READ op is not applied until the CPU write path has DRAINED — it has both
// (a) aged >= FPU_READ_MIN guest cycles (so a store issued at the op's retire has reached
// DDRAM_WE) and (b) been quiet (no DDR write beat) for FPU_QUIET consecutive cycles (so
// the whole prior store burst landed in ddr[]); a per-op cap FPU_READ_MAX bounds the wait.
// Non-read ops (register-form, stores, control) apply immediately, exactly as before.
//
// Ops are queued (see ao486_fpu_op) and applied in retirement order. Earlier revisions
// de-duplicated by (opmodrm, lin) to absorb the RTL probe's held-high `fire`; sim_prims.sv
// now edge-detects `fire` and delivers each ESC op exactly once, so no de-duplication may
// happen here -- a tight loop whose body is one ESC instruction legitimately repeats it.
//
// Operand size (bytes) for a memory-READ op, so the snoop overlay covers exactly the read.
static int op_read_bytes(uint8_t op, uint8_t modrm) {
    if (modrm >= 0xC0) return 0;
    int reg = (modrm >> 3) & 7;
    switch (op) {
        case 0xD8: return 4;  case 0xDC: return 8;  case 0xDA: return 4;  case 0xDE: return 2;
        case 0xD9: return reg==0?4 : reg==4?28 : reg==5?2 : 0;   // FLD m32 / FLDENV m28 / FLDCW m2
        case 0xDD: return reg==0?8 : reg==4?108 : 0;             // FLD m64 / FRSTOR m108
        case 0xDB: return reg==0?4 : reg==5?10 : 0;              // FILD m32 / FLD m80
        case 0xDF: return reg==0?2 : reg==5?8 : 0;               // FILD m16 / FILD m64
        default:   return 0;                                    // stores / control: no read overlay
    }
}
static inline int op_reads_mem(uint8_t op, uint8_t modrm) { return op_read_bytes(op, modrm) > 0; }

// L2-invalidation QUEUE for co-sim FPU stores (the harness pulses one entry per iteration,
// after ddr_service). The co-sim writes its stores straight into ddr[], bypassing the CPU's
// L2, so every DDR word the store touched must be invalidated or the CPU keeps a stale copy
// that later lands back in ddr[].
//
// system.v wires .l2_inv_addr(l2_fpu_inv_addr[27:3]) => the granularity is ONE 8-byte word.
// A single start-address pulse is therefore wrong for any store that spans more than one
// word, and FSTP m80 (10 bytes) ALWAYS does. That lost the extended value's 2-byte exponent:
// a stored 1.06 reloaded as [42e7:87ae147ae147b000] = 9.8e223, so sprintf("%4.2f",1.06) in
// Draw_ConsoleBackground printed ~230 digits, overran its `ver[]` local, and smashed the
// `lines` argument -> wild memcpy src -> #PF. FSTENV(28)/FNSAVE(108)/misaligned m64 were
// silently truncated the same way.
enum { STOREQ = 32 };                       // > 108/8 + 1, so FNSAVE fits
static uint32_t g_storeq[STOREQ];
static int g_storeq_h = 0, g_storeq_t = 0;  // head=pop, tail=push
static int g_storeq_max = 0;                // depth watermark: if this climbs, the harness is
                                            // draining slower than the co-sim enqueues and an
                                            // invalidation is arriving after the CPU reads it.
static void store_inval_range(uint64_t phys, int nbytes) {
    for (uint64_t a = phys & ~7ull; a < phys + (uint64_t)nbytes; a += 8) {
        int nt = (g_storeq_t + 1) % STOREQ;
        if (nt == g_storeq_h) { fprintf(stderr, "[STOREQ] FULL -- dropped invalidation @%08llx\n",
                                        (unsigned long long)a); return; }
        g_storeq[g_storeq_t] = (uint32_t)a; g_storeq_t = nt;
    }
    int d = (g_storeq_t - g_storeq_h + STOREQ) % STOREQ;
    if (d > g_storeq_max) { g_storeq_max = d;
        if (d >= 4) fprintf(stderr, "[STOREQ] depth watermark %d\n", d); }
}
extern "C" int ao486_fpu_store_pending(unsigned int *phys) {
    if (g_storeq_h == g_storeq_t) return 0;
    *phys = g_storeq[g_storeq_h]; g_storeq_h = (g_storeq_h + 1) % STOREQ;
    return 1;
}

// Write `nbytes` from `src` into guest physical `phys` (bypassing the CPU L2) and queue an L2-line
// invalidation for every word touched, so the CPU's later loads refetch the new value from DDR.
// Used to clamp a runaway guest global (Quake's unclamped-timedemo host_frametime) at the co-sim
// seam, via the same coherency path the FPU stores use.
extern "C" int ao486_poke_guest(unsigned int phys, const void *src, int nbytes) {
    if (!ddr) return 0;
    if ((uint64_t)phys + (uint64_t)nbytes > DDR_BYTES) return 0;
    memcpy((uint8_t *)ddr + phys, src, nbytes);
    store_inval_range(phys, nbytes);
    return 1;
}

// ---- CPU-write snoop overlay (read-side coherency) ------------------------------
// A store from a just-retired prior instruction commits on the CPU's avalon write bus a
// few cycles BEFORE it drains through the write-through L2 into ddr[] (DDRAM_WE). The
// co-sim reads its operand straight from ddr[] the instant the ESC op retires, so it can
// miss that not-yet-drained store and read STALE bytes. We must NOT delay applying the op
// (Quake's FP loops are timing-sensitive to when co-sim results appear — deferring drops/
// reorders ops and wedges), and we must NOT poke ddr[] directly (that would corrupt CPU
// reads, which capture DDR data at issue-time). Instead a bound probe forwards every CPU
// write here at COMMIT time into a small time-stamped ring; when the co-sim reads an
// operand it OVERLAYS the ring entries that are newer than what has drained into ddr[]
// (the last SNOOP_WINDOW cycles) onto the operand bytes. This gives the co-sim the same
// value the CPU's own load path would see, at retire+1, with op timing unchanged.
static uint64_t g_now = 0;                        // advances once per ao486_fpu_process()
#define SNOOP_RING   256
// A committed CPU write can take longer than 8 cycles to drain through the write-through L2
// into ddr[] under DDR/fill contention (a write queued behind an 8-beat cache fill). If the
// FPU reads its operand after the write aged out of the overlay window but BEFORE it drained
// to ddr[], it reads STALE bytes. Widen the window well past the worst-case drain latency.
// Safe: the overlay applies newest-wins and the chronological ring holds writes in order, so
// a wider window never resurrects a value older than what ddr[] already holds — EXCEPT an FP
// store (which writes ddr[] directly, bypassing the snoop) could be undone by an older CPU
// snoop write still in a wider window; snoop_clear_range() below removes those, keeping it safe.
#define SNOOP_WINDOW 8                             // cycles a committed write may still be undrained (revert; fix disproven)
struct SnoopEnt { uint32_t phys; uint32_t data; uint8_t be; uint64_t t; };
static SnoopEnt g_snoop[SNOOP_RING]; static int g_snoop_head = 0;   // next slot (chronological ring)
extern "C" void ao486_snoop_write(int addr, int data, int be) {
    SnoopEnt &e = g_snoop[g_snoop_head];
    e.phys = (uint32_t)addr; e.data = (uint32_t)data; e.be = (uint8_t)(be & 0xf); e.t = g_now;
    g_snoop_head = (g_snoop_head + 1) & (SNOOP_RING - 1);
}
// Overlay recently-committed (not-yet-drained) CPU writes onto an operand buffer.
static void snoop_overlay(uint8_t *buf, uint64_t op_phys, int size) {
    uint64_t op_end = op_phys + (uint64_t)size;
    // iterate the ring oldest->newest so later writes win
    for (int k = 0; k < SNOOP_RING; k++) {
        const SnoopEnt &e = g_snoop[(g_snoop_head + k) & (SNOOP_RING - 1)];
        if (!e.be) continue;
        if (g_now - e.t > SNOOP_WINDOW) continue;                 // already drained into ddr[]
        for (int i = 0; i < 4; i++) if (e.be & (1 << i)) {
            uint64_t ba = (uint64_t)e.phys + i;
            if (ba >= op_phys && ba < op_end) buf[ba - op_phys] = (uint8_t)(e.data >> (i * 8));
        }
    }
}

// An FP store writes ddr[] directly (bypassing the snoop bus). Any OLDER CPU snoop write to
// the same bytes is now superseded by the FP store; clear it so the (widened) overlay can't
// re-apply a stale pre-FP-store value on top of the fresh ddr[] bytes.
static void snoop_clear_range(uint64_t phys, int size) {
    uint64_t end = phys + (uint64_t)size;
    for (int k = 0; k < SNOOP_RING; k++) {
        SnoopEnt &e = g_snoop[k];
        if (!e.be) continue;
        for (int i = 0; i < 4; i++) if (e.be & (1 << i)) {
            uint64_t ba = (uint64_t)e.phys + i;
            if (ba >= phys && ba < end) e.be &= (uint8_t)~(1 << i);
        }
    }
}

// Pending-op FIFO. sim_prims.sv's fpu_probe now calls this exactly ONCE per retired ESC op
// (rising edge of `fire`), so nothing here may de-duplicate: two consecutive iterations of a
// single-ESC-instruction loop are legitimately the same (op, modrm, lin) and must both be
// applied. The old value-based collapse swallowed them -- Q_atof's `fdiv st(1),st(0)` divide
// loop ran 2 of its 6 iterations, so "800.000000" parsed as 8000000.0, R_NewMap then asked
// Hunk_Alloc for r_cnumsurfs*64 = 512,000,000 bytes and Quake aborted on map load.
// The FIFO also covers several ESC ops retiring between two ao486_fpu_process() calls.
enum { OPQ = 64 };
static uint32_t g_opq_om[OPQ], g_opq_lin[OPQ];
static int g_opq_h = 0, g_opq_t = 0, g_opq_max = 0;

extern "C" void ao486_fpu_op(int op_modrm, int lin) {
    // Detect a double-signalled ESC op (same opcode+modrm AND same operand address back-to-back):
    // the RTL retire pulse firing twice would enqueue -> apply the op twice -> stack push/pop leak.
    if (fpu_dbg()) {
        static int p_om=-2, p_lin=-2; static uint64_t dupc=0, mem_dupc=0;
        uint8_t mrm = (uint8_t)((op_modrm>>8)&0xff);
        if (op_modrm==p_om && lin==p_lin) { dupc++;
            if (mrm < 0xC0) mem_dupc++;   // mem op with same operand addr = near-certain double-fire
            if ((dupc & (dupc-1))==0 || dupc<=8)
                fprintf(stderr,"[DUP] op=%04x lin=%08x back-to-back #%llu (mem_dup=%llu)\n",
                        (unsigned)op_modrm,(unsigned)lin,(unsigned long long)dupc,(unsigned long long)mem_dupc); }
        p_om=op_modrm; p_lin=lin;
    }
    int nt = (g_opq_t + 1) % OPQ;
    if (nt == g_opq_h) {   // must never happen: ops are drained every harness iteration
        fprintf(stderr, "[OPQ] FULL -- dropped ESC op %04x lin=%08x\n", op_modrm, (unsigned)lin);
        return;
    }
    g_opq_om[g_opq_t] = (uint32_t)op_modrm; g_opq_lin[g_opq_t] = (uint32_t)lin; g_opq_t = nt;
    int d = (g_opq_t - g_opq_h + OPQ) % OPQ;
    if (d > g_opq_max) { g_opq_max = d; if (d >= 8) fprintf(stderr, "[OPQ] depth %d\n", d); }
}

// ---- FPU op ring (co-sim wedge hunt) --------------------------------------------
// Record every applied ESC op so that when the CPU wild-jumps (crash) we can dump the
// recent FP history and link the corrupted memory operand to the op that produced it.
struct FpuEnt {
    uint64_t seq;          // g_fpu_ops sequence number
    uint64_t now;          // g_now (cycle-ish timestamp)
    uint8_t  op, modrm;
    uint32_t lin, phys;
    int      rb, mw;       // read bytes / mem_write bytes
    uint8_t  opbytes[16];  // operand as seen (post-overlay for reads / as written for stores)
    long double st0;       // ST(0) after the op
};
#define FRING 1024
static FpuEnt g_fring[FRING]; static int g_fring_head = 0;
extern "C" void ao486_fpu_dump_ring(int n) {
    if (n <= 0 || n > FRING) n = FRING;
    fprintf(stderr, "=== FPU op ring (last %d, oldest->newest) TOP=%d ===\n", n, TOP);
    for (int k = FRING - n; k < FRING; k++) {
        const FpuEnt &e = g_fring[(g_fring_head + k) & (FRING - 1)];
        if (!e.seq) continue;
        double d0 = (double)e.st0;
        fprintf(stderr, "  #%llu now=%llu op=%02x/%02x lin=%08x phys=%08x rb=%d mw=%d bytes=",
                (unsigned long long)e.seq, (unsigned long long)e.now, e.op, e.modrm,
                e.lin, e.phys, e.rb, e.mw);
        int nb = e.rb > e.mw ? e.rb : e.mw; if (nb > 16) nb = 16; if (nb == 0) nb = 4;
        for (int i = 0; i < nb; i++) fprintf(stderr, "%02x", e.opbytes[i]);
        fprintf(stderr, " st0=%.9g\n", d0);
    }
}

// Latest retired guest eip (set by sim_main's ao486_cpu_trace2). Kept as a hook for eip-gated
// FP probes; carries no functional role.
uint32_t g_trace_eip = 0;

// ---- "last 1.06 conversion" recorder -----------------------------------------------------
// Draw_ConsoleBackground does sprintf(ver,"%4.2f",1.06) with the double pushed as an immediate
// (push 0x3ff0f5c2 / push 0x8f5c28f6), and `ver`'s tail overlaps its own return address and the
// `lines` argument. A runaway conversion smashes both, so the next memcpy() reads a wild src
// -> #PF. The same conversion succeeds earlier in the run, so record EVERY cvt-of-1.06 into a
// rotating buffer and let sim_main dump the most recent (= the failing) one at the fault.
enum { CVT_MAX = 700 };
static char     g_cvt_line[CVT_MAX][168];
static int      g_cvt_n   = 0;   // ops buffered for the current conversion
static int      g_cvt_on  = 0;   // currently recording
static int      g_cvt_seq = 0;   // how many 1.06 conversions have started
static char     g_cvt_hdr[200];

extern "C" void x87_dump_last_cvt(void) {
    fprintf(stderr, "=== LAST cvt (conversion #%d), %d ops ===\n%s", g_cvt_seq, g_cvt_n, g_cvt_hdr);
    for (int i = 0; i < g_cvt_n; i++) fputs(g_cvt_line[i], stderr);
    fflush(stderr);
}

static void fpu_apply(uint8_t opcode, uint8_t modrm, uint32_t lin) {
    uint8_t *mem = nullptr;
    uint64_t phys = 0;
    if (modrm < 0xC0 && ddr) {
        phys = translate(lin, g_cr3, g_cr0pg);
        if (phys + 128 <= DDR_BYTES) mem = (uint8_t*)ddr + phys;
    }
    g_fpu_ops++;
    if (fpu_dbg() && (g_fpu_ops <= 5 || (g_fpu_ops % 20000) == 0))
        fprintf(stderr, "[FPUOP] total=%llu last op=%02x modrm=%02x oplin=%08x\n",
                (unsigned long long)g_fpu_ops, opcode, modrm, (unsigned)lin);
    // For a memory-READ op, hand x87_execute a copy of the operand with any recently-
    // committed (not-yet-drained) CPU stores overlaid, so the load is coherent. Store/
    // control ops keep writing through the real ddr[] pointer.
    int rb = mem ? op_read_bytes(opcode, modrm) : 0;
    uint8_t obuf[128];
    if (rb > 0 && rb <= (int)sizeof(obuf)) {
        memcpy(obuf, mem, rb);
        snoop_overlay(obuf, phys, rb);
        mem = obuf;
    }
    // CL_LerpPoint frac = (cl.time-mtime[1]) / (mtime[0]-mtime[1]); the FDIV is at eip 0x27c2,
    // dividend built 0x27b6(fld cl.time)-0x27bc(fsub mtime1). Log st0/st1 across the window so we
    // see whether the divisor (mtime[0]-mtime[1]) is tiny (-> frac~99 overshoot) or the FDIV misfires.
    if (fpu_dbg() && ((g_trace_eip >= 0x27b0u && g_trace_eip <= 0x27ccu) ||
                      (g_trace_eip >= 0x2a20u && g_trace_eip <= 0x2a8cu))) {   // CL_LerpPoint FDIV + entity origin/angle lerp
        static int fn = 0;
        if (fn++ < 160) fprintf(stderr, "[FRAC] eip=%05x op=%02x/%02x mem=%016llx st0=%.9Lg st1=%.9Lg\n",
                (unsigned)g_trace_eip, opcode, modrm,
                (unsigned long long)(mem ? *(const uint64_t*)mem : 0ull), st(0), st(1));
    }
    x87_result r = x87_execute(opcode, modrm, mem);
    if (r.mem_write > 0 && mem) {
        store_inval_range(phys, r.mem_write);   // every DDR word the store touched, not just the first
        // go32-corruption write-watch: report FPU-co-sim direct-ddr[] stores (these bypass
        // the DDRAM_WE path so the harness's ddr_service watch never sees them).
        ao486_watch_store((unsigned int)phys, ddr ? ddr[phys >> 3] : 0ull, 0ull, r.mem_write);
    }
    (void)snoop_clear_range;   // fix disproven; keep the helper defined but unused
    // [FPCTX] per-op context around the point (~#108) where the co-sim goes silent on a fresh
    // boot. If ES (bit7) sticks set under Quake's CW=0x037F (all masked), every later ESC op
    // would trap as an FP-error (INT 7) instead of reaching the co-sim -> the DPI stops firing.
    if (fpu_dbg() && g_fpu_ops <= 200) {
        uint16_t sw = status_word();
        int reg = (modrm >> 3) & 7, ismem = modrm < 0xC0;
        const char *nm = "";   // flag the state-affecting env ops (coordinator's FNSAVE/FRSTOR suspects)
        if (opcode==0xDD && ismem && reg==6) nm="<<FSAVE";
        else if (opcode==0xDD && ismem && reg==4) nm="<<FRSTOR";
        else if (opcode==0xD9 && ismem && reg==4) nm="<<FLDENV";
        else if (opcode==0xD9 && ismem && reg==6) nm="<<FNSTENV";
        else if (opcode==0xD9 && ismem && reg==5) nm="<<FLDCW";
        else if (opcode==0xD9 && ismem && reg==7) nm="<<FNSTCW";
        else if (opcode==0xDB && modrm==0xE3) nm="<<FNINIT";
        else if (opcode==0xDB && modrm==0xE2) nm="<<FNCLEX";
        else if (opcode==0xD9 && modrm>=0xF0 && modrm<=0xFF) nm="<<TRANSC/special";
        fprintf(stderr, "[FPCTX] #%llu op=%02x/%02x SW=%04x ES=%d exc=%02x(unmask=%02x) CW=%04x TOP=%d TW=%04x st0=%.6g st1=%.6g %s\n",
                (unsigned long long)g_fpu_ops, opcode, modrm, sw, (sw>>7)&1, SW&0x3f, (SW&0x3f)&~(CW&0x3f),
                CW, TOP, TW, (double)st(0), (double)st(1), nm);
    }
    // Record into the FPU op ring (post-execute: opbytes reflects the read operand /
    // the just-written store bytes; st0 is the resulting ST(0)).
    FpuEnt &fe = g_fring[g_fring_head];
    fe.seq = g_fpu_ops; fe.now = g_now; fe.op = opcode; fe.modrm = modrm;
    fe.lin = lin; fe.phys = (uint32_t)phys; fe.rb = rb; fe.mw = r.mem_write;
    memset(fe.opbytes, 0, sizeof(fe.opbytes));
    if (mem) { int nb = (rb > r.mem_write ? rb : r.mem_write); if (nb > 16) nb = 16;
               memcpy(fe.opbytes, mem, nb); }
    fe.st0 = st(0);
    g_fring_head = (g_fring_head + 1) & (FRING - 1);

    // R_NewMap's `r_cnumsurfs = (int)r_maxsurfs.value` (fld dword [0x603d8] .. fistp [esp]).
    // Quake aborts with Hunk_Alloc(r_cnumsurfs*64 = 512,000,000), i.e. r_cnumsurfs == 8,000,000
    // where the cvar default "0" should give 0. Print the operand bytes + ST(0) so we can tell a
    // corrupt float in memory from a broken FLD/FISTP round-trip.
    if (g_trace_eip >= 0x32270u && g_trace_eip <= 0x32298u) {
        static int n = 0;
        if (n++ < 24) {
            uint64_t mv = 0; if (mem) memcpy(&mv, mem, 8);
            fprintf(stderr, "[SURF] eip=%05x op=%02x/%02x m=%016llx st0=%.9Lg T=%d W=%04x CW=%04x SW=%04x\n",
                    g_trace_eip, opcode, modrm, (unsigned long long)mv, st(0), TOP, TW, CW, SW);
            fflush(stderr);
        }
    }
    // ---- rotating record of the current cvt-of-1.06 (see x87_dump_last_cvt) ----
    if (g_trace_eip == 0x5425eu) {
        g_cvt_seq++; g_cvt_on = 1; g_cvt_n = 0;
        snprintf(g_cvt_hdr, sizeof(g_cvt_hdr),
                 "  hdr: cyc=%llu TOP=%d TW=%04x SW=%04x CW=%04x st0=%.19Lg ovf=%llu\n",
                 (unsigned long long)g_now, TOP, TW, SW, CW, st(0),
                 (unsigned long long)g_push_ovf);
    }
    if (g_cvt_on) {
        if (g_cvt_n < CVT_MAX) {
            unsigned long long sig = 0; unsigned short ex = 0; ld_bits(st(0), &sig, &ex);
            uint64_t mv = 0; if (mem) memcpy(&mv, mem, 8);
            snprintf(g_cvt_line[g_cvt_n], sizeof(g_cvt_line[0]),
                     "  %03d e=%05x %02x/%02x m=%016llx st0=%.19Lg [%04x:%016llx] T=%d W=%04x S=%04x C=%04x\n",
                     g_cvt_n, g_trace_eip, opcode, modrm, (unsigned long long)mv,
                     st(0), ex, sig, TOP, TW, SW, CW);
            g_cvt_n++;
        } else g_cvt_on = 0;
    }

    // ---- minimal eip-gated dtoa probe (settling (a) upstream-value-corruption vs (b) FP-state) ----
    // Fires ONLY at the LATE (cyc>700M) Draw_ConsoleBackground "%4.2f" version sprintf, whose cvt/dtoa
    // FP code runs at guest eip 0x54250..0x548d0 (the sign test FLD is at 0x5425b, the digit loop at
    // 0x5484e). Logs the value ST(0) currently holds + the full x87 state, bounded to 64 lines. No env
    // var, no per-cycle counter (g_now is a plain uint64 threshold). Compare the FLD-of-the-version value
    // here vs the working banner: non-1.06 => upstream memory/DMA corruption (a); 1.06 but a later op
    // diverges => x87 stack/tag/sticky-exception state left by the renderer (b).
    // cvt/dtoa op-stream tracer. Window 1 = the first (working, banner) conversion of 1.06;
    // window 2 = the first conversion after cyc 700M, i.e. Draw_Init's runaway one. Both enter
    // with an identical x87 state, so diffing the two op streams isolates the first op whose
    // result differs -- that op's emulation is the bug.
}

// Apply every queued ESC op, in retirement order. Called once per harness iteration and also
// before a combinational FNSTSW read, so the status word never reflects a not-yet-applied op.
static void drain_pending() {
    while (g_opq_h != g_opq_t) {
        uint32_t om = g_opq_om[g_opq_h], l = g_opq_lin[g_opq_h];
        g_opq_h = (g_opq_h + 1) % OPQ;
        fpu_apply((uint8_t)(om & 0xff), (uint8_t)((om >> 8) & 0xff), l);
    }
}

// Harness driver: called once per main-loop iteration, AFTER ddr_service. Applies the
// pending ESC op(s) (original timing); operand reads are made coherent by the snoop overlay.
extern "C" void ao486_fpu_process() {
    g_now++;
    drain_pending();
}

// DPI function the RTL calls for FNSTSW AX / FSTSW AX to obtain the value to load into AX.
//
// READ-AFTER-WRITE HAZARD FIX (root cause of "Quake v-00.00" and the post-load #GP):
// printf's %f sign test is  `fcomp; fnstsw ax; and ah,0x45; jne <positive>`. The FCOMP
// posts its condition codes (C0/C2/C3) to the co-sim status word, but the co-sim applies
// each ESC op via the DEFERRED ao486_fpu_process() (end of the main-loop iteration / after
// x86_poll). FNSTSW AX, by contrast, is decoded to CMD_FNSTSW and reads the status word
// HERE, combinationally, the instant it retires. When the FCOMP fired the probe during an
// x86_poll sub-clock (so it is still pending when FNSTSW retires a cycle later), FNSTSW
// returned the PRE-compare codes: for a positive value (e.g. 1.06) C0 was still clear, the
// `jne` fell through, and the code negated it and printed a bogus "-00.00". The same stale
// status derails other FNSTSW-driven branches in dtoa/Host_Init, ultimately the #GP.
//
// Fix: flush any pending ESC op before reporting the status. Verilator only evaluates this
// DPI when exe_cmd==CMD_FNSTSW (the `?:` short-circuits), i.e. only while an FNSTSW occupies
// the execute stage — so the just-retired ESC op has left execute and CANNOT re-fire the
// probe here, and draining is idempotent within one eval (the FIFO empties, so repeated
// combinational calls no-op). Read coherency for a pending memory operand is still provided
// by the CPU-write snoop overlay inside fpu_apply().
extern "C" int ao486_fpu_status() {
    drain_pending();   // apply any pending (prev+current) ESC ops so the status is up to date
    return (int)status_word();
}

// Diagnostic: return a guest-code pointer for --dump-at disassembly of a stuck loop.
// Real mode -> use the cs<<4+eip linear directly; flat-protected (paging on) -> the eip
// is the linear (DJGPP flat, cs base 0) which we page-walk to physical.
extern "C" int  ao486_paging_on() { return g_cr0pg; }
extern "C" unsigned char* ao486_code_ptr(unsigned int lin_real, unsigned int eip) {
    if (!ddr) return nullptr;
    uint32_t lin = lin_real ? lin_real : eip;   // lin_real = true (segmented) linear
    uint64_t phys = translate(lin, g_cr3, g_cr0pg);
    if (phys + 256 > DDR_BYTES) return nullptr;
    return (unsigned char*)ddr + phys;
}

// Like ao486_code_ptr but with an EXPLICIT paging context. The wedge crash dump runs while
// the CPU is in DOS/DPMI real-mode (paging OFF), so translating a Quake flat linear needs
// Quake's own cr3 + paging-on, not the current (teardown) context.
extern "C" unsigned char* ao486_code_ptr_ctx(unsigned int lin, unsigned int cr3, int pg) {
    if (!ddr) return nullptr;
    uint64_t phys = translate(lin, cr3, pg ? 1 : 0);
    if (phys + 256 > DDR_BYTES) return nullptr;
    return (unsigned char*)ddr + phys;
}
extern "C" int ao486_cur_cr3() { return (int)g_cr3; }
extern "C" int ao486_cur_pg()  { return g_cr0pg; }

// Expose the linear->physical page walk to the harness (go32-corruption write-watch).
// Returns the physical byte address, or -1 if it would fall outside the DDR image.
extern "C" long long ao486_xlate(unsigned int lin, unsigned int cr3, int pg) {
    if (!ddr) return -1;
    uint64_t phys = translate((uint32_t)lin, (uint32_t)cr3, pg ? 1 : 0);
    if (phys + 8 > DDR_BYTES) return -1;
    return (long long)phys;
}

// Diagnostic: verbose page-walk of a linear addr, printing each stage + the bytes it
// lands on. Used to crack the wedge disassembly (the loop's true linear/physical).
extern "C" void ao486_walk_dbg(unsigned int lin) {
    const uint8_t *m = (const uint8_t*)ddr;
    fprintf(stderr, "[WALK] lin=%08x cr3=%08x pg=%d :", lin, g_cr3, g_cr0pg);
    if (!g_cr0pg) { fprintf(stderr, " (paging off) phys=%08x\n", lin); }
    else {
        uint32_t pde_a = (g_cr3 & 0xFFFFF000u) + ((lin >> 22) & 0x3FF) * 4u;
        uint32_t pde; memcpy(&pde, m + pde_a, 4);
        fprintf(stderr, " PDE@%08x=%08x", pde_a, pde);
        uint64_t phys;
        if (!(pde & 1)) { fprintf(stderr, " [PDE not present] -> identity\n"); phys = lin; }
        else if (pde & 0x80) { phys = (pde & 0xFFC00000u) | (lin & 0x003FFFFFu); fprintf(stderr, " [4MB] phys=%08llx\n", (unsigned long long)phys); }
        else {
            uint32_t pte_a = (pde & 0xFFFFF000u) + ((lin >> 12) & 0x3FF) * 4u;
            uint32_t pte; memcpy(&pte, m + pte_a, 4);
            fprintf(stderr, " PTE@%08x=%08x", pte_a, pte);
            if (!(pte & 1)) { fprintf(stderr, " [PTE not present] -> identity\n"); phys = lin; }
            else { phys = (pte & 0xFFFFF000u) | (lin & 0xFFFu); fprintf(stderr, " [4KB] phys=%08llx\n", (unsigned long long)phys); }
        }
        fprintf(stderr, "[WALK] bytes@phys:");
        for (int k = 0; k < 32 && phys + k < DDR_BYTES; k++) fprintf(stderr, " %02x", m[phys + k]);
        fprintf(stderr, "\n");
    }
}

// Raw CS descriptor cache snapshot (to verify the cs_base extraction).
static uint32_t g_cscache_lo = 0, g_cscache_hi = 0;
extern "C" void ao486_dbg_cscache(int lo, int hi) { g_cscache_lo = (uint32_t)lo; g_cscache_hi = (uint32_t)hi; }
extern "C" void ao486_dump_cscache() {
    uint32_t base = (g_cscache_hi & 0xFF000000u) | ((g_cscache_lo >> 16) & 0x0000FFFFu) | ((g_cscache_hi & 0xFFu) << 16);
    fprintf(stderr, "[CSC] cs_cache=%08x_%08x  base(extract)=%08x\n", g_cscache_hi, g_cscache_lo, base);
}

// Debug: called by a bound probe when a CMD_FNSTSW op retires — confirms DF-E0 decoded
// to the new command and shows the status word being handed to AX.
extern "C" void ao486_fnstsw_dbg() {
    if (g_fnstsw_dbg < 40) { fprintf(stderr, "[FNSTSW] retire, SW=0x%04x fpu_ops=%llu\n",
            status_word(), (unsigned long long)g_fpu_ops); g_fnstsw_dbg++; }
}
