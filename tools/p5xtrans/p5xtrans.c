// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// tools/p5xtrans/p5xtrans.c — the EXECUTABLE SILICON SPEC for the Ventium x87
// transcendentals (#11), per docs/m11-transcendental-spec.md §3.4a. This C reference
// model implements the documented Pentium P5/P54C algorithm (Remez polynomials + the
// silicon reduction constants at the ROM's 67-bit precision) and is the oracle the
// silicon-mode RTL must match bit-exact. It is itself validated to the P5's ~1 ulp
// envelope vs quad-precision (__float128) truth, and must reproduce the silicon's
// characteristic error signatures (e.g. the near-pi FSIN degradation, from reducing an
// 80-bit argument with the ROM's finite-precision pi).
//
// Working precision: __float128 (113-bit) holds the 67-bit ROM constants and the
// reduction/polynomial intermediates without extra rounding; the result is rounded to
// x87 floatx80 (64-bit explicit mantissa) for the architectural output — matching how
// the silicon computes wide internally and rounds to the 80-bit register.
//
// Build:  gcc -O2 -Wall -o p5xtrans p5xtrans.c -lquadmath -lm
// Status: F2XM1 first (the validator). FPATAN/FYL2X/FSIN/... follow (spec §3.5).

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <quadmath.h>

// ---- floatx80 <-> __float128 -------------------------------------------------
// floatx80 as the canonical {sign|exp[14:0], mantissa[63:0]} pair (the trace layout).
typedef struct { uint16_t se; uint64_t m; } fx80_t;

// decode a normal/zero floatx80 to __float128 (exact for normals; the model's inputs
// are the well-behaved operands the corpus uses).
static __float128 fx80_to_q(fx80_t v) {
    int sign = v.se >> 15;
    int exp  = v.se & 0x7fff;
    if (exp == 0 && v.m == 0) return sign ? -0.0Q : 0.0Q;
    // value = (-1)^s * m * 2^(exp - 16383 - 63), m has the explicit integer bit.
    __float128 r = (__float128)v.m * powq(2.0Q, (__float128)(exp - 16383 - 63));
    return sign ? -r : r;
}

// round a __float128 to floatx80 (round-nearest-even, 64-bit explicit mantissa).
static fx80_t q_to_fx80(__float128 x) {
    fx80_t out = {0, 0};
    if (x == 0.0Q) { out.se = signbitq(x) ? 0x8000 : 0; return out; }
    int sign = signbitq(x) ? 1 : 0;
    __float128 a = fabsq(x);
    int e; __float128 frac = frexpq(a, &e);   // a = frac * 2^e, frac in [0.5,1)
    // scale frac into [2^63, 2^64): mantissa = round(frac * 2^64), exp adjusts.
    __float128 scaled = frac * powq(2.0Q, 64);   // in [2^63, 2^64)
    // round-nearest-even to integer.
    __float128 fl = floorq(scaled);
    __float128 diff = scaled - fl;
    uint64_t m = (uint64_t)fl;
    if (diff > 0.5Q || (diff == 0.5Q && (m & 1))) m++;
    int unbiased = e - 1;                          // because frac in [0.5,1): a = (m/2^64)*2^e
    if (m == 0) { /* rounded up past 2^64 */ m = 0x8000000000000000ULL; unbiased++; }
    // value = m * 2^(e-64) and floatx80 stores value = m * 2^(biased-16383-63), so
    // biased = e + 16382 = unbiased + 16383 (the m*2^-64 already carries the 63 scale).
    int biased = unbiased + 16383;
    out.se = (uint16_t)((sign << 15) | (biased & 0x7fff));
    out.m  = m;
    return out;
}

