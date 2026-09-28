# Bounded fixed-work P54 resource microbenchmarks. Assemble with --defsym CASE=N.
# These are diagnostic workloads, not gameplay or an architectural oracle.
.ifndef CASE
.set CASE, 1
.endif
.ifndef ITERATIONS
.set ITERATIONS, 1000
.endif
.text
.globl _start
_start:
    movl $arena, %esi
    movl $arena+32, %edi
    movl $ITERATIONS, %ecx
    xorl %eax, %eax
    xorl %ebx, %ebx
    xorl %edx, %edx
.if CASE == 7 || CASE == 8
    # ST0=1, ST1=0. FADD ST1 is an exact no-op with a real FP dependency.
    fldz
    fld1
.endif
.if CASE == 25
    # The first loop entry must have the same not-taken ZF as later entries.
    testl %ecx, %ecx
.endif
    jmp loop_body
.if CASE == 9
    .balign 32
.elseif CASE == 10
    .balign 32
    .space 31, 0x90
.else
    .balign 32
.endif
.globl loop_body
loop_body:
.if CASE == 1
    # Two legal independent loads, distinct banks (0,1), different lines.
    # Both bank variants change line, so registered same-line reuse is not a
    # false witness for dual-ported service.
    movl (%esi), %eax
    movl 36(%esi), %edx
.elseif CASE == 2
    # Same instructions but both addresses use bank 0 (different lines).
    movl (%esi), %eax
    movl 32(%esi), %edx
.elseif CASE == 3
    # Two independent stores to distinct banks and different lines.
    movl %eax, (%esi)
    movl %edx, 36(%esi)
.elseif CASE == 4
    # Same-bank store pair, with otherwise identical instruction count.
    movl %eax, (%esi)
    movl %edx, 32(%esi)
.elseif CASE == 5
    # Resident ALU-memory forms must retain their execution occupancy.
    addl (%esi), %eax
    addl 4(%esi), %edx
.elseif CASE == 6
    # Register-only control for CASE 5; same arithmetic dependencies.
    addl %ebx, %eax
    addl %edi, %edx
.elseif CASE == 7
    # FP can overlap these independent integer instructions.
    fadd %st(1), %st(0)
    incl %eax
    incl %ebx
    incl %edx
.elseif CASE == 8
    # Integer-only control with a nonpairable leading EAX dependency. This
    # matches the FP case's extra U issue group instead of letting NOP pair.
    incl %eax
    incl %eax
    incl %ebx
    incl %edx
.elseif CASE == 9 || CASE == 10
    # Identical hot bytes, with the first instruction aligned or straddling
    # a 32-byte I-cache line. This exposes persistent-uop-cache fallback cost.
    addl $1, %eax
    incl %ebx
.elseif CASE == 11
    # Two independent dword loads from one resident line. Reuse may serve
    # the second without another registered 256-bit-line capture.
    movl (%esi), %eax
    movl 4(%esi), %edx
.elseif CASE == 12
    # Same instruction classes but a second physical line is required.
    movl (%esi), %eax
    movl 32(%esi), %edx
.elseif CASE == 13
    # A register U followed by an independent memory V. This distinguishes
    # V-memory admission from a U-only load path even when only one bank fires.
    movl %ebx, %eax
    movl (%esi), %edx
.elseif CASE == 14
    # Reverse order of CASE 13: U load and independent V register operation.
    movl (%esi), %eax
    movl %ebx, %edx
.elseif CASE == 15
    # A resident read/modify ALU operand followed by independent integer work.
    # The arithmetic's EX occupancy may not be collapsed by cache-window reuse.
    addl (%esi), %eax
    incl %edx
.elseif CASE == 16
    orl (%esi), %eax
    orl 4(%esi), %edx
.elseif CASE == 17
    adcl (%esi), %eax
    adcl 4(%esi), %edx
.elseif CASE == 18
    sbbl (%esi), %eax
    sbbl 4(%esi), %edx
.elseif CASE == 19
    andl (%esi), %eax
    andl 4(%esi), %edx
.elseif CASE == 20
    subl (%esi), %eax
    subl 4(%esi), %edx
.elseif CASE == 21
    xorl (%esi), %eax
    xorl 4(%esi), %edx
.elseif CASE == 22
    # The last data read is from a different line than the branch target's
    # first read. A dependent register op after the target load gives the
    # ordinary next-load lookahead an independent edge; a branch-target prime
    # must save its own capture clock, not merely move it to the second load.
    movl (%esi), %eax
    addl %ebx, %edi
    movl %eax, %ebx
    movl 32(%esi), %edx
.elseif CASE == 23
    # A dependent register consumer prevents each load from pairing with it.
    # The final DEC/JNZ can then form a V-branch pair, whose target is the
    # resident load in the other data line. Both branches use the same general
    # prediction/actual-outcome ownership rule.
    movl (%esi), %eax
    movl %eax, %ebx
    movl 32(%esi), %edx
    movl %edx, %edi
.elseif CASE == 24
    # The first load uses a different data line and cannot pair with the
    # following WAW XOR. XOR/JNZ then forms a V conditional branch, always
    # predicted/resolved not taken, ahead of the fall-through resident load.
    movl 32(%esi), %eax
    xorl %eax, %eax
    jnz 1f
    movl (%esi), %edi
1:
.elseif CASE == 25
    # The first JZ is U and always not taken: startup TEST and each loop's
    # nonterminal DEC leave ZF clear. This is the U fall-through counterpart.
    jz 1f
    movl (%esi), %eax
    movl %eax, %ebx
    movl 32(%esi), %edx
1:
.elseif CASE == 26
    # U JC predicts fall-through through the warm loop, then resolves taken
    # on the terminal iteration. CMP sets CF when ECX=2; DEC/JNZ preserve CF,
    # so only the next/final loop entry skips the candidate load.
    jc 1f
    movl (%esi), %eax
    movl 32(%esi), %edx
    cmpl $3, %ecx
1:
.elseif CASE == 27
    # CMP consumes the first load, so CMP/JE forms a V branch. The alternate
    # arena word is one; only the terminal iteration takes JE.
    movl 32(%esi), %eax
    cmpl %eax, %ecx
    je 1f
    movl (%esi), %edx
1:
.elseif CASE == 28
    # A preceding ordered store leaves no register/branch load-prime slot.
    # The following two resident MOV loads must share a fresh U capture edge
    # using separate banks; this isolates the core V-owner path from priming.
    movl %ebx, (%esi)
    movl (%esi), %eax
    movl 36(%esi), %edx
.elseif CASE == 29
    # Identical issue opportunity, but the two physical word indices are
    # bank 0 in different lines. V must be rejected and retry as U.
    movl %ebx, (%esi)
    movl (%esi), %eax
    movl 32(%esi), %edx
.elseif CASE == 30
    # A dword at byte 30 uses bank 7 of this line and bank 0 of the next.
    # Return immediately to bank 0 of the first line, then read bank 0 of
    # the next line. This exposes any false complete-window reuse after the
    # shared-bank0 crossing capture and measures its one-clock tradeoff.
    movl 30(%esi), %eax
    movl (%esi), %edx
    movl 32(%esi), %edi
.else
    .error "unsupported CASE"
.endif
    decl %ecx
    jnz loop_body
.globl loop_end
loop_end:
    movl $1, %eax
    xorl %ebx, %ebx
.globl exit_syscall
exit_syscall:
    int $0x80
.data
.balign 32
.globl arena
arena:
    .long 0x10203040
    .space 28
.if CASE == 27
    .long 1
.else
    .long 0x90abcdef
.endif
    .long 0x50607080
.section .note.GNU-stack,"",@progbits
