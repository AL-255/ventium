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
    .equ R_W1_DRQ,   0x00002048  /* WRITE single: status after 0x30  = 0x58 */
    .equ R_W1_POST,  0x0000204C  /* WRITE single: status after drain = 0x50 */
    .equ R_W2_DRQ0,  0x00002050  /* WRITE multi : status after 0x30  = 0x58 */
    .equ R_W2_MID,   0x00002054  /* WRITE multi : status at boundary = 0x58 (re-armed) */
    .equ R_W2_POST,  0x00002058  /* WRITE multi : status after both  = 0x50 */
    .equ R_RB1_ST,   0x0000205C  /* read-back single: status after   = 0x50 */
    .equ R_RB2_ST,   0x00002060  /* read-back multi : status after   = 0x50 */
    /* --- M8.4c IDE PIO fidelity result slots --- */
    .equ R_OORR_ST,  0x00002064  /* OOR READ @128 status   = 0x41 (abort)      */
    .equ R_OORR_ER,  0x00002068  /* OOR READ error         = 0x04 (ABRT)       */
    .equ R_OORR_SEC, 0x0000206C  /* OOR READ sector reg    = 0x80 (unchanged)  */
    .equ R_RA_NS,    0x00002070  /* reg-advance nsector    = 0x00 (after READ) */
    .equ R_RA_SEC,   0x00002074  /* reg-advance sector     = 0x01 (LBA0->1)    */
    .equ R_RA_SEL,   0x00002078  /* reg-advance select     = 0xE0              */
    .equ R_OORW_DRQ, 0x0000207C  /* OOR WRITE @129 DRQ     = 0x58 (armed)      */
    .equ R_OORW_ST,  0x00002080  /* OOR WRITE status       = 0x41 (abort)      */
    .equ R_OORW_ER,  0x00002084  /* OOR WRITE error        = 0x04              */
    .equ R_OORW_SEC, 0x00002088  /* OOR WRITE sector reg   = 0x81 (no advance) */
    .equ R_MRC_ST,   0x0000208C  /* multi-READ cross status= 0x41 (boundary)   */
    .equ R_MRC_ER,   0x00002090  /* multi-READ cross error = 0x04              */
    .equ R_MRC_SEC,  0x00002094  /* multi-READ cross sector= 0x80 (OOR LBA)    */
    .equ R_MWC_MID,  0x00002098  /* multi-WRITE cross mid   = 0x58 (re-armed)  */
    .equ R_MWC_ST,   0x0000209C  /* multi-WRITE cross status= 0x41 (final)     */
    .equ R_CHS_ST,   0x000020A0  /* CHS read status        = 0x50              */
    .equ R_CWD_ST,   0x000020A4  /* command-while-DRQ status= 0x58 (unchanged) */
    .equ R_CWD_ER,   0x000020A8  /* command-while-DRQ error = 0x00 (no abort)  */
    .equ R_RDW_ST,   0x000020AC  /* read-during-write status= 0x58 (no advance)*/
    .equ R_SEEK_ST,  0x000020B0  /* SEEK status            = 0x50              */
    .equ R_SEEK_ER,  0x000020B4  /* SEEK error             = 0x00              */
    .equ R_RECAL_ST, 0x000020B8  /* RECALIBRATE status     = 0x50              */
    .equ R_INIT_ST,  0x000020BC  /* INIT-DEV-PARAMS status = 0x50              */
    /* --- M8.4d Tier 1 result slots --- */
    .equ R_SM_ST,    0x000020C0  /* SET MULTIPLE 8 status   = 0x50             */
    .equ R_SM3_ST,   0x000020C4  /* SET MULTIPLE 3 (abort)  = 0x41             */
    .equ R_SM32_ST,  0x000020C8  /* SET MULTIPLE 32 (abort) = 0x41             */
    .equ R_SF03_ST,  0x000020CC  /* SET FEATURES 0x03 status= 0x50             */
    .equ R_SF02_ST,  0x000020D0  /* SET FEATURES 0x02 status= 0x50             */
    .equ R_SF82_ST,  0x000020F8  /* SET FEATURES 0x82 status= 0x50 (completes) */
    .equ R_SF99_ST,  0x000020D4  /* SET FEATURES 0x99 abort = 0x41             */
    .equ R_ID_W59,   0x000020D8  /* IDENTIFY w59 = 0x0110 (SET MULT does NOT    */
                                 /*   patch the cached IDENTIFY — qemu fidelity) */
    .equ R_ID_W88,   0x000020DC  /* IDENTIFY w88 = 0x043F (udma2)              */
    .equ R_ID_W85,   0x000020E0  /* IDENTIFY w85 = 0x4001 (after 0x82 wcache off)*/
    .equ R_SR_PRE,   0x000020E4  /* SRST: dirty status pre  = 0x41             */
    .equ R_SR_ST,    0x000020E8  /* SRST: status post       = 0x50             */
    .equ R_SR_ER,    0x000020EC  /* SRST: error post        = 0x01             */
    .equ R_SR_SEC,   0x000020F0  /* SRST: sector post       = 0x01             */
    .equ R_SR_SEL,   0x000020F4  /* SRST: devhead post      = 0xA0             */

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

    /* ============ WRITE SECTORS (0x30) single @ scratch LBA 64 ========== */
    /* Scratch LBA 64 does NOT overlap any READ-tested LBA (0/1/127). The write
     * pattern word j = 0xC000+j is distinct from the native content (0x4000+j),
     * so the later read-back returning 0xC0xx (not 0x40xx) PROVES the write took
     * effect (non-vacuous). outw %ax,%dx (66 EF) drives the full 16-bit word. */
    movb    $1, %al                     /* nsector = 1 */
    movw    $0x1F2, %dx
    outb    %al, %dx
    movb    $64, %al                    /* LBA[7:0] = 64 */
    movw    $0x1F3, %dx
    outb    %al, %dx
    movb    $0, %al
    movw    $0x1F4, %dx
    outb    %al, %dx
    movb    $0, %al
    movw    $0x1F5, %dx
    outb    %al, %dx
    movb    $0xE0, %al                  /* LBA, master */
    movw    $0x1F6, %dx
    outb    %al, %dx
    movb    $0x30, %al                  /* WRITE SECTORS */
    movw    $0x1F7, %dx
    outb    %al, %dx
    movw    $0x1F7, %dx                 /* DRQ-out set immediately -> 0x58 */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_W1_DRQ
