// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// tools/p5xtrans/qref.c — the QEMU-MODE bit-exact reference for the Group-B x87
// transcendentals (#11). Companion to p5xtrans.c (the SILICON-mode oracle).
//
// The dual-mode RTL engine (docs/m11-transcendental-spec.md §3.4) ships SILICON
// behaviour but, by DEFAULT (+VEN_TRANSCENDENTAL without +VEN_TRSC_SILICON),
// reproduces QEMU 8.2's softfloat helper bit-for-bit so the existing `make verify`
// x87 path stays a real exact gate. This file is the executable definition of that
// QEMU-mode target: a faithful, line-by-line port of qemu-8.2.2
// target/i386/tcg/fpu_helper.c (helper_f2xm1) + the fpu/softfloat.c bits it uses.
//
//   * floatx80_mul / floatx80_add / floatx80_sub / floatx80_scalbn /
//     floatx80_to_int32 in the Horner loop  -> host `long double` (x86-64 long
//     double IS the 80-bit x87 format, computed in 80-bit x87 registers with the
//     default RNE / 64-bit precision-control, == softfloat floatx80_* precision_x).
//   * the 128/192-bit reconstruction (mul128By64To192 / add128 / sub128 /
//     shift128RightJamming / normalizeRoundAndPackFloatx80) -> `unsigned __int128`,
//     transcribed exactly from softfloat-macros.h / softfloat.c.
//
// Validated bit-for-bit against the pinned qemu-i386 (verif/.../qemu-i386) running
// the same f2xm1 — see tools/p5xtrans/qref_validate.sh. The RTL engine's QEMU mode
// is then graded bit-exact against THIS reference offline (fast, no core spin-up),
// before the in-core `make verify` x87 gate.
//
// Build: gcc -O2 -Wall -Wextra -std=c11 -o qref qref.c   (no libs; uses __int128)
// ----------------------------------------------------------------------------
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdbool.h>
#include <fenv.h>
#include <math.h>

// ---- floatx80 <-> host long double (x86-64 80-bit extended) -----------------
// long double is 16 bytes: [0:8)=frac (with explicit integer bit), [8:10)=sign|exp.
typedef union { long double ld; struct { uint64_t frac; uint16_t se; } __attribute__((packed)) p; } ldx_t;

static long double mk(uint16_t se, uint64_t frac) {
    ldx_t u; memset(&u, 0, sizeof u); u.p.frac = frac; u.p.se = se; return u.ld;
}
static uint64_t x80_frac(long double x){ ldx_t u; memset(&u,0,sizeof u); u.ld = x; return u.p.frac; }
static int32_t  x80_exp (long double x){ ldx_t u; memset(&u,0,sizeof u); u.ld = x; return u.p.se & 0x7fff; }
static int      x80_sign(long double x){ ldx_t u; memset(&u,0,sizeof u); u.ld = x; return u.p.se >> 15; }

// ---- softfloat wide-integer helpers (exact transcription) -------------------
static void add128(uint64_t a0,uint64_t a1,uint64_t b0,uint64_t b1,uint64_t*z0,uint64_t*z1){
    unsigned __int128 lo = (unsigned __int128)a1 + b1;
    uint64_t carry = (uint64_t)(lo >> 64);
    *z1 = (uint64_t)lo;
    *z0 = a0 + b0 + carry;
}
static void sub128(uint64_t a0,uint64_t a1,uint64_t b0,uint64_t b1,uint64_t*z0,uint64_t*z1){
    *z1 = a1 - b1;
    *z0 = a0 - b0 - (a1 < b1 ? 1u : 0u);
}
static void shift128RightJamming(uint64_t a0,uint64_t a1,int count,uint64_t*z0p,uint64_t*z1p){
    uint64_t z0,z1; int8_t negCount = (-count) & 63;
    if (count == 0){ z1=a1; z0=a0; }
    else if (count < 64){
        z1 = (a0<<negCount) | (a1>>count) | ((a1<<negCount)!=0);
        z0 = a0>>count;
    } else {
        if (count == 64)        z1 = a0 | (a1!=0);
        else if (count < 128)   z1 = (a0>>(count&63)) | (((a0<<negCount)|a1)!=0);
        else                    z1 = ((a0|a1)!=0);
        z0 = 0;
    }
    *z1p = z1; *z0p = z0;
}
static void mul128By64To192(uint64_t a0,uint64_t a1,uint64_t b,uint64_t*z0,uint64_t*z1,uint64_t*z2){
    unsigned __int128 p1 = (unsigned __int128)a1 * b;       // a1*b -> m1:z2
    uint64_t m1 = (uint64_t)(p1>>64); *z2 = (uint64_t)p1;
    unsigned __int128 p0 = (unsigned __int128)a0 * b;       // a0*b -> z0:z1
    uint64_t hz0 = (uint64_t)(p0>>64), hz1 = (uint64_t)p0;
    add128(hz0,hz1, 0,m1, z0,z1);
}

// ---- normalizeRoundAndPackFloatx80(precision_x) -----------------------------
// rc: x87 RC field (0 RNE, 1 down, 2 up, 3 truncate) == QEMU float_rounding_mode.
// Only the NORMAL (non-overflow / non-tiny) precision80 branch is reachable for
// f2xm1 results (|result| in [~2^-79, 1]); guarded with an assert for safety.
static long double norm_round_pack_x(int zSign, int32_t zExp, uint64_t zSig0, uint64_t zSig1, int rc){
    // normalizeRoundAndPackFloatx80
    if (zSig0 == 0){ zSig0 = zSig1; zSig1 = 0; zExp -= 64; }
    int sc = zSig0 ? __builtin_clzll(zSig0) : 64;
    if (sc){ zSig0 = (zSig0<<sc) | (zSig1>>(64-sc)); zSig1 <<= sc; }
    zExp -= sc;
    // roundAndPackFloatx80 (precision80, normal path)
    bool roundNearestEven = (rc==0);
    bool increment;
    switch (rc){
        case 0:  increment = ((int64_t)zSig1 < 0); break;     // nearest-even / ties-away
        case 1:  increment = zSign && zSig1;       break;     // toward -inf
        case 2:  increment = !zSign && zSig1;      break;     // toward +inf
        default: increment = 0;                    break;     // truncate
    }
    if (!(zExp > 0 && zExp < 0x7FFE)){
        fprintf(stderr, "qref: f2xm1 zExp=%d out of normal range (unexpected)\n", zExp);
        // fall through with best-effort pack
    }
    if (increment){
        zSig0++;
        if (zSig0 == 0){ zExp++; zSig0 = 0x8000000000000000ULL; }
        else if (!(zSig1<<1) && roundNearestEven) zSig0 &= ~1ULL;
    } else {
        if (zSig0 == 0) zExp = 0;
    }
    return mk((uint16_t)((zSign<<15) | (zExp & 0x7fff)), zSig0);
}

