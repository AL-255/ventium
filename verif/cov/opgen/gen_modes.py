#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""Generate the MODE lane: bare-metal opcode streams for the modes the user-mode
(PM32/CPL3) lane cannot reach — REAL mode and PM32/CPL0. These cover the opcodes
whose behaviour DIFFERS by mode/privilege (flag/IF/IOPL ops that diverge in
CPL3, privileged register/system ops that #GP in user mode, 16-bit real-mode
operand defaults). Each is a -bios image run under `tb --system` and diffed,
per-record, against the qemu-system-i386 golden (the same oracle the sys gate
uses) — so the real-mode + CPL0 opcode behaviour is differentially verified.

Outputs verif/cov/opgen/modes/<name>/{<name>.S,.ld,Makefile} (-bios 64 KiB).
"""
from __future__ import annotations
import os

HERE = os.path.dirname(os.path.abspath(__file__))
MODES = os.path.join(HERE, "modes")

# the mode/privilege-sensitive opcode body, real-mode CPL0 (16-bit).
REALMODE_IO = r"""
    /* ---- OUT imm8/DX, IN imm8/DX (E4-E7, EC-EF) at CPL0 real mode -------- */
    /* port 0x80 = POST diagnostic (OUT harmless; IN open-bus). */
    movb    $0x5a, %al
    outb    %al, $0x80              /* OUT imm8, AL */
    movw    $0x00eb, %ax
    outw    %ax, $0x80
    movw    $0x0080, %dx
    movb    $0x33, %al
    outb    %al, %dx                /* OUT DX, AL */
    outw    %ax, %dx
    inb     $0x80, %al              /* IN AL, imm8 */
    inb     %dx, %al                /* IN AL, DX */
    inw     %dx, %ax
"""

REALMODE_FAR = r"""
    /* far transfers, real mode. offset = (label - _start16 + _start16_off):
     * assembly-local difference + the linker segment offset (fits 16-bit). */
    lcallw  $0xF000, $(far_rtn - _start16 + _start16_off)          /* 9A direct far CALL + CB far RET */
    lcallw  $0xF000, $(far_rtn_imm - _start16 + _start16_off)      /* 9A + CA far RET imm16 */
    ljmpw   $0xF000, $(after_fjmp - _start16 + _start16_off)       /* EA direct far JMP */
after_fjmp:
    movw    $(far_rtn - _start16 + _start16_off), 0x640            /* FF/3 indirect far CALL via mem */
    movw    $0xF000, 0x642
    lcallw  *0x640
    movw    $(after_ijmp - _start16 + _start16_off), 0x644         /* FF/5 indirect far JMP via mem */
    movw    $0xF000, 0x646
    ljmpw   *0x644
after_ijmp:
    jmp     past_rtns
far_rtn:
    lretw
far_rtn_imm:
    lretw   $0
past_rtns:
"""

REALMODE_INT = r"""
    /* set up real-mode IVT entries -> a handler in this segment (CS=0xF000).
     * the 16-bit offset is (handler - _start16 + _start16_off): a section-local
     * difference (assembly-time) plus the linker-computed segment offset. */
    movw    $(handler - _start16 + _start16_off), %ax
    movw    %ax, 0x100        /* IVT[0x40].off (vec*4 = 0x40*4) */
    movw    $0xF000, 0x102    /* IVT[0x40].seg */
    movw    %ax, 0x0c         /* IVT[3].off  (INT3) */
    movw    $0xF000, 0x0e
    movw    %ax, 0x10         /* IVT[4].off  (INTO) */
    movw    $0xF000, 0x12
    /* ---- INT n (CD 40) -> push flags:cs:ip, vector to handler, IRET back -- */
    int     $0x40
    /* ---- INT3 (CC) ----------------------------------------------------- */
    int3
    /* ---- INTO (CE): set OF then INTO (taken) --------------------------- */
    movb    $0x7f, %al
    addb    $0x7f, %al        /* OF=1 */
    into
    /* ---- INTO with OF=0 (not taken, falls through) --------------------- */
    xorb    %al, %al
    into
    jmp     int_done
handler:
    iret                      /* CF: pop ip:cs:flags */
int_done:
"""

REALMODE_PRIV = r"""
    /* ---- MOV r32, CRn / CRn, r32 (0F 20/22) privileged, CPL0 ------------- */
    movl    %cr0, %eax
    movl    %eax, %cr0
    movl    %cr2, %ebx
    movl    %ebx, %cr2
    movl    %cr3, %ecx
    movl    %ecx, %cr3
    movl    %cr4, %edx
    movl    %edx, %cr4
    /* ---- MOV r32, DRn / DRn, r32 (0F 21/23) ----------------------------- */
    movl    %dr0, %eax
    movl    %dr1, %ebx
    movl    %dr2, %ecx
    movl    %dr3, %edx
    movl    %dr6, %esi
    movl    %dr7, %edi
    movl    %edi, %dr7
    /* ---- INVLPG (no arch reg effect; CLTS/WBINVD/INVD gated-> cosim lane) ----- */
    /* ---- LGDT / LIDT (load from a 6-byte pseudo-descriptor in low RAM) --- */
    movw    $0x00ff, 0x630
    movl    $0x00010000, 0x632
    lgdtl   0x630
    lidtl   0x630
