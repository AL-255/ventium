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
    .equ R_SLV_LC,   0x000020FC  /* absent slave lcyl    = 0xFF (M8.4e indep shadow) */
    .equ R_SLV_HC,   0x00002100  /* absent slave hcyl    = 0xFF (M8.4e indep shadow) */
    /* --- M8.4e secondary-channel (empty ATAPI CD) result slots --- */
    .equ R_SEC_ST,     0x00002104 /* SEC master status    = 0x50 */
    .equ R_SEC_SIG_L,  0x00002108 /* SEC ATAPI sig lcyl   = 0x14 */
    .equ R_SEC_SIG_H,  0x0000210C /* SEC ATAPI sig hcyl   = 0xEB */
    .equ R_SEC_DIAG_ST,0x00002110 /* SEC DIAGNOSTIC status= 0x00 (ATAPI, not 0x50) */
    .equ R_SEC_EC_ST,  0x00002114 /* SEC 0xEC abort status= 0x41 */
    .equ R_SEC_EC_ER,  0x00002118 /* SEC 0xEC abort error = 0x04 */
    .equ R_SEC_RD_ST,  0x0000211C /* SEC READ abort status= 0x41 (not 0x58) */
    .equ R_SEC_SLV_LC, 0x00002120 /* SEC slave lcyl       = 0xFF */
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
    /* --- M8.4e2 review-hardening result slots (primary + secondary ATAPI) --- */
    .equ R_DP_IDLE,  0x00002124  /* primary IDLE 0x1F0 read  = 0x0000 (!DRQ->0) */
    .equ R_SLV_NS,   0x00002128  /* absent-slave nsector (indep of master adv)  */
    .equ R_SLV_SEC2, 0x0000212C  /* absent-slave sector  (indep of master adv)  */
    .equ R_SEC_DR_ST,  0x00002130 /* SEC 0x08 DEVICE RESET status (ATAPI 0x00)  */
    .equ R_SEC_DR_ER,  0x00002134 /* SEC 0x08 error                             */
    .equ R_SEC_DR_NS,  0x00002138 /* SEC 0x08 nsector = 0x01 (ide_set_signature)*/
    .equ R_SEC_DR_SEC, 0x0000213C /* SEC 0x08 sector  = 0x01                    */
    .equ R_SEC_DR_LC,  0x00002140 /* SEC 0x08 lcyl    = 0x14                    */
    .equ R_SEC_DR_HC,  0x00002144 /* SEC 0x08 hcyl    = 0xEB                    */
    .equ R_SEC_DR_DH,  0x00002148 /* SEC 0x08 devhead = 0xA0 (head cleared)     */
    .equ R_SEC_FC_ST,  0x0000214C /* SEC 0xE7 FLUSH CACHE status (completes)    */
    .equ R_SEC_FC_ER,  0x00002150 /* SEC 0xE7 error                             */
    .equ R_SEC_EF_ST,  0x00002154 /* SEC 0xEF SET FEATURES status               */
    .equ R_SEC_EF_ER,  0x00002158 /* SEC 0xEF error                             */
    .equ R_SEC_BA_ST,  0x0000215C /* SEC 0xB0 SMART (unsupported) status = 0x41 */
    .equ R_SEC_BA_ER,  0x00002160 /* SEC 0xB0 error = 0x04                      */
    .equ R_SEC_BA_LC,  0x00002164 /* SEC bare-abort: lcyl unchanged = 0x55      */
    .equ R_SEC_SR_ST,  0x00002168 /* SEC SRST status post (ATAPI = 0x00)        */
    .equ R_SEC_SR_ER,  0x0000216C /* SEC SRST error post = 0x01                 */
    /* --- M8.4f-pre PCI config (PIIX3 IDE 00:01.1) result slots (32-bit) --- */
    .equ R_PCI_VID,    0x00002170 /* reg0x00 vendor/device = 0x70108086         */
    .equ R_PCI_CLASS,  0x00002174 /* reg0x08 class/prog-if  = 0x01018000        */
    .equ R_PCI_CMD0,   0x00002178 /* reg0x04 command pre-enable  = 0x0000       */
    .equ R_PCI_BAR0,   0x0000217C /* reg0x20 BAR4 pre-program    = 0x00000001   */
    .equ R_PCI_BAR1,   0x00002180 /* reg0x20 BAR4 after 0xC000   = 0x0000C001   */
    .equ R_PCI_CMD1,   0x00002184 /* reg0x04 command after IO|BM = 0x0005       */
    /* --- M8.4f single-PRD READ DMA (0xC8) result slots --- */
    .equ R_DMA_DTP,    0x00002188 /* BMIDTP readback (low-2 masked) = 0x00005000 */
    .equ R_DMA_BMIC,   0x0000218C /* BMIC readback (cmd & 0x09)     = 0x09        */
    .equ R_DMA_BMIS,   0x00002190 /* BMIS after completion (nIEN: no INT)         */
    .equ R_DMA_ST,     0x00002194 /* task-file status after DMA     = 0x50        */
    .equ R_DMA_NS,     0x00002198 /* nsector after DMA (advance)    = 0x00        */
    .equ R_DMA_SEC,    0x0000219C /* sector  after DMA (LBA0->1)    = 0x01        */
    .equ R_DMA_W0,     0x000021A0 /* DMA'd buffer word0   = 0x0000  (LBA0 w0)     */
    .equ R_DMA_W255,   0x000021A4 /* DMA'd buffer word255 = 0xAA55  (boot sig)    */
    .equ R_DMA_C8ST,   0x000021A8 /* status after 0xC8, pre-START = 0x58 (DRQ)    */
    /* --- M8.4d2 READ/WRITE MULTIPLE (0xC4/0xC5) block-mode PIO slots --- */
    .equ R_RMSM_ST,    0x000021AC /* SET MULTIPLE 4 status = 0x50                 */
    .equ R_RM_MID,     0x000021B0 /* RD-MULT: status after 256 words = 0x58 (DRQ) */
    .equ R_RM_W0,      0x000021B4 /* RD-MULT word0   = 0x0000 (LBA0)              */
    .equ R_RM_W255,    0x000021B8 /* RD-MULT word255 = 0xAA55 (LBA0 boot sig)     */
    .equ R_RM_W256,    0x000021BC /* RD-MULT word256 = 0x0100 (LBA1 w0)           */
    .equ R_RM_W512,    0x000021C0 /* RD-MULT word512 = 0x0200 (LBA2 w0)           */
    .equ R_RM_W768,    0x000021C4 /* RD-MULT word768 = 0x0300 (LBA3 w0)           */
    .equ R_RM_ST,      0x000021C8 /* RD-MULT post status = 0x50                   */
    .equ R_RM_NS,      0x000021CC /* RD-MULT nsector after = 0x00                 */
    .equ R_RM_SEC,     0x000021D0 /* RD-MULT sector after = 0x04 (LBA0+4)         */
    .equ R_RMP_MID,    0x000021D4 /* RD-MULT partial: status at block bndry = 0x58*/
    .equ R_RMP_W1024,  0x000021D8 /* RD-MULT partial: block2 word0 = 0x0400 (LBA4)*/
    .equ R_RMP_W1280,  0x000021DC /* RD-MULT partial: block2 word256 = 0x0500     */
    .equ R_RMP_ST,     0x000021E0 /* RD-MULT partial: post status = 0x50          */
    .equ R_RMP_NS,     0x000021E4 /* RD-MULT partial: nsector = 0x00              */
    .equ R_RMP_SEC,    0x000021E8 /* RD-MULT partial: sector = 0x06 (LBA0+6)      */
    .equ R_RM_ABRT_ST, 0x000021EC /* RD-MULT mult=0 abort status = 0x41           */
    .equ R_RM_ABRT_ER, 0x000021F0 /* RD-MULT mult=0 abort error  = 0x04           */
    .equ R_WM_DRQ,     0x000021F4 /* WR-MULT: status after 0xC5 = 0x58            */
    .equ R_WM_ST,      0x000021F8 /* WR-MULT post status = 0x50                   */
    .equ R_WM_NS,      0x000021FC /* WR-MULT nsector after = 0x00                 */
    .equ R_WM_SEC,     0x00002200 /* WR-MULT sector after = 0x72 (LBA112+2=114)   */
    .equ R_WM_RB0,     0x00002204 /* WR-MULT read-back LBA112 word0 = 0xE000      */
    .equ R_WM_RB256,   0x00002208 /* WR-MULT read-back LBA113 word0 = 0xE100      */
    .equ R_RM_W59,     0x0000220C /* re-IDENTIFY w59 = 0x0110 (cache freeze)      */
    .equ R_RMX_ST,     0x00002210 /* RD-MULT straddling-block OOR: status = 0x41  */
    .equ R_RMX_ER,     0x00002214 /* RD-MULT straddling-block OOR: error  = 0x04  */
    .equ R_RMX_SEC,    0x00002218 /* RD-MULT straddling-block OOR: sector reg unmoved = 0x7E (126) */
    /* --- M8.5 PCI bus-0 enumeration (controlled subset) result slots --- */
    .equ R_PCI_H00,    0x0000221C /* 00:00.0 i440FX vendor/device = 0x12378086    */
    .equ R_PCI_H08,    0x00002220 /* 00:00.0 class/prog-if/rev    = 0x06000002    */
    .equ R_PCI_I00,    0x00002224 /* 00:01.0 PIIX3 ISA vendor/dev = 0x70008086    */
    .equ R_PCI_I04,    0x00002228 /* 00:01.0 status<<16|cmd       = 0x02000000    */
    .equ R_PCI_I08,    0x0000222C /* 00:01.0 class (ISA bridge)   = 0x06010000    */
    .equ R_PCI_I0C,    0x00002230 /* 00:01.0 header-type (multifn)= 0x00800000    */
    .equ R_PCI_D00,    0x00002234 /* 00:01.1 IDE vendor/device    = 0x70108086    */
    .equ R_PCI_D04,    0x00002238 /* 00:01.1 IDE status<<16|cmd = 0x02800005 (status 0x0280|cmd 0x0005, IO|BM set by M8.4f-pre) */
    .equ R_PCI_D08,    0x0000223C /* 00:01.1 IDE class            = 0x01018000    */
    .equ R_PCI_D2C,    0x00002240 /* 00:01.1 subsystem            = 0x11001AF4    */
    .equ R_PCI_PM00,   0x00002244 /* 00:01.3 PIIX4-PM vendor/dev  = 0x71138086    */
    .equ R_PCI_PM08,   0x00002248 /* 00:01.3 PM class             = 0x06800003    */
    .equ R_PCI_PM3C,   0x00002268 /* 00:01.3 PM reg0x3C int-pin   = 0x00000100 (pin A) */
    .equ R_PCI_VG00,   0x0000224C /* 00:02.0 std-VGA vendor/dev   = 0x11111234    */
    .equ R_PCI_VG08,   0x00002250 /* 00:02.0 VGA class            = 0x03000002    */
    .equ R_PCI_BARSZ,  0x00002254 /* IDE BAR4 sizing (write ~0)   = 0xFFFFFFF1    */
    .equ R_PCI_BARRE,  0x00002258 /* IDE BAR4 restored (0xC000)   = 0x0000C001    */
    .equ R_PCI_ABS1,   0x0000225C /* absent 00:00.1 (devfn 0x01)  = 0xFFFFFFFF    */
    .equ R_PCI_ABS2,   0x00002260 /* absent 00:01.2 (devfn 0x0A)  = 0xFFFFFFFF    */
    .equ R_PCI_OFF,    0x00002264 /* CONFIG_ADDRESS bit31=0 (disabled) = 0xFFFFFFFF */

    .equ PRD_TBL,    0x00005000  /* PRD table (8 bytes, dword-aligned) */
    .equ DMA_BUF,    0x00006000  /* DMA target buffer (512 bytes)      */
    .equ BUF_RM,     0x00008000  /* M8.4d2 block-mode drain buffer (4 KiB, < stack 0x90000) */
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
    /* M8.4e: the absent slave's INDEPENDENT lcyl/hcyl = 0xFF (fresh signature
     * shadow, before any LBA write broadcasts over it) — NOT the master's 0x00. */
    movw    $0x1F4, %dx                 /* slave lcyl -> 0xFF */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_SLV_LC
    movw    $0x1F5, %dx                 /* slave hcyl -> 0xFF */
    inb     %dx, %al
    andl    $0xFF, %eax
    movl    %eax, R_SLV_HC
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

    /* =============== M8.4e2 PRIMARY review-hardening =================== */
    /* (a) an IDLE data-port (0x1F0) read returns 0x0000 in qemu (ide_data_readw
     *     returns 0 whenever DRQ is clear) — proves the RTL no longer leaks a
     *     stale buffer word off the read-DRQ window (tightens boundary (b)).
     * (b) the absent slave's nsector/sector are INDEPENDENT of a MASTER command's
     *     register advance (qemu per-IDEState regs): after a master READ drives the
     *     MASTER nsector->0 / sector->1, the absent slave still reads its last
     *     broadcast-written value (nsector=1 / sector=0). */
    movb    $0xE0, %al; movw $0x1F6, %dx; outb %al, %dx   /* LBA master */
    movb    $0x01, %al; movw $0x1F2, %dx; outb %al, %dx   /* nsector=1 (bcast -> slave=1) */
    xorb    %al, %al
    movw    $0x1F3, %dx; outb %al, %dx                    /* LBA[7:0]=0 (bcast sector -> slave=0) */
    movw    $0x1F4, %dx; outb %al, %dx                    /* LBA[15:8]=0 */
    movw    $0x1F5, %dx; outb %al, %dx                    /* LBA[23:16]=0 */
    movb    $0x20, %al; movw $0x1F7, %dx; outb %al, %dx   /* READ SECTORS LBA0 */
