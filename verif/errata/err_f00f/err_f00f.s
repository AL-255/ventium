# =============================================================================
# Ventium M6 errata test: err_f00f -- F00F LOCK CMPXCHG8B reg-dst HANG (Erratum 81)
# =============================================================================
# Spec: 242480-041_Pentium_Spec_Update_199901.pdf doc p.51, "Invalid Operand with
# Locked CMPXCHG8B Instruction". CMPXCHG8B's only valid destination is MEMORY; a
# REGISTER destination is an invalid opcode (#UD). But when the LOCK prefix is
# applied to the invalid register-destination form, the processor never starts
# the #UD handler (the bus stays locked) and HANGS.
#
# The infamous "F00F" byte sequence: F0 0F C7 C9
#   F0 = LOCK ; 0F C7 = CMPXCHG8B ; C9 = ModR/M mod=11 (register dst) /1 rm=ECX.
#
# We hand-encode it (the assembler refuses the invalid form). A few NOPs retire
# first so the trace proves the core was live before the hang.
#
# SELF-CHECK (verif/errata/run-m6.sh), reading the TB stderr + trace:
#   errata ON  : the core HANGS (TB prints "CPU HUNG (F00F ... Erratum 81)") and
#                NEVER retires the int 0x80 exit (a few NOPs retired, then hang).
#   errata OFF : the invalid opcode HALTs LOUDLY (no hang, no retire of it) -- the
#                clean core never enters the hang state.
#
# A valid MEMORY-form CMPXCHG8B (LOCK 0F C7 /0 with a memory ModR/M) is provided
# in err_f00f_mem.s as the contrast that must NOT hang even with errata ON.
#
# Freestanding 32-bit i386 (P5).
# =============================================================================

    .text
    .globl  _start
_start:
    nop                         # retire 1 (proves the core is live)
    nop                         # retire 2
    nop                         # retire 3
    # ---- the F00F sequence: LOCK CMPXCHG8B with a REGISTER destination --------
    .byte 0xF0, 0x0F, 0xC7, 0xC9   # lock cmpxchg8b %ecx  (invalid; reg dst /1)
    # ---- never reached on a hung stepping ------------------------------------
    nop
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80
