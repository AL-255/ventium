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
    .long 0x90abcdef
    .long 0x50607080
.section .note.GNU-stack,"",@progbits
