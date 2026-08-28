// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/tb/tb_main.cpp
//
// Producer C top-level: the Verilator C++ testbench. It builds the verilated
// ventium_top model, loads a flat test image into the bus-functional memory,
// drives clk/rst_n, services the mem_* bus each clock, and lets the core retire
// instructions through the vtm_retire DPI callback (which writes the func-mode
// .vtrace via dpi_retire.cpp / trace_writer.h).
//
// Contracts:
//   - docs/rtl-interface.md §1 (ports), §3 (mem_* bus), §4 (image load), §5 (M0)
//   - docs/trace-format.md   §1/§2.2 (func-mode .vtrace)
//   - PLAN.md §4.2 (RTL trace from Verilator), §7 M0 gate (boot+canned retire)
//
// CLI:
//   --image <flat blob>   raw bytes to load into memory          (optional)
//   --load  <hexaddr>     byte address to load the blob at        (default 0)
//   --entry <hexaddr>     entry / reset EIP (informational at M0) (default 0)
//   --out   <trace.vtrace> output trace file                      (required)
//   --max-insn   N        stop after N retired instructions       (default 1<<20)
//   --max-cycles M        stop after M core clocks                (default 1<<24)
//   --trace-vcd  f        write a Verilator VCD waveform to f      (optional)
//   --quiesce    K        idle-cycle threshold to declare done    (default 64)

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include "verilated.h"
#include "Vventium_top.h"
#if VM_TRACE
#  include "verilated_vcd_c.h"
#endif
#ifdef VEN_SAVABLE
#  include "verilated_save.h"   // VerilatedSave/Restore — full-model sim checkpointing
#endif
#ifdef VEN_XOVER
#  include "xover.h"            // task #102 state-crossover (RTL<->qemu) extract/inject
#endif

#include "memmodel.h"
#include "trace_writer.h"
#include "quake_image.h"
#include "win95_cosim.h"
#include "syscall_emu.h"   // M14 free-run syscall emulator

#ifdef VEN_DOS_MODELS
// Faithful FreeDOS repro: the SAME PS-side peripheral C models ven_soc_app drives
// on the KV260, wired to tb_main's io_* bridge so SeaBIOS POST follows the board's
// EXACT path through L1/AXI — to pinpoint a board-only memory-path freeze in sim.
// Declared exactly like tb_soc.cpp (Verilator builds the .c models as C++).
#include "ven_periph.h"
ven_periph_t* ven_i8042_new(void);
ven_periph_t* ven_pic_new(void);
ven_periph_t* ven_vgaregs_new(void);
ven_periph_t* ven_pit_new(void);
ven_periph_t* ven_rtc_new(void);
ven_periph_t* ven_ide_new(const char* disk_path);
const uint8_t* ven_vgaregs_dac(ven_periph_t* p);  // live 768B DAC palette (6-bit RGB)
extern int    g_ven_f4a_arm;   // ven_ide sets this when VEN_F4A_ARM_LBA is read (F4A trace arm)
void          ven_pic_set_irq(ven_periph_t*, int irq, int level);
uint8_t       ven_pic_peek_vector(ven_periph_t*);
uint8_t       ven_pic_intack(ven_periph_t*);
int           ven_pit_irq0_ticks(ven_periph_t*);
#endif

#include <vector>
#include <memory>

namespace {

struct Args {
    std::string image;
    std::string out;
    std::string vcd;
    uint32_t load_addr  = 0;
    uint32_t entry      = 0;
    uint32_t init_esp   = 0x40c34910;  // QEMU linux-user initial ESP (M1 default;
                                       // exact value is argv/env-dependent, so the
                                       // gate passes the golden's n=0 ESP explicitly)
    uint64_t max_insn   = 1ull << 20;
    uint64_t max_cycles = 1ull << 24;
    uint32_t quiesce    = 64;     // K consecutive no-retire cycles => done
    bool     x87        = false;  // emit x87 fields + header x87:true (M3)
    bool     cycle      = false;  // emit cycle-mode trace + header mode:cycle (M4)
    bool     soc_en     = false;  // force core soc_en=1 for a -bios firmware (CPUID/etc. ungate)
    // M5B-int: --bus-mode drives the top bus_mode=1, routing the core memory
    // through the gated pin-level 64-bit P5 bus subsystem (rtl/bus/biu.sv ->
    // biu_p5). DEFAULT 0 = the direct mem_* path (byte-identical, the M4/M5-gated
    // path). No new C++ memory responder is needed: the loopback responder is in
    // RTL, and this same TB memmodel is the bus subsystem's abstract BACK side.
    // Only FUNCTIONAL equivalence is meaningful through the bus (no pin-level
    // cycle oracle — docs/m5b-bus-spec.md §5.3), so --bus-mode is for func runs.
    bool     bus_mode   = false;
    // P1-1: --l1-axi drives the top l1axi_en=1 (bus_mode=2), routing the core mem
    // port through ventium_l1_axi (ven_l1d + ven_axi_master) to an AXI4 master that
    // this TB's behavioral DDR slave services off the SAME MemModel. Only meaningful
    // in the +VEN_L1_AXI build; FUNCTIONAL equivalence vs mode 0 (timing emergent).
    bool     l1_axi     = false;
    bool     golden     = false;  // --golden: ven_l1d flush-after-each-access (L1-useless diagnostic)
    uint32_t errata     = 0;      // M6 errata-enable bus (default 0 = clean core)
    // M2S.1: --system selects boot_mode=system (cold reset at F000:FFF0, real
    // mode) and emits the sys fields + header sys:true. A -bios image is loaded
    // so its LAST byte sits at 0x000FFFFF (image base = 0x100000 - image_bytes),
    // matching qemu-system-i386 -bios; the reset vector F000:FFF0 = 0x000FFFF0
    // then lands on the image's last 16 bytes.
    bool     system     = false;
    // P2 repro: --cosim enables the port-I/O co-sim bus (cosim_en=1) for a plain
    // -bios run (no win95 golden) — services OUT/IN so a real-mode test image
    // (e.g. calltest) executes its COM1 writes + isa-debug-exit. COM1 (0x3F8/0xE9)
    // OUT bytes are printed so SAAAZ-style output is visible; lets us reproduce the
    // deployed-config CALL/RET failure in sim through the L1AXI+REMAP path.
    bool     cosim       = false;
    bool     dos         = false;        // VEN_DOS_MODELS: wire the PS peripheral C models
    std::string disk;                    // --disk <img> for the IDE C model (--dos)
    uint32_t dbg_step_n  = 0;            // VEN_DBG_CORE: single-step N instructions + log each
    uint32_t dbg_bp      = 0;            // VEN_DBG_CORE: --dbg-bp <eip> hardware breakpoint
    // M2S.5 SMM structural self-check: after the run, dump the SMM-relevant
    // physical memory (the handler sentinels @ 0x2000.. AND the P5 save-state
    // map @ SMBASE+0xFE00..) to this JSON file so the RTL-only self-check can
    // assert the round-trip + the P5 save-map at the DOCUMENTED offsets — the
    // RTL analogue of the QMP free-run readback (psmm-selfcheck.py). Off unless
    // --smm-dump is given (so it never perturbs the normal func/sys gates).
    std::string smm_dump;
    uint32_t smbase = 0x30000;   // default SMBASE (overridable via --smbase)

    // M7.1 Quake user-mode lock-step (docs/m7-lockstep-spec.md). --quake-image
    // loads the producer's initial-process-image JSON (regions + regs/segs) and
    // ENABLES the int-0x80 proxy + %gs base path (proxy_en=1). --lockstep names
    // the GOLDEN .vtrace whose per-record sys_call effects the proxy replays at
    // each int-0x80 (writes -> bus memory; ret/resume-eip/gs -> core). Both off by
    // default, so every existing user/sys/cycle gate is byte-identical.
    std::string quake_image;
    std::string lockstep;

    // M7.3b Win95 system co-sim (docs/m7-lockstep-spec.md M7.3). --win95-image
    // loads the producer's initial PHYSICAL-memory image (paddr-keyed regions),
    // forces --system boot (cold reset at F000:FFF0), and ENABLES the port-I/O
    // co-sim bus (cosim_en=1) so the core EXECUTES IN/OUT. --lockstep names the
    // GOLDEN .vtrace whose dev_in[] read values the bus replays at each IN (the
    // only environment input injected). Both off by default -> every existing
    // gate is byte-identical. The RTL emits a --system retire trace graded by
    // compare_stream.py (sys mode).
    std::string win95_image;

    // M14 free-run syscall EMULATION (with --quake-image, WITHOUT --lockstep):
    // the TB emulates int-0x80 directly so the RTL runs the ELF to completion.
    bool        emulate     = false;   // --emulate-syscalls
    std::string user_stdin;            // --user-stdin <file>  (bytes for read())
    std::string user_stdout;           // --user-stdout <file> (captured fd 1/2)
    uint32_t    brk_base    = 0;       // --brk-base <hexaddr> (initial program break)

    // --no-trace: do NOT open a TraceWriter (leave g_trace == nullptr). The
    // per-retire DPI then early-returns BEFORE the ~718-byte fprintf record
    // (g_last_arch is still maintained, so --checkpoint-* keeps working). This
    // is a large free-run speedup for runs that discard the trace anyway (e.g.
    // the Quake framebuffer demo, which only wants the captured frame stream).
    bool        no_trace    = false;   // --no-trace

    // M14 periodic complete-state checkpoints (free-run "replay mechanism"):
    // every N retired insns, dump {arch regs + full MemModel} to a 2-deep ring in
    // --checkpoint-dir. The newest checkpoint before a divergence is the restart /
    // inspect point.
    uint64_t    checkpoint_every = 0;  // --checkpoint-every N (0 = off)
    std::string checkpoint_dir;        // --checkpoint-dir D

    // ---- full-model sim state checkpoint (requires the --savable build) --------
    // Save the entire RTL model (top), MemModel, PS peripheral models + tb scalars
    // at --save-at-cycle, and/or restore them at startup, so a long deterministic
    // boot is run ONCE and later iterations resume from near the point of interest.
    // Two files: <prefix>.vlt (RTL via VerilatedSave) + <prefix>.aux (everything else).
    std::string save_state;            // --save-state <prefix>     (write checkpoint)
    std::string restore_state;         // --restore-state <prefix>  (load at startup)
    uint64_t    save_at_cycle = 0;     // --save-at-cycle N         (clock to write at)
    bool        save_exit     = false; // --save-exit               (stop right after saving)

    // M14 video capture (Quake): the guest's $P5Q_VIDEO path; the emulator
    // captures writes to it (the P5Q1 frame stream) and we dump them to
    // --video-out for offline PNG conversion.
    std::string video_path;            // --video-path <guest $P5Q_VIDEO value>
    std::string video_out;             // --video-out <file> (raw P5Q1 stream)
    std::string dump_fb;               // --dump-fb <file> (vid.buffer @0x087a29e0 at exit)

