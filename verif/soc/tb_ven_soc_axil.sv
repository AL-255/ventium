// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/soc/tb_ven_soc_axil.sv — unit gate for ven_soc_axil (KV260 PS<->PL bridge, F2).
// A small AXI4-Lite master BFM drives the slave: control/config register round-trips,
// the retire-counter torn-read-free snapshot, IDENT, core_rst_n = aresetn & CORE_RUN,
// the flush_all W1P pulse, and the CRUX — the port-I/O capture/release handshake: a
// "core" task asserts io_req and HOLDS it (like S_IO), the slave keeps io_ack=0 and
// raises the IRQ; the "PS" reads the captured request, writes IO_RDATA, pulses
// IO_CTRL.ACK, and the core must then see io_ack for EXACTLY one cycle with the right
// data. Prints SOCAXIL-GATE-OK / -FAIL.

module tb_ven_soc_axil;
  logic clk=0, aresetn=0;
  always #5 clk = ~clk;

  // AXI-Lite master signals
  logic [15:0] awaddr=0; logic awvalid=0, awready;
  logic [31:0] wdata=0;  logic [3:0] wstrb=0; logic wvalid=0, wready;
  logic [1:0]  bresp;    logic bvalid; logic bready=1;
  logic [15:0] araddr=0; logic arvalid=0, arready;
  logic [31:0] rdata;    logic [1:0] rresp; logic rvalid; logic rready=1;

  // control/config out
  logic core_rst_n; logic [31:0] init_eip, init_esp; logic boot_mode, cycle_mode, bus_mode;
  logic l1axi_en, proxy_en, cosim_en, soc_en; logic [4:0] errata_en; logic flush_all;
  // status in
  logic cpu_hung=0, bus_err=0; logic [63:0] retire_n=64'd0;
  // io bus
  logic io_req=0, io_we=0; logic [15:0] io_addr=0; logic [2:0] io_size=0; logic [31:0] io_wdata=0;
  logic [31:0] io_rdata; logic io_ack;
  // F3 interrupt-injection seam
  logic intr_out; logic [7:0] intr_vec; logic inta=0;
  logic irq_out;

  ven_soc_axil dut (
    .clk(clk), .aresetn(aresetn),
    .s_axil_awaddr(awaddr), .s_axil_awprot(3'd0), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
    .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
    .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
    .s_axil_araddr(araddr), .s_axil_arprot(3'd0), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
    .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready),
    .core_rst_n(core_rst_n), .init_eip(init_eip), .init_esp(init_esp), .boot_mode(boot_mode),
    .cycle_mode(cycle_mode), .bus_mode(bus_mode), .l1axi_en(l1axi_en), .proxy_en(proxy_en),
    .cosim_en(cosim_en), .soc_en(soc_en), .errata_en(errata_en), .flush_all(flush_all),
    .cpu_hung(cpu_hung), .bus_err(bus_err), .retire_n(retire_n),
    .io_req(io_req), .io_we(io_we), .io_addr(io_addr), .io_size(io_size), .io_wdata(io_wdata),
    .io_rdata(io_rdata), .io_ack(io_ack),
    .intr_out(intr_out), .intr_vec(intr_vec), .inta(inta),
    .irq_out(irq_out)
  );

  int errors = 0;
  task automatic chk(input string what, input logic [31:0] got, exp);
    if (got !== exp) begin $display("  FAIL %s: got %08x exp %08x", what, got, exp); errors++; end
    else $display("  ok   %s = %08x", what, got);
  endtask

  task automatic axil_write(input logic [15:0] a, input logic [31:0] d, input logic [3:0] strb);
    @(negedge clk); awaddr<=a; awvalid<=1'b1; wdata<=d; wstrb<=strb; wvalid<=1'b1;
    do @(posedge clk); while (!(awready && wready));
    @(negedge clk); awvalid<=1'b0; wvalid<=1'b0;
  endtask

  task automatic axil_read(input logic [15:0] a, output logic [31:0] d);
    @(negedge clk); araddr<=a; arvalid<=1'b1;
    do @(posedge clk); while (!arready);
    @(negedge clk); arvalid<=1'b0;
    do @(posedge clk); while (!rvalid); #1; d = rdata;
  endtask

  // the CORE side of an IN/OUT: assert io_req and HOLD it until io_ack (mirrors S_IO).
  task automatic core_io(input logic we, input logic [15:0] port, input logic [2:0] sz,
                         input logic [31:0] wd, output logic [31:0] rd);
    int g;
    @(negedge clk); io_req<=1'b1; io_we<=we; io_addr<=port; io_size<=sz; io_wdata<=wd;
    g=0;
    forever begin @(posedge clk); #1;
      if (io_ack) begin rd = io_rdata; break; end
      if (++g > 500) begin $display("  FAIL core_io port %04x: no io_ack (deadlock)", port); errors++; rd=32'hx; break; end
    end
    @(negedge clk); io_req<=1'b0;
  endtask

  // the PS side: wait for the request (via irq_out), service it, ACK + clear IRQ.
  task automatic ps_service_io(input logic [31:0] ret_val, input logic exp_we, input logic [15:0] exp_port);
    logic [31:0] t; int g;
    g=0; do begin @(posedge clk); if (++g>500) begin $display("  FAIL ps: no irq"); errors++; return; end end while (!irq_out);
    axil_read(16'h24, t); chk("PS sees io_addr", t, {16'd0, exp_port});
    axil_read(16'h20, t); chk("PS sees io is_write", t[1], exp_we);
    if (!exp_we) axil_write(16'h30, ret_val, 4'hF);   // IO_RDATA (only meaningful for IN)
    axil_write(16'h34, 32'h3, 4'hF);                  // IO_CTRL: ACK | IRQ_CLR
  endtask

  logic [31:0] d, rdv;
  initial begin
    repeat(4) @(posedge clk); aresetn<=1'b1; @(posedge clk);

    $display("[1] identity + reset defaults");
    axil_read(16'h7C, d); chk("IDENT", d, 32'h5654_4D43);
    chk("core_rst_n low at reset (CORE_RUN=0)", core_rst_n, 1'b0);

    $display("[2] config register round-trips");
    axil_write(16'h08, 32'hDEAD_BEEF, 4'hF); chk("INIT_EIP out", init_eip, 32'hDEAD_BEEF);
    axil_read (16'h08, d);                    chk("INIT_EIP rb", d, 32'hDEAD_BEEF);
    axil_write(16'h0C, 32'h0008_0000, 4'hF); chk("INIT_ESP out", init_esp, 32'h0008_0000);
    // MODE: boot_mode=1, l1axi_en=1, errata_en=0x1F
    axil_write(16'h10, 32'h0000_1F09, 4'hF);
    chk("boot_mode", boot_mode, 1'b1); chk("l1axi_en", l1axi_en, 1'b1);
    chk("cosim_en", cosim_en, 1'b0);   chk("errata_en", errata_en, 5'h1F);
    axil_read(16'h10, d); chk("MODE rb", d, 32'h0000_1F09);

    $display("[3] CORE_RUN gates core_rst_n; IRQ enable");
    axil_write(16'h00, 32'h0000_0101, 4'hF);   // CORE_RUN=1, IRQ_EN=1
    chk("core_rst_n high after CORE_RUN", core_rst_n, 1'b1);

    $display("[4] flush_all W1P pulse");
    fork
      axil_write(16'h00, 32'h0000_0103, 4'hF); // CORE_RUN=1, FLUSH_ALL_REQ=1, IRQ_EN=1
      begin : catch_flush
        int g; logic seen=0; g=0;
        forever begin @(posedge clk); #1; if (flush_all) seen=1'b1; g=g+1; if (seen || g>20) break; end
        chk("flush_all pulsed", {31'd0, seen}, 32'd1);
      end
    join

    $display("[5] retire counter snapshot (torn-read-free)");
    retire_n <= 64'h1234_5678_9ABC_DEF0;
    @(posedge clk);
    axil_read(16'h14, d); chk("RETIRE_LO", d, 32'h9ABC_DEF0);
    axil_read(16'h18, d); chk("RETIRE_HI (snapshot)", d, 32'h1234_5678);

    $display("[6] port-I/O bridge: OUT (core stalls until PS ACK)");
    fork
      core_io(1'b1, 16'h0070, 3'd0, 32'h0000_00A5, rdv);   // OUT 0xA5 -> port 0x70
      ps_service_io(32'h0, 1'b1, 16'h0070);
    join
    chk("OUT completed (io_ack seen)", 32'd1, 32'd1);

    $display("[7] port-I/O bridge: IN (PS returns 0xC3, core latches it)");
    fork
      core_io(1'b0, 16'h0060, 3'd0, 32'h0, rdv);           // IN from port 0x60
      ps_service_io(32'h0000_00C3, 1'b0, 16'h0060);
    join
    chk("IN returned the PS value", rdv, 32'h0000_00C3);
    @(posedge clk); chk("irq cleared after service", irq_out, 1'b0);

    $display("[8] status reflects cpu_hung / bus_err");
    cpu_hung <= 1'b1; bus_err <= 1'b1; @(posedge clk);
    axil_read(16'h04, d); chk("STATUS cpu_hung|bus_err", d[1:0], 2'b11);

    $display("[9] F3 PS->core interrupt-injection seam (R_INTR + MODE.SOCEN)");
    // default: never written -> fully inert (soc_en low, no level, vector 0)
    chk("intr_out idle low (reset)", intr_out, 1'b0);
    chk("soc_en idle low (reset)", soc_en, 1'b0);
    axil_read(16'h38, d); chk("R_INTR reset value", d, 32'h0);
    // MODE bit 6 drives soc_en (and only bit 6 — earlier MODE writes left it 0)
    axil_write(16'h10, 32'h0000_1F49, 4'hF);   // [2] MODE value + SOCEN (bit 6)
    chk("soc_en out (MODE.SOCEN)", soc_en, 1'b1);
    axil_read(16'h10, d); chk("MODE rb with SOCEN", d, 32'h0000_1F49);
    // write {assert, vector} -> intr level + staged vector observable at the core pins
    axil_write(16'h38, 32'h0000_0109, 4'hF);   // vector 0x09 (IRQ1 @ base 08h), ASSERT
    chk("intr_out asserted", intr_out, 1'b1);
    chk("intr_vec staged", intr_vec, 8'h09);
    axil_read(16'h38, d); chk("R_INTR rb {assert,vec}", d, 32'h0000_0109);
    // the core's 1-clock inta strobe -> pending clears in HW + seen latches
    @(negedge clk); inta<=1'b1; @(negedge clk); inta<=1'b0; @(posedge clk); #1;
    chk("intr_out dropped by inta", intr_out, 1'b0);
    axil_read(16'h38, d); chk("R_INTR rb after inta (seen=1 assert=0)", d, 32'h0000_0209);
    axil_read(16'h70, d); chk("IRQ_STAT[1] inta-seen", d[1], 1'b1);
    // W1C via IRQ_STAT[1]
    axil_write(16'h70, 32'h0000_0002, 4'hF);
    axil_read(16'h38, d); chk("inta-seen W1C (IRQ_STAT)", d, 32'h0000_0009);
    // INTA_IRQ_EN: the next inta raises irq_out (GIC notify) until W1C
    axil_write(16'h38, 32'h0001_0170, 4'hF);   // vec 0x70, ASSERT, INTA_IRQ_EN
    chk("intr_out asserted (2nd inject)", intr_out, 1'b1);
    chk("irq_out low before inta", irq_out, 1'b0);
    @(negedge clk); inta<=1'b1; @(negedge clk); inta<=1'b0; @(posedge clk); #1;
    chk("irq_out raised by inta (INTA_IRQ_EN)", irq_out, 1'b1);
    axil_write(16'h38, 32'h0000_0200, 4'h2);   // W1C seen via R_INTR[9] (wstrb[1] only)
    @(posedge clk);
    chk("irq_out cleared by R_INTR[9] W1C", irq_out, 1'b0);
    // the PS can withdraw an un-taken assert (PIC IMR masked it)
    axil_write(16'h38, 32'h0000_0108, 4'hF);
    chk("re-assert (vec 0x08)", intr_out, 1'b1);
    axil_write(16'h38, 32'h0000_0008, 4'hF);
    chk("PS deassert withdraws the level", intr_out, 1'b0);

    if (errors==0) $display("SOCAXIL-GATE-OK (control + status + retire + IO-bridge handshake all pass)");
    else           $display("SOCAXIL-GATE-FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin #200000; $display("SOCAXIL-GATE-FAIL (timeout)"); $finish; end
endmodule