1:  movw    $0x1F7, %dx; inb %dx, %al; testb $0x80, %al; jnz 1b
    testb   $0x08, %al; jz fail                           /* DRQ set */
    movl    $256, %ecx; movw $0x1F0, %dx
2:  inw     %dx, %ax; decl %ecx; jnz 2b                   /* drain 256 (MASTER advances) */
    /* (a) idle data-port read -> 0x0000 (status now 0x50, DRQ clear) */
    movw    $0x1F0, %dx; inw %dx, %ax; andl $0xFFFF, %eax; movl %eax, R_DP_IDLE
    /* (b) absent slave: independent nsector/sector (NOT the master's advanced regs) */
    movb    $0xB0, %al; movw $0x1F6, %dx; outb %al, %dx   /* select absent slave */
    movw    $0x1F2, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SLV_NS   /* slave nsector */
    movw    $0x1F3, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SLV_SEC2 /* slave sector */
    movb    $0xA0, %al; movw $0x1F6, %dx; outb %al, %dx   /* reselect master */

    /* =============== M8.4e SECONDARY CHANNEL (empty ATAPI CD) ========== */
    /* The secondary master is qemu's auto-created empty ide1-cd0 (ATAPI). Every
     * read below is graded per-record; the key discriminators are stored. */
    movb    $0x02, %al; movw $0x376, %dx; outb %al, %dx   /* nIEN on the secondary */

    /* SEC-1 signature: 0xEB14 marks ATAPI (vs the HD's 0x0000) */
    movb    $0xA0, %al; movw $0x176, %dx; outb %al, %dx   /* select secondary master */
    movw    $0x177, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SEC_ST   /* 0x50 */
    movw    $0x376, %dx; inb %dx, %al; andl $0xFF, %eax                        /* 0x50 altstat */
    movw    $0x171, %dx; inb %dx, %al; andl $0xFF, %eax                        /* 0x00 error */
    movw    $0x172, %dx; inb %dx, %al; andl $0xFF, %eax                        /* 0x01 nsector */
    movw    $0x173, %dx; inb %dx, %al; andl $0xFF, %eax                        /* 0x01 sector */
    movw    $0x174, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SEC_SIG_L /* 0x14 */
    movw    $0x175, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SEC_SIG_H /* 0xEB */
    movw    $0x176, %dx; inb %dx, %al; andl $0xFF, %eax                        /* 0xA0 devhead */

    /* SEC-2 DIAGNOSTIC: ATAPI clears READY_STAT -> status 0x00 (NOT 0x50) */
    movb    $0x90, %al; movw $0x177, %dx; outb %al, %dx
    movw    $0x171, %dx; inb %dx, %al; andl $0xFF, %eax                        /* 0x01 error */
    movw    $0x177, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SEC_DIAG_ST /* 0x00 */
    movw    $0x174, %dx; inb %dx, %al; andl $0xFF, %eax                        /* 0x14 sig */
    movw    $0x175, %dx; inb %dx, %al; andl $0xFF, %eax                        /* 0xEB sig */

    /* SEC-3 IDENTIFY DEVICE (0xEC) on an ATAPI device -> ABORT + signature */
    movb    $0xA0, %al; movw $0x176, %dx; outb %al, %dx
    movb    $0xEC, %al; movw $0x177, %dx; outb %al, %dx
    movw    $0x177, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SEC_EC_ST /* 0x41 */
    movw    $0x171, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SEC_EC_ER /* 0x04 */
    movw    $0x174, %dx; inb %dx, %al; andl $0xFF, %eax                        /* 0x14 (sig re-set) */
    movw    $0x175, %dx; inb %dx, %al; andl $0xFF, %eax                        /* 0xEB */

    /* SEC-4 HD command (READ SECTORS) on ATAPI -> ABORT (no DRQ; an HD gives 0x58) */
    movb    $0x01, %al; movw $0x172, %dx; outb %al, %dx
    movb    $0xA0, %al; movw $0x176, %dx; outb %al, %dx
    movb    $0x20, %al; movw $0x177, %dx; outb %al, %dx
    movw    $0x177, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SEC_RD_ST /* 0x41 */
    movw    $0x171, %dx; inb %dx, %al; andl $0xFF, %eax                        /* 0x04 */

    /* SEC-5 secondary SLAVE (absent): masked status/error + indep lcyl/hcyl=0xFF */
    movb    $0xB0, %al; movw $0x176, %dx; outb %al, %dx
    movw    $0x177, %dx; inb %dx, %al; andl $0xFF, %eax                        /* 0x00 masked */
    movw    $0x171, %dx; inb %dx, %al; andl $0xFF, %eax                        /* 0x00 masked */
    movw    $0x376, %dx; inb %dx, %al; andl $0xFF, %eax                        /* 0x00 masked */
    movw    $0x172, %dx; inb %dx, %al; andl $0xFF, %eax                        /* 0x01 shared */
    movw    $0x173, %dx; inb %dx, %al; andl $0xFF, %eax                        /* 0x01 shared */
    movw    $0x174, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SEC_SLV_LC /* 0xFF */
    movw    $0x175, %dx; inb %dx, %al; andl $0xFF, %eax                        /* 0xFF */

    /* SEC-6 DEVICE RESET (0x08): CD_OK -> ide_reset + signature, status 0x00, NO
     * IRQ (cmd_device_reset returns false; the dispatch leaves status untouched).
     * qemu does NOT abort it — the canonical ATAPI reset primitive. */
    movb    $0xA0, %al; movw $0x176, %dx; outb %al, %dx   /* reselect secondary master */
    movb    $0x08, %al; movw $0x177, %dx; outb %al, %dx   /* DEVICE RESET */
    movw    $0x177, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SEC_DR_ST
    movw    $0x171, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SEC_DR_ER
    movw    $0x172, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SEC_DR_NS
    movw    $0x173, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SEC_DR_SEC
    movw    $0x174, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SEC_DR_LC
    movw    $0x175, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SEC_DR_HC
    movw    $0x176, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SEC_DR_DH

    /* SEC-7 FLUSH CACHE (0xE7): ALL_OK -> cmd_flush_cache COMPLETES (not abort). */
    movb    $0xE7, %al; movw $0x177, %dx; outb %al, %dx
    movw    $0x177, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SEC_FC_ST
    movw    $0x171, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SEC_FC_ER

    /* SEC-8 SET FEATURES (0xEF, sub=0x02): ALL_OK -> cmd_set_features (the golden
     * decides complete-vs-abort on the empty CD; the RTL is built to match it). */
    movb    $0x02, %al; movw $0x171, %dx; outb %al, %dx   /* feature sub = 0x02 */
    movb    $0xEF, %al; movw $0x177, %dx; outb %al, %dx
    movw    $0x177, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SEC_EF_ST
    movw    $0x171, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SEC_EF_ER

    /* SEC-9 unsupported opcode bare abort (0xB0 SMART = HD_CFA_OK, NOT CD_OK ->
     * ide_abort_command WITHOUT ide_set_signature): a lcyl pre-written to 0x55 must
     * SURVIVE (qemu leaves the task file untouched on a permission-denied abort). */
    movb    $0x55, %al; movw $0x174, %dx; outb %al, %dx   /* lcyl <- 0x55 (broadcast) */
    movb    $0xB0, %al; movw $0x177, %dx; outb %al, %dx   /* SMART (unsupported on CD) */
    movw    $0x177, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SEC_BA_ST  /* 0x41 */
    movw    $0x171, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SEC_BA_ER  /* 0x04 */
    movw    $0x174, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SEC_BA_LC  /* 0x55 kept */

    /* SEC-10 SRST on the secondary (0x376 bit2 edge): ATAPI post-reset status (qemu
     * sets the CD status — the golden pins it), error 0x01, signature restored. */
    movb    $0x06, %al; movw $0x376, %dx; outb %al, %dx   /* nIEN(2)|SRST(4) assert */
    movb    $0x02, %al; movw $0x376, %dx; outb %al, %dx   /* SRST deassert, nIEN kept */
    movw    $0x177, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SEC_SR_ST
    movw    $0x171, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_SEC_SR_ER
    movb    $0xA0, %al; movw $0x176, %dx; outb %al, %dx   /* reselect master */

    /* =============== M8.4f-pre PCI config (PIIX3 IDE 00:01.1) ============ */
    /* Program the bus-master IDE BAR4 via the 0xCF8/0xCFC config mechanism so the
     * BMIDE register block (M8.4f) becomes addressable. Empirically validated vs
     * the live qemu-system golden: vendor/device 0x70108086, class 0x01018000,
     * BAR4 unmapped (0x00000001) until written -> 0xC001, command IO|BM. Uses the
     * 32-bit outl/inl I/O path (io_size=4) — first exercise of it under soc_en. */

    /* vendor/device id (reg 0x00) -> 0x70108086 */
    movl    $0x80000900, %eax; movw $0xCF8, %dx; outl %eax, %dx
    movw    $0xCFC, %dx; inl %dx, %eax; movl %eax, R_PCI_VID

    /* class code / prog-if (reg 0x08) -> 0x01018000 */
    movl    $0x80000908, %eax; movw $0xCF8, %dx; outl %eax, %dx
    movw    $0xCFC, %dx; inl %dx, %eax; movl %eax, R_PCI_CLASS

    /* PCI_COMMAND (reg 0x04) pre-enable word -> 0x0000 */
    movl    $0x80000904, %eax; movw $0xCF8, %dx; outl %eax, %dx
    movw    $0xCFC, %dx; inw %dx, %ax; andl $0xFFFF, %eax; movl %eax, R_PCI_CMD0

    /* BAR4 (reg 0x20) pre-program -> 0x00000001 (unmapped, I/O indicator) */
    movl    $0x80000920, %eax; movw $0xCF8, %dx; outl %eax, %dx
    movw    $0xCFC, %dx; inl %dx, %eax; movl %eax, R_PCI_BAR0

    /* program BAR4 = 0xC000 ; read back -> 0x0000C001 */
    movl    $0x80000920, %eax; movw $0xCF8, %dx; outl %eax, %dx
    movl    $0x0000C000, %eax; movw $0xCFC, %dx; outl %eax, %dx
    movl    $0x80000920, %eax; movw $0xCF8, %dx; outl %eax, %dx
    movw    $0xCFC, %dx; inl %dx, %eax; movl %eax, R_PCI_BAR1

    /* enable PCI_COMMAND.IO (bit0) + bus-master (bit2) = 0x0005 ; read back */
    movl    $0x80000904, %eax; movw $0xCF8, %dx; outl %eax, %dx
    movw    $0x0005, %ax; movw $0xCFC, %dx; outw %ax, %dx
    movl    $0x80000904, %eax; movw $0xCF8, %dx; outl %eax, %dx
    movw    $0xCFC, %dx; inw %dx, %ax; andl $0xFFFF, %eax; movl %eax, R_PCI_CMD1

    /* =============== M8.4f single-PRD READ DMA (0xC8) ==================== */
    /* The BMIDE block is now decodable (PCI_COMMAND.IO set, BAR4=0xC000). Build one
     * EOT PRD describing a 512-byte buffer, issue READ DMA of LBA0, poll BMIS to
     * completion, then CPU-read the buffer back byte-identical to the disk — the
     * non-vacuous proof the engine moved the sector into the RAM the CPU sees.
     * nIEN is set, so BMIS-INT (bit2) is NEVER raised -> poll DMAING (bit0). */

    /* PRD @0x5000: dword0 = buffer base 0x6000 ; dword1 = EOT|count(512)=0x80000200 */
    movl    $DMA_BUF,     PRD_TBL
    movl    $0x80000200,  PRD_TBL+4

    /* pre-fill the DMA target buffer with a 0xFFFFFFFF sentinel (distinct from the
     * disk content 0x0000..0xAA55 and the PIO buffers) so a no-op DMA is caught */
    movl    $128, %ecx
    movl    $DMA_BUF, %edi
    movl    $0xFFFFFFFF, %eax
