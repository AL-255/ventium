# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Generic MOV source service, every physical byte/word/dword destination. No
# saved state, dynamic opcode specialization, or benchmark-specific addresses.
.ifndef WIDTH
.set WIDTH,16
.endif
.ifndef LANE
.set LANE,0
.endif
.ifndef DATA_OFFSET
.set DATA_OFFSET,0
.endif
.ifndef MODE
.set MODE,0
.endif
.ifndef VALUE
.set VALUE,0xdeadbeef
.endif
.text
.globl _start
_start:
    movl %esp,original_esp
    movl $0x12345678,%eax
    movl $0x12345678,%ecx
    movl $0x12345678,%edx
    movl $0x12345678,%ebx
    movl $0x12345678,%ebp
    movl $0x12345678,%esi
    movl $0x12345678,%edi
    jmp loop_body
.balign 32
.globl loop_body
loop_body:
.globl predecessor
predecessor:
    stc
.globl tested_op
tested_op:
# Byte/dword get exactly one segment prefix to exercise the slow source path.
# Word gets its ordinary 66. MODE1 adds a second prefix, deliberately excluded.
.if MODE==1 || WIDTH!=16
    .byte 0x3e
.endif
.if MODE==1 && WIDTH!=16
    .byte 0x36
.endif
.if MODE==2
    cmpw $0,arena+DATA_OFFSET
.elseif MODE==3
    testw $-1,arena+DATA_OFFSET
.elseif WIDTH==8
.if LANE==0
    movb arena+DATA_OFFSET,%al
.elseif LANE==1
    movb arena+DATA_OFFSET,%cl
.elseif LANE==2
    movb arena+DATA_OFFSET,%dl
.elseif LANE==3
    movb arena+DATA_OFFSET,%bl
.elseif LANE==4
    movb arena+DATA_OFFSET,%ah
.elseif LANE==5
    movb arena+DATA_OFFSET,%ch
.elseif LANE==6
    movb arena+DATA_OFFSET,%dh
.else
    movb arena+DATA_OFFSET,%bh
.endif
.elseif WIDTH==16
.if LANE==0
    movw arena+DATA_OFFSET,%ax
.elseif LANE==1
    movw arena+DATA_OFFSET,%cx
.elseif LANE==2
    movw arena+DATA_OFFSET,%dx
.elseif LANE==3
    movw arena+DATA_OFFSET,%bx
.elseif LANE==4
    movw arena+DATA_OFFSET,%sp
.elseif LANE==5
    movw arena+DATA_OFFSET,%bp
.elseif LANE==6
    movw arena+DATA_OFFSET,%si
.else
    movw arena+DATA_OFFSET,%di
.endif
.else
.if LANE==0
    movl arena+DATA_OFFSET,%eax
.elseif LANE==1
    movl arena+DATA_OFFSET,%ecx
.elseif LANE==2
    movl arena+DATA_OFFSET,%edx
.elseif LANE==3
    movl arena+DATA_OFFSET,%ebx
.elseif LANE==4
    movl arena+DATA_OFFSET,%esp
.elseif LANE==5
    movl arena+DATA_OFFSET,%ebp
.elseif LANE==6
    movl arena+DATA_OFFSET,%esi
.else
    movl arena+DATA_OFFSET,%edi
.endif
.endif
.globl consumer
consumer:
.if MODE==2 || MODE==3
    setc %al
.elseif WIDTH==8
.if LANE==0
    movzbl %al,%eax
.elseif LANE==1
    movzbl %cl,%eax
.elseif LANE==2
    movzbl %dl,%eax
.elseif LANE==3
    movzbl %bl,%eax
.elseif LANE==4
    movzbl %ah,%eax
.elseif LANE==5
    movzbl %ch,%eax
.elseif LANE==6
    movzbl %dh,%eax
.else
    movzbl %bh,%eax
.endif
.elseif WIDTH==16
.if LANE==0
    movzwl %ax,%eax
.elseif LANE==1
    movzwl %cx,%eax
.elseif LANE==2
    movzwl %dx,%eax
.elseif LANE==3
    movzwl %bx,%eax
.elseif LANE==4
    movzwl %sp,%eax
.elseif LANE==5
    movzwl %bp,%eax
.elseif LANE==6
    movzwl %si,%eax
.else
    movzwl %di,%eax
.endif
.else
.if LANE==0
    movl %eax,%eax
.elseif LANE==1
    movl %ecx,%eax
.elseif LANE==2
    movl %edx,%eax
.elseif LANE==3
    movl %ebx,%eax
.elseif LANE==4
    movl %esp,%eax
.elseif LANE==5
    movl %ebp,%eax
.elseif LANE==6
    movl %esi,%eax
.else
    movl %edi,%eax
.endif
.endif
    adcl $0,%eax                    # consumes the MOV-preserved carry
    movl %eax,signature
    decl iterations
    jne loop_body
    movl original_esp,%esp
    movl $1,%eax
    movl $0,%ebx
.globl exit_syscall
exit_syscall:
    int $0x80
.data
original_esp:.long 0
signature:.long 0
iterations:.long 8
.balign 4096
arena:
.if DATA_OFFSET>0
    .space DATA_OFFSET
.endif
    .long VALUE
    .fill 8,4,0x76543210
.section .note.GNU-stack,"",@progbits
