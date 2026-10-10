/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1 */
/* Ordinary BIOS hard-disk boot, not a register/memory snapshot. */
.code16
.section .text
.global _start
_start:
    cli
    xorw %ax,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    movw $0x7c00,%sp
    movb %dl,boot_drive
    sti
    movw $3,%ax
    int $0x10
    xorw %ax,%ax
    movw %ax,%ds
    movw $packet,%si
    movb boot_drive,%dl
    movb $0x42,%ah
    int $0x13
    jc failed
    cli
    ljmp $0x1000,$0
failed:
    movb $'!',%al
    outb %al,$0xe9
    movw $0x0e21,%ax
    xorw %bx,%bx
    int $0x10
    cli
1:  hlt
    jmp 1b
.balign 4
packet:
    .byte 16,0
    .word PAYLOAD_SECTORS
    .word 0,0x1000
    .long 1,0
boot_drive: .byte 0
.org 510
.word 0xaa55
.section .note.GNU-stack,"",@progbits
