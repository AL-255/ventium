// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Deferred whole-core QEMU/retirement-owner fixture; no save-state or synthetic
// result. OLD:0 MOVSX,1 IMUL2. NEXT:0 MOVSX,1 0FAF,2 word69,3 word6B,
// 4 word66+0FAF (must reject:two prefix clocks). MEM:memory next operand.
// HAZARD:old IMUL writes ESI immediately before next memory EA uses ESI.
.text
.globl _start
_start:
    movl $64, %ecx
    movl $arena, %esi
    movl $3, %ebx
    movl $0xa55a8081, %eax
    jmp loop_body
.balign 32
.globl loop_body, tested_old, tested_next
loop_body:
tested_old:
.if OLD == 0
    movswl %bx, %eax
.elseif HAZARD
    imull $1, %esi, %esi
.else
    imull %ebx, %eax
.endif
tested_next:
.if NEXT == 0
  .if MEM
    movswl (%esi), %eax
  .else
    movswl %ax, %eax
  .endif
.elseif NEXT == 1
  .if MEM
    imull (%esi), %eax
  .else
    imull %ebx, %eax
  .endif
.elseif NEXT == 2
  // Force69; assembler may choose6B for a representable signed byte.
  .if MEM
    .byte 0x66, 0x69, 0x06, 0x34, 0x92
  .else
    .byte 0x66, 0x69, 0xc0, 0x34, 0x92
  .endif
.elseif NEXT == 3
  .if MEM
    imulw $-3, (%esi), %ax
  .else
    imulw $-3, %ax, %ax
  .endif
.elseif NEXT == 4
  .if MEM
    imulw (%esi), %ax
  .else
    imulw %bx, %ax
  .endif
.else
    .error "invalid NEXT"
.endif
    decl %ecx
    jnz loop_body
    movl %eax, %edx
    movl $1, %eax
    xorl %ebx, %ebx
.globl exit_syscall
exit_syscall:
    int $0x80
.balign 32
arena:
    .long 3, 0xffff8001, 0xa5c38181, 7