1:  movl    %eax, (%edi); addl $4, %edi; decl %ecx; jnz 1b

    /* program BMIDTP = PRD table addr ; read back (low-2 masked) -> 0x00005000 */
    movl    $PRD_TBL, %eax; movw $0xC004, %dx; outl %eax, %dx
    movw    $0xC004, %dx; inl %dx, %eax; movl %eax, R_DMA_DTP

    /* task file: nsector=1, LBA=0, devhead 0xE0 (LBA|master) ; issue READ DMA */
    movb    $0x01, %al; movw $0x1F2, %dx; outb %al, %dx
    xorb    %al, %al
    movw    $0x1F3, %dx; outb %al, %dx
    movw    $0x1F4, %dx; outb %al, %dx
    movw    $0x1F5, %dx; outb %al, %dx
    movb    $0xE0, %al; movw $0x1F6, %dx; outb %al, %dx
    movb    $0xC8, %al; movw $0x1F7, %dx; outb %al, %dx

    /* M8.4f review: after 0xC8 (BEFORE the BMIC-START), qemu's ide_sector_start_dma
     * leaves the task-file status = READY|SEEK|DRQ = 0x58 (DRQ set, no BUSY/BSY) —
     * cmd_read_dma returns false so the dispatch never clears it. Grade it. */
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_DMA_C8ST  /* 0x58 */
    movw    $0x3F6, %dx; inb %dx, %al; andl $0xFF, %eax                         /* 0x58 alt-status */

    /* launch: BMIC = START(0x01)|RWCON-READ(0x08) = 0x09 ; read back (cmd&0x09) */
    movb    $0x09, %al; movw $0xC000, %dx; outb %al, %dx
    movw    $0xC000, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_DMA_BMIC

    /* poll BMIS until DMAING (bit0) clears, then grade the final BMIS */
