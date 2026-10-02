// HOST-ONLY, stubbed I/O admission microchecks. Never link the real PS backend.
// Include the exact reviewed daemon source; assertions exercise its real guards,
// CLI, FileOpenEx/FileReadAdv callbacks, reset/release and cold-loop code.
// Compile at -O0 -fno-inline -finstrument-functions. Required --wrap symbols:
// open,fopen,fdopen,fileno,fclose,fstat,lstat,fread,ferror,fgets,fgetc,mmap,close,
// usleep,pread,access,fseeko,fwrite,open64,openat,openat64,creat,creat64,
// fopen64,freopen,freopen64,mmap64,__open_2,__open64_2,__openat_2,__openat64_2.
// No real device, disk, ROM or sysfs reads.
// fmemopen and __real_* stdio operate ONLY on owned in-memory buffers.
#include <vector>
#include <string>
#include <map>
#include <algorithm>
#include <stdarg.h>
#include <assert.h>

#define main daemon_main
#include "../src/board_shim.cpp"
#undef main

#define NOINST __attribute__((no_instrument_function))
static bool track_calls = false;
static unsigned hold_calls, release_calls, flush_calls, mmio_reads, mmio_writes;
extern "C" void NOINST __cyg_profile_func_enter(void *fn, void *) {
    if (!track_calls) return;
    if (fn == reinterpret_cast<void *>(&core_hold_reset)) ++hold_calls;
    if (fn == reinterpret_cast<void *>(&core_release)) ++release_calls;
    if (fn == reinterpret_cast<void *>(&ven_flush_toggle)) ++flush_calls;
    if (fn == reinterpret_cast<void *>(&reg_rd)) ++mmio_reads;
    if (fn == reinterpret_cast<void *>(&reg_wr)) ++mmio_writes;
}
extern "C" void NOINST __cyg_profile_func_exit(void *, void *) {}

enum class Fault {
    None, Open, Fdopen, OpenStat, OpenIdentity, ReadStat, ReadIdentity,
    ShortRead, ShortRetry, ReadError, Skip, MapBounds
};
struct Stream {
    std::vector<char> bytes;
    FILE *file = nullptr;
    int kind = -1; // -3 manager, -2 iomem, 0 HDD, 1 boot0, 2 boot1
    int fd = -1;
};
struct Fixture {
    std::string manager = "operating\n";
    std::string iomem = "00000000-5fffffff : System RAM\n70000000-7fffffff : System RAM\n";
    std::string paths[3] = {"/fake/hdd.img", "/fake/bios/boot0.rom", "/fake/bios/boot1.rom"};
    struct stat stats[3] = {};
    std::map<int, int> fds;
    std::map<FILE *, Stream *> streams;
    int nextfd = 1000;
    unsigned opens = 0, ctrl_maps = 0, ddr_maps = 0, sleeps = 0;
    unsigned stat_calls[3] = {}, reads[3] = {};
    bool manager_open_fail = false, manager_error = false;
    bool iomem_open_fail = false, iomem_error = false;
    bool dev_open_fail = false, ctrl_map_fail = false, ddr_map_fail = false;
    bool wrong_ident = false;
    int preflight_lstat_fail = -1, preflight_fstat_fail = -1, preflight_changed = -1;
    int fault_rom = 1;
    Fault fault = Fault::None;
};
static Fixture fx;
static uint32_t control[CTRL_SIZE / sizeof(uint32_t)];
static uint8_t *guest = nullptr;
static unsigned tests = 0;

static void check(bool okay, const char *what) {
    if (!okay) { fprintf(stderr, "CLEAN-GUARD-FAIL: %s (case %u)\n", what, tests); abort(); }
}
static void unexpected(const char *what) {
    fprintf(stderr, "CLEAN-GUARD-UNEXPECTED-IO: %s\n", what); abort();
}
static int kind_for(const char *name) {
    for (int i = 0; i < 3; ++i) if (name && fx.paths[i] == name) return i;
    unexpected(name ? name : "null path"); return -1;
}
static Stream *stream_for(FILE *file) {
    auto it = fx.streams.find(file);
    if (it == fx.streams.end()) unexpected("unowned FILE");
    return it->second;
}
static FILE *new_stream(int kind, int fd, const std::string &text) {
    Stream *s = new Stream;
    s->kind = kind; s->fd = fd;
    s->bytes.assign(text.begin(), text.end());
    // A zero-length fmemopen buffer still requires valid owned backing storage.
    if (s->bytes.empty()) s->bytes.push_back(0);
    s->file = fmemopen(s->bytes.data(), text.size(), "rb");
    check(s->file != nullptr, "fmemopen allocation");
    fx.streams[s->file] = s;
    return s->file;
}
static bool rom_fault(int kind, Fault f) {
    return g_startup_rom_phase && kind == fx.fault_rom && fx.fault == f;
}

