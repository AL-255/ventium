/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 */

/* Ventium M9b — DMA boot-firmware STUB (the -bios image, pboot_dma_stub.bin).
 *
 * Same "smallest real boot" idea as pboot_stub.S (M9), but the firmware chain-loads
 * the boot sector with BUS-MASTER DMA instead of programmed I/O:
 *
 *   reset (F000:FFF0) -> 16-bit real mode -> protected mode (flat 32-bit GDT) ->
 *   set nIEN (polled, NO IRQ14 ever) -> enable PCI_COMMAND.IO|bus-master + map the
 *   BMIDE BAR4 (0xCF8/0xCFC) -> build one EOT PRD pointing at RAM 0x8000 -> issue
 *   READ DMA (0xC8) of disk LBA0 -> poll BMIS DMAING to completion -> FAR JMP 0x8000.
 *
 * The bus-master engine writes the boot sector straight into RAM at 0x8000 (NO CPU
 * inw drain); the firmware then far-jmps INTO it (fetch-after-DMA-write). The boot
 * sector (disk LBA0, pboot_mbr.bin — SAME sector the PIO M9 gate uses) executes from
 * RAM to a signature write + isa-debug-exit.
 *
 * This reuses the EXACT M8.4f single-PRD READ-DMA recipe (the only DMA shape that is
 * single-step differentiable: a single-PRD single-sector cached READ completes INLINE
 * in qemu's block layer, so the gen_trace single-step golden — which has no main-loop
 * AIO pump — still advances; multi-sector / multi-PRD / WRITE DMA do NOT, see
 * memory/m84f-dma-plan.md). Every step is a synchronous IN/OUT or polled-status read
 * (nIEN set FIRST -> no IRQ14), so the whole run is PER-RECORD differentiable under
 * the qemu-system single-step golden. NO new RTL: it runs on the existing
 * ventium_soc + ven_ide DMA engine + the PCI shim + the flat TB memory (2-master mux).
 *
 * vs pboot_stub.S (PIO): identical boot/handoff, but the load uses the bus-master
 * mem-master port — so this gate additionally proves the DMA write into the executed
 * region is coherent with the subsequent instruction fetch from that region.
 */
    .equ BOOT_LOAD, 0x00008000      /* DMA target = where the boot sector lands     */
    .equ GDT_BASE,  0x00000500      /* flat GDT in low RAM                           */
    .equ PRD_TBL,   0x00005000      /* PRD table (8 bytes, dword-aligned)            */

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

    /* --- make the BMIDE block decodable: BAR4=0xC000 + PCI_COMMAND.IO|bus-master ---
     * (the same 0xCF8/0xCFC config writes the pide M8.4f-pre block proved). The IDE
     * function is bus0 devfn 0x09; cs_bmide gates the 0xC000 window on PCI_COMMAND.IO. */
    movl    $0x80000920, %eax; movw $0xCF8, %dx; outl %eax, %dx   /* CONFIG_ADDRESS: devfn 0x09 reg 0x20 (BAR4) */
    movl    $0x0000C000, %eax; movw $0xCFC, %dx; outl %eax, %dx   /* BAR4 = 0xC000 */
    movl    $0x80000904, %eax; movw $0xCF8, %dx; outl %eax, %dx   /* CONFIG_ADDRESS: devfn 0x09 reg 0x04 (COMMAND) */
    movw    $0x0005, %ax;      movw $0xCFC, %dx; outw %ax, %dx    /* COMMAND = IO(bit0)|bus-master(bit2) */

    /* --- build one EOT PRD @0x5000 describing the 512-byte boot sector at 0x8000 ---
     * dword0 = buffer base 0x00008000 ; dword1 = EOT(bit31)|count(512) = 0x80000200 */
    movl    $BOOT_LOAD,   PRD_TBL
    movl    $0x80000200,  PRD_TBL+4

    /* pre-fill the DMA target (0x8000) with a 0xFFFFFFFF sentinel — distinct from both
     * the disk content (0x0000..0xAA55) and any valid opcode stream: if the DMA failed
     * to move the sector, the far-jmp would fetch the sentinel and diverge/never exit,
     * so a no-op DMA can never silently pass. The 512-byte sector fully overwrites it. */
    movl    $128, %ecx
    movl    $BOOT_LOAD, %edi
    movl    $0xFFFFFFFF, %eax
1:  movl    %eax, (%edi); addl $4, %edi; decl %ecx; jnz 1b

    /* program BMIDTP (BAR4+4 = 0xC004) = PRD table address */
    movl    $PRD_TBL, %eax; movw $0xC004, %dx; outl %eax, %dx

    /* task file: nsector=1, LBA=0, devhead 0xE0 (LBA|master) ; issue READ DMA (0xC8) */
    movb    $0x01, %al; movw $0x1F2, %dx; outb %al, %dx
    xorb    %al, %al
    movw    $0x1F3, %dx; outb %al, %dx
    movw    $0x1F4, %dx; outb %al, %dx
    movw    $0x1F5, %dx; outb %al, %dx
    movb    $0xE0, %al; movw $0x1F6, %dx; outb %al, %dx
    movb    $0xC8, %al; movw $0x1F7, %dx; outb %al, %dx

    /* launch: BMIC (BAR4+0 = 0xC000) = START(0x01)|RWCON-READ(0x08) = 0x09 */
    movb    $0x09, %al; movw $0xC000, %dx; outb %al, %dx

    /* poll BMIS (BAR4+2 = 0xC002) until DMAING (bit0) clears -> the sector is in RAM */
1:  movw    $0xC002, %dx; inb %dx, %al; testb $0x01, %al; jnz 1b
    /* loud guard: if BMIS ERROR (bit1) is set the DMA failed -> bail (non-133 exit) */
    testb   $0x02, %al; jnz boot_fail

    /* hand off: far jmp into the DMA-loaded boot sector (cs=0x08, flat 32-bit).
     * This FETCHES from RAM the bus-master engine just wrote -> the gate proves the
     * DMA-write/instruction-fetch coherency, not just a PIO drain. */
    .byte   0xEA
    .long   BOOT_LOAD
    .word   0x08

boot_fail:
    /* DMA error -> exit with a distinct (non-133) code so the differential FAILS
     * loudly rather than handing off to garbage */
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
