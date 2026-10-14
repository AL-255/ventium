// Real iobus + production PS/2/FIFO instances. Only ordinary I/O and wire input.
// Four status variants share identical stimuli; there are no hierarchical writes.
`timescale 1ns/1ps
module tb_ps2_aux_status;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n = 0;
  logic cpu_read_do = 0, cpu_write_do = 0, bus_wait = 0;
  logic [15:0] cpu_read_address = 0, cpu_write_address = 0;
  logic [31:0] cpu_write_data = 0;
  wire [31:0] cpu_read_data, bus_writedata;
  wire cpu_read_done, cpu_write_done, bus_read, bus_write;
  wire [15:0] bus_address;
  wire [2:0] bus_datasize;
  logic io_cs = 0, ctl_cs = 0;
  logic dev_kclk = 1, dev_kdata = 1, dev_mclk = 1, dev_mdata = 1;
  wire [3:0] kclk, kdata, mclk, mdata, kirq, mirq;
  wire [7:0] read_data [4];
  int variant = 0, scenario = 0, source_mask = 0, half_period = 64;
  int wait_cycles = 0, translate = 1, interrupts = 1;
  int read_strobes = 0, write_strobes = 0, consumed = 0;
  int cycles = 0;

  always @(posedge clk) begin
    // Match the registered selects in rtl/system.v, not a direct 8042 shortcut.
    io_cs <= bus_address[15:3] == 13'h00c;
    ctl_cs <= bus_address[15:4] == 12'h009;
    if (rst_n && bus_read && io_cs) read_strobes <= read_strobes + 1;
    if (rst_n && bus_write && io_cs) write_strobes <= write_strobes + 1;
    cycles <= cycles + 1;
    if (cycles > 5000000) $fatal(1, "PS2-AUX-TIMEOUT");
    if (rst_n && cycles > 100) begin
      // A status-only change must not alter physical device control or IRQs.
      if (kirq != {4{kirq[0]}} || mirq != {4{mirq[0]}} ||
          kclk != {4{kclk[0]}} || mclk != {4{mclk[0]}} ||
          kdata != {4{kdata[0]}} || mdata != {4{mdata[0]}})
        $fatal(1, "PS2-AUX-STATE-DIVERGENCE");
    end
  end

  iobus bus_dut (
    .clk(clk), .reset(!rst_n), .cpu_read_do(cpu_read_do),
    .cpu_read_address(cpu_read_address), .cpu_read_length(3'd1),
    .cpu_read_data(cpu_read_data), .cpu_read_done(cpu_read_done),
    .cpu_write_do(cpu_write_do), .cpu_write_address(cpu_write_address),
    .cpu_write_length(3'd1), .cpu_write_data(cpu_write_data),
    .cpu_write_done(cpu_write_done), .bus_address(bus_address),
    .bus_write(bus_write), .bus_read(bus_read), .bus_io32(1'b0),
    .bus_datasize(bus_datasize), .bus_writedata(bus_writedata),
    .bus_readdata({24'd0, read_data[variant]}), .bus_wait(bus_wait)
  );

`define AUX_INSTANCE(TYPE, NAME, N) \
  TYPE NAME ( \
    .clk(clk), .rst_n(rst_n), .irq_keyb(kirq[N]), .irq_mouse(mirq[N]), \
    .io_address(bus_address[3:0]), .io_read(bus_read), \
    .io_readdata(read_data[N]), .io_write(bus_write), \
    .io_writedata(bus_writedata[7:0]), .io_cs(io_cs), .ctl_cs(ctl_cs), \
    .output_a20_enable(), .output_reset_n(), .a20_enable(), \
    .ps2_kbclk(dev_kclk & kclk[N]), .ps2_kbdat(dev_kdata & kdata[N]), \
    .ps2_kbclk_out(kclk[N]), .ps2_kbdat_out(kdata[N]), \
    .ps2_mouseclk(dev_mclk & mclk[N]), .ps2_mousedat(dev_mdata & mdata[N]), \
    .ps2_mouseclk_out(mclk[N]), .ps2_mousedat_out(mdata[N]) \
  );
  `AUX_INSTANCE(ps2_aux_parent, parent_dut, 0)
  `AUX_INSTANCE(ps2_aux_fixed, fixed_dut, 1)
  `AUX_INSTANCE(ps2_aux_zero, zero_dut, 2)
  `AUX_INSTANCE(ps2_aux_one, one_dut, 3)
