.intel_syntax noprefix
.section .text
.global _start
_start:
    xor ebp, ebp
    mov esi, offset cases
again:
    fninit
    frstor [esi]
    frndint
    fnsave [saved]
    mov ebx, 1
    mov eax, [saved+28]
    cmp eax, [esi+108]
    jne finish
    inc ebx
    mov eax, [saved+32]
    cmp eax, [esi+112]
    jne finish
    inc ebx
    movzx eax, word ptr [saved+36]
    cmp eax, [esi+116]
    jne finish
    inc ebx
    movzx eax, word ptr [saved+4]
    and eax, 0x82ff
    mov edx, [esi+120]
    and edx, 0x82ff
    cmp eax, edx
    jne finish
    inc ebp
    add esi, 124
    cmp esi, offset cases_end
    jne again
    xor ebx, ebx
finish:
    mov eax, 1
    int 0x80
.section .data
.balign 16
cases:
.incbin "cases.bin"
cases_end:
.balign 16
saved:
.zero 108
.section .note.GNU-stack,"",@progbits
