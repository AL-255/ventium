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
        // A representative sweep over [-1,1]: the table breakpoints, midpoints,
        // tiny args (ln2 path), the +-1 corners, signed zero, and irregular bits.
        for (int n = -32; n <= 32; n++){
            long double x = (long double)n / 32.0L;        // exact breakpoints
            long double r = qf2xm1(x, 0);
            printf("%04x%016llx %04x%016llx\n",
                (unsigned)(x80_exp(x)|(x80_sign(x)<<15)), (unsigned long long)x80_frac(x),
                (unsigned)(x80_exp(r)|(x80_sign(r)<<15)), (unsigned long long)x80_frac(r));
        }
        // off-grid / irregular значения
        static const long double extra[] = {
            0.3333333333333333333L, -0.3333333333333333333L,
            0.7071067811865475244L, -0.123456789L, 0.987654321L,
            1e-8L, -1e-8L, 1e-20L, 0.5000001L, -0.9999999L,
        };
        for (size_t i=0;i<sizeof(extra)/sizeof(extra[0]);i++){
            long double x = extra[i], r = qf2xm1(x, 0);
            printf("%04x%016llx %04x%016llx\n",
                (unsigned)(x80_exp(x)|(x80_sign(x)<<15)), (unsigned long long)x80_frac(x),
                (unsigned)(x80_exp(r)|(x80_sign(r)<<15)), (unsigned long long)x80_frac(r));
        }
        // Feed each table breakpoint t EXACTLY -> exercises the y==0 fast path.
        for (int n=0; n<=64; n++){
            long double x = mk(TBL[n].t_se, TBL[n].t_f);
            if (x == 0.0L) continue;                       // n==32 is +0, covered above
            long double r = qf2xm1(x, 0);
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
            long double r = qf2xm1(x, 0);
            printf("%04x%016llx %04x%016llx\n",
                (unsigned)(x80_exp(x)|(x80_sign(x)<<15)), (unsigned long long)x80_frac(x),
                (unsigned)(x80_exp(r)|(x80_sign(r)<<15)), (unsigned long long)x80_frac(r));
        }
        return 0;
    }
    fprintf(stderr, "usage: %s f2xm1 <se_hex> <frac_hex> | --sweep\n", argv[0]);
    return 2;
}
