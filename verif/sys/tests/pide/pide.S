/* Ventium M8.4a — bare-metal SoC IDE/ATA differential test (PIO, primary master).
 *
 * This is the M8.4a SoC-integration gate test. It exercises the IDE/ATA device
 * M8.4 wires into ventium_soc — the primary command block (0x1F0-0x1F7) + the
 * control block (0x3F6), one drive (primary MASTER, unit 0), PIO mode only.
 *
 * --------------------------------------------------------------------------
 * FULL PER-RECORD DIFFERENTIAL (like pvga/psocdev, stronger than pirqsoc):
 * --------------------------------------------------------------------------
 * The test sets nIEN (0x3F6 bit1) FIRST, so NO IRQ14 is ever delivered — every
 * device interaction is a SYNCHRONOUS IN/OUT or a POLLED-status read. qemu's
 * gdbstub single-step (gen_trace.py --system) IS a valid per-record oracle (the
 * SSTEP_NOIRQ HW-IRQ masking is structurally irrelevant: no IRQ is raised). The
 * gate is plain compare.py EQUIVALENT, running on ventium_soc with -drive
 * if=ide,format=raw,index=0,file=pide.img (the SAME image ven_ide $readmemh's).
 *
 * What it grades byte-identical vs qemu-system-i386 8.2.2 over every instruction:
 *   - RESET SIGNATURE: status=0x50, error=0x00, nsector=1, sector=1, lcyl=0,
 *     hcyl=0, devhead=0xA0, alt-status(0x3F6)=0x50 (== status, no IRQ side effect)
 *   - ABSENT SLAVE: select unit1 (0x1F6 bit4=1); status(0x1F7)/error(0x1F1)/
 *     alt-status(0x3F6) read 0x00 (qemu masks only these for the absent selected
 *     slave); reselect master
 *   - IDENTIFY DEVICE (0xEC): 256 words via inw, COMPARED per-record (geometry
 *     words 0/1/3/6/.., feature words, the config-pinned model/serial/fw strings)
 *   - READ SECTORS (0x20) LBA 0 and LBA 127: 256 words each via inw, byte-
 *     identical to the single-source disk image (proves LBA->offset addressing
 *     on a non-zero, non-adjacent LBA; sector-0 last word = 0xAA55 boot sig)
 *   - EXECUTE DEVICE DIAGNOSTIC (0x90): error=0x01 (passed), status=0x50,
 *     devhead=0xA0 (ATA_DEV_ALWAYS_ON)
 *
 * Data port: read with `inw %dx,%ax` (16-bit, opcode 66 ED — decoded under
 * soc_en; `insw`/`rep insw` is gated on cosim_en in the decoder so it is NOT
 * used). Each inw advances ven_ide's word pointer by one; the read value lands
 * in AX and is graded per-record. `stosw` stores it to the in-RAM block for the
 * self-documenting end-state.
 *
 * Memory plan (machine -m 32; NO paging, linear==physical):
 *   GDT     @ 0x00000500    results @ 0x00002000    stack @ 0x00090000
 *   IDENTIFY block @ 0x00004000 ; sector0 @ 0x00004200 ; sector127 @ 0x00004400
 *
 * Build: gcc -m32 -ffreestanding -nostdlib (see Makefile); objcopy -O binary,
 * padded to 64 KiB. GNU-as (AT&T) syntax.
 */

    .equ R_SIG_ST,   0x00002000  /* signature status     = 0x50 */
    .equ R_SIG_ERR,  0x00002004  /* signature error      = 0x00 */
    .equ R_SIG_NS,   0x00002008  /* signature nsector    = 0x01 */
    .equ R_SIG_SEC,  0x0000200C  /* signature sector     = 0x01 */
    .equ R_SIG_LC,   0x00002010  /* signature lcyl       = 0x00 */
    .equ R_SIG_HC,   0x00002014  /* signature hcyl       = 0x00 */
    .equ R_SIG_DH,   0x00002018  /* signature devhead    = 0xA0 */
    .equ R_SIG_ALT,  0x0000201C  /* alt-status (0x3F6)   = 0x50 */
    .equ R_SLV_ST,   0x00002020  /* absent slave status  = 0x00 */
    .equ R_SLV_ERR,  0x00002024  /* absent slave error   = 0x00 */
    .equ R_SLV_ALT,  0x00002028  /* absent slave altstat = 0x00 */
    .equ R_ID_ST,    0x0000202C  /* status after IDENTIFY drain = 0x50 */
    .equ R_RD0_ST,   0x00002030  /* status after READ LBA0 drain = 0x50 */
    .equ R_RD127_ST, 0x00002034  /* status after READ LBA127 drain = 0x50 */
    .equ R_DIAG_ERR, 0x00002038  /* diagnostic error     = 0x01 */
    .equ R_DIAG_ST,  0x0000203C  /* diagnostic status    = 0x50 */
    .equ R_DIAG_DH,  0x00002040  /* diagnostic devhead   = 0xA0 */
    .equ R_MS_ST,    0x00002044  /* status after multi-sector drain = 0x50 */

    .equ BUF_ID,     0x00004000  /* IDENTIFY 512-byte block       */
    .equ BUF_S0,     0x00004200  /* sector 0   block              */
    .equ BUF_S127,   0x00004400  /* sector 127 block              */
    .equ BUF_MS,     0x00004600  /* multi-sector (2 x 512 = 1024) block */

    .code16
    .section .text16, "ax"
    .global _start16