1:  movw    $0x1F7, %dx
    inb     %dx, %al
    testb   $0x80, %al
    jnz     1b
    testb   $0x08, %al
    jz      fail
    movw    $0xC000, %ax                /* pattern word j = 0xC000 + j */
    movl    $256, %ecx
    movw    $0x1F0, %dx
2:  outw    %ax, %dx                    /* write word (graded via read-back) */
    incw    %ax
    decl    %ecx
    jnz     2b
    movw    $0x1F7, %dx                 /* DRQ cleared after commit -> 0x50 */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_W1_POST

    /* ============ WRITE SECTORS (0x30) multi @ LBA 70 (nsector=2) ======= */
    movb    $2, %al
    movw    $0x1F2, %dx
    outb    %al, %dx
    movb    $70, %al                    /* LBA[7:0] = 70 */
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
    movb    $0x30, %al
    movw    $0x1F7, %dx
    outb    %al, %dx
    movw    $0x1F7, %dx                 /* -> 0x58 */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_W2_DRQ0
1:  movw    $0x1F7, %dx
    inb     %dx, %al
    testb   $0x80, %al
    jnz     1b
    testb   $0x08, %al
    jz      fail
    movw    $0xC000, %ax                /* sector 0 words: 0xC000..0xC0FF */
    movl    $256, %ecx
    movw    $0x1F0, %dx
2:  outw    %ax, %dx
    incw    %ax
    decl    %ecx
    jnz     2b
    movw    $0x1F7, %dx                 /* sector boundary: DRQ RE-ARMED -> 0x58 */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_W2_MID
