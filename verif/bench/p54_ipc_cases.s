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
.if CASE == 53
    # A dword destination straddles two mapped pages; early command issue is
    # forbidden until the second page's write permission probe completes.
    movl $arena+4094, %edi
.else
    movl $arena+32, %edi
.endif
    movl $ITERATIONS, %ecx
    xorl %eax, %eax
    xorl %ebx, %ebx
    xorl %edx, %edx
.if CASE >= 75 && CASE <= 83
    # Exercise signed overflow and low-word writes after multiplier sharing.
    movl $0x70010081, %eax
.endif
.if CASE >= 84 && CASE <= 86
    # Keep the complete PUSH/POP transaction in mapped ordinary RAM in both
    # the standalone RTL memory model and QEMU's user-mode ELF mapping.
    movl $arena+256, %esp
.endif
.if CASE == 7 || CASE == 8 || (CASE >= 84 && CASE <= 86)
    # ST0=1, ST1=0. FADD ST1 is an exact no-op with a real FP dependency.
    fldz
    fld1
.endif
.if CASE == 51
    # Keep one fractional x87 source live across the non-pop FIST loop.
    flds (%esi)
.endif
.if CASE == 25
    # The first loop entry must have the same not-taken ZF as later entries.
    testl %ecx, %ecx
.endif
.if CASE == 46 || CASE == 47
    # Populate both read windows before measuring the loop. The second line
    # remains in the shadow while the first is the registered primary.
    movl 32(%esi), %ebx
    movl (%esi), %edi
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
.elseif CASE == 31
    # Three same-set lines exceed the 2-way P5 L1D, so the third source
    # starts a fill each iteration. The final load is a resident different-
    # set line: hit-under-fill should serve it while the tail drains.
    movl (%esi), %eax
    movl 4096(%esi), %edx
    movl 8192(%esi), %eax
    movl (%edi), %edx
.elseif CASE == 32
    # Same three-line thrash, but consume the just-returned line's next word
    # before starting the second miss. This isolates landed-word forwarding.
    movl (%esi), %eax
    movl 4(%esi), %ebx
    movl 4096(%esi), %edx
    movl 8192(%esi), %eax
.elseif CASE == 33
    # The load's backing word changes after each iteration. A branch-target
    # V pre-read must see the preceding ordered store, not a held old result.
    movl %ebx, %eax
    movl (%esi), %edx
    movl %eax, (%esi)
.elseif CASE == 34
    # LEA and JNZ may pair in the preceding issue group, but LEA changes the
    # next V load's address. Pre-reading from the pre-LEA ESI is forbidden.
    movl %ebx, %eax
    movl (%esi), %edx
    decl %ecx
    leal 32(%esi), %esi
    jnz loop_body
.elseif CASE == 35
    # Model the recurrent game shape without depending on game addresses:
    # integer-to-x87 load, x87 integer store/pop, then independent integer
    # work. The result is consumed after the loop so stores are observable.
    fildl (%esi)
    fistpl (%edi)
    incl %eax
    incl %ebx
.elseif CASE == 36
    # A and B are resident; a write to independent line C must not discard
    # A's shadow read window. The final read observes any saved capture clock.
    movl (%esi), %eax
    movl 32(%esi), %edx
    movl %ebx, 64(%esi)
    movl (%esi), %eax
.elseif CASE == 37
    # Independent byte loads touch distinct 32-bit data banks (0 and 1).
    .rept 8
    movb (%esi), %al
    movb 4(%esi), %dl
    .endr
.elseif CASE == 38
    # Same-bank byte loads must keep V behind U, even at different byte lanes.
    .rept 8
    movb (%esi), %al
    movb 1(%esi), %dl
    .endr
.elseif CASE == 39
    # V's last byte in a resident line needs bank 7 only; it neither crosses
    # the line nor reads the undefined bytes beyond it.
    .rept 8
    movl (%esi), %eax
    movb 31(%esi), %dl
    .endr
.elseif CASE == 40
    # High-byte register writes must merge against the correct parent GPRs.
    .rept 8
    movb (%esi), %ah
    movb 7(%esi), %dh
    .endr
.elseif CASE == 41
    # Same registered line serves two independent aligned dword MOV loads.
    .rept 8
    movl (%esi), %eax
    movl 4(%esi), %edx
    .endr
.elseif CASE == 42
    # Identical-word U/V loads still conflict in the P54's physical bank.
    .rept 8
    movl (%esi), %eax
    movl (%esi), %edx
    .endr