1:  movw    $0xC002, %dx; inb %dx, %al; testb $0x01, %al; jnz 1b
    movw    $0xC002, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_DMA_BMIS

    /* task-file status (0x50) + the LBA-register advance after the DMA */
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_DMA_ST
    movw    $0x1F2, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_DMA_NS
    movw    $0x1F3, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_DMA_SEC

    /* CPU read-back: grade every dword of the DMA'd buffer (=disk LBA0) + pin the
     * first word (0x0000) and the boot-signature word255 (0xAA55) */
    movl    $128, %ecx
    movl    $DMA_BUF, %esi
1:  movl    (%esi), %eax; addl $4, %esi; decl %ecx; jnz 1b
    movl    DMA_BUF,     %eax; andl $0xFFFF, %eax; movl %eax, R_DMA_W0
    movl    DMA_BUF+508, %eax; shrl $16, %eax;     movl %eax, R_DMA_W255

    /* =============== M8.4d2 READ/WRITE MULTIPLE (0xC4/0xC5) ============= */
    /* Block-mode PIO: SET MULTIPLE (0xC6) sets the block size; 0xC4/0xC5 transfer
     * MIN(nsector, mult_sectors) sectors per DRQ window (one window of n*512 B),
     * vs one-sector-per-window for 0x20/0x30. The ONLY qemu difference is
     * req_nb_sectors (mult vs 1); the drain/fill engine is shared. */

    /* TEST A: SET MULTIPLE 4, then READ MULTIPLE 4 @ LBA0 (single 4-sector block) */
    movb    $4, %al;    movw $0x1F2, %dx; outb %al, %dx       /* nsector=4 */
    movb    $0xC6, %al; movw $0x1F7, %dx; outb %al, %dx       /* SET MULTIPLE */
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_RMSM_ST /* 0x50 */
    movb    $4, %al;    movw $0x1F2, %dx; outb %al, %dx       /* nsector=4 */
    xorb    %al, %al
    movw    $0x1F3, %dx; outb %al, %dx                        /* LBA[7:0]=0 */
    movw    $0x1F4, %dx; outb %al, %dx
    movw    $0x1F5, %dx; outb %al, %dx
    movb    $0xE0, %al; movw $0x1F6, %dx; outb %al, %dx       /* LBA master */
    movb    $0xC4, %al; movw $0x1F7, %dx; outb %al, %dx       /* READ MULTIPLE */
