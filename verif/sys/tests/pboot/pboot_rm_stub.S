/* Ventium M9-rm — REAL-MODE boot-firmware STUB (the -bios image, pboot_rm_stub.bin).
 *
 * The CANONICAL real-mode boot. Unlike M9/pboot (which goes real->protected and loads
 * the boot sector to 0x8000 in flat-32), this firmware STAYS in 16-bit real mode the
 * whole time and chain-loads the boot sector to the canonical real-mode boot address
 * 0000:7C00 — exactly where a PC BIOS drops an MBR:
 *
 *   reset (F000:FFF0) -> 16-bit real mode (NO protected-mode transition) -> set nIEN
 *   FIRST (polled, NO IRQ14 ever) -> READ SECTORS (0x20) disk LBA0 from the IDE primary
 *   master via 16-bit PIO into RAM at 0000:7C00 -> FAR JMP 0x0000:0x7C00 into it.
 *
 * The boot sector (disk LBA0, built by pboot_rm_mbr.S) is 16-bit real-mode code that
 * executes FROM RAM (cs=0, ip=0x7C00) to an observable end-state (signature write +
 * isa-debug-exit). Every step is a synchronous IN/OUT or polled-status read (nIEN set
 * FIRST -> no interrupt is ever delivered), so the whole run is PER-RECORD differentiable
 * under the qemu-system single-step golden, exactly like the M9/M8.4 gates. NO new RTL:
 * it runs on the existing ventium_soc + ven_ide PIO read path + the flat TB memory.
 *
 * This is strictly SIMPLER than M9 (no GDT, no LGDT, no CR0.PE, no PM far-jmp; cr0 stays
 * the reset 0x60000010 for every record). It proves the firmware->MBR handoff at the
 * canonical 0000:7C00 entry the way a real boot sector is actually loaded.
 *
 * Encoding notes (validated against the core's 16-bit decode):
 *  - the drain pointer is loaded with `movl $0x7C00,%edi` (0x66-prefixed) so EDI[31:16]=0;
 *    the string engine advances the FULL 32-bit EDI, which matches qemu's es:di only while
 *    the high half is zero. (EDI is 0 at reset and untouched here, so it is safe regardless,
 *    but the movl pins it edit-robustly.)
 *  - inw/stosw/decw are BARE 16-bit ops (no 0x66) — 16-bit is the real-mode default width.
 *  - the only 16-bit memory addressing used is [disp16]-direct (the core supports just that
 *    real-mode ModR/M form); no register-indirect addressing anywhere.
 */
    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli
    cld
    xorw    %ax, %ax
    movw    %ax, %ds                    /* ds = 0 */
    movw    %ax, %es                    /* es = 0 -> stosw target es:di = 0000:7C00 */
    movw    %ax, %ss
    movw    $0x7C00, %sp                /* stack grows DOWN from 0x7C00 (canonical) */

    /* set nIEN FIRST (0x3F6 bit1) -> polled mode, NO IRQ14 ever delivered */
    movb    $0x02, %al
    movw    $0x3F6, %dx
    outb    %al, %dx

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

    /* drain the 256-word boot sector into es:di = 0000:7C00 */
    movl    $0x00007C00, %edi           /* zero-extend EDI (0x66 movl); see header */
    movw    $256, %cx
    movw    $0x1F0, %dx
2:  inw     %dx, %ax; stosw; decw %cx; jnz 2b

    /* hand off: real-mode FAR JMP to 0x0000:0x7C00 (cs.base=0 -> pc=eip=0x7C00) */
    .byte   0xEA                        /* far jmp ptr16:16 -> EA 00 7C 00 00 */
    .word   0x7C00                      /* offset (ip) */
    .word   0x0000                      /* segment (cs) */

boot_fail:
    /* no DRQ -> the disk read failed; exit with a distinct (non-133) code so the
     * differential FAILS loudly rather than silently handing off to garbage */
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
