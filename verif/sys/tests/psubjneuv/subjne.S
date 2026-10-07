/* Exact 59662..59697 memory-SUB/JNE chain from the captured executable.
 * Synthetic CPL3 fixture only. Production Quake/BIOS are not patched.
 * All acceptance runs require --cycle plus the frozen UV/fast define set.
 */
.ifndef SUB_VARIANT
.set SUB_VARIANT,0
.endif
.set CBASE,0x59000
.code32
.section .sub32,"ax"
.global sub_client, sub_subject, sub_wrong_boundary, sub_jne, sub_taken, sub_zero
sub_client:
    movw $0xaf,%ax
    movw %ax,%ds
    movw %ax,%es
    movl $0,0x59f00
    movl $0,0x59f04
    movl $0,0x59f08
    movl $0,0x59f0c
.Lcase:
    movl $0xe07f8,%esp
    movl $0xe0f00,%ebp
    movl 0x59f00,%eax
    andl $3,%eax
    movl %eax,0x59f10
    /* First three and last two comparisons equal. Fourth is 1-1,1-1,
     * 80000000-1, or 0-80000000: NT,NT,T,T with both overflow signs. */
    movl $0x11,-0x44(%ebp)
    movl $0x11,-0x18(%ebp)
    movl $0x22,-0x48(%ebp)
    movl $0x22,-0x1c(%ebp)
    movl $0x33,-0x4c(%ebp)
    movl $0x33,-0x20(%ebp)
    movl $0x55,-0x54(%ebp)
    movl $0x55,-0x28(%ebp)
    movl $0x66,-0x58(%ebp)
    movl $0x66,-0x2c(%ebp)
    movl $0x108,-0x68(%ebp)
    movl $1,-0x50(%ebp)
    movl $1,-0x24(%ebp)
    cmpl $2,%eax
    jb .Lprepared
    movl $0x80000000,-0x50(%ebp)
    je .Lprepared
    movl $0,-0x50(%ebp)
    movl $0x80000000,-0x24(%ebp)
.Lprepared:
    .if SUB_VARIANT == 1
    /* Read-after-write adjacency, preserving the data/truth schedule. */
    movl -0x24(%ebp),%edx
    movl %edx,-0x24(%ebp)
    .endif
    .if SUB_VARIANT == 2
    /* Execute a congruent cache line without writing code. */
    xorl %eax,%eax
    movl $0x35680,%edx
    call *%edx
    cmpl $0x3555,%eax
    jne .Lbad
    .endif
    .if SUB_VARIANT == 3
    /* Reproduce the immediately preceding indirect-call / ADD ESP shape. */
    pushl $0
    pushl $0
    pushl $0
    movl $0x356a0,%edi
    jmp sub_callback_call
    .else
    jmp sub_chain
    .endif
    .org 0x65d,0x90
.global sub_callback_call, sub_chain
sub_callback_call:
    call *%edi
    addl $0x0c,%esp
sub_chain:
    /* Bytes below are copied literally, verified against QUAKE.EXE. */
    .byte 0x8b,0x5d,0xbc,0x2b,0x5d,0xe8,0x8b,0x4d,0x98,0x75,0x26
    .byte 0x8b,0x5d,0xb8,0x2b,0x5d,0xe4,0x75,0x1e
    .byte 0x8b,0x5d,0xb4,0x2b,0x5d,0xe0,0x75,0x16
    .byte 0x8b,0x5d,0xb0
sub_subject:
    .byte 0x2b,0x5d
sub_wrong_boundary:
    .byte 0xdc
sub_jne:
    .byte 0x75,0x0e
    .byte 0x8b,0x5d,0xac,0x2b,0x5d,0xd8,0x75,0x06
    .byte 0x8b,0x5d,0xa8,0x2b,0x5d,0xd4,0x85,0xdb,0x74,0x31
sub_taken:
    movl $1,%eax
    jmp .Lverify
    .org 0x6c8,0x90
sub_zero:
    xorl %eax,%eax
    jmp .Lverify
    .org 0x800,0x90
.Lverify:
    cmpl $0xe07f8,%esp
    jne .Lbad
    cmpl $0xe0f00,%ebp
    jne .Lbad
    cmpl $0x108,%ecx
    jne .Lbad
    movl 0x59f10,%edx
    cmpl $2,%edx
    jb .Lequal
    cmpl $1,%eax
    jne .Lbad
    cmpl $2,%edx
    jne .Lnegative
    cmpl $0x7fffffff,%ebx
    jne .Lbad
    jmp .Lchecked
.Lnegative:
    cmpl $0x80000000,%ebx
    jne .Lbad
    jmp .Lchecked
.Lequal:
    testl %eax,%eax
    jne .Lbad
    testl %ebx,%ebx
    jne .Lbad
.Lchecked:
    addl %eax,0x59f04
    incl 0x59f00
    cmpl $64,0x59f00
    jb .Lcase
    cmpl $32,0x59f04
    jne .Lbad
    movl $0x5355424a,0x59f08
    movl $0x42,%eax
    int $0x80
.Lbad:
    movl $0xbad,0x59f0c
    movl $0xee,%eax
    int $0x80
    ud2
    .org 4096,0x90
.section .subwarm32,"ax"
.global sub_warm_page
sub_warm_page:
    .org 0x680,0x90
    addl $0x3555,%eax
    ret
    .org 0x6a0,0x90
    ret
    .org 4096,0x90