1:  movw    $0x1F7, %dx
    inb     %dx, %al
    testb   $0x80, %al
    jnz     1b
    testb   $0x08, %al
    jz      fail
    movw    $0xC100, %ax                /* sector 1 words: 0xC100..0xC1FF */
    movl    $256, %ecx
    movw    $0x1F0, %dx
2:  outw    %ax, %dx
    incw    %ax
    decl    %ecx
    jnz     2b
    movw    $0x1F7, %dx                 /* both sectors committed -> 0x50 */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_W2_POST

    /* ============ read-back LBA 64 (single) — proves the write took ===== */
    movb    $1, %al
    movw    $0x1F2, %dx
    outb    %al, %dx
    movb    $64, %al
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
    movb    $0x20, %al                  /* READ SECTORS */
    movw    $0x1F7, %dx
    outb    %al, %dx
1:  movw    $0x1F7, %dx
    inb     %dx, %al
    testb   $0x80, %al
    jnz     1b
    testb   $0x08, %al
    jz      fail
    movl    $256, %ecx                  /* each inw word = 0xC000+j (NOT 0x40xx) */
    movw    $0x1F0, %dx
2:  inw     %dx, %ax
    decl    %ecx
    jnz     2b
    movw    $0x1F7, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_RB1_ST

    /* ============ read-back LBA 70-71 (multi) — proves multi write data = */
    movb    $2, %al
    movw    $0x1F2, %dx
    outb    %al, %dx
    movb    $70, %al
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
    movl    $512, %ecx                  /* sector 70 (0xC000..) + 71 (0xC100..) */
    movw    $0x1F0, %dx
2:  inw     %dx, %ax
    decl    %ecx
    jnz     2b
    movw    $0x1F7, %dx
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_RB2_ST

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

    /* ===================== M8.4c IDE PIO FIDELITY ====================== */
    /* All new scratch LBAs (128/129/127/100/CHS) run AFTER the existing graded
     * reads/writes so they cannot disturb them. WRITEs go to the snapshot=on
     * overlay; the committed pide.img stays pristine (gate md5 PRE==POST). */

    /* --- (1) OOR single READ @ LBA 128: upfront abort (no DRQ) --------- */
    movb    $1, %al;   movw $0x1F2, %dx; outb %al, %dx
    movb    $128, %al; movw $0x1F3, %dx; outb %al, %dx   /* LBA 128 (0x80) = OOR */
    movb    $0, %al;   movw $0x1F4, %dx; outb %al, %dx
    movb    $0, %al;   movw $0x1F5, %dx; outb %al, %dx
    movb    $0xE0, %al;movw $0x1F6, %dx; outb %al, %dx
    movb    $0x20, %al;movw $0x1F7, %dx; outb %al, %dx   /* READ -> OOR upfront abort */
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_OORR_ST  /* 0x41 */
    movw    $0x1F1, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_OORR_ER  /* 0x04 */
    movw    $0x1F3, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_OORR_SEC /* 0x80 */

    /* follow-up READ LBA 0 proves the disk is UNTOUCHED (no aliasing) + the
     * LBA-register advance (after this in-range nsec=1 read, regs -> LBA 1). */
    movb    $1, %al;   movw $0x1F2, %dx; outb %al, %dx
    movb    $0, %al;   movw $0x1F3, %dx; outb %al, %dx
    movb    $0, %al;   movw $0x1F4, %dx; outb %al, %dx
    movb    $0, %al;   movw $0x1F5, %dx; outb %al, %dx
    movb    $0xE0, %al;movw $0x1F6, %dx; outb %al, %dx
    movb    $0x20, %al;movw $0x1F7, %dx; outb %al, %dx
1:  movw    $0x1F7, %dx; inb %dx, %al; testb $0x80, %al; jnz 1b
    testb   $0x08, %al; jz fail
    movl    $256, %ecx; movw $0x1F0, %dx
