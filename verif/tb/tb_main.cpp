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
void          ven_pic_set_irq(ven_periph_t*, int irq, int level);
uint8_t       ven_pic_peek_vector(ven_periph_t*);
uint8_t       ven_pic_intack(ven_periph_t*);
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

    // M14 video capture (Quake): the guest's $P5Q_VIDEO path; the emulator
    // captures writes to it (the P5Q1 frame stream) and we dump them to
    // --video-out for offline PNG conversion.
    std::string video_path;            // --video-path <guest $P5Q_VIDEO value>
    std::string video_out;             // --video-out <file> (raw P5Q1 stream)
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
        else if (k == "--system")     a.system     = true;
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
        else if (k == "--video-path") a.video_path = need("--video-path");
        else if (k == "--video-out")  a.video_out  = need("--video-out");
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
    // IRQ0 (timer) pump — CYCLE-paced (deterministic; advances during HLT, unlike the
    // board's wall-clock pacing, so a STI;HLT timer wait wakes). Mirrors ven_soc_app's
    // PIC pump: raise IRQ0 every IRQ0_PERIOD cycles, present the PIC's vector on the
    // core's intr seam ONLY once the PIC is programmed (vector>=0x08), intack on inta.
    const uint64_t DOS_IRQ0_PERIOD =
        std::getenv("VEN_IRQ0_PERIOD") ? (uint64_t)strtoull(std::getenv("VEN_IRQ0_PERIOD"),0,0) : 8000;
    uint64_t dos_irq0_next = DOS_IRQ0_PERIOD;
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
    struct { bool ar,r,aw,w,b; uint32_t araddr,arlen,awaddr,wdata,wstrb; } axhs{};
    // #34: AXI_STUCK=1 freezes the slave (a dead DDR/bridge) to exercise the master
    // watchdog -> bus_err -> the core's S_HALT override (cpu_hung), end-to-end.
    const bool axi_stuck = (std::getenv("AXI_STUCK") != nullptr);
    // P2 repro: AXI_RLAT/AXI_WLAT add read/write response latency (wait states) so the
    // sim slave behaves like the real smartconnect + PS DDR (multi-cycle, not immediate)
    // — exposes any L1/AXI fetch-redirect race the immediate-response slave masks.
    const uint32_t AXI_RLAT = std::getenv("AXI_RLAT") ? (uint32_t)atoi(std::getenv("AXI_RLAT")) : 0;
    const uint32_t AXI_WLAT = std::getenv("AXI_WLAT") ? (uint32_t)atoi(std::getenv("AXI_WLAT")) : 0;
    uint32_t axr_lat = 0, axw_lat = 0;   // remaining wait cycles before R / B
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
        top->m_axi_rdata   = r_rdy ? mem.read32(axr_addr) : 0u;
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
        axhs.awaddr = (uint32_t)top->m_axi_awaddr - AXI_REMAP;
        axhs.wdata  = (uint32_t)top->m_axi_wdata;  axhs.wstrb = (uint32_t)top->m_axi_wstrb;
    };
    auto axi_advance = [&]() {
        if (!top->rst_n) { axr=0; axw=0; axr_lat=0; axw_lat=0; return; }
        if (axr==0) { if (axhs.ar) { axr_addr=axhs.araddr; axr_cnt=axhs.arlen; axr=1; axr_lat=AXI_RLAT; } }
        else        { if (axr_lat>0) axr_lat--;
                      else if (axhs.r)  { if (axr_cnt==0) axr=0; else { axr_cnt--; axr_addr+=4; axr_lat=AXI_RLAT; } } }
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
            mem.write32(aligned,nw);
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
    bool     io_exit       = false;   // saw an `out 0xf4` (isa-debug-exit)
    uint64_t io_in_count   = 0;       // diagnostics: IN reads serviced
    uint64_t io_out_count  = 0;       // diagnostics: OUT writes consumed
    int      io_desync     = 0;       // diagnostics: port/size mismatches (a bug)
    auto service_io = [&]() {
        if (!cosim_mode) { top->io_rdata = 0; top->io_ack = 0; return; }
        if (!top->io_req) { top->io_rdata = 0; top->io_ack = 0; io_pending_in = false; return; }
        const uint32_t port = (uint32_t)top->io_addr;
        const uint32_t size = (uint32_t)top->io_size;
        if (top->io_we) {
            // OUT: the CPU drives the value out; we consume it. The isa-debug-exit
            // port 0xf4 stops the run (matches qemu-system -device isa-debug-exit).
            if (port == 0xf4) io_exit = true;
#ifdef VEN_DOS_MODELS
            else if (ven_periph_t* m = dos_model_of((uint16_t)port)) {
                m->io_write(m, (uint16_t)port, (uint8_t)(top->io_wdata & 0xff));
            }
#endif
            else if (args.cosim && (port == 0x3f8 || port == 0xe9)) {
                std::putchar((int)(top->io_wdata & 0xff)); std::fflush(stdout);
            }
            top->io_rdata = 0;
            top->io_ack   = 1;
            io_pending_in = false;
        } else {
            // IN: return the next recorded dev_in value (in order). Cross-check the
            // port + size; a mismatch is a HARNESS/stream desync — report, do not
            // silently mis-replay. Over-run / plain --cosim (no golden dev_in stream):
            // return OPEN BUS 0xFF.. — a real PC (and qemu) float an unmodeled port
            // high, and SeaBIOS branches on 0xFF; returning 0 derails POST.
            uint32_t v = (size == 1) ? 0xFFu : (size == 2) ? 0xFFFFu : 0xFFFFFFFFu;
#ifdef VEN_DOS_MODELS
            if (ven_periph_t* m = dos_model_of((uint16_t)port)) {
                v = (size >= 2 && m->io_read16) ? m->io_read16(m, (uint16_t)port)
                                                : m->io_read(m, (uint16_t)port);
            } else if (args.dos && port == 0x3fd) { v = 0x60;   // COM1 LSR: THR+TSR empty
            } else if (args.dos && port == 0x3f8) { v = 0x00;   // COM1 RBR: no input byte
            } else
#endif
            if (devin_idx < devins.size()) {
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
            top->io_rdata = v;
            top->io_ack   = 1;
            io_pending_in = true;   // commit (advance) on the rising edge
        }
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
    top->soc_en      = 0;
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
    // VEN_DBG_CORE single-step / breakpoint selftest: --dbg-step N parks from reset
    // and grants one instruction per re-park (logging the committed EIP each time, so
    // the printed sequence IS the executed instruction stream); --dbg-bp <eip> arms a
    // PC breakpoint and runs free until the core parks at it.
    uint32_t dbg_steps_done = 0;
    bool     dbg_step_inflight = false;
    if (args.dbg_step_n) top->dbg_halt_req = 1;                  // park at the first boundary
    if (args.dbg_bp)   { top->dbg_bp_en = 1; top->dbg_bp_addr = args.dbg_bp; }
#endif
    while (true) {
        uint64_t before = trace.retired();
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
            if (cycles >= dos_irq0_next) { dos_pit_pending = 1; dos_irq0_next = cycles + DOS_IRQ0_PERIOD; }
            ven_pic_set_irq(g_pic, 0, dos_pit_pending);
            uint8_t pv = ven_pic_peek_vector(g_pic);
            top->soc_en = 1;
            if (g_pic->irq(g_pic) && pv >= 0x08) { top->intr = 1; top->inta_vector = pv; }
            else                                 { top->intr = 0; }
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
        service_proxy();      // M7.1: drive int-0x80 effects if syscall_active
                              //       (may re-arm flush_l1_pending for next clock)
        service_io();         // M7.3b: serve the port-I/O bus if io_req
        top->eval();
        // syscall_active settles combinationally this phase (state==S_DECODE);
        // re-serve so the inputs propagate, then sample whether we proxied.
        service_bus();
        service_proxy();
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
        service_proxy();
        service_io();
        top->eval();          // <- DPI vtm_retire calls happen here; the core
                              //    latches the proxied syscall effects here too
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
            if (devin_idx < devins.size()) ++devin_idx;
            ++io_in_count;
        }
        if (cosim_mode && (bool)top->io_req && (bool)top->io_we && (bool)top->io_ack)
            ++io_out_count;

        ++cycles;

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

        // quiescence / limit detection
        if (trace.retired() > before) {
            idle = 0;
        } else {
            ++idle;
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
        std::fprintf(stderr,
            "tb: [VEN_DBG] EIP=%08x CS=%04x ESP=%08x EFLAGS=%08x\n"
            "tb: [VEN_DBG] FSM=S_%s(0x%02x) mode=%s%s vec=0x%02x fault_pc=%08x CR0=%08x halted=%d\n",
            (uint32_t)top->dbg_eip, (unsigned)top->dbg_cs, (uint32_t)top->dbg_esp,
            (uint32_t)top->dbg_eflags, sn, s,
            (top->dbg_cr0 & 1u) ? "PE" : "real", (top->dbg_cr0 & 0x80000000u) ? "+PG" : "",
            (unsigned)top->dbg_int_vec, (uint32_t)top->dbg_fault_pc, (uint32_t)top->dbg_cr0,
            (int)top->dbg_halted);
    }
#endif

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
                "  \"save_cr0\":      \"0x%08x\",\n"   // SMBASE+0xFFFC (offset 0x7FFC)
                "  \"save_cr3\":      \"0x%08x\",\n"   // +0xFFF8
                "  \"save_eflags\":   \"0x%08x\",\n"   // +0xFFF4
                "  \"save_eip\":      \"0x%08x\",\n"   // +0xFFF0
                "  \"save_eax\":      \"0x%08x\",\n"   // +0xFFD0
                "  \"save_ebx\":      \"0x%08x\",\n"   // +0xFFDC
                "  \"save_cs_sel\":   \"0x%08x\",\n"   // +0xFFAC
                "  \"save_smbase\":   \"0x%08x\"\n"    // +0xFEF8 SMBASE relocation slot
                "}\n",
                args.smbase,
                mem.read32(0x2000), mem.read32(0x2004), mem.read32(0x2008),
                mem.read32(sm + 0x7FFC), mem.read32(sm + 0x7FF8),
                mem.read32(sm + 0x7FF4), mem.read32(sm + 0x7FF0),
                mem.read32(sm + 0x7FD0), mem.read32(sm + 0x7FDC),
                mem.read32(sm + 0x7FAC), mem.read32(sm + 0x7EF8));
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

    ventium::g_trace = nullptr;
    trace.close();
    delete top;
    return exit_code;
}
