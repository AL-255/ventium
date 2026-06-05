// verif/soc/tb_ven_port92.cpp — directed unit self-check for rtl/soc/ven_port92.sv
//
// Unit-level self-check vs the DOCUMENTED QEMU 8.2.2 hw/i386/port92.c semantics.
// This is NOT yet differential-vs-qemu-system (that comes at SoC integration);
// it asserts the CPU-observable register read/write behaviour matches spec.
//
// Checks (each drives the common ven_<x> register interface):
//   1. Power-on: outport=0 => rdata=0, a20_gate=0, reset_req=0.
//   2. Write 0x02 (bit1=1): a20_gate goes high; rdata reads back 0x02;
//      no reset_req (bit0 stayed 0).
//   3. Read-back fidelity: full byte stored verbatim (write 0xAA -> read 0xAA),
//      a20_gate tracks bit1.
//   4. reset_req EDGE: write with bit0 0->1 produces exactly a 1-clock pulse.
//   5. No re-pulse: a second write keeping bit0=1 produces NO pulse.
//   6. Re-arm: write bit0=0 then bit0=1 again -> pulse fires again.
//   7. PC RESET (rst): clears bit0 ONLY, preserves A20/bit1 (QEMU port92_reset).
//   8. Reset re-arms the edge detector: after a reset that cleared bit0, a
//      subsequent 0->1 write fires reset_req again.
//   9. Reads have no side effects on outport.
//  10. cs deasserted: writes are ignored (no state change, no pulse).

#include <verilated.h>
#include "Vven_port92.h"
#include <cstdio>
#include <cstdlib>

static Vven_port92* dut;
static vluint64_t   main_time = 0;
static int          g_fail = 0;
static int          g_checks = 0;

static void tick() {
  // one full clock: drive low then high edge, evaluating combinational between.
  dut->clk = 0; dut->eval(); main_time++;
  dut->clk = 1; dut->eval(); main_time++;
}

// settle combinational outputs without advancing a clock edge (clk held low)
static void settle() {
  dut->clk = 0; dut->eval();
}

static void check(const char* name, bool cond) {
  g_checks++;
  printf("  [%-4s] %s\n", cond ? "PASS" : "FAIL", name);
  if (!cond) g_fail++;
}

// Drive a CPU OUT (write) of `val` to port 0x92, committed on one clock edge.
static void cpu_write(uint8_t val) {
  dut->cs = 1; dut->we = 1; dut->addr = 0x0092; dut->wdata = val;
  tick();
  dut->cs = 0; dut->we = 0;  // bus idle after the access
  settle();
}

// Drive a CPU IN (read) — clock one cycle with cs&!we, return combinational rdata.
static uint8_t cpu_read() {
  dut->cs = 1; dut->we = 0; dut->addr = 0x0092; dut->wdata = 0x00;
  settle();                 // rdata is combinational off outport
  uint8_t r = dut->rdata;
  tick();                   // advance a cycle (read has no side effect)
  dut->cs = 0;
  settle();
  return r;
}

