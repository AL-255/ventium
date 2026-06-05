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
    uint32_t errata     = 0;      // M6 errata-enable bus (default 0 = clean core)
    // M2S.1: --system selects boot_mode=system (cold reset at F000:FFF0, real
    // mode) and emits the sys fields + header sys:true. A -bios image is loaded
    // so its LAST byte sits at 0x000FFFFF (image base = 0x100000 - image_bytes),
    // matching qemu-system-i386 -bios; the reset vector F000:FFF0 = 0x000FFFF0
    // then lands on the image's last 16 bytes.
    bool     system     = false;
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
};

[[noreturn]] void usage(const char* prog, int code) {
    std::fprintf(stderr,
        "usage: %s --out <trace.vtrace> [--image <blob> --load <hexaddr>]\n"
        "          [--entry <hexaddr>] [--init-esp <hexaddr>]\n"
        "          [--max-insn N] [--max-cycles M]\n"
        "          [--trace-vcd f] [--quiesce K] [--x87] [--cycle] [--system]\n"
        "          [--errata <hexmask>] [--smm-dump <file>] [--smbase <hexaddr>]\n"
        "          [--quake-image <image.json> --lockstep <golden.vtrace>]\n", prog);
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
        else if (k == "--system")     a.system     = true;
        else if (k == "--smm-dump")   a.smm_dump    = need("--smm-dump");
        else if (k == "--smbase")     a.smbase      = parse_u32(need("--smbase"));
        else if (k == "--quake-image") a.quake_image = need("--quake-image");
        else if (k == "--lockstep")    a.lockstep    = need("--lockstep");
        else if (k == "--errata")     a.errata     = parse_u32(need("--errata"));
        else if (k == "-h" || k == "--help") usage(argv[0], 0);
        else {
            std::fprintf(stderr, "%s: unknown argument '%s'\n", argv[0], k.c_str());
            usage(argv[0], 2);
        }
    }
    if (a.out.empty()) {
        std::fprintf(stderr, "%s: --out is required\n", argv[0]);
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
    }

    // ---- M7.1 Quake initial process image + int-0x80 proxy ----------------
    // When --quake-image is given: map the producer's process image (PT_LOAD +
    // stack + vDSO regions) into the bus memory at their vaddrs, seed the reset
    // regs (entry/esp/eflags) + flat user selectors, and ENABLE proxy_en. The
    // golden's sys_call effects (--lockstep) are replayed at each int-0x80.
    bool                          proxy_mode = false;
    std::vector<ventium::SyscallEffect> syscalls;
    size_t                        sc_idx = 0;   // next syscall to replay (in order)
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
        if (!args.lockstep.empty()) {
            syscalls = ventium::load_syscall_replay(args.lockstep);
        }
        std::fprintf(stderr,
            "tb: quake lock-step ON (proxy_en=1): entry=0x%08x esp=0x%08x, "
            "%zu syscalls to replay\n", img.eip, img.esp, syscalls.size());
    }

    // ---- trace writer (opens file + writes header) ------------------------
    ventium::TraceWriter trace;
    {
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
    auto service_proxy = [&]() {
        if (!proxy_mode) return;
        if (!top->syscall_active) return;
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
    top->errata_en  = args.errata & 0xF;     // M6: errata-enable bus (default 0)
    top->proxy_en   = proxy_mode ? 1 : 0;    // M7.1: int-0x80 proxy + %gs base
    top->syscall_resume_eip = 0;
    top->syscall_eax        = 0;
    top->syscall_apply_gs   = 0;
    top->syscall_gs_base    = 0;
    top->mem_rdata = 0;
    top->mem_ack   = 0;
    top->eval();

    const int kResetClocks = 4;
    for (int c = 0; c < kResetClocks; ++c) {
        // clk low phase
        top->clk = 0;
        service_bus();
        top->eval();
        dump(half++);
        // clk high phase (rising edge)
        top->clk = 1;
        service_bus();
        top->eval();
        dump(half++);
    }
    top->rst_n = 1;   // deassert reset (synchronous; §1)

    // ---- run loop ---------------------------------------------------------
    uint64_t cycles      = 0;
    uint32_t idle        = 0;        // consecutive clocks with no new retire
    int      exit_code   = 0;

    uint64_t syscalls_replayed = 0;   // M7.1 diagnostics
    while (true) {
        uint64_t before = trace.retired();

        // -- clk low phase: combinational settle + serve bus --
        top->clk = 0;
        service_bus();
        service_proxy();      // M7.1: drive int-0x80 effects if syscall_active
        top->eval();
        // syscall_active settles combinationally this phase (state==S_DECODE);
        // re-serve so the inputs propagate, then sample whether we proxied.
        service_bus();
        service_proxy();
        top->eval();
        bool saw_active = proxy_mode && (bool)top->syscall_active;
        dump(half++);

        // Cycle mode (M4): stamp the clock the about-to-fire retirements belong
        // to. `cycles` is the count of completed clocks; this rising edge is the
        // (cycles+1)-th clock, so cyc is 1-based and the first retirement lands
        // at cyc>=1. Two retirements in this same eval (a paired issue) read the
        // same value and so share cyc. Cheap + harmless in func mode.
        trace.set_clock(cycles + 1);

        // -- clk high phase: rising edge; vtm_retire fires inside eval() --
        top->clk = 1;
        service_bus();
        service_proxy();
        top->eval();          // <- DPI vtm_retire calls happen here; the core
                              //    latches the proxied syscall effects here too
        // Re-serve in case the edge changed the request (combinational ack).
        service_bus();
        top->eval();
        dump(half++);

        // M7.1: a proxied int-0x80 has been latched by the core this clock —
        // advance to the next golden sys_call effect (strict order).
        if (saw_active && sc_idx < syscalls.size()) {
            ++sc_idx;
            ++syscalls_replayed;
        }

        ++cycles;

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
                "tb: stop: CPU HUNG (F00F: LOCK CMPXCHG8B reg-dst, Erratum 81) "
                "after %llu retired in %llu clocks\n",
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
    if (proxy_mode) {
        std::fprintf(stderr,
            "tb: M7.1 proxy: replayed %llu / %zu int-0x80 syscalls\n",
            (unsigned long long)syscalls_replayed, syscalls.size());
    }

    ventium::g_trace = nullptr;
    trace.close();
    delete top;
    return exit_code;
}