.elseif CASE == 43
    # V's aligned final dword is wholly inside the resident line.
    .rept 8
    movl (%esi), %eax
    movl 28(%esi), %edx
    .endr
.elseif CASE == 44
    # Prime two resident line windows, then pair independent byte MOVs from
    # distinct physical banks in those different lines (2 and 1).
    movl 32(%esi), %ebx
    movl (%esi), %edi
    movb 8(%esi), %al
    movb 36(%esi), %dl
.elseif CASE == 45
    # The same two windows, but both final loads use bank 1. A saved window
    # must not bypass the P54 bank restriction.
    movl 32(%esi), %ebx
    movl (%esi), %edi
    movb 4(%esi), %al
    movb 36(%esi), %dl
.elseif CASE == 46
    movb 8(%esi), %al
    movb 36(%esi), %dl
.elseif CASE == 47
    movb 4(%esi), %al
    movb 36(%esi), %dl
.elseif CASE == 48
    # P54 immediate register ROR is a one-clock U operation and may lead
    # an independent integer V instruction. This is a generic throughput
    # witness, not a workload-address-specific shortcut.
    rorl $16, %eax
    incl %ebx
    incl %edx
.elseif CASE == 49
    # Effective counts 0/1/0/1 exercise CF/OF preservation and count masking
    # through the same fast decode that CASE 48 measures.
    rorl $0, %eax
    rorl $1, %eax
    rorl $32, %eax
    rorl $33, %eax
.elseif CASE == 50
    # Fractional conversion, pop, store visibility, and independent integer
    # work.  The result is read back on every iteration, not merely at exit.
    flds (%esi)
    fistpl (%edi)
    movl (%edi), %edx
    incl %eax
.elseif CASE == 51
    # Same probed m32 destination with non-pop FIST; TOP/tag must remain live.
    fistl (%edi)
    movl (%edi), %edx
    incl %eax
    incl %ebx
.elseif CASE == 52
    # Masked empty-stack store emits the integer indefinite and retains the
    # same ordered destination-store ownership as an ordinary conversion.
    fistpl (%edi)
    movl (%edi), %edx
    incl %eax
    incl %ebx
.elseif CASE == 53
    fildl (%esi)
    fistpl (%edi)
    movl (%edi), %edx
    incl %eax
.elseif CASE == 54
mixed_u:
    movl (%esi), %eax
mixed_v:
    movl %edx, 36(%esi)
.elseif CASE == 55
mixed_u:
    movl (%esi), %eax
mixed_v:
    movl %edx, 32(%esi)
.elseif CASE == 56
    # V consumes U's loaded EAX and must not pair despite distinct banks.
mixed_u:
    movl (%esi), %eax
mixed_v:
    movl %eax, 36(%esi)
.elseif CASE == 57
    # Same resident line, distinct word banks: U must observe the old bank-0
    # value while V updates bank 1 and posts the write exactly once.
mixed_u:
    movl (%esi), %eax
mixed_v:
    movl %edx, 4(%esi)
.elseif CASE == 58 || CASE == 59
    # Nonpairable integer multiply leaves enough service time for the two
    # physical write-buffer slots. This isolates issue-group savings from a
    # saturated write-through backend, with equal work in both bank controls.
mixed_u:
    movl (%esi), %eax
mixed_v:
.if CASE == 58
    movl %edx, 36(%esi)
.else
    movl %edx, 32(%esi)
.endif
    imull %ebx, %ebx
.elseif CASE == 60 || CASE == 61 || CASE == 62
    # Ordered U store followed by a V load. CASE 60 is independent and
    # distinct-bank; CASE 61 conflicts in bank 0 without aliasing; CASE 62
    # aliases the U address and must read the newly stored value. Keep the
    # same fixed-work IMUL spacer as the reverse-direction pair cases.
mixed_u:
    movl %edx, (%esi)
mixed_v:
.if CASE == 60
    movl 36(%esi), %eax
.elseif CASE == 61
    movl 32(%esi), %eax
.else
    movl (%esi), %eax
.endif
    imull %ebx, %ebx
.elseif CASE == 63 || CASE == 64 || CASE == 65
    # Register exchange is NP/two clocks on P54. Two exchanges restore both
    # registers so the loop count and final architectural state stay stable;
    # the variant changes only which real GPR pair is exercised.
.if CASE == 63
    xchgl %eax, %edi
    xchgl %eax, %edi
.elseif CASE == 64
    xchgl %eax, %ecx
    xchgl %eax, %ecx