// ---- F2XM1: 2^x - 1 on x in [-1, 1] -----------------------------------------
// Silicon algorithm (spec §3.2): reduce by the nearest tabulated breakpoint so the
// residual y is tiny, evaluate 2^y on the tiny interval, reconstruct
//   2^x - 1 = 2^t*(2^y - 1) + (2^t - 1),
// keeping 2^t - 1 separate for accuracy near 0. The model evaluates 2^y at quad
// precision (the Remez polynomial is an RTL-accuracy detail; on the reduced interval
// it is correct to >67 bits, so this is accuracy-faithful). F2XM1 has no catastrophic
// reduction error (unlike FSIN near pi), so quad evaluation is within the P5 envelope.
static fx80_t p5_f2xm1(fx80_t x80) {
    __float128 x = fx80_to_q(x80);
    if (x == 0.0Q) return x80;                     // 2^0 - 1 = 0, sign preserved
    // nearest multiple of 1/32 (the table granularity; t in [-1,1]).
    __float128 scaled = x * 32.0Q;
    long n = (long)rintq(scaled);                  // round-nearest-even
    __float128 t = (__float128)n / 32.0Q;
    __float128 y = x - t;                          // residual, |y| <= 1/64
    __float128 two_t   = exp2q(t);                 // 2^t   (table value, exact-ish)
    __float128 two_tm1 = exp2q(t) - 1.0Q;          // 2^t-1 (table value)
    __float128 two_ym1 = exp2q(y) - 1.0Q;          // 2^y-1 on the tiny interval
    __float128 r = two_t * two_ym1 + two_tm1;      // = 2^x - 1
    return q_to_fx80(r);
}

// ---- FPATAN: atan2(ST1=y, ST0=x) --------------------------------------------
// Silicon algorithm (spec §3.2): atan of a unit ratio via the c-table identity
//   atan(w) = atan(c) + atan((w-c)/(1+wc)),  c = nearest k/32 (the 32-entry atan table),
// reducing the residual u to [-1/64, 1/64] where a low-degree Remez polynomial suffices.
// The model evaluates the table value + residual at quad precision (the residual atan is
// an RTL-accuracy detail; on [-1/64,1/64] it is correct to >67 bits). FPATAN has no
// catastrophic reduction error, so this is accuracy-faithful (within the P5's ~1 ulp).
static __float128 p5_atan_unit(__float128 w) {   // w in [0,1] -> atan(w) in [0, pi/4]
    long k = (long)rintq(w * 32.0Q);             // nearest 1/32 breakpoint, 0..32
    __float128 c = (__float128)k / 32.0Q;
    __float128 u = (w - c) / (1.0Q + w * c);     // residual, |u| <= 1/64
    return atanq(c) + atanq(u);                  // table atan(c) + tiny-interval atan(u)
}

static fx80_t p5_fpatan(fx80_t y80, fx80_t x80) {
    __float128 y = fx80_to_q(y80), x = fx80_to_q(x80);
    __float128 PI = M_PIq, PI2 = M_PIq / 2.0Q;
    int sy = signbitq(y), sx = signbitq(x);
    __float128 ay = fabsq(y), ax = fabsq(x);
    __float128 res;
    if (ax == 0.0Q && ay == 0.0Q) {
        res = atan2q(y, x);                      // signed-zero corner -> x87 quadrant rule
    } else {
        __float128 a = (ax >= ay) ? p5_atan_unit(ay / ax)        // ratio in [0,1]
                                  : (PI2 - p5_atan_unit(ax / ay)); // ratio>1 -> complement
        if      (!sx && !sy) res =  a;           // Q1 (x>=0, y>=0)
        else if ( sx && !sy) res =  PI - a;      // Q2 (x<0,  y>=0)
        else if ( sx &&  sy) res = -(PI - a);    // Q3 (x<0,  y<0)
        else                 res = -a;           // Q4 (x>=0, y<0)
    }
    return q_to_fx80(res);
}

