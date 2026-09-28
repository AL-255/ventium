# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Two adjacent full-dword stores. SECOND_OFFSET=4 is the eligible same-line,
# different-bank case; 0 aliases U and 32 crosses the physical cache line.
.ifndef SECOND_OFFSET
.set SECOND_OFFSET, 4
.endif
.ifndef IDLE_GAP
.set IDLE_GAP, 0
.endif
.text
.globl _start
_start:
    movl $arena, %esi
    movl $1000, %ecx
    movl $0x12345678, %eax
    movl $0x87654321, %edx
.balign 32
.globl loop_body
loop_body:
.globl first_store
first_store:
    movl %eax, (%esi)
.globl second_store
second_store:
    movl %edx, SECOND_OFFSET(%esi)
    movl SECOND_OFFSET(%esi), %ebx
    # In the open-slot variant, let prior AXI B responses drain before the
    # next pair. The saturated variant must fall back to serial issue cheaply.
.rept IDLE_GAP
    nop
.endr
    decl %ecx
    jnz loop_body
    movl $1, %eax
.globl exit_syscall
exit_syscall:
    int $0x80
.data
.balign 4096
arena:
    .zero 8192
