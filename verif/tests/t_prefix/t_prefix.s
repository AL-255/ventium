# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Ventium M2 test: t_prefix  --  segment overrides + LOCK as functional no-ops
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build:
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000 \
#       -o t_prefix.elf t_prefix.s
#
# Goal: prove that the prefix machine (docs/m2-isa-spec.md "Operand sizes &
# prefixes") DECODES and SKIPS the segment-override prefixes
#   2E(cs) 36(ss) 3E(ds) 26(es) 64(fs) 65(gs)
# and the LOCK prefix F0, treating them as FUNCTIONAL NO-OPS on a normal memory
# access in the flat user model (all segment bases = 0; FS/GS base = 0 here).
#
# Method: every memory access is performed TWICE — once unprefixed and once
# through an explicit segment override (or LOCK) to the SAME address — and the
# two results are folded together (sub / cmp) so that if a prefix changed the
# effective address or perturbed the operation, a checked GPR diverges from the
# QEMU golden.  We also stack a segment override TOGETHER WITH the 0x66
# operand-size prefix (multiple prefixes) to exercise the prefix loop.
#
# Uses: mov r/m32,r32 / r32,r/m32 with %cs:/%ss:/%ds:/%es:/%fs:/%gs: overrides,
#   lock add/lock xor/lock inc to memory, 0x66+override stacked, add/sub/cmp.
# All accesses target our own RW .data page; no faulting, deterministic.
# =============================================================================

    .text
    .globl  _start
_start:
    # ---- seed a base pointer to the data area + constants -------------------
    leal    buf, %ebx               # ebx = &buf  (base for indirect accesses)
    movl    $0x12345678, %eax       # eax = test value
    movl    $0xCAFEBABE, %ecx       # ecx = second test value

    # ---- store via plain access, reload via DS override (same addr) ---------
    movl    %eax, (%ebx)            # buf[0] = 0x12345678  (no prefix)
    # GNU as elides a redundant DS (3E) override, so force the raw prefix byte
    # in front of a plain "mov (%ebx),%esi" (8b 33) to actually exercise 3E.
    .byte   0x3e                    # DS segment-override prefix
    movl    (%ebx), %esi            # esi = ds:buf[0] = 0x12345678 (3E forced)
    subl    %eax, %esi              # esi must be 0  (override read == plain read)

    # ---- store via ES override, reload plain (same addr) --------------------
    movl    %ecx, %es:4(%ebx)       # buf[4] = 0xcafebabe  (26 prefix on store)
    movl    4(%ebx), %edi           # edi = buf[4] = 0xcafebabe (plain)
    cmpl    %ecx, %edi              # ZF must be 1 (equal)

    # ---- CS / SS overrides on loads (read-only style, flat == same addr) ----
    movl    %cs:(%ebx), %edx        # edx = cs:buf[0] = 0x12345678 (2E prefix)
    subl    %eax, %edx              # edx must be 0
    movl    %ss:4(%ebx), %ebp       # ebp = ss:buf[4] = 0xcafebabe (36 prefix)
    subl    %ecx, %ebp              # ebp must be 0

    # ---- FS / GS overrides: base = 0 in the flat user model -----------------
    # fs:addr and gs:addr resolve to the SAME linear address as addr here.
    movl    %eax, %fs:8(%ebx)       # buf[8] = 0x12345678 (64 prefix on store)
    movl    8(%ebx), %esi           # esi = buf[8] = 0x12345678 (plain reload)
    subl    %eax, %esi              # esi must be 0 again
    movl    %gs:(%ebx), %edi        # edi = gs:buf[0] = 0x12345678 (65 prefix)
    subl    %eax, %edi              # edi must be 0

    # ---- LOCK prefix (F0) as a no-op on a normal RMW memory access ----------
    # lock add/xor/inc to memory must give the same result as the unlocked form.
    movl    $0x00000001, 12(%ebx)   # buf[12] = 1
    lock addl $0x0000000F, 12(%ebx) # buf[12] = 0x10 (locked RMW)
    lock incl 12(%ebx)              # buf[12] = 0x11
    lock xorl %eax, 12(%ebx)        # buf[12] ^= 0x12345678 = 0x12345669
    movl    12(%ebx), %edx          # edx = 0x12345669
    movl    $0x12345669, %ecx       # expected
    subl    %ecx, %edx              # edx must be 0

    # ---- multiple stacked prefixes: 0x66 (op16) + segment override ----------
    # exercise the prefix loop consuming MORE than one prefix before the opcode.
    movl    $0xAAAA0000, %eax       # eax hi witness
    movw    $0xBEEF, %fs:16(%ebx)   # 16-bit store through fs override (66 64 ..)
    # force 3E (DS) stacked with 66 (op-size) in front of a 16-bit load:
    .byte   0x3e                    # DS segment-override prefix (stacks w/ 66)
    movw    16(%ebx), %ax           # ax = ds:buf[16] = 0xbeef (66 3E .. stacked)
                                    # eax must be 0xAAAAbeef (hi preserved)
    # fold the assembled value so a wrong prefix path is observable
    movzwl  %ax, %esi               # esi = 0x0000beef

    # ---- final accumulate of all the "must be 0" results into ebp -----------
    # esi(beef) is intentionally nonzero; sum the zeroed witnesses:
    addl    %ebp, %edi              # 0 + 0 = 0
    addl    %edi, %edx              # 0 + 0 = 0  (edx holds 0 from lock fold)

    # ---- clean exit ---------------------------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80                   # halt

    # =========================================================================
    # RW scratch buffer (distinct .data PT_LOAD page; flat image spans it).
    # =========================================================================
    .data
    .align 4
buf:
    .long 0, 0, 0, 0, 0, 0          # buf[0..20], room for all accesses above
