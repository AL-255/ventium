// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/tb/tb_soc.cpp
//
// Ventium M8.1 --soc TB driver: the Verilator C++ testbench for the SoC
// integration top (ventium_soc = core[soc_en=1] + ven_pic + ven_pit on the PMIO
// decoder over the io_* seam). It loads a bare-metal BIOS image, cold-resets the
// system (boot_mode=1, CS:EIP=F000:FFF0), services the mem_* bus from a flat
// memory each clock, and lets the core retire instructions through the SAME DPI
// retire path (vtm_retire / dpi_retire.cpp) used by tb_main.cpp — so the emitted
// .vtrace is the standard system-mode trace the sys gate already grades.
//
// Unlike tb_main.cpp this TB does NOT service io_* (the PIC/PIT live INSIDE
// ventium_soc and answer IN/OUT on-die) and has no proxy/cosim modes. The PIT
// raises IRQ0 into the PIC, the PIC drives the core INTR, the core acknowledges
// (inta) + takes the interrupt through the IDT, all inside the RTL.
//
// The differential gate (CHECKPOINT-DIFFERENTIAL, de-risked under qemu-system
// 8.2.2) is auditable from two TB outputs: (1) the emitted retire .vtrace (which
// the gate script scans for the checkpoint-EIP record's GPRs + the structural
// per-delivery effect), and (2) the --checkpoint-dump JSON of the deterministic
// var memory (IRQ0 counter + PIC ISR/IMR readback) at end-of-run. Both are
// boundary-INDEPENDENT and compared against pirqsoc.checkpoint.golden.
//
// CLI:
//   --image <bios.bin>     bare-metal image (mapped so its last byte = 0xFFFFF)
//   --out   <trace.vtrace> output system-mode trace                  (required)
//   --checkpoint-dump <f>  write {mem[0x2000],mem[0x2004],mem[0x2008]} JSON
//   --max-insn   N         stop after N retired instructions  (default 1<<20)
//   --max-cycles M         stop after M core clocks           (default 1<<24)
//   --quiesce    K         idle-cycle threshold to declare done (default 64)
//   --trace-vcd  f         write a Verilator VCD waveform              (optional)

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include "verilated.h"
#include "Vventium_soc.h"
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
    std::string ckpt_dump;
    uint64_t max_insn   = 1ull << 20;
    uint64_t max_cycles = 1ull << 24;
    uint32_t quiesce    = 64;
};

[[noreturn]] void usage(const char* a0, int code) {
    std::fprintf(stderr,
        "usage: %s --image <bios.bin> --out <trace.vtrace>\n"
        "          [--checkpoint-dump f] [--max-insn N] [--max-cycles M]\n"
        "          [--quiesce K] [--trace-vcd f]\n", a0);
    std::exit(code);
}

uint32_t parse_u32(const char* s) { return (uint32_t)std::strtoull(s, nullptr, 0); }
uint64_t parse_u64(const char* s) { return (uint64_t)std::strtoull(s, nullptr, 0); }

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
        if      (k == "--image")           a.image      = need("--image");
        else if (k == "--out")             a.out        = need("--out");
        else if (k == "--checkpoint-dump") a.ckpt_dump  = need("--checkpoint-dump");
        else if (k == "--trace-vcd")       a.vcd        = need("--trace-vcd");
        else if (k == "--max-insn")        a.max_insn   = parse_u64(need("--max-insn"));
        else if (k == "--max-cycles")      a.max_cycles = parse_u64(need("--max-cycles"));
        else if (k == "--quiesce")         a.quiesce    = parse_u32(need("--quiesce"));
        else if (k == "-h" || k == "--help") usage(argv[0], 0);
        else {
            std::fprintf(stderr, "%s: unknown argument '%s'\n", argv[0], k.c_str());
            usage(argv[0], 2);
        }
    }
    if (a.image.empty()) { std::fprintf(stderr, "%s: --image is required\n", argv[0]); usage(argv[0], 2); }
    if (a.out.empty())   { std::fprintf(stderr, "%s: --out is required\n",   argv[0]); usage(argv[0], 2); }
    return a;
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Args args = parse_args(argc, argv);

    // ---- backing memory + BIOS image --------------------------------------
    // System cold reset: a -bios image is mapped so its LAST byte lands at
    // 0x000FFFFF (the reset vector F000:FFF0 -> 0x000FFFF0 hits its last 16
    // bytes). load_addr = 0x00100000 - filesize (a 64 KiB image sits at
    // 0x000F0000.., so segment 0xF000 / base 0x000F0000 / the PM code at
    // 0x000Fxxxx all resolve). Identical to tb_main.cpp's --system mapping.
    ventium::MemModel mem;
    {
        long sz = 0;
        { FILE* f = std::fopen(args.image.c_str(), "rb");
          if (f) { std::fseek(f, 0, SEEK_END); sz = std::ftell(f); std::fclose(f); } }
        if (sz <= 0 || sz > 0x00100000) {
            std::fprintf(stderr, "tb_soc: bios image bad size %ld\n", sz);
            return 2;
        }
        uint32_t load_at = (uint32_t)(0x00100000u - (uint32_t)sz);
        long n = mem.load_image(args.image, load_at);
        if (n < 0) {
            std::fprintf(stderr, "tb_soc: failed to load image '%s'\n", args.image.c_str());
            return 2;
        }
        std::fprintf(stderr, "tb_soc: loaded %ld bytes at 0x%08x from %s (bios)\n",
                     n, load_at, args.image.c_str());
    }

    // ---- trace writer (system-mode .vtrace: x87=false, cycle=false, sys=true) --
    ventium::TraceWriter trace;
    {
        char note[256];
        std::snprintf(note, sizeof note, "ventium_soc tb; image=%s (soc)",
                      args.image.c_str());
        if (!trace.open(args.out, note, /*x87=*/false, /*cycle=*/false, /*sys=*/true)) {
            std::fprintf(stderr, "tb_soc: cannot open trace '%s'\n", args.out.c_str());
            return 2;
        }
    }
    ventium::g_trace = &trace;

    // ---- verilated SoC model ----------------------------------------------
    auto* top = new Vventium_soc;

