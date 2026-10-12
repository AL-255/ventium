/* Memory FDIV/FDIVR erratum witness. FORMAT: f32/f64/i32/i16.
 * The first three forms use the classic 4195835 / 3145727 pair. The i16
 * form uses 29 / 7 (both directions) as a narrow signed-width control.
 * No snapshots or workload-specific processor behavior are involved.
 */
    .text
    .code32
    .global _start, quotient, exit_int
_start:
    fninit
    movl $1,%esi
    movl $2,%edi
    .rept 8
    addl $3,%esi
    addl $5,%edi
    .endr
    fldl initial
quotient:
#if FORMAT == 0
#if REVERSE
    fdivrs operand
#else
    fdivs operand
#endif
#elif FORMAT == 1
#if REVERSE
    fdivrl operand
#else
    fdivl operand
#endif
#elif FORMAT == 2
#if REVERSE
    fidivrl operand
#else
    fidivl operand
#endif
#else
#if REVERSE
    fidivrs operand
#else
    fidivs operand
#endif
#endif
    fnstsw %ax
    movl %eax,%edx
    movl $1,%eax
    xorl %ebx,%ebx
exit_int:
    int $0x80

    .data
    .balign 8
initial:
#if FORMAT == 3
#if REVERSE
    .double 7
#else
    .double 29
#endif
#else
#if REVERSE
    .double 3145727
#else
    .double 4195835
#endif
#endif
operand:
#if REVERSE
#define VALUE 4195835
#else
#define VALUE 3145727
#endif
#if FORMAT == 0
    .float VALUE
#elif FORMAT == 1
    .double VALUE
#elif FORMAT == 2
    .long VALUE
#else
#if REVERSE
    .short 29
#else
    .short 7
#endif
#endif
    .section .note.GNU-stack,"",@progbits