2:  inw     %dx, %ax; decl %ecx; jnz 2b               /* word0=0x0000..w255=0xAA55 native */
    movw    $0x1F2, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_RA_NS  /* nsector=0 */
    movw    $0x1F3, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_RA_SEC /* sector=1 */
    movw    $0x1F6, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_RA_SEL /* select=0xE0 */

    /* --- (2) OOR single WRITE @ LBA 129: fill, abort on last word, alias intact - */
    movb    $1, %al;   movw $0x1F2, %dx; outb %al, %dx
    movb    $129, %al; movw $0x1F3, %dx; outb %al, %dx   /* LBA 129 (0x81) = OOR */
    movb    $0, %al;   movw $0x1F4, %dx; outb %al, %dx
    movb    $0, %al;   movw $0x1F5, %dx; outb %al, %dx
    movb    $0xE0, %al;movw $0x1F6, %dx; outb %al, %dx
    movb    $0x30, %al;movw $0x1F7, %dx; outb %al, %dx   /* WRITE -> arms 0x58 (abort deferred) */
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_OORW_DRQ /* 0x58 */
1:  movw    $0x1F7, %dx; inb %dx, %al; testb $0x80, %al; jnz 1b
    testb   $0x08, %al; jz fail
    movw    $0xE000, %ax; movl $256, %ecx; movw $0x1F0, %dx
2:  outw    %ax, %dx; incw %ax; decl %ecx; jnz 2b       /* fill 256 (DROPPED: OOR sector) */
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_OORW_ST  /* 0x41 */
    movw    $0x1F1, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_OORW_ER  /* 0x04 */
    movw    $0x1F3, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_OORW_SEC /* 0x81 no advance */
    /* prove the alias target LBA 1 (129 mod 128) is NOT corrupted */
    movb    $1, %al;   movw $0x1F2, %dx; outb %al, %dx
    movb    $1, %al;   movw $0x1F3, %dx; outb %al, %dx
    movb    $0, %al;   movw $0x1F4, %dx; outb %al, %dx
    movb    $0, %al;   movw $0x1F5, %dx; outb %al, %dx
    movb    $0xE0, %al;movw $0x1F6, %dx; outb %al, %dx
    movb    $0x20, %al;movw $0x1F7, %dx; outb %al, %dx
1:  movw    $0x1F7, %dx; inb %dx, %al; testb $0x80, %al; jnz 1b
    testb   $0x08, %al; jz fail
    movl    $256, %ecx; movw $0x1F0, %dx
2:  inw     %dx, %ax; decl %ecx; jnz 2b               /* word0=0x0100 native (NOT 0xE0xx) */

    /* --- (3) multi-READ crossing @ LBA 127 nsec=2: deliver 127, abort at 128 - */
    movb    $2, %al;   movw $0x1F2, %dx; outb %al, %dx
    movb    $127, %al; movw $0x1F3, %dx; outb %al, %dx
    movb    $0, %al;   movw $0x1F4, %dx; outb %al, %dx
    movb    $0, %al;   movw $0x1F5, %dx; outb %al, %dx
    movb    $0xE0, %al;movw $0x1F6, %dx; outb %al, %dx
    movb    $0x20, %al;movw $0x1F7, %dx; outb %al, %dx
1:  movw    $0x1F7, %dx; inb %dx, %al; testb $0x80, %al; jnz 1b
    testb   $0x08, %al; jz fail
    movl    $256, %ecx; movw $0x1F0, %dx
2:  inw     %dx, %ax; decl %ecx; jnz 2b               /* sector 127 real data (w0=0x7F00) */
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_MRC_ST  /* 0x41 at boundary */
    movw    $0x1F1, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_MRC_ER  /* 0x04 */
    movw    $0x1F3, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_MRC_SEC /* 0x80 advanced to OOR */

    /* --- (4) multi-WRITE crossing @ LBA 127 nsec=2: commit 127, abort at 128 - */
    movb    $2, %al;   movw $0x1F2, %dx; outb %al, %dx
    movb    $127, %al; movw $0x1F3, %dx; outb %al, %dx
    movb    $0, %al;   movw $0x1F4, %dx; outb %al, %dx
    movb    $0, %al;   movw $0x1F5, %dx; outb %al, %dx
    movb    $0xE0, %al;movw $0x1F6, %dx; outb %al, %dx
    movb    $0x30, %al;movw $0x1F7, %dx; outb %al, %dx