extern "C" {
size_t __real_fread(void *, size_t, size_t, FILE *);
int __real_ferror(FILE *);
char *__real_fgets(char *, int, FILE *);
int __real_fgetc(FILE *);
int __real_fclose(FILE *);
int __real_fseeko(FILE *, off_t, int);
size_t __real_fwrite(const void *, size_t, size_t, FILE *);

int __wrap_open(const char *name, int flags, ...) {
    if (name && !strcmp(name, "/dev/mem")) {
        ++fx.opens;
        check(flags == (O_RDWR | O_SYNC), "devmem flags");
        if (fx.dev_open_fail) { errno = EACCES; return -1; }
        return 99;
    }
    int kind = kind_for(name);
    check((flags & O_NOFOLLOW) && (flags & O_CLOEXEC), "input open nofollow/cloexec");
    if (rom_fault(kind, Fault::Open)) { errno = ENOENT; return -1; }
    int fd = fx.nextfd++;
    fx.fds[fd] = kind;
    return fd;
}
FILE *__wrap_fopen(const char *name, const char *mode) {
    check(mode && !strcmp(mode, "rb"), "fopen read-only mode");
    if (name && !strcmp(name, "/sys/class/fpga_manager/fpga0/state")) {
        if (fx.manager_open_fail) { errno = ENOENT; return nullptr; }
        return new_stream(-3, -1, fx.manager);
    }
    if (name && !strcmp(name, "/proc/iomem")) {
        if (fx.iomem_open_fail) { errno = EACCES; return nullptr; }
        return new_stream(-2, -1, fx.iomem);
    }
    unexpected(name ? name : "null fopen path"); return nullptr;
}
FILE *__wrap_fdopen(int fd, const char *mode) {
    auto it = fx.fds.find(fd);
    if (it == fx.fds.end()) unexpected("fdopen unknown fd");
    check(mode && !strcmp(mode, "rb"), "ROM fdopen read-only");
    int kind = it->second;
    if (rom_fault(kind, Fault::Fdopen)) { errno = ENOMEM; return nullptr; }
    check(kind == 1 || kind == 2, "fdopen ROM only");
    return new_stream(kind, fd, std::string(static_cast<size_t>(fx.stats[kind].st_size), kind == 1 ? '\x55' : '\x2a'));
}
int __wrap_fileno(FILE *file) { return stream_for(file)->fd; }
int __wrap_fclose(FILE *file) {
    Stream *s = stream_for(file);
    fx.streams.erase(file);
    if (s->fd >= 0) fx.fds.erase(s->fd);
    int rc = __real_fclose(file);
    delete s;
    return rc;
}
int __wrap_close(int fd) {
    if (fd == 99) return 0;
    if (!fx.fds.erase(fd)) unexpected("close unknown fd");
    return 0;
}
int __wrap_lstat(const char *name, struct stat *st) {
    int kind = kind_for(name);
    if (kind == fx.preflight_lstat_fail) { errno = EIO; return -1; }
    *st = fx.stats[kind];
    if (kind == fx.preflight_changed && ++fx.stat_calls[kind] > 1) ++st->st_ino;
    return 0;
}
int __wrap_fstat(int fd, struct stat *st) {
    auto it = fx.fds.find(fd);
    if (it == fx.fds.end()) unexpected("fstat unknown fd");
    int kind = it->second;
    if ((!g_startup_rom_phase && kind == fx.preflight_fstat_fail) ||
        rom_fault(kind, Fault::OpenStat) || (rom_fault(kind, Fault::ReadStat) && fx.reads[kind])) {
        errno = EIO; return -1;
    }
    *st = fx.stats[kind];
    if (rom_fault(kind, Fault::OpenIdentity) || (rom_fault(kind, Fault::ReadIdentity) && fx.reads[kind])) ++st->st_ino;
    return 0;
}
size_t __wrap_fread(void *buf, size_t size, size_t count, FILE *file) {
    Stream *s = stream_for(file);
    check(s->kind == 1 || s->kind == 2, "fread ROM only");
    ++fx.reads[s->kind];
    if ((rom_fault(s->kind, Fault::ShortRead) || rom_fault(s->kind, Fault::ShortRetry)) && fx.reads[s->kind] == 1) {
        check(size == 1 && count > 1, "short-read fault shape");
        return __real_fread(buf, size, count - 1, file);
    }
    return __real_fread(buf, size, count, file);
}
int __wrap_ferror(FILE *file) {
    Stream *s = stream_for(file);
    if ((s->kind == -3 && fx.manager_error) || (s->kind == -2 && fx.iomem_error) ||
        rom_fault(s->kind, Fault::ReadError)) return 1;
    return __real_ferror(file);
}
char *__wrap_fgets(char *buf, int size, FILE *file) {
    Stream *s = stream_for(file);
    check(s->kind == -3 || s->kind == -2, "fgets metadata only");
    return __real_fgets(buf, size, file);
}
int __wrap_fgetc(FILE *file) {
    check(stream_for(file)->kind == -3, "fgetc manager only");
    return __real_fgetc(file);
}
void *__wrap_mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset) {
    check(!addr && prot == (PROT_READ | PROT_WRITE) && flags == MAP_SHARED && fd == 99, "mmap signature");
    if (offset == CTRL_BASE && length == CTRL_SIZE) {
        ++fx.ctrl_maps;
        if (fx.ctrl_map_fail) { errno = ENOMEM; return MAP_FAILED; }
        control[R_IDENT / 4] = fx.wrong_ident ? 0 : IDENT_MAGIC;
        return control;
    }
    if (offset == DDR_BASE_DEFAULT && length == DDR_SIZE) {
        ++fx.ddr_maps;
        if (fx.ddr_map_fail) { errno = ENOMEM; return MAP_FAILED; }
        return guest;
    }
    unexpected("mmap unknown aperture"); return MAP_FAILED;
}
int __wrap_usleep(useconds_t) {
    check(++fx.sleeps <= 2, "cold/attach loop must remain bounded by test freeze");
    return 0;
}
ssize_t __wrap_pread(int, void *, size_t, off_t) { unexpected("pread"); return -1; }
int __wrap_open64(const char *, int, ...) { unexpected("open64"); return -1; }
int __wrap___open_2(const char *name, int flags) { return __wrap_open(name, flags); }
int __wrap___open64_2(const char *, int) { unexpected("__open64_2"); return -1; }
int __wrap___openat_2(int, const char *, int) { unexpected("__openat_2"); return -1; }
int __wrap___openat64_2(int, const char *, int) { unexpected("__openat64_2"); return -1; }
int __wrap_openat(int, const char *, int, ...) { unexpected("openat"); return -1; }
int __wrap_openat64(int, const char *, int, ...) { unexpected("openat64"); return -1; }
int __wrap_creat(const char *, mode_t) { unexpected("creat"); return -1; }
int __wrap_creat64(const char *, mode_t) { unexpected("creat64"); return -1; }
FILE *__wrap_fopen64(const char *, const char *) { unexpected("fopen64"); return nullptr; }
FILE *__wrap_freopen(const char *, const char *, FILE *) { unexpected("freopen"); return nullptr; }
FILE *__wrap_freopen64(const char *, const char *, FILE *) { unexpected("freopen64"); return nullptr; }
void *__wrap_mmap64(void *, size_t, int, int, int, __off64_t) { unexpected("mmap64"); return MAP_FAILED; }
int __wrap_access(const char *, int) { unexpected("access"); return -1; }
int __wrap_fseeko(FILE *file, off_t offset, int origin) {
    Stream *s = stream_for(file);
    check((s->kind == 1 || s->kind == 2) && offset == 0 && origin == SEEK_SET, "only retry ROM seek admitted");
    return __real_fseeko(file, offset, origin);
}
size_t __wrap_fwrite(const void *buf, size_t size, size_t count, FILE *file) {
    // GCC may lower constant fprintf/printf diagnostics to fwrite even at -O0.
    // Only inherited stdout/stderr are allowed; fake media/ROM writes abort.
    if (file == stdout || file == stderr) return __real_fwrite(buf, size, count, file);
    unexpected("non-diagnostic fwrite"); return 0;
}
}

