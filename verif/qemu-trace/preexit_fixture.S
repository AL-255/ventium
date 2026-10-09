/* Real linux-user write, followed by exit/exit_group with known integer/x87
 * state. No saved state or debugger register writes. Parameters are assembler
 * --defsym values; the initial explicit stack removes loader-env differences. */
.code32
.section .text
.global _start, terminal, after_terminal
_start:
    mov $stack_top, %esp
    fninit
    mov $4, %eax
    mov $1, %ebx
    mov $message, %ecx
    mov $8, %edx
    int $0x80
.if FP_VARIANT
    fld1
    fldl2t
    fchs
.else
    fldz
    fld1
.endif
    xor %ecx, %ecx
    mov $0x12345678, %ecx
    mov $0x23456789, %edx
    mov $0x3456789a, %esi
    mov $0x456789ab, %edi
    mov $0x56789abc, %ebp
    mov $EXIT_CODE, %ebx
    mov $EXIT_NR, %eax
.if FLAGS_VARIANT
    stc
    std
.else
    clc
    cld
.endif
terminal:
    int $0x80
after_terminal:
    ud2                         /* Never executes on any passing native run. */
.section .rodata
message: .ascii "PREEXIT\n"
.section .bss
.balign 16
    .skip 4096
stack_top:
.section .note.GNU-stack,"",@progbits
