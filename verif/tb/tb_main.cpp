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
};

[[noreturn]] void usage(const char* prog, int code) {
    std::fprintf(stderr,
        "usage: %s --out <trace.vtrace> [--image <blob> --load <hexaddr>]\n"
        "          [--entry <hexaddr>] [--init-esp <hexaddr>]\n"
        "          [--max-insn N] [--max-cycles M]\n"
        "          [--trace-vcd f] [--quiesce K] [--x87] [--cycle]\n"
        "          [--errata <hexmask>]\n", prog);
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
        long n = mem.load_image(args.image, args.load_addr);
        if (n < 0) {
            std::fprintf(stderr, "tb: failed to load image '%s'\n",
                         args.image.c_str());
            return 2;
        }
        std::fprintf(stderr, "tb: loaded %ld bytes at 0x%08x from %s\n",
                     n, args.load_addr, args.image.c_str());
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
        if (!trace.open(args.out, note, args.x87, args.cycle)) {
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

    // ---- reset: hold rst_n low for a few clocks, then release -------------
    // The TB plays the loader: it establishes the architectural init state the
    // core latches at reset (docs/m1-core-spec.md "Initial architectural
    // state"). init_eip = entry, init_esp = --init-esp. Segments/EFLAGS reset
    // value are constants inside the core.
    top->clk    = 0;
    top->rst_n  = 0;
    top->init_eip  = args.entry;
    top->init_esp  = args.init_esp;
    top->cycle_mode = args.cycle ? 1 : 0;   // M4: enable dual U/V issue
    top->errata_en  = args.errata & 0xF;     // M6: errata-enable bus (default 0)
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

    while (true) {
        uint64_t before = trace.retired();

        // -- clk low phase: combinational settle + serve bus --
        top->clk = 0;
        service_bus();
        top->eval();
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
        top->eval();          // <- DPI vtm_retire calls happen here
        // Re-serve in case the edge changed the request (combinational ack).
        service_bus();
        top->eval();
        dump(half++);

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

    ventium::g_trace = nullptr;
    trace.close();
    delete top;
    return exit_code;
}