    // ---- task #102 state-crossover harness (VEN_XOVER build only) -------------
    // --xover-save <prefix> @ --xover-at-retire N: when the FSM is at a clean
    // instruction boundary (S_DECODE) at/after retire N, dump {arch regs + full
    // MemModel} to <prefix>.arch/.mem and (optionally) stop. --xover-load <prefix>:
    // re-inject a (qemu-produced) arch+mem state into the core at startup-or-boundary
    // and continue. Off by default; only the new xover build links the implementation.
    std::string xover_save_prefix;     // --xover-save <prefix>
    std::string xover_load_prefix;     // --xover-load <prefix>
    uint64_t    xover_at_retire = 0;   // --xover-at-retire N (save trigger; 0 = off)
    bool        xover_save_exit = false; // --xover-save-exit (stop right after saving)
    int         xover_at_cs    = -1;   // --xover-at-cs <hex> (also require dbg_cs==this; -1=any)
    int64_t     xover_at_eip   = -1;   // --xover-at-eip <hex> (require architectural eip==this; -1=any)
};

[[noreturn]] void usage(const char* prog, int code) {
    std::fprintf(stderr,
        "usage: %s --out <trace.vtrace> [--image <blob> --load <hexaddr>]\n"
        "          [--entry <hexaddr>] [--init-esp <hexaddr>]\n"
        "          [--max-insn N] [--max-cycles M]\n"
        "          [--trace-vcd f] [--quiesce K] [--x87] [--cycle] [--bus-mode] [--system]\n"
        "          [--errata <hexmask>] [--smm-dump <file>] [--smbase <hexaddr>]\n"
        "          [--quake-image <image.json> --lockstep <golden.vtrace>]\n"
        "          [--win95-image <image.json> --lockstep <golden.vtrace>]\n", prog);
    std::exit(code);
}

uint32_t parse_u32(const char* s) {
    return (uint32_t)std::strtoul(s, nullptr, 0);   // 0x.. or decimal
}
uint64_t parse_u64(const char* s) {
    return (uint64_t)std::strtoull(s, nullptr, 0);
}

Args parse_args(int argc, char** argv) {
    Args a;
    for (int i = 1; i < argc; ++i) {
        const std::string k = argv[i];
        // Verilator plusargs (+verilator+rand+reset+N, +verilator+seed+N, ...) are
        // consumed by Verilated::commandArgs() in main(); skip them here so the
        // x-init fetch sweep can pass them through without tripping "unknown argument".
        if (!k.empty() && k[0] == '+') continue;
        auto need = [&](const char* opt) -> const char* {
            if (i + 1 >= argc) {
                std::fprintf(stderr, "%s: %s requires an argument\n", argv[0], opt);
                usage(argv[0], 2);
            }
            return argv[++i];
        };
        if      (k == "--image")      a.image      = need("--image");
        else if (k == "--out")        a.out        = need("--out");
        else if (k == "--trace-vcd")  a.vcd        = need("--trace-vcd");
        else if (k == "--load")       a.load_addr  = parse_u32(need("--load"));
        else if (k == "--entry")      a.entry      = parse_u32(need("--entry"));
        else if (k == "--init-esp")   a.init_esp   = parse_u32(need("--init-esp"));
        else if (k == "--max-insn")   a.max_insn   = parse_u64(need("--max-insn"));
        else if (k == "--max-cycles") a.max_cycles = parse_u64(need("--max-cycles"));
        else if (k == "--quiesce")    a.quiesce    = parse_u32(need("--quiesce"));
        else if (k == "--x87")        a.x87        = true;
        else if (k == "--cycle")      a.cycle      = true;
        else if (k == "--bus-mode")   a.bus_mode   = true;   // M5B-int
        else if (k == "--l1-axi")     a.l1_axi     = true;   // P1-1 bus_mode=2
        else if (k == "--golden")     a.golden     = true;   // ven_l1d flush-after-each-access
        else if (k == "--system")     a.system     = true;
        else if (k == "--soc-en")     a.soc_en     = true;
        else if (k == "--cosim")    { a.cosim = true; a.system = true; }   // P2 repro
        else if (k == "--dos")      { a.dos = true; a.cosim = true; a.system = true; }
        else if (k == "--disk")       a.disk       = need("--disk");
        else if (k == "--dbg-step")   a.dbg_step_n = parse_u32(need("--dbg-step"));
        else if (k == "--dbg-bp")     a.dbg_bp     = parse_u32(need("--dbg-bp"));
        else if (k == "--smm-dump")   a.smm_dump    = need("--smm-dump");
        else if (k == "--smbase")     a.smbase      = parse_u32(need("--smbase"));
        else if (k == "--quake-image") a.quake_image = need("--quake-image");
        else if (k == "--win95-image") a.win95_image = need("--win95-image");
        else if (k == "--lockstep")    a.lockstep    = need("--lockstep");
        else if (k == "--emulate-syscalls") a.emulate = true;
        else if (k == "--no-trace")         a.no_trace = true;
        else if (k == "--user-stdin")  a.user_stdin  = need("--user-stdin");
        else if (k == "--user-stdout") a.user_stdout = need("--user-stdout");
        else if (k == "--brk-base")    a.brk_base    = parse_u32(need("--brk-base"));
        else if (k == "--checkpoint-every") a.checkpoint_every = parse_u64(need("--checkpoint-every"));
        else if (k == "--checkpoint-dir")   a.checkpoint_dir   = need("--checkpoint-dir");
        else if (k == "--save-state")       a.save_state       = need("--save-state");
        else if (k == "--restore-state")    a.restore_state    = need("--restore-state");
        else if (k == "--save-at-cycle")    a.save_at_cycle    = parse_u64(need("--save-at-cycle"));
        else if (k == "--save-exit")        a.save_exit        = true;
        else if (k == "--video-path") a.video_path = need("--video-path");
        else if (k == "--video-out")  a.video_out  = need("--video-out");
        else if (k == "--dump-fb")    a.dump_fb    = need("--dump-fb");
        else if (k == "--xover-save")      a.xover_save_prefix = need("--xover-save");
        else if (k == "--xover-load")      a.xover_load_prefix = need("--xover-load");
        else if (k == "--xover-at-retire") a.xover_at_retire   = parse_u64(need("--xover-at-retire"));
        else if (k == "--xover-at-cs")      a.xover_at_cs       = (int)parse_u32(need("--xover-at-cs"));
        else if (k == "--xover-at-eip")     a.xover_at_eip      = (int64_t)parse_u32(need("--xover-at-eip"));
        else if (k == "--xover-save-exit") a.xover_save_exit   = true;
        else if (k == "--errata")     a.errata     = parse_u32(need("--errata"));
        else if (k == "-h" || k == "--help") usage(argv[0], 0);
        else {
            std::fprintf(stderr, "%s: unknown argument '%s'\n", argv[0], k.c_str());
            usage(argv[0], 2);
        }
    }
    if (a.out.empty() && !a.no_trace) {
        std::fprintf(stderr, "%s: --out is required (or pass --no-trace)\n", argv[0]);
        usage(argv[0], 2);
    }
    return a;
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Args args = parse_args(argc, argv);

    // ---- backing memory + image -------------------------------------------
    ventium::MemModel mem;
    // task #52: optional backing-store latency. The model acks in-cycle by default,
    // which makes the M4/M5 cycle bands a statement about the core's fill FSM rather
    // than about memory cost -- that is how hardware retiring nothing on 98.66% of
    // cycles passed every gate green (DISK_BOOT_STATUS UPDATE 229/230). Unset => 0 =>
    // byte-identical to before, so all existing goldens stay reproducible.
    //   VEN_MEM_RD_LAT / VEN_MEM_WR_LAT : per-access stall in core cycles.
    // CALIBRATE from hardware (perf counters at 0x100-0x150); do not guess.
    {
        const char* rl = getenv("VEN_MEM_RD_LAT");
        const char* wl = getenv("VEN_MEM_WR_LAT");
        unsigned r = rl ? (unsigned)strtoul(rl, nullptr, 0) : 0u;
        unsigned w = wl ? (unsigned)strtoul(wl, nullptr, 0) : 0u;
        if (r || w) {
            mem.set_latency(r, w);
            fprintf(stderr, "[memmodel] latency ENABLED: read=%u write=%u core cycles "
                            "(cycle bands below are NOT comparable to the 0-latency goldens)\n", r, w);
        }
    }
    if (!args.image.empty()) {
        // M2S.1 --system: a -bios image is mapped so its LAST byte is at
        // 0x000FFFFF (and the reset vector F000:FFF0 -> 0x000FFFF0 lands on its
        // last 16 bytes). We compute the load address from the file size:
        // load_addr = 0x00100000 - filesize. The whole image then sits at
        // 0x000F0000.. for a 64 KiB image (where segment 0xF000, base 0x000F0000,
        // and the PM code at 0x000Fxxxx all resolve). User mode keeps --load.
        uint32_t load_at = args.load_addr;
        if (args.system) {
            long sz = 0;
            { FILE* f = std::fopen(args.image.c_str(), "rb");
              if (f) { std::fseek(f, 0, SEEK_END); sz = std::ftell(f); std::fclose(f); } }
            if (sz <= 0 || sz > 0x00100000) {
                std::fprintf(stderr, "tb: --system bios image bad size %ld\n", sz);
                return 2;
            }
            load_at = (uint32_t)(0x00100000u - (uint32_t)sz);
        }
        long n = mem.load_image(args.image, load_at);
        if (n < 0) {
            std::fprintf(stderr, "tb: failed to load image '%s'\n",
                         args.image.c_str());
            return 2;
        }
        std::fprintf(stderr, "tb: loaded %ld bytes at 0x%08x from %s%s\n",
                     n, load_at, args.image.c_str(),
                     args.system ? " (bios)" : "");
#ifdef VEN_KV260_SOC
        // 4 GiB-TOP ALIAS, KV260 form: the deployed bitstream folds the high BIOS
        // ROM window (0xFFFE0000.. for a 128 KiB ROM) into the DDR carveout via
        // ventium_top's L1AXI_ADDR_MASK=0x0FFF_FFFF wrap, and the PS stages a 2nd
        // BIOS copy at carveout offset 0x0FFE0000 to back it. After the BFM strips
        // AXI_REMAP it sees that MASKED phys, so we stage the same copy here. Only
        // a real BIOS (>64 KiB) POSTs from the high alias; smaller stubs are inert.
        if (args.system) {
            long sz = 0;
            { FILE* f = std::fopen(args.image.c_str(), "rb");
              if (f) { std::fseek(f, 0, SEEK_END); sz = std::ftell(f); std::fclose(f); } }
            if (sz > 0x10000) {
                uint32_t hi_masked = (uint32_t)((0u - (uint32_t)sz) & 0x0FFFFFFFu);
                mem.load_image(args.image, hi_masked);
                std::fprintf(stderr, "tb: KV260 4G-top alias (masked) at 0x%08x\n", hi_masked);
            }
        }
#endif
    }

    // ---- M7.1 Quake initial process image + int-0x80 proxy ----------------
    // When --quake-image is given: map the producer's process image (PT_LOAD +
    // stack + vDSO regions) into the bus memory at their vaddrs, seed the reset
    // regs (entry/esp/eflags) + flat user selectors, and ENABLE proxy_en. The
    // golden's sys_call effects (--lockstep) are replayed at each int-0x80.
    bool                          proxy_mode = false;
    std::vector<ventium::SyscallEffect> syscalls;
    size_t                        sc_idx = 0;   // next syscall to replay (in order)
    // M14 free-run emulator state (captured by service_proxy + the run loop).
    std::unique_ptr<ventium::SyscallEmulator> emu;
    bool      emu_exit = false, emu_unsupported = false;
    int       emu_code = 0;  uint32_t emu_bad_nr = 0;
    uint64_t  last_emu_n = ~0ull;
    uint32_t  emu_eax = 0, emu_gs = 0;  bool emu_apply_gs = false;
    if (!args.quake_image.empty()) {
        ventium::QuakeImage img = ventium::load_quake_image(args.quake_image, mem);
        if (!img.ok) {
            std::fprintf(stderr, "tb: failed to load --quake-image '%s'\n",
                         args.quake_image.c_str());
            return 2;
        }
        // Seed the core's reset architectural state from the image (the TB plays
        // the loader: it establishes exactly QEMU's starting process image).
        args.entry    = img.eip;
        args.init_esp = img.esp;
        proxy_mode    = true;
        if (args.emulate) {
            // M14 free-run: EMULATE int-0x80 (no golden). Slurp the optional stdin
            // feed; pick a safe default program break if the harness gave none.
            std::vector<uint8_t> sin;
            if (!args.user_stdin.empty()) {
                if (FILE* f = std::fopen(args.user_stdin.c_str(), "rb")) {
                    int c; while ((c = std::fgetc(f)) != EOF) sin.push_back((uint8_t)c);
                    std::fclose(f);
                }
            }
            uint32_t brk0 = args.brk_base ? args.brk_base : 0x0a000000u;
            emu.reset(new ventium::SyscallEmulator(mem, std::move(sin), brk0));
            if (!args.video_path.empty()) emu->set_video_path(args.video_path);
            std::fprintf(stderr,
                "tb: FREE-RUN emulate ON (proxy_en=1): entry=0x%08x esp=0x%08x "
                "brk_base=0x%08x stdin=%zuB\n", img.eip, img.esp, brk0,
                args.user_stdin.empty() ? (size_t)0 : (size_t)1);
        } else {
            if (!args.lockstep.empty())
                syscalls = ventium::load_syscall_replay(args.lockstep);
            std::fprintf(stderr,
                "tb: quake lock-step ON (proxy_en=1): entry=0x%08x esp=0x%08x, "
                "%zu syscalls to replay\n", img.eip, img.esp, syscalls.size());
        }
    }

    // ---- M7.3b Win95 initial physical-memory image + port-I/O co-sim --------
    // When --win95-image is given: map the producer's phys regions into bus
    // memory (paddr-keyed), force --system boot (cold reset at F000:FFF0), and
    // ENABLE cosim_en so the core EXECUTES IN/OUT through the io_* bus. The
    // golden's dev_in read VALUES (--lockstep) are returned, in order, at each IN.
    bool                       cosim_mode = false;
    std::vector<ventium::DevIn> devins;
    size_t                     devin_idx = 0;   // next dev_in value to return (in order)
    bool                       devin_had_intr = false;
    if (!args.win95_image.empty()) {
        ventium::Win95Image img = ventium::load_win95_image(args.win95_image, mem);
        if (!img.ok) {
            std::fprintf(stderr, "tb: failed to load --win95-image '%s'\n",
                         args.win95_image.c_str());
            return 2;
        }
        // The co-sim boots in SYSTEM mode (cold reset F000:FFF0). The core's own
        // reset arch state IS the golden record 0 (we do NOT inject CPU regs);
        // cosim_en additionally selects the `-cpu pentium` reset EDX=0x543. We do
        // NOT override args.entry/init_esp: boot_mode=system seeds CS:EIP itself.
        args.system = true;
        cosim_mode  = true;
        if (!args.lockstep.empty()) {
            devins = ventium::load_devin_replay(args.lockstep, &devin_had_intr);
        }
        std::fprintf(stderr,
            "tb: WIN95 co-sim ON (cosim_en=1, system boot): %ld phys regions, "
            "%zu dev_in values to replay%s\n",
            img.n_regions, devins.size(),
            devin_had_intr ? " [WARNING: intr in prefix — injection deferred!]" : "");
    }

    // P2 repro: plain -bios co-sim (no win95 golden) — execute IN/OUT via the io bus.
    if (args.cosim) cosim_mode = true;

    // F4A environment-replay: --dos --lockstep <golden> makes the core's IN reads
    // (fw_cfg, PIC, PIT, RTC, IDE — EVERY port) return qemu's recorded dev_in values
    // instead of the PS C-models, so the core sees qemu's EXACT environment and the
    // full-boot differential stays aligned through POST (where qemu's fw_cfg diverges
    // from the board's CMOS-only path). Routed in the IN path below via dos_env_replay.
    bool dos_env_replay = false;
    if (args.dos && !args.lockstep.empty()) {
        devins = ventium::load_devin_replay(args.lockstep, &devin_had_intr);
        dos_env_replay = !devins.empty();
        std::fprintf(stderr,
            "tb: --dos ENV-REPLAY ON: %zu dev_in values from %s%s\n",
            devins.size(), args.lockstep.c_str(),
            devin_had_intr ? " [golden carries intr — timing replay needed]" : "");
    }

#ifdef VEN_DOS_MODELS
    // --dos: instantiate the PS peripheral C models (same code ven_soc_app runs on
    // the KV260) so SeaBIOS POST gets faithful device responses + follows the board's
    // exact path through L1/AXI. Lets a board-only memory-path freeze be found in sim.
    ven_periph_t *g_pit=nullptr,*g_rtc=nullptr,*g_ide=nullptr,*g_pic=nullptr,
                 *g_i8042=nullptr,*g_vga=nullptr;
    if (args.dos) {
        g_pit=ven_pit_new(); g_rtc=ven_rtc_new(); g_pic=ven_pic_new();
        g_i8042=ven_i8042_new(); g_vga=ven_vgaregs_new();
        g_ide = args.disk.empty() ? nullptr : ven_ide_new(args.disk.c_str());
        std::fprintf(stderr, "tb: --dos PS peripheral C models wired (disk=%s)\n",
                     args.disk.empty() ? "(none)" : args.disk.c_str());
    }
    auto dos_model_of = [&](uint16_t port) -> ven_periph_t* {
        if (!args.dos) return nullptr;
        if (port==0x60 || port==0x64) return g_i8042;
        if (port==0x20||port==0x21||port==0xA0||port==0xA1||port==0x4D0||port==0x4D1) return g_pic;
        if (port>=0x3B0 && port<=0x3DF) return g_vga;
        if (port>=0x40 && port<=0x43) return g_pit;
        if (port==0x70 || port==0x71) return g_rtc;
        if ((port>=0x1F0 && port<=0x1F7) || port==0x3F6) return g_ide;
        return nullptr;
    };

    // ---- soft-VGA: PS-side INT 10h (VGABIOS) for DOS Quake (task #99) --------
    // PORT of ven_soc_app.c's --soft-vga into the sim. The vgabios-stdvga option
    // ROM is unusable on Ventium (no PCI std-vga device), so the PS *is* the
    // VGABIOS: a tiny in-guest stub installed at C000:0 (IVT[0x10] -> it, after
    // POST) saves the guest regs to C000:0x100 then OUTs the VGA trap port; the
    // TB services the call here and writes mode-13h state into MemModel. Mode-13h
    // pixels land at 0xA0000 (dumped to /tmp/sim_vga13.bin at exit); the palette
    // comes via AH=10/AL=12 routed into the existing g_vga DAC. Env-gated by
    // VEN_SOFTVGA so the default --dos run is byte-identical (stub never installs).
    const bool soft_vga = args.dos && (std::getenv("VEN_SOFTVGA") != nullptr);
    // VEN_SOFTVGA_FORCE installs the stub immediately (no POST/IDE-read trigger) —
    // for a bare-metal INT 10h soft-VGA unit test that never boots a disk.
    const bool soft_vga_force = soft_vga && (std::getenv("VEN_SOFTVGA_FORCE") != nullptr);
    bool softvga_installed = false, softvga_post_done = false;
    bool softvga_flush_req = false;     // ORed into flush_l1_pending each clock
    unsigned long softvga_calls = 0;
    static const uint32_t VGA_STUB_PHYS = 0xC0000u;
    static const uint16_t VGA_STUB_SEG  = 0xC000u;
    static const uint32_t VGA_REGBUF    = VGA_STUB_PHYS + 0x100u; // AX@+0 BX@+2 CX@+4 DX@+6 SI@+8 DI@+a BP@+c ES@+e DS@+10
    static const uint16_t VGA_TRAP_PORT = 0x02E0u;
    // 93-byte stub: save AX/BX/CX/DX/SI/DI/BP/ES/DS to cs:0x100..; out 0x2E0,al;
    // restore them from the (possibly TB-modified) buffer; iret. (Identical bytes
    // to ven_soc_app.c's g_vga_stub, so board and sim share one VGABIOS contract.)
    static const uint8_t g_vga_stub[] = {
        0x2e,0xa3,0x00,0x01, 0x2e,0x89,0x1e,0x02,0x01, 0x2e,0x89,0x0e,0x04,0x01,
        0x2e,0x89,0x16,0x06,0x01, 0x2e,0x89,0x36,0x08,0x01, 0x2e,0x89,0x3e,0x0a,0x01,
        0x2e,0x89,0x2e,0x0c,0x01, 0x2e,0x8c,0x06,0x0e,0x01, 0x2e,0x8c,0x1e,0x10,0x01,
        0xba,0xe0,0x02, 0xee,
        0x2e,0xa1,0x00,0x01, 0x2e,0x8b,0x1e,0x02,0x01, 0x2e,0x8b,0x0e,0x04,0x01,
        0x2e,0x8b,0x16,0x06,0x01, 0x2e,0x8b,0x36,0x08,0x01, 0x2e,0x8b,0x3e,0x0a,0x01,
        0x2e,0x8b,0x2e,0x0c,0x01, 0x2e,0x8e,0x06,0x0e,0x01, 0x2e,0x8e,0x1e,0x10,0x01,
        0xcf
    };
    auto gr16 = [&](uint32_t p)->uint16_t { return (uint16_t)(mem.read8(p) | (mem.read8(p+1) << 8)); };
    auto gw16 = [&](uint32_t p, uint16_t v){ mem.write8(p, (uint8_t)v); mem.write8(p+1, (uint8_t)(v>>8)); };
    auto softvga_install = [&]() {
        for (size_t i = 0; i < sizeof(g_vga_stub); i++) mem.write8(VGA_STUB_PHYS + (uint32_t)i, g_vga_stub[i]);
        gw16(0x40, 0x0000);            // IVT[0x10].offset
        gw16(0x42, VGA_STUB_SEG);      // IVT[0x10].segment
        softvga_flush_req = true;      // refetch the new stub bytes + IVT coherently
        std::fprintf(stderr, "tb: soft-VGA INT10h installed (stub@C000:0, trap port 0x%x)\n", VGA_TRAP_PORT);
    };
    auto softvga_set_mode13 = [&]() {
        mem.write8(0x449, 0x13);                  // BDA video mode = 13h
        gw16(0x44a, 40); gw16(0x44c, 0);          // BDA columns / regen size
        mem.write8(0x462, 0); mem.write8(0x487, 0x60); // active page / VGA mode flags (graphics)
    };
    auto softvga_service = [&]() {
        uint16_t ax = gr16(VGA_REGBUF+0), bx = gr16(VGA_REGBUF+2),
                 cx = gr16(VGA_REGBUF+4), dx = gr16(VGA_REGBUF+6),
                 es = gr16(VGA_REGBUF+0x0e);
        uint8_t  ah = (uint8_t)(ax >> 8), al = (uint8_t)ax;
        if (softvga_calls++ < 64 || ah != 0x0E)
            std::fprintf(stderr, "tb: soft-vga int10 #%lu ax=%04x bx=%04x cx=%04x dx=%04x\n",
                         softvga_calls, ax, bx, cx, dx);
        switch (ah) {
            case 0x00:                                  // set video mode
                if (al == 0x13) softvga_set_mode13(); else mem.write8(0x449, al);
                break;
            case 0x02:                                  // set cursor position
                gw16(0x450, dx);
                break;
            case 0x03:                                  // get cursor -> DX=pos CX=shape
                dx = gr16(0x450); cx = gr16(0x460);
                break;
            case 0x0E: {                                // teletype: write AL, advance cursor (page 0)
                uint8_t ch = al;
                uint16_t cur = gr16(0x450);
                uint8_t col = (uint8_t)cur, row = (uint8_t)(cur >> 8);
                uint8_t cols = (uint8_t)gr16(0x44a); if (!cols) cols = 80;
                { static char cbuf[256]; static int cn = 0;   // mirror teletype -> stderr (fault banner detection)
                  if (ch == 0x0A || cn >= 255) { cbuf[cn] = 0; if (cn) std::fprintf(stderr, "GUESTCON: %s\n", cbuf); cn = 0; }
                  else if (ch >= 0x20) cbuf[cn++] = (char)ch; }
                if      (ch == 0x0D) col = 0;
                else if (ch == 0x0A) row++;
                else if (ch == 0x08) { if (col) col--; }
                else {
                    uint32_t v = 0xB8000u + ((uint32_t)row*cols + col)*2u;
                    mem.write8(v, ch); mem.write8(v+1, 0x07);
                    if (++col >= cols) { col = 0; row++; }
                }
                if (row >= 25) {                        // scroll up one line
                    uint32_t w = (uint32_t)cols*2u, b = 0xB8000u;
                    for (uint32_t i = 0; i < w*24u; i++) mem.write8(b+i, mem.read8(b+w+i));
                    for (uint32_t i = 0; i < cols;  i++) { mem.write8(b+w*24u+i*2,(uint8_t)' '); mem.write8(b+w*24u+i*2+1,0x07); }
                    row = 24;
                }
                gw16(0x450, (uint16_t)(((uint16_t)row << 8) | col));
                break; }
            case 0x0F:                                  // get mode -> AL=mode AH=cols BH=page
                ax = (uint16_t)(((uint16_t)(uint8_t)gr16(0x44a) << 8) | mem.read8(0x449));
                bx = (uint16_t)(bx & 0x00ff);
                break;
            case 0x10:                                  // palette / DAC
                if (al == 0x12 && g_vga) {              // set block: ES:DX -> (R,G,B) table, BX start, CX count
                    uint32_t tbl = ((uint32_t)es << 4) + dx;
                    g_vga->io_write(g_vga, 0x3C8, (uint8_t)bx);
                    for (uint16_t i = 0; i < cx; i++) {
                        g_vga->io_write(g_vga, 0x3C9, mem.read8(tbl + i*3 + 0));
                        g_vga->io_write(g_vga, 0x3C9, mem.read8(tbl + i*3 + 1));
                        g_vga->io_write(g_vga, 0x3C9, mem.read8(tbl + i*3 + 2));
                    }
                } else if (al == 0x10 && g_vga) {       // set single DAC reg: BX=index, DH=r DL=g CH=b... actually CH=g CL=b DH=r
                    g_vga->io_write(g_vga, 0x3C8, (uint8_t)bx);
                    g_vga->io_write(g_vga, 0x3C9, (uint8_t)(dx >> 8));   // R
                    g_vga->io_write(g_vga, 0x3C9, (uint8_t)(cx >> 8));   // G
                    g_vga->io_write(g_vga, 0x3C9, (uint8_t)cx);          // B
                }
                break;
            case 0x1A:                                  // get display combination code -> VGA color
                if (al == 0x00) { ax = 0x001A; bx = (uint16_t)((bx & 0xff00) | 0x08); }
                break;
            case 0x4F:                                  // VBE: leave AX=0x4Fxx (!=0x004F) -> unsupported
            default:                                    // -> Quake falls back to mode 13h
                break;
        }
        gw16(VGA_REGBUF+0, ax); gw16(VGA_REGBUF+2, bx);
        gw16(VGA_REGBUF+4, cx); gw16(VGA_REGBUF+6, dx);
        softvga_flush_req = true;   // stub re-reads the regbuf through L1 after the OUT
    };

    // IRQ0 (timer) pump — PIT-DRIVEN, EMULATED-TIME-paced. The 8254 C model
    // (g_pit, the same ven_pit.c the KV260 runs) decides the IRQ0 rate from the
    // guest's port-0x40/0x43 counter0 reload + mode; we feed it an emulated
    // nanosecond clock and ven_pit_irq0_ticks() reports how many ch0 periods
    // elapsed -> latch IRQ0 pending.
    //
    // ROOT-CAUSE FIX (DOS-Quake go32 #DE): the OLD pump free-ran at a FIXED
    // VEN_IRQ0_PERIOD=8000 core-cycles, IGNORING the guest's PIT programming, so a
    // BIOS INT 1Ch timer tick landed inside a CWSDPMI real-mode reflection window
    // and corrupted its bookkeeping -> eventual zero denominator -> "Division by
    // Zero eip=0x24e". The cure is a tick-to-INSTRUCTION ratio that matches a real
    // Pentium / qemu, where the guest executes MILLIONS of instructions between
    // timer ticks. A cycle-rated clock at the 40 MHz core rate is NOT enough: the
    // Verilated/RTL core spends ~10 cycles per retired instruction, so a 40 MHz
    // cycle clock still ticks ~15-20x too often per instruction and the bad tick
    // recurs (just at a different instruction). So the emulated clock is rated by
    // RETIRED INSTRUCTIONS at a target MIPS (~real-Pentium throughput), which fixes
    // the insn-per-tick density directly.
    //
    // The catch: a STI;HLT timer-wait (SeaBIOS boot menu, DOS idle) FREEZES the
    // retire count, so an instruction-only clock would never advance during HLT and
    // the wait would deadlock. Real hardware keeps ticking while halted, waking the
    // CPU. So while the core is NOT retiring (idle/halt), the clock instead advances
    // by core cycles at VEN_EMU_HZ (40 MHz) — fast enough to wake a HLT wait. Net:
    //   emulated_ns = retired_insn * 1e9 / EMU_MIPS  (executing: correct density)
    //               + halt_cycles  * 1e9 / EMU_HZ    (halted:    wakes the wait)
    // Both bases are deterministic (no wall-clock), so the run is reproducible.
    //
    // VEN_IRQ0_PERIOD still honored as a legacy ESCAPE HATCH (fixed-cycle pump) for
    // the old cadence-sweep diagnostics; default is the PIT-driven path.
    const uint64_t DOS_IRQ0_PERIOD =
        std::getenv("VEN_IRQ0_PERIOD") ? (uint64_t)strtoull(std::getenv("VEN_IRQ0_PERIOD"),0,0) : 0;
    // Target emulated instruction throughput (MIPS) — sets the insn-per-tick density
    // during execution. ~100 MIPS gives ~5.5M instructions per default-18.2Hz tick,
    // matching a fast Pentium; override with VEN_EMU_MIPS. Higher = sparser ticks.
    const uint64_t DOS_EMU_MIPS =
        std::getenv("VEN_EMU_MIPS") ? (uint64_t)strtoull(std::getenv("VEN_EMU_MIPS"),0,0) : 100ull;
    uint64_t dos_halt_cycles = 0;   // core cycles accumulated while NOT retiring (HLT/idle)
    // Emulated core clock (Hz) used to advance PIT time during HLT/idle. Default
    // 40 MHz (the deployed KV260 PL0 rate); override with VEN_EMU_HZ.
    const uint64_t DOS_EMU_HZ =
        std::getenv("VEN_EMU_HZ") ? (uint64_t)strtoull(std::getenv("VEN_EMU_HZ"),0,0) : 40000000ull;
    uint64_t dos_irq0_next = DOS_IRQ0_PERIOD;   // legacy fixed-pump next-edge cycle
    int      dos_pit_pending = 0;
#endif

    // ---- trace writer (opens file + writes header) ------------------------
    // --no-trace leaves g_trace == nullptr: the per-retire DPI early-returns
    // before formatting/writing any record (see dpi_retire.cpp), a large
    // free-run speedup. g_last_arch is still updated, so --checkpoint-* works.
    ventium::TraceWriter trace;
    if (args.no_trace) {
        // Count retirements (the loop's progress/termination signal) but skip
        // all per-instruction record formatting — the big free-run speedup.
        trace.open_discard();
    } else {
        char note[256];
        std::snprintf(note, sizeof note,
                      "ventium tb; entry=0x%08x load=0x%08x image=%s%s%s",
                      args.entry, args.load_addr,
                      args.image.empty() ? "(none)" : args.image.c_str(),
                      args.x87   ? " x87"   : "",
                      args.cycle ? " cycle" : "");
        // --cycle wins over --x87: a cycle trace carries no x87 fields. open()
        // forces x87:false in cycle mode, so the header stays well-formed.
        // --system adds the sys fields (cr0..cr4) + header sys:true (func mode).
        if (!trace.open(args.out, note, args.x87, args.cycle, args.system)) {
            std::fprintf(stderr, "tb: cannot open trace '%s'\n", args.out.c_str());
            return 2;
        }
    }
    ventium::g_trace = &trace;   // dpi_retire.cpp emits records through this

    // ---- verilated model --------------------------------------------------
    auto* top = new Vventium_top;

#if VM_TRACE
    VerilatedVcdC* vcd = nullptr;
    if (!args.vcd.empty()) {
        Verilated::traceEverOn(true);
        vcd = new VerilatedVcdC;
        top->trace(vcd, 99);
        vcd->open(args.vcd.c_str());
    }
#else
    if (!args.vcd.empty()) {
        std::fprintf(stderr,
            "tb: --trace-vcd given but model built without tracing "
            "(rebuild with TRACE=1)\n");
    }
#endif

    // Time in *half cycles*: even = clk low (we drive inputs / settle),
    // odd = clk high (rising edge work happens at the low->high eval).
    uint64_t half = 0;
    auto dump = [&](uint64_t t) {
#if VM_TRACE
        if (vcd) vcd->dump((vluint64_t)t);
#else
        (void)t;
#endif
    };

#ifdef VEN_L1_AXI
    // ---- behavioral AXI4 DDR slave (P1-1 --l1-axi / bus_mode=2) -------------
    // Services the core's m_axi master off the SAME MemModel `mem`. Synchronous:
    // its outputs are driven combinationally from registered state (axi_drive,
    // called from service_bus so every bus-service phase drives them), and the
    // state advances ONCE per rising edge using PRE-EDGE handshakes — axi_capture()
    // right after clk=1 (reads the DUT's pre-edge m_axi outputs + the slave's own
    // pre-advance state), axi_advance() after the edge eval (using those captured
    // values). This pre-edge capture is required: a synchronous slave and the DUT
    // master each decide their handshake from the OTHER side's pre-edge value.
    // REMAP_BASE=0 in ventium_top, so m_axi addr == x86 phys (direct MemModel index).
    // Inert in modes 0/1 (the master never issues -> the slave stays IDLE).
    int      axr = 0;                  // read FSM: 0=IDLE, 1=BEAT
    int      axw = 0;                  // write FSM: 0=IDLE, 1=DATA, 2=RESP
    uint32_t axr_addr = 0, axw_addr = 0, axr_cnt = 0;
    uint32_t axr_size = 2;               // R2-H01: latched ARSIZE (0=1B,1=2B,2=4B)
    struct { bool ar,r,aw,w,b; uint32_t araddr,arlen,awaddr,wdata,wstrb,arsize; } axhs{};
    // #34: AXI_STUCK=1 freezes the slave (a dead DDR/bridge) to exercise the master
    // watchdog -> bus_err -> the core's S_HALT override (cpu_hung), end-to-end.
    const bool axi_stuck = (std::getenv("AXI_STUCK") != nullptr);
    // P2 repro: AXI_RLAT/AXI_WLAT add read/write response latency (wait states) so the
    // sim slave behaves like the real smartconnect + PS DDR (multi-cycle, not immediate)
    // — exposes any L1/AXI fetch-redirect race the immediate-response slave masks.
    const uint32_t AXI_RLAT = std::getenv("AXI_RLAT") ? (uint32_t)atoi(std::getenv("AXI_RLAT")) : 0;
    const uint32_t AXI_WLAT = std::getenv("AXI_WLAT") ? (uint32_t)atoi(std::getenv("AXI_WLAT")) : 0;
    uint32_t axr_lat = 0, axw_lat = 0;   // remaining wait cycles before R / B
    // F4 INVESTIGATOR-A: FAITHFUL R-channel timing. The idealized slave above returns
    // every line-fill R beat zero-gap, in-order, no backpressure — a real PS DDR +
    // SmartConnect returns R beats with variable first-beat latency, mid-burst RVALID
    // deassertions (gaps), and respects RREADY backpressure. AXI_RGAP=1 turns on a
    // deterministic-PRNG faithful model so the L1/AXI fill FSM is exercised against the
    // exact beat patterns silicon produces. Default off => the 77-corpus stays clean.
    //   AXI_RGAP=1            : enable faithful R timing (PRNG seed = AXI_RSEED or 1)
    //   AXI_RSEED=<n>         : PRNG seed (sweep many beat patterns)
    //   AXI_RFIRST=<n>        : max extra first-beat (AR->first R) latency, 0..n random
    //   AXI_RGAPMAX=<n>       : max inter-beat gap (RVALID deasserts), 0..n random (def 3)
    //   AXI_RGAPPROB=<0..100> : % chance of a gap before each non-first beat (def 60)
    // The model still honors RREADY (only counts a beat on rvalid&&rready) and presents
    // a STABLE rdata/rlast while rvalid is held but unaccepted (AXI VALID-stability).
    const bool     AXI_RGAP    = (std::getenv("AXI_RGAP") != nullptr);
    const uint32_t AXI_RSEED   = std::getenv("AXI_RSEED")   ? (uint32_t)strtoul(std::getenv("AXI_RSEED"),0,0) : 1u;
    const uint32_t AXI_RFIRST  = std::getenv("AXI_RFIRST")  ? (uint32_t)atoi(std::getenv("AXI_RFIRST"))  : 4u;
    const uint32_t AXI_RGAPMAX = std::getenv("AXI_RGAPMAX") ? (uint32_t)atoi(std::getenv("AXI_RGAPMAX")) : 3u;
    const uint32_t AXI_RGAPPRB = std::getenv("AXI_RGAPPROB")? (uint32_t)atoi(std::getenv("AXI_RGAPPROB")): 60u;
    uint32_t rgap_state = AXI_RSEED ? AXI_RSEED : 1u;       // xorshift32 PRNG state
    auto rgap_rng = [&]() -> uint32_t {                     // deterministic per-seed
        uint32_t x = rgap_state; x ^= x<<13; x ^= x>>17; x ^= x<<5; rgap_state = x; return x;
    };
    // AXI_WPOST: model a POSTED write — BVALID returns (write "accepted") but the
    // datum becomes globally visible only AXI_WPOST clocks later. A read-miss fill
    // that races into that window reads STALE backing (pre-write) data, exactly like
    // the real PL->smartconnect->DDR path where BVALID precedes DRAM commit. This
    // exposes ven_l1d's no-write-allocate hole: a write-miss (e.g. __init_libc's
    // `rep stos` zeroing an uncached buffer) goes write-through only, and a later
    // read-miss of the same line fills from not-yet-committed DRAM -> garbage ->
    // free-run derail (single-step drains the post between insns, hiding it). 0=off.
    const uint32_t AXI_WPOST = std::getenv("AXI_WPOST") ? (uint32_t)atoi(std::getenv("AXI_WPOST")) : 0;
    struct PostW { uint32_t addr, val; int cd; };
    std::vector<PostW> wpost_q;
    // P2 repro: under VEN_KV260_SOC the L1/AXI master remaps x86 phys into the DDR
    // carveout (m_axi addr = 0x4000_0000 + phys, ventium_top L1AXI_REMAP_BASE). The
    // MemModel is x86-phys-indexed, so subtract the carveout base off every AXI addr.
#ifdef VEN_KV260_SOC
    const uint32_t AXI_REMAP = 0x40000000u;
#else
    const uint32_t AXI_REMAP = 0u;
#endif
    auto axi_drive = [&]() {
        if (axi_stuck) {  // never ready/valid
            top->m_axi_arready=0; top->m_axi_rvalid=0; top->m_axi_rdata=0; top->m_axi_rlast=0;
            top->m_axi_rid=0; top->m_axi_rresp=0; top->m_axi_awready=0; top->m_axi_wready=0;
            top->m_axi_bvalid=0; top->m_axi_bid=0; top->m_axi_bresp=0; return;
        }
        const bool r_rdy = (axr==1) && (axr_lat==0);   // data ready only after RLAT waits
        const bool b_rdy = (axw==2) && (axw_lat==0);
        top->m_axi_arready = (axr==0);
        top->m_axi_rvalid  = r_rdy;
        // R2-H01: honor ARSIZE per the AXI narrow-transfer rule -- the addressed
        // bytes on their OWN lanes, zeros elsewhere (the RTL's narrow device
        // pieces depend on it; a 4B fill beat is the full word, as before).
        uint32_t rd32 = 0;
        if (r_rdy) {
            const uint32_t nb   = 1u << axr_size;
            const uint32_t lane = axr_addr & 3u;
            for (uint32_t b = lane; b < lane + nb && b < 4; ++b)
                rd32 |= (uint32_t)mem.read8(axr_addr + (b - lane)) << (8u*b);
        }
        top->m_axi_rdata   = rd32;
        top->m_axi_rlast   = r_rdy && (axr_cnt==0);
        top->m_axi_rid = 0; top->m_axi_rresp = 0;
        top->m_axi_awready = (axw==0);
        top->m_axi_wready  = (axw==1);
        top->m_axi_bvalid  = b_rdy;
        top->m_axi_bid = 0; top->m_axi_bresp = 0;
    };
    auto axi_capture = [&]() {
        if (axi_stuck) { axhs = {}; return; }   // frozen: no handshakes
        axhs.ar = (axr==0) && (bool)top->m_axi_arvalid;
        axhs.r  = (axr==1) && (axr_lat==0) && (bool)top->m_axi_rready;
        axhs.aw = (axw==0) && (bool)top->m_axi_awvalid;
        axhs.w  = (axw==1) && (bool)top->m_axi_wvalid;
        axhs.b  = (axw==2) && (axw_lat==0) && (bool)top->m_axi_bready;
        axhs.araddr = (uint32_t)top->m_axi_araddr - AXI_REMAP; axhs.arlen = (uint32_t)top->m_axi_arlen;
        axhs.arsize = (uint32_t)top->m_axi_arsize;
        axhs.awaddr = (uint32_t)top->m_axi_awaddr - AXI_REMAP;
        axhs.wdata  = (uint32_t)top->m_axi_wdata;  axhs.wstrb = (uint32_t)top->m_axi_wstrb;
    };
    auto axi_advance = [&]() {
        if (!top->rst_n) { axr=0; axw=0; axr_lat=0; axw_lat=0; wpost_q.clear(); return; }
        // drain posted writes whose visibility delay has elapsed (apply to backing).
        if (!wpost_q.empty()) {
            size_t k = 0;
            for (size_t i = 0; i < wpost_q.size(); ++i) {
                if (--wpost_q[i].cd <= 0) mem.write32(wpost_q[i].addr, wpost_q[i].val);
                else wpost_q[k++] = wpost_q[i];
            }
            wpost_q.resize(k);
        }
        if (axr==0) { if (axhs.ar) {
                          axr_addr=axhs.araddr; axr_cnt=axhs.arlen; axr_size=axhs.arsize; axr=1;
                          // first-beat (AR->first R) latency: fixed AXI_RLAT, plus a
                          // random 0..AXI_RFIRST under the faithful model (real DDR
                          // open-row vs precharge variance).
                          axr_lat = AXI_RLAT + (AXI_RGAP ? (rgap_rng() % (AXI_RFIRST+1)) : 0);
                      } }
        else        { if (axr_lat>0) axr_lat--;                  // gap cycle: rvalid==0
                      else if (axhs.r)  {                        // beat accepted (rvalid&&rready)
                          if (axr_cnt==0) axr=0;
                          else {
                              axr_cnt--; axr_addr+=4;
                              // inter-beat latency: fixed AXI_RLAT, plus under the
                              // faithful model a random gap (RVALID deasserts mid-burst)
                              // with probability AXI_RGAPPROB, size 1..AXI_RGAPMAX.
                              uint32_t g = 0;
                              if (AXI_RGAP && AXI_RGAPMAX>0 && (rgap_rng()%100) < AXI_RGAPPRB)
                                  g = 1 + (rgap_rng() % AXI_RGAPMAX);
                              axr_lat = AXI_RLAT + g;
                          }
                      } }
        if (axw==0) { if (axhs.aw) { axw_addr=axhs.awaddr; axw=1; } }
        else if (axw==1) { if (axhs.w) {
            // FAITHFUL DDR/AXI write: a 32-bit-bus write places byte lane b at the
            // WORD-ALIGNED address + b, selected by WSTRB. (A real DDR controller
            // ignores awaddr[1:0] for lane placement — the address's low bits must be
            // reflected in WSTRB by the master.) Aligning here models real hardware;
            // the earlier byte-addressed write() was too lenient and HID the L1/AXI
            // unaligned-write lane bug (a sub-word write to a non-word-aligned byte
            // address wrote the wrong bytes on silicon but "passed" in sim).
            uint32_t aligned = axw_addr & ~3u;
            uint32_t old=mem.read32(aligned), nw=0;
            for (int b=0;b<4;b++){ uint32_t by=((axhs.wstrb>>b)&1)?((axhs.wdata>>(b*8))&0xff)
                                                                  :((old>>(b*8))&0xff); nw|=by<<(b*8); }
#ifdef VEN_DBG_CORE
            // DEBUG: force DF_FIXED into the C: ddt descflags to PROVE the wedge is the
            // dropped-DF_FIXED detection bug. VEN_FORCE_DFFIXED=<word addr of descflags>
            // (e.g. 0x27ec); DF_FIXED=bit0 of descflags low byte @+1 == bit8 of the word.
            { static uint32_t dff = std::getenv("VEN_FORCE_DFFIXED")
                  ? (uint32_t)strtoul(std::getenv("VEN_FORCE_DFFIXED"),0,0) : 0;
              if (dff && aligned == (dff & ~3u)) nw |= 0x0100u; }
#endif
            if (AXI_WPOST > 0) wpost_q.push_back({aligned, nw, (int)AXI_WPOST}); // posted: defer visibility
            else               mem.write32(aligned,nw);                          // immediate (coherent)
#ifdef VEN_DBG_CORE
            { static uint32_t wbase = std::getenv("VEN_WATCH")
                  ? (uint32_t)strtoul(std::getenv("VEN_WATCH"), 0, 0) : 0xFFFFFFFFu;
              if (wbase != 0xFFFFFFFFu && aligned >= (wbase & ~0x1fu) && aligned < ((wbase & ~0x1fu) + 0x40))
                std::fprintf(stderr, "tb: [watch] WR [%05x] strb=%x wdata=%08x : %08x -> %08x  (last retire EIP=%08x)\n",
                             aligned, (unsigned)axhs.wstrb, (uint32_t)axhs.wdata, old, nw,
                             (uint32_t)ventium::g_last_arch.pc); }
#endif
            axw=2; axw_lat=AXI_WLAT; } }
        else { if (axw_lat>0) axw_lat--; else if (axhs.b) axw=0; }
    };
#endif

    // ---- service the bus + step one half-cycle ----------------------------
    // The mem_* protocol is single-beat / combinational-OK at M0: we compute
    // (rdata, ack) from the core's current bus outputs, drive them back, and
    // re-eval so the same clock edge sees the response. (docs/rtl-interface §3)
    auto service_bus = [&]() {
        uint32_t rdata = 0;
        bool ack = false;
        mem.service((bool)top->mem_req, (bool)top->mem_we,
                    (uint32_t)top->mem_addr, (uint32_t)top->mem_wdata,
                    (uint8_t)top->mem_wstrb, &rdata, &ack);
        top->mem_rdata = rdata;
        top->mem_ack   = ack;
        // VEN_BWATCH: BFM-side store/load tracer (env-gated, inert by default).
        // Logs every mem-port access touching the 32-byte line around the addr.
        if (top->mem_req && ack) {
            static uint32_t bw = std::getenv("VEN_BWATCH")
                ? (uint32_t)strtoul(std::getenv("VEN_BWATCH"), 0, 0) : 0xFFFFFFFFu;
            if (bw != 0xFFFFFFFFu) {
                uint32_t a = (uint32_t)top->mem_addr;
                if ((a & ~0x1fu) == (bw & ~0x1fu)) {
                    std::fprintf(stderr,
                        "tb: [bwatch] %s addr=%05x strb=%x wdata=%08x rdata=%08x EIP=%08x\n",
                        top->mem_we ? "WR" : "RD", a, (unsigned)top->mem_wstrb,
                        (uint32_t)top->mem_wdata, rdata,
                        (uint32_t)ventium::g_last_arch.pc);
                }
            }
        }
#ifdef VEN_L1_AXI
        axi_drive();   // keep the AXI slave outputs driven every bus-service phase
#endif
    };

    // ---- M7.3b Win95 port-I/O co-sim service (combinational, like the bus) ---
    // The core raises io_req for the S_IO clock(s) of an IN/OUT. We ack it and:
    //   * IN  (io_we=0): drive back the NEXT golden dev_in VALUE on io_rdata. The
    //     value is the ONLY thing injected (the device-read the CPU cannot
    //     compute); the core writes it width-aware into eAX itself. We CROSS-CHECK
    //     the core's io_addr/io_size against the recorded dev_in port/size and
    //     advance the cursor exactly once per IN (committed on the rising edge).
    //   * OUT (io_we=1): consume the value (the CPU computed it). The existing
    //     isa-debug-exit `out 0xf4` terminates the run (flagged via io_exit).
    // INERT when cosim_mode==0 (io_req never asserts; io_rdata/io_ack stay 0).
    bool     io_pending_in = false;   // an IN is being serviced this clock
    bool     io_used_golden = false;  // this IN consumed a golden dev_in (scoped replay)
    bool     io_exit       = false;   // saw an `out 0xf4` (isa-debug-exit)
    uint8_t  io_exit_al    = 0;       // the AL value of that `out 0xf4` (status source)
    uint64_t io_in_count   = 0;       // diagnostics: IN reads serviced
    uint64_t io_out_count  = 0;       // diagnostics: OUT writes consumed
    int      io_desync     = 0;       // diagnostics: port/size mismatches (a bug)
    bool     io_serviced   = false;   // FIX: current io_req assertion already had its 1 side-effect
    uint32_t io_held_rdata = 0;       //      held IN value while io_req stays asserted (S_IO multi-clock)
    // wedge diag: per-port IO histogram + recent-op ring (env-gated dump at exit).
    // Classifies a busy loop: a dominant polled port => peripheral-model gap;
    // zero IO in the wedge window => a CPU/logic loop (rep-string class).
    std::vector<uint64_t> io_rd_hist(65536, 0), io_wr_hist(65536, 0);
    uint64_t io_op_seq = 0;
    static const int IO_RING = 64;
    uint32_t io_ring_port[IO_RING] = {0}; uint8_t  io_ring_we[IO_RING] = {0};
    uint32_t io_ring_val[IO_RING]  = {0}; uint64_t io_ring_seq[IO_RING] = {0};
    int io_ring_pos = 0;
    auto service_io = [&]() {
        if (!cosim_mode) {
            if (getenv("VEN_IOPROBE") && top->io_req) {
                static long n = 0;
                if (n < 8) fprintf(stderr, "[IOPROBE] io_req=1 addr=%04x we=%d size=%u\n",
                                   (unsigned)top->io_addr, (int)top->io_we, (unsigned)top->io_size);
                n++;
                if (n == 8) fprintf(stderr, "[IOPROBE] (further io_req assertions suppressed)\n");
            }
            // task #73: acknowledge the cycle. An unclaimed port reads as 0 and
            // swallows writes -- what an empty ISA slot does -- and 0xf4 terminates the
            // run exactly as in cosim mode. Leaving io_ack at 0 modelled nothing and
            // held the core forever. Same once-per-assertion discipline as the cosim
            // path below: do the side effect once, then hold ack until io_req drops.
            if (!top->io_req) {
                top->io_rdata = 0; top->io_ack = 0;
                io_pending_in = false; io_serviced = false;
                return;
            }
            if (io_serviced) { top->io_rdata = 0; top->io_ack = 1; return; }
            io_serviced = true;
            if (top->io_we && ((uint32_t)top->io_addr == 0xf4)) {
                io_exit = true; io_exit_al = (uint8_t)(top->io_wdata & 0xff);
            }
            top->io_rdata = 0; top->io_ack = 1;
            return; }
        if (!top->io_req) {            // bus idle: ready for the next op
            top->io_rdata = 0; top->io_ack = 0;
            io_pending_in = false; io_serviced = false;
            return;
        }
        // The core HOLDS io_req asserted for the S_IO clock(s). Do the side-effecting
        // device access EXACTLY ONCE per assertion (matching ven_soc_app's poll->ack on
        // silicon), then just HOLD io_ack/io_rdata until io_req deasserts. Re-doing it
        // every clock quad-counted OUTs and (worse) advanced FIFO/data-port reads
        // multiple times per IN -> SeaBIOS POST desync (the old --dos sim divergence).
        if (io_serviced) { top->io_rdata = io_held_rdata; top->io_ack = 1; return; }
        io_serviced = true;
        const uint32_t port = (uint32_t)top->io_addr;
        const uint32_t size = (uint32_t)top->io_size;
        if (top->io_we) {
            // OUT: the CPU drives the value out; we consume it. The isa-debug-exit
            // port 0xf4 stops the run (matches qemu-system -device isa-debug-exit).
            // Capture the AL value so a bare-metal self-checking sys image (e.g.
            // verif/sys/tests/pdtlbw) can report PASS/FAIL through the exit STATUS:
            // qemu's isa-debug-exit maps AL -> process status ((AL<<1)|1), so we
            // mirror that as the TB's exit code (qemu-faithful; inert otherwise).
            if (port == 0xf4) { io_exit = true; io_exit_al = (uint8_t)(top->io_wdata & 0xff); }
#ifdef VEN_DOS_MODELS
            else if (soft_vga && port == VGA_TRAP_PORT) {
                // soft-VGA INT 10h trap: the in-guest stub OUTs here after staging
                // the guest regs to C000:0x100. Service the call; the stub then
                // restores (TB-modified) regs from the buffer and IRETs.
                softvga_service();
            }
            else if (ven_periph_t* m = dos_model_of((uint16_t)port)) {
                // soft-VGA install trigger: the first ATA READ-SECTORS (0x20) to the
                // IDE cmd port = the boot sector load = POST done + 0xC0000 is free.
                if (soft_vga && port == 0x1F7 && (top->io_wdata & 0xff) == 0x20)
                    softvga_post_done = true;
                if (std::getenv("VEN_PIC_LOG") && port == 0x21 && (top->io_wdata & 0xff) == 0x08)
                    std::fprintf(stderr, "[PICOUT] OUT 0x21,0x08 retire=%llu cs=0x%04x eip=0x%08x\n",
                                 (unsigned long long)trace.retired(), (unsigned)top->dbg_cs,
                                 (uint32_t)top->dbg_eip);
                m->io_write(m, (uint16_t)port, (uint8_t)(top->io_wdata & 0xff));
            }
#endif
            else if (args.cosim && (port == 0x3f8 || port == 0xe9 || port == 0x402)) {
                std::putchar((int)(top->io_wdata & 0xff)); std::fflush(stdout);  // COM1 / qemu-dbg / SeaBIOS DEBUG_IO_PORT
                // F4A: a sentinel byte 0x07 on 0xe9 arms the f4a per-commit trace
                // (a marker .COM emits it right before the instruction under study,
                // so the trace captures that exact region instead of the boot idle).
                // Guarded: g_ven_f4a_arm only exists in the VEN_DOS_MODELS build.
#ifdef VEN_DOS_MODELS
                if (port == 0xe9 && (top->io_wdata & 0xff) == 0x07) g_ven_f4a_arm = 1;
#endif
            }
            io_held_rdata = 0;
            io_pending_in = false;
        } else {
            // IN: return the next recorded dev_in value (in order). Cross-check the
            // port + size; a mismatch is a HARNESS/stream desync — report, do not
            // silently mis-replay. Over-run / plain --cosim (no golden dev_in stream):
            // return OPEN BUS 0xFF.. — a real PC (and qemu) float an unmodeled port
            // high, and SeaBIOS branches on 0xFF; returning 0 derails POST.
            uint32_t v = (size == 1) ? 0xFFu : (size == 2) ? 0xFFFFu : 0xFFFFFFFFu;
#ifdef VEN_DOS_MODELS
            bool used_model = false;
            io_used_golden = false;
            // SCOPED ENV-REPLAY: the PS C-models serve the modeled ports (PIC/PIT/RTC/IDE,
            // which already match qemu); the golden serves ONLY the UNMODELED ports —
            // i.e. qemu's fw_cfg (0x510/0x511), the sole environment divergence.
            if (ven_periph_t* m = dos_model_of((uint16_t)port)) {
                v = (size >= 2 && m->io_read16) ? m->io_read16(m, (uint16_t)port)
                                                : m->io_read(m, (uint16_t)port);
                used_model = true;
            } else if (args.dos && port == 0x3fd) { v = 0x60; used_model = true;  // COM1 LSR
            } else if (args.dos && port == 0x3f8) { v = 0x00; used_model = true;  // COM1 RBR
            }
            (void)dos_env_replay;
            // the golden serves ONLY qemu's fw_cfg (0x510/0x511) — the one device the
            // core lacks; all other unmodeled ports stay open-bus (0xff), matching a
            // real PC, so they don't consume fw_cfg golden entries.
            if (!used_model && (port == 0x510 || port == 0x511))
#endif
            if (devin_idx < devins.size()) {
                io_used_golden = true;
                const ventium::DevIn& d = devins[devin_idx];
                if (d.port != port || d.size != size) {
                    if (io_desync < 8)
                        std::fprintf(stderr,
                            "tb: WIN95 IO DESYNC: core IN port=0x%x size=%u but next "
                            "golden dev_in is port=0x%x size=%u region=%s (idx=%zu)\n",
                            port, size, d.port, d.size, d.region.c_str(), devin_idx);
                    ++io_desync;
                }
                // Mask the value to the access width (e.g. the 0xFFFF.. -1 IN -> 0xFF).
                uint64_t mv = d.val;
                if (size == 1) mv &= 0xffull;
                else if (size == 2) mv &= 0xffffull;
                else mv &= 0xffffffffull;
                v = (uint32_t)mv;
            }
            io_held_rdata = v;
            io_pending_in = true;   // commit (advance) on the rising edge
        }
        // wedge diag: record this op exactly once per io_req assertion
        if (top->io_we) io_wr_hist[port & 0xffff]++; else io_rd_hist[port & 0xffff]++;
        io_ring_port[io_ring_pos] = port;
        io_ring_we[io_ring_pos]   = top->io_we ? 1 : 0;
        io_ring_val[io_ring_pos]  = top->io_we ? (uint32_t)(top->io_wdata) : io_held_rdata;
        io_ring_seq[io_ring_pos]  = io_op_seq++;
        io_ring_pos = (io_ring_pos + 1) % IO_RING;
        top->io_rdata = io_held_rdata;
        top->io_ack   = 1;
    };

    // ---- M7.1 int-0x80 proxy service (combinational, like the bus) ----------
    // The core raises syscall_active for the S_DECODE clock it proxies an
    // int-0x80. We then: (1) drive back the NEXT golden sys_call effect's
    // ret/resume-eip/gs for the core to latch on the rising edge, and (2) apply
    // that syscall's kernel memory WRITES to the bus memory exactly once. The
    // writes are applied at most once per active pulse (write_applied_idx guards
    // re-application across the multiple evals of one clock). Syscalls are
    // consumed strictly in order; we cross-check syscall_n against the producer's
    // recorded n. Inert when proxy_en==0 (syscall_active never asserts).
    long write_applied_idx = -1;   // sc_idx whose writes are already in memory
    bool flush_l1_pending = false; // #35: a proxy/emulator write bypassed the core
                                   // mem port and wrote MemModel directly, so the L1
                                   // (mode 2) may hold a stale copy. Arm a one-cycle
                                   // flush_all pulse; consumed in the run-loop clk=0
                                   // phase. Inert unless VEN_L1_AXI + --l1-axi.
#ifdef VEN_PS_PROXY
    // F4 PS-bridge model: with +VEN_PS_PROXY the core STALLS in S_SYSCALL_WAIT on an
    // int-0x80 and commits only when syscall_resp_valid arrives. The TB plays the PS:
    // it latches the proxy response service_proxy() drove at the syscall_active pulse,
    // then holds it on the ports and asserts resp_valid after an 8-clock "service"
    // latency — proving the gated stall reproduces the zero-latency proxy's trace.
    bool     pp_armed = false; int pp_delay = 0;
    uint32_t pp_eax = 0, pp_resume = 0, pp_gs = 0; bool pp_apply = false;
#endif
    uint64_t cycles = 0;           // clock count (declared here so service_proxy,
                                   // M14 emulate clock, can read it by reference)
    static const bool kSyscallProbe = (std::getenv("TB_SYSCALL_PROBE") != nullptr);
    auto service_proxy = [&]() {
        if (!proxy_mode) return;
        if (!top->syscall_active) return;
        if (kSyscallProbe) {
            std::fprintf(stderr,
                "[probe] syscall_active n=%llu nr(eax)=%u ebx=0x%x ecx=0x%x "
                "edx=0x%x esi=0x%x edi=0x%x ebp=0x%x\n",
                (unsigned long long)top->syscall_n, top->syscall_arg_eax,
                top->syscall_arg_ebx, top->syscall_arg_ecx, top->syscall_arg_edx,
                top->syscall_arg_esi, top->syscall_arg_edi, top->syscall_arg_ebp);
        }
        // M14 FREE-RUN: emulate the syscall directly (no golden). Service ONCE per
        // syscall_active pulse (keyed on the upcoming-retire n, stable across the
        // multiple evals of one clock); re-drive the cached result on re-evals so
        // the kernel effect (stdin consumed / stdout appended / clock advanced) is
        // applied exactly once. Then drive eax/gs back for the core to latch.
        if (emu) {
            if (last_emu_n != top->syscall_n) {
#ifdef VEN_L1_AXI
                // a real PS syscall service takes microseconds (thousands of core
                // clocks); any posted write in flight has long since become globally
                // visible. Drain the AXI_WPOST queue BEFORE the emulator touches guest
                // memory so its direct writes are not later clobbered by a stale post.
                for (auto& w : wpost_q) mem.write32(w.addr, w.val);
                wpost_q.clear();
#endif
                emu->set_cycles(cycles);   // drive the synthetic wall clock
                ventium::SyscallEmuResult r = emu->service(
                    top->syscall_arg_eax, top->syscall_arg_ebx, top->syscall_arg_ecx,
                    top->syscall_arg_edx, top->syscall_arg_esi, top->syscall_arg_edi,
                    top->syscall_arg_ebp);
                last_emu_n   = top->syscall_n;
                emu_eax      = r.eax;
                emu_apply_gs = r.apply_gs;
                emu_gs       = r.gs_base;
                if (r.unsupported) { emu_unsupported = true; emu_bad_nr = top->syscall_arg_eax; }
                if (r.should_exit) { emu_exit = true; emu_code = r.exit_code; }
#ifdef VEN_L1_AXI
                // The emulator wrote kernel effects into MemModel behind the L1's
                // back (set_thread_area's user_desc, read/mmap buffers, brk zero
                // pages). In mode 2 invalidate the L1 so the core's next read
                // refills coherently — mirrors ven_soc_app's per-syscall FLUSH_REQ
                // on the board. Without it a stale L1 returns the OLD user_desc
                // entry -> wrong %gs selector (0xfffb) -> NULL vsyscall call -> derail.
                flush_l1_pending = true;
#endif
            }
            top->syscall_resume_eip = 0;
            top->syscall_eax        = emu_eax;
            top->syscall_apply_gs   = emu_apply_gs ? 1 : 0;
            top->syscall_gs_base    = emu_gs;
            return;
        }
        if (sc_idx >= syscalls.size()) {
            // The core hit an int-0x80 with no golden effect left to replay: a
            // genuine over-run (the RTL reached a syscall the golden prefix never
            // recorded). Drive zeros + resume at cd80+2 so we don't hang; report.
            top->syscall_resume_eip = (uint32_t)top->syscall_n;  // placeholder
            top->syscall_eax        = 0;
            top->syscall_apply_gs   = 0;
            top->syscall_gs_base    = 0;
            return;
        }
        const ventium::SyscallEffect& e = syscalls[sc_idx];
        // Cross-check ordering: the core names the upcoming retire n; it MUST
        // match the producer's recorded n for this syscall, else the streams
        // desynced (a harness bug — report loudly, do not silently mis-replay).
        if ((uint64_t)top->syscall_n != e.n) {
            std::fprintf(stderr,
                "tb: PROXY DESYNC: core syscall_n=%llu but next golden "
                "sys_call is n=%llu (sc_idx=%zu)\n",
                (unsigned long long)top->syscall_n,
                (unsigned long long)e.n, sc_idx);
        }
        top->syscall_resume_eip = e.has_resume ? e.resume_eip : 0;
        top->syscall_eax        = e.ret;
        top->syscall_apply_gs   = e.apply_gs ? 1 : 0;
        top->syscall_gs_base    = e.gs_base;
        // Apply the kernel memory writes ONCE for this syscall.
        if (write_applied_idx != (long)sc_idx) {
            for (const auto& w : e.writes) {
                if (w.zero) {
                    // anon mmap2 / brk-grow zero region — MemModel reads unmapped
                    // as 0, but the program may have dirtied these pages earlier
                    // (mmap re-use), so explicitly zero the requested span.
                    for (uint32_t i = 0; i < w.zlen; ++i)
                        mem.write8(w.addr + i, 0);
                } else {
                    for (size_t i = 0; i < w.bytes.size(); ++i)
                        mem.write8(w.addr + (uint32_t)i, w.bytes[i]);
                }
            }
            write_applied_idx = (long)sc_idx;
#ifdef VEN_L1_AXI
            // #35: these writes hit MemModel behind the L1's back. In mode 2 the
            // L1 may cache the pre-write line; arm an external invalidation so the
            // core's next read of the syscall buffer refills coherently. No-op
            // unless there were writes AND mode 2 is active (flush_all is tied 0
            // in the RTL when !l1axi_en, so this is also harmless in modes 0/1).
            if (!e.writes.empty()) flush_l1_pending = true;
#endif
        }
    };

#ifdef VEN_FPTRAP
    // F4 FP-op PS-trap service (mirrors the A53 PS handler): when the core stalls in
    // S_FPTRAP_WAIT on FPATAN, read ST0/ST1 (floatx80), compute atan2(ST1,ST0), and
    // drive fptrap_result + fptrap_resp_valid. x86_64 `long double` IS 80-bit floatx80,
    // so the operand/result are a direct 10-byte reinterpret. FPATAN: ST0=x, ST1=y.
    auto service_fptrap = [&]() {
        if (!top->fptrap_active) { top->fptrap_resp_valid = 0; return; }
        auto rd80 = [](const auto& sig) -> long double {
            uint8_t b[16] = {0};
            uint32_t w0 = sig[0], w1 = sig[1], w2 = sig[2];
            memcpy(b+0,&w0,4); memcpy(b+4,&w1,4); b[8]=w2&0xff; b[9]=(w2>>8)&0xff;
            long double ld; memcpy(&ld,b,10); return ld;
        };
        long double x = rd80(top->fptrap_st0), y = rd80(top->fptrap_st1);
        long double r = atan2l(y, x);                       // FPATAN = atan2(ST1, ST0)
        uint8_t b[16]; memcpy(b,&r,16);
        top->fptrap_result[0] = (uint32_t)b[0]|((uint32_t)b[1]<<8)|((uint32_t)b[2]<<16)|((uint32_t)b[3]<<24);
        top->fptrap_result[1] = (uint32_t)b[4]|((uint32_t)b[5]<<8)|((uint32_t)b[6]<<16)|((uint32_t)b[7]<<24);
        top->fptrap_result[2] = (uint32_t)b[8]|((uint32_t)b[9]<<8);
        top->fptrap_resp_valid = 1;
    };
#else
    auto service_fptrap = [&]() {};
#endif

    // ---- reset: hold rst_n low for a few clocks, then release -------------
    // The TB plays the loader: it establishes the architectural init state the
    // core latches at reset (docs/m1-core-spec.md "Initial architectural
    // state"). init_eip = entry, init_esp = --init-esp. Segments/EFLAGS reset
    // value are constants inside the core.
    top->clk    = 0;
    top->rst_n  = 0;
    top->init_eip  = args.entry;
    top->init_esp  = args.init_esp;
    top->boot_mode  = args.system ? 1 : 0;  // M2S.1: system cold reset
    top->cycle_mode = args.cycle ? 1 : 0;   // M4: enable dual U/V issue
#ifdef VEN_KV260_SOC
    // P2 repro: KV260 build adds the PS->core interrupt-injection ports. calltest
    // takes no interrupts, so drive them inert (soc_en=0 keeps the divert dead).
    top->soc_en      = args.soc_en ? 1 : 0;
    top->intr        = 0;
    top->inta_vector = 0;
#endif
#ifdef VEN_DBG_CORE
    // Debug single-step/breakpoint inputs: inert by default (the hold never
    // engages), so a normal run is cycle-identical. --dbg-step arms them below.
    top->dbg_halt_req = 0; top->dbg_step = 0; top->dbg_bp_en = 0;
    top->dbg_bp_addr  = 0; top->dbg_bp_clr = 0;
#endif
    top->bus_mode   = args.bus_mode ? 1 : 0; // M5B-int: route mem via the bus subsystem
#ifdef VEN_L1_AXI
    top->l1axi_en   = args.l1_axi ? 1 : 0;   // P1-1: route mem via ventium_l1_axi (mode 2)
    if (args.l1_axi) top->bus_mode = 0;      // mode 2 supersedes the biu (kept inert)
    top->flush_all  = 0;                     // #35: external L1 invalidation (idle until armed)
    top->golden_l1  = args.golden ? 1 : 0;   // golden/L1-useless: flush ven_l1d after each access
    // clean-shutdown quiesce must be driven INERT. On the board this comes from the
    // ven_soc_axil R_CTRL.SHUTDOWN bit, which resets to 0; the TB never instantiates
    // that block, so an undriven port is X under --x-assign unique. A stray 1 puts
    // ven_axi_master into local-shutdown-ack (m_ack with rdata=0, NO AXI read) so a
    // line fill silently returns all-zeros -> opcode misdecode. Pin it to the board
    // reset value so the x-init fetch sweep matches silicon.
    top->shutdown   = 0;
#endif
    top->errata_en  = args.errata & 0x1F;    // M6/M6B: errata-enable bus (default 0)
    top->proxy_en   = proxy_mode ? 1 : 0;    // M7.1: int-0x80 proxy + %gs base
    top->cosim_en   = cosim_mode ? 1 : 0;    // M7.3b: Win95 port-I/O co-sim bus
    top->syscall_resume_eip = 0;
    top->syscall_eax        = 0;
    top->syscall_apply_gs   = 0;
    top->syscall_gs_base    = 0;
#ifdef VEN_PS_PROXY
    top->syscall_resp_valid = 0;
#endif
    top->mem_rdata = 0;
    top->mem_ack   = 0;
    top->io_rdata  = 0;
    top->io_ack    = 0;
#ifdef VEN_L1_AXI
    axi_drive();   // drive the AXI slave outputs to their reset values before eval 0
#endif
    top->eval();

    const int kResetClocks = 4;
    for (int c = 0; c < kResetClocks; ++c) {
        // clk low phase
        top->clk = 0;
        service_bus();
        service_io();
        top->eval();
        dump(half++);
        // clk high phase (rising edge)
        top->clk = 1;
#ifdef VEN_L1_AXI
        axi_capture();               // pre-edge handshake snapshot
#endif
        service_bus();
        service_io();
        top->eval();
#ifdef VEN_L1_AXI
        axi_advance();               // advance the AXI slave on the rising edge
#endif
        dump(half++);
    }
    top->rst_n = 1;   // deassert reset (synchronous; §1)

    // ---- run loop ---------------------------------------------------------
    cycles = 0;
    uint32_t idle        = 0;        // consecutive clocks with no new retire
    int      exit_code   = 0;
    uint64_t next_ckpt   = args.checkpoint_every;   // M14 next checkpoint threshold
    int      ckpt_ring   = 0;                        // 2-deep ring index
    uint64_t next_vflush = 4000000ull;               // M14 periodic video-stream flush

    uint64_t syscalls_replayed = 0;   // M7.1 diagnostics
#ifdef VEN_DBG_CORE
    // read-beat trace selftest: count dbg_rd_valid pulses + remember the first/last
    // few {addr,data} beats. This is the SAME signal ven_soc_dbg's ring captures, so
    // if it fires here (tb compiles ventium_top) the upstream master->top plumbing is
    // sound and a board count=0 means the bug is downstream (ring / wrapper / readback).
    uint64_t g_rd_beats = 0;
    uint32_t g_rd_first_addr = 0, g_rd_first_data = 0;
    uint32_t g_rd_last_addr  = 0, g_rd_last_data  = 0;
    // VEN_DBG_CORE single-step / breakpoint selftest: --dbg-step N parks from reset
    // and grants one instruction per re-park (logging the committed EIP each time, so
    // the printed sequence IS the executed instruction stream); --dbg-bp <eip> arms a
    // PC breakpoint and runs free until the core parks at it.
    uint32_t dbg_steps_done = 0;
    bool     dbg_step_inflight = false;
    if (args.dbg_step_n) top->dbg_halt_req = 1;                  // park at the first boundary
    if (args.dbg_bp)   { top->dbg_bp_en = 1; top->dbg_bp_addr = args.dbg_bp; }
#endif

    // ---- full-model sim state checkpoint: helpers + restore -------------------
#ifdef VEN_SAVABLE
    const uint64_t kSaveMagic = 0x56454e5341564531ull;   // "VENSAVE1"
    // Peripheral models are saved/restored in a FIXED order; both directions must
    // iterate the same list. A per-model present-byte tolerates a NULL/hookless model.
    auto ckpt_save_devs = [&](FILE* f){
        ven_periph_t* devs[6] = { g_pic, g_rtc, g_pit, g_i8042, g_vga, g_ide };
        for (int i = 0; i < 6; i++) {
            uint8_t present = (devs[i] && devs[i]->save) ? 1u : 0u;
            std::fwrite(&present, 1, 1, f);
            if (present) devs[i]->save(devs[i], f);
        }
    };
    auto ckpt_load_devs = [&](FILE* f){
        ven_periph_t* devs[6] = { g_pic, g_rtc, g_pit, g_i8042, g_vga, g_ide };
        for (int i = 0; i < 6; i++) {
            uint8_t present = 0; if (std::fread(&present, 1, 1, f) != 1) return;
            if (present && devs[i] && devs[i]->load) devs[i]->load(devs[i], f);
        }
    };
    auto ckpt_write = [&](const std::string& prefix){
        VerilatedSave os; os.open((prefix + ".vlt").c_str());
        os << *top; os.close();                          // entire RTL model (flops + caches)
        FILE* af = std::fopen((prefix + ".aux").c_str(), "wb");
        if (!af) { std::fprintf(stderr, "tb: SAVE: cannot open %s.aux\n", prefix.c_str()); return; }
        uint64_t u; int32_t i32;
        u = kSaveMagic;          std::fwrite(&u, 8, 1, af);
        u = cycles;              std::fwrite(&u, 8, 1, af);
        u = dos_irq0_next;       std::fwrite(&u, 8, 1, af);
        i32 = dos_pit_pending;   std::fwrite(&i32, 4, 1, af);
        std::fwrite(&idle, 4, 1, af);
        u = (uint64_t)devin_idx; std::fwrite(&u, 8, 1, af);
        u = (uint64_t)sc_idx;    std::fwrite(&u, 8, 1, af);
        u = io_in_count;         std::fwrite(&u, 8, 1, af);
        u = io_out_count;        std::fwrite(&u, 8, 1, af);
        u = syscalls_replayed;   std::fwrite(&u, 8, 1, af);
        mem.snapshot(af);                                // full sparse DDR (BIOS + DOS + heap)
        ckpt_save_devs(af);                              // PS peripheral models
        std::fclose(af);
        std::fprintf(stderr, "tb: SAVED state @ cyc=%llu retired=%llu -> %s.{vlt,aux}\n",
                     (unsigned long long)cycles, (unsigned long long)trace.retired(), prefix.c_str());
    };
    if (!args.restore_state.empty()) {
        const std::string& prefix = args.restore_state;
        FILE* af = std::fopen((prefix + ".aux").c_str(), "rb");
        if (!af) { std::fprintf(stderr, "tb: RESTORE: cannot open %s.aux\n", prefix.c_str()); return 2; }
        uint64_t u, magic = 0; int32_t i32 = 0;
        if (std::fread(&magic, 8, 1, af) != 1 || magic != kSaveMagic) {
            std::fprintf(stderr, "tb: RESTORE: bad/again magic in %s.aux\n", prefix.c_str());
            std::fclose(af); return 2;
        }
        std::fread(&u, 8, 1, af);   cycles          = u;
        std::fread(&u, 8, 1, af);   dos_irq0_next   = u;
        std::fread(&i32, 4, 1, af); dos_pit_pending = i32;
        std::fread(&idle, 4, 1, af);
        std::fread(&u, 8, 1, af);   devin_idx       = (size_t)u;
        std::fread(&u, 8, 1, af);   sc_idx          = (size_t)u;
        std::fread(&u, 8, 1, af);   io_in_count     = u;
        std::fread(&u, 8, 1, af);   io_out_count    = u;
        std::fread(&u, 8, 1, af);   syscalls_replayed = u;
        mem.restore(af);
        ckpt_load_devs(af);
        std::fclose(af);
        VerilatedRestore is; is.open((prefix + ".vlt").c_str());
        is >> *top; is.close();
        top->eval();                                     // settle combinational off restored flops
        // CADENCE-RESONANCE PROBE (task #102 follow-up): phase-shift the NEXT IRQ0
        // tick relative to the restored checkpoint by VEN_IRQ0_PHASE core-cycles
        // (signed; +advance the tick later, -fire it sooner). Sweeping this across
        // a full ~tick period maps the FAULT (#GP@cs=0x2b:0x7a0) vs CLEAN regions
        // and answers whether a robust safe timer cadence exists. Off by default
        // (phase 0 = the original checkpointed cadence => the baseline #GP).
        if (const char* ph = std::getenv("VEN_IRQ0_PHASE")) {
            long long d = strtoll(ph, nullptr, 0);
            // dos_irq0_next is a cycle count; clamp so a large negative can't wrap.
            if (d < 0 && (unsigned long long)(-d) > dos_irq0_next) dos_irq0_next = cycles;
            else dos_irq0_next = (uint64_t)((long long)dos_irq0_next + d);
            std::fprintf(stderr, "tb: IRQ0-PHASE shift %+lld -> next tick @ cyc=%llu\n",
                         d, (unsigned long long)dos_irq0_next);
        }
        std::fprintf(stderr, "tb: RESTORED state @ cyc=%llu (next IRQ0 @ %llu) -> resuming\n",
                     (unsigned long long)cycles, (unsigned long long)dos_irq0_next);
    }
#endif

#ifdef VEN_XOVER
    // task #102 Stage 3 — RTL RESTORE. Inject a (qemu-produced) arch+mem state into
    // the core's internal registers and continue. Done at startup (the model is at
    // its reset boundary, or just after a --restore-state of a saved pre-state). We
    // load arch+mem, write the architectural registers via the --public-flat-rw
    // hierarchy, FLUSH the L1 (the injected MemModel differs from any cached lines),
    // and force the FSM to S_FETCH so the very next step re-fetches from the new
    // cs:eip. The post-eip arch state then drives the continued run past the bug.
    if (!args.xover_load_prefix.empty()) {
        ventium::XoverArch xa;
        if (!ventium::xover_load(args.xover_load_prefix, xa, mem)) {
            std::fprintf(stderr, "tb: --xover-load FAILED\n"); return 2;
        }
        ventium::xover_dump_summary("LOAD/pre-inject(RTL-current)", ([&]{
            ventium::XoverArch cur; ventium::xover_extract(top, cur); return cur; }()));
        ventium::xover_inject(top, xa);   // also forces FSM -> S_FETCH for a clean refetch
        top->eval();
        ventium::xover_dump_summary("LOAD/post-inject(RTL)", xa);
        // Flush the L1 next clock so the injected memory image is the source of truth.
        flush_l1_pending = true;
        std::fprintf(stderr, "tb: XOVER-LOAD injected @ cyc=%llu -> continuing past the bug\n",
                     (unsigned long long)cycles);
    }
#endif

    while (true) {
        uint64_t before = trace.retired();
#ifdef VEN_SAVABLE
        // checkpoint write point: the loop top is a clean per-cycle boundary (flops
        // settled from the prior rising edge). On restore we re-enter here with the
        // same `cycles`, so the resumed run is bit-identical to the original.
        if (!args.save_state.empty() && args.save_at_cycle && cycles == args.save_at_cycle) {
            ckpt_write(args.save_state);
            if (args.save_exit) { std::fprintf(stderr, "tb: --save-exit: stopping after checkpoint\n"); break; }
        }
#endif
#ifdef VEN_DBG_CORE
        top->dbg_step = 0;
        if (args.dbg_step_n) {
            if (!top->dbg_halted) dbg_step_inflight = false;     // a step is executing
            else if (dbg_steps_done < args.dbg_step_n && !dbg_step_inflight) {
                std::fprintf(stderr, "tb: [dbg-step %2u] EIP=%08x CS=%04x ESP=%08x FSM=0x%02x\n",
                             dbg_steps_done, (uint32_t)top->dbg_eip, (unsigned)top->dbg_cs,
                             (uint32_t)top->dbg_esp, (unsigned)top->dbg_state);
                top->dbg_step = 1; dbg_step_inflight = true; dbg_steps_done++;
            }
        }
        if (args.dbg_bp && top->dbg_halted)
            std::fprintf(stderr, "tb: [dbg-bp] core parked: EIP=%08x bp=%08x FSM=0x%02x\n",
                         (uint32_t)top->dbg_eip, args.dbg_bp, (unsigned)top->dbg_state);
#endif

#ifdef VEN_DOS_MODELS
        // F3 IRQ pump: present the PIC's timer vector on the core's intr seam.
        if (args.dos) {
            static int irq0_off = std::getenv("VEN_IRQ0_OFF") ? 1 : 0;  // diag: suppress IRQ0 entirely
            if (irq0_off) {
                /* no timer ticks at all */
            } else if (DOS_IRQ0_PERIOD != 0) {
                // Legacy fixed-cycle pump (VEN_IRQ0_PERIOD set) — diagnostics only.
                if (cycles >= dos_irq0_next) { dos_pit_pending = 1; dos_irq0_next = cycles + DOS_IRQ0_PERIOD; }
            } else {
                // PIT-driven pump: advance the 8254's emulated clock and latch IRQ0
                // if any ch0 period elapsed. The clock is rated by RETIRED
                // INSTRUCTIONS while the core is executing (correct insn-per-tick
                // density), and by core CYCLES while the core is halted/idle (so a
                // HLT timer-wait still wakes). The PIT model then ticks IRQ0 at
                // whatever counter0 reload/mode the guest programmed.
                static uint64_t dos_prev_ret2 = 0;
                uint64_t ret_now = (uint64_t)trace.retired();
                if (ret_now == dos_prev_ret2) dos_halt_cycles++;  // this clock retired nothing
                dos_prev_ret2 = ret_now;
                uint64_t emu_ns = (uint64_t)((__uint128_t)ret_now * 1000000000ull / DOS_EMU_MIPS / 1000000ull)
                                + (uint64_t)((__uint128_t)dos_halt_cycles * 1000000000ull / DOS_EMU_HZ);
                ven_pit_set_emu_ns(g_pit, emu_ns);
                if (ven_pit_irq0_ticks(g_pit) > 0) {
                    dos_pit_pending = 1;
                    // DIAG: log the cycle interval between the first IRQ0 deliveries
                    // so the cadence (vs the old fixed 8000) is visible in the log.
                    if (std::getenv("VEN_IRQ0_DIAG")) {
                        static uint64_t last_tick_cyc = 0; static int tick_n = 0;
                        if (tick_n < 16)
                            std::fprintf(stderr, "tb: [IRQ0] tick #%d at cyc=%llu (Δ=%llu)\n",
                                tick_n, (unsigned long long)cycles,
                                (unsigned long long)(cycles - last_tick_cyc));
                        last_tick_cyc = cycles; ++tick_n;
                    }
                }
            }
#ifdef VEN_RTL_IRQ
            // RTL-IRQ: the in-PL ven_pit owns IR0 (the guest programs it via the
            // intercepted 0x40-0x43 IO) and ven_pic drives the core's intr directly,
            // so the IRQ0 cadence is cycle-deterministic (== the board). The TB feeds
            // only the device-IRQ levels (IDE/RTC are polled in this sim => all 0).
            top->soc_en     = 1;
            top->dev_irq_ps = 0;
#else
            ven_pic_set_irq(g_pic, 0, dos_pit_pending);
            uint8_t pv = ven_pic_peek_vector(g_pic);
            top->soc_en = 1;
            if (g_pic->irq(g_pic) && pv >= 0x08) { top->intr = 1; top->inta_vector = pv; }
            else                                 { top->intr = 0; }
#endif
        }
#endif

        // -- clk low phase: combinational settle + serve bus --
        top->clk = 0;
#ifdef VEN_L1_AXI
        // #35: consume a pending external-invalidation request as a one-cycle
        // flush_all pulse. service_proxy() applied a MemModel write LAST clock
        // (behind the L1's back), so the L1 may hold a stale line; held high for
        // this whole iteration, the single rising edge below invalidates the L1.
        // The 1-clock latency is ample — the core is still resuming from the
        // int-0x80 and cannot issue the buffer load for several clocks. Tied 0 in
        // the RTL when !l1axi_en, so this is inert in modes 0/1 / the 77-corpus.
#ifdef VEN_DOS_MODELS
        // soft-VGA: install the INT 10h stub + IVT[0x10] once POST is done (first
        // ATA read); its MemModel writes (stub bytes/IVT, and each serviced call's
        // regbuf write-back) need the same flush_all coherency pulse as a proxy write.
        if (soft_vga && (softvga_post_done || soft_vga_force) && !softvga_installed) {
            softvga_install(); softvga_installed = true;
        }
        if (softvga_flush_req) { flush_l1_pending = true; softvga_flush_req = false; }
#endif
        top->flush_all = flush_l1_pending ? 1 : 0;
        flush_l1_pending = false;
#endif
#ifdef VEN_PS_PROXY
        // PS-bridge: while armed, HOLD the latched response on the ports and assert
        // resp_valid once the "service latency" elapses (the core's S_SYSCALL_WAIT
        // commits on it). Inert when not armed (proxy idle / non-proxy runs).
        if (pp_armed) {
            top->syscall_eax        = pp_eax;
            top->syscall_resume_eip = pp_resume;
            top->syscall_apply_gs   = pp_apply ? 1 : 0;
            top->syscall_gs_base    = pp_gs;
            top->syscall_resp_valid = (pp_delay == 0) ? 1 : 0;
        } else {
            top->syscall_resp_valid = 0;
        }
#endif
        service_bus();
        service_proxy(); service_fptrap();      // M7.1: drive int-0x80 effects if syscall_active
                              //       (may re-arm flush_l1_pending for next clock)
        service_io();         // M7.3b: serve the port-I/O bus if io_req
        top->eval();
        // syscall_active settles combinationally this phase (state==S_DECODE);
        // re-serve so the inputs propagate, then sample whether we proxied.
        service_bus();
        service_proxy(); service_fptrap();
        service_io();
        top->eval();
        bool saw_active = proxy_mode && (bool)top->syscall_active;
        // Sample whether THIS clock the core is reading an IN off the io bus (so we
        // advance the dev_in cursor exactly once per IN, after the rising edge
        // commits the value). io_req && !io_we && io_ack identifies a serviced IN.
        bool saw_io_in = cosim_mode && (bool)top->io_req && !(bool)top->io_we
                         && (bool)top->io_ack;
        dump(half++);

        // Cycle mode (M4): stamp the clock the about-to-fire retirements belong
        // to. `cycles` is the count of completed clocks; this rising edge is the
        // (cycles+1)-th clock, so cyc is 1-based and the first retirement lands
        // at cyc>=1. Two retirements in this same eval (a paired issue) read the
        // same value and so share cyc. Cheap + harmless in func mode.
        trace.set_clock(cycles + 1);

        // -- clk high phase: rising edge; vtm_retire fires inside eval() --
        top->clk = 1;
#ifdef VEN_L1_AXI
        axi_capture();        // snapshot the PRE-edge AXI handshakes (DUT + slave state)
#endif
        service_bus();
        service_proxy(); service_fptrap();
        service_io();
        top->eval();          // <- DPI vtm_retire calls happen here; the core
                              //    latches the proxied syscall effects here too
#ifdef VEN_XOVER
        // VEN_FAULT_EA: cycle-precise #PF forensic. walk_pf is high for the cycle the
        // page-walk raises vec=14 (CR2<=walk_lin), BEFORE any handler runs — so this
        // catches the EXACT faulting linear addr + the FE_PIPE/dtlb micro-state. Prints
        // only on the rising edge of walk_pf. Env-gated/inert by default.
        if (std::getenv("VEN_FAULT_EA")) {
            static uint8_t prev_walk_pf = 0;
            static long fea_n = 0;
            ventium::XoverFaultState fs;
            uint8_t wpf = ventium::xover_read_fault_state(top, fs);
            if (wpf && !prev_walk_pf && fea_n++ < 40) {
                std::fprintf(stderr,
                    "tb: [FAULT-EA] cyc=%llu walk_lin=%08x is_w=%u step=%u errcode=%x cur_lin=%08x xlate_miss=%u\n"
                    "tb: [FAULT-EA]   fe_dtlb: hit=%u v=%u page=%05x phys=%05x dirty=%u | dtlb_lk: hit=%u phys=%08x dirty=%u\n",
                    (unsigned long long)cycles, fs.walk_lin, fs.walk_is_write, fs.walk_step,
                    fs.pf_errcode, fs.cur_lin, fs.xlate_miss,
                    fs.fe_dtlb_hit, fs.fe_dtlb_v, fs.fe_dtlb_page, fs.fe_dtlb_phys, fs.fe_dtlb_dirty,
                    fs.dtlb_lk_hit, fs.dtlb_lk_phys, fs.dtlb_lk_dirty);
                std::fflush(stderr);
            }
            prev_walk_pf = wpf;
        }
#endif
#ifdef VEN_DBG_CORE
        // read-beat trace selftest: sample dbg_rd_valid at the SAME instant ven_soc_dbg's
        // ring does (post-edge eval, after axi_capture snapped the pre-edge R handshake,
        // before axi_advance mutates the slave). Nonzero here => upstream plumbing fires.
        if (top->dbg_rd_valid) {
            if (g_rd_beats == 0) { g_rd_first_addr = top->dbg_rd_addr; g_rd_first_data = top->dbg_rd_data; }
            g_rd_last_addr = top->dbg_rd_addr; g_rd_last_data = top->dbg_rd_data;
            g_rd_beats++;
        }
#endif
#ifdef VEN_L1_AXI
        axi_advance();        // advance the AXI slave on the rising edge (pre-edge snap)
#endif
        // Re-serve in case the edge changed the request (combinational ack).
        service_bus();
        service_io();
        top->eval();
        dump(half++);

#ifdef VEN_DOS_MODELS
        // INTA boundary: the core took our injected vector this clock -> intack the
        // PIC model (ISR set / IRR clear); clear IRQ0's pending if it was the timer.
        if (args.dos && top->inta) {
            uint8_t vec = ven_pic_intack(g_pic);
            if (vec == 0x08) dos_pit_pending = 0;
            // Cadence-alignment harness, step 1: record the HW-IRQ acceptance schedule
            // (retired-insn count + vector + cs:eip) so qemu can be driven to inject
            // IRQ0 at the identical instruction points. Gated by VEN_IRQ_REC=<path>.
            if (const char* rp = std::getenv("VEN_IRQ_REC")) {
                static FILE* recf = std::fopen(rp, "w");
                if (recf) {
                    std::fprintf(recf, "%llu %u %04x %08x\n",
                                 (unsigned long long)trace.retired(), (unsigned)vec,
                                 (unsigned)top->dbg_cs, (uint32_t)top->dbg_eip);
                    std::fflush(recf);
                }
            }
        }
#endif

        // M7.1: a proxied int-0x80 has been latched by the core this clock —
        // advance to the next golden sys_call effect (strict order).
        if (saw_active && sc_idx < syscalls.size()) {
            ++sc_idx;
            ++syscalls_replayed;
        }

#ifdef VEN_PS_PROXY
        // F4 PS-bridge: on the syscall_active pulse, LATCH the response service_proxy
        // just drove (the core hasn't committed it — it parked in S_SYSCALL_WAIT); then
        // count down the service latency and disarm once resp_valid has been asserted
        // (the core committed). One transaction in flight (the next int-0x80 cannot
        // fire until this one resumes), so a single armed slot is sufficient.
        if (saw_active && !pp_armed) {
            pp_eax   = top->syscall_eax;     pp_resume = top->syscall_resume_eip;
            pp_apply = (bool)top->syscall_apply_gs; pp_gs = top->syscall_gs_base;
            pp_armed = true; pp_delay = 8;
        } else if (pp_armed) {
            if (pp_delay > 0) pp_delay--;
            else { pp_armed = false; top->syscall_resp_valid = 0; }
        }
#endif

        // M7.3b: the core latched the IN value this clock — advance the dev_in
        // cursor (strict retire order) so the next IN reads the next value.
        if (saw_io_in) {
            // SCOPED replay: advance the golden cursor ONLY when this IN actually
            // consumed a golden value (an unmodeled/fw_cfg port) — modeled-port reads
            // are served by the PS C-models and must not eat a golden entry.
            if (io_used_golden && devin_idx < devins.size()) ++devin_idx;
            ++io_in_count;
        }
        if (cosim_mode && (bool)top->io_req && (bool)top->io_we && (bool)top->io_ack)
            ++io_out_count;

        ++cycles;

        // wedge diag: optionally zero the IO histogram at a cycle threshold so the
        // dump at exit reflects ONLY the post-threshold (wedge) window. VEN_IOHIST_RESET=N
        {
            static uint64_t io_hist_reset_at =
                std::getenv("VEN_IOHIST_RESET") ? strtoull(std::getenv("VEN_IOHIST_RESET"), nullptr, 0) : 0;
            if (io_hist_reset_at && cycles == io_hist_reset_at) {
                for (auto& x : io_rd_hist) x = 0;
                for (auto& x : io_wr_hist) x = 0;
                io_op_seq = 0;
                std::fprintf(stderr, "tb: [IOHIST] reset at cyc=%llu\n",
                             (unsigned long long)cycles);
            }
        }

#ifdef VEN_XOVER
        // task #102 boundary PROBE (VEN_XOVER_PROBE=<cs hex>): log every clean
        // S_DECODE boundary at that CS in the [VEN_PROBE_LO,VEN_PROBE_HI] retire
        // window with its eip-delta (architectural eip - dbg_eip). A delta of 0 or
        // a small insn length = a TRUE instruction boundary (safe snapshot point);
        // a large delta = a mid-interrupt-vectoring micro-state (DO NOT snapshot).
        // Used to pick the pre-int-0x31 snapshot target. OFF unless armed.
        if (const char* pc = std::getenv("VEN_XOVER_PROBE")) {
            static unsigned probe_cs = (unsigned)strtoul(pc, nullptr, 0);
            static uint64_t plo = std::getenv("VEN_PROBE_LO") ? strtoull(std::getenv("VEN_PROBE_LO"),0,0) : 0;
            static uint64_t phi = std::getenv("VEN_PROBE_HI") ? strtoull(std::getenv("VEN_PROBE_HI"),0,0) : ~0ull;
            static long probe_n = 0;
            if ((unsigned)top->dbg_state == 2 && (unsigned)top->dbg_cs == probe_cs &&
                trace.retired() >= plo && trace.retired() <= phi && probe_n++ < 400) {
                ventium::XoverArch px; ventium::xover_extract(top, px);
                std::fprintf(stderr, "tb: [XPROBE] ret=%llu cyc=%llu cs=%04x dbg_eip=%08x arch_eip=%08x delta=%d cr0=%08x\n",
                    (unsigned long long)trace.retired(), (unsigned long long)cycles,
                    (unsigned)top->dbg_cs, (uint32_t)top->dbg_eip, px.eip,
                    (int)(px.eip - (uint32_t)top->dbg_eip), px.cr0);
                std::fflush(stderr);
            }
        }
        // task #102 Stage 1 — RTL EXTRACT. At/after --xover-at-retire, the FIRST
        // time the FSM sits at a clean instruction boundary (S_DECODE=2, no in-flight
        // uop), serialize the full arch state + MemModel to <prefix>.arch/.mem. The
        // post-edge here is a settled boundary; gating on dbg_state==S_DECODE ensures
        // the pipeline is empty (this in-order core retires before re-entering DECODE).
        bool xsave_gate = !args.xover_save_prefix.empty() && args.xover_at_retire &&
            trace.retired() >= args.xover_at_retire &&
            (unsigned)top->dbg_state == 2 /*S_DECODE*/ &&
            (args.xover_at_cs < 0 || (unsigned)top->dbg_cs == (unsigned)args.xover_at_cs);
        // --xover-at-eip: also require the ARCHITECTURAL next-fetch eip == target.
        // Lets us pin the snapshot to a specific instruction boundary (e.g. the
        // int 0x31 at cs=0x87:0x24c) rather than the first boundary at/after a
        // retire count. Requires a peek-extract to read the architectural eip.
        if (xsave_gate && args.xover_at_eip >= 0) {
            ventium::XoverArch peek; ventium::xover_extract(top, peek);
            if (peek.eip != (uint32_t)args.xover_at_eip) xsave_gate = false;
        }
        if (xsave_gate) {
            ventium::XoverArch xa;
            ventium::xover_extract(top, xa);
            // Cross-check the extracted arch state vs the independent dbg ports
            // (the Stage-1 verification gate). NOTE: dbg_eip = core_retire_pc = the
            // COMMITTED pc of the LAST RETIRED instruction, whereas the architectural
            // `eip` register at the S_DECODE boundary already points at the NEXT
            // instruction to fetch. So extract.eip == dbg_eip + (last insn length):
            // they are SUPPOSED to differ by the instruction advance. cs/eflags/esp
            // are post-commit state and MUST match exactly.
            uint32_t d_eip = (uint32_t)top->dbg_eip, d_esp = (uint32_t)top->dbg_esp;
            uint32_t d_efl = (uint32_t)top->dbg_eflags; unsigned d_cs = (unsigned)top->dbg_cs;
            bool ok = (xa.seg_sel[0] == d_cs) && (xa.eflags == d_efl) &&
                      (xa.gpr[4] == d_esp) && (xa.eip >= d_eip) && (xa.eip - d_eip <= 15);
            std::fprintf(stderr,
                "tb: XOVER-SAVE @ retire=%llu cyc=%llu  dbg{cs=%04x eip=%08x(committed) efl=%08x esp=%08x} "
                "extract{cs=%04x eip=%08x(next) efl=%08x esp=%08x}  CROSSCHECK=%s (eip delta=+%d = last-insn len)\n",
                (unsigned long long)trace.retired(), (unsigned long long)cycles,
                d_cs, d_eip, d_efl, d_esp,
                xa.seg_sel[0], xa.eip, xa.eflags, xa.gpr[4],
                ok ? "MATCH" : "MISMATCH", (int)(xa.eip - d_eip));
            ventium::xover_dump_summary("SAVE", xa);
            ventium::xover_save(args.xover_save_prefix, xa, mem);
            args.xover_at_retire = 0;  // one-shot
            if (args.xover_save_exit) {
                std::fprintf(stderr, "tb: --xover-save-exit: stopping after crossover save\n");
                break;
            }
        }
#endif

        // M7.3b: the co-sim hit the isa-debug-exit `out 0xf4` — qemu-system would
        // exit here; stop the run cleanly (matches the producer's termination).
        if (io_exit) {
            std::fprintf(stderr,
                "tb: stop: WIN95 co-sim isa-debug-exit (out 0xf4) after %llu "
                "retired in %llu clocks\n",
                (unsigned long long)trace.retired(), (unsigned long long)cycles);
            break;
        }

        // M14 free-run: the guest called exit_group/exit — stop exactly as the
        // kernel would end the process (the captured stdout is already complete:
        // musl's exit() flushed stdio before issuing the raw exit_group).
        if (emu_exit) {
            std::fprintf(stderr,
                "tb: stop: FREE-RUN guest exit_group(%d) after %llu retired in "
                "%llu clocks\n", emu_code, (unsigned long long)trace.retired(),
                (unsigned long long)cycles);
            break;
        }
        if (emu_unsupported) {
            std::fprintf(stderr,
                "tb: stop: FREE-RUN UNIMPLEMENTED syscall nr=%u after %llu retired "
                "(LOUD stop — never a silent wrong answer; add it to syscall_emu)\n",
                emu_bad_nr, (unsigned long long)trace.retired());
            break;
        }

        // M14 periodic complete-state checkpoint: every K retired insns, dump the
        // latest arch state + full MemModel to a 2-deep ring (newest before a
        // divergence = the restart/inspect point). Written at a retirement
        // boundary (this in-order core's pipeline is empty between retirements).
        if (args.checkpoint_every && trace.retired() >= next_ckpt) {
            char path[1024];
            std::snprintf(path, sizeof(path), "%s/ckpt.%d.bin",
                          args.checkpoint_dir.c_str(), ckpt_ring);
            if (FILE* cf = std::fopen(path, "wb")) {
                std::fwrite(&ventium::g_last_arch, sizeof(ventium::g_last_arch), 1, cf);
                mem.snapshot(cf);
                std::fclose(cf);
                std::fprintf(stderr, "tb: checkpoint @ %llu retired -> %s\n",
                             (unsigned long long)trace.retired(), path);
            }
            ckpt_ring ^= 1;
            next_ckpt += args.checkpoint_every;
        }

        // M14 periodic video flush: write the captured P5Q1 stream to --video-out
        // every ~4M retired insns so a long render run can be converted to PNG
        // MID-RUN (the first frame is reachable without waiting for exit).
        if (emu && !args.video_out.empty() && trace.retired() >= next_vflush) {
            next_vflush += 4000000ull;
            if (!emu->video().empty()) {
                if (FILE* vf = std::fopen(args.video_out.c_str(), "wb")) {
                    std::fwrite(emu->video().data(), 1, emu->video().size(), vf);
                    std::fclose(vf);
                }
            }
        }

#ifdef VEN_DBG_CORE
        // --dos long-run progress: periodically name where the boot is (BIOS POST
        // lives at CS=0x08/EIP~0xFxxxx; the FreeDOS kernel at phys 0x600+ -> CS=0/EIP
        // small). Lets a multi-100M-cycle run be watched without a per-insn trace.
        if (cycles && (cycles % 50000000ull) == 0) {
            static uint64_t last_prog = 0;
            if (cycles != last_prog) {
                last_prog = cycles;
                std::fprintf(stderr, "tb: progress cyc=%llu ret=%llu EIP=%08x CS=%04x st=%u "
                    "EAX=%08x ECX=%08x EDX=%08x ESI=%08x EDI=%08x\n",
                    (unsigned long long)cycles, (unsigned long long)trace.retired(),
                    (uint32_t)top->dbg_eip, (unsigned)top->dbg_cs, (unsigned)top->dbg_state,
                    ventium::g_last_arch.gpr[0], ventium::g_last_arch.gpr[1],
                    ventium::g_last_arch.gpr[2], ventium::g_last_arch.gpr[6],
                    ventium::g_last_arch.gpr[7]);
                std::fflush(stderr);
            }
        }
        // F4A: windowed per-commit trace of the VBR KERNEL.SYS load loop (cs=0x1FE0,
        // ~0x7dxx) to root-cause the non-terminating rep-movsb/dec-di spin. It consumes
        // the DOS peripheral-model arm flag and the KV260-only interrupt port, so do
        // not make a generic VEN_DBG_CORE build depend on those unrelated interfaces.
#if defined(VEN_DOS_MODELS) && defined(VEN_KV260_SOC)
        {
            static uint32_t f4a_last = 0xffffffffu; static int f4a_n = 0;
            static uint64_t f4a_lo = std::getenv("VEN_F4A_CYC_LO") ? strtoull(std::getenv("VEN_F4A_CYC_LO"),0,0) : 0ull;
            static uint64_t f4a_hi = std::getenv("VEN_F4A_CYC_HI") ? strtoull(std::getenv("VEN_F4A_CYC_HI"),0,0) : ~0ull;
            static int f4a_force = std::getenv("VEN_F4A_FORCE") ? 1 : 0;  // arm by cycle-window alone
            uint32_t e = (uint32_t)top->dbg_eip;
            uint32_t key = ((uint32_t)top->dbg_cs << 16) ^ e;
            if ((g_ven_f4a_arm || f4a_force) && cycles >= f4a_lo && cycles <= f4a_hi && f4a_n < 400000 && key != f4a_last) {
                f4a_last = key; f4a_n++;
                std::fprintf(stderr, "f4a cs=%04x eip=%04x fl=%08x IF=%d intr=%d ax=%08x bx=%08x cx=%08x dx=%08x si=%08x di=%08x bp=%08x sp=%08x\n",
                    (unsigned)top->dbg_cs, e,
                    ventium::g_last_arch.eflags, (int)((ventium::g_last_arch.eflags>>9)&1), (int)top->intr,
                    ventium::g_last_arch.gpr[0], ventium::g_last_arch.gpr[3],
                    ventium::g_last_arch.gpr[1], ventium::g_last_arch.gpr[2],
                    ventium::g_last_arch.gpr[6], ventium::g_last_arch.gpr[7],
                    ventium::g_last_arch.gpr[5], ventium::g_last_arch.gpr[4]);
            }
        }
#endif
        // Log every real-mode INT (vector + AX at entry). init_call_intr patches
        // `int 0`->`int N` via SMC; if Ventium's icache serves a stale opcode in the
        // kernel (INIT_TEXT) context, the WRONG vector fires -> init_readdasd's AH=15h
        // DASD probe never runs as int 0x13 -> DF_FIXED dropped. S_RMINT_RD=state 32.
        {
            static unsigned prev_rmst = 0;
            static long int_log_count = 0;
            static long idle28_count = 0;
            unsigned dsn = (unsigned)top->dbg_state;
            if (dsn == 32 && prev_rmst != 32) {
                uint32_t ax = ventium::g_last_arch.gpr[0];
                unsigned vec = (unsigned)top->dbg_int_vec;
                if (int_log_count++ < 4000) {   // cap the [INT] spam (idle loop floods it)
                    std::fprintf(stderr, "tb: [INT] vec=0x%02x CS:EIP=%04x:%08x AX=%04x (cyc=%llu)\n",
                        vec, (unsigned)top->dbg_cs, (uint32_t)top->dbg_eip,
                        (unsigned)(ax & 0xffff), (unsigned long long)cycles);
                    std::fflush(stderr);
                }
                // F4A: INT 10h teletype (AH=0Eh) — capture AL UNCAPPED. The VGA BIOS's
                // writes to video RAM don't land in the sim, but the console output IS
                // visible via this teletype stream (FreeDOS/Quake printf -> INT10h/0Eh).
                if (vec == 0x10 && ((ax >> 8) & 0xff) == 0x0e)
                    std::fprintf(stderr, "tbCON %02x\n", (unsigned)(ax & 0xff));
                // F4A: INT 0x28 = COMMAND.COM DOS-idle => Quake has exited to the C:\
                // prompt. After enough idle ticks, dump the screen+memory (clean-exit
                // path below) so the failure/error banner is captured, then stop.
                if (vec == 0x28 && ++idle28_count >= 300) {
                    std::fprintf(stderr, "tb: DOS-IDLE (300x INT 0x28) @cycle %llu retired %llu -- Quake exited to DOS; dumping+stopping\n",
                        (unsigned long long)cycles, (unsigned long long)trace.retired());
                    break;
                }
            }
            prev_rmst = dsn;
        }
        // task #102: PM gate-delivery trace. The [INT] logger above only catches
        // REAL-mode S_RMINT_RD; PROTECTED-mode interrupt/exception delivery walks
        // S_INT_GATE (state 36) instead, so a #DE/#GP/#UD/IRQ reaching go32's PM
        // handler is otherwise invisible. Log the vector + faulting CS:EIP at the
        // S_INT_GATE rising entry. Env-gated (VEN_PMGATE_LOG) so it is OFF by
        // default and adds zero output to existing runs.
        if (std::getenv("VEN_PMGATE_LOG")) {
            static unsigned prev_igst = 0;
            static long pmgate_count = 0;
            unsigned igst = (unsigned)top->dbg_state;
            if (igst == 36 && prev_igst != 36 && pmgate_count++ < 4000) {
                std::fprintf(stderr, "tb: [PMGATE] vec=0x%02x cs=%04x eip=%08x cr0=%08x (cyc=%llu)\n",
                    (unsigned)top->dbg_int_vec, (unsigned)top->dbg_cs,
                    (uint32_t)top->dbg_eip, (uint32_t)top->dbg_cr0,
                    (unsigned long long)cycles);
                std::fflush(stderr);
            }
            prev_igst = igst;
        }
        // F4A: capture fault deliveries (esp. the #DE vec 0 that aborts Quake). When
        // dbg_fault_pc changes the core just raised a fault; dbg_eip/ibuf still point
        // at the faulting instruction, dbg_int_vec = the vector. Logs cs:eip:ibuf:vec.
        {
            static uint32_t prev_fpc = 0xFFFFFFFFu;
            uint32_t fpc = (uint32_t)top->dbg_fault_pc;
            if (fpc != prev_fpc) {
                std::fprintf(stderr, "tb: [FAULT] vec=0x%02x cs=%04x eip=%08x fault_pc=%08x ibuf=%016llx (cyc=%llu)\n",
                    (unsigned)top->dbg_int_vec, (unsigned)top->dbg_cs, (uint32_t)top->dbg_eip,
                    fpc, (unsigned long long)top->dbg_ibuf, (unsigned long long)cycles);
                std::fflush(stderr);
#ifdef VEN_XOVER
                // VEN_FAULT_CR2: dump CR2 (the #PF linear address) at each new fault so a
                // crossover #PF whose insn never retires can still be localized. Env-gated.
                if (std::getenv("VEN_FAULT_CR2"))
                    std::fprintf(stderr, "tb: [FAULT-CR2] cr2=%08x\n", ventium::xover_read_cr2(top));
#endif
                prev_fpc = fpc;
                // CADENCE-RESONANCE CLASSIFIER (VEN_RESON_CLASS): the residual #GP is
                // vec 0x0d at cs=0x2b:0x7a0 (mov es,0x2593 in the wrongly-resumed
                // reflector ctx). Detect it and stop LOUD+early so a phase sweep can
                // bin this run as FAULT in one line. Off by default.
                if (std::getenv("VEN_RESON_CLASS") &&
                    (unsigned)top->dbg_int_vec == 0x0d &&
                    (unsigned)top->dbg_cs == 0x2b &&
                    (uint32_t)top->dbg_eip == 0x7a0) {
                    std::fprintf(stderr, "tb: [RESON] FAULT (#GP cs=0x2b:0x7a0) @ cyc=%llu retired=%llu\n",
                        (unsigned long long)cycles, (unsigned long long)trace.retired());
                    std::fflush(stderr);
                    break;
                }
            }
        }
        // CADENCE-RESONANCE CLEAN decision: if we run past the #GP decision window
        // (a retire count comfortably beyond where the fault fires) without the
        // cs=0x2b:0x7a0 #GP, this phase is CLEAN. VEN_RESON_CLEAN_AT = the retire
        // count to declare CLEAN at (default: ~1200 past the checkpoint's bug point).
        if (std::getenv("VEN_RESON_CLASS")) {
            static uint64_t clean_at = std::getenv("VEN_RESON_CLEAN_AT")
                ? strtoull(std::getenv("VEN_RESON_CLEAN_AT"),0,0) : 3000ull;
            if (trace.retired() >= clean_at) {
                std::fprintf(stderr, "tb: [RESON] CLEAN (no #GP through retire %llu) @ cyc=%llu\n",
                    (unsigned long long)trace.retired(), (unsigned long long)cycles);
                std::fflush(stderr);
                break;
            }
        }
        // Patchable opcode-capture hook: arm via VEN_HOOK (e.g. 0x3 = enable + DIV/IDIV
        // class); print {eip, EDX:EAX, divisor} on each capture (seq counter changes).
        {
            static int hk_init = 0; static uint16_t hk_cfg = 0;
            if (!hk_init) { const char* e = std::getenv("VEN_HOOK");
                hk_cfg = e ? (uint16_t)strtoul(e, 0, 0) : 0; hk_init = 1; }
            top->dbg_hook_cfg = hk_cfg;
            static int seq_init = 0; static uint8_t prev_seq = 0;
            uint8_t s = (uint8_t)top->dbg_hook_seq;
            if (!seq_init) { prev_seq = s; seq_init = 1; }
            else if (s != prev_seq) { prev_seq = s;
                uint32_t m = (uint32_t)top->dbg_hook_meta;
                std::fprintf(stderr, "tb: [HOOK] eip=%08x EDX:EAX=%016llx divisor=%08x (op=%u w=%u cs=%04x)\n",
                    (uint32_t)top->dbg_hook_eip, (unsigned long long)top->dbg_hook_opa,
                    (uint32_t)top->dbg_hook_opb, (m>>24)&0xff, m&0x7, (m>>8)&0xffff);
                std::fflush(stderr);
            }
        }
#endif
        // quiescence / limit detection
        if (trace.retired() > before) {
            idle = 0;
        } else {
            ++idle;
        }

        // F4A: early-exit the moment DOS Quake renders a frame (substantial nonzero
        // VGA mode-13h px @0xA0000). Checked ~every 2M cycles (cheap vs the run).
        if ((cycles & 0x1FFFFFull) == 0) {
            long nz = 0;
            for (int i = 0; i < 64000; ++i) if (mem.read8(0xA0000u + i)) ++nz;
            // VEN_FRAME_SEQ: periodic 0xA0000 frame dump (sim_vga13_seqNNN.bin) so an
            // ANIMATING live game loop can be captured as a sequence (motion across
            // frames). Dumps when the frame content CHANGES (a cheap 64-byte stride
            // hash) so identical frames aren't re-dumped. Env-gated; inert by default.
            if (std::getenv("VEN_FRAME_SEQ") && nz > 1000) {
                static uint64_t prev_hash = 0; static int seq_n = 0;
                uint64_t h = 1469598103934665603ull;
                for (int i = 0; i < 64000; i += 61) { h ^= mem.read8(0xA0000u+i); h *= 1099511628211ull; }
                if (h != prev_hash) {
                    prev_hash = h;
                    char fn[128]; std::snprintf(fn, sizeof(fn), "/tmp/sim_vga13_seq%03d.bin", seq_n);
                    if (FILE* sf = std::fopen(fn, "wb")) {
                        for (int i = 0; i < 64000; ++i) { uint8_t p = mem.read8(0xA0000u+i); std::fwrite(&p,1,1,sf); }
                        std::fclose(sf);
                        // also dump the DAC palette alongside the first frame
                        std::fprintf(stderr, "tb: [FRAME-SEQ] #%d cyc=%llu retired=%llu nz=%ld -> %s\n",
                            seq_n, (unsigned long long)cycles, (unsigned long long)trace.retired(), nz, fn);
                        std::fflush(stderr);
                    }
                    seq_n++;
                }
            }
            if (nz > 1000 && !std::getenv("VEN_NO_FRAME_EXIT")) {
                std::fprintf(stderr, "tb: FRAME! %ld nonzero VGA px @cycle %llu retired %llu\n",
                             nz, (unsigned long long)cycles,
                             (unsigned long long)trace.retired());
                break;
            }
            if ((cycles & 0x3FFFFFFull) == 0) { // ~every 64M cycles: progress heartbeat
                std::fprintf(stderr, "tb: progress @cycle %llu retired %llu vga_nz %ld\n",
                             (unsigned long long)cycles,
                             (unsigned long long)trace.retired(), nz);
                // F4A: also snapshot the non-blank VGA TEXT lines (0xB8000) so Quake's
                // DOS console messages (init steps + any error banner) are visible live.
                for (int row = 0; row < 25; ++row) {
                    char line[81]; int any = 0;
                    for (int col = 0; col < 80; ++col) {
                        uint8_t ch = mem.read8(0xB8000u + (uint32_t)(row*80+col)*2u);
                        line[col] = (ch >= 32 && ch < 127) ? (char)ch : ' ';
                        if (ch >= 33 && ch < 127) any = 1;
                    }
                    line[80] = 0;
                    int e = 80; while (e > 0 && line[e-1] == ' ') line[--e] = 0;
                    if (any) std::fprintf(stderr, "tb: TXT| %s\n", line);
                }
                std::fflush(stderr);
            }
        }
        if (trace.retired() >= args.max_insn) {
            std::fprintf(stderr, "tb: stop: reached --max-insn (%llu)\n",
                         (unsigned long long)args.max_insn);
            break;
        }
        if (cycles >= args.max_cycles) {
            std::fprintf(stderr, "tb: stop: reached --max-cycles (%llu)\n",
                         (unsigned long long)args.max_cycles);
            break;
        }
        // M6 Erratum 81 (F00F): the core latched cpu_hung -> it entered the
        // documented LOCK-CMPXCHG8B-reg HANG. Report it distinctly and stop (the
        // core will never retire again). This makes the hang observable to the
        // self-check (which greps this line) without waiting out the full quiesce.
        if (top->cpu_hung) {
            std::fprintf(stderr,
                "tb: stop: CPU HUNG (cpu_hung asserted: F00F Erratum 81, OR a #34 "
                "bus_err fatal AXI fault -> S_HALT) after %llu retired in %llu clocks\n",
                (unsigned long long)trace.retired(),
                (unsigned long long)cycles);
            break;
        }
        if (idle >= args.quiesce) {
            std::fprintf(stderr,
                "tb: stop: quiescent for %u clocks (core idle)\n", idle);
            break;
        }
        if (Verilated::gotFinish()) {
            std::fprintf(stderr, "tb: stop: $finish from RTL\n");
            break;
        }
    }

#ifdef VEN_DBG_CORE
    // VEN_DBG_CORE: print the core debug bundle at the stop point. On a freeze this
    // names WHERE + WHY the core stopped (FSM micro-state, mode, last fault) and the
    // committed state of the last retired instruction — what previously took a
    // faithful-sim build to recover. The vtrace is the per-PC trail alongside it.
    {
        static const char* SN[] = {
            "RESET","FETCH","DECODE","LOAD","LOAD2","EXEC","STORE","USEQ","HALT","FLOAD",
            "FEXEC","FSTORE","FP_BUSY","DIV_BUSY","BCD_BUSY","FBLD_BUSY","TRSC_BUSY",
            "FEXEC_EX","SYSCALL_WAIT","FENV_ST","FENV_LD","IO","INS","PF","PIPE",
            "F00F_HANG","LGDT","SEGLD","LJMP","LCALL","RETF","SGDT","RMINT_RD",
            "RMINT_PUSH","RMIRET","HLTWAIT","WALK","INT_GATE","INT_CS","INT_PUSH","IRET",
            "INT_CS_RET","LTR","INT_TSS","INT_SS","IRET_SS","TSW_SAVE","TSW_READ",
            "TSW_SEG","TSW_BUSY","SMI_SAVE","RSM","DB_EXTRA" };
        unsigned s = (unsigned)top->dbg_state;
        const char* sn = (s < sizeof(SN)/sizeof(SN[0])) ? SN[s] : "?";
        unsigned fcw = (unsigned)top->dbg_fctrl;
        unsigned pc  = (fcw >> 8) & 3;
        const char* pcs = (pc==3)?"64/ext":(pc==2)?"53/dbl":(pc==0)?"24/sgl":"rsvd";
        std::fprintf(stderr,
            "tb: [VEN_DBG] EIP=%08x CS=%04x ESP=%08x EFLAGS=%08x\n"
            "tb: [VEN_DBG] FSM=S_%s(0x%02x) mode=%s%s vec=0x%02x fault_pc=%08x CR0=%08x halted=%d\n"
            "tb: [VEN_DBG] FCTRL=%04x PC=%u(%s) RC=%u  q_fxop=%u\n"
            "tb: [VEN_DBG] IBUF=%016llx (8 bytes at committed EIP, little-endian)\n"
            "tb: [VEN_DBG] GDTR=%08x CS.D=%d\n",
            (uint32_t)top->dbg_eip, (unsigned)top->dbg_cs, (uint32_t)top->dbg_esp,
            (uint32_t)top->dbg_eflags, sn, s,
            (top->dbg_cr0 & 1u) ? "PE" : "real", (top->dbg_cr0 & 0x80000000u) ? "+PG" : "",
            (unsigned)top->dbg_int_vec, (uint32_t)top->dbg_fault_pc, (uint32_t)top->dbg_cr0,
            (int)top->dbg_halted,
            fcw, pc, pcs, (fcw>>10)&3, (unsigned)top->dbg_fxop,
            (unsigned long long)top->dbg_ibuf,
            (uint32_t)(top->dbg_seg & 0xffffffffu), (int)((top->dbg_seg >> 32) & 1u));
        {   // divide-#DE tap: faulting dividend/divisor/eip/width + count
            uint64_t num = (uint64_t)top->dbg_de_num, info = (uint64_t)top->dbg_de_info;
            unsigned decnt = (unsigned)(info & 0x1fffu);
            std::fprintf(stderr,
                "tb: [VEN_DBG] DIVDE cnt=%u  last: w=%u eip=%04x den=%08x num=%08x:%08x (EDX:EAX)\n",
                decnt, (unsigned)((info >> 13) & 7u), (unsigned)((info >> 16) & 0xffffu),
                (uint32_t)(info >> 32), (uint32_t)(num >> 32), (uint32_t)(num & 0xffffffffu));
        }
        std::fprintf(stderr,
            "tb: [VEN_DBG] rd_beats=%llu  first={addr=%08x data=%08x} last={addr=%08x data=%08x}\n",
            (unsigned long long)g_rd_beats, g_rd_first_addr, g_rd_first_data,
            g_rd_last_addr, g_rd_last_data);
    }
#endif

#ifdef VEN_DOS_MODELS
    // --dos: dump low physical memory (IVT/BDA/loaded FreeDOS kernel @0x600+/_Dyn
    // ~0x26A4/the C: ddt) so the runtime ddt_descflags (DF_FIXED bit) can be checked
    // offline — the board can't read this region safely (uninit-ECC SIGBUS risk).
    if (args.dos) {
        if (FILE* lf = std::fopen("/tmp/sim_lowmem.bin", "wb")) {
            for (uint32_t i = 0; i < 0x100000u; i++) std::fputc(mem.read8(i), lf);  // full low 1MB (incl VGA BIOS @0xC0000)
            std::fclose(lf);
            std::fprintf(stderr, "tb: dumped lowmem 0..0x40000 -> /tmp/sim_lowmem.bin\n");
        }
        // F4A: VGA mode-13h framebuffer @0xA0000 (320x200x8 = 64000 B). DOS Quake
        // blits its frame here; dump it so a render can be checked offline + a
        // nonzero-pixel count printed (blank vs rendered is obvious).
        if (FILE* vf = std::fopen("/tmp/sim_vga13.bin", "wb")) {
            long nz = 0;
            for (uint32_t i = 0; i < 64000u; i++) {
                uint8_t p = mem.read8(0xA0000u + i);
                if (p) nz++;
                std::fputc(p, vf);
            }
            std::fclose(vf);
            std::fprintf(stderr, "tb: dumped VGA13 @0xA0000 (64000 B, %ld nonzero px) -> /tmp/sim_vga13.bin\n", nz);
        }
#ifdef VEN_DOS_MODELS
        // task #99: also dump the live 256-entry DAC palette (6-bit R/G/B, as the
        // guest set it via the soft-VGA AH=10 calls or the 0x3C8/0x3C9 ports) so the
        // mode-13h framebuffer can be colorized into a PPM offline. Inert if g_vga null.
        if (g_vga) {
            const uint8_t* pal = ven_vgaregs_dac(g_vga);
            if (FILE* pf = std::fopen("/tmp/sim_vga13.pal", "wb")) {
                std::fwrite(pal, 1, 768, pf);
                std::fclose(pf);
                std::fprintf(stderr, "tb: dumped VGA13 DAC palette (768 B) -> /tmp/sim_vga13.pal\n");
            }
        }
#endif
        // F4A: VGA TEXT @0xB8000 (80x25, char+attr). FreeDOS CON writes its banner /
        // prompt / errors directly here; the sim has no soft-VGA INT10h so this is
        // the only way to SEE the boot screen. Dump non-blank rows as readable text.
        {
            // F4A diag: BDA video state — mode (0x449), active page (0x462), CRTC
            // start (0x44E), cursor (0x450). Distinguishes color (mode 3 @0xB8000)
            // vs mono (mode 7 @0xB0000) and shows where the active page maps.
            std::fprintf(stderr, "tb: BDA mode=0x%02x page=0x%02x crtc_start=0x%04x cur=0x%04x\n",
                (unsigned)mem.read8(0x449), (unsigned)mem.read8(0x462),
                (unsigned)(mem.read8(0x44E) | (mem.read8(0x44F)<<8)),
                (unsigned)(mem.read8(0x450) | (mem.read8(0x451)<<8)));
            for (int row = 0; row < 25; row++) {   // also the MONO buffer @0xB0000 (mode 7)
                char ml[81]; int many = 0;
                for (int col = 0; col < 80; col++) {
                    uint8_t ch = mem.read8(0xB0000u + (uint32_t)(row*80+col)*2u);
                    ml[col] = (ch >= 0x21 && ch < 0x7f) ? (char)ch : ' ';
                    if (ch >= 0x21 && ch < 0x7f) many = 1;
                }
                ml[80]=0; int me=80; while(me>0 && ml[me-1]==' ') ml[--me]=0;
                if (many) std::fprintf(stderr, "tb: B0000| %s\n", ml);
            }
            std::fprintf(stderr, "tb: === VGA text @0xB8000 (80x25) ===\n");
            for (int row = 0; row < 25; row++) {
                char line[81]; int any = 0;
                for (int col = 0; col < 80; col++) {
                    uint8_t ch = mem.read8(0xB8000u + (uint32_t)(row*80 + col)*2u);
                    line[col] = (ch >= 0x20 && ch < 0x7f) ? (char)ch : ' ';
                    if (line[col] != ' ') any = 1;
                }
                int e = 80; line[80] = 0; while (e > 0 && line[e-1] == ' ') line[--e] = 0;
                if (any) std::fprintf(stderr, "tb: %2d|%s\n", row, line);
            }
        }
        // wedge diag: top IO ports (a dominant port => poll loop / peripheral gap;
        // all-zero after VEN_IOHIST_RESET => the wedge does NO IO == CPU/logic loop)
        std::fprintf(stderr, "tb: === IO histogram (top ports, window since reset) ===\n");
        for (int dir = 0; dir < 2; dir++) {
            std::vector<uint64_t>& h = dir ? io_wr_hist : io_rd_hist;
            for (int k = 0; k < 12; k++) {
                uint64_t best = 0; int bp = -1;
                for (int p = 0; p < 65536; p++) if (h[p] > best) { best = h[p]; bp = p; }
                if (bp < 0 || best == 0) break;
                std::fprintf(stderr, "tb: IO %s port=0x%04x count=%llu\n",
                             dir ? "OUT" : "IN ", bp, (unsigned long long)best);
                h[bp] = 0;
            }
        }
        std::fprintf(stderr, "tb: === last IO ops (seq port dir val) ===\n");
        for (int i = 0; i < IO_RING; i++) {
            int idx = (io_ring_pos + i) % IO_RING;
            if (io_ring_seq[idx] == 0 && io_ring_val[idx] == 0 && io_ring_port[idx] == 0) continue;
            std::fprintf(stderr, "tb: io seq=%llu port=0x%04x %s val=0x%x\n",
                (unsigned long long)io_ring_seq[idx], io_ring_port[idx],
                io_ring_we[idx] ? "OUT" : "IN ", io_ring_val[idx]);
        }
    }
#endif

    // ---- F4: dump the Quake framebuffer (vid.buffer @0x087a29e0, 320x200 8-bit
    // indexed) so a sim render can be checked offline (combine with gfx/palette.lmp
    // -> PNG). The MemModel is x86-phys-indexed, so read the guest vaddr directly.
    if (!args.dump_fb.empty()) {
        FILE* ff = std::fopen(args.dump_fb.c_str(), "wb");
        if (ff) {
            for (uint32_t i = 0; i < 64000u; i++)
                std::fputc(mem.read8(0x087a29e0u + i), ff);
            std::fclose(ff);
            std::fprintf(stderr, "tb: dumped framebuffer (64000B @0x087a29e0) -> %s\n",
                         args.dump_fb.c_str());
        }
    }

    // ---- M2S.5: dump SMM-relevant physical memory for the structural check --
    // The RTL analogue of psmm-selfcheck.py's QMP readback: the handler sentinels
    // and the P5 save-state map at the DOCUMENTED offsets (SMBASE+0x8000+offset).
    if (!args.smm_dump.empty()) {
        const uint32_t sm = args.smbase + 0x8000u;   // base of the save-map window
        FILE* df = std::fopen(args.smm_dump.c_str(), "w");
        if (df) {
            std::fprintf(df,
                "{\n"
                "  \"smbase\": \"0x%08x\",\n"
                "  \"sent_smm_ran\":  \"0x%08x\",\n"   // [0x2000] handler sentinel
                "  \"sent_resumed\":  \"0x%08x\",\n"   // [0x2004] 'RET!' resume
                "  \"sent_intact\":   \"0x%08x\",\n"   // [0x2008] EBX witness
                "  \"sent_dr7\":      \"0x%08x\",\n"   // [0x200C] DR7 after RSM (M-02)
                "  \"save_cr0\":      \"0x%08x\",\n"   // SMBASE+0xFFFC (offset 0x7FFC)
                "  \"save_cr3\":      \"0x%08x\",\n"   // +0xFFF8
                "  \"save_eflags\":   \"0x%08x\",\n"   // +0xFFF4
                "  \"save_eip\":      \"0x%08x\",\n"   // +0xFFF0
                "  \"save_eax\":      \"0x%08x\",\n"   // +0xFFD0
                "  \"save_ebx\":      \"0x%08x\",\n"   // +0xFFDC
                "  \"save_cs_sel\":   \"0x%08x\",\n"   // +0xFFAC
                "  \"save_smbase\":   \"0x%08x\",\n"   // +0xFEF8 SMBASE relocation slot
                // REVIEW2 M-02: the four ARCHITECTURAL P5 slots that used to be an
                // unwritten hole between EAX (0x7FD0) and GS (0x7FBC). Dumped so the
                // self-check can prove they are actually populated -- adding save-map
                // beats without a check that reads them back is how the previous gap
                // went unnoticed in the first place.
                "  \"save_dr6\":      \"0x%08x\",\n"   // +0xFFCC
                "  \"save_dr7\":      \"0x%08x\",\n"   // +0xFFC8
                "  \"save_tr\":       \"0x%08x\",\n"   // +0xFFC4 TR selector
                "  \"save_ldtr\":     \"0x%08x\",\n"   // +0xFFC0 LDTR selector
                // ... and the implementation-private TR/LDTR hidden descriptor cache.
                "  \"save_tr_base\":  \"0x%08x\",\n"   // +0xFE50
                "  \"save_tr_limit\": \"0x%08x\",\n"   // +0xFE54
                "  \"save_ldt_base\": \"0x%08x\",\n"   // +0xFE58
                "  \"save_ldt_pack\": \"0x%08x\"\n"    // +0xFE5C {ldt_limit,tr_valid,tr_attr}
                "}\n",
                args.smbase,
                mem.read32(0x2000), mem.read32(0x2004), mem.read32(0x2008),
                mem.read32(0x200C),
                mem.read32(sm + 0x7FFC), mem.read32(sm + 0x7FF8),
                mem.read32(sm + 0x7FF4), mem.read32(sm + 0x7FF0),
                mem.read32(sm + 0x7FD0), mem.read32(sm + 0x7FDC),
                mem.read32(sm + 0x7FAC), mem.read32(sm + 0x7EF8),
                mem.read32(sm + 0x7FCC), mem.read32(sm + 0x7FC8),
                mem.read32(sm + 0x7FC4), mem.read32(sm + 0x7FC0),
                mem.read32(sm + 0x7E50), mem.read32(sm + 0x7E54),
                mem.read32(sm + 0x7E58), mem.read32(sm + 0x7E5C));
            std::fclose(df);
            std::fprintf(stderr, "tb: wrote SMM memory dump to %s\n",
                         args.smm_dump.c_str());
        } else {
            std::fprintf(stderr, "tb: WARNING cannot open --smm-dump '%s'\n",
                         args.smm_dump.c_str());
        }
    }

    // ---- finalize ---------------------------------------------------------
    top->final();
#if VM_TRACE
    if (vcd) { vcd->close(); delete vcd; }
#endif

#if VM_COVERAGE
    // Coverage builds (verif/tb `make cov`, --coverage) accumulate line/toggle
    // counters per run. Dump them to the path in $VEN_COV_DAT so the coverage
    // runner can merge one .dat per program with verilator_coverage. Inert in
    // every non-coverage build (VM_COVERAGE is 0), so the default obj_dir TB is
    // byte-identical and unaffected.
    if (const char* covdat = std::getenv("VEN_COV_DAT")) {
        Verilated::threadContextp()->coveragep()->write(covdat);
        std::fprintf(stderr, "tb: wrote coverage to %s\n", covdat);
    }
#endif

    std::fprintf(stderr,
        "tb: retired %llu instructions in %llu clocks "
        "(bus: %llu reads, %llu writes)\n",
        (unsigned long long)trace.retired(),
        (unsigned long long)cycles,
        (unsigned long long)mem.reads(),
        (unsigned long long)mem.writes());
    if (proxy_mode && !emu) {
        std::fprintf(stderr,
            "tb: M7.1 proxy: replayed %llu / %zu int-0x80 syscalls\n",
            (unsigned long long)syscalls_replayed, syscalls.size());
    }
    if (emu) {
        std::fprintf(stderr,
            "tb: FREE-RUN: %llu syscalls emulated, %zu bytes stdout captured%s\n",
            (unsigned long long)emu->syscalls_serviced(),
            emu->captured_stdout().size(),
            emu_exit ? "" : " (NOTE: guest did not reach exit_group)");
        if (!args.user_stdout.empty()) {
            if (FILE* f = std::fopen(args.user_stdout.c_str(), "wb")) {
                std::fwrite(emu->captured_stdout().data(), 1,
                            emu->captured_stdout().size(), f);
                std::fclose(f);
            }
        }
        std::fprintf(stderr, "----- guest stdout -----\n%s------------------------\n",
                     emu->captured_stdout().c_str());
        if (!args.video_out.empty() && !emu->video().empty()) {
            if (FILE* vf = std::fopen(args.video_out.c_str(), "wb")) {
                std::fwrite(emu->video().data(), 1, emu->video().size(), vf);
                std::fclose(vf);
                std::fprintf(stderr, "tb: wrote %zu bytes of P5Q1 video stream to %s\n",
                             emu->video().size(), args.video_out.c_str());
            }
        }
        if (emu_exit) exit_code = emu_code;
    }
    if (cosim_mode) {
        std::fprintf(stderr,
            "tb: M7.3b win95 co-sim: %llu IN reads serviced (%zu dev_in available, "
            "cursor at %zu), %llu OUT writes consumed, %d port/size desync(s)%s\n",
            (unsigned long long)io_in_count, devins.size(), devin_idx,
            (unsigned long long)io_out_count, io_desync,
            io_exit ? ", isa-debug-exit reached" : "");
    }

    // Bare-metal self-checking sys images report PASS/FAIL through the
    // isa-debug-exit AL value; surface it as the process status the qemu way
    // (((AL<<1)|1)) so a runner can assert it WITHOUT a qemu-system golden. Only
    // taken when the run actually ended on `out 0xf4` and nothing else already
    // claimed exit_code (free-run guest exit / a real error). Inert for the whole
    // make-verify corpus (those tests never touch port 0xf4 / never set io_exit).
    if (io_exit && exit_code == 0) exit_code = ((int)io_exit_al << 1) | 1;

    ventium::g_trace = nullptr;
    trace.close();
    delete top;
    return exit_code;
}