1:  movw    $0x1F7, %dx; inb %dx, %al; testb $0x80, %al; jnz 1b
    testb   $0x08, %al; jz fail                               /* DRQ set (0x58) */
    /* drain sector 0 (256 words) into BUF_RM */
    movl    $256, %ecx; movl $BUF_RM, %edi; movw $0x1F0, %dx
2:  inw     %dx, %ax; stosw; decl %ecx; jnz 2b
    /* DISCRIMINATOR: the block window does NOT re-arm at the sector-0/1 boundary
     * (DRQ still set, status 0x58) -- a per-sector-window RTL would diverge here */
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_RM_MID  /* 0x58 */
    /* drain sectors 1-3 (768 words), continuing into BUF_RM */
    movl    $768, %ecx; movw $0x1F0, %dx
2:  inw     %dx, %ax; stosw; decl %ecx; jnz 2b
    movl    BUF_RM,      %eax; andl $0xFFFF, %eax; movl %eax, R_RM_W0    /* 0x0000 */
    movl    BUF_RM+508,  %eax; shrl $16, %eax;     movl %eax, R_RM_W255  /* 0xAA55 */
    movl    BUF_RM+512,  %eax; andl $0xFFFF, %eax; movl %eax, R_RM_W256  /* 0x0100 */
    movl    BUF_RM+1024, %eax; andl $0xFFFF, %eax; movl %eax, R_RM_W512  /* 0x0200 */
    movl    BUF_RM+1536, %eax; andl $0xFFFF, %eax; movl %eax, R_RM_W768  /* 0x0300 */
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_RM_ST  /* 0x50 */
    movw    $0x1F2, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_RM_NS  /* 0x00 */
    movw    $0x1F3, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_RM_SEC /* 0x04 */

    /* TEST B: partial last block -- READ MULTIPLE nsector=6 @ LBA0, mult still 4
     * -> block1 = 4 sectors (1024 words), block2 = MIN(2,4) = 2 sectors (512 words) */
    movb    $6, %al; movw $0x1F2, %dx; outb %al, %dx
    xorb    %al, %al
    movw    $0x1F3, %dx; outb %al, %dx
    movw    $0x1F4, %dx; outb %al, %dx
    movw    $0x1F5, %dx; outb %al, %dx
    movb    $0xE0, %al; movw $0x1F6, %dx; outb %al, %dx
    movb    $0xC4, %al; movw $0x1F7, %dx; outb %al, %dx