1:  movw    $0x1F7, %dx; inb %dx, %al; testb $0x80, %al; jnz 1b
    testb   $0x08, %al; jz fail
    movw    $0xB000, %ax; movl $256, %ecx; movw $0x1F0, %dx   /* sector 127: 0xB000+j */
2:  outw    %ax, %dx; incw %ax; decl %ecx; jnz 2b
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_MWC_MID /* 0x58 re-armed */
1:  movw    $0x1F7, %dx; inb %dx, %al; testb $0x80, %al; jnz 1b
    testb   $0x08, %al; jz fail
    movw    $0xF000, %ax; movl $256, %ecx; movw $0x1F0, %dx   /* sector 128 OOR (dropped) */
2:  outw    %ax, %dx; incw %ax; decl %ecx; jnz 2b
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_MWC_ST  /* 0x41 final */
    /* prove sector 127 COMMITTED before the OOR abort: read LBA 127 -> 0xB000+j */
    movb    $1, %al;   movw $0x1F2, %dx; outb %al, %dx
    movb    $127, %al; movw $0x1F3, %dx; outb %al, %dx
    movb    $0, %al;   movw $0x1F4, %dx; outb %al, %dx
    movb    $0, %al;   movw $0x1F5, %dx; outb %al, %dx
    movb    $0xE0, %al;movw $0x1F6, %dx; outb %al, %dx
    movb    $0x20, %al;movw $0x1F7, %dx; outb %al, %dx
1:  movw    $0x1F7, %dx; inb %dx, %al; testb $0x80, %al; jnz 1b
    testb   $0x08, %al; jz fail
    movl    $256, %ecx; movw $0x1F0, %dx
2:  inw     %dx, %ax; decl %ecx; jnz 2b               /* word0=0xB000 (committed pre-abort) */

    /* --- (5) CHS addressing: C0/H1/S2 -> LBA 64 (devhead bit6=0) -------- */
    movb    $1, %al;   movw $0x1F2, %dx; outb %al, %dx
    movb    $2, %al;   movw $0x1F3, %dx; outb %al, %dx   /* sector = 2 (1-based) */
    movb    $0, %al;   movw $0x1F4, %dx; outb %al, %dx   /* cyl lo = 0 */
    movb    $0, %al;   movw $0x1F5, %dx; outb %al, %dx   /* cyl hi = 0 */
    movb    $0xA1, %al;movw $0x1F6, %dx; outb %al, %dx   /* bit6=0 CHS, master, head=1 */
    movb    $0x20, %al;movw $0x1F7, %dx; outb %al, %dx
1:  movw    $0x1F7, %dx; inb %dx, %al; testb $0x80, %al; jnz 1b
    testb   $0x08, %al; jz fail
    movl    $256, %ecx; movw $0x1F0, %dx
2:  inw     %dx, %ax; decl %ecx; jnz 2b               /* C0/H1/S2 -> LBA 64: w0=0x4000 */
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_CHS_ST   /* 0x50 */

    /* --- (6) command-while-DRQ: a 2nd command mid-DRQ is DROPPED -------- */
    movb    $1, %al;   movw $0x1F2, %dx; outb %al, %dx
    movb    $0, %al;   movw $0x1F3, %dx; outb %al, %dx   /* LBA 0 */
    movb    $0, %al;   movw $0x1F4, %dx; outb %al, %dx
    movb    $0, %al;   movw $0x1F5, %dx; outb %al, %dx
    movb    $0xE0, %al;movw $0x1F6, %dx; outb %al, %dx
    movb    $0x20, %al;movw $0x1F7, %dx; outb %al, %dx   /* READ LBA0 -> DRQ */
1:  movw    $0x1F7, %dx; inb %dx, %al; testb $0x80, %al; jnz 1b
    testb   $0x08, %al; jz fail
    movb    $0xEC, %al;movw $0x1F7, %dx; outb %al, %dx   /* mid-DRQ IDENTIFY -> DROPPED */
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_CWD_ST  /* still 0x58 */
    movw    $0x1F1, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_CWD_ER  /* 0x00 no abort */
    movl    $256, %ecx; movw $0x1F0, %dx