// ---- the QEMU f2xm1 table + coefficients (verbatim, qemu 8.2.2) -------------
#define f2c0     mk(0x3ffe, 0xb17217f7d1cf79acULL)
#define f2c0_low mk(0xbfbc, 0xd87edabf495b3762ULL)
#define f2c1     mk(0x3ffc, 0xf5fdeffc162c7543ULL)
#define f2c2     mk(0x3ffa, 0xe35846b82505fcc7ULL)
#define f2c3     mk(0x3ff8, 0x9d955b7dd273b899ULL)
#define f2c4     mk(0x3ff5, 0xaec3ff3c4ef4ac0cULL)
#define f2c5     mk(0x3ff2, 0xa184897c3a7f0de9ULL)
#define f2c6     mk(0x3fee, 0xffe634d0ec30d504ULL)
#define f2c7     mk(0x3feb, 0xb160111d2db515e4ULL)
#define ln2_sig_high 0xb17217f7d1cf79abULL
#define ln2_sig_low  0xc9e3b39803f2f6afULL

typedef struct { uint16_t t_se; uint64_t t_f; uint16_t e2_se; uint64_t e2_f; uint16_t em_se; uint64_t em_f; } f2row;
// {t, exp2, exp2m1} as raw floatx80 {se,frac}. Generated from qemu's f2xm1_table[65].
static const f2row TBL[65] = {
#include "qref_f2xm1_table.inc"
};

// ---- helper_f2xm1 (qemu 8.2.2 target/i386/tcg/fpu_helper.c), rc-parameterized.
// Returns the floatx80 result of f2xm1(x). NaN / out-of-range corners return a
// QEMU default-NaN sentinel (0xffffc000000000000000) — not exercised by the gate.
static long double qf2xm1(long double x, int rc){
    uint64_t sig = x80_frac(x);
    int32_t  exp = x80_exp(x);
    int      sign = x80_sign(x);

    if (exp > 0x3fff || (exp == 0x3fff && sig != 0x8000000000000000ULL)){
        return mk(0xffff, 0xc000000000000000ULL);        // out of range -> default NaN
    } else if (exp == 0x3fff){
        if (sign) return mk(0xbffe, 0x8000000000000000ULL);  // f2xm1(-1) = -0.5
        return x;                                            // f2xm1(+1) = +1.0
    } else if (exp < 0x3fb0){
        if (x == 0.0L) return x;                          // +-0 unchanged
        uint64_t sig0,sig1,sig2;
        mul128By64To192(ln2_sig_high, ln2_sig_low, sig, &sig0,&sig1,&sig2);
        sig1 |= 1;                                        // inexact
        return norm_round_pack_x(sign, exp, sig0, sig1, rc);
    } else {
        // Find the nearest multiple of 1/32 (RNE), table-indexed by n=32+round(x*32).
        long double tmp = x * 32.0L;                      // floatx80_scalbn(x,5): exact
        long n = 32 + (long)llrintl(tmp);                 // floatx80_to_int32, RNE
        long double tval = mk(TBL[n].t_se, TBL[n].t_f);
        long double y = x - tval;                         // floatx80_sub (RNE, prec_x)
        if (y == 0.0L){
            return tval;                                  // qemu: ST0 = table[n].t
        }
        // Horner for (2^y-1)/y lower parts, RNE precision_x (host long double).
        long double accum;
        accum = f2c7 * y;
        accum = f2c6 + accum;
        accum = accum * y;
        accum = f2c5 + accum;
        accum = accum * y;
        accum = f2c4 + accum;
        accum = accum * y;
        accum = f2c3 + accum;
        accum = accum * y;
        accum = f2c2 + accum;
        accum = accum * y;
        accum = f2c1 + accum;
        accum = accum * y;
        accum = f2c0_low + accum;
        // full poly = f2c0 + accum (accum much smaller), in 128-bit.
        int32_t aexp = x80_exp(f2c0);
        int     asign = x80_sign(f2c0);
        uint64_t asig0, asig1, asig2, bsig0, bsig1;
        shift128RightJamming(x80_frac(accum), 0, aexp - x80_exp(accum), &asig0,&asig1);
        bsig0 = x80_frac(f2c0); bsig1 = 0;
        if (asign == x80_sign(accum)) add128(bsig0,bsig1,asig0,asig1,&asig0,&asig1);
        else                          sub128(bsig0,bsig1,asig0,asig1,&asig0,&asig1);
        // approx 2^y - 1 = poly * y
        mul128By64To192(asig0,asig1, x80_frac(y), &asig0,&asig1,&asig2);
        aexp += x80_exp(y) - 0x3ffe;
        asign ^= x80_sign(y);
        if (n != 32){
            mul128By64To192(asig0,asig1, x80_frac(mk(TBL[n].e2_se,TBL[n].e2_f)), &asig0,&asig1,&asig2);
            aexp += x80_exp(mk(TBL[n].e2_se,TBL[n].e2_f)) - 0x3ffe;
            int32_t bexp = x80_exp(mk(TBL[n].em_se,TBL[n].em_f));
            bsig0 = x80_frac(mk(TBL[n].em_se,TBL[n].em_f)); bsig1 = 0;
            if (bexp < aexp)      shift128RightJamming(bsig0,bsig1, aexp-bexp, &bsig0,&bsig1);
            else if (aexp < bexp){ shift128RightJamming(asig0,asig1, bexp-aexp, &asig0,&asig1); aexp = bexp; }
            int bsign = x80_sign(mk(TBL[n].em_se,TBL[n].em_f));
            if (asign == bsign){
                shift128RightJamming(asig0,asig1, 1, &asig0,&asig1);
                shift128RightJamming(bsig0,bsig1, 1, &bsig0,&bsig1);
                ++aexp;
                add128(asig0,asig1,bsig0,bsig1,&asig0,&asig1);
            } else {
                sub128(bsig0,bsig1,asig0,asig1,&asig0,&asig1);
                asign = bsign;
            }
        }
        asig1 |= 1;                                       // inexact
        return norm_round_pack_x(asign, aexp, asig0, asig1, rc);
    }
}

