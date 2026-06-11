/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M9.5 — CPUID (0F A2) real-mode firmware (the -bios image, psoccpuid.bin).
 *
 * The smallest possible exerciser of the newly-ungated CPUID in the SoC (soc_en=1):
 * a reset-vector firmware that STAYS in 16-bit real mode and executes CPUID for the
 * leaves real boot firmware actually probes, then isa-debug-exits. Every step is a
 * synchronous, deterministic instruction (no IRQ, no device I/O except the final
 * exit), so the whole run is PER-RECORD differentiable under the qemu-system-i386
 * `-cpu pentium` single-step golden — exactly the same oracle the M9/M9-rm boot gates
 * use. The per-record compare checks eax/ebx/ecx/edx the instant each CPUID retires,
 * so the four CPUID results are diffed directly against qemu (no memory store needed).
 *
 * Leaves exercised (the three distinct results qemu `-cpu pentium` produces):
 *   0x00000000 -> max-basic-leaf=1 + "GenuineIntel" (ebx=Genu ecx=ntel edx=ineI)
 *   0x00000001 -> family5/model4/step3 sig (eax=0x543) + P5 feature flags
 *   0x40000000 -> the TCG hypervisor leaf ("TCGTCGTCG" signature)
 *   0x80000000 -> an extended leaf -> qemu clamps to the leaf-1 Pentium result
 * ecx (the subleaf) is xored to 0 before each CPUID so the run is fully deterministic
 * regardless of the seeded reset state (no leaf here consults the subleaf anyway).
 *
 * cr0 stays the reset 0x60000010 for every record (pure 16-bit real mode, no PM, no
 * paging, no GDT). Zero new RTL beyond the 1-line CPUID decode ungate (cosim_en ->
 * cosim_en||soc_en); the K_CPUID leaf table already existed (verified vs qemu in the
 * Win95 co-sim). Encoding: `66`-prefixed movl/xorl (32-bit ops in a 16-bit segment),
 * bare `cpuid` (0F A2), `out 0xf4` isa-debug-exit (al=0x42 -> status 133).
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

    /* The standard leaf set real boot firmware (SeaBIOS / DOS) probes. ecx (the
     * subleaf) is xored to 0 before each so the run is fully deterministic. Each
     * result is diffed per-record against qemu-system-i386 -cpu pentium. */
    xorl    %eax, %eax              /* 0x00000000 — max-basic-leaf + GenuineIntel */
    xorl    %ecx, %ecx
    cpuid
    movl    $0x00000001, %eax       /* 0x00000001 — family/model/stepping + features */
    xorl    %ecx, %ecx
    cpuid
    movl    $0x00000002, %eax       /* 0x00000002 — cache/TLB descriptors */
    xorl    %ecx, %ecx
    cpuid
    movl    $0x00000003, %eax       /* 0x00000003 — processor serial (0 on pentium) */
    xorl    %ecx, %ecx
    cpuid
    movl    $0x00000004, %eax       /* 0x00000004 — deterministic cache params (subleaf 0) */
    xorl    %ecx, %ecx
    cpuid
    movl    $0x40000000, %eax       /* 0x40000000 — TCG hypervisor max + signature */
    xorl    %ecx, %ecx
    cpuid
    movl    $0x40000001, %eax       /* 0x40000001 — TCG hypervisor feature leaf */
    xorl    %ecx, %ecx
    cpuid
    movl    $0x80000000, %eax       /* 0x80000000 — max extended leaf */
    xorl    %ecx, %ecx
    cpuid
    movl    $0x80000001, %eax       /* 0x80000001 — extended feature flags */
    xorl    %ecx, %ecx
    cpuid
    movl    $0x80000002, %eax       /* 0x80000002 — brand string [0..15] */
    xorl    %ecx, %ecx
    cpuid
    movl    $0x80000003, %eax       /* 0x80000003 — brand string [16..31] */
    xorl    %ecx, %ecx
    cpuid
    movl    $0x80000004, %eax       /* 0x80000004 — brand string [32..47] */
    xorl    %ecx, %ecx
    cpuid

    /* isa-debug-exit: out 0xf4, al=0x42 -> process status (0x42<<1)|1 = 133 */
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
1:  hlt
    jmp     1b

    /* ===================== 16-bit reset stub @ 0xFFF0 ==================== */
    .section .reset,"ax"
    .global _reset
_reset:
    .byte   0xEA                        /* far jmp 0xF000:_start16_off */
    .word   _start16_off
    .word   0xF000
