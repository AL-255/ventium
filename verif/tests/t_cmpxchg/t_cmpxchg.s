# =============================================================================
# Ventium M7 test: t_cmpxchg  --  CMPXCHG r/m,r  (0F B0 / 0F B1)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build: gcc -m32 -march=pentium -nostdlib -static -Wl,-Ttext=0x08048000
#
# Bucket: cmpxchg. CMPXCHG r/m,r is the lock-cmpxchg primitive the Quake macro-
# workload hit (`lock cmpxchg dword ptr [edi+...], edx`). Validated DIFFERENTIALLY
# against the QEMU gdbstub golden (compare.py --mode func): every GPR + EFLAGS +
# EIP is compared after EVERY instruction, so a wrong result OR a wrong flag bit
# OR a wrong conditional write diverges immediately.
#
# CMPXCHG r/m,r (accumulator = AL for 0F B0, eAX for 0F B1):
#   temp = r/m;  CMP accumulator,temp (sets ZF/CF/PF/AF/SF/OF as accumulator-temp);
#   if accumulator==temp:  ZF=1; r/m  <- src (the reg operand)
#   else:                  ZF=0; accumulator <- temp  (r/m unchanged)
# CMPXCHG fully DEFINES all six arithmetic flags (exactly like CMP), so no flag
# is undefined and no EFLAGS masking is needed — the whole EFLAGS image is checked.
#
# Coverage (each form, both the EQUAL and NOT-EQUAL branch):
#   * 0F B1 32-bit  reg-dest   (mod==11)  equal + not-equal
#   * 0F B1 32-bit  mem-dest   (mod!=11)  equal + not-equal      <-- the Quake form
#   * 0F B1 16-bit  (66 prefix) reg-dest  + mem-dest             (partial reg/mem)
#   * 0F B0  8-bit  reg-dest (AL/BL + a high8 BH) + mem-dest      (partial byte)
#   * LOCK-prefixed mem-dest (F0) — must be a functional no-op (atomic RMW)
# Destinations are seeded with recognizable patterns so a too-wide or wrong-value
# write diverges; the surrounding bytes of partial-width writes are checked too.
# =============================================================================

    .text
    .globl  _start
