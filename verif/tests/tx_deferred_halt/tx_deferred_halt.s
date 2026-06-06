# =============================================================================
# Ventium M3 x87 boundary test: tx_deferred_halt -- DEFERRED op MUST loud-HALT
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium), x87 FPU. AT&T / GNU as.
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Pins the x87 COVERAGE BOUNDARY (REVIEW_Jun5.md Recommended Step 4, Limit #2):
# the transcendental / FP-environment ops are DEFERRED (m3-fpu-spec.md
# "DEFERRED — loud HALT, never fake"). (BCD FBLD/FBSTP were deferred too but are
# now IMPLEMENTED in M10; FSIN below stands in for the still-deferred set.) The
# machine-checkable expectation is that
# the RTL core enters S_HALT on the deferred decode (d_unknown -> S_HALT, see
# rtl/core/core.sv:1889 + the S_DECODE default -> S_HALT at :3139) and DOES NOT
# retire the deferred op or anything after it. That is the *correct* behavior for
# a deferred op: a loud HALT is strictly better than a silent mis-execution.
#
# This is NOT a differential-vs-QEMU func test (QEMU *does* execute FSIN with its
# own softfloat approximation and would keep running -> a length mismatch, which
# the standard compare.py would flag as a divergence). It is gated instead by the
# dedicated harness verif/tests/run_x87_boundary.sh, which asserts the HALT
# directly: the PRE sentinel retires, the deferred op + POST sentinel + the
# int-0x80 exit never retire, and the core goes quiescent (no further retire).
#
# Representative deferred op chosen: FSIN (D9 FE) -- a transcendental, the
# canonical "QEMU-computes-an-approximation, real-P54C-differs" case from
# m3-fpu-spec.md:51. It is a pure 2-byte opcode (mod==11, mrm=0xFE), no FWAIT
# prefix, no memory operand -> the cleanest possible boundary marker. It hits the
# `default: d_unknown=1'b1` arm in the D9 reg-form casez (core.sv:1889).
#
# QEMU (the correct, full-x87 producer) behavior, for the record: FSIN on a
# normal operand returns sin(st0) in st0 and clears C2 (argument-in-range);
# helper_fsin in target/i386/fpu_helper.c. Ventium intentionally does NOT
# reproduce that bit-exactly (matching QEMU's approximation != matching real
# Pentium microcode), so it HALTs. See the other deferred families documented in
# the comments below; FSIN stands in for all of them at the decode boundary.
# =============================================================================

    .text
    .globl  _start
_start:
    # ---- PRE sentinel: this MUST retire (proves we reached the boundary) -----
    # A distinctive marker the boundary harness greps for in the RTL trace. If
    # this never retires the test is mis-built; if it DOES retire we know the
    # core ran up to the deferred op.
    movl    $0xDEAD0001, %eax       # PRE  marker -> EAX

    # Set up a benign normal operand so FSIN would have valid input *if* it ran.
    fldpi                           # st0 = pi (a normal, in-range operand)

    # ---- THE DEFERRED OP: must loud-HALT here (d_unknown -> S_HALT) ----------
    # D9 FE. The RTL must NOT retire this. Everything below is "after the HALT"
    # and must therefore NEVER appear in the RTL retire trace.
    fsin                            # DEFERRED: transcendental. RTL HALTs here.

    # ---- POST sentinel + exit: these MUST NOT retire -------------------------
    # If any of the following retires, the boundary has silently rotted (the
    # deferred op was implemented/decoded instead of HALTing) -> harness FAILS.
    movl    $0xDEAD0002, %ebx       # POST marker -> EBX (must never be observed)

    movl    $1, %eax                # Linux _exit(0) -- the normal clean terminator
    xorl    %ebx, %ebx
    int     $0x80                   # would HALT cleanly (d_halt) IF reached -- it
                                    # is NOT reached because FSIN already HALTed.
