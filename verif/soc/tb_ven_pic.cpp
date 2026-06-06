// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// ============================================================================
// tb_ven_pic.cpp  --  directed unit self-check for ven_pic.sv (8259A PIC pair)
//
//   Drives the SoC common register interface through the DOCUMENTED 8259A
//   programming sequences and asserts the CPU-observable results match the
//   QEMU 8.2.2 hw/intc/i8259.c semantics.  This is a UNIT-level self-check
//   vs the documented behaviour (NOT yet differential-vs-qemu-system).
//
//   Build/run via verif/soc/Makefile (target: pic).
// ============================================================================
#include "Vven_pic.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <string>

static Vven_pic* dut = nullptr;
static vluint64_t main_time = 0;
static int g_pass = 0;
static int g_fail = 0;

// ---- clock helpers ---------------------------------------------------------
static void tick() {
    dut->clk = 0; dut->eval(); main_time++;
    dut->clk = 1; dut->eval(); main_time++;
}

// Settle combinational outputs without advancing the clock edge.
static void settle() { dut->eval(); }

// ---- check helper ----------------------------------------------------------
static void check(const std::string& name, uint32_t got, uint32_t exp) {
    if (got == exp) {
        printf("  [PASS] %-52s got=0x%02x\n", name.c_str(), got);
        g_pass++;
    } else {
        printf("  [FAIL] %-52s got=0x%02x exp=0x%02x\n", name.c_str(), got, exp);
        g_fail++;
    }
}
static void check_bool(const std::string& name, int got, int exp) {
    if (got == exp) { printf("  [PASS] %-52s got=%d\n", name.c_str(), got); g_pass++; }
    else { printf("  [FAIL] %-52s got=%d exp=%d\n", name.c_str(), got, exp); g_fail++; }
}

// ---- bus transactions (cs asserted for exactly one clocked edge) ----------
// OUT (CPU write): commits on the clocked edge while (cs & we).
static void io_out(uint16_t port, uint8_t val) {
    dut->cs = 1; dut->we = 1; dut->addr = port; dut->wdata = val;
    tick();
    dut->cs = 0; dut->we = 0;
    settle();
}

// IN (CPU read): rdata is combinational off the regs; any read side-effect
// (poll-mode intack) commits on the clocked edge while (cs & ~we).
static uint8_t io_in(uint16_t port) {
    dut->cs = 1; dut->we = 0; dut->addr = port;
    settle();                 // sample the combinational read value first
    uint8_t r = dut->rdata;
    tick();                   // clocked edge applies any read side-effect
    dut->cs = 0;
    settle();
    return r;
}

// pulse the INTA strobe for one clock (pic_read_irq): vector is combinational,
// side-effects commit on the edge.
static uint8_t inta_cycle() {
    dut->inta = 1;
    settle();
    uint8_t vec = dut->inta_vector;
    tick();
    dut->inta = 0;
    settle();
    return vec;
}

static void set_irqline(int bit, int level) {
    if (level) dut->irq_in |= (1u << bit);
    else       dut->irq_in &= ~(1u << bit);
    settle();
}

// Standard PC/AT BIOS init of the master 8259A (base 0x08), edge, cascade,
// 8086 mode.  ICW1=0x11, ICW2=0x08, ICW3=0x04 (slave on IR2), ICW4=0x01.
static void init_master(uint8_t base) {
    io_out(0x20, 0x11);   // ICW1: ICW4 needed, cascade, edge
    io_out(0x21, base);   // ICW2: vector base
    io_out(0x21, 0x04);   // ICW3: slave attached to IR2
    io_out(0x21, 0x01);   // ICW4: 8086 mode, normal EOI
    io_out(0x21, 0x00);   // OCW1: unmask all
}
// Standard init of the slave 8259A (base 0x70).  ICW3=0x02 (cascade id 2).
static void init_slave(uint8_t base) {
    io_out(0xA0, 0x11);
    io_out(0xA1, base);
    io_out(0xA1, 0x02);   // ICW3: slave id 2
    io_out(0xA1, 0x01);
    io_out(0xA1, 0x00);
}