2:  inw     %dx, %ax; decl %ecx; jnz 2b               /* LBA0 data (w0=0x0000), NOT IDENTIFY 0x0040 */

    /* --- (7) read-during-write-DRQ: a stray inw returns 0 + consumes no slot - */
    movb    $1, %al;   movw $0x1F2, %dx; outb %al, %dx
    movb    $100, %al; movw $0x1F3, %dx; outb %al, %dx   /* scratch LBA 100 */
    movb    $0, %al;   movw $0x1F4, %dx; outb %al, %dx
    movb    $0, %al;   movw $0x1F5, %dx; outb %al, %dx
    movb    $0xE0, %al;movw $0x1F6, %dx; outb %al, %dx
    movb    $0x30, %al;movw $0x1F7, %dx; outb %al, %dx   /* WRITE -> 0x58 */
1:  movw    $0x1F7, %dx; inb %dx, %al; testb $0x80, %al; jnz 1b
    testb   $0x08, %al; jz fail
    movw    $0x1F0, %dx; inw %dx, %ax                    /* stray READ in write window -> 0x0000 */
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_RDW_ST  /* still 0x58, no advance */
    movw    $0xD000, %ax; movl $256, %ecx; movw $0x1F0, %dx
2:  outw    %ax, %dx; incw %ax; decl %ecx; jnz 2b        /* fill all 256 (the stray read took no slot) */
    /* read back LBA 100 -> 0xD000+j (all 256 words present/correct) */
    movb    $1, %al;   movw $0x1F2, %dx; outb %al, %dx
    movb    $100, %al; movw $0x1F3, %dx; outb %al, %dx
    movb    $0, %al;   movw $0x1F4, %dx; outb %al, %dx
    movb    $0, %al;   movw $0x1F5, %dx; outb %al, %dx
    movb    $0xE0, %al;movw $0x1F6, %dx; outb %al, %dx
    movb    $0x20, %al;movw $0x1F7, %dx; outb %al, %dx
1:  movw    $0x1F7, %dx; inb %dx, %al; testb $0x80, %al; jnz 1b
    testb   $0x08, %al; jz fail
    movl    $256, %ecx; movw $0x1F0, %dx