_start16:
    cli
    cld
    xorw    %ax, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    $0x7000, %sp

    /* --- flat GDT (null + code32 0x08 + data32 0x10) @ 0x0500 --- */
    movl    $0x00000500, %ebx
    movl    $0x00000000, 0(%ebx)
    movl    $0x00000000, 4(%ebx)
    movl    $0x0000FFFF, 8(%ebx)        /* code32 */
    movl    $0x00CF9A00, 12(%ebx)
    movl    $0x0000FFFF, 16(%ebx)       /* data32 */
    movl    $0x00CF9200, 20(%ebx)

    movw    $0x0017, 0x0480
    movl    $0x00000500, 0x0482
    lgdt    0x0480

    movl    %cr0, %eax
    orl     $0x1, %eax
    movl    %eax, %cr0

    .byte   0x66, 0xEA                  /* far jmp 0x08:pm32_entry */
    .long   pm32_entry
    .word   0x08

    .code32
    .section .text32, "ax"
    .global pm32_entry
pm32_entry:
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    %ax, %fs
    movw    %ax, %gs
    movl    $0x00090000, %esp

    /* ============ set polled mode (nIEN) — no IRQ ever delivered ========= */
    movb    $0x02, %al                  /* device control: nIEN (bit1)=1 */
    movw    $0x3F6, %dx
    outb    %al, %dx

    /* ============ select primary MASTER + read RESET SIGNATURE =========== */
    movb    $0xA0, %al                  /* devhead: unit0 (master), ALWAYS_ON */
    movw    $0x1F6, %dx
    outb    %al, %dx

    movw    $0x1F7, %dx                 /* status */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_SIG_ST
    movw    $0x1F1, %dx                 /* error */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_SIG_ERR
    movw    $0x1F2, %dx                 /* nsector */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_SIG_NS
    movw    $0x1F3, %dx                 /* sector */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_SIG_SEC
    movw    $0x1F4, %dx                 /* lcyl */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_SIG_LC
    movw    $0x1F5, %dx                 /* hcyl */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_SIG_HC
    movw    $0x1F6, %dx                 /* devhead */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_SIG_DH
    movw    $0x3F6, %dx                 /* alt-status (no IRQ side effect) */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_SIG_ALT

    /* ============ ABSENT SLAVE: status/error/altstatus read 0x00 ========= */
    movb    $0xB0, %al                  /* devhead: unit1 (slave, ABSENT) */
    movw    $0x1F6, %dx
    outb    %al, %dx
    movw    $0x1F7, %dx                 /* status -> 0x00 (absent) */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_SLV_ST
    movw    $0x1F1, %dx                 /* error -> 0x00 */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_SLV_ERR
    movw    $0x3F6, %dx                 /* alt-status -> 0x00 */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_SLV_ALT
    movb    $0xA0, %al                  /* reselect master */
    movw    $0x1F6, %dx
    outb    %al, %dx

    /* ============ IDENTIFY DEVICE (0xEC) ================================= */
    movb    $0xEC, %al
    movw    $0x1F7, %dx
    outb    %al, %dx
    /* poll: wait BSY=0 then require DRQ=1 */
1:  movw    $0x1F7, %dx
    inb     %dx, %al
    testb   $0x80, %al                  /* BSY */
    jnz     1b
    testb   $0x08, %al                  /* DRQ */
    jz      fail
    /* drain 256 words from the data port (0x1F0) into BUF_ID */
    movl    $256, %ecx
    movl    $BUF_ID, %edi
    movw    $0x1F0, %dx
2:  inw     %dx, %ax                    /* word -> AX (graded per-record) */
    stosw                               /* AX -> ES:[EDI], EDI += 2 */
    decl    %ecx
    jnz     2b
    movw    $0x1F7, %dx                 /* status after drain -> 0x50 */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_ID_ST

    /* ============ READ SECTORS (0x20) LBA 0 ============================= */
    movb    $1, %al                     /* nsector = 1 */
    movw    $0x1F2, %dx
    outb    %al, %dx
    movb    $0, %al                     /* LBA[7:0] = 0 */
    movw    $0x1F3, %dx
    outb    %al, %dx
    movb    $0, %al                     /* LBA[15:8] = 0 */
    movw    $0x1F4, %dx
    outb    %al, %dx
    movb    $0, %al                     /* LBA[23:16] = 0 */
    movw    $0x1F5, %dx
    outb    %al, %dx
    movb    $0xE0, %al                  /* devhead: LBA(0x40)|master|LBA[27:24]=0 */
    movw    $0x1F6, %dx
    outb    %al, %dx
    movb    $0x20, %al                  /* READ SECTORS */
    movw    $0x1F7, %dx
    outb    %al, %dx
