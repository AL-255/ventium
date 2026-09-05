`timescale 1ns/1ps

// AXI-channel-independence witness for the externally supplied DDRAM bridge.
// AXI permits W to handshake before AW.  A correct bridge must retain the
// remaining channel, enter B only after both have completed, and never repeat
// an accepted address command while waiting for B.
module ven_ddram_axi_aw_w_tb;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n = 1'b0;
    wire DDRAM_BUSY;
    reg [7:0] DDRAM_BURSTCNT = 8'd1;
    reg [24:0] DDRAM_ADDR = 25'd0;
    wire [63:0] DDRAM_DOUT;
    wire DDRAM_DOUT_READY;
    reg DDRAM_RD = 1'b0;
    reg [63:0] DDRAM_DIN = 64'd0;
    reg [7:0] DDRAM_BE = 8'hff;
    reg DDRAM_WE = 1'b0;

    wire [3:0] m_axi_awid;
    wire [31:0] m_axi_awaddr;
    wire [7:0] m_axi_awlen;
    wire [2:0] m_axi_awsize;
    wire [1:0] m_axi_awburst;
    wire m_axi_awvalid;
    reg m_axi_awready = 1'b0;
    wire [63:0] m_axi_wdata;
    wire [7:0] m_axi_wstrb;
    wire m_axi_wlast;
    wire m_axi_wvalid;
    reg m_axi_wready = 1'b0;
    reg [1:0] m_axi_bresp = 2'b00;
    reg m_axi_bvalid = 1'b0;
    wire m_axi_bready;
    wire [3:0] m_axi_arid;
    wire [31:0] m_axi_araddr;
    wire [7:0] m_axi_arlen;
    wire [2:0] m_axi_arsize;
    wire [1:0] m_axi_arburst;
    wire m_axi_arvalid;
    reg m_axi_arready = 1'b0;
    reg [63:0] m_axi_rdata = 64'd0;
    reg [1:0] m_axi_rresp = 2'b00;
    reg m_axi_rlast = 1'b0;
    reg m_axi_rvalid = 1'b0;
    wire m_axi_rready;
    wire [2:0] dbg_st;

    ven_ddram_axi dut (
        .clk(clk), .rst_n(rst_n),
        .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT),
        .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
        .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
        .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
        .m_axi_awid(m_axi_awid), .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst), .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready), .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready), .m_axi_arid(m_axi_arid),
        .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready), .dbg_st(dbg_st)
    );

    integer aw_count = 0;
    integer w_count = 0;
    integer b_count = 0;
    reg [31:0] first_awaddr = 32'd0;
    reg [63:0] first_wdata = 64'd0;

    always @(posedge clk) begin
        if (rst_n && m_axi_awvalid && m_axi_awready) begin
            aw_count = aw_count + 1;
            if (aw_count == 1) first_awaddr = m_axi_awaddr;
        end
        if (rst_n && m_axi_wvalid && m_axi_wready) begin
            w_count = w_count + 1;
            if (w_count == 1) first_wdata = m_axi_wdata;
        end
        if (rst_n && m_axi_bvalid && m_axi_bready)
            b_count = b_count + 1;
    end

    task automatic wait_clks(input integer n);
        begin
            repeat (n) @(posedge clk);
            #1;
        end
    endtask

    task automatic start_single_write(input [24:0] addr, input [63:0] data);
        begin
            @(negedge clk);
            DDRAM_ADDR = addr;
            DDRAM_DIN = data;
            DDRAM_BE = 8'hff;
            DDRAM_BURSTCNT = 8'd1;
            DDRAM_WE = 1'b1;
            @(negedge clk);
            DDRAM_WE = 1'b0;
        end
    endtask

    task automatic clear_scoreboard;
        begin
            aw_count = 0;
            w_count = 0;
            b_count = 0;
            first_awaddr = 32'd0;
            first_wdata = 64'd0;
        end
    endtask

    task automatic expect_counts(input integer aw_exp, input integer w_exp,
                                 input integer b_exp, input integer case_no);
        begin
            if ((aw_count != aw_exp) || (w_count != w_exp) || (b_count != b_exp)) begin
                $display("DDRAM-AXI-AW-W FAIL case=%0d aw=%0d/%0d w=%0d/%0d b=%0d/%0d state=%0d awv=%0b wv=%0b",
                         case_no, aw_count, aw_exp, w_count, w_exp,
                         b_count, b_exp, dbg_st, m_axi_awvalid, m_axi_wvalid);
                $fatal(1);
            end
        end
    endtask

    initial begin
        wait_clks(2);
        @(negedge clk);
        rst_n = 1'b1;
        wait_clks(1);

        // Case 1: AW first, then W, then a delayed B response.
        clear_scoreboard;
        m_axi_awready = 1'b1;
        m_axi_wready = 1'b0;
        start_single_write(25'h00100, 64'h1122_3344_5566_7788);
        wait_clks(1); // AW handshake
        m_axi_wready = 1'b1;
        wait_clks(1); // W handshake
        m_axi_wready = 1'b0;
        wait_clks(2); // B deliberately delayed: no duplicate command is legal
        expect_counts(1, 1, 0, 1);
        if (first_awaddr !== 32'h0000_0800 || first_wdata !== 64'h1122_3344_5566_7788) begin
            $display("DDRAM-AXI-AW-W FAIL case=1 payload addr=%08x data=%016x",
                     first_awaddr, first_wdata);
            $fatal(1);
        end
        @(negedge clk);
        m_axi_bvalid = 1'b1;
        wait_clks(1);
        @(negedge clk);
        m_axi_bvalid = 1'b0;
        wait_clks(1);
        expect_counts(1, 1, 1, 1);

        // Case 2: W first is legal AXI.  Hold AWREADY low until W has been
        // accepted, then leave AWREADY high while B is delayed.  Exactly one
        // AW handshake must occur; the historical bridge repeats it here.
        clear_scoreboard;
        m_axi_awready = 1'b0;
        m_axi_wready = 1'b1;
        start_single_write(25'h00200, 64'h8877_6655_4433_2211);
        wait_clks(1); // W handshake, AW stalled
        wait_clks(2);
        expect_counts(0, 1, 0, 2);
        m_axi_awready = 1'b1;
        wait_clks(1); // sole permitted AW handshake
        wait_clks(2); // B still absent: repeated AW is a protocol bug
        expect_counts(1, 1, 0, 2);
        if (first_awaddr !== 32'h0000_1000 || first_wdata !== 64'h8877_6655_4433_2211) begin
            $display("DDRAM-AXI-AW-W FAIL case=2 payload addr=%08x data=%016x",
                     first_awaddr, first_wdata);
            $fatal(1);
        end
        @(negedge clk);
        m_axi_bvalid = 1'b1;
        wait_clks(1);
        @(negedge clk);
        m_axi_bvalid = 1'b0;
        wait_clks(1);
        expect_counts(1, 1, 1, 2);

        // Case 3: simultaneous AW/W acceptance followed by a delayed B.
        clear_scoreboard;
        m_axi_awready = 1'b1;
        m_axi_wready = 1'b1;
        start_single_write(25'h00300, 64'h0102_0304_0506_0708);
        wait_clks(1);
        wait_clks(2);
        expect_counts(1, 1, 0, 3);
        @(negedge clk);
        m_axi_bvalid = 1'b1;
        wait_clks(1);
        @(negedge clk);
        m_axi_bvalid = 1'b0;
        wait_clks(1);
        expect_counts(1, 1, 1, 3);

        $display("DDRAM-AXI-AW-W-TB-OK");
        $finish;
    end
endmodule
