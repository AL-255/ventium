/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 * Ventium coverage: RDTSC (0F 31) + INVD (0F 08) + WBINVD (0F 09) real-mode
 * -bios firmware. These ops gate on (cosim_en || soc_en); this image is run
 * under ventium_top --system --cosim so the K_RDTSC + INVD/WBINVD decode+exec
 * arms (decode_stages.sv ~650/660, core_exec.svh:555, core_gpr_wb.svh:325) get
 * covered. RDTSC is non-differential (time), so this is COVERAGE-ONLY (no golden).
 */
    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli
    cld
    xorw    %ax, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    $0x7000, %sp

    rdtsc                           /* 0F 31 -> EDX:EAX = TSC (K_RDTSC) */
    rdtsc
    .byte   0x0f, 0x09              /* WBINVD (0F 09) -> NOP retire */
    .byte   0x0f, 0x08              /* INVD   (0F 08) -> NOP retire */

    /* isa-debug-exit: out 0xf4, al=0x42 -> status 133 */
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
1:  hlt
    jmp     1b

    .section .reset,"ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