static void do_reset() {
  dut->rst = 1; dut->cs = 0; dut->we = 0; dut->wdata = 0; dut->addr = 0;
  tick();
  dut->rst = 0;
  settle();
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vven_port92;

  // init inputs
  dut->clk = 0; dut->rst = 0; dut->cs = 0; dut->we = 0;
  dut->addr = 0; dut->wdata = 0;
  dut->eval();

  printf("== tb_ven_port92 directed unit self-check ==\n");

  // ---- Check 1: power-on state ----
  // Evaluate combinational outputs at power-on (init value of outport = 0).
  settle();
  check("1.power-on rdata==0x00",  dut->rdata == 0x00);
  check("1.power-on a20_gate==0",  dut->a20_gate == 0);
  check("1.power-on reset_req==0", dut->reset_req == 0);

  // ---- Check 2: write 0x02 sets A20, no reset ----
  cpu_write(0x02);
  check("2.a20_gate==1 after wr 0x02", dut->a20_gate == 1);
  check("2.rdata==0x02",               cpu_read() == 0x02);
  check("2.no reset_req (bit0=0)",     dut->reset_req == 0);

  // ---- Check 3: full byte stored verbatim ----
  cpu_write(0xAA);  // 1010_1010 : bit1=1 (a20), bit0=0
  check("3.rdata==0xAA verbatim",  cpu_read() == 0xAA);
  check("3.a20_gate tracks bit1=1", dut->a20_gate == 1);
  cpu_write(0x00);  // clear everything (bit0 0->0, no edge)
  check("3.rdata==0x00 after clear", cpu_read() == 0x00);
  check("3.a20_gate==0 (bit1=0)",    dut->a20_gate == 0);

  // ---- Check 4: reset_req on bit0 0->1 edge, exactly 1-clk pulse ----
  // outport currently 0x00 (bit0=0). Drive a write with bit0=1, observing the
  // pulse on the committing edge. We single-step the edge manually to confirm
  // the pulse is 1-clock-wide.
  {
    dut->cs = 1; dut->we = 1; dut->addr = 0x0092; dut->wdata = 0x01;
    // before edge: reset_req should still be 0
    settle();
    bool before = (dut->reset_req == 0);
    // commit the write edge
    dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); main_time += 2;
    bool on_edge = (dut->reset_req == 1);  // pulse asserted this cycle
    // next cycle with cs deasserted: pulse must drop
    dut->cs = 0; dut->we = 0;
    dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); main_time += 2;
    bool after = (dut->reset_req == 0);
    settle();
    check("4.reset_req low before edge", before);
    check("4.reset_req pulse on edge",   on_edge);
    check("4.reset_req 1-clk wide",      after);
  }
  // outport now 0x01 (bit0=1).
  check("4.rdata==0x01 after edge", cpu_read() == 0x01);

  // ---- Check 5: no re-pulse when bit0 stays 1 ----
  {
    // write 0x03 (bit0 still 1, also set bit1) — no rising edge on bit0.
    dut->cs = 1; dut->we = 1; dut->addr = 0x0092; dut->wdata = 0x03;
    dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); main_time += 2;
    bool no_pulse = (dut->reset_req == 0);
    dut->cs = 0; dut->we = 0; settle();
    check("5.no re-pulse (bit0 1->1)", no_pulse);
    check("5.rdata==0x03",             cpu_read() == 0x03);
    check("5.a20_gate==1 (bit1=1)",    dut->a20_gate == 1);
  }

  // ---- Check 6: re-arm by clearing bit0 then setting it ----
  cpu_write(0x02);  // bit0 1->0 (no pulse on falling), bit1=1
  check("6.no pulse on bit0 1->0", dut->reset_req == 0);
  {
    dut->cs = 1; dut->we = 1; dut->addr = 0x0092; dut->wdata = 0x03; // bit0 0->1
    dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); main_time += 2;
    bool repulse = (dut->reset_req == 1);
    dut->cs = 0; dut->we = 0; settle();
    check("6.re-pulse after re-arm", repulse);
  }

  // ---- Check 7: PC RESET clears bit0 ONLY, preserves A20 ----
  // outport currently 0x03 (bit1=1 a20, bit0=1). QEMU port92_reset: outport &= ~1.
  do_reset();
  check("7.rst cleared bit0",       (cpu_read() & 0x01) == 0x00);
  check("7.rst preserved a20 bit1", dut->a20_gate == 1);
  check("7.rdata==0x02 post-reset", cpu_read() == 0x02);

  // ---- Check 8: reset re-arms the edge detector ----
  // After the reset cleared bit0, a fresh 0->1 write must fire reset_req.
  {
    dut->cs = 1; dut->we = 1; dut->addr = 0x0092; dut->wdata = 0x03; // bit0 0->1
    dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); main_time += 2;
    bool pulse = (dut->reset_req == 1);
    dut->cs = 0; dut->we = 0; settle();
    check("8.edge fires after reset re-arm", pulse);
  }

  // ---- Check 9: reads have no side effects ----
  {
    uint8_t r1 = cpu_read();
    uint8_t r2 = cpu_read();
    uint8_t r3 = cpu_read();
    check("9.repeated reads stable", (r1 == r2) && (r2 == r3));
    check("9.no reset_req from reads", dut->reset_req == 0);
  }

  // ---- Check 10: cs deasserted => write ignored ----
  {
    uint8_t pre = cpu_read();
    dut->cs = 0; dut->we = 1; dut->addr = 0x0092; dut->wdata = 0x55; // bit0 set
    dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); main_time += 2;
    bool no_pulse = (dut->reset_req == 0);
    settle();
    uint8_t post = cpu_read();
    check("10.no state change (cs=0)", pre == post);
    check("10.no reset_req (cs=0)",    no_pulse);
  }

  dut->final();
  delete dut;

  printf("== %d checks, %d failed ==\n", g_checks, g_fail);
  if (g_fail == 0) {
    printf("RESULT: PASS\n");
    return 0;
  }
  printf("RESULT: FAIL\n");
  return 1;
}