// ============================================================================
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vven_pic;

    // power-on
    dut->clk = 0; dut->rst = 0; dut->cs = 0; dut->we = 0;
    dut->addr = 0; dut->wdata = 0; dut->irq_in = 0; dut->inta = 0;
    dut->eval();
    // synchronous active-high reset
    dut->rst = 1; tick(); tick(); dut->rst = 0; settle();

    printf("== ven_pic directed unit self-check (vs QEMU i8259.c) ==\n");

    // ------------------------------------------------------------------
    // T1: ICW init sequence sets the vector base (irq_base = ICW2 & 0xf8)
    //     and leaves init_state back at normal so OCW1 writes IMR.
    // ------------------------------------------------------------------
    printf("\n[T1] ICW init sequence + IMR readback\n");
    init_master(0x08);
    init_slave(0x70);
    // After unmask-all OCW1, reading the data port returns IMR (==0x00).
    check("master IMR after init (port 0x21 read)", io_in(0x21), 0x00);
    check("slave  IMR after init (port 0xA1 read)", io_in(0xA1), 0x00);
    // mask some lines via OCW1 and read back
    io_out(0x21, 0xAA);
    check("master IMR readback = 0xAA", io_in(0x21), 0xAA);
    io_out(0x21, 0x00); // unmask again

    // ------------------------------------------------------------------
    // T2: edge-triggered IRQ on master IR1 -> IRR bit set, int_out asserts.
    //     OCW3 read-register-select chooses IRR vs ISR on the cmd port.
    // ------------------------------------------------------------------
    printf("\n[T2] raise IRQ1 (edge): IRR set, int_out asserted\n");
    set_irqline(1, 1);  tick(); settle();   // edge sampled on a clock
    io_out(0x20, 0x0A); // OCW3: read IRR
    check("master IRR after IRQ1 = 0x02", io_in(0x20), 0x02);
    check_bool("int_out asserted with pending IRQ1", dut->int_out, 1);
    // ISR still zero (not yet acknowledged)
    io_out(0x20, 0x0B); // OCW3: read ISR
    check("master ISR before INTA = 0x00", io_in(0x20), 0x00);

    // ------------------------------------------------------------------
    // T3: INTA acknowledge: vector = base + irq (0x08+1=0x09), ISR set,
    //     IRR cleared (edge), int_out drops.
    // ------------------------------------------------------------------
    printf("\n[T3] INTA acknowledge of IRQ1\n");
    {
        uint8_t vec = inta_cycle();
        check("INTA vector for IRQ1 = base+1 = 0x09", vec, 0x09);
    }
    io_out(0x20, 0x0B); // read ISR
    check("master ISR after INTA = 0x02", io_in(0x20), 0x02);
    io_out(0x20, 0x0A); // read IRR
    check("master IRR cleared after edge INTA = 0x00", io_in(0x20), 0x00);
    // line still high but edge already consumed -> no re-trigger, no INT
    check_bool("int_out low while IR1 in-service (line high, no edge)", dut->int_out, 0);

    // ------------------------------------------------------------------
    // T4: non-specific EOI (OCW2 = 0x20) clears highest ISR bit.
    // ------------------------------------------------------------------
    printf("\n[T4] non-specific EOI clears ISR\n");
    set_irqline(1, 0); tick(); settle();    // drop the line (clears last_irr)
    io_out(0x20, 0x20); // OCW2: non-specific EOI
    io_out(0x20, 0x0B); // read ISR
    check("master ISR after non-specific EOI = 0x00", io_in(0x20), 0x00);

    // ------------------------------------------------------------------
    // T5: IMR masking: a masked line must NOT produce int_out / INTA.
    // ------------------------------------------------------------------
    printf("\n[T5] IMR masks IRQ3\n");
    io_out(0x21, 0x08);  // mask IR3
    set_irqline(3, 1); tick(); settle();
    io_out(0x20, 0x0A);  // read IRR -- IRR still records the request
    check("IRR records masked IRQ3 = 0x08", io_in(0x20), 0x08);
    check_bool("int_out low: IRQ3 masked", dut->int_out, 0);
    io_out(0x21, 0x00);  // unmask
    settle();
    check_bool("int_out asserts once IRQ3 unmasked", dut->int_out, 1);
    // ack + EOI to clean up
    {
        uint8_t vec = inta_cycle();
        check("INTA vector for IRQ3 = base+3 = 0x0B", vec, 0x0B);
    }
    set_irqline(3, 0); tick(); settle();
    io_out(0x20, 0x20); // EOI

    // ------------------------------------------------------------------
    // T6: priority -- two simultaneous edges (IR1 + IR4): IR1 (higher prio,
    //     lower number) wins the first INTA.
    // ------------------------------------------------------------------
    printf("\n[T6] priority: IR1 served before IR4\n");
    set_irqline(1, 1); set_irqline(4, 1); tick(); settle();
    {
        uint8_t vec = inta_cycle();
        check("first INTA serves IR1 -> 0x09", vec, 0x09);
    }
    // IR1 now in-service (prio 1). IR4 is lower prio than the in-service IR1,
    // so it must NOT preempt -> int_out stays low until IR1 EOI'd.
    check_bool("int_out low: IR4 lower prio than in-service IR1", dut->int_out, 0);
    set_irqline(1, 0); tick(); settle();
    io_out(0x20, 0x20);            // non-specific EOI clears IR1
    settle();
    check_bool("int_out re-asserts for pending IR4 after EOI", dut->int_out, 1);
    {
        uint8_t vec = inta_cycle();
        check("second INTA serves IR4 -> 0x0C", vec, 0x0C);
    }
    set_irqline(4, 0); tick(); settle();
    io_out(0x20, 0x20);            // EOI IR4

    // ------------------------------------------------------------------
    // T7: cascade -- slave IR (irq_in[8+3] = IR11) -> master IR2 -> INTA
    //     returns the SLAVE vector (slave base 0x70 + 3 = 0x73).  Requires
    //     two ISR clears (slave then master).
    // ------------------------------------------------------------------
    printf("\n[T7] cascade: slave IR3 (global IRQ11) via master IR2\n");
    set_irqline(8 + 3, 1);         // slave IR3
    tick(); settle();              // slave edge sampled; cascade level -> master IR2
    tick(); settle();              // master IR2 edge sampled
    check_bool("int_out asserted for cascaded slave IRQ", dut->int_out, 1);
    {
        uint8_t vec = inta_cycle();
        check("cascade INTA returns slave vector 0x73", vec, 0x73);
    }
    // master ISR bit2 set, slave ISR bit3 set
    io_out(0x20, 0x0B); check("master ISR bit2 set (cascade) = 0x04", io_in(0x20), 0x04);
    io_out(0xA0, 0x0B); check("slave  ISR bit3 set = 0x08", io_in(0xA0), 0x08);
    // EOI slave then master (real software EOIs both)
    set_irqline(8 + 3, 0); tick(); settle();
    io_out(0xA0, 0x20);            // slave non-specific EOI
    io_out(0x20, 0x20);            // master non-specific EOI
    io_out(0xA0, 0x0B); check("slave ISR cleared after EOI = 0x00", io_in(0xA0), 0x00);
    io_out(0x20, 0x0B); check("master ISR cleared after EOI = 0x00", io_in(0x20), 0x00);

    // ------------------------------------------------------------------
    // T8: spurious IRQ -- INTA while nothing pending returns base+7 (IR7),
    //     and does NOT set ISR (QEMU: spurious host IRQ).
    // ------------------------------------------------------------------
    printf("\n[T8] spurious master INTA -> IR7 (0x0F), no ISR set\n");
    {
        check_bool("int_out low (nothing pending)", dut->int_out, 0);
        uint8_t vec = inta_cycle();
        check("spurious INTA vector = base+7 = 0x0F", vec, 0x0F);
    }
    io_out(0x20, 0x0B);
    check("master ISR after spurious INTA = 0x00", io_in(0x20), 0x00);

    // ------------------------------------------------------------------
    // T9: ELCR registers (0x4D0/0x4D1) read/write with the per-chip masks
    //     (master 0xf8, slave 0xde).
    // ------------------------------------------------------------------
    printf("\n[T9] ELCR masked read/write (master 0xf8, slave 0xde)\n");
    io_out(0x4D0, 0xFF);
    check("ELCR master = 0xFF & 0xF8 = 0xF8", io_in(0x4D0), 0xF8);
    io_out(0x4D1, 0xFF);
    check("ELCR slave  = 0xFF & 0xDE = 0xDE", io_in(0x4D1), 0xDE);
    io_out(0x4D0, 0x00); io_out(0x4D1, 0x00); // clear (back to edge mode)

    // ------------------------------------------------------------------
    // T10: level-triggered via ELCR -- IRR bit follows the line; after INTA
    //      the IRR is NOT cleared while the line stays high (QEMU pic_intack).
    // ------------------------------------------------------------------
    printf("\n[T10] level-triggered IRQ5 via ELCR (IRR not cleared on INTA)\n");
    io_out(0x4D0, 0x20);           // ELCR master bit5 -> IR5 level triggered
    set_irqline(5, 1); tick(); settle();
    io_out(0x20, 0x0A);
    check("level IRQ5 sets IRR = 0x20", io_in(0x20), 0x20);
    {
        uint8_t vec = inta_cycle();
        check("INTA serves IR5 -> 0x0D", vec, 0x0D);
    }
    io_out(0x20, 0x0A);
    check("IRR still 0x20 after INTA (level, line high)", io_in(0x20), 0x20);
    io_out(0x20, 0x0B);
    check("ISR bit5 set after INTA = 0x20", io_in(0x20), 0x20);
    // drop line then EOI
    set_irqline(5, 0); tick(); settle();
    io_out(0x20, 0x0A);
    check("IRR clears once level line low = 0x00", io_in(0x20), 0x00);
    io_out(0x20, 0x20);            // EOI
    io_out(0x4D0, 0x00);           // restore edge mode

    // ------------------------------------------------------------------
    // T11: specific EOI (OCW2 = 0x60 | irq) clears exactly that ISR bit.
    //      Put IR1 and IR6 in service, specific-EOI IR6 only.
    // ------------------------------------------------------------------
    printf("\n[T11] specific EOI clears the named ISR bit only\n");
    // serve IR6 first by masking IR1 path: simplest is to drive IR6, ack,
    // then drive IR1, ack (IR1 higher prio than in-service IR6 -> preempts).
    set_irqline(6, 1); tick(); settle();
    (void)inta_cycle();            // IR6 in service (ISR bit6)
    set_irqline(1, 1); tick(); settle();
    (void)inta_cycle();            // IR1 preempts (higher prio) -> ISR bit1 too
    io_out(0x20, 0x0B);
    check("ISR = IR1|IR6 = 0x42", io_in(0x20), 0x42);
    io_out(0x20, 0x66);            // specific EOI of IR6 (0x60 | 6)
    io_out(0x20, 0x0B);
    check("after specific-EOI IR6, ISR = IR1 only = 0x02", io_in(0x20), 0x02);
    set_irqline(1, 0); set_irqline(6, 0); tick(); settle();
    io_out(0x20, 0x61);            // specific EOI IR1 (0x60 | 1)
    io_out(0x20, 0x0B);
    check("ISR fully cleared = 0x00", io_in(0x20), 0x00);

    // ------------------------------------------------------------------
    // T12: poll mode (OCW3 bit2): the next read returns (0x80 | irq) and
    //      acknowledges (sets ISR), per QEMU pic_ioport_read poll path.
    // ------------------------------------------------------------------
    printf("\n[T12] poll mode read returns 0x80|irq and acks\n");
    set_irqline(4, 1); tick(); settle();
    io_out(0x20, 0x0C);            // OCW3 with poll bit (0x08|0x04)
    {
        uint8_t r = io_in(0x20);   // poll read: 0x80 | 4
        check("poll read = 0x80 | IR4 = 0x84", r, 0x84);
    }
    io_out(0x20, 0x0B);
    check("poll-mode ack set ISR bit4 = 0x10", io_in(0x20), 0x10);
    set_irqline(4, 0); tick(); settle();
    io_out(0x20, 0x20);            // EOI

    // ------------------------------------------------------------------
    // T13: auto-EOI (ICW4 bit1) -- INTA does NOT set ISR (auto-cleared).
    // ------------------------------------------------------------------
    printf("\n[T13] auto-EOI: INTA leaves ISR clear\n");
    io_out(0x20, 0x11);            // ICW1
    io_out(0x21, 0x08);            // ICW2 base
    io_out(0x21, 0x04);            // ICW3
    io_out(0x21, 0x03);            // ICW4 = 8086 (bit0) + auto-EOI (bit1)
    io_out(0x21, 0x00);            // OCW1 unmask
    set_irqline(2 == 2 ? 1 : 1, 1); // use IR1 (avoid cascade IR2)
    tick(); settle();
    {
        uint8_t vec = inta_cycle();
        check("auto-EOI INTA vector IR1 = 0x09", vec, 0x09);
    }
    io_out(0x20, 0x0B);
    check("auto-EOI: ISR remains 0x00 after INTA", io_in(0x20), 0x00);
    set_irqline(1, 0); tick(); settle();

    // ==================================================================
    printf("\n================ SUMMARY ================\n");
    printf("  PASS = %d   FAIL = %d\n", g_pass, g_fail);
    printf("  RESULT: %s\n", (g_fail == 0) ? "PASS" : "FAIL");
    printf("=========================================\n");

    dut->final();
    delete dut;
    return (g_fail == 0) ? 0 : 1;
}