// ============================================================================
// FPATAN — atan2(ST1, ST0). A verbatim port of qemu-8.2.2 helper_fpatan +
// the softfloat.c routines it calls. Quake's ONLY transcendental.
// ============================================================================
static void mul64To128(uint64_t a, uint64_t b, uint64_t*z0, uint64_t*z1){
    unsigned __int128 p = (unsigned __int128)a * b; *z0 = (uint64_t)(p>>64); *z1 = (uint64_t)p;
}
static void add192(uint64_t a0,uint64_t a1,uint64_t a2,uint64_t b0,uint64_t b1,uint64_t b2,
                   uint64_t*z0,uint64_t*z1,uint64_t*z2){
    unsigned __int128 t = (unsigned __int128)a2 + b2; uint64_t c = (uint64_t)(t>>64); *z2=(uint64_t)t;
    t = (unsigned __int128)a1 + b1 + c; c = (uint64_t)(t>>64); *z1=(uint64_t)t;
    *z0 = a0 + b0 + c;
}
static void sub192(uint64_t a0,uint64_t a1,uint64_t a2,uint64_t b0,uint64_t b1,uint64_t b2,
                   uint64_t*z0,uint64_t*z1,uint64_t*z2){
    uint64_t bo0,bo1;
    *z2 = a2 - b2; bo1 = (a2 < b2);
    *z1 = a1 - b1 - bo1; bo0 = (a1 < b1) || (a1==b1 && bo1);
    *z0 = a0 - b0 - bo0;
}
static void shift128Right(uint64_t a0,uint64_t a1,int count,uint64_t*z0,uint64_t*z1){
    uint64_t zz0,zz1; int8_t negc = (-count)&63;
    if (count==0){ zz1=a1; zz0=a0; }
    else if (count<64){ zz1=(a0<<negc)|(a1>>count); zz0=a0>>count; }
    else { zz1=(count<128)?(a0>>(count&63)):0; zz0=0; }
    *z1=zz1; *z0=zz0;
}
static void shift128Left(uint64_t a0,uint64_t a1,int count,uint64_t*z0,uint64_t*z1){
    if (count<64){ *z1=a1<<count; *z0=(count==0)?a0:((a0<<count)|(a1>>((-count)&63))); }
    else { *z1=0; *z0=a1<<(count-64); }
}
static void mul128To256(uint64_t a0,uint64_t a1,uint64_t b0,uint64_t b1,
                        uint64_t*z0,uint64_t*z1,uint64_t*z2,uint64_t*z3){
    uint64_t zz0,zz1,zz2,m0,m1,m2,n1,n2;
    mul64To128(a1,b0,&m1,&m2);
    mul64To128(a0,b1,&n1,&n2);
    mul64To128(a1,b1,&zz2,z3);
    mul64To128(a0,b0,&zz0,&zz1);
    add192(0,m1,m2, 0,n1,n2, &m0,&m1,&m2);
    add192(m0,m1,m2, zz0,zz1,zz2, z0,z1,z2);
}
static uint64_t estimateDiv128To64(uint64_t a0,uint64_t a1,uint64_t b){
    uint64_t b0,b1,rem0,rem1,term0,term1,z;
    if (b<=a0) return 0xFFFFFFFFFFFFFFFFULL;
    b0=b>>32;
    z=(b0<<32 <= a0) ? 0xFFFFFFFF00000000ULL : (a0/b0)<<32;
    mul64To128(b,z,&term0,&term1);
    sub128(a0,a1,term0,term1,&rem0,&rem1);
    while (((int64_t)rem0)<0){ z-=0x100000000ULL; b1=b<<32; add128(rem0,rem1,b0,b1,&rem0,&rem1); }
    rem0=(rem0<<32)|(rem1>>32);
    z |= (b0<<32 <= rem0) ? 0xFFFFFFFFULL : rem0/b0;
    return z;
}
static void normalizeFloatx80Subnormal(uint64_t aSig,int32_t*zExp,uint64_t*zSig){
    int sc = __builtin_clzll(aSig);
    *zSig = aSig<<sc; *zExp = 1 - sc;
}
static int x80_is_zero(long double v){ return (x80_exp(v)==0) && (x80_frac(v)==0); }

// pi / pi2 / pi4 / 3pi4 (128-bit), and the fpatan coeffs + 9-entry atan c-table.
#define PI_EXP   0x4000
#define PI_H     0xc90fdaa22168c234ULL
#define PI_L     0xc4c6628b80dc1cd1ULL
#define PI2_EXP  0x3fff
#define PI4_EXP  0x3ffe
#define PI34_EXP 0x4000
#define PI34_H   0x96cbe3f9990e91a7ULL
#define PI34_L   0x9394c9e8a0a5159dULL
#define fac0 mk(0x3fff,0x8000000000000000ULL)
#define fac1 mk(0xbffd,0xaaaaaaaaaaaaaa43ULL)
#define fac2 mk(0x3ffc,0xccccccccccbfe4f8ULL)
#define fac3 mk(0xbffc,0x92492491fbab2e66ULL)
#define fac4 mk(0x3ffb,0xe38e372881ea1e0bULL)
#define fac5 mk(0xbffb,0xba2c0104bbdd0615ULL)
#define fac6 mk(0x3ffb,0x9baf7ebf898b42efULL)
static const struct { uint16_t hi_se; uint64_t hi_f; uint16_t lo_se; uint64_t lo_f; } FATBL[9] = {
    {0x0000,0x0000000000000000ULL, 0x0000,0x0000000000000000ULL},
    {0x3ffb,0xfeadd4d5617b6e33ULL, 0xbfb9,0xdda19d8305ddc420ULL},
    {0x3ffc,0xfadbafc96406eb15ULL, 0x3fbb,0xdb8f3debef442fccULL},
    {0x3ffd,0xb7b0ca0f26f78474ULL, 0xbfbc,0xeab9bdba460376faULL},
    {0x3ffd,0xed63382b0dda7b45ULL, 0x3fbc,0xdfc88bd978751a06ULL},
    {0x3ffe,0x8f005d5ef7f59f9bULL, 0x3fbd,0xb906bc2ccb886e90ULL},
    {0x3ffe,0xa4bc7d1934f70924ULL, 0x3fbb,0xcd43f9522bed64f8ULL},
    {0x3ffe,0xb8053e2bc2319e74ULL, 0xbfbc,0xd3496ab7bd6eef0cULL},
    {0x3ffe,0xc90fdaa22168c235ULL, 0xbfbc,0xece675d1fc8f8cbcULL},
};