2:  inw     %dx, %ax; decl %ecx; jnz 2b               /* w0=0xD000..w255=0xD0FF */

    /* --- (8) misc non-data commands complete 0x50/0x00 ----------------- */
    movb    $0xE0, %al;movw $0x1F6, %dx; outb %al, %dx
    movb    $0x70, %al;movw $0x1F7, %dx; outb %al, %dx   /* SEEK */
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SEEK_ST  /* 0x50 */
    movw    $0x1F1, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SEEK_ER  /* 0x00 */
    movb    $0x10, %al;movw $0x1F7, %dx; outb %al, %dx   /* RECALIBRATE */
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_RECAL_ST /* 0x50 */
    movb    $63, %al;  movw $0x1F2, %dx; outb %al, %dx   /* sectors/track for INIT-DEV-PARAMS */
    movb    $0x91, %al;movw $0x1F7, %dx; outb %al, %dx   /* INIT DEVICE PARAMS */
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_INIT_ST  /* 0x50 */
    /* NOTE: the mid-DRQ task-file-register WRITE drop (qemu core.c:1287) IS
     * modeled (ven_ide.sv gates 0x1F1-0x1F6 writes on !r_status[3]), but is NOT
     * separately gate-tested here: any mid-DRQ register READ that would observe
     * the drop also samples the off-surface register-advance LAG (qemu advances
     * the visible sector reg at DRQ-window-open via ide_sector_read_cb, the RTL
     * at end-of-drain), a documented boundary. The two agree on the POST-transfer
     * value (R_RA_SEC=1 above), which IS gate-proven. */

    /* ===================== M8.4d ATA command-set (Tier 1) ============== */
    /* --- SET MULTIPLE (0xC6): accept 8 (-> IDENTIFY w59=0x0108), abort 3/32 -- */
    movb    $8, %al;   movw $0x1F2, %dx; outb %al, %dx   /* nsector=8 (pow2 <=16) */
    movb    $0xC6, %al;movw $0x1F7, %dx; outb %al, %dx
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SM_ST   /* 0x50 */
    movb    $3, %al;   movw $0x1F2, %dx; outb %al, %dx   /* nsector=3 (not pow2) */
    movb    $0xC6, %al;movw $0x1F7, %dx; outb %al, %dx
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SM3_ST  /* 0x41 */
    movb    $32, %al;  movw $0x1F2, %dx; outb %al, %dx   /* nsector=32 (>16) */
    movb    $0xC6, %al;movw $0x1F7, %dx; outb %al, %dx
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SM32_ST /* 0x41 */

    /* --- SET FEATURES (0xEF): 0x03 udma2 (-> w62/63/88), 0x02 wcache (-> w85),
     *     0x99 unsupported (-> abort) -------------------------------------- */
    movb    $0x03, %al;movw $0x1F1, %dx; outb %al, %dx   /* feature 0x03 = set transfer */
    movb    $0x42, %al;movw $0x1F2, %dx; outb %al, %dx   /* mode 0x42 = UDMA2 */
    movb    $0xEF, %al;movw $0x1F7, %dx; outb %al, %dx
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SF03_ST /* 0x50 */
    movb    $0x02, %al;movw $0x1F1, %dx; outb %al, %dx   /* feature 0x02 = wcache enable */
    movb    $0xEF, %al;movw $0x1F7, %dx; outb %al, %dx
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SF02_ST /* 0x50 */
    movb    $0x82, %al;movw $0x1F1, %dx; outb %al, %dx   /* feature 0x82 = wcache DISABLE */
    movb    $0xEF, %al;movw $0x1F7, %dx; outb %al, %dx   /* qemu COMPLETES it -> w85=0x4001 */
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SF82_ST /* 0x50 */
    movb    $0x99, %al;movw $0x1F1, %dx; outb %al, %dx   /* feature 0x99 = unsupported */
    movb    $0xEF, %al;movw $0x1F7, %dx; outb %al, %dx
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SF99_ST /* 0x41 */

    /* --- IDENTIFY: grade the mutated words per-record (drain into BUF_ID) --- */
    movb    $0xEC, %al;movw $0x1F7, %dx; outb %al, %dx
1:  movw    $0x1F7, %dx; inb %dx, %al; testb $0x80, %al; jnz 1b
    testb   $0x08, %al; jz fail
    movl    $256, %ecx; movl $BUF_ID, %edi; movw $0x1F0, %dx
2:  inw     %dx, %ax; stosw; decl %ecx; jnz 2b           /* w59=0x0110 (unchanged), w88=0x043F, w85=0x4001 */
    movl    BUF_ID+118, %eax; andl $0xFFFF, %eax; movl %eax, R_ID_W59  /* word 59 */
    movl    BUF_ID+176, %eax; andl $0xFFFF, %eax; movl %eax, R_ID_W88  /* word 88 */
    movl    BUF_ID+170, %eax; andl $0xFFFF, %eax; movl %eax, R_ID_W85  /* word 85 */

    /* --- SRST (0x3F6 bit2): dirty the state, soft-reset, read the signature -- */
    movb    $0xFF, %al;movw $0x1F7, %dx; outb %al, %dx   /* bogus cmd -> abort (dirty) */
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SR_PRE  /* 0x41 */
    movb    $0x06, %al;movw $0x3F6, %dx; outb %al, %dx   /* SRST(bit2)+nIEN(bit1) assert */
    movb    $0x02, %al;movw $0x3F6, %dx; outb %al, %dx   /* deassert SRST, keep nIEN */
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SR_ST   /* 0x50 */
    movw    $0x1F1, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SR_ER   /* 0x01 */
    movw    $0x1F3, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SR_SEC  /* 0x01 */
    movw    $0x1F6, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SR_SEL  /* 0xA0 */

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
