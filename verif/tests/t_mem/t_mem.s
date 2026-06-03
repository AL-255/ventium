# =============================================================================
# Ventium M1 test: t_mem  --  memory load/store + AGU coverage
# =============================================================================
# Freestanding 32-bit i386 (P5 / Pentium). AT&T / GNU as.
# Built like smoke:
#   gcc -m32 -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000
#
# Goal: exercise the address-generation unit (AGU) + data bus by storing and
# reloading values through several addressing forms the M1 decoder supports,
# then doing ALU on the reloaded values so a wrong load/store corrupts a GPR
# the comparator checks. Uses ONLY the M1-implemented integer subset
# (docs/m1-core-spec.md): mov r32,imm32 (B8+rd), mov r/m32,r32 (89 /r),
# mov r32,r/m32 (8B /r), mov r/m32,imm32 (C7 /0 id), add/sub/and/or/xor/cmp
# (reg & 83-imm8 forms), lea (8D /r), inc/dec. NO undefined-EFLAGS ops.
#
# Memory addressing forms exercised (all 32-bit):
#   * absolute   [disp32]            (mod=00, rm=101)   -> .data symbols
#   * base       [reg]               (mod=00, rm=base)
#   * base+disp8 disp8(%reg)         (mod=01)
#   * SIB        (%base,%index,scale) (rm=100 + SIB)
#
# The .data area lives in a separate RW PT_LOAD segment (linker default); the
# Verilator TB's flat image (elf2flat) spans + zero-fills the gap, and QEMU's
# linux-user loader maps it, so both models see identical memory.
# =============================================================================

    .text
    .globl  _start
_start:
    # --- seed registers with deterministic constants -------------------------
    movl    $0x12345678, %eax       # eax = 0x12345678
    movl    $0x0000abcd, %ecx       # ecx = 0x0000abcd
    movl    $0x00000004, %edx       # edx = 4 (used as a SIB index)

    # --- absolute [disp32] store/reload (89 /r, 8B /r, mod=00 rm=101) --------
    movl    %eax, var_a             # mem[var_a]  = 0x12345678   (89 /05 disp32)
    movl    %ecx, var_b             # mem[var_b]  = 0x0000abcd
    movl    var_a, %esi             # esi = mem[var_a] = 0x12345678  (8B /35 disp32)
    movl    var_b, %edi             # edi = mem[var_b] = 0x0000abcd

    # --- mov r/m32, imm32 to memory (C7 /0 id, mod=00 rm=101) ----------------
    movl    $0xdeadbeef, var_c      # mem[var_c] = 0xdeadbeef
    movl    var_c, %ebx             # ebx = 0xdeadbeef

    # --- ALU on reloaded values (so a bad load shows up in a checked GPR) ----
    addl    %edi, %esi              # esi = 0x12345678 + 0x0000abcd = 0x12346245
    subl    $0x00000045, %esi       # esi = 0x12346200  (83 /5 ib, sign-ext imm8)

    # --- base-register indirect [reg] (mod=00, rm=base) ----------------------
    leal    var_d, %ebp             # ebp = &var_d            (8D /r, abs via disp32)
    movl    %esi, (%ebp)            # mem[var_d] = esi = 0x12346200   (89 /55 -> [ebp]?)
    movl    (%ebp), %eax            # eax = mem[var_d] = 0x12346200

    # --- base + disp8 (mod=01) -----------------------------------------------
    movl    $0xcafef00d, 4(%ebp)    # mem[var_d+4] = 0xcafef00d  (C7 /0 disp8 imm32)
    movl    4(%ebp), %ecx           # ecx = 0xcafef00d

    # --- SIB: base + index*scale (rm=100 + SIB) ------------------------------
    leal    var_e, %ebx             # ebx = &var_e
    movl    %eax, (%ebx,%edx,2)     # mem[var_e + edx*2] = eax  (edx=4 -> +8)
    movl    (%ebx,%edx,2), %edi     # edi = mem[var_e+8] = 0x12346200

    # --- final ALU to fold everything into flags-bearing GPRs ----------------
    xorl    %edx, %edx              # edx = 0 (ZF=1,PF=1,CF=0,OF=0)
    orl     $0x0000000f, %edx       # edx = 0x0000000f
    andl    $0x00000005, %edx       # edx = 0x00000005

    # --- clean exit: Linux i386 _exit(0) -------------------------------------
    movl    $1, %eax                # __NR_exit
    xorl    %ebx, %ebx              # status = 0
    int     $0x80                   # halt / syscall -> never returns

    # =========================================================================
    # Read/write data area. Distinct page (RW PT_LOAD); reachable by absolute
    # disp32 and via lea'd base/index addressing above.
    # =========================================================================
    .data
    .align 4
var_a:  .long 0x00000000
var_b:  .long 0x00000000
var_c:  .long 0x00000000
var_d:  .long 0x00000000
        .long 0x00000000            # var_d+4 slot
var_e:  .long 0x00000000
        .long 0x00000000            # var_e+4
        .long 0x00000000            # var_e+8 slot (SIB target)
        .long 0x00000000