_start:

    # =====================================================================
    # 0F B1 — CMPXCHG r/m32, r32  (32-bit)
    # =====================================================================

    # ---- EQUAL (reg-dest): acc==dst  ->  ZF=1, dst <- src --------------
    movl    $0x11112222, %eax       # accumulator
    movl    $0x11112222, %ebx       # dst (== acc)  -> equal
    movl    $0xDEADBEEF, %ecx       # src
    cmpxchg %ecx, %ebx              # acc==ebx -> ZF=1; ebx <- ecx (0xDEADBEEF)
                                    # eax unchanged (0x11112222)

    # ---- NOT-EQUAL (reg-dest): acc!=dst  ->  ZF=0, acc <- dst ----------
    movl    $0x11112222, %eax       # accumulator
    movl    $0x33334444, %ebx       # dst (!= acc)  -> not equal
    movl    $0xCAFEF00D, %ecx       # src (must NOT be written)
    cmpxchg %ecx, %ebx              # acc!=ebx -> ZF=0; eax <- ebx (0x33334444)
                                    # ebx unchanged (0x33334444), ecx unchanged

    # ---- dst == EAX corner (always-equal): cmpxchg eax,ebx ------------
    movl    $0x55556666, %eax
    movl    $0x77778888, %ebx       # src
    cmpxchg %ebx, %eax              # acc(eax)==dst(eax) always -> ZF=1; eax <- ebx

    # ---- flags exercise: acc<dst (borrow) -> CF=1, ZF=0 ---------------
    movl    $0x00000001, %eax
    movl    $0x00000002, %ebx       # dst > acc -> 1-2 borrows: CF=1, SF=1, ZF=0
    movl    $0x99999999, %ecx
    cmpxchg %ecx, %ebx              # not equal -> eax <- 2; CF=1,SF=1,ZF=0,OF=0

    # =====================================================================
    # 0F B1 — CMPXCHG r/m32, r32  MEMORY destination (the Quake form)
    # =====================================================================

    leal    qword_a, %edi           # base for [edi+disp]

    # ---- EQUAL (mem-dest): acc==[mem] -> ZF=1, [mem] <- src -----------
    movl    $0xA5A5A5A5, %eax       # accumulator
    movl    $0xA5A5A5A5, qword_a    # seed mem == acc -> equal
    movl    $0x0BADF00D, %edx       # src
    cmpxchg %edx, (%edi)            # equal -> ZF=1; [edi] <- edx (0x0BADF00D)
    movl    qword_a, %esi           # reload to fold the store into a checked GPR

    # ---- NOT-EQUAL (mem-dest): acc!=[mem] -> ZF=0, acc <- [mem] -------
    movl    $0xA5A5A5A5, %eax       # accumulator
    movl    $0x12345678, qword_a    # seed mem != acc -> not equal
    movl    $0xFEEDFACE, %edx       # src (must NOT be written to mem)
    cmpxchg %edx, (%edi)            # not equal -> eax <- 0x12345678; mem unchanged
    movl    qword_a, %esi           # esi = mem (still 0x12345678)

    # ---- LOCK-prefixed mem-dest (F0): functional no-op, equal case ----
    movl    $0xC0FFEE11, %eax
    movl    $0xC0FFEE11, qword_b    # equal
    movl    $0xBEEFCAFE, %edx
    leal    qword_b, %ebp
    lock cmpxchg %edx, (%ebp)       # F0 prefix: still equal -> [ebp] <- edx
    movl    qword_b, %esi           # esi = 0xBEEFCAFE

    # ---- LOCK-prefixed mem-dest with disp32 (mirrors Quake's encoding) -
    movl    $0x20202020, %eax
    movl    $0x20202020, qword_c    # equal
    movl    $0x31313131, %edx
    lock cmpxchg %edx, qword_c      # cmpxchg [disp32], edx — Quake-shaped form
    movl    qword_c, %esi

    # =====================================================================
    # 0F B1 with 66 prefix — CMPXCHG r/m16, r16  (16-bit)
    # =====================================================================

    # ---- 16-bit reg-dest, equal: AX==BX -> BX <- CX, upper16 preserved
    movl    $0xAAAA1234, %eax       # AX=0x1234, upper=0xAAAA preserved
    movl    $0xBBBB1234, %ebx       # BX=0x1234 (== AX) -> equal
    movl    $0xCCCC5678, %ecx       # CX=0x5678 src
    cmpxchgw %cx, %bx               # equal -> ZF=1; BX <- CX (ebx=0xBBBB5678)
                                    # upper16 of ebx preserved, eax unchanged

    # ---- 16-bit reg-dest, not-equal: AX!=BX -> AX <- BX --------------
    movl    $0xAAAA1234, %eax       # AX=0x1234
    movl    $0xBBBB9999, %ebx       # BX=0x9999 (!= AX) -> not equal
    movl    $0xCCCC5678, %ecx
    cmpxchgw %cx, %bx               # not equal -> AX <- BX(0x9999); eax=0xAAAA9999

    # ---- 16-bit mem-dest, equal ---------------------------------------
    movl    $0x0000ABCD, %eax       # AX=0xABCD
    movw    $0xABCD, word_a         # mem16 == AX -> equal
    movl    $0x0000EF01, %edx       # DX=0xEF01 src
    leal    word_a, %edi
    cmpxchgw %dx, (%edi)            # equal -> [edi].w <- DX (0xEF01)
    movzwl  word_a, %esi            # esi = 0xEF01

    # =====================================================================
    # 0F B0 — CMPXCHG r/m8, r8  (8-bit)
    # =====================================================================

    # ---- 8-bit reg-dest, equal: AL==BL -> BL <- CL --------------------
    movl    $0x111111AA, %eax       # AL=0xAA, upper preserved
    movl    $0x222222AA, %ebx       # BL=0xAA (== AL) -> equal
    movl    $0x33333355, %ecx       # CL=0x55 src
    cmpxchgb %cl, %bl               # equal -> BL <- CL (ebx=0x22222255)

    # ---- 8-bit reg-dest, not-equal: AL!=BL -> AL <- BL ---------------
    movl    $0x111111AA, %eax       # AL=0xAA
    movl    $0x2222227F, %ebx       # BL=0x7F (!= AL) -> not equal
    movl    $0x33333355, %ecx
    cmpxchgb %cl, %bl               # not equal -> AL <- BL(0x7F); eax=0x1111117F

    # ---- 8-bit reg-dest with a HIGH-8 operand (BH), equal -------------
    movl    $0x000000C3, %eax       # AL=0xC3
    movl    $0xDDC300DD, %ebx       # BH=0xC3 (== AL) -> equal
    movl    $0x00009100, %ecx       # CH=0x91 src (high-8)
    cmpxchgb %ch, %bh               # equal -> BH <- CH (ebx=0xDD9100DD)

    # ---- 8-bit mem-dest, equal ----------------------------------------
    movl    $0x000000E7, %eax       # AL=0xE7
    movb    $0xE7, byte_a           # mem8 == AL -> equal
    movl    $0x0000002B, %edx       # DL=0x2B src
    leal    byte_a, %edi
    cmpxchgb %dl, (%edi)            # equal -> [edi].b <- DL (0x2B)
    movzbl  byte_a, %esi            # esi = 0x2B

    # ---- 8-bit mem-dest, not-equal: mem unchanged, AL <- mem ---------
    movl    $0x000000E7, %eax       # AL=0xE7
    movb    $0x40, byte_a           # mem8 != AL -> not equal
    movl    $0x0000002B, %edx       # DL src (must NOT be written)
    cmpxchgb %dl, (%edi)            # not equal -> AL <- 0x40; mem unchanged
    movzbl  byte_a, %esi            # esi = 0x40 (mem unchanged)

    # =====================================================================
    # clean exit: Linux i386 _exit(0)
    # =====================================================================
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80                   # halt / syscall

    # =========================================================================
    # Read/write data area (distinct RW PT_LOAD page).
    # =========================================================================
    .data
    .align 4
qword_a:  .long 0x00000000
qword_b:  .long 0x00000000
qword_c:  .long 0x00000000
word_a:   .long 0x00000000
byte_a:   .long 0x00000000
