// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// tb_fxabort.sv — the focused fragment-engine ABORT/RESET testbench. Wraps
// ventium_top (the whole core) with a small byte memory whose ack timing is
// programmable, so the generic page-crossing fragment engine can be observed
// hierarchically (dut.u_core.fx_*) while the fxprog image drives every
// fragment phase from the ISA level.
//
// What it proves (the ISA-unreachable half of the abort matrix; the
// differential half lives in verif/sys/tests/pxfrag + the pxc04 family):
//   * RESET during each active phase (read frag1/frag2, write probe/fragA/
//     fragB): the engine returns to the one idle state (fx_act=0, ph=0) and
//     no output shaping stays armed. The negedge sample catches even the
//     single-cycle write probe.
//   * FAULT ABORT at every reachable phase, with same-cycle (0) and delayed
//     (1, 3) acks: write probe (page 2 not-present, armed), read frag2
//     (page 2 not-present, armed), read frag1 (page 1 not-present: the
//     initial request faults BEFORE the engine engages -- proven by a pulse
//     with fx_act==0 and by the engagement count). Post-probe write
//     fragments cannot fault by construction (the probe leaves both pages
//     TLB-resident + writable, interrupts are sampled at instruction
//     boundaries, segment enforcement is off by default) -- their abort
//     machinery is the reset sweep above.
//   * no stale fragment shaping after an abort until the engine has gone
//     idle and a fresh sequence has started (the #PF delivery's traffic is
//     never redirected), and a fresh write sequence starts at the probe.
//
// The RTL's own sim-only checks (incl. the abort-cycle kill assertion) run
// in this build; any $error from them fails the gate via the log grep.

