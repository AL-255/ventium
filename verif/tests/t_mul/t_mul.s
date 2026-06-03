# =============================================================================
# Ventium M2 test: t_mul  --  MUL / IMUL coverage (multiply group)
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Build:
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Covers (docs/m2-isa-spec.md "Multiply / divide"):
#   * MUL  r/m32   (F7 /4)            -- unsigned, EDX:EAX <- EAX * r/m32
#   * IMUL r/m32   (F7 /5)            -- signed,   EDX:EAX <- EAX * r/m32
#   * IMUL r32, r/m32        (0F AF)  -- two-operand, 32-bit result in dst
#   * IMUL r32, r/m32, imm8  (6B /r ib, sign-extended imm)
#   * IMUL r32, r/m32, imm32 (69 /r id)
# Memory r/m sources are exercised for the EDX:EAX forms so the AGU path is hit.
#
# EFLAGS: MUL/IMUL leave SF/ZF/AF/PF *undefined* (CF/OF defined). The comparator
# masks those undefined bits (tracefmt EFLAGS_UNDEFINED["mul"/"imul"]=0x8C4), so
# we only need the architectural CF/OF (full-result-fits indicator) to match,
# which it will because QEMU is ground truth. No new masking entries needed.
#
# Edge operands: 0, 1, 0x7fffffff (INT_MAX), 0x80000000 (INT_MIN), 0xffffffff
# (-1 signed / max unsigned), and products that do / do not overflow 32 bits so
# CF/OF take both values. NO faulting ops. Deterministic. Ends _exit(0).
# =============================================================================

    .text
    .globl  _start
_start:
    # ---- MUL r/m32 (unsigned, full 64-bit product into EDX:EAX) -------------
    # (a) small * small : product fits in 32 bits -> EDX=0, CF=OF=0
    movl    $0x00000007, %eax
    movl    $0x00000006, %ecx
    mull    %ecx                    # EDX:EAX = 7*6 = 42 ; EDX=0
    # eax=0x2a edx=0

    # (b) large unsigned * 2 : overflows 32 bits -> EDX!=0, CF=OF=1
    movl    $0x80000000, %eax       # 2^31
    movl    $0x00000002, %ecx
    mull    %ecx                    # EDX:EAX = 0x1_0000_0000 ; EDX=1 EAX=0
    # edx=1 eax=0  (CF=OF=1)

    # (c) 0xffffffff * 0xffffffff = 0xfffffffe_00000001 (max unsigned square)
    movl    $0xffffffff, %eax
    movl    $0xffffffff, %ecx
    mull    %ecx                    # EDX=0xfffffffe EAX=0x00000001
    # edx=0xfffffffe eax=0x00000001

    # (d) MUL by memory operand, multiplier 0 -> product 0, EDX=0, CF=OF=0
    movl    $0x12345678, %eax
    mull    m_zero                  # EAX * 0 -> EDX:EAX = 0
    # eax=0 edx=0

    # ---- IMUL r/m32 (signed, full product into EDX:EAX) --------------------
    # (e) (-1) * (-1) = 1 : EDX sign-extends to 0
    movl    $0xffffffff, %eax       # -1
    movl    $0xffffffff, %ecx       # -1
    imull   %ecx                    # EDX:EAX = 1 ; EDX=0
    # eax=1 edx=0  (CF=OF=0: result fits in 32-bit signed)

    # (f) INT_MIN * (-1) = +2^31 : does NOT fit signed 32-bit -> CF=OF=1
    movl    $0x80000000, %eax       # -2^31
    movl    $0xffffffff, %ecx       # -1
    imull   %ecx                    # EDX:EAX = 0x0000_0000_8000_0000
    # edx=0 eax=0x80000000  (CF=OF=1)

    # (g) signed large positive * small positive via memory source
    movl    $0x7fffffff, %eax       # INT_MAX
    imull   m_two                   # EDX:EAX = 0xfffffffe (INT_MAX*2)
    # full 64-bit: 0x0000_0000_ffff_fffe ; EDX=0 EAX=0xfffffffe (CF=OF=1)

    # ---- IMUL r32, r/m32  (0F AF) : two-operand, low 32 bits kept ----------
    # (h) reg,reg
    movl    $0x00010000, %ebx       # 2^16
    movl    $0x00010000, %edx       # 2^16
    imull   %edx, %ebx              # ebx = (2^16 * 2^16) low32 = 0  (CF=OF=1)
    # ebx=0

    # (i) reg, memory : signed -3 * 5 = -15
    movl    $0xfffffffd, %esi       # -3
    imull   m_five, %esi            # esi = -15 = 0xfffffff1  (fits: CF=OF=0)
    # esi=0xfffffff1

    # ---- IMUL r32, r/m32, imm8  (6B /r ib, sign-extended) ------------------
    # (j) src * (-2)
    movl    $0x00000064, %edi       # 100
    imull   $-2, %edi, %edi         # edi = 100 * (-2) = -200 = 0xffffff38
    # edi=0xffffff38

    # (k) memory src * imm8, into a fresh reg
    imull   $7, m_three, %ebp       # ebp = 3 * 7 = 21 = 0x15
    # ebp=0x15

    # ---- IMUL r32, r/m32, imm32 (69 /r id) ---------------------------------
    # (l) src * large imm32 -> overflow low32 kept (CF=OF=1)
    movl    $0x00010001, %ecx
    imull   $0x00010001, %ecx, %edx # edx = 0x00010001 * 0x00010001 low32
                                    #     = 0x1_0002_0001 -> low32 = 0x00020001
    # edx=0x00020001  (CF=OF=1)

    # ---- clean exit: Linux i386 _exit(0) ------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80                   # halt / syscall

    # =========================================================================
    .data
    .align 4
m_zero:  .long 0x00000000
m_two:   .long 0x00000002
m_three: .long 0x00000003
m_five:  .long 0x00000005
