ENTRY(_reset)
SECTIONS {
    . = 0xf0000;
    .text16 : { *(.text16) }
    _start16_off = ABSOLUTE(_start16 - 0xf0000);
    fail16_off = ABSOLUTE(fail16 - 0xf0000);
    nm16_off = ABSOLUTE(nm16 - 0xf0000);
    probe_off = ABSOLUTE(probe - 0xf0000);
    . = 0xffff0;
    .reset : { *(.reset) }
    /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame*) *(.bss) }
}