1:  movw    $0x1F7, %dx; inb %dx, %al; testb $0x80, %al; jnz 1b
    testb   $0x08, %al; jz fail
    /* drain block1 (4 sectors = 1024 words), graded per-record (discard) */
    movl    $1024, %ecx; movw $0x1F0, %dx
2:  inw     %dx, %ax; decl %ecx; jnz 2b
    /* block boundary: window RE-ARMED for block2 (DRQ still set, 0x58) */
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_RMP_MID /* 0x58 */
    /* drain block2 (2 sectors = 512 words) into BUF_RM */
    movl    $512, %ecx; movl $BUF_RM, %edi; movw $0x1F0, %dx
2:  inw     %dx, %ax; stosw; decl %ecx; jnz 2b
    movl    BUF_RM,     %eax; andl $0xFFFF, %eax; movl %eax, R_RMP_W1024 /* 0x0400 (LBA4 w0) */
    movl    BUF_RM+512, %eax; andl $0xFFFF, %eax; movl %eax, R_RMP_W1280 /* 0x0500 (LBA5 w0) */
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_RMP_ST  /* 0x50 */
    movw    $0x1F2, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_RMP_NS  /* 0x00 */
    movw    $0x1F3, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_RMP_SEC /* 0x06 */

    /* TEST C: READ MULTIPLE with mult_sectors=0 -> abort (no SET MULTIPLE block).
     * Disable via SET MULTIPLE 0, then 0xC4 must abort 0x41/0x04 with NO DRQ. */
    xorb    %al, %al;   movw $0x1F2, %dx; outb %al, %dx       /* nsector=0 */
    movb    $0xC6, %al; movw $0x1F7, %dx; outb %al, %dx       /* SET MULTIPLE 0 (disable) */
    movb    $4, %al;    movw $0x1F2, %dx; outb %al, %dx       /* nsector=4 */
    xorb    %al, %al;   movw $0x1F3, %dx; outb %al, %dx
    movb    $0xE0, %al; movw $0x1F6, %dx; outb %al, %dx
    movb    $0xC4, %al; movw $0x1F7, %dx; outb %al, %dx       /* READ MULTIPLE (mult=0) */
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_RM_ABRT_ST /* 0x41 */
    movw    $0x1F1, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_RM_ABRT_ER /* 0x04 */
    /* restore the block size for TEST D */
    movb    $4, %al;    movw $0x1F2, %dx; outb %al, %dx
    movb    $0xC6, %al; movw $0x1F7, %dx; outb %al, %dx

    /* TEST D: WRITE MULTIPLE 0xC5 @ scratch LBA 112, nsector=2, mult=4 (one 2-sector
     * window). Fill 0xE0xx then PIO read-back -> proves the block write moved data. */
    movb    $2, %al;  movw $0x1F2, %dx; outb %al, %dx
    movb    $112, %al; movw $0x1F3, %dx; outb %al, %dx        /* LBA[7:0]=112 */
    xorb    %al, %al
    movw    $0x1F4, %dx; outb %al, %dx
    movw    $0x1F5, %dx; outb %al, %dx
    movb    $0xE0, %al; movw $0x1F6, %dx; outb %al, %dx
    movb    $0xC5, %al; movw $0x1F7, %dx; outb %al, %dx        /* WRITE MULTIPLE */
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_WM_DRQ /* 0x58 */
    /* fill 2 sectors (512 words): sector0 = 0xE000+j, sector1 = 0xE100+j */
    movl    $256, %ecx; movw $0x1F0, %dx; movw $0xE000, %ax