static long double qfpatan(long double st1_y, long double st0_x, int rc){
    uint64_t arg0_sig = x80_frac(st0_x); int32_t arg0_exp = x80_exp(st0_x); int arg0_sign = x80_sign(st0_x);
    uint64_t arg1_sig = x80_frac(st1_y); int32_t arg1_exp = x80_exp(st1_y); int arg1_sign = x80_sign(st1_y);
    int rsign; int32_t rexp; uint64_t rsig0, rsig1;

    if (x80_is_zero(st1_y) && !arg0_sign){
        return st1_y;                              // pass zero through
    } else if (arg0_exp - arg1_exp >= 80 && !arg0_sign){
        // ST1/ST0 (avoid spurious underflow); exact result -> adjust for inexact.
        // qemu uses the USER rounding mode for this divide (it is OUTSIDE the
        // force-RNE block), so honor rc on the host division.
        int fe = (rc==1)?FE_DOWNWARD : (rc==2)?FE_UPWARD : (rc==3)?FE_TOWARDZERO : FE_TONEAREST;
        fesetround(fe);
        long double q = st1_y / st0_x;             // floatx80_div, precision_x, user rc
        fesetround(FE_TONEAREST);
        // (the exact-result adjust at qemu 1337-1356 nudges the significand; for the
        //  finite comparable-exponent sweep this branch is exercised only by the
        //  explicit far-apart cases — emulate the adjust faithfully.)
        if (!x80_is_zero(q)){
            uint64_t sig=x80_frac(q); int32_t e=x80_exp(q); int s=x80_sign(q);
            if (e==0) normalizeFloatx80Subnormal(sig,&e,&sig);
            // only when the division was exact (no inexact). We can't read softfloat
            // flags here; recompute exactly: y == q*x ? If exact, apply the nudge.
            long double back = q * st0_x;
            if (back == st1_y)
                return norm_round_pack_x(s, e, sig-1, (uint64_t)-1, rc);
        }
        return q;
    }

    // result is inexact
    rsign = arg1_sign;
    if (x80_is_zero(st1_y)){                        // ST0<0 -> +-pi
        rexp=PI_EXP; rsig0=PI_H; rsig1=PI_L;
    } else if (x80_is_zero(st0_x) || arg1_exp - arg0_exp >= 80){
        rexp=PI2_EXP; rsig0=PI_H; rsig1=PI_L;      // pi/2
    } else if (arg0_exp - arg1_exp >= 80){
        rexp=PI_EXP; rsig0=PI_H; rsig1=PI_L;       // ST0<0 -> pi
    } else {
        int32_t adj_exp,num_exp,den_exp,xexp,yexp,n,texp,zexp,aexp,azexp,axexp;
        int adj_sub,ysign,zsign;
        uint64_t adj_sig0,adj_sig1,num_sig,den_sig,xsig0,xsig1;
        uint64_t msig0,msig1,msig2,remsig0,remsig1,remsig2;
        uint64_t ysig0,ysig1,tsig,zsig0,zsig1,asig0,asig1;
        uint64_t azsig0,azsig1,azsig2,azsig3,axsig0,axsig1;
        if (arg0_exp==0) normalizeFloatx80Subnormal(arg0_sig,&arg0_exp,&arg0_sig);
        if (arg1_exp==0) normalizeFloatx80Subnormal(arg1_sig,&arg1_exp,&arg1_sig);
        if (arg0_exp>arg1_exp || (arg0_exp==arg1_exp && arg0_sig>=arg1_sig)){
            num_exp=arg1_exp; num_sig=arg1_sig; den_exp=arg0_exp; den_sig=arg0_sig;
            if (arg0_sign){ adj_exp=PI_EXP; adj_sig0=PI_H; adj_sig1=PI_L; adj_sub=1; }
            else          { adj_exp=0; adj_sig0=0; adj_sig1=0; adj_sub=0; }
        } else {
            num_exp=arg0_exp; num_sig=arg0_sig; den_exp=arg1_exp; den_sig=arg1_sig;
            adj_exp=PI2_EXP; adj_sig0=PI_H; adj_sig1=PI_L; adj_sub=!arg0_sign;
        }
        // x = num/den in (0,1]
        xexp = num_exp - den_exp + 0x3ffe;
        remsig0=num_sig; remsig1=0;
        if (den_sig<=remsig0){ shift128Right(remsig0,remsig1,1,&remsig0,&remsig1); ++xexp; }
        xsig0 = estimateDiv128To64(remsig0,remsig1,den_sig);
        mul64To128(den_sig,xsig0,&msig0,&msig1);
        sub128(remsig0,remsig1,msig0,msig1,&remsig0,&remsig1);
        while (((int64_t)remsig0)<0){ --xsig0; add128(remsig0,remsig1,0,den_sig,&remsig0,&remsig1); }
        xsig1 = estimateDiv128To64(remsig1,0,den_sig);
        // x = t + y, t = n/8 nearest
        long double x8v = norm_round_pack_x(0, xexp+3, xsig0, xsig1, 0);
        n = (int32_t)llrintl(x8v);
        if (n==0){ ysign=0; yexp=xexp; ysig0=xsig0; ysig1=xsig1; texp=0; tsig=0; }
        else {
            int shift = __builtin_clz((unsigned)n) + 32;
            texp = 0x403b - shift; tsig=(uint64_t)n; tsig<<=shift;
            if (texp==xexp){
                sub128(xsig0,xsig1,tsig,0,&ysig0,&ysig1);
                if (((int64_t)ysig0)>=0){
                    ysign=0;
                    if (ysig0==0){
                        if (ysig1==0) yexp=0;
                        else { shift=__builtin_clzll(ysig1)+64; yexp=xexp-shift; shift128Left(ysig0,ysig1,shift,&ysig0,&ysig1); }
                    } else { shift=__builtin_clzll(ysig0); yexp=xexp-shift; shift128Left(ysig0,ysig1,shift,&ysig0,&ysig1); }
                } else {
                    ysign=1; sub128(0,0,ysig0,ysig1,&ysig0,&ysig1);
                    shift = (ysig0==0)?(__builtin_clzll(ysig1)+64):__builtin_clzll(ysig0);
                    yexp=xexp-shift; shift128Left(ysig0,ysig1,shift,&ysig0,&ysig1);
                }
            } else {
                uint64_t usig0,usig1;
                shift128RightJamming(xsig0,xsig1,texp-xexp,&usig0,&usig1);
                ysign=1; sub128(tsig,0,usig0,usig1,&ysig0,&ysig1);
                shift = (ysig0==0)?(__builtin_clzll(ysig1)+64):__builtin_clzll(ysig0);
                yexp=texp-shift; shift128Left(ysig0,ysig1,shift,&ysig0,&ysig1);
            }
        }
        // z = y/(1+tx)
        zsign=ysign;
        if (texp==0 || yexp==0){ zexp=yexp; zsig0=ysig0; zsig1=ysig1; }
        else {
            int32_t dexp = texp+xexp-0x3ffe; uint64_t dsig0,dsig1,dsig2;
            mul128By64To192(xsig0,xsig1,tsig,&dsig0,&dsig1,&dsig2);
            shift128RightJamming(dsig0,dsig1,0x3fff-dexp,&dsig0,&dsig1);
            dsig0 |= 0x8000000000000000ULL;
            zexp=yexp-1; remsig0=ysig0; remsig1=ysig1; remsig2=0;
            if (dsig0<=remsig0){ shift128Right(remsig0,remsig1,1,&remsig0,&remsig1); ++zexp; }
            zsig0 = estimateDiv128To64(remsig0,remsig1,dsig0);
            mul128By64To192(dsig0,dsig1,zsig0,&msig0,&msig1,&msig2);
            sub192(remsig0,remsig1,remsig2,msig0,msig1,msig2,&remsig0,&remsig1,&remsig2);
            while (((int64_t)remsig0)<0){ --zsig0; add192(remsig0,remsig1,remsig2,0,dsig0,dsig1,&remsig0,&remsig1,&remsig2); }
            zsig1 = estimateDiv128To64(remsig1,remsig2,dsig0);
        }
        if (zexp==0){ azexp=0; azsig0=0; azsig1=0; }
        else {
            uint64_t z2s0,z2s1,z2s2,z2s3;
            mul128To256(zsig0,zsig1,zsig0,zsig1,&z2s0,&z2s1,&z2s2,&z2s3);
            long double z2 = norm_round_pack_x(0, zexp+zexp-0x3ffe, z2s0, z2s1, 0);
            long double accum;
            accum = fac6 * z2; accum = fac5 + accum;
            accum = accum * z2; accum = fac4 + accum;
            accum = accum * z2; accum = fac3 + accum;
            accum = accum * z2; accum = fac2 + accum;
            accum = accum * z2; accum = fac1 + accum;
            accum = accum * z2;
            aexp = x80_exp(fac0);
            shift128RightJamming(x80_frac(accum),0, aexp - x80_exp(accum), &asig0,&asig1);
            sub128(x80_frac(fac0),0, asig0,asig1, &asig0,&asig1);
            azexp = aexp + zexp - 0x3ffe;
            mul128To256(asig0,asig1, zsig0,zsig1, &azsig0,&azsig1,&azsig2,&azsig3);
        }
        // atan(x) = atan(t) + atan(z)
        if (texp==0){ axexp=azexp; axsig0=azsig0; axsig1=azsig1; }
        else {
            int low_sign = (FATBL[n].lo_se>>15); int32_t low_exp = FATBL[n].lo_se & 0x7fff;
            uint64_t low_sig0 = FATBL[n].lo_f, low_sig1 = 0;
            axexp = FATBL[n].hi_se & 0x7fff; axsig0 = FATBL[n].hi_f; axsig1 = 0;
            shift128RightJamming(low_sig0,low_sig1, axexp-low_exp, &low_sig0,&low_sig1);
            if (low_sign) sub128(axsig0,axsig1,low_sig0,low_sig1,&axsig0,&axsig1);
            else          add128(axsig0,axsig1,low_sig0,low_sig1,&axsig0,&axsig1);
            if (azexp>=axexp){
                shift128RightJamming(axsig0,axsig1, azexp-axexp+1, &axsig0,&axsig1);
                axexp=azexp+1; shift128RightJamming(azsig0,azsig1,1,&azsig0,&azsig1);
            } else {
                shift128RightJamming(axsig0,axsig1,1,&axsig0,&axsig1);
                shift128RightJamming(azsig0,azsig1, axexp-azexp+1, &azsig0,&azsig1);
                ++axexp;
            }
            if (zsign) sub128(axsig0,axsig1,azsig0,azsig1,&axsig0,&axsig1);
            else       add128(axsig0,axsig1,azsig0,azsig1,&axsig0,&axsig1);
        }
        if (adj_exp==0){ rexp=axexp; rsig0=axsig0; rsig1=axsig1; }
        else {
            if (adj_exp>=axexp){
                shift128RightJamming(axsig0,axsig1, adj_exp-axexp+1, &axsig0,&axsig1);
                rexp=adj_exp+1; shift128RightJamming(adj_sig0,adj_sig1,1,&adj_sig0,&adj_sig1);
            } else {
                shift128RightJamming(axsig0,axsig1,1,&axsig0,&axsig1);
                shift128RightJamming(adj_sig0,adj_sig1, axexp-adj_exp+1, &adj_sig0,&adj_sig1);
                rexp=axexp+1;
            }
            if (adj_sub) sub128(adj_sig0,adj_sig1,axsig0,axsig1,&rsig0,&rsig1);
            else         add128(adj_sig0,adj_sig1,axsig0,axsig1,&rsig0,&rsig1);
        }
    }
    rsig1 |= 1;                                    // inexact
    return norm_round_pack_x(rsign, rexp, rsig0, rsig1, rc);
}

