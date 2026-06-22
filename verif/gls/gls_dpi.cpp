// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// verif/gls/gls_dpi.cpp — DPI-C glue for the xsim gate-level FreeDOS harness.
//
// The SV testbench (tb_gls_soc.sv) drives the synthesized ventium_top netlist.
// xsim cannot link the Verilator C++ models directly, so this file re-exposes
// the SAME C/C++ models the Verilator tb_main.cpp uses (MemModel + the PS
// peripheral C models in sw/ps_periph/*.c) as DPI-C functions:
//
//   gls_init(disk, bios)            : construct MemModel + the 6 PS peripheral
//                                     models, load seabios.bin so its last byte
//                                     is at phys 0xFFFFF (+ KV260 4G-top alias),
//                                     attach the FreeDOS disk to ven_ide.
//   gls_mem_read32(addr)            : behavioral AXI4 DDR slave read backing
//   gls_mem_write32(addr,data,wstrb): behavioral AXI4 DDR slave write backing
//                                     (both x86-phys-indexed; the SV slave has
//                                     already stripped the KV260 AXI_REMAP).
//   gls_io_service(...)             : the service_io() port dispatch — ONE
//                                     side-effect per io_req assertion. Read
//                                     returns rdata+ack; write consumes + acks.
//   gls_irq_poll(cycle)             : the F3 IRQ0 timer pump — raise IRQ0 every
//                                     period, return {intr, vector} for the
//                                     core's intr seam.
//   gls_inta(vec)                   : INTA boundary — intack the PIC model.
//
// This is a faithful port of the seams in verif/tb/tb_main.cpp; see the inline
// references. It deliberately reuses memmodel.cpp + sw/ps_periph/*.c verbatim
// (compiled into the same xsc shared object) — nothing is reimplemented.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "svdpi.h"
#include "memmodel.h"

extern "C" {
#include "ven_periph.h"
}

// The PS peripheral-model constructors (sw/ps_periph/*.c, compiled as C).
extern "C" {
ven_periph_t* ven_i8042_new(void);
ven_periph_t* ven_pic_new(void);
ven_periph_t* ven_vgaregs_new(void);
ven_periph_t* ven_pit_new(void);
ven_periph_t* ven_rtc_new(void);
ven_periph_t* ven_ide_new(const char* disk_path);
void          ven_pic_set_irq(ven_periph_t*, int irq, int level);
uint8_t       ven_pic_peek_vector(ven_periph_t*);
uint8_t       ven_pic_intack(ven_periph_t*);
}

namespace {

ventium::MemModel*  g_mem  = nullptr;
ven_periph_t*       g_pit  = nullptr;
ven_periph_t*       g_rtc  = nullptr;
ven_periph_t*       g_pic  = nullptr;
ven_periph_t*       g_i8042= nullptr;
ven_periph_t*       g_vga  = nullptr;
ven_periph_t*       g_ide  = nullptr;

// F3 IRQ0 timer-pump state (mirrors tb_main.cpp DOS_IRQ0_PERIOD pump).
uint64_t g_irq0_period = 8000;
uint64_t g_irq0_next   = 8000;
int      g_pit_pending = 0;

// service_io side-effect-once guard (mirrors io_serviced/io_held_rdata).
bool     g_io_serviced = false;
uint32_t g_io_held     = 0;

// diagnostics
uint64_t g_io_in = 0, g_io_out = 0;

// GLS_PROBE self-check capture: the AL value the program drives on `out 0xf4`
// (the isa-debug-exit code) + a marker-port (0xE9/0x402) trail. A probe program
// computes a KNOWN value and exits with AL=0x00 on PASS, AL=<nonzero failcode>
// on the first detected fetch divergence; the SV tb reads g_probe_exit_al at
// termination and prints PASS/FAIL.  g_probe_markers is the ordered list of bytes
// the program wrote to 0xE9 (a "trail" — each checkpoint emits a distinct byte,
// so a derail shows up as a truncated/wrong trail even if it never reaches 0xf4).
uint32_t g_probe_exit_al = 0xFFFFFFFFu;   // 0xFFFF.. = never exited cleanly
uint8_t  g_probe_markers[256];
int      g_probe_nmark = 0;

// Map a port to its PS peripheral model (verif/tb/tb_main.cpp dos_model_of).
ven_periph_t* dos_model_of(uint16_t port) {
    if (port == 0x60 || port == 0x64) return g_i8042;
    if (port == 0x20 || port == 0x21 || port == 0xA0 || port == 0xA1 ||
        port == 0x4D0 || port == 0x4D1) return g_pic;
    if (port >= 0x3B0 && port <= 0x3DF) return g_vga;
    if (port >= 0x40 && port <= 0x43) return g_pit;
    if (port == 0x70 || port == 0x71) return g_rtc;
    if ((port >= 0x1F0 && port <= 0x1F7) || port == 0x3F6) return g_ide;
    return nullptr;
}

} // namespace