// Harmless link stubs. No real x86/IDE PS object may be linked into this harness.
ide_config ide_inst[2] = {};
void x86_set_image(int num, char *name) {
    check(num == 2 && name && fx.paths[0] == name, "HDD0 setup shape");
}
void x86_init() {
    // The test stub reproduces only ROM callback usage, NOT the real PS backend.
    // Real x86 load_rom visits boot1 then boot0 and ignores callback failures.
    for (int kind : {2, 1}) {
        if (rom_fault(kind, Fault::Skip)) continue;
        fileTYPE f;
        if (!FileOpen(&f, fx.paths[kind].c_str())) continue;
        unsigned offset = kind == 1 ? 0xf0000 : 0xc0000;
        uint32_t address = rom_fault(kind, Fault::MapBounds) ? SHMEM_ADDR + DDR_SIZE - 1 : SHMEM_ADDR + offset;
        void *dest = shmem_map(address, static_cast<uint32_t>(f.size));
        if (!dest) { FileClose(&f); continue; }
        memset(dest, 0, static_cast<size_t>(f.size));
        FileReadAdv(&f, dest, static_cast<int>(f.size));
        if (rom_fault(kind, Fault::ShortRetry)) {
            check(FileSeek(&f, 0, SEEK_SET) == 1, "ROM retry seek");
            FileReadAdv(&f, dest, static_cast<int>(f.size));
        }
        FileClose(&f);
    }
    // Deliberate mismatch: an active LED-sync/BDA hack would rewrite 0x497.
    ddr[0x417] = 0x70;
    ddr[0x497] = 0;
}
void x86_poll(int only_ide) {
    check(only_ide == 0, "ordinary cold poll");
    // Freeze is FAKE test termination, not a claim about a guest. Set during
    // iteration zero so that its whole body runs, then next iteration exits.
    control[R_DBG_FRZINFO / 4] = 0x80000000u;
}
void x86_poll_ide0() { unexpected("attach poll not exercised"); }
int x86_attach_hdd0(const char *) { unexpected("attach backend not exercised"); return 0; }
void ide_io(int num, int req) { check(num == 0 && req == 0, "normal reset-finish poll shape"); }
extern "C" uint16_t ven_ide_irqstate(int) { return 0; }
extern "C" void ven_ide_snapshot(int, uint16_t *a, uint16_t *b, uint16_t *c,
                                  uint32_t *d, uint32_t *e, uint32_t *f, uint32_t *g) {
    *a = *b = *c = 0; *d = *e = *f = *g = 0;
}

