// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Focused full-core/QEMU fixture: paid D1 then legal PU register execution.
// CASE0 independent word SHR+dword AND;1CMP16+Jcc;2RAW;3WAW;4ADC+INC;
// 5word MOV upper-half preservation;6prefixed V rejected;7memory stays slow;
// 8PC above64K and low16 carry;9duplicate prefix stays slow;10actual own SMC.
// 11 explicit word-SP/full-ESP WAW is forbidden, not an implicit stack pair.
.ifndef CASE
.set CASE,0
.endif
.ifndef LOOP_PAD
.set LOOP_PAD,0
.endif
.text
.globl _start
_start:
    movl $0xdeadf001,%eax
    movl $0x123400ff,%ebx
    movl $0xbad2ff01,%ecx
    movl $1,%edx
    movl $arena,%esi
    movl $0x56780000,%ebp
    movl $1000,%edi
    jmp loop_body
.if CASE==8
    .org 0x7ffe                 # entry08048000 => word opcode0804fffe
.else
    .balign 32
    .fill LOOP_PAD,1,0x90
.endif
.globl loop_body
loop_body:
.if CASE==10
    testl $1,%edi
    jz smc_right
    movb $0xe0,tested_op+2       # SHL AX,1, self-modifying real store
    jmp smc_done
smc_right:
    movb $0xe8,tested_op+2       # SHR AX,1
smc_done:
.endif
.globl tested_op
tested_op:
.if CASE==11
    movw $0x1234,%sp
    movl $0x98765432,%esp        # explicit ESP WAW must serialize
.elseif CASE==1
    cmpw %dx,%di
    jne follower_end
    nop
.elseif CASE==2
    addw %dx,%ax
    movl %eax,%ecx               # RAW must serialize
.elseif CASE==3
    movw $0x1234,%ax
    movl $0x98765432,%eax        # WAW must serialize
.elseif CASE==4
    adcw $0,%si
    incl %ebp                   # legal independent V preserves new CF
.elseif CASE==5
    movw $0x8001,%bx
    xorl %edx,%edx
.elseif CASE==6
    addw %dx,%ax
    subw %dx,%cx                # prefixed follower cannot fill V
.elseif CASE==7
    movw arena,%ax              # memory is not new prefix register path
    andl $1,%edx
.elseif CASE==9
    .byte 0x66
    shrw $1,%ax                 # duplicate prefix retains reference decoder
    andl $1,%edx
.else
    shrw $1,%ax                 # CASE10 modifies this ModR/M byte
    andl $1,%edx
.endif
.globl follower_end
follower_end:
    decl %edi
    jne loop_body
    movl $1,%eax
    movl $0,%ebx
.globl exit_syscall
exit_syscall:
    int $0x80
.data
.balign 16
arena:
    .long 0x734f8001