"""

REALMODE_SEG = r"""
    /* ---- MOV Sreg <-> r/m (8C/8E) — selector reads/loads (real mode) ----- */
    movw    %ds, %ax
    movw    %es, %bx
    movw    %ss, %cx
    movw    %cs, %dx
    movw    %ax, %es
    movw    %ax, %ds
    /* ---- segment loads LDS/LES/LSS/LFS/LGS (real-mode far ptr in RAM) ----- */
    movw    $0x1000, 0x600           /* offset */
    movw    $0x2000, 0x602           /* segment */
    lds     0x600, %si
    les     0x600, %di
    lss     0x600, %bp
    lfs     0x600, %si
    lgs     0x600, %di
    /* ---- SGDT / SIDT to memory (non-privileged) -------------------------- */
    sgdt    0x610
    sidt    0x618
    /* ---- conversions CBW/CWD/CWDE/CDQ ------------------------------------- */
    movw    $0xff80, %ax
    cbtw                              /* CBW (AL->AX) */
    cwtd                              /* CWD (AX->DX:AX) */
    cwtl                              /* CWDE */
    cltd                              /* CDQ */
    /* ---- BCD adjust DAA/DAS/AAA/AAS --------------------------------------- */
    movw    $0x9a, %ax
    daa
    movw    $0x9a, %ax
    das
    movw    $0x010a, %ax
    aaa
    movw    $0x010a, %ax
    aas
"""

REALMODE_BODY = r"""
    /* ---- flag ops (CLC/STC/CMC/CLD/STD/CLI/STI) — IF/DF/CF differ by mode -- */
    stc
    clc
    cmc
    cmc
    cld
    std
    cld
    cli
    sti
    cli
    /* ---- LAHF / SAHF / PUSHF / POPF (full + IOPL behaviour) -------------- */
    lahf
    sahf
    pushf
    popf
    pushfl
    popfl
    /* ---- 16-bit real-mode ALU / MOV (operand-size defaults differ) ------- */
    movw    $0x1234, %ax
    addw    $0x1111, %ax
    movw    $0x00ff, %bx
    andw    %bx, %ax
    orw     $0xf000, %ax
    xorw    %bx, %bx
    incw    %cx
    decw    %dx
    shlw    $3, %ax
    sarw    $1, %ax
    rolw    $4, %bx
    /* ---- privileged register reads (work at CPL0; #GP in user mode) ------ */
    smsww   %ax                 /* SMSW — read CR0 low 16 (non-priv read) */
    movl    %cr0, %eax          /* MOV r32, CR0  (privileged) */
    movl    %eax, %cr0          /* write it back unchanged */
    movl    %dr7, %ebx          /* MOV r32, DR7  (privileged) */
"""


def write_image(name, code16_body):
    d = os.path.join(MODES, name)
    os.makedirs(d, exist_ok=True)
    S = f"""/* Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * GENERATED by gen_modes.py — {name}: mode/privilege-sensitive opcode stream.
 */
    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli
    cld
    xorw    %ax, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    $0x7000, %sp
{code16_body}
    /* isa-debug-exit: out 0xf4, al=0x42 -> status 133 */
    movb    $0x42, %al
    movw    $0xF4, %dx
    outb    %al, %dx
1:  hlt
    jmp     1b

    .section .reset,"ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
"""
    open(os.path.join(d, f"{name}.S"), "w").write(S)
    _emit_ld_mk(d, name)
    print(f"mode image: modes/{name}/{name}.S")


def _emit_ld_mk(d, name):
    # linker script + Makefile (-bios 64 KiB layout) — shared by real-mode and
    # protected-mode images (identical section layout: .text16/.text32/.reset).
    ld = """ENTRY(_reset)
IMAGE_BASE = 0x000F0000;
SECTIONS {
  . = IMAGE_BASE;
  .text16 : { *(.text16) }
  _start16_off = ABSOLUTE(_start16 - IMAGE_BASE);
  .text32 : { . = ALIGN(16); *(.text32) *(.text) *(.rodata*) *(.data*) }
  . = IMAGE_BASE + 0xFFF0;
  .reset : { *(.reset) }
  /DISCARD/ : { *(.note*) *(.comment) *(.eh_frame*) *(.bss) }
}
"""
    open(os.path.join(d, f"{name}.ld"), "w").write(ld)
    mk = f"""CC ?= gcc
