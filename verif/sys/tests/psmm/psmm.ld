/* Ventium M2S.5 — linker script for the bare-metal SMM / RSM image.
 *
 * Identical layout strategy to the M2S.0 pmode / M2S.1 pseg / ... images: a flat
 * 64 KiB BIOS image.  qemu-system-i386 -bios maps it so the last byte is at
 * physical 0x000FFFFF; the reset vector is CS:EIP=F000:FFF0 (linear 0x000FFFF0).
 *   - the image base linear address is 0x000F0000 (= 0x100000 - 0x10000)
 *   - .reset (the 16-bit reset stub) lands at linear 0x000FFFF0 = image off 0xFFF0
 *   - .text16 (the 16-bit entry) + the 32-bit body + the SMM handler bytes sit
 *     early in the image, within the 0xF000 real-mode segment so the reset
 *     ljmp $0xF000,$off reaches them, and within the flat 32-bit code segment
 *     (base 0) so $smm_handler is a full 0x000Fxxxx linear address that the
 *     mainline `rep movsb` copies to SMBASE+0x8000 (0x38000).
 *
 * NO paging in psmm, so all linear addresses are physical; the GDT (0x500) /
 * sentinels (0x2000) / SMRAM (0x30000) / stack (0x90000) / APIC MMIO
 * (0xFEE00000) all live outside the 0x000Fxxxx image window.
 */
ENTRY(_reset)

IMAGE_BASE = 0x000F0000;   /* linear base of a 64 KiB -bios image */

SECTIONS
{
    . = IMAGE_BASE;

    .text16 : {
        *(.text16)
    }

    /* segment-relative offset of the real-mode entry inside segment 0xF000,
     * computed at link time as an ABSOLUTE constant so the reset stub's hand-
     * encoded far jump can use a 16-bit immediate that already fits. */
    _start16_off = ABSOLUTE(_start16 - IMAGE_BASE);

    .text32 : {
        . = ALIGN(16);
        *(.text32)
        *(.text)
        *(.rodata*)
        *(.data*)
    }

    /* The reset stub goes at the very end: image offset 0xFFF0 == linear FFFF0. */
    . = IMAGE_BASE + 0xFFF0;
    .reset : {
        *(.reset)
    }

    /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame*) *(.bss) }
}
