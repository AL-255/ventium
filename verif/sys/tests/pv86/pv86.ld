/* Ventium M7.2 — linker script for the bare-metal VIRTUAL-8086 (V86) image.
 *
 * Identical layout strategy to the M2S.3 pfault / M2S.4 pcpl / M2S.6 pdebug
 * images: a flat 64 KiB BIOS image.  qemu-system-i386 -bios maps it so the last
 * byte is at physical 0x000FFFFF and the whole image is aliased at the top of
 * the 32-bit space; the reset vector is CS:EIP=F000:FFF0 (linear 0x000FFFF0).  So:
 *   - the image base linear address is 0x000F0000 (= 0x100000 - 0x10000)
 *   - .reset (the 16-bit reset stub) must land at linear 0x000FFFF0, i.e. image
 *     offset 0xFFF0
 *   - .text16 (the 16-bit entry) + the 32-bit monitor body + the #GP handler sit
 *     early in the image, all within the 0xF000 real-mode segment so
 *     `ljmp $0xF000,$off` reaches them, and all in the flat 32-bit code segment
 *     (base 0) so the IDT gate offset ($gp_handler) is a full 0x000Fxxxx linear
 *     address.
 *
 * The V86 task code (.text_v86) is placed in a LOW, page-aligned window at linear
 * 0x00010000 (segment 0x1000:0000 in V86 sel<<4 addressing) so the V86 task runs
 * with CS=0x1000 and small 16-bit offsets.  It is a SEPARATE output section whose
 * VMA is the V86 linear address; the loader (objcopy -O binary) flattens the image
 * so the bytes land at file offset = VMA - IMAGE_BASE.  Because 0x00010000 is BELOW
 * IMAGE_BASE (0x000F0000), we instead COPY the V86 task into low RAM at run time
 * from a copy that lives in the high BIOS image (see _v86_blob_* below) — the
 * monitor memcpy's the blob to linear 0x00010000 before entering V86.
 *
 * Paging IS enabled in pv86 (V86 mode is PE=1 & PG=1).  The identity page table
 * maps the low 1 MiB 1:1 (covering the V86 task window 0x00010000, the page
 * tables, GDT/IDT/TSS/markers, and the stacks) plus the code window 0x000Fxxxx, so
 * EIP stays valid across CR0.PG 0->1 and across the V86 entry.
 */
ENTRY(_reset)

IMAGE_BASE = 0x000F0000;   /* linear base of a 64 KiB -bios image */

SECTIONS
{
    . = IMAGE_BASE;

    .text16 : {
        *(.text16)
    }

    _start16_off = ABSOLUTE(_start16 - IMAGE_BASE);

    .text32 : {
        . = ALIGN(16);
        *(.text32)
        *(.text)
        *(.rodata*)
        *(.data*)
    }

    /* The V86 task body, assembled as 16-bit code, runs at linear 0x00010000
     * (V86 segment 0x1000, offset 0).  We give the section a VMA at the RUN-TIME
     * base (0x00010000) so every label inside resolves to a small 16-bit offset
     * within segment 0x1000 — exactly what the V86 task needs.  But its LOAD
     * address (LMA, where objcopy -O binary actually places the bytes in the BIOS
     * image) is kept HIGH, right after .text32, so the bytes live in the 64 KiB
     * image; the monitor memcpy's the blob from its image location down to linear
     * 0x00010000 before entering V86.  _v86_lma is the image-resident source.    */
    V86_RUN_BASE = 0x00010000;
    _v86_lma = . ;
    .text_v86 V86_RUN_BASE : AT (_v86_lma) {
        _v86_blob_start = . ;
        *(.text_v86)
        _v86_blob_end = . ;
    }
    _v86_blob_len = ABSOLUTE(_v86_blob_end - _v86_blob_start);
    . = _v86_lma + SIZEOF(.text_v86);

    . = IMAGE_BASE + 0xFFF0;
    /* Pin the reset stub's LOAD address (LMA) to image offset 0xFFF0 explicitly.
     * Without AT(), the preceding .text_v86 AT(_v86_lma) leaves the LMA region's
     * implicit counter pointing past the V86 blob, so .reset would inherit a LMA
     * far outside the 64 KiB image and objcopy -O binary would TRUNCATE the reset
     * stub off (leaving 0xFFF0 zero-filled). AT(IMAGE_BASE+0xFFF0) places the 5
     * reset bytes at file offset 0xFFF0 so the `ljmp $0xF000,$_start16_off` is real. */
    .reset (IMAGE_BASE + 0xFFF0) : AT (IMAGE_BASE + 0xFFF0) {
        *(.reset)
    }

    /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame*) *(.bss) }
}
