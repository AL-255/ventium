// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Prepared whole-core dependency witness, not executed in the CoreMark-only
// phase. Six instructions/1000 loops; use run-load-issue-ipc.sh ASM_SOURCE.
// FAMILY:0EXT,1TESTmem,2MULmem,3DIVmem,4IMUL2mem,5LEA16,6moffs.
// DEPENDENT=0: writer EBX, address ESI (no AGI).
// DEPENDENT=1: writer EBX, address EBX (retain the old decode clock unless
// the optional PREFIX_AGI profile pays a real prefix D1 clock in its place).
// EXTRA_PREFIX=1 adds66, EXTRA_PREFIX=2 adds2E, EXTRA_PREFIX=3 adds66+2E.
// 0F EXT/IMUL inherently have one opcode-map prefix; 66LEA inherently has66.
.ifndef FAMILY
.set FAMILY,0
.endif
.ifndef EXTRA_PREFIX
.set EXTRA_PREFIX,0
.endif
.text
.globl _start
_start:
    movl $1000,%ecx
    movl $arena,%esi
    movl $arena,%ebx
    movl $0,%edi
    movl $0,%edx
    jmp loop_body
.balign 32
.globl loop_body
loop_body:
    // EDX=0 is preserved by these operands, including MUL high half and DIV
    // remainder, so no unrelated setup needs to intervene after predecessor.
    movl $7,%eax
.globl predecessor
predecessor:
    movl %esi,%ebx
.globl tested_op
tested_op:
.if EXTRA_PREFIX==1 || EXTRA_PREFIX==3
    .byte 0x66
.endif
.if EXTRA_PREFIX==2 || EXTRA_PREFIX==3
    .byte 0x2e
.endif
.if FAMILY==6
    movl arena,%eax // A1 moffs: no base/index dependency, even on EBX writes.
.else
.if DEPENDENT
.if FAMILY==0
    movzbl (%ebx),%eax
.elseif FAMILY==1
    testl %edx,(%ebx)
.elseif FAMILY==2
    mull (%ebx)
.elseif FAMILY==3
    divl (%ebx)
.elseif FAMILY==4
    imull (%ebx),%eax
.else
    leaw (%ebx),%ax
.endif
.else
.if FAMILY==0
    movzbl (%esi),%eax
.elseif FAMILY==1
    testl %edx,(%esi)
.elseif FAMILY==2
    mull (%esi)
.elseif FAMILY==3
    divl (%esi)
.elseif FAMILY==4
    imull (%esi),%eax
.else
    leaw (%esi),%ax
.endif
.endif
.endif
    addl $1,%edi
    decl %ecx
    jne loop_body
    movl $1,%eax
    movl $0,%ebx
.globl exit_syscall
exit_syscall:
    int $0x80
.data
.balign 16
arena:
    .long 7 // DIV remainder0, MUL high half0, no #DE or growing operands.