static void reset_case() {
    check(fx.streams.empty() && fx.fds.empty(), "prior case must close every fake input");
    fx = Fixture();
    for (int i = 0; i < 3; ++i) {
        fx.stats[i].st_dev = 42; fx.stats[i].st_ino = 100 + i;
        fx.stats[i].st_mode = S_IFREG | 0600; fx.stats[i].st_nlink = 1;
        fx.stats[i].st_size = i == 0 ? 67108864 : (i == 1 ? 65536 : 32768);
        fx.stats[i].st_mtim.tv_sec = 1; fx.stats[i].st_ctim.tv_sec = 2;
    }
    memset(control, 0, sizeof(control));
    regs = nullptr; ddr = nullptr; memfd = -1; DDR_BASE = DDR_BASE_DEFAULT;
    g_startup_rom_phase = false; g_startup_rom_error = false;
    memset(g_rom_loaded, 0, sizeof(g_rom_loaded));
    memset(g_rom_paths, 0, sizeof(g_rom_paths));
    memset(g_rom_stats, 0, sizeof(g_rom_stats));
    g_bios_dir = "../3rd-party/ao486_MiSTer/releases";
    g_inject_keys = 0; g_stall_flush = 0; g_ident_win = 0; g_flush_rescues = 0;
    g_peek_addr = g_peekrun = 0; g_rng_phase = g_rng_base = 0; g_disk_reads = 0;
    hold_calls = release_calls = flush_calls = mmio_reads = mmio_writes = 0;
    unsetenv("VEN_IDE_DROP_WRITES"); unsetenv("VEN_IDE_FORCE_DISPATCH");
    ++tests;
}
static std::vector<std::string> cold_args() {
    return {"test-clean", "--hdd", fx.paths[0], "--bios", "/fake/bios", "--secs", "0"};
}
static int invoke(std::vector<std::string> args) {
    std::vector<char *> argv;
    for (auto &arg : args) argv.push_back(&arg[0]);
    argv.push_back(nullptr);
    track_calls = true;
    int rc = daemon_main(static_cast<int>(args.size()), argv.data());
    track_calls = false;
    check(fx.streams.empty() && fx.fds.empty(), "all fake inputs closed on return");
    check(flush_calls == 0, "no cache rescue function executed");
    return rc;
}
static void no_mmio() {
    check(!fx.opens && !fx.ctrl_maps && !fx.ddr_maps && !mmio_reads && !mmio_writes &&
          !hold_calls && !release_calls, "refusal precedes all MMIO/device opens");
}
static void expect_refused(std::vector<std::string> args, int rc = 2) {
    check(invoke(args) == rc, "expected refused exit"); no_mmio();
}
static void expect_cold(int rc, bool held, bool released) {
    check(invoke(cold_args()) == rc, "cold exit");
    check(hold_calls == (held ? 1u : 0u), "exact reset-hold call count");
    check(release_calls == (released ? 1u : 0u), "exact reset-release call count");
    if (held) check(control[R_CTRL / 4] == (released ? CTRL_RUN | CTRL_IRQ_EN : CTRL_CORE_RESET), "CTRL final state");
    if (released) {
        check(fx.ctrl_maps == 1 && fx.ddr_maps == 1, "exact cold apertures");
        check(g_rom_loaded[0] && g_rom_loaded[1] && !g_startup_rom_error, "both checked ROM reads required");
        check(guest[0x417] == 0x70 && guest[0x497] == 0, "no BDA LED rewrite");
        check(control[W_DBG_CMPRNG / 4] == 0 && g_rng_phase == 0, "no debug flush pulse");
    }
}