extern "C" {

// gls_init: construct everything + load the BIOS image. disk may be "" (no IDE).
// Mirrors tb_main.cpp's --system image load + the VEN_KV260_SOC 4G-top alias +
// the --dos peripheral-model construction. Returns 0 on success.
int gls_init(const char* disk, const char* bios) {
    if (!g_mem) g_mem = new ventium::MemModel();

    // --system BIOS load: image's LAST byte at 0x000FFFFF (load = 0x100000 - sz).
    long sz = 0;
    { FILE* f = std::fopen(bios, "rb");
      if (!f) { std::fprintf(stderr, "gls: cannot open bios '%s'\n", bios); return 2; }
      std::fseek(f, 0, SEEK_END); sz = std::ftell(f); std::fclose(f); }
    if (sz <= 0 || sz > 0x00100000) {
        std::fprintf(stderr, "gls: bad bios size %ld\n", sz); return 2;
    }
    uint32_t load_at = (uint32_t)(0x00100000u - (uint32_t)sz);
    long n = g_mem->load_image(bios, load_at);
    if (n < 0) { std::fprintf(stderr, "gls: failed to load bios\n"); return 2; }
    std::fprintf(stderr, "gls: loaded %ld bytes at 0x%08x from %s (bios)\n",
                 n, load_at, bios);

    // KV260 4G-top alias: the deployed bitstream folds the high BIOS ROM window
    // into the DDR carveout via the L1AXI_ADDR_MASK=0x0FFF_FFFF wrap. After the
    // SV slave strips AXI_REMAP it sees the MASKED phys, so stage the same copy.
    if (sz > 0x10000) {
        uint32_t hi_masked = (uint32_t)((0u - (uint32_t)sz) & 0x0FFFFFFFu);
        g_mem->load_image(bios, hi_masked);
        std::fprintf(stderr, "gls: KV260 4G-top alias (masked) at 0x%08x\n", hi_masked);
    }

    // --dos PS peripheral C models (same code ven_soc_app runs on the KV260).
    g_pit = ven_pit_new();
    g_rtc = ven_rtc_new();
    g_pic = ven_pic_new();
    g_i8042 = ven_i8042_new();
    g_vga = ven_vgaregs_new();
    g_ide = (disk && disk[0]) ? ven_ide_new(disk) : nullptr;
    std::fprintf(stderr, "gls: PS peripheral C models wired (disk=%s)\n",
                 (disk && disk[0]) ? disk : "(none)");

    // env override of the IRQ0 period (mirrors VEN_IRQ0_PERIOD).
    if (const char* e = std::getenv("VEN_IRQ0_PERIOD")) {
        g_irq0_period = (uint64_t)strtoull(e, nullptr, 0);
        if (!g_irq0_period) g_irq0_period = 8000;
    }
    g_irq0_next = g_irq0_period;

    // ---- STRETCH: fetch-stress repro (GLS_FETCHSTRESS=1) -------------------
    // Opt-in only: leaves the default SeaBIOS boot byte-identical when unset.
    // Stages a tiny self-contained 16-bit real-mode loop right at the reset
    // vector's far-jump target (phys 0xFE05B, the entry SeaBIOS would reach) and
    // overwrites the SeaBIOS entry there with a stream that exercises the fetch
    // RAMs WITHOUT the multi-minute SeaBIOS POST: a marching set of taken/near
    // jumps across several cache lines (the fetch path the board-only bug lives
    // in), terminated by `out 0xf4` (isa-debug-exit) so the harness stops cleanly.
    //
    // The reset far-jump `jmp f000:e05b` (phys 0xFE05B) is untouched, so the core
    // takes the exact same first control transfer as the real boot — only the
    // landing code is replaced. If the board-only fetch corruption is RAM-fill/
    // select related it can be hit in far fewer gate-level cycles here.
    if (const char* e = std::getenv("GLS_FETCHSTRESS")) {
      if (e[0] == '1') {
        // phys 0xFE05B = the reset far-jump target (cs=F000, ip=E05B). Build a
        // sequence of short forward jumps spanning cache-line boundaries, a tight
        // backward loop counted in CX, then isa-debug-exit. All bytes 16-bit.
        // Layout (offsets from 0xFE05B):
        //   ip=E05B: mov cx, 0x0040      ; B9 40 00     (loop count)
        //   ip=E05E: nop x N (pad to span lines)         ; 90 ...
        //   loop:    dec cx              ; 49
        //            jnz back            ; 75 FB        (taken backward branch)
        //            mov dx, 0x00F4      ; BA F4 00
        //            mov al, 0x00        ; B0 00
        //            out dx, al          ; EE           (isa-debug-exit)
        // Use a long NOP sled so the backward branch + several forward fetches
        // cross multiple 16-byte/32-byte fetch granules.
        const uint32_t base = 0x000FE05Bu;
        std::vector<uint8_t> p;
        p.push_back(0xB9); p.push_back(0x40); p.push_back(0x00);  // mov cx,0x40
        // 80-byte NOP sled to span several cache lines before the loop body.
        size_t sled = 80;
        for (size_t i = 0; i < sled; i++) p.push_back(0x90);     // nop
        // loop body starts here (offset 3+sled).
        p.push_back(0x49);                                        // dec cx
        p.push_back(0x75);                                        // jnz rel8
        // rel8 back to the start of the sled (so each iteration re-fetches it):
        // target = sledStart ; next_ip after this jnz = base+3+sled+2.
        // disp = sledStart - next_ip = (base+3) - (base+3+sled+2) = -(sled+2)
        p.push_back((uint8_t)(0 - (int)(sled + 2)));              // disp8
        p.push_back(0xBA); p.push_back(0xF4); p.push_back(0x00);  // mov dx,0xF4
        p.push_back(0xB0); p.push_back(0x00);                     // mov al,0
        p.push_back(0xEE);                                        // out dx,al
        for (size_t i = 0; i < p.size(); i++)
            g_mem->write8(base + (uint32_t)i, p[i]);
        std::fprintf(stderr,
            "gls: GLS_FETCHSTRESS staged %zu-byte loop at phys 0x%08x "
            "(cx=0x40, %zu-byte sled, isa-debug-exit)\n", p.size(), base, sled);
      }
    }

    // ---- GLS_PROBE: targeted self-checking fetch-corruption probes ----------
    // The residual board fetch bug is a SPECIFIC fill->read / way-stale window in
    // the SPINE fetch-select (core.sv ic_byte, the rd_lineA/B content-addressed
    // mux), NOT a naive A[2]-straddle (the reset far-jump straddles A[2] and is
    // CORRECT). GLS_PROBE=<n> stages a small, fully-known 16-bit real-mode program
    // at the reset far-jump target (phys 0xFE05B, cs=F000 ip=E05B) that recreates
    // ONE such stress condition and SELF-CHECKS its own control flow:
    //
    //   * the program computes a known value / takes a known branch;
    //   * on the EXPECTED path it writes marker bytes to port 0xE9 (a "trail")
    //     and exits `out 0xf4, AL=0x00` (PASS);
    //   * any FETCH DIVERGENCE (a branch displacement/immediate read wrong, an
    //     opcode misdecoded) sends control to a FAIL block `out 0xf4, AL=<code>`
    //     OR off into unpopulated (zero) memory -> the harness wedge/fault detector
    //     fires. The SV tb reads g_probe_result() and prints PASS/FAIL.
    //
    // Each probe targets a fetch-RAM stress the NOP-sled + single far-jump do NOT
    // cover. The probe number selects which (see the switch). Combine with
    // GLS_MODE=net GLS_DBG=1 for the committed-PC trajectory.
    if (const char* e = std::getenv("GLS_PROBE")) {
      int probe = atoi(e);
      // Real-mode CS=0xF000; IP=0xE05B is phys 0xFE05B. We assemble at a chosen
      // IP and the helper converts to phys (0xF0000 + ip). All control transfers
      // are near (within CS=F000), so IP stays the linear-low 16 bits.
      const uint32_t CSBASE = 0x000F0000u;
      auto emit = [&](uint32_t ip, const std::vector<uint8_t>& bytes) {
        for (size_t i = 0; i < bytes.size(); i++)
          g_mem->write8(CSBASE + ip + (uint32_t)i, bytes[i]);
      };
      // building blocks (16-bit real mode)
      auto MARK = [&](uint8_t b) -> std::vector<uint8_t> {            // out 0xE9, b
        return { 0xB0, b, 0xE6, 0xE9 };                              // mov al,b; out 0xE9,al
      };
      auto EXIT = [&](uint8_t code) -> std::vector<uint8_t> {        // out 0xF4, code
        return { 0xB0, code, 0xE6, 0xF4 };                          // mov al,code; out 0xF4,al
      };
      const uint32_t ENTRY = 0xE05Bu;     // reset far-jump target IP

      // Common epilogue blocks placed high so probes can JMP to them:
      //   PASS @ ip=0xE800 : MARK(0xAA) ; EXIT(0x00)
      //   FAIL @ ip=0xE810 : EXIT(0xEE)            (generic mismatch)
      const uint32_t PASS_IP = 0xE800u;
      const uint32_t FAIL_IP = 0xE810u;
      { std::vector<uint8_t> b; auto m = MARK(0xAA); b.insert(b.end(),m.begin(),m.end());
        auto x = EXIT(0x00); b.insert(b.end(),x.begin(),x.end()); emit(PASS_IP, b); }
      { auto x = EXIT(0xEE); emit(FAIL_IP, x); }

      // helper: a near jmp rel8/rel16; and a Jcc rel16. We compute disp from the
      // INSTRUCTION END (x86 rel is relative to next-IP).
      auto JMP16 = [&](uint32_t at, uint32_t tgt) -> std::vector<uint8_t> {
        int32_t disp = (int32_t)tgt - (int32_t)(at + 3);   // E9 + 2-byte rel16
        return { 0xE9, (uint8_t)(disp & 0xff), (uint8_t)((disp >> 8) & 0xff) };
      };
      // Jcc rel16: 0F 8x  cw   (8x: 83=jae/jnc, 84=jz, 85=jnz, 82=jb/jc)
      auto JCC16 = [&](uint32_t at, uint8_t cc, uint32_t tgt) -> std::vector<uint8_t> {
        int32_t disp = (int32_t)tgt - (int32_t)(at + 4);   // 0F 8x + 2-byte rel16
        return { 0x0F, cc, (uint8_t)(disp & 0xff), (uint8_t)((disp >> 8) & 0xff) };
      };

      std::fprintf(stderr, "gls: GLS_PROBE=%d staging (entry phys 0x%05x)\n",
                   probe, CSBASE + ENTRY);

      switch (probe) {
      // ====================================================================
      // PROBE 1: rel16 operand alignment sweep — a `jae rel16` whose 2-byte
      // displacement is placed at EVERY byte offset across the A[2] boundaries
      // (0x04/0x0C/0x14/0x1C) and the 32-byte LINE boundary (0x1E-0x22). This is
      // the EXACT instruction class of the documented residual (`jae 0x04DA`,
      // bytes 0f 83 2d f3, rel16 read as 0xB595 not 0xF32D). A correct fetch takes
      // the branch to PASS; a corrupted displacement lands in zero memory (wedge)
      // or at FAIL. The sweep walks a chain: at each alignment a `jae +disp`
      // jumps FORWARD to the next aligned slot; the last jumps to PASS. Any wrong
      // displacement breaks the chain -> derail.
      // ====================================================================
      case 1: {
        // Set flags so jae (CF=0) is TAKEN: clc-equivalent via `xor ax,ax` then
        // the chain. We pre-clear CF with a `clc` (0xF8).
        emit(ENTRY, { 0xF8 });            // clc  (CF=0 -> jae taken)
        // Build a chain of jae's; the i-th jae sits so its 2-byte rel16 operand
        // (bytes 2..3 of the 4-byte 0F 83 cw) lands at successive line offsets.
        // We place each jae at an IP whose (IP&0x1F) makes the operand straddle a
        // target boundary, padding with NOPs from a running cursor.
        uint32_t cursor = ENTRY + 1;      // after clc
        // operand byte0 offset targets to sweep (relative to a 32-byte line):
        // 0x03,0x04,0x05 (A[2]=0x04), 0x0B,0x0C,0x0D, 0x13,0x14,0x15,
        // 0x1B,0x1C,0x1D, 0x1E,0x1F,0x20,0x21 (line boundary 0x20).
        const int opnd_off[] = {0x03,0x04,0x05,0x0b,0x0c,0x0d,0x13,0x14,0x15,
                                0x1b,0x1c,0x1d,0x1e,0x1f,0x20,0x21,0x22};
        const int N = (int)(sizeof(opnd_off)/sizeof(opnd_off[0]));
        // lay the chain in a fresh region starting at a 32-byte-aligned base so the
        // offsets are exact; base line aligned just above ENTRY+1.
        uint32_t line_base = (cursor + 0x40) & ~0x1Fu;   // a clean aligned start
        // jmp from ENTRY's clc area into the chain start.
        // chain slot k begins so its OPERAND (jae byte index 2) is at the wanted off.
        // jae layout: [0F][83][lo][hi]; operand byte0 is at jae_ip+2.
        uint32_t line = line_base;
        std::vector<uint32_t> jae_ip;
        for (int k = 0; k < N; k++) {
          uint32_t want_op = line + opnd_off[k];   // where operand byte0 must land
          uint32_t this_jae = want_op - 2;         // jae starts 2 before its operand
          jae_ip.push_back(this_jae);
          line += 0x40;                            // next slot 2 lines down (room)
        }
        // entry clc -> jmp to first jae
        emit(ENTRY + 1, JMP16(ENTRY + 1, jae_ip[0]));
        // fill the whole region with NOPs first so gaps are NOP padding.
        for (uint32_t a = line_base; a < line + 0x40; a++)
          g_mem->write8(CSBASE + a, 0x90);
        // each jae jumps to the NEXT jae; the last jumps to PASS.
        for (int k = 0; k < N; k++) {
          uint32_t tgt = (k + 1 < N) ? jae_ip[k + 1] : PASS_IP;
          emit(jae_ip[k], JCC16(jae_ip[k], 0x83, tgt));   // jae (0F 83) rel16
        }
        std::fprintf(stderr, "gls: PROBE1 rel16-alignment-sweep: %d jae's, "
                     "operand offsets across A[2] + line boundaries\n", N);
        break;
      }

      // ====================================================================
      // PROBE 2: fill->read collision window. Force a fresh LINE FILL of line L,
      // then IMMEDIATELY (next fetch) read an instruction whose operand lives in L
      // — the same-cycle fill-then-read the rd_coll guard exists for. We jump
      // FORWARD by >32 bytes into a never-fetched line (forcing a miss+fill), and
      // the very first instruction there is a `jae rel16` whose operand must be
      // read out of the just-filled line. The branch target encodes a known value:
      // taken -> PASS, wrong displacement -> derail.
      // ====================================================================
      case 2: {
        emit(ENTRY, { 0xF8 });            // clc
        // jump forward into a cold line (line boundary), guaranteeing a fill.
        uint32_t cold_line = (ENTRY + 0x200) & ~0x1Fu;   // far cold aligned line
        emit(ENTRY + 1, JMP16(ENTRY + 1, cold_line));
        // at cold_line: the FIRST byte fetched after the fill is a jae whose
        // 2-byte operand is at cold_line+2 (within the just-filled line). Target
        // PASS. If the fill->read window corrupts the operand read -> derail.
        emit(cold_line, JCC16(cold_line, 0x83, PASS_IP));   // jae -> PASS
        std::fprintf(stderr, "gls: PROBE2 fill->read: jmp to cold line 0x%05x, "
                     "jae operand read straight out of the fresh fill\n",
                     CSBASE + cold_line);
        break;
      }

      // ====================================================================
      // PROBE 3: way re-allocation (way-stale window). Three distinct lines that
      // map to the SAME icache set (addresses differing by exactly the way-stride
      // = num_sets * 32). In a 2-way cache, touching 3 same-set lines forces an
      // eviction + re-fill of a way; then re-reading the FIRST line's operand
      // tests whether rdA_way_q / ic_rd_lineA went stale (the documented
      // "rdA_set_q still matches addr's set but the way changed" window). The
      // program ping-pongs L0->L1->L2->L0 via jae's, each carrying a rel16 the
      // fetch must read correctly; the final jae goes to PASS.
      // ====================================================================
      case 3: {
        emit(ENTRY, { 0xF8 });            // clc
        // num_sets for the deployed half-cache: IC is 2-way; with VEN_CACHE_HALF
        // the index width is small. Use a conservative way-stride of 4 KiB (covers
        // any plausible set count up to 128 sets * 32 B = 4 KiB) so L0/L1/L2 are
        // GUARANTEED same-set for any IDXW<=7. Stay within the 0xF0000 segment.
        const uint32_t STRIDE = 0x1000u;
        uint32_t L0 = (ENTRY + 0x100) & ~0x1Fu;
        uint32_t L1 = L0 + STRIDE;
        uint32_t L2 = L0 + 2 * STRIDE;    // must stay < 0x10000 (real-mode IP)
        if (L2 >= 0xFFF0u) { L0 = 0x9000; L1 = 0xA000; L2 = 0xB000; }
        emit(ENTRY + 1, JMP16(ENTRY + 1, L0));
        // L0: jae -> L1 ; L1: jae -> L2 ; L2: jae -> L0b (a 2nd visit of L0's
        // line, now possibly evicted) ; L0b: jae -> PASS.
        // place a 2nd jae just after L0's first (same line) for the re-visit.
        uint32_t L0b = L0 + 8;            // still in L0's line (offset 8)
        emit(L0,  JCC16(L0,  0x83, L1));
        emit(L1,  JCC16(L1,  0x83, L2));
        emit(L2,  JCC16(L2,  0x83, L0b));
        emit(L0b, JCC16(L0b, 0x83, PASS_IP));
        std::fprintf(stderr, "gls: PROBE3 way-realloc: L0=0x%05x L1=0x%05x "
                     "L2=0x%05x (stride 0x%x), re-read L0 after evict\n",
                     CSBASE+L0, CSBASE+L1, CSBASE+L2, STRIDE);
        break;
      }

      // ====================================================================
      // PROBE 4: mov-imm32 / mov-imm16 whose IMMEDIATE straddles A[2]+line
      // boundaries, with a self-check on the loaded value. mov bx, imm16 (BB lo hi)
      // is placed so the 2-byte immediate crosses each boundary; the program then
      // `cmp bx, KNOWN` and `jne FAIL`. A corrupted immediate fetch -> bx wrong ->
      // jne taken -> FAIL exit code 0xE4. Sweeps the immediate across offsets like
      // probe 1 but checks a DATA value (not a branch target) — catches a fetch
      // corruption that flips operand bytes without derailing control flow.
      // ====================================================================
      case 4: {
        const uint16_t KNOWN = 0x1234;
        uint32_t line_base = (ENTRY + 0x80) & ~0x1Fu;
        emit(ENTRY, JMP16(ENTRY, line_base));
        // sweep the imm16 of `mov bx, 0x1234` (BB lo hi) across offsets.
        const int imm_off[] = {0x04,0x05,0x0c,0x0d,0x14,0x15,0x1c,0x1d,0x1e,0x1f,0x20,0x21};
        const int N = (int)(sizeof(imm_off)/sizeof(imm_off[0]));
        uint32_t line = line_base;
        // NOP-fill the region.
        for (uint32_t a = line_base; a < line_base + (uint32_t)N*0x40 + 0x40; a++)
          g_mem->write8(CSBASE + a, 0x90);
        uint32_t chain_entry = 0;
        uint32_t prev_after = 0;
        for (int k = 0; k < N; k++) {
          uint32_t imm_at = line + imm_off[k];   // imm byte0 offset
          uint32_t mov_ip = imm_at - 1;          // BB is 1 byte before its imm
          if (k == 0) chain_entry = mov_ip;
          // mov bx, KNOWN
          emit(mov_ip, { 0xBB, (uint8_t)(KNOWN & 0xff), (uint8_t)(KNOWN >> 8) });
          // cmp bx, KNOWN  (81 FB lo hi) ; jne FAIL (75 rel8 to a near trampoline)
          uint32_t chk = mov_ip + 3;
          emit(chk, { 0x81, 0xFB, (uint8_t)(KNOWN & 0xff), (uint8_t)(KNOWN >> 8) });
          // jne rel16 to FAIL block (use 0F 85 for range safety)
          uint32_t jne_ip = chk + 4;
          emit(jne_ip, JCC16(jne_ip, 0x85, FAIL_IP));   // jne -> FAIL
          // jmp to next slot (or PASS) after the check
          uint32_t jmp_ip = jne_ip + 4;
          uint32_t nxt = (k + 1 < N) ? (line + 0x40) + imm_off[k+1] - 1 : PASS_IP;
          emit(jmp_ip, JMP16(jmp_ip, nxt));
          prev_after = jmp_ip;
          line += 0x40;
        }
        (void)prev_after;
        emit(ENTRY, JMP16(ENTRY, chain_entry));
        std::fprintf(stderr, "gls: PROBE4 imm16-straddle+check: %d mov/cmp/jne "
                     "across A[2]+line boundaries (FAIL=0xEE on wrong imm)\n", N);
        break;
      }

      // ====================================================================
      // PROBE 5: branch-target prefetch (port B / pf_redir) landing mid-line.
      // A taken branch whose target is mid-line exercises ic_rd_setB =
      // pf_redir_tgt's set (the Method-B reversed/redirect read). We chain taken
      // jae's whose targets land at mid-line offsets (4,12,20,28 within their
      // line), so port B prefetches the redirect target and the spine must read
      // the landed instruction's bytes from the B-buffer. Wrong target/byte ->
      // derail. Final -> PASS.
      // ====================================================================
      case 5: {
        emit(ENTRY, { 0xF8 });            // clc
        uint32_t base = (ENTRY + 0x100) & ~0x1Fu;
        const int land_off[] = {0x04,0x0c,0x14,0x1c,0x06,0x0e,0x16,0x1e};
        const int N = (int)(sizeof(land_off)/sizeof(land_off[0]));
        // NOP-fill.
        for (uint32_t a = base; a < base + (uint32_t)N*0x40 + 0x40; a++)
          g_mem->write8(CSBASE + a, 0x90);
        std::vector<uint32_t> land;
        for (int k = 0; k < N; k++) land.push_back(base + (uint32_t)k*0x40 + land_off[k]);
        // entry jumps to the first landing.
        emit(ENTRY + 1, JMP16(ENTRY + 1, land[0]));
        // at each landing place a jae to the next landing (taken; mid-line target).
        for (int k = 0; k < N; k++) {
          uint32_t tgt = (k + 1 < N) ? land[k + 1] : PASS_IP;
          emit(land[k], JCC16(land[k], 0x83, tgt));
        }
        std::fprintf(stderr, "gls: PROBE5 branch-target-prefetch: %d mid-line "
                     "taken jae targets (port-B redirect read)\n", N);
        break;
      }

      // ====================================================================
      // PROBE 6: predecode re-walk (uopcache pdv hit vs re-walk). A tight loop of
      // SHORT ops (a line of NOPs + a dec/jnz) executed many times: the first pass
      // predecodes+fills the uop slots; subsequent passes hit pdv. We interleave a
      // jae whose operand must read correctly on the RE-FETCH (pdv-hit) path. The
      // loop count is known; an off-by-one from a misfetched displacement changes
      // the iteration count -> a final marker mismatch. The loop ends jae->PASS.
      // ====================================================================
      case 6: {
        emit(ENTRY, { 0xF8 });            // clc (jae taken)
        uint32_t lp = (ENTRY + 0x60) & ~0x1Fu;
        emit(ENTRY + 1, JMP16(ENTRY + 1, lp));
        // mov cx, 0x10 ; loop: <16 nops spanning the line> dec cx; jnz loop; jae PASS
        std::vector<uint8_t> body;
        body.push_back(0xB9); body.push_back(0x10); body.push_back(0x00); // mov cx,0x10
        uint32_t loop_ip = lp + 3;
        for (int i = 0; i < 24; i++) body.push_back(0x90);   // nop sled (spans line)
        body.push_back(0x49);                                 // dec cx
        // jnz loop (75 rel8); rel = loop_ip - (here+2)
        uint32_t jnz_ip = lp + (uint32_t)body.size();
        int8_t d = (int8_t)((int32_t)loop_ip - (int32_t)(jnz_ip + 2));
        body.push_back(0x75); body.push_back((uint8_t)d);
        emit(lp, body);
        // after the loop: jae -> PASS
        uint32_t after = lp + (uint32_t)body.size();
        emit(after, JCC16(after, 0x83, PASS_IP));
        std::fprintf(stderr, "gls: PROBE6 predecode re-walk loop (cx=0x10, "
                     "24-nop body), jae->PASS after\n");
        break;
      }

      // ====================================================================
      // PROBE 7: fill->read COLLISION-WINDOW loop. The documented residual is a
      // way-stale / collided-buffer consume (rd_collA/B window): a fetch read of a
      // line launched the SAME cycle a fill writes that {set,way}. A single pass
      // rarely lands the read on the exact fill cycle; a TIGHT LOOP that re-evicts
      // and re-reads the same set every iteration sweeps the relative phase of
      // (fill-write vs read-launch) across many cycles, so if ANY phase consumes a
      // collided/stale buffer the jae reads a wrong rel16 -> derail. Structure:
      //   loop: jae L1 ; (L1) jae L2 ; (L2) jae L0b(same set as loop, evicted) ;
      //         (L0b) dec cx ; jnz loop ; jae PASS
      // L0/L1/L2 are 3 same-set lines (2-way => each iteration evicts+refills),
      // and the dec/jnz keeps the loop body itself re-fetched. cx large so many
      // phases are tried. A correct fetch loops cx times then jae->PASS.
      // ====================================================================
      case 7: {
        emit(ENTRY, { 0xF8 });            // clc (jae taken)
        const uint32_t STRIDE = 0x1000u;  // same-set for any IDXW<=7
        uint32_t L0 = 0x9000, L1 = L0 + STRIDE, L2 = L0 + 2*STRIDE;  // 0x9000/A000/B000
        emit(ENTRY + 1, JMP16(ENTRY + 1, L0));
        // L0: mov cx,0x80 (first time) — but cx must persist across the loop, so
        // set cx BEFORE the loop, at L0-... Actually set cx at entry region.
        // Re-do: set cx at a preamble line, then jmp into the loop at L0.
        uint32_t pre = 0x8000;
        emit(ENTRY + 1, JMP16(ENTRY + 1, pre));
        emit(pre, { 0xB9, 0x80, 0x00 });             // mov cx, 0x80
        emit(pre + 3, JMP16(pre + 3, L0));           // jmp L0 (loop head)
        // L0 -> L1 -> L2 -> L0b(dec/jnz) chain; L0b in L0's line (offset 8).
        uint32_t L0b = L0 + 8;
        emit(L0, JCC16(L0, 0x83, L1));               // jae L1
        emit(L1, JCC16(L1, 0x83, L2));               // jae L2
        emit(L2, JCC16(L2, 0x83, L0b));              // jae L0b
        // L0b: dec cx ; jnz L0 ; jae PASS
        emit(L0b, { 0x49 });                          // dec cx
        int8_t d = (int8_t)((int32_t)L0 - (int32_t)(L0b + 1 + 2)); // jnz rel8
        emit(L0b + 1, { 0x75, (uint8_t)d });          // jnz L0
        emit(L0b + 3, JCC16(L0b + 3, 0x83, PASS_IP)); // jae PASS
        std::fprintf(stderr, "gls: PROBE7 collision-window loop: L0=0x%05x L1=0x%05x "
                     "L2=0x%05x cx=0x80 (phase sweep of fill-vs-read)\n",
                     CSBASE+L0, CSBASE+L1, CSBASE+L2);
        break;
      }

      // ====================================================================
      // PROBE 8: documented-pattern replay — a `jae rel16` (0F 83 cw, the EXACT
      // opcode of the board residual) reached right after a CPUID-like multi-cycle
      // op + a return, so the jae's fetch follows a control transfer back into a
      // line that may have been evicted by the intervening code's fetches. We
      // mimic: jmp far-ish forward (fill A), execute a few multi-cycle ops (cpuid,
      // imul) that stall the pipe (opening the fill/way-stale window), then a
      // jae BACKWARD to a target whose rel16 spans the A[2] word — the closest
      // structural analogue to cs=2593:11a9 `0f 83 2d f3`. Self-checks via PASS.
      // ====================================================================
      case 8: {
        emit(ENTRY, { 0xF8 });            // clc
        uint32_t blk = (ENTRY + 0x100) & ~0x1Fu;
        emit(ENTRY + 1, JMP16(ENTRY + 1, blk));
        // blk: a BENIGN multi-cycle stall (mul cl, an 8-bit multiply) to open the
        // pipe-stall / fill window WITHOUT real-mode CPUID/operand-size confounds,
        // then a jae(0F83) whose rel16 byte0 lands at an A[2]=1 offset, jumping
        // forward to PASS — the structural analogue of the board residual
        // cs=2593:11a9 `0f 83 2d f3` reached after a multi-cycle predecessor.
        std::vector<uint8_t> b;
        b.push_back(0xB0); b.push_back(0x07);   // mov al, 7
        b.push_back(0xB1); b.push_back(0x09);   // mov cl, 9
        b.push_back(0xF6); b.push_back(0xE1);   // mul cl    (multi-cycle, AX=al*cl=0x3F)
        b.push_back(0xF8);                       // clc  (mul touches CF; re-clear so jae taken)
        // pad with nops so the following jae's rel16 (byte0) lands at offset 0x14
        // (an A[2]=1 boundary) within blk's line.
        uint32_t here = blk + (uint32_t)b.size();
        uint32_t jae_ip_want = (blk & ~0x1Fu) + 0x12; // jae at 0x12 => operand byte0 at 0x14
        while (here < jae_ip_want) { b.push_back(0x90); here++; }
        emit(blk, b);
        // jae -> PASS (operand byte0 at line offset 0x14 = A[2]=1)
        emit(jae_ip_want, JCC16(jae_ip_want, 0x83, PASS_IP));
        std::fprintf(stderr, "gls: PROBE8 documented-replay: mul-cl stall then "
                     "jae(0F83) operand@A[2]=1 (analogue of cs2593:11a9 0f 83 2d f3)\n");
        break;
      }

      default:
        std::fprintf(stderr, "gls: GLS_PROBE=%d UNKNOWN (valid 1-8); no-op\n", probe);
        break;
      }
    }
    return 0;
}

// Behavioral AXI4 DDR slave backing — x86-phys-indexed (SV slave stripped REMAP).
unsigned int gls_mem_read32(unsigned int addr) {
    if (!g_mem) return 0;
    return g_mem->read32(addr);
}

// wstrb is the 4-bit per-byte write enable; the SV slave passes the WORD-ALIGNED
// address (it already aligned awaddr & ~3 like the faithful DDR model in tb_main).
void gls_mem_write32(unsigned int addr, unsigned int data, unsigned int wstrb) {
    if (!g_mem) return;
    uint32_t aligned = addr & ~3u;
    uint32_t old = g_mem->read32(aligned), nw = 0;
    for (int b = 0; b < 4; b++) {
        uint32_t by = ((wstrb >> b) & 1) ? ((data >> (b * 8)) & 0xff)
                                         : ((old >> (b * 8)) & 0xff);
        nw |= by << (b * 8);
    }
    g_mem->write32(aligned, nw);
}

// gls_io_service: the service_io() port dispatch, ONE side-effect per io_req
// assertion. The SV testbench calls this on the rising-edge service phase while
// io_req is asserted, and calls gls_io_idle() when io_req deasserts so the next
// op re-arms. Returns rdata (in *rdata) + ack (return value, 1=ack).
//   we   : io_we (1=OUT/write, 0=IN/read)
//   addr : io_addr (port)
//   size : io_size (1/2/4 bytes)
//   wdata: io_wdata (write data)
int gls_io_service(int we, int addr, int size, unsigned int wdata,
                   unsigned int* rdata) {
    const uint32_t port = (uint32_t)addr & 0xffff;
    const uint32_t sz   = (uint32_t)size;

    if (g_io_serviced) { *rdata = g_io_held; return 1; }  // hold across S_IO clocks
    g_io_serviced = true;

    if (we) {
        // OUT: the CPU drives the value; consume it. isa-debug-exit 0xf4 -> the
        // SV tb watches the return flag bit (0x100) to terminate.
        if (port == 0xf4) {
            g_probe_exit_al = (wdata & 0xff);  // capture the isa-debug-exit code
            *rdata = 0; ++g_io_out; g_io_held = 0; return 0x101;
        }
        if (ven_periph_t* m = dos_model_of((uint16_t)port)) {
            if (sz >= 2 && m->io_write16) m->io_write16(m, (uint16_t)port, (uint16_t)wdata);
            else                          m->io_write(m, (uint16_t)port, (uint8_t)(wdata & 0xff));
        } else if (port == 0x3f8 || port == 0xe9 || port == 0x402) {
            if (port == 0xe9 && g_probe_nmark < 256)
                g_probe_markers[g_probe_nmark++] = (uint8_t)(wdata & 0xff);  // probe trail
            std::putchar((int)(wdata & 0xff)); std::fflush(stdout);  // COM1 / dbg
        }
        g_io_held = 0;
        ++g_io_out;
        *rdata = 0;
        return 1;
    } else {
        // IN: open-bus default 0xFF.. (a real PC floats an unmodeled port high);
        // the modeled ports answer via the PS C-models.
        uint32_t v = (sz == 1) ? 0xFFu : (sz == 2) ? 0xFFFFu : 0xFFFFFFFFu;
        if (ven_periph_t* m = dos_model_of((uint16_t)port)) {
            v = (sz >= 2 && m->io_read16) ? m->io_read16(m, (uint16_t)port)
                                          : m->io_read(m, (uint16_t)port);
        } else if (port == 0x3fd) { v = 0x60;   // COM1 LSR (TX ready)
        } else if (port == 0x3f8) { v = 0x00;   // COM1 RBR
        }
        g_io_held = v;
        ++g_io_in;
        *rdata = v;
        return 1;
    }
}

// Called by the SV tb when io_req deasserts: re-arm the once-per-assertion guard.
void gls_io_idle(void) { g_io_serviced = false; }

// F3 IRQ0 timer pump (mirrors tb_main.cpp DOS IRQ pump). Returns the packed
// {vector[7:0], intr[8]} the SV tb drives on the core's intr/inta_vector seam.
int gls_irq_poll(unsigned long long cycle) {
    if (!g_pic) return 0;
    if (cycle >= g_irq0_next) { g_pit_pending = 1; g_irq0_next = cycle + g_irq0_period; }
    ven_pic_set_irq(g_pic, 0, g_pit_pending);
    uint8_t pv = ven_pic_peek_vector(g_pic);
    if (g_pic->irq(g_pic) && pv >= 0x08) return (int)((1u << 8) | pv);
    return 0;
}

// INTA boundary: the core took the injected vector this clock -> intack the PIC.
void gls_inta(void) {
    if (!g_pic) return;
    uint8_t vec = ven_pic_intack(g_pic);
    if (vec == 0x08) g_pit_pending = 0;
}

// Diagnostics readout at end-of-run.
void gls_io_stats(unsigned long long* in, unsigned long long* out) {
    *in = g_io_in; *out = g_io_out;
}

// GLS_PROBE self-check readout: the captured isa-debug-exit AL code + the marker
// trail length + a packed prefix of the trail (first 4 marker bytes). The SV tb
// prints PASS (al==0 + expected trail) / FAIL.
void gls_probe_result(int* exit_al, int* nmark, unsigned int* trail0) {
    *exit_al = (int)g_probe_exit_al;
    *nmark   = g_probe_nmark;
    unsigned int t = 0;
    for (int i = 0; i < 4 && i < g_probe_nmark; i++)
        t |= ((unsigned int)g_probe_markers[i]) << (i * 8);
    *trail0 = t;
}

} // extern "C"
