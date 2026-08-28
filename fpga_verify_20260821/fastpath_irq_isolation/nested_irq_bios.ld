ENTRY(_reset)

IMAGE_BASE = 0x000F0000;

SECTIONS
{
    . = IMAGE_BASE;
    .text16 : { *(.text16) }

    _start16_off = ABSOLUTE(_start16 - IMAGE_BASE);
    irq0_off     = ABSOLUTE(irq0 - IMAGE_BASE);
    soft13_off   = ABSOLUTE(soft13 - IMAGE_BASE);

    . = IMAGE_BASE + 0xFFF0;
    .reset : { *(.reset) }

    . = IMAGE_BASE + 0xFFFF;
    .last : { BYTE(0xFF) }

    /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame*) *(.bss) }
}