// ============================================================================
// FYL2X / FYL2XP1 — y*log2(x), y*log2(x+1). Verbatim port of qemu-8.2.2
// helper_fyl2x / helper_fyl2xp1 + the shared helper_fyl2x_common.
// ============================================================================
#define log2e_hi 0xb8aa3b295c17f0bbULL
#define log2e_lo 0xbe87fed0691d3e89ULL
#define fyc0     mk(0x4000,0xb8aa3b295c17f0bcULL)
#define fyc0_low mk(0xbfbf,0x834972fe2d7bab1bULL)
#define fyc1     mk(0x3ffe,0xf6384ee1d01febb8ULL)
#define fyc2     mk(0x3ffe,0x93bb62877cdfa2e3ULL)
#define fyc3     mk(0x3ffd,0xd30bb153d808f269ULL)
#define fyc4     mk(0x3ffd,0xa42589eaf451499eULL)
#define fyc5     mk(0x3ffd,0x864d42c0f8f17517ULL)
#define fyc6     mk(0x3ffc,0xe3476578adf26272ULL)
#define fyc7     mk(0x3ffc,0xc506c5f874e6d80fULL)
#define fyc8     mk(0x3ffc,0xac5cf50cc57d6372ULL)
#define fyc9     mk(0x3ffc,0xb1ed0066d971a103ULL)

