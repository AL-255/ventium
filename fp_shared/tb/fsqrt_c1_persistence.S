// Exact-result C1 regression witness. No undefined condition bits are asserted.
// Assemble as i386; FNSTSW writes four raw little-endian words to stdout.
// After FPREM1(16,3), remainder=1 and Q=5 gives C1=1. FSQRT(1) must clear C1.
.section .text
.globl _start
_start:
    fninit
    flds three
    flds sixteen
    fprem1
    fnstsw words
    fsqrt
    fnstsw words+2
    fstp %st(0)
    fnstsw words+4
    fstp %st(0)
    fnstsw words+6
    movl $4,%eax
    movl $1,%ebx
    movl $words,%ecx
    movl $8,%edx
    int $0x80
    movl $1,%eax
    xorl %ebx,%ebx
    int $0x80
.section .data
.align 4
three: .float 3.0
sixteen: .float 16.0
words: .space 8