.else
    # ESP is a second architectural destination, not just an AGU input.
    # Keep the stack invalid only between two adjacent atomic exchanges.
    xchgl %eax, %esp
    xchgl %eax, %esp
.endif
    incl %ebx
.elseif CASE == 66 || CASE == 67
    # Observed gameplay class: an ADC register/memory U followed by an
    # independent ADD register/memory V. V overwrites flags in program order;
    # only the source-bank placement differs between these two fixtures.
    adcl (%esi), %eax
.if CASE == 66
    addl 36(%esi), %edx
.else
    addl 32(%esi), %edx
.endif
    incl %ebx
.elseif CASE == 68 || CASE == 69 || CASE == 70
    # Isolate the ordered store/read pair without the longer IMUL spacer in
    # cases 60-62. An unrelated INC leaves a five-instruction fixed-work loop.
    movl %edx, (%esi)
.if CASE == 68
    movl 36(%esi), %eax
.elseif CASE == 69
    movl 32(%esi), %eax
.else
    movl (%esi), %eax
.endif
    incl %ebx
.elseif CASE == 71 || CASE == 72 || CASE == 73 || CASE == 74
    # Four read-only EXT flavors, all from a negative byte/word in resident
    # ordinary RAM. The dependent ADD checks the extended 32-bit result, not
    # merely the low source byte/word; V pairing must remain disabled (NP).
.if CASE == 71
    movzbl 32(%esi), %eax
.elseif CASE == 72
    movzwl 32(%esi), %eax
.elseif CASE == 73
    movsbl 32(%esi), %eax
.else
    movswl 32(%esi), %eax
.endif
    addl %eax, %edx
    incl %ebx
.elseif CASE == 75
    imull %edi, %eax
    incl %ebx
.elseif CASE == 76
    imull (%esi), %eax
    incl %ebx
.elseif CASE == 77
    imulw %di, %ax
    incl %ebx
.elseif CASE == 78
    imulw (%esi), %ax
    incl %ebx
.elseif CASE == 79
    imull $-7, %eax, %ebx
    incl %edx
.elseif CASE == 80
    imulw $-7, %ax, %bx
    incl %edx
.elseif CASE == 81
    imull %edi
    incl %ebx
.elseif CASE == 82
    imulw %di
    incl %ebx
.elseif CASE == 83
    imulb (%esi)
    incl %ebx
.elseif CASE == 84
    # A masked outstanding x87 add is independent of an integer SS stack
    # transaction. The popped value must equal the prior EAX on every loop.
    fadd %st(1), %st(0)
    pushl %eax
    popl %edi
    incl %ebx
.elseif CASE == 85
    # PUSH ESP stores the pre-decrement value; POP must restore that exact
    # value while the older FP owner is still in flight.
    fadd %st(1), %st(0)
    pushl %esp
    popl %edi
    incl %ebx
.elseif CASE == 86
    # POP into the same GPR read by PUSH exercises the writeback boundary.
    fadd %st(1), %st(0)
    pushl %eax
    popl %eax
    incl %ebx
.else
    .error "unsupported CASE"
.endif
.if CASE != 34
    decl %ecx
    jnz loop_body
.endif
.globl loop_end
loop_end:
.if CASE == 35
    movl (%edi), %edx
.elseif CASE == 54 || CASE == 56
    movl 36(%esi), %ebx
.elseif CASE == 55
    movl 32(%esi), %ebx
.elseif CASE == 57
    movl 4(%esi), %ebx
.elseif CASE == 58
    movl 36(%esi), %ebx
.elseif CASE == 59
    movl 32(%esi), %ebx
.elseif CASE == 60 || CASE == 61 || CASE == 62
    movl (%esi), %edx
.endif
    movl $1, %eax
    xorl %ebx, %ebx
.globl exit_syscall
exit_syscall:
    int $0x80
.data
.balign 32
.globl arena
arena:
.if CASE == 50 || CASE == 51
    .long 0x3fc00000
.else
    .long 0x10203040
.endif
    .space 28
.if CASE == 27
    .long 1
.else
    .long 0x90abcdef
.endif
    .long 0x50607080
.if CASE == 31 || CASE == 32
    .space 8192
.elseif CASE == 34
    # The directed runner permits up to 10,000 iterations of +32-byte ESI.
    .space 327680
.elseif CASE == 53
    .space 8192
.elseif CASE >= 84 && CASE <= 86
    .space 512
.endif
.section .note.GNU-stack,"",@progbits
