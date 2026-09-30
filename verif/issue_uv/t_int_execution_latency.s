// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Six instructions per iteration. Arithmetic results never rely on a snapshot.
// OP: 0 MUL, 1 unary IMUL, 2 0F AF IMUL, 3 6B IMUL, 4 DIV, 5 IDIV,
//     6 69 IMUL, 7 CL SHL, 8 CL SHR, 9 CL SAR, 10 CL ROL, 11 CL ROR.
.macro cl_operation operation
  .if WIDTH == 8
    .if MEM
      \operation\()b %cl, (%esi)
    .elseif HIGH8
      \operation\()b %cl, %ah
    .else
      \operation\()b %cl, %al
    .endif
  .elseif WIDTH == 16
    .if MEM
      \operation\()w %cl, (%esi)
    .else
      \operation\()w %cl, %ax
    .endif
  .else
    .if MEM
      \operation\()l %cl, (%esi)
    .else
      \operation\()l %cl, %eax
    .endif
  .endif
.endm
.text
.globl _start
_start:
.if OP >= 7
    movl $64, %edi
    movl $COUNT, %ecx
.else
    movl $64, %ecx
.endif
    movl $arena, %esi
    movl $3, %ebx
    jmp loop_body
.balign 32
.ifndef LOOP_PAD
  .set LOOP_PAD, 0
.endif
.fill LOOP_PAD, 1, 0x90
.globl loop_body
loop_body:
.if OP >= 7
  .if MEM
    movl $0xa5c38181, (%esi)
  .else
    movl $0xa5c38181, %eax
  .endif
    stc
.else
    movl $6, %eax
    xorl %edx, %edx
.endif
.globl tested_op
tested_op:
.if OP == 7
    cl_operation shl
.elseif OP == 8
    cl_operation shr
.elseif OP == 9
    cl_operation sar
.elseif OP == 10
    cl_operation rol
.elseif OP == 11
    cl_operation ror
.elseif OP == 0
  .if WIDTH == 8
    .if MEM
      mulb (%esi)
    .else
      mulb %bl
    .endif
  .elseif WIDTH == 16
    .if MEM
      mulw (%esi)
    .else
      mulw %bx
    .endif
  .else
    .if MEM
      mull (%esi)
    .else
      mull %ebx
    .endif
  .endif
.elseif OP == 1
  .if WIDTH == 8
    .if MEM
      imulb (%esi)
    .else
      imulb %bl
    .endif
  .elseif WIDTH == 16
    .if MEM
      imulw (%esi)
    .else
      imulw %bx
    .endif
  .else
    .if MEM
      imull (%esi)
    .else
      imull %ebx
    .endif
  .endif
.elseif OP == 2 || OP == 3 || OP == 6
  .if WIDTH == 16
    .if MEM
      .if OP == 6
        imulw $0x1234, (%esi), %ax
      .elseif OP == 3
        imulw $3, (%esi), %ax
      .else
        imulw (%esi), %ax
      .endif
    .else
      .if OP == 6
        imulw $0x1234, %bx, %ax
      .elseif OP == 3
        imulw $3, %bx, %ax
      .else
        imulw %bx, %ax
      .endif
    .endif
  .else
    .if MEM
      .if OP == 6
        imull $0x1234, (%esi), %eax
      .elseif OP == 3
        imull $3, (%esi), %eax
      .else
        imull (%esi), %eax
      .endif
    .else
      .if OP == 6
        imull $0x1234, %ebx, %eax
      .elseif OP == 3
        imull $3, %ebx, %eax
      .else
        imull %ebx, %eax
      .endif
    .endif
  .endif
.else
  .if WIDTH == 8
    .if MEM
      .if OP == 5
        idivb (%esi)
      .else
        divb (%esi)
      .endif
    .else
      .if OP == 5
        idivb %bl
      .else
        divb %bl
      .endif
    .endif
  .elseif WIDTH == 16
    .if MEM
      .if OP == 5
        idivw (%esi)
      .else
        divw (%esi)
      .endif
    .else
      .if OP == 5
        idivw %bx
      .else
        divw %bx
      .endif
    .endif
  .else
    .if MEM
      .if OP == 5
        idivl (%esi)
      .else
        divl (%esi)
      .endif
    .else
      .if OP == 5
        idivl %ebx
      .else
        divl %ebx
      .endif
    .endif
  .endif
.endif
    nop
.if OP >= 7
    decl %edi
.else
    decl %ecx
.endif
    jnz loop_body
    xorl %ebx, %ebx
    movl $1, %eax
.globl exit_syscall
exit_syscall:
    int $0x80
.data
.balign 32
arena:
    .long 3
