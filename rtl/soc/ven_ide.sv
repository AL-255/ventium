// ============================================================================
// ven_ide.sv -- Ventium SoC (M8.4a/b/c) IDE/ATA controller: PIO, primary master.
//   M8.4a: IDENTIFY + READ SECTORS + DIAGNOSTIC + signature + absent-slave.
//   M8.4b: + WRITE SECTORS (0x30/0x31, single + multi-sector) — the data-port
//          host->device fill, symmetric to the READ drain.
//   M8.4c: + PIO fidelity — OOR-LBA clean abort, LBA-register advance, CHS
//          addressing, command-while-DRQ + read-during-write guards, the misc
//          commands 0x70/0x10/0x91, and the per-command error-register clear.
//   M8.4d: + SET MULTIPLE (0xC6), SET FEATURES (0xEF, incl 0x03 transfer-mode /
//          0x02+0x82 write-cache patching the cached IDENTIFY words 62/63/85/88),
//          and SRST (0x3F6 bit2). SET MULTIPLE is status-only (qemu does NOT patch
//          the cached IDENTIFY w59). Tier 2 (0x91 geometry, CHS reg-advance) +
//          READ/WRITE MULTIPLE + the register-trajectory lag + LBA48 deferred.
//   M8.4e: + parameterized as the SECONDARY channel's EMPTY ATAPI CD-ROM
//          (IS_ATAPI=1 / HAS_DISK=0): the 0xEB14 signature, DIAGNOSTIC status 0x00.
//   M8.4f: + IDE BUS-MASTER DMA (HAS_DMA=1 on the primary): the BMIDE register
//          block (BMIC/BMIS/BMIDTP at the PCI BAR4 window) + a memory-master port
//          + a single-PRD single-sector READ DMA (0xC8). The BMIC-START OUT is held
//          (the SoC gates io_ack on dma_busy) so the core parks in S_IO while the
//          engine walks the PRD + copies 512 B disk[]->RAM — matching qemu's
//          synchronous bmdma_cmd_writeb. Polled via BMIS DMAING (nIEN gates INT).
//   M8.4e2: + (review fold-back) the ATAPI command surface made command-specific
//          (NOT a blanket abort): DEVICE RESET (0x08) -> ide_reset+signature/status
//          0x00/no-IRQ; SET FEATURES (0xEF) completes; FLUSH CACHE (0xE7) ABORTS at
//          runtime on the empty CD (no medium); IDENTIFY/READ (0xEC/0x20/0x21) ->
//          full-signature abort; unsupported opcodes -> BARE abort (regs untouched);
//          ATAPI SRST status 0x00. The absent slave's INDEPENDENT nsector/sector
//          shadow (was shared). Idle/write-window data-port reads return 0. The full
//          PACKET surface (0xA0 / 0xA1, which qemu DRQ-enters) is still deferred — a
//          DOCUMENTED divergence the directed test issues neither of.
// ============================================================================
//
// DEVICE: a single ATA hard disk on the PRIMARY channel, MASTER (unit 0), PIO
// mode only (no bus-master DMA, no PCI BAR4 -- qemu's bus->dma=ide_dma_nop by
// default, so PIO is fully functional with zero DMA/8237 dependency).
//   command block : 0x1F0-0x1F7  (cs)
//   control block : 0x3F6        (cs_ctl)
//   slave (unit 1): ABSENT  (selecting it: status/error/alt-status read 0x00)
//
// GROUNDING (CPU-observable semantics, QEMU 8.2.2 hw/ide/core.c + ioport.c):
//   ide_ioport_read/write (the task-file register decode + the absent-drive
//     mask: only ERROR/STATUS read 0 for the selected absent slave),
//   ide_exec_cmd (command dispatch), ide_identify (the 256-word IDENTIFY block),
//   ide_sector_read + cmd_write_pio/ide_sector_write/ide_data_writew (the data-
//     port PIO READ + WRITE transfers: BSY->DRQ, drain/fill, commit, end),
//   cmd_exec_dev_diagnostic (error=0x01, select=ATA_DEV_ALWAYS_ON=0xA0),
//   ide_abort_command (status=0x41, error=0x04), ide_reset (signature).
// Every value this device produces was first OBSERVED under qemu-system-i386 (a
// single-step golden) and is graded byte-identical per-record by the `pide` gate.
//
// DIFFERENTIAL SURFACE (deterministic, clk-sampled, reproducible):
//   - the task-file register state + reset signature,
//   - the IDENTIFY 256-word block (geometry words COMPUTED from the geometry
//     parameters; the model/serial/firmware strings + feature/capability words
//     are config-pinned constants captured from qemu 8.2.2 for the fixed single
//     `-drive if=ide,index=0` 128-sector config -- documented build-pinned data,
//     the same category as the disk image; the per-record compare is REAL: the
//     committed constants here are graded against a FRESHLY generated golden, so
//     a qemu drift is caught, not hidden),
//   - the READ SECTORS data words (single + MULTI-sector, byte-identical to the
//     single-source disk image; LBA->offset addressing + the per-sector PIO
//     continuation modeled and GATE-PROVEN),
//   - the WRITE SECTORS path (M8.4b, single + MULTI-sector): the write-direction
//     DRQ status handshake (0x58 immediate, re-armed per sector, 0x50 on commit)
//     + the write-then-read-back (a known pattern written to a scratch LBA reads
//     back byte-identical -- the disk[] mutation is the inverse of the READ),
//   - the absent-slave masking (status/error/alt-status) + DIAGNOSTIC.
//   - M8.4c PIO FIDELITY (modeled + GATE-PROVEN): the OUT-OF-RANGE-LBA clean abort
//     (READ aborts upfront 0x41/0x04 no-DRQ; WRITE / multi-sector crossing commits
//     the in-range sectors then aborts on the OOR sector's last word, disk[]
//     untouched for the OOR sector -- matching qemu's ide_sect_range_ok deferred
//     check); the LBA-register advance after a transfer (ide_set_sector) -- for a
//     single-sector transfer + the FINAL-sector value of a multi-sector one (the
//     mid-transfer trajectory is a boundary, below); CHS addressing (devhead
//     bit6=0 -> (cyl*HEADS+head)*SECS+sector-1); the command-while-DRQ ignore +
//     the read-during-write-DRQ 0x0000 guard + the mid-DRQ task-file-register
//     WRITE drop (0x1F1-0x1F6 gated on !DRQ, qemu core.c:1287 -- modeled but not
//     separately gate-tested, see the trajectory boundary); the misc commands
//     0x70/0x10/0x91 completing 0x50/0x00; and the error-register clear on every
//     accepted command (qemu core.c:2168).
//   - M8.4d ATA command-set: SET MULTIPLE (0xC6, accept pow2<=16 / abort, status-
//     only — w59 stays cached); SET FEATURES (0xEF — 0x03 transfer-mode patches the
//     cached w62/63/88, 0x02/0x82 write-cache patch w85 to 0x4021/0x4001, no-op
//     group, unsupported abort); SRST (0x3F6 bit2 edge, synchronous signature
//     restore, no BSY). All gate-proven vs a re-IDENTIFY / status read.
//   - M8.4f BUS-MASTER DMA (HAS_DMA): the BMIDE registers (BMIC cmd&0x09 / BMIS
//     DMAING+W1C / BMIDTP dword), READ DMA 0xC8, the PRD-walk + single-sector copy.
//     Gate-proven: BMIDTP readback (0x5000), BMIC (0x09), the post-completion BMIS
//     (0x00, no INT under nIEN), task status 0x50, the LBA advance (nsector 0 /
//     sector 1), and the CPU read-back of the DMA'd buffer byte-identical to disk
//     LBA0 (word255=0xAA55) — the non-vacuous proof the engine moved the sector.
// OFF-SURFACE (documented oracle boundaries, never read in a way that exposes
// them): the IRQ14 line-edge instruction boundary (the test sets nIEN so NO IRQ
// is ever raised -- like the quiescent IR1/IR8/IR12 precedent) and the
// inter-instruction async-BSY-vs-synchronous timing (qemu's block READ and the
// WRITE-completion write-back both settle in an async BH before the next single-
// step, so the golden never observes a lingering BSY/0xD0; the RTL settles
// synchronously within the S_IO window -> the same poll sequence).
// MODELING BOUNDARIES (surfaced by the adversarial reviews; all on paths the
// directed test provably does NOT reach, so the EQUIVALENT result is honest --
// documented here, not hidden):
//   * ABSENT SLAVE (M8.4e/e2, now MODELED + GATE-PROVEN, no longer a boundary):
//     qemu masks ONLY error/status/alt-status to 0 for the selected absent slave,
//     and returns the slave's INDEPENDENT register shadow for the rest. This RTL
//     models that shadow for lcyl/hcyl=0xFF AND nsector/sector (reset 1, tracking
//     the broadcast write but NOT a master command's advance) — gate-proven by
//     reading the slave's nsector(=1)/sector(=0) after a master READ advanced the
//     MASTER to nsector=0/sector=1. select needs no shadow (switching drives re-
//     writes 0x1F6, re-broadcasting it). Residual: the slave's error/status HOB
//     paths are unmodeled (the test reads only the masked 0).
//   * a data-port read OUTSIDE a read-DRQ window returns 0x0000 (qemu ide_data_readw
//     returns 0 unless DRQ && pio-out) -- MODELED (M8.4e2) for the idle, write-window,
//     and empty-CD (HAS_DISK=0, no X-leak) cases alike, gate-proven by an idle read.
//   * the WRITE data path commits each word to disk[] on its own clock, whereas
//     qemu buffers the 256 words in io_buffer and commits the whole 512 bytes at
//     end-of-sector (the async write-back); identical CPU-observable result --
//     the written LBA is not re-read until a later READ command, so the
//     intermediate disk[] state is never observed.
//   * the MISC-COMMAND STATE SIDE-EFFECTS are NOT modeled: 0x91 INIT-DEV-PARAMS
//     (cmd_specify) mutates qemu's current heads/sectors -> shifts IDENTIFY words
//     55/56 on a SUBSEQUENT IDENTIFY AND drives the CHS address translation
//     (ide_get_sector) of a SUBSEQUENT CHS transfer; 0x70 SEEK / 0x10 RECAL move
//     the head. This RTL only returns their 0x50/0x00 status. The test never
//     re-IDENTIFYs / does a post-0x91 CHS transfer / reads geometry, so unreachable.
//   * LBA-MODE MULTI-SECTOR REGISTER TRAJECTORY: (i) nsector (0x1F2) is forced to 0
//     at the first sector boundary instead of qemu's per-sector decrement (and
//     stays 0 on a crossing-abort vs qemu's remaining count); (ii) the READ visible
//     LBA registers LAG qemu by one sector DURING the transfer (the RTL advances at
//     end-of-drain; qemu at DRQ-window-open in ide_sector_read_cb). Both off the
//     test surface: regs are read only POST-transfer (where they agree: sector=1)
//     or at the crossing-abort (both land on the OOR LBA 0x80), never mid-transfer.
//   * CHS-mode REGISTER ADVANCE is off-by-one: after a CHS transfer qemu writes the
//     1-based CHS sector (ide_set_sector CHS branch core.c:657) whereas this RTL
//     writes the LBA28 decomposition; the test reads no task-file reg after a CHS
//     transfer.
//   * ATA HD unsupported commands (anything other than EC/20/21/30/31/70/10/91/90/
//     C6/EF) take the default 0x41/0x04 arm; the test issues none beyond those.
//   * ATAPI FULL-PACKET SURFACE (IS_ATAPI=1) is the one ACKNOWLEDGED DIVERGENCE:
//     0xA0 PACKET (cmd_packet core.c:1779) and 0xA1 IDENTIFY-PACKET (cmd_identify_
//     packet core.c:1743) are CD_OK and qemu opens a DRQ packet/identify phase for
//     them (status 0x58), whereas this RTL takes the bare-abort default (0x41/0x04).
//     This is the deferred full-ATAPI-command milestone; the directed test issues
//     NEITHER 0xA0 nor 0xA1, so the per-record EQUIVALENT remains honest. (Every
//     OTHER CD command IS modeled: 0x08/0x90/0xE7/0xEF/0xEC/0x20/0x21 + bare aborts.)
//   * BUS-MASTER DMA is bounded to ONE EOT PRD, ONE in-range sector, READ direction
//     (0xC8), polled (nIEN). DEFERRED (the test issues none): WRITE DMA (0xCA),
//     multi-PRD scatter-gather, multi-sector (nsector>1), LBA48 DMA (0x25/0x35), the
//     IRQ-driven (nIEN=0) completion + BMIS-INT path, the PRD-too-short/long +
//     BM_STATUS_ERROR branches, OOR-LBA DMA abort, a mid-flight BMIC STOP (1->0; the
//     held-OUT synchronous model has no mid-flight window), and secondary-channel DMA.
//     The engine transfers exactly 128 dwords (the PRD count field is assumed 512).
// See verif/sys/tests/pide/manifest.json for the full boundary accounting.
//
// DATA PORT (0x1F0): the directed test READS it with `inw %dx,%ax` and WRITES it
// with `outw %ax,%dx` (both 16-bit, 66 ED / 66 EF -- decoded unconditionally
// under soc_en). The SoC read mux returns the 16-bit data word zero-extended; the
// SoC drives the full 16-bit `wdata` for the WRITE. Each data-port access advances
// the word pointer by one (matching qemu's 16-bit data-port advance/commit).
// `insw`/`rep insw`/`rep outsw` are NOT used (the core gates INS/OUTS decode on
// cosim_en, so they HALT under soc_en) -- the plain inw/outw paths through S_IO.
//
// INTERFACE: the common Ventium SoC device contract.
//   rst : SYNCHRONOUS, ACTIVE-HIGH (PC RESET).
//   cs / cs_ctl : chip-selects from the SoC PMIO decoder (command / control blk).
//   we  : 1 = OUT (write), 0 = IN (read).
//   READS  are combinational off the registers/buffers (same-cycle-ack contract).
//   WRITES + read side-effects (data-port advance, IRQ lower on status read)
//          commit on the clocked edge.  rdata is 16 bits (data-port word; other
//          registers are zero-extended into the low byte).
// ============================================================================