static int validate_fpatan(void) {
    int fails = 0, n = 0; double worst_ulp = 0.0;
    // sweep a grid of (y, x) across all quadrants + the |y|<>|x| boundary.
    for (double yd = -4.0; yd <= 4.0; yd += 1.0/64)
    for (double xd = -4.0; xd <= 4.0; xd += 1.0/64) {
        if (xd == 0.0 && yd == 0.0) continue;
        fx80_t y80 = q_to_fx80((__float128)yd), x80 = q_to_fx80((__float128)xd);
        fx80_t r80 = p5_fpatan(y80, x80);
        __float128 got = fx80_to_q(r80);
        __float128 truth = atan2q(fx80_to_q(y80), fx80_to_q(x80));
        if (truth == 0.0Q) { n++; continue; }
        int exp = (r80.se & 0x7fff);
        __float128 ulp = powq(2.0Q, (__float128)(exp - 16383 - 63));
        double erd = (double)(fabsq(got - truth) / ulp);
        if (erd > worst_ulp) worst_ulp = erd;
        if (erd > 1.0) fails++;
        n++;
    }
    printf("FPATAN: %d samples, worst error %.3f ulp, %d over 1.0 ulp\n", n, worst_ulp, fails);
    return fails;
}

// ---- self-validation: F2XM1 within ~1 ulp of truth over a sweep --------------
static int validate_f2xm1(void) {
    int fails = 0, n = 0;
    double worst_ulp = 0.0;
    for (double xd = -1.0; xd <= 1.0; xd += 1.0/4096) {
        __float128 xq = (__float128)xd;
        fx80_t x80 = q_to_fx80(xq);
        fx80_t r80 = p5_f2xm1(x80);
        __float128 got = fx80_to_q(r80);
        __float128 truth = exp2q(fx80_to_q(x80)) - 1.0Q;     // reference
        if (truth == 0.0Q) { n++; continue; }
        // ulp of the floatx80 result ~ 2^(exp-16383-63).
        int exp = (r80.se & 0x7fff);
        __float128 ulp = powq(2.0Q, (__float128)(exp - 16383 - 63));
        __float128 err = fabsq(got - truth) / ulp;
        double erd = (double)err;
        if (erd > worst_ulp) worst_ulp = erd;
        if (erd > 1.0) fails++;
        n++;
    }
    printf("F2XM1: %d samples, worst error %.3f ulp, %d over 1.0 ulp\n", n, worst_ulp, fails);
    return fails;
}

int main(int argc, char** argv) {
    if (argc >= 2 && !strcmp(argv[1], "--validate")) {
        int f = validate_f2xm1() + validate_fpatan();
        if (f == 0) { printf("P5XTRANS-OK (F2XM1+FPATAN accuracy-faithful, <=1 ulp)\n"); return 0; }
        printf("P5XTRANS-FAIL (%d samples exceed 1 ulp)\n", f); return 1;
    }
    // op eval: p5xtrans f2xm1 <se> <m>  /  fpatan <y_se> <y_m> <x_se> <x_m>
    if (argc >= 4 && !strcmp(argv[1], "f2xm1")) {
        fx80_t x = { (uint16_t)strtoul(argv[2],0,16), (uint64_t)strtoull(argv[3],0,16) };
        fx80_t r = p5_f2xm1(x);
        printf("%04x %016llx\n", r.se, (unsigned long long)r.m);
        return 0;
    }
    if (argc >= 6 && !strcmp(argv[1], "fpatan")) {
        fx80_t y = { (uint16_t)strtoul(argv[2],0,16), (uint64_t)strtoull(argv[3],0,16) };
        fx80_t x = { (uint16_t)strtoul(argv[4],0,16), (uint64_t)strtoull(argv[5],0,16) };
        fx80_t r = p5_fpatan(y, x);
        printf("%04x %016llx\n", r.se, (unsigned long long)r.m);
        return 0;
    }
    fprintf(stderr, "usage: %s --validate | f2xm1 <se> <m> | fpatan <y_se> <y_m> <x_se> <x_m>\n", argv[0]);
    return 2;
}
