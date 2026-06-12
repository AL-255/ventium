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

#include <vector>
// PS-offload peripheral C models (sw/ps_periph/): when a device is +VEN_<DEV>_PS,
// its forwarded io_ps_* requests are serviced HERE by its C model, proving the C
// model bit-exact vs qemu (the same psoc<dev> per-record gate). On the board these
// same .c files run on the A53 behind ven_soc_axil. Inert when no device is PS
// (io_ps_req stays 0). The .c files are plain C that is ALSO valid C++, so the TB
// build (g++ compiles .c as C++) and the A53 build (gcc, C) are each self-consistent
// — the ctor is declared with default (matching-compiler) linkage on each side.
#include "../../sw/ps_periph/ven_periph.h"
ven_periph_t* ven_uart16550_new(void);
ven_periph_t* ven_rtc_new(void);
ven_periph_t* ven_i8042_new(void);
ven_periph_t* ven_acpipm_new(void);
ven_periph_t* ven_i8272_new(void);
ven_periph_t* ven_vgaregs_new(void);

namespace {

// (dev, lo, hi) -> the C model servicing that forwarded I/O port range.
struct PsDev { ven_periph_t* dev; uint16_t lo, hi; };

struct Args {
    std::string image;
    std::string out;
    std::string vcd;
    std::string ckpt_dump;
    std::string vga_bios;   // optional VGA option ROM loaded at 0xC0000
    uint64_t max_insn   = 1ull << 20;
    uint64_t max_cycles = 1ull << 24;
    uint32_t quiesce    = 64;
    bool     peek_pc    = false;   // on stop, dump opcode bytes at the last retired PC
    bool     peek_vga   = false;   // on stop, decode the 0xB8000 VGA text buffer
    uint32_t peek_mem   = 0;       // on stop, hexdump 64 bytes at this linear address (0=off)
    uint32_t watch_write= 0;       // log every mem write into [addr, addr+16) (0=off; gap-walk)
};

// --watch-write debug hook: the mem service lambda is defined before the `cycles`
// counter is in scope, so the watch state lives at file scope. Logs each write whose
// 4-byte-aligned address overlaps the 16-byte window, deduped across same-clock settles.
uint32_t g_watch_addr   = 0;
uint64_t g_watch_cycles = 0;
uint32_t g_wlast_a = 0xffffffffu, g_wlast_d = 0u; uint64_t g_wlast_c = ~0ull;

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
        else if (k == "--peek-pc")         a.peek_pc    = true;
        else if (k == "--peek-vga")        a.peek_vga   = true;
        else if (k == "--vga-bios")        a.vga_bios   = need("--vga-bios");
        else if (k == "--peek-mem")        a.peek_mem   = parse_u32(need("--peek-mem"));
        else if (k == "--watch-write")     a.watch_write= parse_u32(need("--watch-write"));
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
    g_watch_addr = args.watch_write;

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
        // 4 GiB-TOP ALIAS: a real PC chipset mirrors the BIOS ROM at the top of the
        // 32-bit address space (the last `sz` bytes ending at 0xFFFFFFFF) as well as
        // the 1 MiB alias above. SeaBIOS runs its 32-bit POST from the high alias
        // (jmp 0xFFFFxxxx), so without this it fetches 0 there and wanders. Only
        // images larger than the 64 KiB bare-metal stubs (i.e. a real BIOS) need it;
        // those stubs never touch the high alias, so they are unaffected. (Cosim
        // memory-map convenience; the real SoC provides the alias via the PS / decode.)
        if (sz > 0x10000) {
            uint32_t hi_at = (uint32_t)(0u - (uint32_t)sz);   // 0xFFFE0000 for 128 KiB
            mem.load_image(args.image, hi_at);
            std::fprintf(stderr, "tb_soc: BIOS 4G-top alias at 0x%08x\n", hi_at);
        }
    }

    // VGA option ROM at 0xC0000 (real PCs map the video BIOS there; SeaBIOS scans
    // 0xC0000.. for the 0x55AA signature, copies the ROM, runs its init entry, and
    // the init installs INT 10h). Without it SeaBIOS's int10 call16 lands on an
    // uninitialized vector -> 0:0. Optional (a bare-metal stub never needs it).
    if (!args.vga_bios.empty()) {
        long n = mem.load_image(args.vga_bios, 0x000C0000);
        if (n < 0) std::fprintf(stderr, "tb_soc: WARNING failed to load --vga-bios '%s'\n",
                                args.vga_bios.c_str());
        else std::fprintf(stderr, "tb_soc: loaded %ld bytes at 0x000c0000 from %s (vga option ROM)\n",
                          n, args.vga_bios.c_str());
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

    // ---- PS-offload peripheral C models (registered regardless of build; only
    // the +VEN_<DEV>_PS-configured ports ever reach io_ps_*, so unselected models
    // are simply never called). The board uses the same models via ven_soc_axil.
    std::vector<PsDev> ps_devs;
    ps_devs.push_back({ ven_uart16550_new(), 0x3F8, 0x3FF });  // COM1 16550
    ps_devs.push_back({ ven_rtc_new(),       0x070, 0x071 });  // MC146818 RTC
    ps_devs.push_back({ ven_i8042_new(),     0x060, 0x064 });  // 8042 kbd/mouse
    ps_devs.push_back({ ven_acpipm_new(),    0x608, 0x608 });  // ACPI PM timer
    ps_devs.push_back({ ven_i8272_new(),     0x3F1, 0x3F7 });  // 82077 FDC (0x3F6=IDE never forwarded)
    ps_devs.push_back({ ven_vgaregs_new(),   0x3B0, 0x3DF });  // VGA register file
    for (auto& d : ps_devs) d.dev->reset(d.dev);
    top->io_ps_rdata = 0;
    top->io_ps_ack   = 0;
    bool ps_busy = false;   // an io_ps access has been serviced, awaiting io_ps_req drop

    // ---- mem_* bus service (single-beat, combinational-OK, like tb_main) ----
    // service_bus is called several times per clock (both phases, settle x2). The
    // mem bus is idempotent. The PS C models have READ side-effects (LSR clear,
    // FIFO advance), so — like the RTL devices' clocked side-effects — they are
    // applied EXACTLY ONCE per access: the `ps_busy` latch serves the model on the
    // first observation of an io_ps_req pulse, holds io_ps_rdata + acks while the
    // request is up (matching the RTL's combinational io_ack), and rearms when the
    // core drops io_ps_req (the access retired).
    auto service_bus = [&]() {
        uint32_t rdata = 0;
        bool ack = false;
        mem.service((bool)top->mem_req, (bool)top->mem_we,
                    (uint32_t)top->mem_addr, (uint32_t)top->mem_wdata,
                    (uint8_t)top->mem_wstrb, &rdata, &ack);
        top->mem_rdata = rdata;
        top->mem_ack   = ack;

        // --watch-write: report writes that land in the watched 16-byte window.
        if (g_watch_addr && top->mem_req && top->mem_we) {
            uint32_t wa = (uint32_t)top->mem_addr & ~3u;
            if (wa + 3 >= g_watch_addr && wa < g_watch_addr + 16) {
                uint32_t wd = (uint32_t)top->mem_wdata;
                if (!(wa == g_wlast_a && wd == g_wlast_d && g_watch_cycles == g_wlast_c)) {
                    std::fprintf(stderr,
                        "tb_soc: WATCH-WRITE cyc=%llu addr=0x%08x wdata=0x%08x wstrb=0x%x\n",
                        (unsigned long long)g_watch_cycles, wa, wd, (unsigned)top->mem_wstrb);
                    g_wlast_a = wa; g_wlast_d = wd; g_wlast_c = g_watch_cycles;
                }
            }
        }

        if (top->io_ps_req) {
            if (!ps_busy) {                  // serve this forwarded access ONCE
                uint16_t port = (uint16_t)top->io_ps_addr;
                // OPEN BUS: an unmodeled port reads back all-ones on a real PC (and in
                // qemu), NOT 0. SeaBIOS probes absent ports (e.g. the 0x402 debug port)
                // and branches on 0xFF; returning 0 diverged. Matches the PS app's
                // service_in default. (Modeled ports below overwrite rd.)
                uint8_t  rd   = 0xFF;
                for (auto& d : ps_devs) {
                    if (port >= d.lo && port <= d.hi) {
                        if (top->io_ps_we) d.dev->io_write(d.dev, port, (uint8_t)top->io_ps_wdata);
                        else               rd = d.dev->io_read(d.dev, port);
                        break;
                    }
                }
                top->io_ps_rdata = rd;
                ps_busy = true;
            }
            top->io_ps_ack = 1;
        } else {
            ps_busy = false;
            top->io_ps_ack = 0;
        }
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
        g_watch_cycles = cycles;          // for the --watch-write hook

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

    // ---- diagnostic: decode the VGA text buffer (0xB8000, 80x25, char @ even off)
    // shows what the booted firmware/OS printed via INT 10h (FreeDOS banner / C:\ etc).
    if (args.peek_vga) {
        std::fprintf(stderr, "tb_soc: VGA text buffer @0xB8000:\n");
        for (int row = 0; row < 25; ++row) {
            char line[81]; bool any = false;
            for (int c = 0; c < 80; ++c) {
                uint8_t ch = mem.read8(0xB8000 + (row*80 + c)*2);
                line[c] = (ch >= 32 && ch < 127) ? (char)ch : ' ';
                if (line[c] != ' ') any = true;
            }
            line[80] = 0;
            int e = 79; while (e >= 0 && line[e] == ' ') line[e--] = 0;
            if (any) std::fprintf(stderr, "  %2d| %s\n", row, line);
        }
    }

    // ---- diagnostic: dump opcode bytes at the last retired PC --------------
    // On a quiescence stop this tells HLT-waiting (F4 hlt) from a stuck access.
    if (args.peek_pc) {
        uint32_t p  = ventium::g_last_arch.pc;
        uint32_t cs = ventium::g_last_arch.seg[0];
        uint32_t lin_pm = p;                 // PM-flat (cs.base=0)
        uint32_t lin_rm = (cs << 4) + (p & 0xffff);  // real-mode (cs<<4)+ip
        std::fprintf(stderr, "tb_soc: peek @ last retired pc=0x%08x cs=0x%04x\n", p, cs);
        std::fprintf(stderr, "  PM-flat @0x%08x: ", lin_pm);
        for (int i = 0; i < 20; ++i) std::fprintf(stderr, "%02x ", mem.read8(lin_pm + i));
        std::fprintf(stderr, "\n  real-md @0x%08x: ", lin_rm);
        for (int i = 0; i < 20; ++i) std::fprintf(stderr, "%02x ", mem.read8(lin_rm + i));
        // If the stall sits just past an IRET (CF), the target = the frame it popped:
        // [SS:SP-6]=IP, [SS:SP-4]=CS, [SS:SP-2]=FLAGS (16-bit real-mode iret).
        uint32_t ss  = ventium::g_last_arch.seg[1];
        uint32_t esp = ventium::g_last_arch.gpr[4];
        uint32_t fb  = (ss << 4) + ((esp - 6) & 0xffff);
        uint32_t tip = mem.read8(fb) | (mem.read8(fb + 1) << 8);
        uint32_t tcs = mem.read8(fb + 2) | (mem.read8(fb + 3) << 8);
        uint32_t tlin = (tcs << 4) + tip;
        std::fprintf(stderr, "\n  iret-target %04x:%04x @0x%08x: ", tcs, tip, tlin);
        for (int i = 0; i < 20; ++i) std::fprintf(stderr, "%02x ", mem.read8(tlin + i));
        // Bus state AT the stall: mem_req=1 means the core is parked waiting for an
        // ACK on mem_addr (e.g. an IVT read at a bad idt_base) — a bus-wait stall, not
        // a HALT. mem_req=0 = the core is in S_HALT (unknown opcode / hlt).
        std::fprintf(stderr, "\n  bus: mem_req=%d we=%d addr=0x%08x  (req=1 -> unacked bus wait)\n",
                     (int)top->mem_req, (int)top->mem_we, (uint32_t)top->mem_addr);
    }

    if (args.peek_mem) {
        std::fprintf(stderr, "tb_soc: peek-mem @0x%08x:\n", args.peek_mem);
        for (int row = 0; row < 4; ++row) {
            std::fprintf(stderr, "  0x%08x: ", args.peek_mem + row*16);
            for (int i = 0; i < 16; ++i)
                std::fprintf(stderr, "%02x ", mem.read8(args.peek_mem + row*16 + i));
            std::fprintf(stderr, "\n");
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