// log2(1+arg), arg in [sqrt2/2-1, sqrt2-1]. Returns (exp, sig0, sig1) MAGNITUDE;
// caller applies the sign. Runs in forced-RNE (host default).
static void qfyl2x_common(long double arg, int32_t*rexp, uint64_t*rsig0o, uint64_t*rsig1o){
    uint64_t a0sig=x80_frac(arg); int32_t a0exp=x80_exp(arg); int a0sign=x80_sign(arg);
    int asign; int32_t dexp,texp,aexp;
    uint64_t dsig0,dsig1,tsig0,tsig1,rsig0,rsig1,rsig2,msig0,msig1,msig2;
    uint64_t t2s0,t2s1,t2s2,t2s3,as0,as1,as2,as3,bsig0,bsig1;
    long double t2, accum;
    if (a0sign){ dexp=0x3fff; shift128RightJamming(a0sig,0,dexp-a0exp,&dsig0,&dsig1); sub128(0,0,dsig0,dsig1,&dsig0,&dsig1); }
    else       { dexp=0x4000; shift128RightJamming(a0sig,0,dexp-a0exp,&dsig0,&dsig1); dsig0|=0x8000000000000000ULL; }
    texp=a0exp-dexp+0x3ffe; rsig0=a0sig; rsig1=0; rsig2=0;
    if (dsig0<=rsig0){ shift128Right(rsig0,rsig1,1,&rsig0,&rsig1); ++texp; }
    tsig0=estimateDiv128To64(rsig0,rsig1,dsig0);
    mul128By64To192(dsig0,dsig1,tsig0,&msig0,&msig1,&msig2);
    sub192(rsig0,rsig1,rsig2,msig0,msig1,msig2,&rsig0,&rsig1,&rsig2);
    while(((int64_t)rsig0)<0){ --tsig0; add192(rsig0,rsig1,rsig2,0,dsig0,dsig1,&rsig0,&rsig1,&rsig2); }
    tsig1=estimateDiv128To64(rsig1,rsig2,dsig0);
    mul128To256(tsig0,tsig1,tsig0,tsig1,&t2s0,&t2s1,&t2s2,&t2s3);
    t2=norm_round_pack_x(0, texp+texp-0x3ffe, t2s0, t2s1, 0);
    accum=fyc9*t2; accum=fyc8+accum; accum=accum*t2; accum=fyc7+accum;
    accum=accum*t2; accum=fyc6+accum; accum=accum*t2; accum=fyc5+accum;
    accum=accum*t2; accum=fyc4+accum; accum=accum*t2; accum=fyc3+accum;
    accum=accum*t2; accum=fyc2+accum; accum=accum*t2; accum=fyc1+accum;
    accum=accum*t2; accum=fyc0_low+accum;
    aexp=x80_exp(fyc0); asign=x80_sign(fyc0);
    shift128RightJamming(x80_frac(accum),0, aexp-x80_exp(accum), &as0,&as1);
    bsig0=x80_frac(fyc0); bsig1=0;
    if (asign==x80_sign(accum)) add128(bsig0,bsig1,as0,as1,&as0,&as1);
    else                        sub128(bsig0,bsig1,as0,as1,&as0,&as1);
    mul128To256(as0,as1, tsig0,tsig1, &as0,&as1,&as2,&as3);
    aexp += texp - 0x3ffe;
    *rexp=aexp; *rsig0o=as0; *rsig1o=as1;
    (void)a0sign;
}

static void set_round(int rc){
    fesetround((rc==1)?FE_DOWNWARD : (rc==2)?FE_UPWARD : (rc==3)?FE_TOWARDZERO : FE_TONEAREST);
}

static long double qfyl2x(long double st1_y, long double st0_x, int rc){
    uint64_t a0sig=x80_frac(st0_x); int32_t a0exp=x80_exp(st0_x); int a0sign=x80_sign(st0_x);
    uint64_t a1sig=x80_frac(st1_y); int32_t a1exp=x80_exp(st1_y); int a1sign=x80_sign(st1_y);
    if (a0exp==0) normalizeFloatx80Subnormal(a0sig,&a0exp,&a0sig);
    if (a1exp==0) normalizeFloatx80Subnormal(a1sig,&a1exp,&a1sig);
    int32_t int_exp = a0exp - 0x3fff;
    if (a0sig > 0xb504f333f9de6484ULL) ++int_exp;
    long double scaled = ldexpl(st0_x, -int_exp);   // floatx80_scalbn(ST0,-int_exp), exact
    long double arg0_m1 = scaled - 1.0L;             // RNE
    if (arg0_m1 == 0.0L){
        long double r; set_round(rc); r = (long double)int_exp * st1_y; set_round(0); return r;
    }
    int asign = x80_sign(arg0_m1); int32_t aexp; uint64_t asig0,asig1,asig2;
    qfyl2x_common(arg0_m1, &aexp, &asig0, &asig1);
    if (int_exp != 0){
        int isign = (int_exp<0); int32_t iexp; uint64_t isig; int shift;
        int ie = isign ? -int_exp : int_exp;
        shift = __builtin_clz((unsigned)ie) + 32; isig=(uint64_t)ie<<shift; iexp=0x403e - shift;
        shift128RightJamming(asig0,asig1, iexp-aexp, &asig0,&asig1);
        if (asign==isign) add128(isig,0,asig0,asig1,&asig0,&asig1);
        else              sub128(isig,0,asig0,asig1,&asig0,&asig1);
        aexp=iexp; asign=isign;
    }
    mul128By64To192(asig0,asig1, a1sig, &asig0,&asig1,&asig2);
    aexp += a1exp - 0x3ffe;
    asig1 |= 1;
    return norm_round_pack_x(asign ^ a1sign, aexp, asig0, asig1, rc);
    (void)a0sign;
}

