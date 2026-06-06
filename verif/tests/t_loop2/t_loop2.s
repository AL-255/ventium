# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M2 test: t_loop2 -- LOOP / LOOPE / LOOPNE and JECXZ
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Built like the M1 corpus:
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Goal (m2-isa-spec.md "Control / loop"): exercise the ECX-counted loop idioms
# and the JECXZ guard, near forms only. Covered:
#   LOOP   cb (E2): ECX-- (no flag change); jump if ECX != 0
#   LOOPE  cb (E1): ECX--;                  jump if ECX != 0 AND ZF == 1
#   LOOPNE cb (E0): ECX--;                  jump if ECX != 0 AND ZF == 0
#   JECXZ  cb (E3): jump if ECX == 0 (ECX NOT decremented; no flag change)
#
# IMPORTANT semantics encoded (so the core matches QEMU exactly):
#   * LOOP/LOOPE/LOOPNE decrement ECX and test the NEW ECX; they do NOT touch
#     EFLAGS themselves. LOOPE/LOOPNE read ZF as set by a PRIOR instruction.
#   * The decrement-then-test order means a loop entered with ECX=N runs the body
#     N times (ECX N..1), then ECX hits 0 and the back-edge is NOT taken.
#   * JECXZ tests ECX without modifying it.
# We keep all counts small & positive (no 0 -> 0xFFFFFFFF wrap), all targets are
# in-image rel8, and the loop bodies fold results into checked GPRs. No undefined
# flags are produced by LOOP/JECXZ, so NO EFLAGS mask is needed.
# =============================================================================

    .text
    .globl  _start
_start:
    # ---- (1) plain LOOP: sum 1..5 = 15 (0x0f) -------------------------------
    # Count DOWN with LOOP; accumulate ECX each pass. ECX runs 5,4,3,2,1 then
    # LOOP at ECX=1 decrements to 0 and falls through.
    xorl    %eax, %eax              # eax = sum = 0
    movl    $5, %ecx                # ECX = 5 (loop count)
.Lsum:
    addl    %ecx, %eax              # sum += ECX (LOOP must not disturb this CF/ZF)
    loop    .Lsum                   # E2: ECX--; jump back while ECX != 0
    # eax = 5+4+3+2+1 = 15 (0x0f); ECX = 0

    # ---- (2) LOOPE: continue WHILE equal, bounded by ECX --------------------
    # We pre-set ZF=1 with a cmp inside the body so LOOPE keeps looping until the
    # body breaks equality. Body: edx++ ; cmp edx,limit sets ZF when edx==limit.
    # Loop continues while (ECX != 0 AND ZF==1). We arrange equality to hold for
    # the first few passes, then break it, so LOOPE exits on ZF==0 before ECX=0.
    movl    $0, %edx                # edx = 0
    movl    $0, %ebx                # ebx = pass counter
    movl    $8, %ecx                # ECX cap = 8 (upper bound on passes)
.Le_loop:
    incl    %ebx                    # ebx++ (count passes)
    incl    %edx                    # edx = 1,2,3,...
    cmpl    $3, %edx                # ZF=1 while edx != 3? No: ZF=1 iff edx==3.
    loope   .Le_loop                # E1: ECX--; jump while ECX!=0 AND ZF==1
    # cmp sets ZF=0 for edx=1,2 -> LOOPE exits on the FIRST pass (ZF=0 after the
    # first cmp). So ebx=1, edx=1, ECX=7. This proves LOOPE reads ZF correctly:
    # it must NOT keep looping when ZF==0.

    # ---- (3) LOOPE that DOES iterate (ZF stays 1) ---------------------------
    # Keep ZF=1 every pass by comparing a constant to itself, so LOOPE loops
    # until ECX drains to 0. ESI counts the passes.
    movl    $0, %esi                # esi = pass counter
    movl    $4, %ecx                # ECX = 4
.Le_loop2:
    incl    %esi                    # esi++
    cmpl    %eax, %eax              # eax==eax -> ZF=1 every pass
    loope   .Le_loop2               # ECX--; jump while ECX!=0 AND ZF==1
    # ZF always 1 -> exits only when ECX hits 0. esi = 4, ECX = 0.

    # ---- (4) LOOPNE: continue WHILE not equal, bounded by ECX ---------------
    # Body increments edi until it equals a target; LOOPNE loops while ZF==0
    # (not equal) and ECX != 0, so it stops when edi reaches the target (ZF=1).
    movl    $0, %edi                # edi = 0 (search index)
    movl    $9, %ecx                # ECX cap = 9
.Lne_loop:
    incl    %edi                    # edi = 1,2,3,...
    cmpl    $3, %edi                # ZF=1 when edi == 3
    loopne  .Lne_loop               # E0: ECX--; jump while ECX!=0 AND ZF==0
    # edi reaches 3 on the 3rd pass -> ZF=1 -> LOOPNE stops. edi=3, ECX=6.

    # ---- (5) JECXZ taken (ECX == 0) ----------------------------------------
    xorl    %ecx, %ecx              # ECX = 0
    jecxz   .Lecx_zero              # E3: jump because ECX == 0
    movl    $0xBAD00005, %ebx       # sentinel: must NOT run
.Lecx_zero:
    movl    $0x600D0005, %ebx       # marker: JECXZ-taken path

    # ---- (6) JECXZ NOT taken (ECX != 0) -> guard a LOOP that runs once ------
    movl    $1, %ecx                # ECX = 1 (nonzero)
    jecxz   .Lskip_loop             # NOT taken (ECX != 0) -> fall through
    movl    $0x600D0006, %ebp       # runs: JECXZ-not-taken path
.Linner:
    decl    %ebp                    # body
    loop    .Linner                 # ECX=1 -> dec to 0 -> not taken; body ran once
    jmp     .Lafter
.Lskip_loop:
    movl    $0xBAD00006, %ebp       # sentinel: must NOT run
.Lafter:

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80                   # halt / syscall