int main() {
    guest = static_cast<uint8_t *>(calloc(1, DDR_SIZE));
    check(guest != nullptr, "one reusable 256MiB fake DDR allocation");
    // Shared-memory callbacks: actual copied helper, no unbounded pointer/copy.
    reset_case(); ddr = guest;
    check(shmem_map(SHMEM_ADDR, 1) == guest, "shmem lower boundary");
    check(shmem_map(SHMEM_ADDR + DDR_SIZE - 1, 1) == guest + DDR_SIZE - 1, "shmem final byte");
    check(shmem_map(SHMEM_ADDR, DDR_SIZE) == guest, "shmem whole exact extent");
    check(shmem_map(SHMEM_ADDR + DDR_SIZE, 0) == guest + DDR_SIZE, "shmem zero-size one-past");
    check(shmem_get(SHMEM_ADDR + DDR_SIZE, 0, nullptr) && shmem_put(SHMEM_ADDR + DDR_SIZE, 0, nullptr), "zero-size null buffers do not copy");
    uint8_t value = 0xa5, output = 0;
    check(shmem_put(SHMEM_ADDR, 1, &value) && shmem_get(SHMEM_ADDR, 1, &output) && output == value, "valid lower transfer");
    value = 0x5a; output = 0;
    check(shmem_put(SHMEM_ADDR + DDR_SIZE - 1, 1, &value) && shmem_get(SHMEM_ADDR + DDR_SIZE - 1, 1, &output) && output == value, "valid upper transfer");
    struct Extent { uint32_t address, size; } bad[] = {
        {SHMEM_ADDR - 1, 0}, {SHMEM_ADDR - 1, 1}, {0, UINT32_MAX},
        {SHMEM_ADDR, UINT32_MAX}, {SHMEM_ADDR + 1, DDR_SIZE},
        {SHMEM_ADDR + DDR_SIZE - 1, 2}, {SHMEM_ADDR + DDR_SIZE, 1},
        {SHMEM_ADDR + DDR_SIZE + 1, 0}, {UINT32_MAX, 2}
    };
    for (const auto &extent : bad) {
        reset_case(); ddr = guest; output = 0xcc;
        check(!shmem_map(extent.address, extent.size), "invalid shmem map rejected");
        check(!shmem_get(extent.address, extent.size, &output) && output == 0xcc, "invalid shmem get preserves output");
        check(!shmem_put(extent.address, extent.size, &value), "invalid shmem put rejected");
        check(guest[0] == 0xa5 && guest[DDR_SIZE - 1] == 0x5a, "invalid extent preserves boundary canaries");
    }
    for (uint8_t *missing : {static_cast<uint8_t *>(nullptr), static_cast<uint8_t *>(MAP_FAILED)}) {
        reset_case(); ddr = missing;
        check(!shmem_map(SHMEM_ADDR, 0) && !shmem_get(SHMEM_ADDR, 0, nullptr) && !shmem_put(SHMEM_ADDR, 0, nullptr), "absent DDR refuses even zero extent");
    }
    reset_case(); ddr = guest;
    check(!shmem_get(SHMEM_ADDR, 1, nullptr) && !shmem_put(SHMEM_ADDR, 1, nullptr), "nonzero null buffers refused");
    for (int access = 0; access < 3; ++access) {
        reset_case(); ddr = guest; g_startup_rom_phase = true;
        if (access == 0) check(!shmem_map(SHMEM_ADDR - 1, 1), "startup bad map");
        if (access == 1) check(!shmem_get(SHMEM_ADDR, 1, nullptr), "startup bad get");
        if (access == 2) check(!shmem_put(SHMEM_ADDR, 1, nullptr), "startup bad put");
        check(g_startup_rom_error && !release_calls, "startup shared-memory failure sticky without release");
        g_startup_rom_phase = false;
    }
    // DDR guard directly exercises the implementation, not copied predicates.
    const char *accepted_maps[] = {
        "0-5fffffff : System RAM\n70000000-7fffffff : System RAM\n",
        "50000000-5fffffff : System RAM\n",
        "70000000-70000001 : System RAM\n",
        // A legitimate one-byte non-RAM resource is not a masked RAM record.
        "10-10 : reserved\n0-5fffffff : System RAM\n"
    };
    for (auto text : accepted_maps) { reset_case(); fx.iomem = text; check(require_safe_ddr_iomem() == 1, "adjacent DDR ranges admitted"); no_mmio(); }
    const char *rejected_maps[] = {
        "5fffffff-60000000 : System RAM\n", "6fffffff-70000000 : System RAM\n",
        "60000000-60000001 : System RAM\n", "50000000-70000000 : System RAM\n",
        "0-5fffffff : System RAM\n0-0 : System RAM\n", "0-0 : System RAM\n",
        "20-10 : System RAM\n",
        "10000000000000000-1ffffffffffffffff : System RAM\n",
        "0-10000000000000000 : System RAM\n", "xyz-100 : System RAM\n",
        "0-xyz : System RAM\n", "0-100 System RAM\n", "0-100 : \n",
        "0-100junk : System RAM\n", "0-100 : reserved\n", ""
    };
    for (auto text : rejected_maps) { reset_case(); fx.iomem = text; check(require_safe_ddr_iomem() == 0, "bad/masked/overlapping DDR map refused"); no_mmio(); }
    reset_case(); fx.iomem = "0-100 : " + std::string(600, 'x'); check(!require_safe_ddr_iomem(), "truncated map line refused");
    reset_case(); fx.iomem_open_fail = true; check(!require_safe_ddr_iomem(), "iomem open failure");
    reset_case(); fx.iomem_error = true; check(!require_safe_ddr_iomem(), "iomem read failure");
    for (auto text : {"operating\n", "operating"}) { reset_case(); fx.manager = text; check(require_fpga_operating(), "operating manager admitted"); no_mmio(); }
    for (auto text : {"", "unknown\n", "power off\n", "operating\nextra", "operating \n"}) {
        reset_case(); fx.manager = text; check(!require_fpga_operating(), "bad manager refused"); no_mmio();
    }
    reset_case(); fx.manager = std::string(80, 'x'); check(!require_fpga_operating(), "long manager text refused");
    reset_case(); fx.manager_open_fail = true; check(!require_fpga_operating(), "manager open failure");
    reset_case(); fx.manager_error = true; check(!require_fpga_operating(), "manager read failure");
    // Actual CLI gate, before any manager or input admission can reach MMIO.
    for (auto flag : {"--inject-keys", "--stall-flush", "--trace", "--freeze", "--tracesecs", "--cmpcfg", "--cmprng", "--loadonly", "--peek", "--peekrun"}) {
        reset_case(); expect_refused({"test-clean", flag});
    }
    for (auto env : {"VEN_IDE_DROP_WRITES", "VEN_IDE_FORCE_DISPATCH"}) {
        for (auto value : {"1", "false"}) { reset_case(); setenv(env, value, 1); expect_refused({"test-clean", "--ident"}); }
        for (auto value : {"0", ""}) {
            reset_case(); setenv(env, value, 1); check(invoke({"test-clean", "--ident"}) == 0, "disabled env admitted");
            check(fx.ctrl_maps == 1 && !fx.ddr_maps && !hold_calls && !release_calls && !mmio_writes, "IDENT maps CTRL only");
        }
    }
    for (auto value : {"-1", "+1", " 1", "1x", "2147483648", "18446744073709551616", ""}) {
        reset_case(); expect_refused({"test-clean", "--secs", value});
    }
    for (auto value : {"0", "2147483647"}) { reset_case(); auto a = cold_args(); a[6] = value; check(invoke(a) == 0 && release_calls == 1, "secs boundary admitted"); }
    for (auto value : {"0", "256", "16x", "+16"}) { reset_case(); expect_refused({"test-clean", "--mem", value}); }
    reset_case(); check(invoke({"test-clean", "--ident", "--mem", "16"}) == 0, "mem16 admitted");
    for (auto value : {"0", "0x60000001", "0x60000000junk", "0x160000000", "18446744073709551616", "-0x60000000", ""}) {
        reset_case(); expect_refused({"test-clean", "--membase", value});
    }
    for (auto value : {"0x60000000", "1610612736"}) { reset_case(); check(invoke({"test-clean", "--ident", "--membase", value}) == 0 && !fx.ddr_maps, "exact base admitted"); }
    reset_case(); expect_refused({"test-clean", "--ident", "--attach"});
    reset_case(); expect_refused({"test-clean"});
    reset_case(); expect_refused({"test-clean", "--hdd", ""});
    reset_case(); fx.paths[0] = std::string(1024, 'h'); expect_refused(cold_args());
    reset_case(); fx.paths[0] = std::string(1023, 'h'); expect_cold(0, true, true);
    // Generic input geometry/stat preflight rejects before /dev/mem.
    for (off_t size : {off_t(0), off_t(513)}) { reset_case(); fx.stats[0].st_size = size; expect_refused(cold_args()); }
    for (mode_t mode : {mode_t(S_IFDIR | 0600), mode_t(S_IFLNK | 0600)}) { reset_case(); fx.stats[0].st_mode = mode; expect_refused(cold_args()); }
    reset_case(); fx.stats[0].st_nlink = 2; expect_refused(cold_args());
    reset_case(); fx.preflight_lstat_fail = 0; expect_refused(cold_args());
    reset_case(); fx.preflight_fstat_fail = 0; expect_refused(cold_args());
    reset_case(); fx.preflight_changed = 0; expect_refused(cold_args());
    for (int kind : {1, 2}) { reset_case(); --fx.stats[kind].st_size; expect_refused(cold_args()); }
    reset_case(); fx.manager = "power off\n"; expect_refused(cold_args(), 1);
    reset_case(); fx.iomem = "0-7fffffff : System RAM\n"; expect_refused(cold_args(), 1);
    reset_case(); fx.iomem = "0-0 : System RAM\n"; expect_refused(cold_args(), 1);
    // Mapping failures never release or reach a reset/RAM-zero operation.
    reset_case(); fx.dev_open_fail = true; expect_cold(1, false, false);
    reset_case(); fx.ctrl_map_fail = true; expect_cold(1, false, false);
    reset_case(); fx.ddr_map_fail = true; expect_cold(1, false, false);
    reset_case(); fx.wrong_ident = true; expect_cold(1, false, false);
    // Both ROM positions, actual callback failures, required reads and sticky error.
    for (int kind : {1, 2}) {
        for (auto fault : {Fault::Open, Fault::Fdopen, Fault::OpenStat, Fault::OpenIdentity,
                           Fault::ReadStat, Fault::ReadIdentity, Fault::ShortRead,
                           Fault::ShortRetry, Fault::ReadError, Fault::Skip, Fault::MapBounds}) {
            reset_case(); fx.fault_rom = kind; fx.fault = fault; expect_cold(1, true, false);
            if (fault == Fault::ShortRetry) check(g_rom_loaded[0] && g_rom_loaded[1] && g_startup_rom_error, "successful retry does not clear sticky ROM failure");
        }
    }
    reset_case(); expect_cold(0, true, true);
    check(!fx.streams.size() && !fx.fds.size(), "final fake input closure");
    free(guest);
    printf("CLEAN-GUARD-MICROCHECK-OK: %u cases; real guards/CLI/ROM callbacks; fake I/O only\n", tests);
    printf("LIMITS: no real PS backend, physical MMIO, DT reservation, guest execution, standard-suite or gameplay qualification\n");
    return 0;
}
