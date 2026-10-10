OUTPUT_FORMAT(elf32-i386)
OUTPUT_ARCH(i386)
ENTRY(_start16)
SECTIONS {
    . = 0x10000;
    .start : { KEEP(*(.start)) }
    .text : { *(.text .text.*) }
    .rodata : { *(.rodata .rodata.*) }
    .data : { *(.data .data.*) }
    __load_end = .;
    . = ALIGN(4);
    __bss_start = .;
    .bss (NOLOAD) : { *(.bss .bss.* COMMON) . = ALIGN(4); }
    __bss_end = .;
    /DISCARD/ : { *(.comment .eh_frame .note*) }
}
ASSERT(__load_end - 0x10000 <= 127*512, "payload exceeds one BIOS EDD transfer")
ASSERT(__bss_end < 0x80000, "payload overlaps reserved stack space")
