    .text
    .globl _start
_start:
    movl $40, %eax          # bit 40 = dword1 bit 8  (out of dword0's range)
    btl  %eax, bitmap       # CF should be 1 (correct); masked-to-31 impl reads dword0 bit 8 = 0
    jc   good
bad:
    movl $0xbad00001, %ebx
    jmp  exit
good:
    movl $0x600d0001, %ebx
exit:
    movl $1, %eax
    int  $0x80
    .data
    .align 4
bitmap:
    .long 0x00000000        # bits 0..31  (bit 8 CLEAR -> masked impl sees 0)
    .long 0x00000100        # bits 32..63 (bit 40 SET  -> correct impl sees 1)

# REVIEW_Jul29 M-06 reproducer — memory BT with a REGISTER bit index > operand size.
# IA-32: for BT/BTS/BTR/BTC with a MEMORY operand and a REGISTER offset, the offset is
# a SIGNED bit-string index that may address outside the addressed operand; the CPU
# adds (signed(idx) >> 5)*4 (32-bit operand) to the effective address and uses idx&31
# as the in-dword bit. (With an IMMEDIATE offset it is taken modulo the operand size,
# so no EA adjustment — only the register form is affected.)
#
# Ventium currently masks the index to the operand size and never adjusts the EA
# (decode_stages.sv ~8'hA3,8'hAB,8'hB3,8'hBB memory arm), so it reads the WRONG DWORD.
#
# STATUS 2026-07-31: bug CONFIRMED against the QEMU oracle.
#   QEMU  golden : ebx = 0x600d0001  (correct: bit 40 is set in dword1)
#   Ventium RTL  : ebx = 0xbad00001  (masked to dword0 bit 8, which is clear)
# The fix needs an EA adjustment on the bit-test memory load AND the RMW store path;
# not attempted yet because it touches the shared effective-address path. Tracked in
# task #44.
