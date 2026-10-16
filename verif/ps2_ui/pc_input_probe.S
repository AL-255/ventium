/* A general cold-boot 8042 integration probe, not a workload patch.
 * Configure the real controller via I/O, then check Ctrl+Esc and Enter from
 * external PS/2 pins. RAW_MODE selects whether the controller translates.
 */
.section .text,"ax"
.code16
.global _start
_start:
    cli
    cld
    lgdt %cs:(gdt_desc-_start)
    movl %cr0,%eax
    andl $0x9ffffff3,%eax
    orl $1,%eax
    movl %eax,%cr0
    ljmpl $8,$start32
.balign 8
gdt:
    .quad 0,0x00cf9a000000ffff,0x00cf92000000ffff
gdt_desc:
    .word 23
    .long gdt
.code32
start32:
    movw $16,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    movl $0x90000,%esp
    call wait_ibf
    movb $0xa7,%al
    outb %al,$0x64
    call wait_ibf
    /* Drain BIOS-owned output before publishing readiness. */
    movl $1024,%ecx
drain:
    inb $0x64,%al
    testb $1,%al
    jz configure
    inb $0x60,%al
    loop drain
    jmp failed
configure:
    call wait_ibf
    movb $0x60,%al
    outb %al,$0x64
    call wait_ibf
#if RAW_MODE
    movb $0x20,%al
#else
    movb $0x60,%al
#endif
    outb %al,$0x60
    call wait_ibf
    movb $0x20,%al
    outb %al,$0x64
    call read_byte
    andb $0x50,%al
#if RAW_MODE
    cmpb $0,%al
#else
    cmpb $0x40,%al
#endif
    jne failed
    movl $ready,%esi
    call puts
    movl $expected,%esi
    movl $(expected_end-expected),%ebx
receive:
    call read_byte
    cmpb (%esi),%al
    jne failed
    incl %esi
    decl %ebx
    jnz receive
    movl $passed,%esi
    call puts
    movb $0x10,%al
    outb %al,$0xf4
halt:
    cli
    hlt
    jmp halt
failed:
    movl $failure,%esi
    call puts
    movb $0x11,%al
    outb %al,$0xf4
    jmp halt
wait_ibf:
    pushl %ecx
    movl $0x100000,%ecx
1:  inb $0x64,%al
    testb $2,%al
    jz 2f
    loop 1b
    jmp failed
2:  popl %ecx
    ret
read_byte:
    pushl %ecx
    movl $0x1000000,%ecx
1:  inb $0x64,%al
    testb $1,%al
    jz 2f
    testb $0xe0,%al /* No AUX byte, parity error or controller timeout. */
    jnz failed
    inb $0x60,%al
    popl %ecx
    ret
2:  loop 1b
    jmp failed
puts:
    pushal
    movl $0xb8000,%edi
    movl $80,%ecx
    movw $0x0720,%ax
    rep stosw
    movl $0xb8000,%edi
1:  lodsb
    testb %al,%al
    jz 2f
    outb %al,$0xe9 /* Reference diagnostic console; VGA is PC evidence. */
    movb $7,%ah
    stosw
    jmp 1b
2:  movb $10,%al
    outb %al,$0xe9
    popal
    ret
#if RAW_MODE
ready:  .asciz "UI-PROBE-READY raw=1"
passed: .asciz "UI-PROBE-PASS raw=1"
expected: .byte 0x14,0x76,0xf0,0x76,0xf0,0x14,0x5a,0xf0,0x5a
#else
ready:  .asciz "UI-PROBE-READY raw=0"
passed: .asciz "UI-PROBE-PASS raw=0"
expected: .byte 0x1d,0x01,0x81,0x9d,0x1c,0x9c
#endif
expected_end:
failure: .asciz "UI-PROBE-FAIL"
.section .note.GNU-stack,"",@progbits