OBJCOPY ?= objcopy
CFLAGS := -m32 -ffreestanding -nostdlib -fno-pic -fno-pie -Wall
all: {name}.bin
{name}.o: {name}.S
\t$(CC) $(CFLAGS) -c $< -o $@
{name}.elf: {name}.o {name}.ld
\t$(CC) $(CFLAGS) -static -no-pie -nostdlib -Wl,-T,{name}.ld -Wl,--build-id=none {name}.o -o {name}.elf
{name}.bin: {name}.elf
\t$(OBJCOPY) -O binary {name}.elf {name}.bin
\t@truncate -s 65536 {name}.bin
clean:
\trm -f {name}.o {name}.elf {name}.bin
.PHONY: all clean
"""
    open(os.path.join(d, "Makefile"), "w").write(mk)


# PM32/CPL0 body: the PROTECTED-mode-only opcodes the real-mode lane can't reach
# (segment access-rights/limit/verify ops need a live GDT), run at CPL0.
PM32_BODY = r"""
    /* ---- CLI/STI/POPF at CPL0 IN PROTECTED MODE (IOPL semantics) -------- */
    pushfl
    cli
    sti
    popfl
    /* ---- MOV CR/DR in protected mode ----------------------------------- */
    movl    %cr0, %eax
    movl    %cr3, %ebx
    movl    %dr7, %ecx
    /* ---- enable PAGING (PSE 4 MiB identity map): covers the paging-on
     * decode + a paged load/store ----------------------------------------- */
    movl    $0x00010000, %edi
    pushl   %edi
    movl    $1024, %ecx
    xorl    %eax, %eax
    rep stosl                        /* zero the page directory */
    popl    %edi
    movl    $0x00000083, (%edi)      /* PDE0 = identity [0,4MiB) large page (P|RW|PS) */
    movl    %cr4, %eax
    orl     $0x10, %eax
    movl    %eax, %cr4               /* CR4.PSE=1 */
    movl    $0x00010000, %eax
    movl    %eax, %cr3               /* page-directory base */
    movl    %cr0, %eax
    orl     $0x80000000, %eax
    movl    %eax, %cr0               /* CR0.PG=1 -> paging ON */
    movl    $0x12345678, %eax
    movl    %eax, 0x00080000         /* paged store (identity-mapped) */
    movl    0x00080000, %esi         /* read back -> esi = 0x12345678 */
    /* NOTE: LAR/LSL/VERR/VERW/ARPL/SLDT/STR/LLDT/LTR (the 0F 00/02/03 descriptor
     * op group) HALT the core (unimplemented) -> cataloged in known_diverge.txt;
     * excluded here so the PM-entry + working-op stream stays clean. */
"""


def write_pm_image(name, body32):
    d = os.path.join(MODES, name)
    os.makedirs(d, exist_ok=True)
    S = f"""/* GENERATED by gen_modes.py — {name}: PROTECTED-mode CPL0 opcode stream.
 * SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1 */
    .code16
    .section .text16,"ax"
    .global _start16
_start16:
    cli
    cld
    xorw    %ax, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    $0x7000, %sp
    movl    $0x00000500, %ebx
    movl    $0, (%ebx)
    movl    $0, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)
    movl    $0x00CF9200, 20(%ebx)
    movw    $0x0017, 0x0480
    movl    $0x00000500, 0x0482
    lgdt    0x0480
    movl    %cr0, %eax
    orl     $0x1, %eax
    movl    %eax, %cr0
    .byte   0x66, 0xEA
    .long   pm32_entry
    .word   0x08

    .code32
    .section .text32,"ax"
    .global pm32_entry
pm32_entry:
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    %ax, %fs
    movw    %ax, %gs
    movl    $0x00090000, %esp
{body32}
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx
1:  hlt
    jmp     1b

    .code16
    .section .reset,"ax"
    .global _reset
_reset:
    .byte   0xEA
    .word   _start16_off
    .word   0xF000
"""
    open(os.path.join(d, f"{name}.S"), "w").write(S)
    _emit_ld_mk(d, name)
    print(f"PM32 mode image: modes/{name}/{name}.S")


def main():
    os.makedirs(MODES, exist_ok=True)
    write_image("realmode_flags", REALMODE_BODY)
    write_image("realmode_seg", REALMODE_SEG)
    write_image("realmode_priv", REALMODE_PRIV)
    write_image("realmode_int", REALMODE_INT)
    write_image("realmode_far", REALMODE_FAR)
    write_pm_image("pm32_cpl0", PM32_BODY)


if __name__ == "__main__":
    main()
