# =============================================================================
# Ventium M6 errata test: err_f00f_mem -- VALID memory CMPXCHG8B must NOT hang
# =============================================================================
# Contrast for Erratum 81 (F00F). A LOCK CMPXCHG8B with a MEMORY destination is a
# VALID instruction (no #UD) and must NEVER trigger the F00F hang, even with the
# errata flag on. The Ventium clean core does not implement the CMPXCHG8B memory
# datapath (deferred to M2S), so it HALTs as an out-of-scope opcode -- but it must
# do so WITHOUT entering the hang state (cpu_hung stays 0).
#
# Encoding: F0 0F C7 09  =  lock cmpxchg8b (%ecx)   (mod=00 rm=ECX -> memory).
#
# SELF-CHECK: with errata ON (mask 0x4), the TB must NOT print "CPU HUNG" -- the
# memory form takes the loud HALT, not the hang. (cpu_hung never asserts.)
#
# Freestanding 32-bit i386 (P5).
# =============================================================================

    .text
    .globl  _start
_start:
    nop                         # retire 1
    nop                         # retire 2
    movl    $stk, %ecx          # ECX -> a valid memory address (the 8-byte slot)
    # ---- valid LOCK CMPXCHG8B with a MEMORY destination -----------------------
    .byte 0xF0, 0x0F, 0xC7, 0x09   # lock cmpxchg8b (%ecx)  (memory form; mod=00)
    nop
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80

    .data
    .align 8
stk:    .quad 0
