/* Diagnostic FreeDOS .COM helper: mask only master-PIC IRQ0.
 * Quake/DJGPP uses a polled high-resolution timer; QEMU validation must prove
 * that the exact 969-frame timedemo still completes before this is used on FPGA.
 */
.code16
.global _start
_start:
    inb  $0x21, %al
    orb  $0x01, %al
    outb %al, $0x21
    ret
