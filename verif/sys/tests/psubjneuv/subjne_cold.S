/* Directed cold-fault layout, NOT a guest patch or saved-state replay.
 * Original53 bytes; guest initializes ordinary mappings/data/GPRs.
 * 16 self-checks, original subject19-19 and later minute52-58 comparison.
 * v0 plain, v1 D-cache pressure, v2 I-cache pressure, v3 both.
 */
.ifndef SUB_VARIANT
.set SUB_VARIANT,0
.endif
.code32
.section .sub32,"ax"
.global sub_client,sub_chain,sub_subject,sub_jne,sub_taken,sub_zero
sub_client:
    movw $0xaf,%ax
    movw %ax,%ds
    movw %ax,%es
    movl $0,0x59f00
    movl $0,0x59f04
    movl $0,0x59f08
    movl $0,0x59f0c
    movl $0x12121212,0x1af24
    movl $0x34343434,0x1af50
    movl $0x56565656,0x1bf24
    movl $0x78787878,0x1bf50
.Lcase:
    movl $0xfaef0,%esp
    movl $0xfaf74,%ebp
    movl $0x7e,-0x44(%ebp)
    movl $0x7e,-0x18(%ebp)
    movl $6,-0x48(%ebp)
    movl $6,-0x1c(%ebp)
    movl $1,-0x4c(%ebp)
    movl $1,-0x20(%ebp)
    movl $0x13,-0x50(%ebp)
    movl $0x13,-0x24(%ebp)
    movl $0x34,-0x54(%ebp)
    movl $0x3a,-0x28(%ebp)
    movl $0x21,-0x58(%ebp)
    movl $0,-0x2c(%ebp)
    movl $0xc,-0x68(%ebp)
    movl $0x7e,(%esp)
    .if SUB_VARIANT == 1 || SUB_VARIANT == 3
    /* Other physical tags in the same D-cache sets as both SUB operands. */
    movl 0x1af24,%edx
    movl 0x1bf24,%edx
    movl 0x1af50,%edx
    movl 0x1bf50,%edx
    .endif
    .if SUB_VARIANT == 2 || SUB_VARIANT == 3
    /* Two other physical/linear tags congruent with the subject I-line. */
    movl $0x35680,%edx
    call *%edx
    movl $0x37680,%edx
    call *%edx
    .endif
    /* IOPL3 comes from the CPL0 IRET; no TF/RF or debug registers. */
    pushl $0x3202
    popfl
    movl $0x7ec,%eax
    movl $0,%edx
    movl $0x51eb851f,%esi
    movl $0x59948,%edi
    jmp sub_chain
    .org 0x662,0x90
sub_chain:
    .byte 0x8b,0x5d,0xbc,0x2b,0x5d,0xe8,0x8b,0x4d,0x98,0x75,0x26
    .byte 0x8b,0x5d,0xb8,0x2b,0x5d,0xe4,0x75,0x1e
    .byte 0x8b,0x5d,0xb4,0x2b,0x5d,0xe0,0x75,0x16
    .byte 0x8b,0x5d,0xb0
sub_subject:
    .byte 0x2b,0x5d,0xdc
sub_jne:
    .byte 0x75,0x0e
    .byte 0x8b,0x5d,0xac,0x2b,0x5d,0xd8,0x75,0x06
    .byte 0x8b,0x5d,0xa8,0x2b,0x5d,0xd4,0x85,0xdb,0x74,0x31
sub_taken:
    jmp .Lverify
    .org 0x6c8,0x90
sub_zero:
    jmp .Lbad
    .org 0x800,0x90
.Lverify:
    cmpl $0xfffffffA,%ebx
    jne .Lbad
    cmpl $0xfaef0,%esp
    jne .Lbad
    cmpl $0xfaf74,%ebp
    jne .Lbad
    cmpl $0xc,%ecx
    jne .Lbad
    cmpl $0x7ec,%eax
    jne .Lbad
    testl %edx,%edx
    jne .Lbad
    cmpl $0x51eb851f,%esi
    jne .Lbad
    cmpl $0x59948,%edi
    jne .Lbad
    incl 0x59f00
    incl 0x59f04
    cmpl $16,0x59f00
    jb .Lcase
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
    ret
    .org 4096,0x90
