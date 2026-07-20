// ps_shim.cpp — glue between the real MiSTer HPS software (x86.cpp/ide.cpp) and
// the verilated ao486 SoC. Implements the FPGA-access primitives the MiSTer code
// bottoms out on (SPI/mgmt + shmem), file I/O over stdio, and no-op stubs for the
// CD-ROM / VHD / CHD / minimig / shared-folder branches not on the raw-image path.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

#include "Vsystem.h"
#include "spi.h"
#include "fpga_io.h"
#include "shmem.h"
#include "user_io.h"
#include "file_io.h"
#include "hardware.h"
#include "cfg.h"
#include "ide.h"          // drive_t (for parse_vhd_config geometry)
#include "support/vhd/vhdcfg.h"
#include "support/chd/mister_chd.h"

// --- provided by sim_main.cpp ---
extern Vsystem  *top;
extern uint64_t *ddr;          // 256MB host DDR backing store
extern void      ps_clock_tick();   // advance the verilated RTL one clock

// ===========================================================================
// shmem: the HPS view of FPGA DDR -> our ddr[] array (offset = addr-SHMEM_ADDR)
// ===========================================================================
void *shmem_map(uint32_t address, uint32_t size)  { (void)size; return (uint8_t*)ddr + (address - SHMEM_ADDR); }
int   shmem_unmap(void *map, uint32_t size)        { (void)map; (void)size; return 1; }
int   shmem_put(uint32_t a, uint32_t s, void *buf) { memcpy((uint8_t*)ddr + (a - SHMEM_ADDR), buf, s); return 1; }
int   shmem_get(uint32_t a, uint32_t s, void *buf) { memcpy(buf, (uint8_t*)ddr + (a - SHMEM_ADDR), s); return 1; }

// ===========================================================================
// mgmt-bus driver: replays the UIO_DMA SPI protocol onto top->mgmt_*.
// Registers (low nibble != 0xF) auto-increment per word; the data buffer
// (low nibble == 0xF) keeps a fixed address (FPGA's internal counter advances).
// ===========================================================================
static int      txn_dir = 0;   // 0=write, 1=read
static int      txn_pos = 0;   // 0=expect cmd, 1=expect addr, 2=expect addr-hi/data
static uint32_t txn_addr = 0;

// constructed by sim_main from the raw request outputs (set each poll)
extern "C" uint16_t ps_sd_req();

static inline void addr_step() { if ((txn_addr & 0xF) != 0xF) txn_addr++; }   // regs increment, buffer fixed

// ide.v advances its internal buffer index (mgmt_cnt) on the FALLING edge of
// mgmt_write/mgmt_read (see rtl/soc/ide.v: `if((old_wr & ~mgmt_write)|...) mgmt_cnt++`).
// So each mgmt access must be clocked with the strobe HIGH and then again with it LOW,
// or ide.v never sees the deassertion and mgmt_cnt stays 0 -> every buffer word lands
// at index 0 (IDENTIFY / disk sectors come back all-but-first-word zero). Clock both.
static uint16_t mgmt_wr(uint16_t d) {
    top->mgmt_address = txn_addr & 0xFFFF; top->mgmt_writedata = d; top->mgmt_write = 1;
    ps_clock_tick();
    top->mgmt_write = 0;
    ps_clock_tick();
    addr_step(); return 0;
}
static uint16_t mgmt_rd() {
    // The register reads (mgmt_address 0..5) are one registered stage: valid after one
    // posedge. The BUFFER read (mgmt_address low-nibble 0xF) comes from the io_buf dpram,
    // whose q_a is itself registered, so mgmt_readdata reflects it one cycle later. Give
    // the buffer path that extra settle tick, or disk WRITES read the buffer off-by-one
    // and corrupt the image (the read path is unaffected — the CPU reads the buffer over
    // its own io port, not over mgmt).
    int is_buf = ((txn_addr & 0xF) == 0xF);
    top->mgmt_address = txn_addr & 0xFFFF; top->mgmt_read = 1;
    ps_clock_tick();
    if (is_buf) ps_clock_tick();
    uint16_t d = top->mgmt_readdata; top->mgmt_read = 0;
    ps_clock_tick();
    addr_step(); return d;
}

void EnableIO()  { txn_pos = 0; }
void DisableIO() { top->mgmt_write = 0; top->mgmt_read = 0; }