2:  outw    %ax, %dx; incw %ax; decl %ecx; jnz 2b              /* LBA112: 0xE000..0xE0FF */
    movl    $256, %ecx; movw $0x1F0, %dx; movw $0xE100, %ax
2:  outw    %ax, %dx; incw %ax; decl %ecx; jnz 2b              /* LBA113: 0xE100..0xE1FF */
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_WM_ST  /* 0x50 */
    movw    $0x1F2, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_WM_NS  /* 0x00 */
    movw    $0x1F3, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_WM_SEC /* 0x72=114 */
    /* read-back LBA112 (0x20) -> 0xE000 (proves the block write); then LBA113 -> 0xE100 */
    movb    $1, %al;   movw $0x1F2, %dx; outb %al, %dx
    movb    $112, %al; movw $0x1F3, %dx; outb %al, %dx
    movb    $0xE0, %al; movw $0x1F6, %dx; outb %al, %dx
    movb    $0x20, %al; movw $0x1F7, %dx; outb %al, %dx
1:  movw    $0x1F7, %dx; inb %dx, %al; testb $0x80, %al; jnz 1b
    testb   $0x08, %al; jz fail
    movl    $256, %ecx; movl $BUF_RM, %edi; movw $0x1F0, %dx
2:  inw     %dx, %ax; stosw; decl %ecx; jnz 2b
    movl    BUF_RM, %eax; andl $0xFFFF, %eax; movl %eax, R_WM_RB0  /* 0xE000 */
    movb    $1, %al;   movw $0x1F2, %dx; outb %al, %dx
    movb    $113, %al; movw $0x1F3, %dx; outb %al, %dx
    movb    $0xE0, %al; movw $0x1F6, %dx; outb %al, %dx
    movb    $0x20, %al; movw $0x1F7, %dx; outb %al, %dx
1:  movw    $0x1F7, %dx; inb %dx, %al; testb $0x80, %al; jnz 1b
    testb   $0x08, %al; jz fail
    movl    $256, %ecx; movl $BUF_RM, %edi; movw $0x1F0, %dx
2:  inw     %dx, %ax; stosw; decl %ecx; jnz 2b
    movl    BUF_RM, %eax; andl $0xFFFF, %eax; movl %eax, R_WM_RB256 /* 0xE100 */

    /* TEST E: re-IDENTIFY after SET MULTIPLE -> w59 stays 0x0110 (qemu caches the
     * IDENTIFY block; cmd_set_multiple_mode never re-patches w59) */
    movb    $0xEC, %al; movw $0x1F7, %dx; outb %al, %dx
1:  movw    $0x1F7, %dx; inb %dx, %al; testb $0x80, %al; jnz 1b
    testb   $0x08, %al; jz fail
    movl    $256, %ecx; movl $BUF_RM, %edi; movw $0x1F0, %dx
