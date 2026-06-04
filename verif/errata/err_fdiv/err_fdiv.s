# =============================================================================
# Ventium M6 errata test: err_fdiv -- Pentium FDIV / SRT divide flaw (Erratum 23)
# =============================================================================
# Spec: pentium-spec-update-242480-022.pdf doc p.78, "Slight Precision Loss for
# Floating-point Divides on Specific Operand Pairs". Five missing radix-4 SRT
# PLA entries make divides whose DIVISOR significand matches one of
#   1.0001 / 1.0100 / 1.0111 / 1.1010 / 1.1101  followed by >=6 binary ones
# return a quotient wrong at the 13th significant binary digit.
#
# Canonical public vector: 4195835.0 / 3145727.0
#   correct ~ 1.3338204491362410  (double 0x3FF557541C7C6B43)
#   FLAWED  ~ 1.3337390689020376  (double 0x3FF556FEC7254ED1)  <-- P5 silicon
# 3145727.0 normalizes to significand 1.0111111... (pattern 1.0111 + >=6 ones),
# so it HITS a missing PLA entry. SELF-CHECKED (verif/errata/run-m6.sh) against
# the documented flawed value with errata ON, and the CORRECT value with errata
# OFF (the clean core matches QEMU/M3 exactly).
#
# Freestanding 32-bit i386 (P5). AT&T / GNU as. Ends with _exit(0) (int 0x80).
# =============================================================================

    .text
    .globl  _start
_start:
    # Build the canonical pair: st0 = dividend, st1 = divisor, then divide.
    fldl    divisor             # st0 = 3145727.0
    fldl    dividend            # st0 = 4195835.0  st1 = 3145727.0
    # FDIV st0,st1 (AT&T `fdiv %st(1),%st(0)`): st0 = st0 / st1
    #   = 4195835.0 / 3145727.0  (the canonical flawed pair). Quotient stays in
    #   st0 so the trace captures it directly (st1 keeps the divisor).
    fdiv    %st(1), %st(0)      # st0 = st0 / st1  -> quotient in st0

    # clean exit
    movl    $1, %eax            # __NR_exit
    xorl    %ebx, %ebx          # status 0
    int     $0x80               # HALT

    .data
    .align 8
dividend:   .double 4195835.0
divisor:    .double 3145727.0