uint8_t spi_b(uint8_t parm) {
    if (txn_pos == 0) { txn_dir = (parm == UIO_DMA_READ) ? 1 : 0; txn_pos = 1; }
    return 0;
}
uint16_t spi_w(uint16_t word) {
    if (txn_pos == 0) {                        // ide_check(): UIO_DMA_SDIO status query
        // Advance the FPGA clock on every status query. The real ide_check() issues a
        // real SPI transaction that clocks the bus, so the FPGA keeps running while the
        // HPS polls. ide.cpp's multi-sector read/write loops busy-wait on this
        // (`while(!ide_req) ide_req = ide_check()...`) for the core to raise the
        // next-sector request; without a tick here the core is frozen and it spins
        // forever (single-sector transfers break out before that loop, so they worked).
        if (word == UIO_DMA_SDIO) { txn_pos = 9; ps_clock_tick(); return ps_sd_req(); }
        txn_dir = (word == UIO_DMA_READ) ? 1 : 0; txn_pos = 1; return 0;
    }
    if (txn_pos == 9) return 0;                // SDIO second read
    if (txn_pos < 2) txn_pos = 2;
    return txn_dir ? mgmt_rd() : mgmt_wr(word);
}
void     spi32_b(uint32_t parm) { if (txn_pos == 1) { txn_addr = parm; txn_pos = 2; } }
uint32_t spi32_w(uint32_t parm) {
    if (txn_pos == 1) { txn_addr = parm; txn_pos = 2; return 0; }
    return txn_dir ? mgmt_rd() : mgmt_wr((uint16_t)parm);
}
uint16_t fpga_spi_fast(uint16_t word) {
    if (txn_pos == 0) { txn_dir = (word == UIO_DMA_READ) ? 1 : 0; txn_pos = 1; return 0; }
    if (txn_pos == 1) { txn_addr = word; txn_pos = 2; return 0; }           // addr low 16
    if (txn_pos == 2) { txn_addr |= (uint32_t)word << 16; txn_pos = 3; return 0; } // addr high 16
    return txn_dir ? mgmt_rd() : mgmt_wr(word);
}
void fpga_spi_fast_block_write(const uint16_t *buf, uint32_t length)  { while (length--) mgmt_wr(*buf++); }
void fpga_spi_fast_block_read(uint16_t *buf, uint32_t length)         { while (length--) *buf++ = mgmt_rd(); }
void fpga_spi_fast_block_write_8(const uint8_t *buf, uint32_t length) { while (length--) mgmt_wr(*buf++); }
void fpga_spi_fast_block_read_8(uint8_t *buf, uint32_t length)        { while (length--) *buf++ = (uint8_t)mgmt_rd(); }
void fpga_spi_fast_block_write_be(const uint16_t *buf, uint32_t length){ while (length--) { uint16_t w=*buf++; mgmt_wr((w>>8)|(w<<8)); } }
void fpga_spi_fast_block_read_be(uint16_t *buf, uint32_t length)      { while (length--) { uint16_t w=mgmt_rd(); *buf++=(w>>8)|(w<<8); } }

// ===========================================================================
// file I/O over stdio
// ===========================================================================
fileTYPE::fileTYPE()  { filp=0; mode=0; type=0; zip=0; size=0; offset=0; path[0]=0; name[0]=0; }
fileTYPE::~fileTYPE() { if (filp) fclose(filp); }
int fileTYPE::opened() { return filp != 0; }

const char *getFullPath(const char *name) { return name; }   // images passed as direct paths

int FileOpenEx(fileTYPE *f, const char *name, int mode, char mute, int use_zip) {
    (void)mute; (void)use_zip;
    const char *m = (mode & O_RDWR) ? "r+b" : "rb";
    f->filp = fopen(name, m);
    if (!f->filp) { if (!mute) fprintf(stderr, "FileOpenEx: cannot open %s\n", name); f->size = 0; return 0; }
    f->mode = mode;
    struct stat st; if (!fstat(fileno(f->filp), &st)) f->size = st.st_size;
    snprintf(f->path, sizeof(f->path), "%s", name);
    // name is the short basename on real MiSTer (path is the full path). ide.cpp
    // builds the ATA IDENTIFY model string from f->name; passing the full path here
    // put "../tmp/..." (leading "..") into the model number the BIOS formats.
    const char *bn = strrchr(name, '/'); bn = bn ? bn + 1 : name;
    snprintf(f->name, sizeof(f->name), "%s", bn);
    f->offset = 0;
    return 1;
}
int FileOpen(fileTYPE *f, const char *name, char mute) { return FileOpenEx(f, name, O_RDONLY, mute, 1); }
void FileClose(fileTYPE *f) { if (f->filp) { fclose(f->filp); f->filp = 0; } }
int FileSeek(fileTYPE *f, __off64_t offset, int origin) { return f->filp ? (fseeko(f->filp, offset, origin) == 0) : 0; }
int FileSeekLBA(fileTYPE *f, uint32_t lba) { return f->filp ? (fseeko(f->filp, (off_t)lba * 512, SEEK_SET) == 0) : 0; }
int FileReadAdv(fileTYPE *f, void *buf, int length, int failres) { (void)failres; return f->filp ? (int)fread(buf, 1, length, f->filp) : 0; }
int FileReadSec(fileTYPE *f, void *buf) { return f->filp ? (fread(buf, 512, 1, f->filp) == 1) : 0; }
int FileWriteAdv(fileTYPE *f, void *buf, int length, int failres) { (void)failres; return f->filp ? (int)fwrite(buf, 1, length, f->filp) : 0; }
int FileWriteSec(fileTYPE *f, void *buf) { return f->filp ? (fwrite(buf, 512, 1, f->filp) == 1) : 0; }
int FileCanWrite(const char *name) { return access(name, W_OK) == 0; }
int FileSaveConfig(const char *name, void *buf, int size) { (void)name; (void)buf; (void)size; return 1; }
int FileLoadConfig(const char *name, void *buf, int size) { (void)name; (void)buf; (void)size; return 0; }

