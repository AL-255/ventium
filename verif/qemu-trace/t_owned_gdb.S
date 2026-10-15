/* Deterministic first retirement: no loader-stack masking is necessary. */
.section .text
.global _start
_start:
#ifdef VICTIM
    mov $0x2468ace0, %edi
2:  inc %edi
    jmp 2b
#endif
    mov $stack_top, %esp
    mov $0x13579bdf, %edi
    mov $3, %ecx
1:  add $7, %edi
    loop 1b
    fninit
    fld1
    fld1
    faddp
    fstpl result
    mov $1, %eax
    xor %ebx, %ebx
    int $0x80
.section .bss
.align 16
result: .skip 8
.skip 4096
stack_top:
