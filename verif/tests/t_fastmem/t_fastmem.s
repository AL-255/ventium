# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# Generic fast data-memory regression: literal ModR/M disp32, memory CMP, and
# the audited U-side MOV [mem],r32 store forms.
#
# These are ordinary 32-bit DS memory forms emitted by C code for globals and
# array/list traversal.  The checks deliberately use unequal operands and the
# opposite unsigned branches, proving operand order as well as the loaded data:
#   3B /r: CMP r32,r/m32 must compute reg - memory (JB here), and
#   39 /r: CMP r/m32,r32 must compute memory - reg (JA here).
# A branch failure exits nonzero, so it is visible in the QEMU-vs-RTL trace.
# =============================================================================

    .text
    .globl  _start
_start:
    # 89 /r stores must preserve source values even when the source is also an
    # address input. Test direct, base+disp8/base+disp32, SIB with and without
    # displacement, and an unaligned dword; the following ordinary loads make
    # every write externally observable.
    movl    $0x13579bdf, %edi
    movl    %edi, direct_word
    movl    direct_word, %eax
    cmpl    %edi, %eax
    jne     .Lfail

    leal    direct_word-4, %esi
    movl    $0x2468ace0, %edi
    movl    %edi, 4(%esi)
    movl    direct_word, %eax
    cmpl    %edi, %eax
    jne     .Lfail

    # Force ModR/M mod=10 (disp32), which must use the exact signed dword
    # displacement rather than the disp8 path above.
    leal    direct_word-0x1234, %esi
    movl    $0x55aa33cc, %edi
    movl    %edi, 0x1234(%esi)
    movl    direct_word, %eax
    cmpl    %edi, %eax
    jne     .Lfail

    # The same GPR is a base and source: the old architectural value must be
    # used for both, not a post-retire value or an implicit temporary.
    leal    direct_word, %eax
    movl    %eax, (%eax)
    movl    direct_word, %edi
    cmpl    %eax, %edi
    jne     .Lfail

    leal    store_array, %edx
    movl    $1, %ecx
    # Concrete-base SIB with no displacement (mod=00) and an active index.
    movl    $0x76543210, %edi
    movl    %edi, (%edx,%ecx,4)
    movl    4(%edx), %eax
    cmpl    %edi, %eax
    jne     .Lfail

    movl    $0x0badc0de, %edi
    movl    %edi, 4(%edx,%ecx,4)
    movl    8(%edx), %eax
    cmpl    %edi, %eax
    jne     .Lfail

    movl    $0x89abcdef, %edi
    movl    %edi, unaligned_word
    movl    unaligned_word, %eax
    cmpl    %edi, %eax
    jne     .Lfail

    # Restore the read/CMP fixture used by the checks below.
    movl    $0xa4f16d39, %edi
    movl    %edi, direct_word

    # 8B /r mod=00,r/m=101: MOV EDI,DS:[absolute disp32].
    movl    direct_word, %edi
    cmpl    $0xa4f16d39, %edi
    jne     .Lfail

    # 3B /r mod=00,r/m=101: EDI - DS:[absolute disp32] = -1 -> CF=1.
    movl    $0xa4f16d38, %edi
    cmpl    direct_word, %edi
    jb      1f
    jmp     .Lfail
1:
    # 39 /r mod=00,r/m=101: DS:[absolute disp32] - EDI = +1 -> JA.
    cmpl    %edi, direct_word
    ja      2f
    jmp     .Lfail
2:
    # The common base+disp8 forms must retain the same semantics.  LEA is only
    # setup; the following CMPs are the forms under test.
    leal    direct_word-4, %esi
    movl    $0xa4f16d38, %edi
    cmpl    4(%esi), %edi
    jb      3f
    jmp     .Lfail
3:
    cmpl    %edi, 4(%esi)
    ja      4f
    jmp     .Lfail
4:
    movl    $1, %eax
    xorl    %ebx, %ebx
    int     $0x80

.Lfail:
    movl    $1, %eax
    movl    $1, %ebx
    int     $0x80

    .data
    .align 4
direct_word:
    .long   0xa4f16d39
store_array:
    .long   0, 0, 0
    .byte   0
unaligned_word:
    .long   0