// ===========================================================================
// user_io / framework stubs (x86 core, no Amiga/PCXT/OSD)
// ===========================================================================
uint32_t user_io_status_get(const char *opt, int ex) { (void)ex; if(opt && opt[1]=='1' && opt[2]=='1') return 1; return 0; }  // [11] memcfg=1 -> 16MB
void     user_io_status_set(const char *opt, uint32_t value, int ex) { (void)opt; (void)value; (void)ex; }
char    *user_io_get_core_name(int orig) { (void)orig; static char s[] = "ao486"; return s; }
char    *user_io_get_core_path(const char *suffix) { (void)suffix; static char s[] = "."; return s; }
char     is_x86()     { return 1; }
char     is_pcxt()    { return 0; }
char     is_minimig() { return 0; }

// the BIOS ROM filenames x86_init loads via user_io_make_filepath(home, "bootN.rom")
char *user_io_make_filepath(const char *path, const char *filename) {
    (void)path; static char s[1024];
    snprintf(s, sizeof(s), "../3rd-party/ao486_MiSTer/releases/%s", filename);
    return s;
}

cfg_t   cfg = {};
#include "support/minimig/minimig_config.h"
mm_configTYPE minimig_config = {};
uint8_t rstval = 0;
void hexdump(void *data, uint16_t size, uint16_t offset) { (void)data; (void)size; (void)offset; }

// ===========================================================================
// stubs for branches the raw-HDD/-floppy boot path never enters
// ===========================================================================
struct ide_config;
int  cdrom_handle_cmd(ide_config*) { return 1; }
void cdrom_handle_pkt(ide_config*) {}
void cdrom_read(ide_config*) {}
void cdrom_reply(ide_config*, uint8_t, uint8_t, uint8_t, bool) {}
void cdrom_mode_select(ide_config*) {}
void ide_cdda_send_sector() {}
const char* cdrom_parse(uint32_t, const char*) { return 0; }
// A raw VHD has no .cfg geometry sidecar, so report "no config loaded" -- exactly what
// real MiSTer's parse_vhd_config does (VHD_NO_CONFIG) for a bare image. ide_img_set's
// caller (x86.cpp:495-518) then applies the geometry IT already chose from the image
// size: 63 SPT / 16 heads for images <= 8.4GB (line 516) -- which is what this 2GB
// Win95 VHD receives -- or the 16/256 default for larger disks. That is the exact
// geometry a real ao486 reports; because CMOS 0x39 = LBA, the BIOS derives INT 13h
// geometry from the total sector count regardless, and the data path is LBA, so this
// value is correct rather than merely "valid". The sim's vhd_error enum has only
// {VHD_NOERROR=0, VHD_ERROR=1}; return the non-zero ("no config") value so ide.cpp
// takes the `ide_set_geometry(drive, sectors, heads)` branch. Do NOT hard-set
// drive->spt/heads here -- the previous 16/63 override duplicated the caller's value
// and masked, rather than fixed, whatever early-POST fault the 256-SPT default once hit
// (that fault was resolved by the DDR/mgmt read-timing fixes; see AO486_SOC_FIX.md).
vhd_error parse_vhd_config(drive_t* drive) {
    (void)drive;
    return VHD_ERROR;   // "no .cfg" -> caller applies its size-based geometry (real MiSTer behavior)
}
int mister_load_chd(const char*, fileTYPE*) { return 1; }
int mister_chd_read_sector(chd_file*, uint32_t, uint32_t, uint32_t, void*, int*, uint8_t*) { return 1; }

// x86_share (shared-folder feature) — not needed to boot
void x86_share_reset() {}
void x86_share_poll() {}
