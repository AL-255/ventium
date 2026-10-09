# Generic resident x87 operand behind a critical-word instruction refill.
# Three code islands alias the two-way 8KiB P5 I-cache set. The operand is
# warmed normally at a different D-cache set; no hierarchical state writes.
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
    .global _start, island_a, island_b, island_c, pass_exit
_start:
    fninit
    movl $operand+SOURCE_OFFSET, %ebx
    source_load
    fwait
    fstp %st(0)
    movl $16, %ecx
    jmp island_a
    .org 0x2000, 0x90
island_a:
    source_load
    fwait
    fstp %st(0)
    jmp island_b
    .org 0x4000, 0x90
island_b:
    source_load
    fwait
    fstp %st(0)
    jmp island_c
    .org 0x6000, 0x90
island_c:
    source_load
    fwait
    fstp %st(0)
    decl %ecx
    jnz island_a
    movl $1, %eax
    movl $0, %ebx
pass_exit:
    int $0x80
    .data
    .balign 4096
    .space 0x100
operand:
    # Distinct, finite bytes at every contained/misaligned test offset.
    .long 0x01234567, 0x3ff13579, 0x23456789, 0x4002468a
    .long 0x456789ab, 0x4013579b, 0x6789abcd, 0x402468ac
    .long 0x89abcdef, 0x403579bd, 0xabcdef01, 0x40468ace