#if VM_TRACE
    VerilatedVcdC* vcd = nullptr;
    if (!args.vcd.empty()) {
        Verilated::traceEverOn(true);
        vcd = new VerilatedVcdC;
        top->trace(vcd, 99);
        vcd->open(args.vcd.c_str());
    }
#else
    if (!args.vcd.empty())
        std::fprintf(stderr, "tb_soc: --trace-vcd given but built without tracing (TRACE=1)\n");
#endif

    uint64_t half = 0;
    auto dump = [&](uint64_t t) {
#if VM_TRACE
        if (vcd) vcd->dump((vluint64_t)t);
#else
        (void)t;
#endif
    };

    // ---- mem_* bus service (single-beat, combinational-OK, like tb_main) ----
    auto service_bus = [&]() {
        uint32_t rdata = 0;
        bool ack = false;
        mem.service((bool)top->mem_req, (bool)top->mem_we,
                    (uint32_t)top->mem_addr, (uint32_t)top->mem_wdata,
                    (uint8_t)top->mem_wstrb, &rdata, &ack);
        top->mem_rdata = rdata;
        top->mem_ack   = ack;
    };

    // ---- reset: hold rst_n low, boot_mode=1 (system cold reset F000:FFF0) ---
    top->clk       = 0;
    top->rst_n     = 0;
    top->init_eip  = 0;          // system reset seeds CS:EIP itself (F000:FFF0)
    top->init_esp  = 0;
    top->boot_mode = 1;          // system cold reset
    top->mem_rdata = 0;
    top->mem_ack   = 0;
    top->eval();

    const int kResetClocks = 4;
    for (int c = 0; c < kResetClocks; ++c) {
        top->clk = 0; service_bus(); top->eval(); dump(half++);
        top->clk = 1; service_bus(); top->eval(); dump(half++);
    }
    top->rst_n = 1;

    // ---- run loop ----------------------------------------------------------
    uint64_t cycles    = 0;
    uint32_t idle      = 0;
    int      exit_code = 0;

    while (true) {
        uint64_t before = trace.retired();

        // clk low: combinational settle + serve bus
        top->clk = 0; service_bus(); top->eval();
        service_bus(); top->eval();
        dump(half++);

        trace.set_clock(cycles + 1);

        // clk high: rising edge; vtm_retire fires inside eval()
        top->clk = 1; service_bus(); top->eval();
        service_bus(); top->eval();
        dump(half++);

        ++cycles;

        if (trace.retired() > before) idle = 0; else ++idle;

        if (trace.retired() >= args.max_insn) {
            std::fprintf(stderr, "tb_soc: stop: reached --max-insn (%llu)\n",
                         (unsigned long long)args.max_insn);
            break;
        }
        if (cycles >= args.max_cycles) {
            std::fprintf(stderr, "tb_soc: stop: reached --max-cycles (%llu)\n",
                         (unsigned long long)args.max_cycles);
            break;
        }
        // The SoC HALTs on the isa-debug-exit `out 0xf4` (S_HALT, no retire), so
        // the core stops retiring. Quiescence detects that termination cleanly.
        if (idle >= args.quiesce) {
            std::fprintf(stderr, "tb_soc: stop: quiescent for %u clocks (core idle / isa-debug-exit)\n", idle);
            break;
        }
        if (Verilated::gotFinish()) {
            std::fprintf(stderr, "tb_soc: stop: $finish from RTL\n");
            break;
        }
    }

    // ---- checkpoint memory dump (the boundary-independent var memory) -------
    // mem[0x2000] = IRQ0 delivery counter (== N), mem[0x2004] = PIC master ISR
    // readback (0x00, all EOIed), mem[0x2008] = PIC master IMR readback (0xFF,
    // all masked). Differenced against pirqsoc.checkpoint.golden by the gate.
    if (!args.ckpt_dump.empty()) {
        FILE* df = std::fopen(args.ckpt_dump.c_str(), "w");
        if (df) {
            std::fprintf(df,
                "{\n"
                "  \"mem_0x2000_ctr\": %u,\n"
                "  \"mem_0x2004_isr\": \"0x%02x\",\n"
                "  \"mem_0x2008_imr\": \"0x%02x\"\n"
                "}\n",
                mem.read32(0x2000),
                mem.read32(0x2004) & 0xff,
                mem.read32(0x2008) & 0xff);
            std::fclose(df);
            std::fprintf(stderr, "tb_soc: wrote checkpoint memory dump to %s\n",
                         args.ckpt_dump.c_str());
        } else {
            std::fprintf(stderr, "tb_soc: WARNING cannot open --checkpoint-dump '%s'\n",
                         args.ckpt_dump.c_str());
        }
    }

    top->final();
#if VM_TRACE
    if (vcd) { vcd->close(); delete vcd; }
#endif

    std::fprintf(stderr,
        "tb_soc: retired %llu instructions in %llu clocks (bus: %llu reads, %llu writes)\n",
        (unsigned long long)trace.retired(), (unsigned long long)cycles,
        (unsigned long long)mem.reads(), (unsigned long long)mem.writes());

    ventium::g_trace = nullptr;
    trace.close();
    delete top;
    return exit_code;
}
