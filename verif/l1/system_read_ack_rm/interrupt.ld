OUTPUT_FORMAT("elf32-i386")
OUTPUT_ARCH(i386)
ENTRY(_start)
SECTIONS {
    . = 0xf0000;
    .text : { *(.text) }
    start_off = ABSOLUTE(_start - 0xf0000);
    outer_off = ABSOLUTE(outer - 0xf0000);
    inner_off = ABSOLUTE(inner - 0xf0000);
    . = 0xffff0;
    .reset : { *(.reset) }
    /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame*) *(.bss) }
}
