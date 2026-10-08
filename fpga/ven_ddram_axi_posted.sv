`timescale 1ns/1ps
`default_nettype none
// Experimental board-transport replacement, NOT selected by the FPGA flow.
// Four ordered single-beat RAM writes may be outstanding. Independent AW/W
// cursors retain payloads until each channel accepts them; only a real B frees
// a slot. Reads drain ALL older writes before AR. No synthetic AXI response,
// store forwarding, write combining, cache geometry or guest-specific address.
// The ao486 L2 issues single-beat writes only. Invalid bursts / AXI errors latch
// fault and stop new work; issued AW/W transactions are still allowed to drain.
// Reset must reset the downstream AXI domain too (not a transaction cancel).
// Keep the installed bridge's double-read policy unchanged for isolated A/B.
module ven_ddram_axi_posted #(
    parameter integer AXI_ADDR_W = 32,
    parameter integer AXI_ID_W = 4,
    parameter [AXI_ADDR_W-1:0] MEM_BASE = 0
)(
    input wire clk, rst_n,
    output wire DDRAM_BUSY,
    input wire [7:0] DDRAM_BURSTCNT,
    input wire [24:0] DDRAM_ADDR,
    output reg [63:0] DDRAM_DOUT,
    output reg DDRAM_DOUT_READY,
    input wire DDRAM_RD,
    input wire [63:0] DDRAM_DIN,
    input wire [7:0] DDRAM_BE,
    input wire DDRAM_WE,
    output wire [AXI_ID_W-1:0] m_axi_awid,
    output wire [AXI_ADDR_W-1:0] m_axi_awaddr,
    output wire [7:0] m_axi_awlen,
    output wire [2:0] m_axi_awsize,
    output wire [1:0] m_axi_awburst,
    output wire m_axi_awvalid,
    input wire m_axi_awready,
    output wire [63:0] m_axi_wdata,
    output wire [7:0] m_axi_wstrb,
    output wire m_axi_wlast, m_axi_wvalid,
    input wire m_axi_wready,
    input wire [1:0] m_axi_bresp,
    input wire m_axi_bvalid,
    output wire m_axi_bready,
    output wire [AXI_ID_W-1:0] m_axi_arid,
    output reg [AXI_ADDR_W-1:0] m_axi_araddr,
    output reg [7:0] m_axi_arlen,
    output wire [2:0] m_axi_arsize,
    output wire [1:0] m_axi_arburst,
    output wire m_axi_arvalid,
    input wire m_axi_arready,
    input wire [63:0] m_axi_rdata,
    input wire [1:0] m_axi_rresp,
    input wire m_axi_rlast, m_axi_rvalid,
    output wire m_axi_rready,
    output wire [2:0] dbg_st,
    output reg fault
);
    reg [AXI_ADDR_W-1:0] addr_q [0:3];
    reg [63:0] data_q [0:3];
    reg [7:0] strb_q [0:3];
    reg [1:0] tail, aw_head, w_head;
    reg [2:0] occupied, aw_pending, w_pending;
    localparam [2:0] IDLE=0, AR=1, R=2, DRAIN=4;
    reg [2:0] st;
    reg rd_seen, primed;
    reg [7:0] read_left;
    wire aw_hs = m_axi_awvalid && m_axi_awready;
    wire w_hs = m_axi_wvalid && m_axi_wready;
    wire b_hs = m_axi_bvalid && m_axi_bready;
    wire bad_input = DDRAM_RD && DDRAM_WE ||
                     DDRAM_WE && DDRAM_BURSTCNT > 1;
    wire push = !DDRAM_BUSY && DDRAM_WE && !bad_input;
    wire take_read = !DDRAM_BUSY && DDRAM_RD && !rd_seen && !bad_input;
    assign DDRAM_BUSY = !rst_n || fault || st != IDLE || occupied == 4;
    assign m_axi_awvalid = rst_n && aw_pending != 0;
    assign m_axi_wvalid = rst_n && w_pending != 0;
    assign m_axi_awaddr = addr_q[aw_head];
    assign m_axi_wdata = data_q[w_head];
    assign m_axi_wstrb = strb_q[w_head];
    assign m_axi_awid = 0;
    assign m_axi_awlen = 0;
    assign m_axi_awsize = 3;
    assign m_axi_awburst = 1;
    assign m_axi_wlast = 1;
    // Same-ID in-order B responses. Wait until the oldest AW AND W are sent,
    // including when a slave returns B immediately after the final handshake.
    assign m_axi_bready = rst_n && occupied > aw_pending && occupied > w_pending;
    assign m_axi_arid = 0;
    assign m_axi_arsize = 3;
    assign m_axi_arburst = 1;
    assign m_axi_arvalid = rst_n && st == AR;
    assign m_axi_rready = rst_n && st == R;
    assign dbg_st = st != IDLE ? st : occupied != 0 ? 3'd3 : 3'd0;

    always @(posedge clk) begin
        if (!rst_n) begin
            tail <= 0; aw_head <= 0; w_head <= 0;
            occupied <= 0; aw_pending <= 0; w_pending <= 0;
            st <= IDLE; rd_seen <= 0; primed <= 0; read_left <= 0;
            m_axi_araddr <= 0; m_axi_arlen <= 0;
            DDRAM_DOUT <= 0; DDRAM_DOUT_READY <= 0; fault <= 0;
        end else begin
            DDRAM_DOUT_READY <= 0;
            if (!DDRAM_RD) rd_seen <= 0;
            if (!DDRAM_BUSY && bad_input) fault <= 1;
            if (b_hs && m_axi_bresp != 0) fault <= 1;
            case ({push,b_hs})
                2'b10: occupied <= occupied + 1'b1;
                2'b01: occupied <= occupied - 1'b1;
                default: ;
            endcase
            case ({push,aw_hs})
                2'b10: aw_pending <= aw_pending + 1'b1;
                2'b01: aw_pending <= aw_pending - 1'b1;
                default: ;
            endcase
            case ({push,w_hs})
                2'b10: w_pending <= w_pending + 1'b1;
                2'b01: w_pending <= w_pending - 1'b1;
                default: ;
            endcase
            if (aw_hs) aw_head <= aw_head + 1'b1;
            if (w_hs) w_head <= w_head + 1'b1;
            if (push) begin
                addr_q[tail] <= {{(AXI_ADDR_W-28){1'b0}},DDRAM_ADDR,3'b000} + MEM_BASE;
                data_q[tail] <= DDRAM_DIN;
                strb_q[tail] <= DDRAM_BE;
                tail <= tail + 1'b1;
            end
            if (take_read) begin
                m_axi_araddr <= {{(AXI_ADDR_W-28){1'b0}},DDRAM_ADDR,3'b000} + MEM_BASE;
                m_axi_arlen <= DDRAM_BURSTCNT == 0 ? 0 : DDRAM_BURSTCNT - 1'b1;
                rd_seen <= 1;
                primed <= 0;
                st <= DRAIN;
            end
            case (st)
                DRAIN: if (occupied == 0 && !fault) st <= AR;
                AR: if (m_axi_arready) begin
                    st <= R;
                    read_left <= m_axi_arlen + 1'b1;
                end
                R: if (m_axi_rvalid) begin
                    if (m_axi_rresp != 0 || m_axi_rlast != (read_left == 1)) fault <= 1;
                    if (primed && !fault && m_axi_rresp == 0 &&
                        m_axi_rlast == (read_left == 1)) begin
                        DDRAM_DOUT <= m_axi_rdata;
                        DDRAM_DOUT_READY <= 1;
                    end
                    read_left <= read_left - 1'b1;
                    if (m_axi_rlast) begin
                        if (primed || fault || m_axi_rresp != 0 || read_left != 1) st <= IDLE;
                        else begin primed <= 1; st <= AR; end
                    end
                end
                default: ;
            endcase
        end
    end
endmodule
`default_nettype wire
