// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// sw/ps/ven_soc_app/ven_fp_ps.h — FP_PS_ALL x87 op dispatcher (PS side).
//
// When the bitstream is built FP_PS_ALL=1 the ENTIRE x87 compute datapath is gated
// out of the PL (the iterative engines + the fx_add/mul/div/sqrt/compare/frndint/
// fscale combinational cones). Every x87 ARITHMETIC / COMPARE / CLASSIFY /
// TRANSCENDENTAL op traps to the A53, which stalls the core in S_FPTRAP_WAIT and
// exposes the operands over the 0xEC-0xFC AXIL window. This module reads them,
// computes bit-exactly with Berkeley SoftFloat-3e extF80 (the 80-bit x87 type —
// aarch64 `long double` is 128-bit IEEE, NOT floatx80, so a software floatx80 is
// mandatory), and writes back the generalized result vector (res0/res1/status + a
// 4-bit stack action). Data-movement ops (FLD/FST/FILD/FIST/FXCH/FLDCONST/FNINIT/
// ...) stay in the PL and never reach here.
//
// rd/wr are the same mmap'd-AXIL word accessors ven_soc_app.c uses (passed in so
// this stays a thin, testable unit). Returns 1 if a trap was serviced, else 0.

#ifndef VEN_FP_PS_H
#define VEN_FP_PS_H

#include <stdint.h>

typedef uint32_t (*ven_rd_fn)(uint32_t off);
typedef void     (*ven_wr_fn)(uint32_t off, uint32_t v);

// Service ONE pending FP trap (read op+operands, compute, write result+commit).
// Caller gates on (rd(VEN_R_FPT_STAT) & VEN_FPT_STAT_ACTIVE).
void ven_fp_ps_service(ven_rd_fn rd, ven_wr_fn wr);

#endif // VEN_FP_PS_H