`undef AUX_INSTANCE

  task automatic idle(input int count);
    repeat (count) @(negedge clk);
  endtask

  task automatic write_port(input logic [15:0] address, input logic [7:0] value);
    int before_count, watchdog;
    before_count = write_strobes;
    cpu_write_address = address;
    cpu_write_data = {24'd0, value};
    cpu_write_do = 1;
    bus_wait = wait_cycles != 0;
    idle(1);
    cpu_write_do = 0;
    watchdog = 0;
    while (!bus_write && watchdog < 20) begin idle(1); watchdog++; end
    if (!bus_write) $fatal(1, "PS2-AUX-NO-WRITE-STROBE");
    if (wait_cycles != 0) begin idle(wait_cycles + 1); bus_wait = 0; end
    watchdog = 0;
    while (!cpu_write_done && watchdog < 100) begin idle(1); watchdog++; end
    if (!cpu_write_done || write_strobes != before_count + 1)
      $fatal(1, "PS2-AUX-WRITE-TIMEOUT-OR-DUPLICATE");
    idle(2);
  endtask

  task automatic read_port(input logic [15:0] address, output logic [7:0] value);
    int before_count, watchdog;
    before_count = read_strobes;
    cpu_read_address = address;
    cpu_read_do = 1;
    bus_wait = wait_cycles != 0;
    idle(1);
    cpu_read_do = 0;
    watchdog = 0;
    while (!bus_read && watchdog < 20) begin idle(1); watchdog++; end
    if (!bus_read) $fatal(1, "PS2-AUX-NO-READ-STROBE");
    if (wait_cycles != 0) begin idle(wait_cycles + 2); bus_wait = 0; end
    watchdog = 0;
    while (!cpu_read_done && watchdog < 100) begin idle(1); watchdog++; end
    if (!cpu_read_done || read_strobes != before_count + 1)
      $fatal(1, "PS2-AUX-READ-TIMEOUT-OR-DUPLICATE");
    value = cpu_read_data[7:0];
    idle(2);
  endtask

  task automatic wire_cell(input bit mouse, input bit value);
    if (mouse) begin dev_mdata = value; dev_mclk = 1; end
    else begin dev_kdata = value; dev_kclk = 1; end
    idle(half_period);
    if (mouse) dev_mclk = 0; else dev_kclk = 0;
    idle(half_period);
  endtask

  task automatic wire_byte(input bit mouse, input logic [7:0] value);
    bit parity;
    if (mouse ? !mclk[0] : !kclk[0]) $fatal(1, "PS2-AUX-DEVICE-INHIBITED");
    parity = 1;
    wire_cell(mouse, 0);
    for (int b = 0; b < 8; b++) begin
      parity ^= value[b];
      wire_cell(mouse, value[b]);
    end
    wire_cell(mouse, parity);
    wire_cell(mouse, 1);
    if (mouse) begin dev_mdata = 1; dev_mclk = 1; end
    else begin dev_kdata = 1; dev_kclk = 1; end
    idle(128);
  endtask

  task automatic enqueue(input bit mouse, input logic [7:0] value);
    if ((source_mask & (mouse ? 2 : 1)) != 0) begin
      // Documented controller output-buffer commands, not device commands.
      write_port(16'h64, mouse ? 8'hd3 : 8'hd2);
      write_port(16'h60, value);
      idle(32);
    end else wire_byte(mouse, value);
  endtask

  function automatic logic [7:0] expected_keyboard(input logic [7:0] raw_value);
    if (translate == 0 || (source_mask & 1) != 0) return raw_value;
    case (raw_value)
      8'h5a: return 8'h1c;
      8'h76: return 8'h01;
      default: return 8'hff; // No unspecified translation oracle.
    endcase
  endfunction

  task automatic check_head(input bit mouse);
    idle(8);
    if (!fixed_dut.status_outputbufferfull ||
        fixed_dut.status_mousebufferfull != mouse)
      $fatal(1, "PS2-AUX-PRECONDITION selected=%0d expected=%0d",
             fixed_dut.status_mousebufferfull, mouse);
  endtask

  task automatic expect_byte(input bit mouse, input logic [7:0] expected);
    logic [7:0] status, value;
    bit observed_kirq, observed_mirq;
    check_head(mouse);
    read_port(16'h64, status);
    observed_kirq = kirq[variant];
    observed_mirq = mirq[variant];
    read_port(16'h60, value);
    $display("PS2-AUX-BYTE n=%0d source=%0d status=%02x data=%02x expected=%02x irq=%0d%0d",
             consumed, mouse, status, value, expected, observed_mirq, observed_kirq);
    if (value != expected || !status[0] || status[7:6] != 0)
      $fatal(1, "PS2-AUX-DATA-OR-STATUS-ERROR");
    if (observed_mirq != (interrupts != 0 && mouse) ||
        observed_kirq != (interrupts != 0 && !mouse))
      $fatal(1, "PS2-AUX-IRQ-ERROR");
    if (status[5] != mouse)
      $fatal(1, "PS2-AUX-ORIGIN-MISMATCH variant=%0d scenario=%0d status=%02x data=%02x source=%0d",
             variant, scenario, status, value, mouse);
    consumed++;
  endtask

  task automatic empty_check;
    logic [7:0] status;
    idle(8);
    read_port(16'h64, status);
    // AUX is only meaningful while OBF is set. Do not invent an empty-AUX
    // contract merely to reject a constant-one mutation.
    if (status[0] || status[7:6] != 0 || kirq[variant] || mirq[variant] ||
        !fixed_dut.keyb_fifo_empty || !fixed_dut.mouse_fifo_empty)
      $fatal(1, "PS2-AUX-NOT-DRAINED status=%02x", status);
  endtask

  logic [7:0] prior_status;
  initial begin
    if (!$value$plusargs("variant=%d", variant) || variant < 0 || variant > 3 ||
        !$value$plusargs("scenario=%d", scenario) || scenario < 0 || scenario > 6 ||
        !$value$plusargs("sources=%d", source_mask) || source_mask < 0 || source_mask > 3 ||
        !$value$plusargs("half=%d", half_period) || half_period < 32 || half_period > 2917 ||
        !$value$plusargs("wait=%d", wait_cycles) || wait_cycles < 0 || wait_cycles > 31 ||
        !$value$plusargs("translate=%d", translate) || translate < 0 || translate > 1 ||
        !$value$plusargs("interrupts=%d", interrupts) || interrupts < 0 || interrupts > 1)
      $fatal(1, "PS2-AUX-BAD-ARGUMENTS");
    idle(32); rst_n = 1; idle(64);
    write_port(16'h64, 8'h60);
    write_port(16'h60, (translate ? 8'h40 : 8'h00) | (interrupts ? 8'h03 : 8'h00));
    idle(32); empty_check();
    case (scenario)
      0: begin enqueue(0, 8'h5a); expect_byte(0, expected_keyboard(8'h5a)); end
      1: begin enqueue(1, 8'h08); expect_byte(1, 8'h08); end
      2, 4: begin
        enqueue(0, 8'h5a); check_head(0);
        if (scenario == 4) begin
          read_port(16'h64, prior_status);
          if ((prior_status & 8'h21) != 8'h01) $fatal(1, "PS2-AUX-INITIAL-STATUS");
        end
        enqueue(1, 8'h08);
        if (fixed_dut.mouse_fifo_empty) $fatal(1, "PS2-AUX-MISSING-QUEUED-MOUSE");
        expect_byte(0, expected_keyboard(8'h5a)); expect_byte(1, 8'h08);
      end
      3: begin
        enqueue(1, 8'h08); check_head(1); enqueue(0, 8'h5a);
        expect_byte(1, 8'h08); expect_byte(0, expected_keyboard(8'h5a));
      end
      5: begin
        enqueue(0, 8'h5a); check_head(0); enqueue(1, 8'h08);
        enqueue(0, 8'h76); enqueue(1, 8'h17);
        expect_byte(0, expected_keyboard(8'h5a));
        expect_byte(1, 8'h08); expect_byte(1, 8'h17);
        expect_byte(0, expected_keyboard(8'h76));
      end
      6: begin
        if (source_mask != 0) $fatal(1, "PS2-AUX-SIMULTANEOUS-REQUIRES-WIRES");
        fork wire_byte(0, 8'h5a); wire_byte(1, 8'h08); join
        // Both FIFOs become visible together; the existing arbiter picks mouse.
        expect_byte(1, 8'h08); expect_byte(0, expected_keyboard(8'h5a));
      end
      default: $fatal(1, "PS2-AUX-INVALID-SCENARIO");
    endcase
    empty_check();
    // Ordinary reset while both queues are populated must clear ownership.
    enqueue(0, 8'h5a); enqueue(1, 8'h08);
    rst_n = 0; idle(32); rst_n = 1; idle(64); empty_check();
    $display("PS2-AUX-OK variant=%0d scenario=%0d sources=%0d half=%0d wait=%0d translate=%0d interrupts=%0d consumed=%0d cycles=%0d",
             variant, scenario, source_mask, half_period, wait_cycles, translate,
             interrupts, consumed, cycles);
    $finish;
  end
endmodule
