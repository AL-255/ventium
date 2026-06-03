# =============================================================================
# Ventium M2 test: t_shld  --  SHLD / SHRD (double-precision shifts)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build: gcc -m32 -nostdlib -static -Wl,-Ttext=0x08048000
#
# Bucket (shifts, continued): SHLD = 0F A4 (imm8) / 0F A5 (CL),
#                             SHRD = 0F AC (imm8) / 0F AD (CL).
#
# Semantics:
#   SHLD dst, src, count : dst <<= count, the vacated low bits are filled with
#                          the HIGH `count` bits of src. CF = last bit shifted
#                          out of dst's high end.
#   SHRD dst, src, count : dst >>= count, the vacated high bits are filled with
#                          the LOW `count` bits of src. CF = last bit shifted
#                          out of dst's low end.
#   Count is masked & 0x1f. count == 0 -> no flags change, no result change.
#   AT&T operand order: shld $count, %src, %dst (and shld %cl, %src, %dst).
#
# EFLAGS undefined (comparator table must mask, same as SHL/SHR):
#   SHLD/SHRD: OF undefined for count != 1, AF undefined; CF/ZF/SF/PF defined.
# Diff-clean iff the comparator masks OF+AF for shld/shrd.
#
# Edge counts: 1 (OF defined), 4, 8, 16, 31, 32->&0x1f->0 (no-op).
# =============================================================================

    .text
    .globl  _start
_start:

    # ---- SHLD by imm8 -------------------------------------------------------
    movl    $0x12340000, %eax       # dst
    movl    $0xabcd0000, %edx       # src
    shldl   $16, %edx, %eax         # eax = 0x0000abcd (top 16 of src -> low)

    movl    $0xf0000000, %eax
    movl    $0x0000000f, %edx
    shldl   $4, %edx, %eax          # eax = 0x00000000, CF=1 (count!=1 -> OF undef)

    movl    $0x00000001, %eax
    movl    $0x80000000, %edx
    shldl   $1, %edx, %eax          # eax = 0x00000003, count==1 -> OF defined

    movl    $0x7fffffff, %eax
    movl    $0x80000000, %edx
    shldl   $31, %edx, %eax         # eax = 0xc0000000 (max shift, top 31 of src)

    # ---- SHLD by CL ---------------------------------------------------------
    movl    $0x0000abcd, %eax
    movl    $0xffff0000, %edx
    movl    $8, %ecx
    shldl   %cl, %edx, %eax         # eax = 0x00abcdff

    # ---- SHRD by imm8 -------------------------------------------------------
    movl    $0x0000abcd, %eax       # dst
    movl    $0x0000ffff, %edx       # src
    shrdl   $8, %edx, %eax          # eax = 0xff0000ab (low 8 of src -> high)

    movl    $0x80000000, %eax
    movl    $0x00000001, %edx
    shrdl   $1, %edx, %eax          # eax = 0xc0000000, count==1 -> OF defined

    movl    $0xffffffff, %eax
    movl    $0x00000000, %edx
    shrdl   $4, %edx, %eax          # eax = 0x0fffffff, CF=1 (count!=1)

    # ---- SHRD by CL ---------------------------------------------------------
    movl    $0x12345678, %eax
    movl    $0xfedcba98, %edx
    movl    $4, %ecx
    shrdl   %cl, %edx, %eax         # eax = 0x81234567

    # ---- count == 0 (CL form): NO result change, NO flag change -------------
    movl    $0xdeadbeef, %eax
    movl    $0x12345678, %edx
    movl    $0, %ecx
    cmpl    $1, %eax                # defined flag anchor (eax != 1)
    shldl   %cl, %edx, %eax         # count==0 -> eax & flags unchanged
    movl    $0xcafebabe, %eax
    movl    $0, %ecx
    testl   %eax, %eax              # defined flag anchor (SF=1,ZF=0)
    shrdl   %cl, %edx, %eax         # count==0 -> eax & flags unchanged

    # ---- count == 32 -> masked to 0 (imm form) ------------------------------
    # NOTE: count is masked & 0x1f at execution; for the imm8 form GNU as still
    # encodes the literal 32 as ib=0x20, so this exercises the runtime mask.
    movl    $0x11223344, %eax
    movl    $0x99aabbcc, %edx
    addl    $0, %eax                # defined flag anchor
    shldl   $32, %edx, %eax         # 32 & 0x1f == 0 -> no change to eax/flags

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80                   # halt
