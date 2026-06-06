/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M9 — boot-firmware STUB (the -bios image, pboot_stub.bin).
 *
 * The smallest thing that is genuinely "BOOTING": a reset-vector firmware that
 * chain-loads a REAL boot sector from the disk and hands control to it.
 *
 *   reset (F000:FFF0) -> 16-bit real mode -> protected mode (flat 32-bit GDT) ->
 *   set nIEN (polled, NO IRQ14 ever) -> READ SECTORS (0x20) LBA0 from the IDE
 *   primary master via synchronous PIO into RAM at 0x8000 -> FAR JMP into it.
 *
 * The boot sector (disk LBA0, built by pboot_mbr.S) then executes FROM RAM to an
 * observable end-state (a signature write + isa-debug-exit). Every step is a
 * synchronous IN/OUT or polled-status read (nIEN set FIRST -> no interrupt is ever
 * delivered), so the whole run is PER-RECORD differentiable under the qemu-system
 * single-step golden, exactly like the pide IDE gate. NO new RTL: this runs on the
 * existing ventium_soc + ven_ide PIO read path + the flat TB memory.
 *
 * This proves the BIOS->MBR handoff (firmware reads a boot sector off the disk and
 * jumps to it). A real SeaBIOS POST is a separate, non-single-step-differentiable
 * track (CPUID/far-CALL/RETF/LSS/RDTSC + i440FX PAM shadow + IRQ-driven, 100K+
 * instructions) -- see verif/sys/tests/pboot/manifest.json for the path beyond.
 */
    .equ BOOT_LOAD, 0x00008000      /* where the firmware loads the boot sector */
    .equ GDT_BASE,  0x00000500      /* flat GDT in low RAM */

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
    /* build a flat GDT @ 0x500: [0]=null, [1]=code32 (0x08), [2]=data32 (0x10) */
    movl    $GDT_BASE, %ebx
    movl    $0, 0(%ebx)
    movl    $0, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)        /* code32: base 0, limit 0xFFFFF, 4K, 32-bit */
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)       /* data32: base 0, limit 0xFFFFF, 4K, 32-bit */
    movl    $0x00CF9200, 20(%ebx)
    movw    $0x0017, 0x0480             /* GDTR: limit 0x17 (3 descriptors) */
    movl    $GDT_BASE, 0x0482          /*       base 0x500 */
    lgdt    0x0480
    movl    %cr0, %eax
    orl     $1, %eax                    /* CR0.PE = 1 */
    movl    %eax, %cr0
    .byte   0x66, 0xEA                  /* far jmp 0x08:pm32 (32-bit) */
    .long   pm32
    .word   0x08

    .code32
    .section .text32,"ax"
    .global pm32
pm32:
    movw    $0x10, %ax                  /* flat 32-bit data segments */
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movl    $0x00090000, %esp
    /* set nIEN FIRST (0x3F6 bit1) -> polled mode, NO IRQ14 ever delivered */
    movb    $0x02, %al; movw $0x3F6, %dx; outb %al, %dx
    /* READ SECTORS (0x20) LBA0, nsector=1, primary master, LBA mode */
    movb    $0xE0, %al; movw $0x1F6, %dx; outb %al, %dx   /* devhead: LBA|master */
    movb    $1,    %al; movw $0x1F2, %dx; outb %al, %dx   /* nsector = 1 */
    xorb    %al, %al
    movw    $0x1F3, %dx; outb %al, %dx                    /* LBA[7:0]   = 0 */
    movw    $0x1F4, %dx; outb %al, %dx                    /* LBA[15:8]  = 0 */
    movw    $0x1F5, %dx; outb %al, %dx                    /* LBA[23:16] = 0 */
    movb    $0x20, %al; movw $0x1F7, %dx; outb %al, %dx   /* READ SECTORS */
1:  movw    $0x1F7, %dx; inb %dx, %al; testb $0x80, %al; jnz 1b   /* wait BSY=0 */
    testb   $0x08, %al; jz boot_fail                              /* DRQ must be set */
    /* drain the 256-word boot sector into RAM at BOOT_LOAD */
    movl    $256, %ecx; movl $BOOT_LOAD, %edi; movw $0x1F0, %dx
2:  inw     %dx, %ax; stosw; decl %ecx; jnz 2b
    /* (optional) the boot signature is at BOOT_LOAD+510 = 0xAA55, by construction */
    /* hand off: far jmp into the disk-loaded boot sector (cs=0x08, flat 32-bit) */
    .byte   0xEA
    .long   BOOT_LOAD
    .word   0x08

boot_fail:
    /* no DRQ -> the disk read failed; exit with a distinct (non-133) code so the
     * differential FAILS loudly rather than silently draining nothing */
    movb    $0x84, %al; movw $0xF4, %dx; outb %al, %dx
3:  hlt
    jmp     3b

    /* ===================== 16-bit reset stub @ 0xFFF0 ==================== */
    .section .reset,"ax"
    .global _reset
_reset:
    .byte   0xEA                        /* far jmp 0xF000:_start16_off */
    .word   _start16_off
    .word   0xF000
