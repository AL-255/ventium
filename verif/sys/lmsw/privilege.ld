ENTRY(_reset)
SECTIONS {
    . = 0xf0000;
    .text16 : { *(.text16) }
    _start16_off = ABSOLUTE(_start16 - 0xf0000);
    .text32 : { *(.text32) }
    .textuser : { *(.textuser) }
    user_entry_off = ABSOLUTE(user_entry - 0xf0000);
    lmsw_probe_off = ABSOLUTE(lmsw_probe - 0xf0000);
    . = 0xffff0;
    .reset : { *(.reset) }
    /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame*) *(.bss) }
}