1:  movw    $0x1F7, %dx
    inb     %dx, %al
    testb   $0x80, %al
    jnz     1b
    testb   $0x08, %al
    jz      fail
    movl    $256, %ecx
    movl    $BUF_S0, %edi
    movw    $0x1F0, %dx
2:  inw     %dx, %ax
    stosw
    decl    %ecx
    jnz     2b
    movw    $0x1F7, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_RD0_ST

    /* ============ READ SECTORS (0x20) LBA 127 (non-adjacent) ============ */
    movb    $1, %al
    movw    $0x1F2, %dx
    outb    %al, %dx
    movb    $127, %al                   /* LBA[7:0] = 127 */
    movw    $0x1F3, %dx
    outb    %al, %dx
    movb    $0, %al
    movw    $0x1F4, %dx
    outb    %al, %dx
    movb    $0, %al
    movw    $0x1F5, %dx
    outb    %al, %dx
    movb    $0xE0, %al
    movw    $0x1F6, %dx
    outb    %al, %dx
    movb    $0x20, %al
    movw    $0x1F7, %dx
    outb    %al, %dx
1:  movw    $0x1F7, %dx
    inb     %dx, %al
    testb   $0x80, %al
    jnz     1b
    testb   $0x08, %al
    jz      fail
    movl    $256, %ecx
    movl    $BUF_S127, %edi
    movw    $0x1F0, %dx
2:  inw     %dx, %ax
    stosw
    decl    %ecx
    jnz     2b
    movw    $0x1F7, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_RD127_ST

    /* ============ READ SECTORS (0x20) nsector=2 @ LBA 0 (MULTI-SECTOR) === */
    /* Drains 512 words across the sector-0->sector-1 boundary, exercising the
     * multi-sector PIO continuation (data_idx==255 && nsec_left>1 -> xfer_lba+1,
     * nsec_left-1, reload DRQ). qemu sets req_nb_sectors=1 (core.c:1549) so each
     * sector is its own DRQ window re-armed by ide_sector_read_cb. */
    movb    $2, %al                     /* nsector = 2 (two sectors) */
    movw    $0x1F2, %dx
    outb    %al, %dx
    movb    $0, %al                     /* LBA[7:0] = 0 */
    movw    $0x1F3, %dx
    outb    %al, %dx
    movb    $0, %al
    movw    $0x1F4, %dx
    outb    %al, %dx
    movb    $0, %al
    movw    $0x1F5, %dx
    outb    %al, %dx
    movb    $0xE0, %al                  /* LBA, master, LBA[27:24]=0 */
    movw    $0x1F6, %dx
    outb    %al, %dx
    movb    $0x20, %al                  /* READ SECTORS */
    movw    $0x1F7, %dx
    outb    %al, %dx
1:  movw    $0x1F7, %dx
    inb     %dx, %al
    testb   $0x80, %al
    jnz     1b
    testb   $0x08, %al
    jz      fail
    movl    $512, %ecx                  /* 256 words/sector * 2 sectors */
    movl    $BUF_MS, %edi
    movw    $0x1F0, %dx
2:  inw     %dx, %ax                    /* sector 0 then sector 1, graded */
    stosw
    decl    %ecx
    jnz     2b
    movw    $0x1F7, %dx                 /* status after both sectors -> 0x50 */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_MS_ST

    /* ============ EXECUTE DEVICE DIAGNOSTIC (0x90) ====================== */
    movb    $0x90, %al
    movw    $0x1F7, %dx
    outb    %al, %dx
    movw    $0x1F1, %dx                 /* error -> 0x01 (passed) */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_DIAG_ERR
    movw    $0x1F7, %dx                 /* status -> 0x50 */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_DIAG_ST
    movw    $0x1F6, %dx                 /* devhead -> 0xA0 (ALWAYS_ON) */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_DIAG_DH

    /* ====================== deterministic end-state ===================== */
    movl    BUF_ID+2,   %esi            /* IDENTIFY word 1 (cyls = 2)        */
    movl    BUF_S127,   %edi            /* sector 127 word 0 (= 0x00007F00)  */
    movl    BUF_S0+510, %ebp            /* sector 0 word 255 (= 0x0000AA55)  */
    movl    R_DIAG_ERR, %ecx            /* diagnostic error (= 0x00000001)   */

    /* ====================== clean exit via isa-debug-exit =============== */
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx                    /* qemu status (0x42<<1)|1 = 133 */
hang:
    hlt
    jmp     hang

fail:
    /* DRQ not set when expected — store a sentinel + exit (never taken if the
     * device behaves; keeps the differential honest by not silently draining). */
    movl    $0xBADBAD00, R_ID_ST
    movl    $0x42, %eax
    movw    $0xF4, %dx
    outb    %al, %dx
fhang:
    hlt
    jmp     fhang

    /* ===================== 16-bit reset stub @ 0xFFF0 ==================== */
    .code16
    .section .reset, "ax"
    .global _reset
_reset:
    .byte   0xEA                        /* far jmp 0xF000:_start16_off */
    .word   _start16_off
    .word   0xF000
