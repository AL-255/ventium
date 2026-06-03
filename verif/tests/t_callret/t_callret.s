# =============================================================================
# Ventium M2 test: t_callret -- near CALL / RET, indirect CALL/JMP r/m
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Built like the M1 corpus:
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Goal (m2-isa-spec.md "Control / loop"): exercise the near call/return machinery
# and the indirect control-transfer encodings, checking the pushed return EIP,
# ESP arithmetic, and post-return register state against QEMU. NEAR only (no far
# CALL/RET — those are M2S). Covered:
#   CALL rel32 (E8 cd)              -- push next-EIP, jump relative
#   RET        (C3)                 -- pop EIP
#   RET imm16  (C2 iw)              -- pop EIP, then add imm16 to ESP (stdcall)
#   CALL r/m32 (FF /2)             -- indirect call through a register
#   JMP  r/m32 (FF /4)             -- indirect jump through a register/memory
#   (plus PUSH args / POP to mirror a simple cdecl-ish call sequence)
#
# All control flow is statically determined (deterministic), every target is
# in-image, and the stack stays balanced. No undefined flags are produced by
# CALL/RET/JMP, so NO EFLAGS mask is needed. The leaf functions only do integer
# adds so a wrong return address or unbalanced ESP corrupts a checked GPR.
# =============================================================================

    .text
    .globl  _start
_start:
    # ---- (1) CALL rel32 to a leaf that returns with plain RET (C3) ----------
    movl    $0x00000000, %eax       # accumulator = 0
    movl    $10, %ecx               # scratch reg (not consumed by the leaf)
    call    add_seven               # E8 rel32: push return EIP, jump
    # eax = 0 + 7 = 7 after return (add_seven adds 7 to eax)
    addl    $100, %eax              # eax = 107 (0x6b) — proves correct return

    # ---- (2) CALL rel32 to a function using RET imm16 (C2 iw, stdcall) ------
    # Push one dword argument, callee consumes it and cleans the stack via
    # `ret $4`. We snapshot ESP around the call to confirm it is balanced.
    movl    %esp, %edx              # edx = ESP before the call sequence
    pushl   $0x00000020             # arg = 32 on the stack
    call    add_arg_stdcall         # callee adds [esp+4] to eax, returns with ret $4
    # after `ret $4` ESP is back to edx (arg popped by the callee)
    cmpl    %esp, %edx              # ZF=1 iff ESP balanced
    je      .Lbalanced
    movl    $0xBAD00001, %eax       # sentinel: must NOT run if ESP balanced
.Lbalanced:
    # eax = 107 + 32 = 139 (0x8b)

    # ---- (3) indirect CALL r/m32 (FF /2) through a register -----------------
    leal    times_two, %ebx         # ebx = &times_two
    call    *%ebx                   # FF /2: indirect call; eax = eax*2 in callee
    # eax = 139 * 2 = 278 (0x116)

    # ---- (4) indirect JMP r/m32 (FF /4) through a register (computed goto) ---
    # Jump to one of two stubs; the taken stub increments eax and falls into the
    # common continuation. The not-taken stub poisons eax (must never run).
    leal    .Ljmp_ok, %ebx
    jmp     *%ebx                   # FF /4: indirect jump
    movl    $0xBAD00004, %eax       # must NOT run
.Ljmp_ok:
    incl    %eax                    # eax = 279 (0x117)

    # ---- (5) indirect JMP r/m32 (FF /4) through MEMORY ----------------------
    jmp     *jmp_target             # FF /4 mod=00 rm=101 disp32: [jmp_target]
    movl    $0xBAD00005, %eax       # must NOT run
.Lmem_ok:
    addl    $1, %eax                # eax = 280 (0x118)

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80                   # halt / syscall

    # =========================================================================
    # Leaf functions (near). Each ends in a near RET form.
    # =========================================================================
add_seven:
    addl    $7, %eax                # eax += 7
    ret                             # C3: pop EIP

add_arg_stdcall:
    # one dword argument at [esp+4] (esp+0 = return EIP). stdcall: callee pops it.
    movl    4(%esp), %ecx           # ecx = arg (32)
    addl    %ecx, %eax              # eax += arg
    ret     $4                      # C2 iw: pop EIP, then ESP += 4 (drop the arg)

times_two:
    addl    %eax, %eax              # eax *= 2
    ret                             # C3

    # =========================================================================
    # In-image data: an indirect JMP target table.
    # =========================================================================
    .data
    .align 4
jmp_target: .long .Lmem_ok          # absolute address of the continuation label