`timescale 1ns/1ps
module tb_fxabort;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic        mem_req, mem_we;
  logic [31:0] mem_addr, mem_wdata, mem_rdata;
  logic [3:0]  mem_wstrb;
  logic        mem_ack;

  ventium_top dut (
      .clk(clk), .rst_n(rst_n),
      .init_eip(32'h0), .init_esp(32'h0),
      .boot_mode(1'b1), .bus_mode(1'b0), .cycle_mode(1'b0),
      .errata_en(5'b0), .cpu_hung(),
      .proxy_en(1'b0), .syscall_active(), .syscall_n(),
      .syscall_resume_eip(32'h0), .syscall_eax(32'h0),
      .syscall_apply_gs(1'b0), .syscall_gs_base(32'h0),
      .syscall_arg_eax(), .syscall_arg_ebx(), .syscall_arg_ecx(),
      .syscall_arg_edx(), .syscall_arg_esi(), .syscall_arg_edi(),
      .syscall_arg_ebp(),
      .cosim_en(1'b0), .io_req(), .io_we(), .io_addr(), .io_size(),
      .io_wdata(), .io_rdata(32'h0), .io_ack(1'b0),
      .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr),
      .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
      .mem_rdata(mem_rdata), .mem_ack(mem_ack));

  // ---- engine observation (hierarchical, read-only) ----
  wire        fx_act     = dut.u_core.fx_act;
  wire        fx_wr      = dut.u_core.fx_wr;
  wire [1:0]  fx_ph      = dut.u_core.fx_ph;
  wire        fx_abort   = dut.u_core.fx_abort_q;
  wire [31:0] fx_cr2     = dut.u_core.creg2;
  wire        fx_shaped  = dut.u_core.fx_probe_e | dut.u_core.fx_redirect_e
                         | dut.u_core.fx_shift_e | dut.u_core.fx_maskA_e
                         | dut.u_core.fx_merge_e | dut.u_core.fx_rdfrag2_e;

  // ---- memory: 2 MiB, byte array, programmable ack delay ----
  localparam int MEMBYTES = 2 * 1024 * 1024;
  logic [7:0] mem [0:MEMBYTES-1];
  integer fxdly;          // ack delay in cycles; 0 = same-cycle (canonical TB)
  logic   pend;
  integer dcnt;
  logic   ack_reg;
  logic [31:0] cap_addr, cap_wdata;
  logic [3:0]  cap_wstrb;
  logic        cap_we;

  initial begin
    for (int i = 0; i < MEMBYTES; i++) mem[i] = 8'h00;
    $readmemh("fxprog.hex", mem, 32'h000F0000);
  end

  assign mem_rdata = {mem[mem_addr+3], mem[mem_addr+2],
                      mem[mem_addr+1], mem[mem_addr]};
  assign mem_ack   = (fxdly == 0) ? mem_req : ack_reg;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pend <= 1'b0; ack_reg <= 1'b0; dcnt <= 0;
    end else begin
      ack_reg <= 1'b0;
      if (fxdly != 0) begin
        if (!pend && mem_req) begin
          pend     <= 1'b1;
          dcnt     <= fxdly;
          cap_addr <= mem_addr; cap_wdata <= mem_wdata;
          cap_wstrb <= mem_wstrb; cap_we <= mem_we;
        end else if (pend) begin
          if (dcnt <= 1) begin
            ack_reg <= 1'b1;
            pend    <= 1'b0;
            if (cap_we) begin
              if (cap_wstrb[0]) mem[cap_addr+0] <= cap_wdata[7:0];
              if (cap_wstrb[1]) mem[cap_addr+1] <= cap_wdata[15:8];
              if (cap_wstrb[2]) mem[cap_addr+2] <= cap_wdata[23:16];
              if (cap_wstrb[3]) mem[cap_addr+3] <= cap_wdata[31:24];
            end
          end else dcnt <= dcnt - 1;
        end
      end
    end
  end
  // same-cycle-ack writes apply at the accepting edge
  always_ff @(posedge clk) begin
    if (rst_n && fxdly == 0 && mem_req && mem_we) begin
      if (mem_wstrb[0]) mem[mem_addr+0] <= mem_wdata[7:0];
      if (mem_wstrb[1]) mem[mem_addr+1] <= mem_wdata[15:8];
      if (mem_wstrb[2]) mem[mem_addr+2] <= mem_wdata[23:16];
      if (mem_wstrb[3]) mem[mem_addr+3] <= mem_wdata[31:24];
    end
  end

  // ---- helpers ----
  integer errors = 0;
  task automatic hw_reset();
    @(negedge clk); rst_n = 1'b0;
    repeat (6) @(posedge clk);
    @(negedge clk); rst_n = 1'b1;
    @(posedge clk);
  endtask

  task automatic fail(input string msg);
    errors++;
    $display("FXABORT-FAIL: %s", msg);
  endtask

  // ---- reset sweep: reset during each active phase ----
  task automatic reset_at_phase(input string name, input logic wr, input logic [1:0] ph);
    integer cycles;
    logic hit;
    hw_reset();
    hit = 0; cycles = 0;
    while (!hit && cycles < 200000) begin
      @(negedge clk);
      if (fx_act && fx_wr == wr && fx_ph == ph) hit = 1;
      cycles++;
    end
    if (!hit) begin
      fail({name, ": phase never entered"});
      return;
    end
    // the phase is live THIS half-cycle: reset now
    rst_n = 1'b0;
    repeat (3) @(posedge clk);
    @(negedge clk); rst_n = 1'b1;
    repeat (4) @(posedge clk);
    if (fx_act !== 1'b0 || fx_ph !== 2'd0)
      fail($sformatf("%s: engine not idle after reset (act=%0d ph=%0d)", name, fx_act, fx_ph));
    else if (fx_shaped !== 1'b0)
      fail({name, ": fragment shaping still armed after reset"});
    else
      $display("FXABORT-RESET %-8s OK (engine idle + blank after reset mid-phase)", name);
  endtask

  // ---- fault sweep: abort at every reachable phase, one ack-delay setting ----
  // Sampled on the negedge (mid-cycle, fully settled): the abort pulse is
  // high for exactly one cycle, the shaping kill covers that same cycle, and
  // the engine is idle from the cycle after. start_fault pulses fx_abort_q
  // for EVERY fault, so a pulse with fx_act==0 is the pre-engagement
  // (read-frag1) fault; pulses with fx_act==1 are the engaged aborts
  // (read-frag2 armed, write probe armed).
  task automatic fault_sweep(input integer dly);
    integer cycles, engagements, pulses, eng_aborts, errs0;
    logic prev_act, stale, done, seen_f2, seen_f1, seen_wf, fresh;
    fxdly = dly;
    errs0 = errors;
    hw_reset();
    cycles = 0; engagements = 0; pulses = 0; eng_aborts = 0;
    prev_act = 0; stale = 0; done = 0;
    seen_f2 = 0; seen_f1 = 0; seen_wf = 0;
    while (!done && cycles < 400000) begin
      @(negedge clk);
      cycles++;
      if (fx_abort) begin
        pulses++;
        stale = 1;
        if (fx_act) eng_aborts++;
        $display("FXABORT-FAULT dly=%0d pulse #%0d cr2=%08h engaged=%0d (ph=%0d wr=%0d)",
                 dly, pulses, fx_cr2, fx_act, fx_ph, fx_wr);
        if (fx_cr2 == 32'h00007000 && fx_act)  seen_f2 = 1;
        if (fx_cr2 == 32'h0000D000 && fx_act)  seen_wf = 1;
        if (fx_cr2 == 32'h00004FFE && !fx_act) seen_f1 = 1;
      end
      fresh = (!prev_act && fx_act);
      // a fresh engagement's first-cycle shaping is legitimate; anything
      // else while stale means the aborted sequence is still driving
      if (stale && fx_shaped && !fresh)
        fail($sformatf("dly=%0d: stale fragment shaping after the abort (before any fresh engagement)", dly));
      if (fresh) begin
        engagements++;
        stale = 0;
        // a fresh write sequence must start at its first phase (the probe);
        // reads with a same-cycle ack legitimately land in frag2 already
        if (fx_wr && fx_ph != 2'd0)
          fail($sformatf("dly=%0d: a write sequence engaged at ph=%0d (not the probe)", dly, fx_ph));
      end
      prev_act = fx_act;
      // (the boot zeroes the slot too -- match the sentinel VALUE, not the address)
      if (mem_req && mem_we && mem_addr == 32'h0001F000
          && mem_wdata == 32'hD00DF00D) done = 1;
    end
    if (!done)                fail($sformatf("dly=%0d: DONE marker never written (deadlock?)", dly));
    if (engagements != 7)     fail($sformatf("dly=%0d: engagements=%0d, want 7 (R_OK, R_F2 x2, R_F1-restart, W_OK, W_F x2)", dly, engagements));
    if (pulses != 3 || eng_aborts != 2)
                              fail($sformatf("dly=%0d: pulses=%0d engaged=%0d, want 3 pulses / 2 engaged aborts", dly, pulses, eng_aborts));
    if (!seen_f2 || !seen_wf || !seen_f1)
                              fail($sformatf("dly=%0d: abort coverage f2=%0d wf=%0d f1_idle=%0d", dly, seen_f2, seen_wf, seen_f1));
    if (done && engagements == 7 && pulses == 3 && eng_aborts == 2
        && seen_f2 && seen_wf && seen_f1 && errors == errs0)
      $display("FXABORT-FAULT dly=%0d OK (7 engagements, 2 engaged aborts + 1 idle pulse, no stale shaping, clean completion)", dly);
  endtask

  initial begin
    fxdly = 2;   // the reset sweep needs observable (multi-cycle) phases
    hw_reset();
    reset_at_phase("rfrag1", 1'b0, 2'd0);
    reset_at_phase("rfrag2", 1'b0, 2'd1);
    reset_at_phase("wprobe", 1'b1, 2'd0);
    reset_at_phase("wfragA", 1'b1, 2'd1);
    reset_at_phase("wfragB", 1'b1, 2'd2);
    fault_sweep(0);
    fault_sweep(1);
    fault_sweep(3);
    if (errors == 0) $display("FXABORT-GATE-OK");
    else             $display("FXABORT-GATE-FAIL (%0d errors)", errors);
    $finish;
  end

endmodule