module ven_ide #(
    parameter int unsigned DISK_SECTORS = 128,   // 64 KiB image (single-source)
    parameter int unsigned CYLS         = 2,     // qemu guess_chs_for_size(128)
    parameter int unsigned HEADS        = 16,
    parameter int unsigned SECS         = 63,
    // M8.4e: IS_ATAPI=1 = the empty ATAPI CD-ROM (secondary master) — ATAPI
    // signature 0xEB14, DIAGNOSTIC status 0x00/no-IRQ, IDENTIFY 0xEC + every HD
    // data command ABORT (the full PACKET/IDENTIFY-PACKET surface is deferred).
    // HAS_DISK=0 suppresses the $readmemh (the empty CD has no media).
    parameter bit          IS_ATAPI     = 1'b0,
    parameter bit          HAS_DISK     = 1'b1,
    // M8.4f: HAS_DMA=1 instantiates the bus-master DMA engine (BMIDE registers +
    // a memory-master port + READ DMA 0xC8). Only the primary ATA HD master sets it.
    parameter bit          HAS_DMA      = 1'b0
) (
    input  logic        clk,
    input  logic        rst,        // synchronous, active-high (PC RESET)
    input  logic        cs,         // primary command block 0x1F0-0x1F7
    input  logic        cs_ctl,     // control block 0x3F6
    input  logic        we,         // 1 = OUT (write), 0 = IN (read)
    input  logic [15:0] addr,       // I/O port address (addr[2:0] for cmd block)
    input  logic [15:0] wdata,      // write data: 16-bit data-port word (0x1F0,
                                    // WRITE SECTORS); task-file regs use wdata[7:0]

    output logic [15:0] rdata,      // 16-bit: data-port word, else {8'h0, regbyte}
    output logic        irq14,      // primary IDE interrupt (ISA IRQ14)

    // ---- M8.4f bus-master DMA: the BMIDE register block (decoded at the PCI
    //      BAR4 window by the SoC) + a memory-master port the DMA engine drives.
    //      addr[3:0] selects the BMIDE register (0=BMIC, 2=BMIS, 4-7=BMIDTP).
    input  logic        cs_bm,        // BMIDE register access (BAR4 window)
    input  logic [31:0] bm_wdata,     // 32-bit write data (BMIDTP is a dword)
    output logic [31:0] bm_rdata,     // BMIDE register read value
    output logic        dma_busy,     // 1 while the DMA engine masters memory
    output logic        dma_mem_req,  // single-beat memory-master handshake
    output logic        dma_mem_we,
    output logic [31:0] dma_mem_addr,
    output logic [31:0] dma_mem_wdata,
    output logic [3:0]  dma_mem_wstrb,
    input  logic [31:0] dma_mem_rdata,
    input  logic        dma_mem_ack
);

    // ---- ATA status bits (BSY is never set in M8.4a: reads settle within the
    //      S_IO window, so the golden never observes a lingering BSY) ---------
    localparam logic [7:0] ST_DRDY = 8'h40;
    localparam logic [7:0] ST_DSC  = 8'h10;
    localparam logic [7:0] ST_DRQ  = 8'h08;
    localparam logic [7:0] ST_ERR  = 8'h01;
    localparam logic [7:0] STAT_IDLE  = ST_DRDY | ST_DSC;            // 0x50
    localparam logic [7:0] STAT_DRQ   = ST_DRDY | ST_DSC | ST_DRQ;   // 0x58
    // reset/signature lcyl:hcyl — 0xEB14 marks an ATAPI device, 0x0000 an ATA HD
    localparam logic [7:0] SIG_LCYL   = IS_ATAPI ? 8'h14 : 8'h00;
    localparam logic [7:0] SIG_HCYL   = IS_ATAPI ? 8'hEB : 8'h00;
    localparam logic [7:0] STAT_ABORT = ST_DRDY | ST_ERR;            // 0x41
    localparam logic [7:0] ERR_ABRT   = 8'h04;                       // ABRT

    // ---- task-file registers (the single modeled drive) ------------------
    logic [7:0] r_error;     // 0x1F1 read (error)
    logic [7:0] r_feature;   // 0x1F1 write (features shadow; unused in M8.4a)
    logic [7:0] r_nsector;   // 0x1F2
    logic [7:0] r_sector;    // 0x1F3  LBA[7:0]
    logic [7:0] r_lcyl;      // 0x1F4  LBA[15:8]
    logic [7:0] r_hcyl;      // 0x1F5  LBA[23:16]
    // M8.4e: the absent slave's INDEPENDENT register shadow. qemu broadcasts
    // task-file writes to BOTH drives (ide_ioport_write writes ifs[0] AND ifs[1]),
    // but a *command* advances only the SELECTED drive (ide_set_sector touches the
    // active s). So an unwritten/unadvanced absent slave reads its own reset
    // signature: lcyl/hcyl=0xFF (vs the master's 0x00) and nsector/sector=1 —
    // diverging from the master once a master command advances the master's regs.
    // (select needs no shadow: you must re-write 0x1F6 to switch drives, which
    // re-broadcasts it.) The masked status/error/altstatus are handled separately.
    logic [7:0] r_slv_lcyl, r_slv_hcyl, r_slv_nsector, r_slv_sector;
    logic [7:0] r_select;    // 0x1F6  device/head (reset 0xA0)
    logic [7:0] r_status;    // 0x1F7
    logic [7:0] r_ctrl;      // 0x3F6  device control (bit1 nIEN, bit2 SRST)
    wire        unit1_sel = r_select[4];   // selected drive = slave (absent)
    wire        nien      = r_ctrl[1];     // 1 = IRQ disabled (polled)
    // ---- M8.4d SET FEATURES-mutable IDENTIFY words (qemu patches the cached
    //      identify_data for 0xEF subcmds 0x02/0x03; SET MULTIPLE does NOT) -----
    logic [15:0] r_w62, r_w63, r_w85, r_w88;

    // ---- PIO data-transfer state -----------------------------------------
    logic [8:0]  data_idx;     // word index 0..255 within the 512-byte buffer
    logic        in_identify;  // current PIO-in source: IDENTIFY table vs disk
    logic        in_write;     // current PIO transfer is host->device (WRITE SECTORS)
    logic [27:0] xfer_lba;     // current sector LBA (LBA28)
    logic [8:0]  nsec_left;    // sectors remaining in the multi-sector transfer

    // ---- M8.4f bus-master DMA: BMIDE register block + a PRD-walk/sector-copy FSM.
    //   BMIC  (off 0): bit0 START (SSBM), bit3 RWCON (1=device->memory READ DMA).
    //   BMIS  (off 2): bit0 DMAING (RO to sw), bit1 ERROR, bit2 INT (set only via
    //                  IRQ, gated by nIEN), bits 5/6 sw-R/W (DMA-capable).
    //   BMIDTP(off 4): the 32-bit PRD-table physical pointer (low 2 bits forced 0).
    // The single-PRD single-sector READ DMA: read one 8-byte EOT PRD (base+count)
    // from RAM at BMIDTP, then copy 512 bytes (128 dwords) from disk[] to RAM at the
    // PRD base. The START-write OUT is held (dma_busy gates io_ack at the SoC) for
    // the whole burst, so the core parks in S_IO with the mem bus free — exactly
    // like qemu's bmdma_cmd_writeb running dma_cb synchronously within the OUT.
    logic [7:0]  r_bmic;       // BMIC  (cmd & 0x09)
    logic [7:0]  r_bmis;       // BMIS
    logic [31:0] r_bmidtp;     // BMIDTP
    logic        dma_pending;  // a READ DMA (0xC8) is armed, awaiting START
    logic [27:0] dma_lba;      // the LBA captured at 0xC8
    typedef enum logic [1:0] { DMA_IDLE, DMA_PRD0, DMA_PRD1, DMA_XFER } dma_state_e;
    dma_state_e  dma_state;
    logic [31:0] prd_base;     // PRD entry: physical base of the target buffer
    logic [6:0]  dma_beat;     // dword beat 0..127 within the 512-byte sector
    // byte offset into disk[] for the current dword = LBA*512 + beat*4
    wire  [15:0] dma_doff = {dma_lba[6:0], 9'd0} + {7'd0, dma_beat, 2'b00};
    // launching THIS clock: a START 0->1 EDGE write to BMIC with a DMA armed while
    // idle (the !r_bmic[0] term makes it a true 0->1 edge, matching qemu's
    // keep-old-value-on-no-change; dma_state==IDLE already prevents re-launch).
    wire         dma_launch = HAS_DMA && cs_bm && we && (addr[3:0] == 4'd0) &&
                              bm_wdata[0] && !r_bmic[0] && dma_pending &&
                              (dma_state == DMA_IDLE);
    // busy = the OUT must be held / the DMA owns the mem bus (launch clock + run).
    assign       dma_busy = HAS_DMA && ((dma_state != DMA_IDLE) || dma_launch);

    // ---- backing stores --------------------------------------------------
    logic [7:0]  disk [0:DISK_SECTORS*512-1];   // raw image, $readmemh
    logic [15:0] identify_words [0:255];        // built at time 0 (constants)
`ifdef VEN_IDE_DISK_HEX
    // HAS_DISK=0 (the empty ATAPI CD) -> no backing image to load.
    initial if (HAS_DISK) $readmemh(`VEN_IDE_DISK_HEX, disk);
`endif

    // ---- IDENTIFY DEVICE block (qemu 8.2.2 ide_identify, this -drive config) --
    // Geometry words are COMPUTED from the geometry parameters; the model/serial/
    // firmware strings and the feature/capability words are config-pinned
    // constants captured from qemu 8.2.2 (documented build-pinned data). All 256
    // are graded per-record against a freshly generated golden by the pide gate.
    integer ii;
    localparam int unsigned OLDSIZE = CYLS * HEADS * SECS;   // 2016 = 0x07E0
    initial begin
        for (ii = 0; ii < 256; ii = ii + 1) identify_words[ii] = 16'h0000;
        // -- geometry (computed) --
        identify_words[0]   = 16'h0040;               // general config (fixed HD)
        identify_words[1]   = CYLS[15:0];             // logical cylinders
        identify_words[3]   = HEADS[15:0];            // logical heads
        identify_words[4]   = (16'd512 * SECS[15:0]); // unformatted bytes/track
        identify_words[5]   = 16'd512;                // unformatted bytes/sector
        identify_words[6]   = SECS[15:0];             // sectors/track
        identify_words[54]  = CYLS[15:0];             // current cylinders
        identify_words[55]  = HEADS[15:0];            // current heads
        identify_words[56]  = SECS[15:0];             // current sectors/track
        identify_words[57]  = OLDSIZE[15:0];          // current capacity (lo)
        identify_words[58]  = OLDSIZE[31:16];         // current capacity (hi)
        identify_words[60]  = DISK_SECTORS[15:0];     // LBA28 total sectors (lo)
        identify_words[61]  = DISK_SECTORS[31:16];    // LBA28 total sectors (hi)
        identify_words[100] = DISK_SECTORS[15:0];     // LBA48 total sectors (lo)
        // -- serial "QM00001" (config-pinned, byte-swapped per ATA, space pad) --
        identify_words[10]  = 16'h514d; identify_words[11] = 16'h3030;
        identify_words[12]  = 16'h3030; identify_words[13] = 16'h3120;
        identify_words[14]  = 16'h2020; identify_words[15] = 16'h2020;
        identify_words[16]  = 16'h2020; identify_words[17] = 16'h2020;
        identify_words[18]  = 16'h2020; identify_words[19] = 16'h2020;
        // -- firmware "2.5+" --
        identify_words[23]  = 16'h322e; identify_words[24] = 16'h352b;
        identify_words[25]  = 16'h2020; identify_words[26] = 16'h2020;
        // -- model "QEMU HARDDISK" --
        identify_words[27]  = 16'h5145; identify_words[28] = 16'h4d55;
        identify_words[29]  = 16'h2048; identify_words[30] = 16'h4152;
        identify_words[31]  = 16'h4444; identify_words[32] = 16'h4953;
        identify_words[33]  = 16'h4b20; identify_words[34] = 16'h2020;
        identify_words[35]  = 16'h2020; identify_words[36] = 16'h2020;
        identify_words[37]  = 16'h2020; identify_words[38] = 16'h2020;
        identify_words[39]  = 16'h2020; identify_words[40] = 16'h2020;
        identify_words[41]  = 16'h2020; identify_words[42] = 16'h2020;
        identify_words[43]  = 16'h2020; identify_words[44] = 16'h2020;
        identify_words[45]  = 16'h2020; identify_words[46] = 16'h2020;
        // -- capability / feature words (config-pinned, qemu 8.2.2) --
        identify_words[20]  = 16'h0003; identify_words[21] = 16'h0200;
        identify_words[22]  = 16'h0004; identify_words[47] = 16'h8010;
        identify_words[48]  = 16'h0001; identify_words[49] = 16'h0b00;
        identify_words[51]  = 16'h0200; identify_words[52] = 16'h0200;
        identify_words[53]  = 16'h0007; identify_words[59] = 16'h0110;
        identify_words[62]  = 16'h0007; identify_words[63] = 16'h0007;
        identify_words[64]  = 16'h0003; identify_words[65] = 16'h0078;
        identify_words[66]  = 16'h0078; identify_words[67] = 16'h0078;
        identify_words[68]  = 16'h0078; identify_words[69] = 16'h4000;
        identify_words[80]  = 16'h00f0; identify_words[81] = 16'h0016;
        identify_words[82]  = 16'h4021; identify_words[83] = 16'h7400;
        identify_words[84]  = 16'h4000; identify_words[85] = 16'h4021;
        identify_words[86]  = 16'h3400; identify_words[87] = 16'h4000;
        identify_words[88]  = 16'h203f; identify_words[93] = 16'h6001;
        identify_words[106] = 16'h6000; identify_words[169] = 16'h0001;
    end

    // ---- disk byte address for the current PIO data word -----------------
    // byte_base = xfer_lba*512 + data_idx*2  (LBA in [0,DISK_SECTORS-1]).
    wire [15:0] disk_byte = {xfer_lba[6:0], 9'd0} + {6'd0, data_idx, 1'b0};

    // ---- combinational READ (same-cycle ack) -----------------------------
    logic [15:0] data_word;
    always_comb begin
        if (in_identify) begin
            // M8.4d: the SET MULTIPLE / SET FEATURES-mutable words come from
            // registers; all other IDENTIFY words are the build-pinned constants.
            // NOTE: SET MULTIPLE (0xC6) does NOT patch the cached IDENTIFY in qemu
            // (cmd_set_multiple_mode updates only s->mult_sectors; ide_identify is
            // cached after the first call), so w59 stays the constant 0x0110 here.
            // SET FEATURES (0xEF) DOES patch the cached words 62/63/85/88
            // (put_le16 into s->identify_data), so those are register-backed.
            unique case (data_idx[7:0])
                8'd62:   data_word = r_w62;            // single-word DMA (SET FEATURES)
                8'd63:   data_word = r_w63;            // multiword DMA
                8'd85:   data_word = r_w85;            // enabled features (write cache)
                8'd88:   data_word = r_w88;            // ultra DMA
                default: data_word = identify_words[data_idx[7:0]];
            endcase
        end else data_word = {disk[disk_byte + 16'd1], disk[disk_byte]};
    end

    always_comb begin
        rdata = 16'h0000;
        if (cs_ctl && !we) begin
            // alt-status read (no IRQ side effect); absent slave masks to 0.
            rdata = unit1_sel ? 16'h0000 : {8'h00, r_status};
        end else if (cs && !we) begin
            unique case (addr[2:0])
                // 0x1F0 data port: qemu ide_data_readw returns 0 UNLESS DRQ is set
                // AND the transfer is PIO-OUT (device->host READ). So a read returns
                // the buffer word ONLY inside a read-DRQ window; an idle read or a
                // read in a WRITE-DRQ window returns 0 (this also avoids leaking the
                // never-loaded disk[] X on the HAS_DISK=0 empty CD).
                3'd0: rdata = (r_status[3] && !in_write) ? data_word : 16'h0000;
                3'd1: rdata = unit1_sel ? 16'h0000 : {8'h00, r_error};    // 0x1F1
                3'd2: rdata = unit1_sel ? {8'h00, r_slv_nsector}          // 0x1F2
                                        : {8'h00, r_nsector};
                3'd3: rdata = unit1_sel ? {8'h00, r_slv_sector}           // 0x1F3
                                        : {8'h00, r_sector};
                3'd4: rdata = unit1_sel ? {8'h00, r_slv_lcyl}             // 0x1F4
                                        : {8'h00, r_lcyl};
                3'd5: rdata = unit1_sel ? {8'h00, r_slv_hcyl}             // 0x1F5
                                        : {8'h00, r_hcyl};
                3'd6: rdata = {8'h00, r_select};                          // 0x1F6
                default: rdata = unit1_sel ? 16'h0000 : {8'h00, r_status};// 0x1F7
            endcase
        end
    end

    // ---- M8.4f BMIDE register reads + the DMA engine's memory-master port ----
    always_comb begin
        // BMIDE register read (addr[3:0] selects; the SoC masks to io_size).
        unique case (addr[3:0])
            4'd0:                   bm_rdata = {24'd0, r_bmic};   // BMIC
            4'd2:                   bm_rdata = {24'd0, r_bmis};   // BMIS
            4'd4, 4'd5, 4'd6, 4'd7: bm_rdata = r_bmidtp;          // BMIDTP (dword)
            default:                bm_rdata = 32'd0;             // 1/3 reserved
        endcase
        // single-beat memory-master port: driven ONLY while the FSM is active.
        dma_mem_req   = 1'b0;
        dma_mem_we    = 1'b0;
        dma_mem_addr  = 32'd0;
        dma_mem_wdata = 32'd0;
        dma_mem_wstrb = 4'd0;
        unique case (dma_state)
            DMA_PRD0: begin dma_mem_req = 1'b1; dma_mem_addr = r_bmidtp;          end
            DMA_PRD1: begin dma_mem_req = 1'b1; dma_mem_addr = r_bmidtp + 32'd4;  end
            DMA_XFER: begin
                dma_mem_req   = 1'b1;
                dma_mem_we    = 1'b1;
                dma_mem_wstrb = 4'hF;
                dma_mem_addr  = prd_base + {23'd0, dma_beat, 2'b00};   // base + beat*4
                // little-endian dword from disk[] (byte-identical to a PIO READ)
                dma_mem_wdata = {disk[dma_doff + 16'd3], disk[dma_doff + 16'd2],
                                 disk[dma_doff + 16'd1], disk[dma_doff]};
            end
            default: ;  // DMA_IDLE: bus idle
        endcase
    end

    // ---- LBA / CHS addressing from the task file (M8.4c) ------------------
    // LBA mode (devhead bit6=1): {head[3:0], hcyl, lcyl, sector} = LBA28.
    // CHS mode (devhead bit6=0): qemu ide_get_sector (core.c:631) translates
    //   lba = ((cyl)*HEADS + head)*SECS + (sector - 1)   [sector is 1-based].
    wire [27:0] lba28   = {r_select[3:0], r_hcyl, r_lcyl, r_sector};
    wire [27:0] chs_cyl = {12'd0, r_hcyl, r_lcyl};
    wire [27:0] chs_lba = (chs_cyl * 28'(HEADS) + {24'd0, r_select[3:0]}) * 28'(SECS)
                          + {20'd0, r_sector} - 28'd1;
    wire [27:0] issue_lba = r_select[6] ? lba28 : chs_lba;
    // OOR: a transfer whose (start) LBA is past the last sector. DISK_SECTORS
    // (=128) is the sector count; valid LBAs are 0..DISK_SECTORS-1.
    localparam logic [27:0] NSECT28 = 28'(DISK_SECTORS);
    wire oor_read = (issue_lba >= NSECT28);

    // ---- task-file LBA-register advance (qemu ide_set_sector, LBA28) -------
    // After a completed sector transfer qemu rewrites the task file to the NEXT
    // LBA (start+count) with nsector=0; mirrored here. nl = the next LBA.
    task automatic advance_lba_regs(input logic [27:0] nl);
        r_sector  <= nl[7:0];
        r_lcyl    <= nl[15:8];
        r_hcyl    <= nl[23:16];
        r_select  <= (r_select & 8'hF0) | {4'd0, nl[27:24]};  // keep ALWAYS_ON/LBA/unit
        r_nsector <= 8'h00;
    endtask

    // ---- clocked state: register writes, command dispatch, PIO advance ----
    always_ff @(posedge clk) begin
        if (rst) begin
            // ide_reset signature: nsector=1, sector=1, lcyl=0, hcyl=0, err=0.
            r_error   <= 8'h00;
            r_feature <= 8'h00;
            r_nsector <= 8'h01;
            r_sector  <= 8'h01;
            r_lcyl    <= SIG_LCYL;       // 0x00 (ATA) / 0x14 (ATAPI signature)
            r_hcyl    <= SIG_HCYL;       // 0x00 (ATA) / 0xEB (ATAPI signature)
            r_slv_lcyl <= 8'hFF;         // absent slave's independent signature
            r_slv_hcyl <= 8'hFF;
            r_slv_nsector <= 8'h01;      // ide_set_signature: nsector/sector = 1
            r_slv_sector  <= 8'h01;
            r_select  <= 8'hA0;          // ATA_DEV_ALWAYS_ON, master
            r_status  <= STAT_IDLE;      // 0x50
            r_ctrl    <= 8'h00;
            data_idx  <= 9'd0;
            in_identify <= 1'b0;
            in_write  <= 1'b0;
            xfer_lba  <= 28'd0;
            nsec_left <= 9'd0;
            irq14     <= 1'b0;
            r_w62     <= 16'h0007;
            r_w63     <= 16'h0007;
            r_w85     <= 16'h4021;
            r_w88     <= 16'h203F;
            r_bmic      <= 8'h00;        // M8.4f BMIDE + DMA engine
            r_bmis      <= 8'h00;
            r_bmidtp    <= 32'h0000_0000;
            dma_pending <= 1'b0;
            dma_lba     <= 28'd0;
            dma_state   <= DMA_IDLE;
            prd_base    <= 32'd0;
            dma_beat    <= 7'd0;
        end else begin
            if (cs && we) begin
                // ----- command-block register writes / command dispatch -----
                unique case (addr[2:0])
                    // ---- data port write (0x1F0): WRITE SECTORS fill ---------
                    // Each outw stores one 16-bit word into disk[] at the SAME
                    // disk_byte the READ uses (little-endian: low byte first),
                    // then advances/commits exactly like the READ drain. Honored
                    // ONLY while a write DRQ is active (r_status[3] && in_write),
                    // mirroring qemu's ide_data_writew guard (DRQ set + PIO-out).
                    3'd0: begin
                        if (r_status[3] && in_write) begin
                            // COMMIT the word ONLY for an in-range sector; an OOR
                            // sector's words are DROPPED (disk[] never mutated) —
                            // qemu fills the buffer then aborts without writing.
                            if (xfer_lba < NSECT28) begin
                                disk[disk_byte]         <= wdata[7:0];
                                disk[disk_byte + 16'd1] <= wdata[15:8];
                            end
                            // advance/commit logic OUTSIDE the in-range gate (the
                            // host always fills all 256 words, even for an OOR
                            // sector, before the abort on its last word).
                            if (data_idx == 9'd255) begin
                                if (xfer_lba >= NSECT28) begin      // OOR sector:
                                    data_idx <= 9'd0; in_write <= 1'b0;
                                    r_status <= STAT_ABORT;         // 0x41 / 0x04
                                    r_error  <= ERR_ABRT;           // (regs NOT
                                    irq14    <= ~nien;              //  advanced)
                                end else if (nsec_left > 9'd1) begin // in-range,more
                                    xfer_lba  <= xfer_lba + 28'd1;  // next sector
                                    nsec_left <= nsec_left - 9'd1;
                                    data_idx  <= 9'd0;              // re-arm DRQ
                                    irq14     <= ~nien;             // (nIEN: 0)
                                    advance_lba_regs(xfer_lba + 28'd1);
                                end else begin                       // in-range,last
                                    data_idx <= 9'd0;
                                    in_write <= 1'b0;
                                    r_status <= STAT_IDLE;          // DRQ cleared
                                    irq14    <= ~nien;
                                    advance_lba_regs(xfer_lba + 28'd1);
                                end
                            end else begin
                                data_idx <= data_idx + 9'd1;
                            end
                        end
                    end
                    // Task-file register writes (0x1F1-0x1F6) are DROPPED while a
                    // transfer is active (DRQ set) — qemu ide_ioport_write
                    // (core.c:1287) ignores them when status&(BUSY|DRQ); BSY is
                    // never set here so the live bit is DRQ (r_status[3]). The
                    // data port (0x1F0) is NOT gated (it IS the active transfer).
                    3'd1: if (!r_status[3]) r_feature <= wdata[7:0];       // 0x1F1
                    // qemu broadcasts task-file writes to BOTH drives, so each slave
                    // shadow tracks the master write (same DRQ gate); a *command*
                    // later advances only the master (advance_lba_regs), leaving the
                    // shadows at their last-broadcast value.
                    3'd2: if (!r_status[3]) begin r_nsector <= wdata[7:0]; r_slv_nsector <= wdata[7:0]; end // 0x1F2
                    3'd3: if (!r_status[3]) begin r_sector  <= wdata[7:0]; r_slv_sector  <= wdata[7:0]; end // 0x1F3
                    3'd4: if (!r_status[3]) begin r_lcyl <= wdata[7:0]; r_slv_lcyl <= wdata[7:0]; end // 0x1F4
                    3'd5: if (!r_status[3]) begin r_hcyl <= wdata[7:0]; r_slv_hcyl <= wdata[7:0]; end // 0x1F5
                    3'd6: if (!r_status[3]) r_select  <= wdata[7:0] | 8'hA0;// 0x1F6
                    default: begin                       // 0x1F7 command
                      // COMMAND-WHILE-DRQ: qemu ignores a non-RESET command while
                      // a transfer is active (ide_bus_exec_cmd core.c:2155); drop
                      // it (no state change). BSY is never set in this PIO model.
                      if (!r_status[3]) begin
                        if (!unit1_sel) begin            // commands to absent
                                                         // slave are dropped
                            // qemu clears the error register on EVERY accepted
                            // command (core.c:2168, "needed by Windows"), so a
                            // prior abort's 0x04 does not linger; the DIAGNOSTIC
                            // (0x01) and abort (0x04) arms override this below.
                            r_error <= 8'h00;
                            if (IS_ATAPI) begin
                              // Empty ATAPI CD-ROM command surface. qemu does NOT
                              // blanket-abort: several CD_OK/ALL_OK commands complete
                              // (the cmd table flags them permitted for IDE_CD). The
                              // genuinely-DEFERRED full-PACKET surface is 0xA0 PACKET /
                              // 0xA1 IDENTIFY-PACKET — qemu opens a DRQ packet phase
                              // for those (cmd_packet core.c:1779 / cmd_identify_packet
                              // core.c:1743); this RTL aborts them instead, a KNOWN,
                              // documented divergence the directed test issues NEITHER
                              // of (so the per-record EQUIVALENT is honest).
                              unique case (wdata[7:0])
                                8'h90: begin             // EXECUTE DEVICE DIAGNOSTIC
                                    // cmd_exec_dev_diagnostic: signature + status 0x00
                                    // (clears READY_STAT), error 0x01, NO IRQ.
                                    r_error   <= 8'h01;
                                    r_nsector <= 8'h01; r_sector <= 8'h01;
                                    r_lcyl    <= SIG_LCYL; r_hcyl <= SIG_HCYL;
                                    r_select  <= r_select & 8'hF0;   // ide_set_signature
                                    r_status  <= 8'h00;
                                end
                                8'h08: begin             // DEVICE RESET (CD_OK)
                                    // cmd_device_reset: ide_reset + signature, error 0,
                                    // status 0x00, returns false -> NO IRQ.
                                    r_error   <= 8'h00;
                                    r_nsector <= 8'h01; r_sector <= 8'h01;
                                    r_lcyl    <= SIG_LCYL; r_hcyl <= SIG_HCYL;
                                    r_select  <= r_select & 8'hF0;
                                    r_status  <= 8'h00;
                                end
                                // FLUSH CACHE (0xE7) is permission-ALL_OK but ABORTS
                                // at RUNTIME on the empty CD: blk_aio_flush hits a
                                // no-medium error -> ide_flush_cb -> ide_handle_rw_
                                // error sets status 0x41 / error 0x04 (OBSERVED in the
                                // golden, NOT the 0x50 completion a populated drive
                                // gives). It falls through to the bare-abort default.
                                8'hEF: begin             // SET FEATURES (ALL_OK)
                                    // cmd_set_features completes on the CD (the empty
                                    // tray still has a BlockBackend); the patched
                                    // identify words are unobservable (0xEC aborts).
                                    r_status <= STAT_IDLE; irq14 <= ~nien;
                                end
                                8'hEC, 8'h20, 8'h21: begin
                                    // cmd_identify / cmd_read_pio for IDE_CD call
                                    // ide_set_signature THEN ide_abort_command: full
                                    // signature (nsector/sector=1, lcyl/hcyl=0xEB14,
                                    // head cleared) + status 0x41 / error 0x04 + IRQ.
                                    r_nsector <= 8'h01; r_sector <= 8'h01;
                                    r_lcyl    <= SIG_LCYL; r_hcyl <= SIG_HCYL;
                                    r_select  <= r_select & 8'hF0;
                                    r_status  <= STAT_ABORT; r_error <= ERR_ABRT;
                                    irq14     <= ~nien;
                                end
                                default: begin
                                    // not-permitted opcodes (e.g. 0xB0 SMART) AND the
                                    // deferred 0xA0/0xA1: a BARE ide_abort_command —
                                    // status 0x41 / error 0x04 + IRQ, task-file regs
                                    // LEFT UNTOUCHED (no ide_set_signature).
                                    r_status <= STAT_ABORT; r_error <= ERR_ABRT;
                                    irq14    <= ~nien;
                                end
                              endcase
                            end else begin
                            unique case (wdata[7:0])
                                8'hEC: begin             // IDENTIFY DEVICE
                                    in_identify <= 1'b1;
                                    in_write    <= 1'b0;
                                    data_idx    <= 9'd0;
                                    r_status    <= STAT_DRQ;
                                    irq14       <= ~nien;
                                end
                                8'h20, 8'h21: begin       // READ SECTOR(S)
                                    if (oor_read) begin   // OOR: upfront abort, no
                                        r_status <= STAT_ABORT;  // DRQ ever set,
                                        r_error  <= ERR_ABRT;    // regs UNCHANGED
                                        irq14    <= ~nien;
                                    end else begin
                                        xfer_lba    <= issue_lba;  // LBA or CHS
                                        nsec_left   <= (r_nsector == 8'd0)
                                                       ? 9'd256 : {1'b0, r_nsector};
                                        in_identify <= 1'b0;
                                        in_write    <= 1'b0;
                                        data_idx    <= 9'd0;
                                        r_status    <= STAT_DRQ;
                                        irq14       <= ~nien;
                                    end
                                end
                                8'h30, 8'h31: begin       // WRITE SECTOR(S)
                                    // no upfront range check (qemu cmd_write_pio
                                    // defers it); the abort is in the data arm.
                                    xfer_lba    <= issue_lba;
                                    nsec_left   <= (r_nsector == 8'd0)
                                                   ? 9'd256 : {1'b0, r_nsector};
                                    in_identify <= 1'b0;
                                    in_write    <= 1'b1;  // host->device DRQ
                                    data_idx    <= 9'd0;
                                    r_status    <= STAT_DRQ;  // 0x58 immediately
                                    irq14       <= ~nien;
                                end
                                8'hC8: begin              // READ DMA (M8.4f)
                                    // ARM only (NO PIO data-port phase); the engine
                                    // runs on the BMIC START write. qemu's cmd_read_dma
                                    // -> ide_sector_start_dma sets status READY|SEEK|DRQ
                                    // = 0x58 here (returns false, so it persists until
                                    // the DMA completes -> 0x50). Single-sector, in-range
                                    // (the directed scope). Without HAS_DMA this is an
                                    // unsupported opcode -> the default abort below.
                                    if (HAS_DMA) begin
                                        dma_pending <= 1'b1;
                                        dma_lba     <= issue_lba;
                                        r_status    <= STAT_DRQ;   // 0x58 (DRQ, no BSY)
                                    end else begin
                                        r_status <= STAT_ABORT; r_error <= ERR_ABRT;
                                        irq14    <= ~nien;
                                    end
                                end
                                8'h90: begin              // EXECUTE DIAGNOSTIC
                                    r_error   <= 8'h01;   // device 0 passed
                                    r_nsector <= 8'h01;
                                    r_sector  <= 8'h01;
                                    r_lcyl    <= 8'h00;
                                    r_hcyl    <= 8'h00;
                                    r_select  <= 8'hA0;   // ATA_DEV_ALWAYS_ON
                                    r_status  <= STAT_IDLE;
                                    irq14     <= ~nien;
                                end
                                8'hC6: begin              // SET MULTIPLE MODE
                                    // 0 (disable) or a power-of-two <= 16 accepts
                                    // (mult <- nsector); else abort (qemu
                                    // cmd_set_multiple_mode).
                                    if ((r_nsector != 8'd0) &&
                                        ((r_nsector > 8'd16) ||
                                         ((r_nsector & (r_nsector - 8'd1)) != 8'd0)))
                                    begin
                                        r_status <= STAT_ABORT;
                                        r_error  <= ERR_ABRT;
                                        irq14    <= ~nien;
                                    end else begin
                                        // accept (runtime mult_sectors updates,
                                        // but the cached IDENTIFY w59 is NOT
                                        // patched by qemu -- status-only here).
                                        r_status <= STAT_IDLE;
                                        irq14    <= ~nien;
                                    end
                                end
                                8'hEF: begin              // SET FEATURES (sub=r_feature)
                                    unique case (r_feature)
                                        8'h03: begin       // SET TRANSFER MODE
                                            // r_nsector[7:3] = mode group, [2:0] = mode#
                                            unique case (r_nsector[7:3])
                                              5'h00, 5'h01: begin  // PIO
                                                  r_w62 <= 16'h0007; r_w63 <= 16'h0007;
                                                  r_w88 <= 16'h003F; r_status <= STAT_IDLE;
                                              end
                                              5'h02: begin         // single-word DMA
                                                  r_w62 <= 16'h0007 | (16'h0001 << (r_nsector[2:0] + 4'd8));
                                                  r_w63 <= 16'h0007; r_w88 <= 16'h003F;
                                                  r_status <= STAT_IDLE;
                                              end
                                              5'h04: begin         // multiword DMA
                                                  r_w62 <= 16'h0007;
                                                  r_w63 <= 16'h0007 | (16'h0001 << (r_nsector[2:0] + 4'd8));
                                                  r_w88 <= 16'h003F; r_status <= STAT_IDLE;
                                              end
                                              5'h08: begin         // ultra DMA
                                                  r_w62 <= 16'h0007; r_w63 <= 16'h0007;
                                                  r_w88 <= 16'h003F | (16'h0001 << (r_nsector[2:0] + 4'd8));
                                                  r_status <= STAT_IDLE;
                                              end
                                              default: begin
                                                  r_status <= STAT_ABORT; r_error <= ERR_ABRT;
                                              end
                                            endcase
                                            irq14 <= ~nien;
                                        end
                                        8'h02: begin       // enable write cache -> w85
                                            r_w85    <= 16'h4021;  // (1<<14)|(1<<5)|1
                                            r_status <= STAT_IDLE; irq14 <= ~nien;
                                        end
                                        8'h82: begin       // disable write cache -> w85
                                            // qemu completes 0x82 (NOT an abort):
                                            // w85 = (1<<14)|1 = 0x4001 + an async
                                            // flush (off-surface, settles before the
                                            // next single-step).
                                            r_w85    <= 16'h4001;
                                            r_status <= STAT_IDLE; irq14 <= ~nien;
                                        end
                                        // no-op completions. NOTE: 0xCC/0x66 also
                                        // set/clear qemu's reset_reverts flag (a
                                        // SRST-revert side-effect) which this RTL
                                        // does not model; only 0x91 geometry would
                                        // make it observable (deferred to M8.4d2).
                                        8'hAA, 8'h55, 8'h05, 8'h85, 8'h69, 8'h67,
                                        8'h96, 8'h9A, 8'h42, 8'hC2, 8'hCC, 8'h66: begin
                                            r_status <= STAT_IDLE; irq14 <= ~nien;
                                        end
                                        default: begin     // genuinely unsupported subcmd
                                            r_status <= STAT_ABORT; r_error <= ERR_ABRT;
                                            irq14    <= ~nien;
                                        end
                                    endcase
                                end
                                // ---- non-data commands qemu completes 0x50/0x00 -
                                // SEEK (cmd_seek), RECALIBRATE + INIT DEVICE PARAMS
                                // (cmd_nop/cmd_specify) — all return true with no
                                // PIO phase. (M8.4d Tier 1: 0x91's geometry side
                                // effect is added in Tier 2; here it just completes.)
                                8'h70,                    // SEEK
                                8'h10,                    // RECALIBRATE
                                8'h91: begin              // INIT DEVICE PARAMS
                                    r_status <= STAT_IDLE;
                                    r_error  <= 8'h00;
                                    irq14    <= ~nien;
                                end
                                default: begin            // unsupported -> abort
                                    r_status <= STAT_ABORT;
                                    r_error  <= ERR_ABRT;
                                    irq14    <= ~nien;
                                end
                            endcase
                            end   // else (!IS_ATAPI)
                        end
                      end
                    end
                endcase
            end else if (cs_ctl && we) begin
                // SRST (bit2) assert edge -> synchronous signature restore (reuses
                // the DIAGNOSTIC result: error 0x01, signature, status 0x50). qemu
                // does this in an async soft-reset BH that sets a transient BUSY,
                // but the BH settles before the next single-step (collapsed, like
                // the READ/WRITE async-BH boundary), so a synchronous restore is
                // per-record EQUIVALENT and NEVER raises BSY here.
                if (!r_ctrl[2] && wdata[2]) begin
                    r_error   <= 8'h01;
                    r_nsector <= 8'h01;
                    r_sector  <= 8'h01;
                    r_lcyl    <= SIG_LCYL;   // 0x00 (ATA) / 0x14 (ATAPI signature)
                    r_hcyl    <= SIG_HCYL;   // 0x00 (ATA) / 0xEB (ATAPI signature)
                    r_select  <= 8'hA0;
                    // ATAPI post-reset status is 0x00 (the CD clears READY_STAT, like
                    // DIAGNOSTIC); an ATA HD restores 0x50.
                    r_status  <= IS_ATAPI ? 8'h00 : STAT_IDLE;
                    // the soft reset also re-runs ide_set_signature on the absent
                    // slave (ifs[1]) -> its independent shadow returns to 0xFF / 1.
                    r_slv_lcyl    <= 8'hFF; r_slv_hcyl   <= 8'hFF;
                    r_slv_nsector <= 8'h01; r_slv_sector <= 8'h01;
                end
                r_ctrl <= wdata[7:0];                     // device control (nIEN, SRST)
            end else if (cs && !we && addr[2:0] == 3'd0 && r_status[3] && !in_write) begin
                // ----- data-port READ drain (the !in_write guard drops a read in
                //       a WRITE-DRQ window so it consumes no slot) --------------
                if (data_idx == 9'd255) begin
                    if (!in_identify && nsec_left > 9'd1) begin
                        if ((xfer_lba + 28'd1) >= NSECT28) begin // next sector OOR:
                            data_idx <= 9'd0;                    // abort AFTER this
                            r_status <= STAT_ABORT;              // in-range sector
                            r_error  <= ERR_ABRT;                // is delivered
                            irq14    <= ~nien;
                            advance_lba_regs(xfer_lba + 28'd1);  // regs -> OOR LBA
                        end else begin                           // in-range: re-arm
                            xfer_lba  <= xfer_lba + 28'd1;       // next sector
                            nsec_left <= nsec_left - 9'd1;
                            data_idx  <= 9'd0;                   // new DRQ buffer
                            irq14     <= ~nien;
                            advance_lba_regs(xfer_lba + 28'd1);
                        end
                    end else begin
                        data_idx    <= 9'd0;
                        in_identify <= 1'b0;
                        r_status    <= STAT_IDLE;         // DRQ cleared
                        // READ completion advances the LBA regs; IDENTIFY does not.
                        if (!in_identify) advance_lba_regs(xfer_lba + 28'd1);
                    end
                end else begin
                    data_idx <= data_idx + 9'd1;
                end
            end else if (cs && !we && addr[2:0] == 3'd7) begin
                irq14 <= 1'b0;                            // status read lowers IRQ
            end
            // (0x3F6 alt-status read does NOT lower IRQ)

            // ===== M8.4f bus-master DMA: BMIDE register writes + the engine =====
            // cs_bm is a DISTINCT decode (the PCI BAR4 window) from cs/cs_ctl, so
            // these never overlap the task-file I/O above. During the DMA burst the
            // core is parked in the held START-OUT (cs/cs_ctl = 0), so the FSM below
            // is the only writer of r_status / the task file in those clocks.
            if (HAS_DMA) begin
                if (cs_bm && we) begin
                    if (addr[3:0] == 4'd0) begin              // BMIC
                        r_bmic <= bm_wdata[7:0] & 8'h09;      // store cmd & 0x09
                        if (dma_launch) begin                 // START 0->1, DMA armed
                            dma_state <= DMA_PRD0;            // walk the PRD then copy
                            r_bmis[0] <= 1'b1;                // DMAING
                            dma_beat  <= 7'd0;
                        end
                    end else if (addr[3:0] == 4'd2) begin     // BMIS
                        r_bmis[6:5] <= bm_wdata[6:5];         // DMA-capable bits R/W
                        if (bm_wdata[1]) r_bmis[1] <= 1'b0;   // ERROR write-1-clear
                        if (bm_wdata[2]) r_bmis[2] <= 1'b0;   // INT   write-1-clear
                    end else if (addr[3] || addr[2]) begin    // BMIDTP (off 4-7)
                        r_bmidtp <= bm_wdata & ~32'h0000_0003; // dword-aligned
                    end
                end
                // the PRD-walk + single-sector copy FSM (single-beat mem-master).
                unique case (dma_state)
                    DMA_PRD0: if (dma_mem_ack) begin          // dword0 = PRD base
                        prd_base  <= dma_mem_rdata;
                        dma_state <= DMA_PRD1;
                    end
                    DMA_PRD1: if (dma_mem_ack) begin          // dword1 = count|EOT
                        dma_state <= DMA_XFER;                // (count=512 in scope)
                        dma_beat  <= 7'd0;
                    end
                    DMA_XFER: if (dma_mem_ack) begin          // copy 128 dwords
                        if (dma_beat == 7'd127) begin         // last dword -> done
                            dma_state   <= DMA_IDLE;
                            r_bmis[0]   <= 1'b0;              // DMAING clear
                            r_status    <= STAT_IDLE;        // 0x50 (DMA complete)
                            dma_pending <= 1'b0;
                            advance_lba_regs(dma_lba + 28'd1); // LBA advance (qemu)
                            // BMIS-INT (bit2) stays 0: under nIEN ide_bus_set_irq is
                            // gated, so the DMA-completion IRQ is never delivered.
                        end else begin
                            dma_beat <= dma_beat + 7'd1;
                        end
                    end
                    default: ;  // DMA_IDLE
                endcase
            end
        end
    end

    // No unused outputs to sink (irq14 -> PIC IR14, rdata -> SoC read mux).
    // r_feature is a write-only shadow in M8.4a (SET FEATURES deferred).
    // HAS_DISK is referenced only inside `ifdef VEN_IDE_DISK_HEX (the $readmemh
    // guard); sink it so a standalone lint without that define stays UNUSEDPARAM-clean.
    logic _unused;
    assign _unused = &{1'b0, addr[15:3], r_ctrl[7:3], r_ctrl[0], HAS_DISK};

endmodule