static long double qfyl2xp1(long double st1_y, long double st0_x, int rc){
    uint64_t a0sig=x80_frac(st0_x); int32_t a0exp=x80_exp(st0_x); int a0sign=x80_sign(st0_x);
    uint64_t a1sig=x80_frac(st1_y); int32_t a1exp=x80_exp(st1_y); int a1sign=x80_sign(st1_y);
    if (x80_is_zero(st0_x) || x80_is_zero(st1_y) || a1exp==0x7fff){
        long double r; set_round(rc); r = st0_x * st1_y; set_round(0); return r;
    }
    if (a0exp < 0x3fb0){
        uint64_t s0,s1,s2; int32_t e;
        if (a0exp==0) normalizeFloatx80Subnormal(a0sig,&a0exp,&a0sig);
        if (a1exp==0) normalizeFloatx80Subnormal(a1sig,&a1exp,&a1sig);
        mul128By64To192(log2e_hi, log2e_lo, a0sig, &s0,&s1,&s2);
        e = a0exp + 1;
        mul128By64To192(s0,s1, a1sig, &s0,&s1,&s2);
        e += a1exp - 0x3ffe; s1 |= 1;
        return norm_round_pack_x(a0sign ^ a1sign, e, s0, s1, rc);
    }
    int32_t aexp; uint64_t asig0,asig1,asig2;
    qfyl2x_common(st0_x, &aexp, &asig0, &asig1);
    if (a1exp==0) normalizeFloatx80Subnormal(a1sig,&a1exp,&a1sig);
    mul128By64To192(asig0,asig1, a1sig, &asig0,&asig1,&asig2);
    aexp += a1exp - 0x3ffe; asig1 |= 1;
    return norm_round_pack_x(a0sign ^ a1sign, aexp, asig0, asig1, rc);
}

// ---- CLI --------------------------------------------------------------------
//   qref f2xm1 <se_hex> <frac_hex>   -> prints the 80-bit result as se:frac
//   qref --sweep                     -> prints "in_se in_frac out_se out_frac"
//                                       for a fixed input sweep (the gate vectors)
static void emit(long double r){ printf("%04x%016llx\n", (unsigned)(x80_exp(r)|(x80_sign(r)<<15)), (unsigned long long)x80_frac(r)); }

