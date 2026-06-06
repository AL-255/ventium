/* Ventium M9-rm — the 16-bit REAL-MODE BOOT SECTOR (disk LBA0, 512 bytes, pboot_rm_mbr.bin).
 *
 * The "OS" the real-mode firmware boots: a real boot sector that lives on the IDE disk at
 * LBA0, is read into RAM at 0000:7C00 by pboot_rm_stub.S, and is then EXECUTED (the firmware
 * far-jmps to it as cs=0, ip=0x7C00 — the canonical PC boot entry). It runs in 16-bit real
 * mode; ds is already 0 (set by the firmware), so the absolute stores below resolve to
 * physical 0x9000/0x9004.
 *
 * It writes a deterministic 64-bit signature DISTINCT from M9's (so a trace can tell the
 * real-mode boot apart from the PIO/DMA flat-32 boots), then exits via isa-debug-exit. The
 * last two bytes are the 0x55 0xAA boot signature (added by the linker), so disk LBA0
 * word255 reads 0xAA55.
 *
 * Encoding notes: `movl $imm32,disp16` in .code16 emits a 0x66 operand-size prefix + a
 * [disp16]-direct EA (mod=00, rm=110) — the only 16-bit memory-addressing form the core
 * decodes — and 0x9000/0x9004 fit a 16-bit displacement with ds=0 (no 0x67). No
 * register-indirect addressing is used anywhere.
 */
    .code16
    .section .boot,"ax"
    .global _boot
_boot:
    movl    $0x7C00B007, 0x00009000     /* real-mode "BOOT@7C00" signature word 0 */
    movl    $0x600DF00D, 0x00009004     /* "GOOD FOOD"          signature word 1 */
    /* clean exit via isa-debug-exit: out 0x42 -> qemu status (0x42<<1)|1 = 133 */
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
1:  hlt
    jmp     1b
