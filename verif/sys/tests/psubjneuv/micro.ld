ENTRY(_reset)
IMAGE_BASE = 0x000f0000;
SECTIONS
{
    . = IMAGE_BASE;
    .text16 : { *(.text16) }
    _start16_off = ABSOLUTE(_start16 - IMAGE_BASE);
    .text32 : { *(.text32) }
    ASSERT(. <= IMAGE_BASE + 0x300, "private bootstrap exceeds client offset")
    . = IMAGE_BASE + 0x300;
    .client32 : { *(.client32) }
    _client_rom_off = ABSOLUTE(client - IMAGE_BASE);
    . = IMAGE_BASE + 0x1300;
    .warm_caller32 : { *(.warm_caller32) }
    ASSERT(. <= IMAGE_BASE + 0x3000, "caller overlaps private exception page")
    . = IMAGE_BASE + 0x3000;
    .exception32 : { *(.exception32) }
    ASSERT(. <= IMAGE_BASE + 0x4000, "private logger exceeds mapped page")
    . = IMAGE_BASE + 0x4000;
    .sub32 : { *(.sub32) }
    ASSERT(. == IMAGE_BASE + 0x5000, "new client must be one page")
    .subwarm32 : { *(.subwarm32) }
    ASSERT(. == IMAGE_BASE + 0x6000, "new caller must be one page")
    ASSERT(. < IMAGE_BASE + 0xfff0, "client/callerpage exceed64KiB BIOS payload")
    . = IMAGE_BASE + 0xfff0;
    .reset : { *(.reset) }
    /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame*) *(.bss) *(.data*) *(.text) }
}
