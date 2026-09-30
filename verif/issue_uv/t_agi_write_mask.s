// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Prepared whole-core/QEMU witness. Use run-load-issue-ipc.sh ASM_SOURCE.
// CASE selects a previous writer followed immediately by a memory/LEA address
// consumer. These are functional/actual result-gap witnesses, NOT score claims.
// Parent-authorized bounded qualification uses the prebuilt-binary runner.
.ifndef CASE
.set CASE,0
.endif
.text
.globl _start
_start:
    movl $stack_top,%esp
    movl $arena,%esi
    movl $arena,%ebx
    movl $0,%edx
    movl $stack_top,%eax          # CASE10 XCHG must install a valid stack too
    movl $0,%edi
    movl $1000,%ecx
    jmp loop_body
.balign 32
.globl loop_body
loop_body:
.if CASE==10
    movl $stack_top,%eax          # seed independently of the preceding sample
.endif
.globl predecessor
predecessor:
.if CASE==0
    pushl %ebx                    # implicit ESP must not cause next ESP AGI
.elseif CASE==1
    popl %ebx                     # implicit ESP cleared, explicit EBX kept
.elseif CASE==2
    movl $stack_top,%esp          # explicit ESP must cause following ESP AGI
.elseif CASE==3
    popl %esp                    # explicit popped ESP must not be exempted
.elseif CASE==4
    movl %esi,%ebx               # ordinary dependent base remains tracked
.elseif CASE==5
    movb $0,%bh                  # high-byte parent EBX dependency retained
.elseif CASE==6
    movw $0,%bx                  # word parent EBX dependency retained
.elseif CASE==7
    movzbl (%esi),%ebx           # slow explicit destination now tracked
.elseif CASE==8
    movl $7,%eax
    mull (%esi)                  # actual EAX+EDX outputs both tracked
.elseif CASE==9
    movl $7,%eax
    divl (%esi)                  # actual EAX+EDX outputs both tracked
.elseif CASE==10
    xchgl %eax,%esp              # both explicit outputs including ESP
.elseif CASE==11
    shll $0,%ebx                 # effective count zero emits no physical write
.elseif CASE==12
    movl %esi,%ebx
    nop                          # no-write clock clears previous producer
.else
    movl %esi,%ebx               # unrelated consumer address must not stall
.endif
.globl tested_op
tested_op:
.if CASE<=3 || CASE==10
    movl (%esp),%eax
.elseif CASE==8 || CASE==9
    leal (%eax,%edx,2),%eax       # both MUL/DIV output dependencies
.elseif CASE==5 || CASE==6 || CASE==7
    leal (%ebx),%eax              # avoid dereferencing deliberately small EA
.elseif CASE==13
    movl (%esi),%eax              # independent prior EBX
.else
    movl (%ebx),%eax
.endif
    addl $1,%edi
.if CASE==0
    addl $4,%esp                  # restore balance outside measured edge
.elseif CASE==1 || CASE==3 || CASE==10
    movl $stack_top,%esp
.elseif CASE==8 || CASE==9
    movl $0,%edx
.endif
    decl %ecx
    jne loop_body
    movl $1,%eax
    movl $0,%ebx
.globl exit_syscall
exit_syscall:
    int $0x80
.data
.balign 32
arena:
    .long 7
    .fill 31,4,7
    .balign 32
stack_storage:
    .fill 32,4,0
stack_top:
    .long stack_top               # repeated POP ESP installs a valid stack
    .long arena
    .fill 30,4,0
