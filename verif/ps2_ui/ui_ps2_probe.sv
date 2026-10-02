// MicroTB wrapper: unchanged production RTL; probes are read-only assignments.
// No force, deposit, hierarchical write, alternate FIFO, or controller fix.
`default_nettype none
module ui_ps2_probe (
    input wire clk, rst_n,
    input wire [3:0] io_address,
    input wire io_read, io_write, io_cs, ctl_cs,
    input wire [7:0] io_writedata,
    output wire [7:0] io_readdata,
    input wire ps2_kbclk, ps2_kbdat, ps2_mouseclk, ps2_mousedat,
    output wire ps2_kbclk_out, ps2_kbdat_out, ps2_mouseclk_out, ps2_mousedat_out,
    output wire irq_keyb, irq_mouse, output_a20_enable, output_reset_n, a20_enable,
    input wire [5:0] inspect_index,
    output wire [7:0] inspect_memory,
    output wire [3:0] controller_state,
    output wire synced_clock, synced_data, recv_final, translated, escape_state,
    output wire autoack, reply_done, write_request, fifo_full, fifo_empty,
    output wire fifo_read_request, self_test, output_full, input_full, timeout_event,
    output wire [5:0] write_index, read_index, fifo_used,
    output wire [7:0] recv_raw, translated_value, produced_value, fifo_q
);
    ps2 dut (
        .clk(clk), .rst_n(rst_n), .irq_keyb(irq_keyb), .irq_mouse(irq_mouse),
        .io_address(io_address), .io_read(io_read), .io_readdata(io_readdata),
        .io_write(io_write), .io_writedata(io_writedata), .io_cs(io_cs), .ctl_cs(ctl_cs),
        .output_a20_enable(output_a20_enable), .output_reset_n(output_reset_n),
        .a20_enable(a20_enable), .ps2_kbclk(ps2_kbclk), .ps2_kbdat(ps2_kbdat),
        .ps2_kbclk_out(ps2_kbclk_out), .ps2_kbdat_out(ps2_kbdat_out),
        .ps2_mouseclk(ps2_mouseclk), .ps2_mousedat(ps2_mousedat),
        .ps2_mouseclk_out(ps2_mouseclk_out), .ps2_mousedat_out(ps2_mousedat_out)
    );
    assign controller_state = dut.keyb_state;
    assign synced_clock = dut.keyb_kbclk;
    assign synced_data = dut.keyb_kbdat;
    assign recv_final = dut.keyb_recv_final;
    assign recv_raw = dut.keyb_recv_buffer;
    assign translated = dut.translate;
    assign escape_state = dut.keyb_translate_escape;
    assign translated_value = dut.translate ?
        ({dut.keyb_translate_escape,7'b0} | dut.trans) : dut.keyb_recv_buffer;
    assign autoack = dut.wtk_q;
    assign reply_done = dut.ps2_kb_reply_done;
    assign write_request = dut.kb_fifo_wrreq;
    assign produced_value = dut.kb_fifo_wdata;
    assign fifo_full = dut.keyb_fifo_full;
    assign fifo_empty = dut.keyb_fifo_empty;
    assign fifo_used = dut.keyb_fifo_usedw;
    assign fifo_read_request = dut.keyb_fifo.rdreq;
    assign self_test = dut.cmd_self_test;
    assign output_full = dut.status_outputbufferfull;
    assign input_full = dut.status_inputbufferfull;
    assign timeout_event = dut.keyb_timeout_reset;
    assign fifo_q = dut.keyb_fifo_q;
    assign write_index = dut.keyb_fifo.wr_index;
    assign read_index = dut.keyb_fifo.rd_index;
    assign inspect_memory = dut.keyb_fifo.mem[inspect_index];
endmodule
`default_nettype wire