2:  inw     %dx, %ax; stosw; decl %ecx; jnz 2b
    movl    BUF_RM+118, %eax; andl $0xFFFF, %eax; movl %eax, R_RM_W59 /* word59 = 0x0110 */

    /* TEST F: READ MULTIPLE whose BLOCK STRADDLES the last LBA. qemu range-checks the
     * WHOLE block atomically (ide_sect_range_ok with n=MIN(nsector,mult) sectors): a
     * block whose start is in-range but end is past the last sector aborts ENTIRELY
     * (0x41/0x04, NO DRQ, regs UNMOVED), delivering zero sectors. mult is 4 (restored
     * in TEST C); 0xC4 @ LBA126 nsec=4 -> the 4-sector block [126..129] straddles
     * (128,129 OOR with DISK_SECTORS=128). */
    movb    $4, %al;   movw $0x1F2, %dx; outb %al, %dx
    movb    $126, %al; movw $0x1F3, %dx; outb %al, %dx        /* LBA[7:0]=126 */
    xorb    %al, %al
    movw    $0x1F4, %dx; outb %al, %dx
    movw    $0x1F5, %dx; outb %al, %dx
    movb    $0xE0, %al; movw $0x1F6, %dx; outb %al, %dx
    movb    $0xC4, %al; movw $0x1F7, %dx; outb %al, %dx        /* READ MULTIPLE (straddles) */
    movw    $0x1F7, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_RMX_ST  /* 0x41 */
    movw    $0x1F1, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_RMX_ER  /* 0x04 */
    movw    $0x1F3, %dx; inb %dx, %al; andl $0xFF, %eax; movl %eax, R_RMX_SEC /* 0x7E (126, unmoved) */

    /* =============== M8.5 PCI bus-0 enumeration (controlled subset) ===== */
    /* Scan the chipset-core functions qemu's -machine pc creates on bus 0, read
     * their config IDs via 0xCF8/0xCFC (32-bit), size the IDE BAR4, and confirm
     * the genuinely-absent slots read 0xFFFFFFFF. A CONTROLLED subset (NOT a blind
     * dev 0..31 sweep): the unmodeled-but-present e1000 (00:03.0) + the VGA mem-BAR
     * + chipset quirk regs are never read, so they cannot diverge (documented). All
     * config IDs were captured from the live gate qemu; every inl is graded.
     * CONFIG_ADDRESS = 0x80000000 | (devfn<<8) | (reg & 0xFC). */

    /* 00:00.0 i440FX host bridge */
    movl    $0x80000000, %eax; movw $0xCF8, %dx; outl %eax, %dx   /* devfn 0x00, reg 0x00 */
    movw    $0xCFC, %dx; inl %dx, %eax; movl %eax, R_PCI_H00       /* 0x12378086 */
    movl    $0x80000008, %eax; movw $0xCF8, %dx; outl %eax, %dx   /* reg 0x08 */
    movw    $0xCFC, %dx; inl %dx, %eax; movl %eax, R_PCI_H08       /* 0x06000002 */

    /* 00:01.0 PIIX3 ISA bridge (devfn 0x08, multifunction header) */
    movl    $0x80000800, %eax; movw $0xCF8, %dx; outl %eax, %dx   /* devfn 0x08, reg 0x00 */
    movw    $0xCFC, %dx; inl %dx, %eax; movl %eax, R_PCI_I00       /* 0x70008086 */
    movl    $0x80000804, %eax; movw $0xCF8, %dx; outl %eax, %dx   /* reg 0x04 status|cmd */
    movw    $0xCFC, %dx; inl %dx, %eax; movl %eax, R_PCI_I04       /* 0x02000000 */
    movl    $0x80000808, %eax; movw $0xCF8, %dx; outl %eax, %dx   /* reg 0x08 class */
    movw    $0xCFC, %dx; inl %dx, %eax; movl %eax, R_PCI_I08       /* 0x06010000 */
    movl    $0x8000080C, %eax; movw $0xCF8, %dx; outl %eax, %dx   /* reg 0x0C header-type */
    movw    $0xCFC, %dx; inl %dx, %eax; movl %eax, R_PCI_I0C       /* 0x00800000 (multifn bit7) */

    /* 00:01.1 PIIX3 IDE (devfn 0x09) */
    movl    $0x80000900, %eax; movw $0xCF8, %dx; outl %eax, %dx
    movw    $0xCFC, %dx; inl %dx, %eax; movl %eax, R_PCI_D00       /* 0x70108086 */
    movl    $0x80000904, %eax; movw $0xCF8, %dx; outl %eax, %dx   /* reg 0x04 dword (status fix) */
    movw    $0xCFC, %dx; inl %dx, %eax; movl %eax, R_PCI_D04       /* 0x02800005 (status 0x0280 | cmd 0x0005 set by M8.4f-pre) */
    movl    $0x80000908, %eax; movw $0xCF8, %dx; outl %eax, %dx
    movw    $0xCFC, %dx; inl %dx, %eax; movl %eax, R_PCI_D08       /* 0x01018000 */
    movl    $0x8000092C, %eax; movw $0xCF8, %dx; outl %eax, %dx   /* reg 0x2C subsystem */
    movw    $0xCFC, %dx; inl %dx, %eax; movl %eax, R_PCI_D2C       /* 0x11001AF4 */

    /* 00:01.3 PIIX4 PM (devfn 0x0B) */
    movl    $0x80000B00, %eax; movw $0xCF8, %dx; outl %eax, %dx
    movw    $0xCFC, %dx; inl %dx, %eax; movl %eax, R_PCI_PM00      /* 0x71138086 */
    movl    $0x80000B08, %eax; movw $0xCF8, %dx; outl %eax, %dx
    movw    $0xCFC, %dx; inl %dx, %eax; movl %eax, R_PCI_PM08      /* 0x06800003 */
    movl    $0x80000B3C, %eax; movw $0xCF8, %dx; outl %eax, %dx   /* reg 0x3C interrupt pin */
    movw    $0xCFC, %dx; inl %dx, %eax; movl %eax, R_PCI_PM3C      /* 0x00000100 (pin A) */

    /* 00:02.0 std-VGA (devfn 0x10) */
    movl    $0x80001000, %eax; movw $0xCF8, %dx; outl %eax, %dx
    movw    $0xCFC, %dx; inl %dx, %eax; movl %eax, R_PCI_VG00      /* 0x11111234 */
    movl    $0x80001008, %eax; movw $0xCF8, %dx; outl %eax, %dx
    movw    $0xCFC, %dx; inl %dx, %eax; movl %eax, R_PCI_VG08      /* 0x03000002 */

    /* IDE BAR4 (reg 0x20) sizing: write all-ones -> read the size mask 0xFFFFFFF1
     * (16-byte I/O BAR), then restore 0xC000 -> 0xC001 (BMIDE window stays benign) */
    movl    $0x80000920, %eax; movw $0xCF8, %dx; outl %eax, %dx
    movl    $0xFFFFFFFF, %eax; movw $0xCFC, %dx; outl %eax, %dx
    movl    $0x80000920, %eax; movw $0xCF8, %dx; outl %eax, %dx
    movw    $0xCFC, %dx; inl %dx, %eax; movl %eax, R_PCI_BARSZ     /* 0xFFFFFFF1 */
    movl    $0x80000920, %eax; movw $0xCF8, %dx; outl %eax, %dx
    movl    $0x0000C000, %eax; movw $0xCFC, %dx; outl %eax, %dx
    movl    $0x80000920, %eax; movw $0xCF8, %dx; outl %eax, %dx
    movw    $0xCFC, %dx; inl %dx, %eax; movl %eax, R_PCI_BARRE     /* 0x0000C001 */

    /* genuinely-absent functions -> 0xFFFFFFFF (00:00.1 devfn 0x01, 00:01.2 devfn 0x0A) */
    movl    $0x80000100, %eax; movw $0xCF8, %dx; outl %eax, %dx
    movw    $0xCFC, %dx; inl %dx, %eax; movl %eax, R_PCI_ABS1      /* 0xFFFFFFFF */
    movl    $0x80000A00, %eax; movw $0xCF8, %dx; outl %eax, %dx
    movw    $0xCFC, %dx; inl %dx, %eax; movl %eax, R_PCI_ABS2      /* 0xFFFFFFFF */
    /* CONFIG_ADDRESS bit31=0 (mechanism disabled) -> CONFIG_DATA reads 0xFFFFFFFF */
    movl    $0x00000900, %eax; movw $0xCF8, %dx; outl %eax, %dx
    movw    $0xCFC, %dx; inl %dx, %eax; movl %eax, R_PCI_OFF       /* 0xFFFFFFFF */

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
