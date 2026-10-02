// Isolated source-only micro wrapper. All hierarchical accesses are read-only.
`default_nettype none
module ps2_resync_probe (
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
    output wire [3:0] controller_state, mouse_state,
    output wire synced_clock, synced_data, recv_final, translated, escape_state,
    output wire ack_offer, ack_commit, scan_commit, rx_pending, reply_valid,
    output wire reply_done, write_request, fifo_full, fifo_empty, mouse_full,
    output wire fifo_read_request, self_test, output_full, input_full, input_done,
    output wire timeout_event, write_keyb, write_mouse,
    output wire [5:0] write_index, read_index, fifo_used,
    output wire [7:0] recv_raw, translated_value, produced_value, fifo_q,
    output wire mouse_recv_final, mouse_fifo_empty, mouse_rdreq,
    output wire [7:0] mouse_recv_raw, mouse_fifo_q,
    output wire [7:0] pending_data
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
    assign mouse_recv_final=dut.mouse_recv_final;
    assign mouse_recv_raw=dut.mouse_recv_buffer;
    assign mouse_fifo_empty=dut.mouse_fifo_empty;
    assign mouse_rdreq=dut.mouse_fifo.rdreq;
    assign mouse_fifo_q=dut.mouse_fifo_q;
    assign controller_state=dut.keyb_state;
    assign mouse_state=dut.mouse_state;
    assign synced_clock=dut.keyb_kbclk;
    assign synced_data=dut.keyb_kbdat;
    assign recv_final=dut.keyb_recv_final;
    assign recv_raw=dut.keyb_recv_buffer;
    assign translated=dut.translate;
    assign escape_state=dut.keyb_translate_escape;
    assign translated_value=dut.translate ?
        ({dut.keyb_translate_escape,7'b0}|dut.trans) : dut.keyb_recv_buffer;
`ifdef PS2_LEGACY_CONTROL
`ifdef VEN_KBD_AUTOACK
    assign ack_offer=dut.wtk_q;
`else
    assign ack_offer=1'b0;
`endif
    assign ack_commit=1'b0;
    assign scan_commit=1'b0;
    assign rx_pending=1'b0;
    assign pending_data=8'd0;
`else
    assign ack_offer=dut.kb_ack_offer;
    assign ack_commit=dut.kb_ack_commit;
    assign scan_commit=dut.kb_scan_commit;
    assign rx_pending=dut.kb_rx_pending;
    assign pending_data=dut.kb_rx_pending_data;
`endif
    assign reply_valid=dut.keyb_reply_valid;
    assign reply_done=dut.ps2_kb_reply_done;
    assign write_request=dut.kb_fifo_wrreq;
    assign produced_value=dut.kb_fifo_wdata;
    assign fifo_full=dut.keyb_fifo_full;
    assign fifo_empty=dut.keyb_fifo_empty;
    assign fifo_used=dut.keyb_fifo_usedw;
    assign fifo_read_request=dut.keyb_fifo.rdreq;
    assign self_test=dut.cmd_self_test;
    assign output_full=dut.status_outputbufferfull;
    assign mouse_full=dut.status_mousebufferfull;
    assign input_full=dut.status_inputbufferfull;
    assign input_done=dut.input_write_done;
    assign timeout_event=dut.keyb_timeout_reset;
    assign write_keyb=dut.write_to_keyb;
    assign write_mouse=dut.write_to_mouse;
    assign fifo_q=dut.keyb_fifo_q;
    assign write_index=dut.keyb_fifo.wr_index;
    assign read_index=dut.keyb_fifo.rd_index;
    assign inspect_memory=dut.keyb_fifo.mem[inspect_index];
endmodule
`default_nettype wire
