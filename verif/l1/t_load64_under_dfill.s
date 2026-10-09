# Resident x87 operand overlaps the tail of an independent integer data miss.
    .ifndef SOURCE_OFFSET
    .set SOURCE_OFFSET, 0
    .endif
    .ifndef SOURCE_WIDE
    .set SOURCE_WIDE, 1
    .endif
    .macro source_load
    .if SOURCE_WIDE
    fldl (%ebx)
    .else
    flds (%ebx)
    .endif
    .endm
    .text
    .global _start, source_probe, pass_exit
_start:
    fninit
    movl $operand+SOURCE_OFFSET, %ebx
    source_load
    fwait
    fstp %st(0)
    movl $miss_lines, %esi
    movl $16, %ecx
    .balign 32, 0x90
loop:
    movl (%esi), %eax
source_probe:
    source_load
    fwait
    fstp %st(0)
    addl $32, %esi
    decl %ecx
    jnz loop
    movl $1, %eax
    movl $0, %ebx
pass_exit:
    int $0x80
    .data
    .balign 4096
    .space 0x100
operand:
    .long 0x01234567, 0x3ff13579, 0x23456789, 0x4002468a
    .long 0x456789ab, 0x4013579b, 0x6789abcd, 0x402468ac
    .long 0x89abcdef, 0x403579bd, 0xabcdef01, 0x40468ace
    .balign 4096
    .space 0x800
miss_lines:
    .rept 128
    .long 0x13579bdf
    .endr
