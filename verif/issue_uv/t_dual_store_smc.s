# Two independent, different-line dword stores patch executable immediates.
# The V store's line must receive its own I$/uop snoop on an accepted pair.
.text
.globl _start, loop_body, first_store, second_store, exit_syscall
_start:
    # Keep both oracle and RTL stack traffic in the low DRAM window. The
    # production no-L2 cachemap does not classify QEMU's 0x40xxxxxx stack as
    # DRAM unless the separate snapshot-user-highmem experiment is enabled.
    movl $stack_end, %esp
    call patch_u
    call patch_v
    movl $patch_u+1, %esi
    movl $patch_v+1, %edi
    movl $64, %ebp
    movl $10, %ecx
    movl $20, %ebx
    jmp loop_body
.balign 32
loop_body:
first_store:
    movl %ecx, (%esi)
second_store:
    movl %ebx, (%edi)
    call patch_u
    cmpl %ecx, %eax
    jne fail
    call patch_v
    cmpl %ebx, %edx
    jne fail
    incl %ecx
    incl %ebx
    decl %ebp
    jnz loop_body
    movl $1, %eax
    xorl %ebx, %ebx
exit_syscall:
    int $0x80
fail:
    movl $1, %eax
    movl $1, %ebx
    int $0x80
.balign 32
.space 3, 0x90
patch_u:
    .byte 0xb8                 # MOV imm32, EAX
    .long 1                    # dword starts at physical bank 1
    ret
.balign 32
.space 7, 0x90
patch_v:
    .byte 0xba                 # MOV imm32, EDX
    .long 2                    # dword starts at physical bank 2, next line
    ret
.data
.balign 4096
    .space 4096
stack_end:
.section .note.GNU-stack,"",@progbits
