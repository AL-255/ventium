/* Ventium M9 — the BOOT SECTOR (disk LBA0, 512 bytes, pboot_mbr.bin).
 *
 * This is the "OS" the firmware boots: a real boot sector that lives on the IDE
 * disk at LBA0, is read into RAM at 0x8000 by the firmware stub (pboot_stub.S),
 * and is then EXECUTED (the firmware far-jmps to it as cs=0x08, flat 32-bit).
 *
 * It runs in the 32-bit flat segment the stub set up (the simplest boot-sector
 * variant; a 16-bit-real-mode @ 0000:7C00 variant is a documented follow-on). It
 * writes a deterministic 64-bit "I am the booted sector" signature to RAM, then
 * exits via isa-debug-exit. Deterministic + synchronous -> byte-identical to qemu
 * per record. The last two bytes are the 0x55 0xAA boot signature (added by the
 * linker), so disk LBA0 word255 reads 0xAA55.
 */
    .code32
    .section .boot,"ax"
    .global _boot
_boot:
    movl    $0xB007B007, 0x00009000     /* "BOOT" signature word 0 */
    movl    $0x600DCAFE, 0x00009004     /* "GOOD CAFE" signature word 1 */
    /* clean exit via isa-debug-exit: out 0x42 -> qemu status (0x42<<1)|1 = 133 */
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
1:  hlt
    jmp     1b
