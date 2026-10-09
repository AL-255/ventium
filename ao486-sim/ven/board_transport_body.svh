// Simulation-only board topology. Real leaf RTL; same core/cache/PS model.
wire board_ddram_busy, board_ddram_valid;
wire [63:0] board_ddram_data;
wire [127:0] board_dbg_cmp = {18'd0, board_transport_fault, 1'b1,
                              board_transport_drained, cpu_dbg_cmp[106:0]};
generate if (BOARD_POSTED) begin : g_board_posted
    ven_ddram_axi_posted #(.WRITE_SLOTS(BOARD_WRITE_SLOTS)) board_ddr (
        .fault(board_transport_fault), .drained(board_transport_drained),
        `include "board_transport_connections.svh"
    );
end else begin : g_board_serial
    ven_ddram_axi board_ddr (
        `include "board_transport_connections.svh"
    );
    assign board_transport_fault = 1'b0;
    assign board_transport_drained = board_axi_resetn && !board_ddram_busy &&
                                      !DDRAM_RD && !DDRAM_WE && !board_ddram_valid;
end endgenerate