int main(int argc, char**argv){
    fesetround(FE_TONEAREST);
    if (argc >= 4 && !strcmp(argv[1],"f2xm1")){
        uint16_t se = (uint16_t)strtoul(argv[2],0,16);
        uint64_t fr = strtoull(argv[3],0,16);
        emit(qf2xm1(mk(se,fr), 0));
        return 0;
    }
    if (argc >= 2 && !strcmp(argv[1],"--sweep")){
        int rc = (argc >= 3) ? atoi(argv[2]) : 0;   // 0 RNE, 1 down, 2 up, 3 trunc
        // A representative sweep over [-1,1]: the table breakpoints, midpoints,
        // tiny args (ln2 path), the +-1 corners, signed zero, and irregular bits.
        for (int n = -32; n <= 32; n++){
            long double x = (long double)n / 32.0L;        // exact breakpoints
            long double r = qf2xm1(x, rc);
            printf("%04x%016llx %04x%016llx\n",
                (unsigned)(x80_exp(x)|(x80_sign(x)<<15)), (unsigned long long)x80_frac(x),
                (unsigned)(x80_exp(r)|(x80_sign(r)<<15)), (unsigned long long)x80_frac(r));
        }
        // off-grid / irregular values
        static const long double extra[] = {
            0.3333333333333333333L, -0.3333333333333333333L,
            0.7071067811865475244L, -0.123456789L, 0.987654321L,
            1e-8L, -1e-8L, 1e-20L, 0.5000001L, -0.9999999L,
        };
        // genuinely tiny args (exp < 0x3fb0, |x| < 2^-79) -> the ln2 fast path.
        static const struct { uint16_t se; uint64_t fr; } tiny[] = {
            {0x3f9b, 0x8000000000000000ULL}, {0xbf9b, 0xc90fdaa22168c235ULL},
            {0x3f50, 0x9249249249249249ULL}, {0x3e00, 0xfedcba9876543210ULL},
            {0xbf00, 0x8000000000000001ULL}, {0x3faf, 0xffffffffffffffffULL},
        };
        for (size_t i=0;i<sizeof(tiny)/sizeof(tiny[0]);i++){
            long double x = mk(tiny[i].se, tiny[i].fr), r = qf2xm1(x, rc);
            printf("%04x%016llx %04x%016llx\n",
                (unsigned)(x80_exp(x)|(x80_sign(x)<<15)), (unsigned long long)x80_frac(x),
                (unsigned)(x80_exp(r)|(x80_sign(r)<<15)), (unsigned long long)x80_frac(r));
        }
        for (size_t i=0;i<sizeof(extra)/sizeof(extra[0]);i++){
            long double x = extra[i], r = qf2xm1(x, rc);
            printf("%04x%016llx %04x%016llx\n",
                (unsigned)(x80_exp(x)|(x80_sign(x)<<15)), (unsigned long long)x80_frac(x),
                (unsigned)(x80_exp(r)|(x80_sign(r)<<15)), (unsigned long long)x80_frac(r));
        }
        // Feed each table breakpoint t EXACTLY -> exercises the y==0 fast path.
        for (int n=0; n<=64; n++){
            long double x = mk(TBL[n].t_se, TBL[n].t_f);
            if (x == 0.0L) continue;                       // n==32 is +0, covered above
            long double r = qf2xm1(x, rc);
            printf("%04x%016llx %04x%016llx\n",
                (unsigned)(x80_exp(x)|(x80_sign(x)<<15)), (unsigned long long)x80_frac(x),
                (unsigned)(x80_exp(r)|(x80_sign(r)<<15)), (unsigned long long)x80_frac(r));
        }
        // A spread of irregular mantissas across (-1,1) (xorshift-style, no RNG dep).
        uint64_t st = 0x9e3779b97f4a7c15ULL;
        for (int i=0;i<48;i++){
            st ^= st<<13; st ^= st>>7; st ^= st<<17;
            // map to a value in (-1,1): exponent in [0x3fb0,0x3ffe] (polynomial
            // path, strictly |x|<1, never the +-1 out-of-range corner), random frac
            uint16_t e = 0x3fb0 + (uint16_t)(st % (0x3fffu - 0x3fb0u));
            uint64_t fr = 0x8000000000000000ULL | (st >> 1);
            uint16_t se = (uint16_t)(((st>>40)&1)<<15 | e);
            long double x = mk(se, fr);
            long double r = qf2xm1(x, rc);
            printf("%04x%016llx %04x%016llx\n",
                (unsigned)(x80_exp(x)|(x80_sign(x)<<15)), (unsigned long long)x80_frac(x),
                (unsigned)(x80_exp(r)|(x80_sign(r)<<15)), (unsigned long long)x80_frac(r));
        }
        return 0;
    }
    if (argc >= 6 && !strcmp(argv[1],"fpatan")){
        // qref fpatan <y_se> <y_frac> <x_se> <x_frac>
        long double y = mk((uint16_t)strtoul(argv[2],0,16), strtoull(argv[3],0,16));
        long double x = mk((uint16_t)strtoul(argv[4],0,16), strtoull(argv[5],0,16));
        emit(qfpatan(y, x, 0));
        return 0;
    }
    if (argc >= 2 && !strcmp(argv[1],"--sweep-fpatan")){
        int rc = (argc >= 3) ? atoi(argv[2]) : 0;
        // grid of (y,x) over all four quadrants + the |y|<>|x| boundary, plus the
        // signed-zero / axis corners (pi, pi/2). Emits "y80 x80 out80" per line.
        for (int yi=-8; yi<=8; yi++)
        for (int xi=-8; xi<=8; xi++){
            long double y = (long double)yi / 8.0L * 1.3L;   // off-grid scale (irregular bits)
            long double x = (long double)xi / 8.0L * 0.9L;
            if (yi==0 && xi==0) continue;
            long double r = qfpatan(y, x, rc);
            printf("%04x%016llx %04x%016llx %04x%016llx\n",
                (unsigned)(x80_exp(y)|(x80_sign(y)<<15)), (unsigned long long)x80_frac(y),
                (unsigned)(x80_exp(x)|(x80_sign(x)<<15)), (unsigned long long)x80_frac(x),
                (unsigned)(x80_exp(r)|(x80_sign(r)<<15)), (unsigned long long)x80_frac(r));
        }
        // axis / sign corners: y=0 & x<0 -> +-pi ; x=0 -> +-pi/2 ; +-1,+-1 -> +-pi/4,3pi/4
        static const long double yy[] = { 0.0L, -0.0L, 1.0L, -1.0L, 0.0L, 2.0L, -2.0L, 1e-30L };
        static const long double xx[] = {-1.0L, -1.0L, 0.0L,  0.0L, 1.0L,-2.0L, -2.0L, 5.0L };
        for (size_t i=0;i<sizeof(yy)/sizeof(yy[0]);i++){
            long double r = qfpatan(yy[i], xx[i], rc);
            printf("%04x%016llx %04x%016llx %04x%016llx\n",
                (unsigned)(x80_exp(yy[i])|(x80_sign(yy[i])<<15)), (unsigned long long)x80_frac(yy[i]),
                (unsigned)(x80_exp(xx[i])|(x80_sign(xx[i])<<15)), (unsigned long long)x80_frac(xx[i]),
                (unsigned)(x80_exp(r)|(x80_sign(r)<<15)), (unsigned long long)x80_frac(r));
        }
        return 0;
    }
    if (argc >= 6 && (!strcmp(argv[1],"fyl2x") || !strcmp(argv[1],"fyl2xp1"))){
        long double yv = mk((uint16_t)strtoul(argv[2],0,16), strtoull(argv[3],0,16));
        long double xv = mk((uint16_t)strtoul(argv[4],0,16), strtoull(argv[5],0,16));
        emit(!strcmp(argv[1],"fyl2x") ? qfyl2x(yv,xv,0) : qfyl2xp1(yv,xv,0));
        return 0;
    }
    if (argc >= 2 && (!strcmp(argv[1],"--sweep-fyl2x") || !strcmp(argv[1],"--sweep-fyl2xp1"))){
        int isp1 = !strcmp(argv[1],"--sweep-fyl2xp1");
        int rc = (argc >= 3) ? atoi(argv[2]) : 0;
        // y over a spread, x over the op's valid domain. Emits "y80 x80 out80".
        static const long double ys[] = { 1.0L,-1.0L, 2.5L,-0.5L, 0.123L, 7.0L, 100.0L, 1e-5L };
        for (size_t i=0;i<sizeof(ys)/sizeof(ys[0]);i++){
            for (int xi=1; xi<=40; xi++){
                long double xv, yv=ys[i];
                if (isp1) xv = (long double)(xi-20) / 80.0L;          // (-0.2375, 0.25)
                else      xv = (long double)xi / 8.0L;                 // (0.125, 5.0]
                if (!isp1 && xv==1.0L) continue;
                long double r = isp1 ? qfyl2xp1(yv,xv,rc) : qfyl2x(yv,xv,rc);
                printf("%04x%016llx %04x%016llx %04x%016llx\n",
                    (unsigned)(x80_exp(yv)|(x80_sign(yv)<<15)), (unsigned long long)x80_frac(yv),
                    (unsigned)(x80_exp(xv)|(x80_sign(xv)<<15)), (unsigned long long)x80_frac(xv),
                    (unsigned)(x80_exp(r)|(x80_sign(r)<<15)), (unsigned long long)x80_frac(r));
            }
        }
        // corners: x=1 (fyl2x -> +-0), x=2/0.5 (exact powers), x=0 (fyl2xp1 passthrough)
        static const long double cy[]={1.0L,-1.0L, 3.0L, 2.0L};
        for (size_t i=0;i<sizeof(cy)/sizeof(cy[0]);i++){
            long double xv = isp1 ? 0.0L : ((i&1)?0.5L:2.0L), yv=cy[i];
            long double r = isp1 ? qfyl2xp1(yv,xv,rc) : qfyl2x(yv,xv,rc);
            printf("%04x%016llx %04x%016llx %04x%016llx\n",
                (unsigned)(x80_exp(yv)|(x80_sign(yv)<<15)), (unsigned long long)x80_frac(yv),
                (unsigned)(x80_exp(xv)|(x80_sign(xv)<<15)), (unsigned long long)x80_frac(xv),
                (unsigned)(x80_exp(r)|(x80_sign(r)<<15)), (unsigned long long)x80_frac(r));
        }
        return 0;
    }
    fprintf(stderr, "usage: %s f2xm1|fpatan|fyl2x|fyl2xp1 ... | --sweep[-fpatan|-fyl2x|-fyl2xp1] [rc]\n", argv[0]);
    return 2;
}
