# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M2 test: t_stack -- PUSH/POP family, PUSHF/POPF, LAHF/SAHF, LEAVE
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Built like the M1 corpus:
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Goal (m2-isa-spec.md "Stack / flags"): exercise the stack-engine encodings and
# the flags transfer ops, checking ESP arithmetic and the pushed/popped values
# against QEMU. Covered:
#   PUSH imm8  (6A ib, sign-extended to 32b)
#   PUSH imm32 (68 id)
#   PUSH r/m32 (FF /6)              -- both register and memory forms
#   POP  r/m32 (8F /0)              -- both register and memory forms
#   PUSH r32   (50+r) / POP r32 (58+r)  (baseline, used to set up/verify)
#   PUSHF (9C) / POPF (9D)          -- 32-bit flags image round-trip
#   LAHF (9F) / SAHF (9E)          -- AH<->low byte of EFLAGS
#   LEAVE (C9)                      -- mov esp,ebp ; pop ebp
#
# Flag hygiene: POPF only ever restores an image previously produced by PUSHF
# (so no TF/IF/IOPL surprises in user mode); SAHF loads a benign AH. PUSHF/POPF,
# LAHF/SAHF produce architecturally DEFINED results -> NO EFLAGS mask needed.
# All addresses are in-image; the stack lives at the loader-established ESP.
# =============================================================================

    .text
    .globl  _start
_start:
    # ---- baseline: seed registers -------------------------------------------
    movl    $0xAAAA0001, %eax
    movl    $0xBBBB0002, %ecx
    movl    $0xCCCC0003, %edx

    # ---- PUSH imm8 / imm32, then POP them back (LIFO order) ------------------
    pushl   $0x68000001             # 68 id (PUSH imm32)
    pushl   $0x7F                   # 6A ib (PUSH imm8, +ve, sign-ext -> 0x7F)
    pushl   $-2                     # 6A ib (PUSH imm8, -ve, sign-ext 0xFFFFFFFE)
    popl    %esi                    # esi = 0xFFFFFFFE
    popl    %edi                    # edi = 0x0000007F
    popl    %ebx                    # ebx = 0x68000001
    # ESP back to entry value

    # ---- PUSH r32 / POP r/m32 (register form, 8F /0) ------------------------
    pushl   %eax                    # [esp] = 0xAAAA0001 (50+r)
    popl    %ebp                    # 8F /0 (mod=11): ebp = 0xAAAA0001

    # ---- PUSH r/m32 (FF /6) register & memory forms -------------------------
    pushl   %ecx                    # FF /6 reg? gas emits 51 (PUSH r32) for reg
    .byte   0xFF, 0x35              # PUSH r/m32 (FF /6), mod=00 rm=101 disp32:
    .long   slot_a                  #   push the dword at [slot_a]
    popl    %edx                    # edx = mem[slot_a]
    popl    %ecx                    # ecx = 0xBBBB0002 (restore)

    # ---- POP r/m32 to MEMORY (8F /0, mod=00 rm=101 disp32) ------------------
    pushl   $0x5151AB00             # value to land in memory
    .byte   0x8F, 0x05              # POP r/m32 (8F /0) -> [slot_b]
    .long   slot_b                  #   mem[slot_b] = 0x5151AB00
    movl    slot_b, %edi            # edi = 0x5151AB00 (read it back)

    # ---- PUSHF / POPF round-trip --------------------------------------------
    movl    $5, %eax
    cmpl    $5, %eax                # ZF=1, CF=0
    pushfl                          # push EFLAGS image (9C)
    popl    %esi                    # esi = flags image (low byte has ZF=1)
    cmpl    $7, %eax                # 5-7: ZF=0, SF=1, CF=1 (different flags)
    pushfl                          # push the new flags
    popfl                           # POPF restores them (9D) — round-trip clean

    # ---- LAHF / SAHF ---------------------------------------------------------
    movl    $0xFFFFFFFF, %ebx
    addl    $1, %ebx                # 0xFFFFFFFF+1 -> 0, CF=1, ZF=1, PF=1, AF=1
    lahf                            # AH = low byte of EFLAGS (bit1 always set)
    movb    $0xD5, %ah              # benign image: SF ZF AF PF CF set, bit1 mbz
    sahf                            # SF=1,ZF=1,AF=1,PF=1,CF=1 (all defined)

    # ---- LEAVE: tear down a frame (mov esp,ebp ; pop ebp) -------------------
    # Build a tiny frame manually: save old ebp, set ebp=esp, push a local.
    pushl   %ebp                    # save caller ebp
    movl    %esp, %ebp              # ebp = frame pointer
    pushl   $0xF00DF00D             # one local on the stack (esp = ebp-4)
    leave                           # esp=ebp ; pop ebp  -> ebp restored, local gone

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80                   # halt / syscall

    # =========================================================================
    # In-image RW data.
    # =========================================================================
    .data
    .align 4
slot_a: .long 0x1234ABCD
slot_b: .long 0x00000000
