`timescale 1ns/1ps
// Measures the REAL board bridge with delayed write responses. The historical
// full-PC C++ DDR model has no B-channel delay and cannot expose this bottleneck.
// No guest code, retirement estimate, or Quake-specific traffic is used here.
module ven_ddram_axi_throughput_tb;
    parameter integer B_LATENCY = 20;
    localparam integer N = 64;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    wire DDRAM_BUSY, DDRAM_DOUT_READY;
    reg [7:0] DDRAM_BURSTCNT = 1, DDRAM_BE = 8'hff;
    reg [24:0] DDRAM_ADDR = 0;
    wire [63:0] DDRAM_DOUT;
    reg [63:0] DDRAM_DIN = 0;
    reg DDRAM_WE = 0, DDRAM_RD = 0;
    wire [3:0] m_axi_awid, m_axi_arid;
    wire [31:0] m_axi_awaddr, m_axi_araddr;
    wire [7:0] m_axi_awlen, m_axi_arlen;
    wire [2:0] m_axi_awsize, m_axi_arsize, dbg_st;
    wire [1:0] m_axi_awburst, m_axi_arburst;
    wire m_axi_awvalid, m_axi_wvalid, m_axi_wlast, m_axi_bready;
    wire m_axi_arvalid, m_axi_rready;
    wire [63:0] m_axi_wdata;
    wire [7:0] m_axi_wstrb;
    reg m_axi_awready = 0, m_axi_wready = 0, m_axi_arready = 0;
    reg m_axi_bvalid = 0, m_axi_rvalid = 0, m_axi_rlast = 0;
    reg [1:0] m_axi_bresp = 0, m_axi_rresp = 0;
    reg [63:0] m_axi_rdata = 0;
    wire fault;
`ifdef VEN_TEST_POSTED
    ven_ddram_axi_posted dut (.*);
`else
    ven_ddram_axi dut (.*);
    assign fault = 0;
`endif

    integer cyc = 0, aw = 0, w = 0, b = 0, ar = 0, r = 0;
    integer aw_at[0:N-1], w_at[0:N-1];
    reg [63:0] committed[0:N-1];
    integer read_due = -1;
    integer start_cyc, write_done_cyc, i;
    reg read_seen = 0;

    always @(posedge clk) begin
        cyc = cyc + 1;
        if (cyc > 20000) $fatal(1,"bridge timeout");
        if (rst_n) begin
            if (fault) $fatal(1,"unexpected bridge fault");
            if (m_axi_awvalid && m_axi_awready) begin
                if (aw >= N || m_axi_awaddr !== (32'h800 + 8*aw) ||
                    m_axi_awlen !== 0 || m_axi_awsize !== 3 || m_axi_awid !== 0)
                    $fatal(1,"bad/duplicate AW %0d",aw);
                aw_at[aw] = cyc;
                aw = aw + 1;
            end
            if (m_axi_wvalid && m_axi_wready) begin
                if (w >= N || m_axi_wdata !== (64'hf00d000000000000 + w) ||
                    m_axi_wstrb !== 8'hff || !m_axi_wlast)
                    $fatal(1,"bad/duplicate W %0d",w);
                w_at[w] = cyc;
                w = w + 1;
            end
            if (m_axi_bvalid && m_axi_bready) begin
                if (b >= aw || b >= w) $fatal(1,"B without AW/W");
                committed[b] = 64'hf00d000000000000 + b;
                b = b + 1;
                if (b == N) write_done_cyc = cyc;
            end
            if (m_axi_arvalid && m_axi_arready) begin
                if (b != N) $fatal(1,"read overtook uncommitted writes");
                if (m_axi_araddr !== 32'h9f8 || m_axi_arlen !== 0)
                    $fatal(1,"wrong read command");
                read_due = cyc + 7;
                ar = ar + 1;
            end
            if (m_axi_rvalid && m_axi_rready) begin
                r = r + 1;
                read_due = -1;
            end
            if (DDRAM_DOUT_READY) begin
                if (read_seen || DDRAM_DOUT !== (64'hf00d000000000000 + N-1))
                    $fatal(1,"lost/duplicate/stale read result");
                read_seen = 1;
            end
        end
    end
    // Independent AW/W acceptance exercises both channel orders; commit only
    // at the delayed response, so a read that jumps the barrier returns stale.
    always @(negedge clk) begin
        m_axi_awready = rst_n && (cyc % 5 != 1);
        m_axi_wready = rst_n && (cyc % 7 != 2);
        m_axi_arready = rst_n;
        m_axi_bvalid = 0;
        if (b < N && b < aw && b < w)
            m_axi_bvalid = cyc >= ((aw_at[b] > w_at[b] ? aw_at[b] : w_at[b]) + B_LATENCY);
        m_axi_rvalid = read_due >= 0 && cyc >= read_due;
        m_axi_rlast = m_axi_rvalid;
        m_axi_rdata = committed[N-1];
    end
    initial begin
        for (i=0;i<N;i=i+1) committed[i]=0;
        repeat(3) @(negedge clk);
        rst_n = 1;
        @(negedge clk);
        start_cyc = cyc;
        for (i=0;i<N;i=i+1) begin
            while (DDRAM_BUSY) @(negedge clk);
            DDRAM_ADDR = 25'h100 + i;
            DDRAM_DIN = 64'hf00d000000000000 + i;
            DDRAM_WE = 1;
            @(negedge clk);
            DDRAM_WE = 0;
            @(negedge clk);
        end
        // Do NOT wait for B completion here: the posted implementation must
        // enforce the read-after-write barrier itself, not rely on the driver.
        while (DDRAM_BUSY) @(negedge clk);
        DDRAM_ADDR = 25'h13f;
        DDRAM_RD = 1;
        @(negedge clk);
        DDRAM_RD = 0;
        while (!read_seen) @(negedge clk);
        repeat(4) @(negedge clk);
        if (aw != N || w != N || b != N || ar != 2 || r != 2)
            $fatal(1,"unbalanced traffic aw=%0d w=%0d b=%0d ar=%0d r=%0d",aw,w,b,ar,r);
        $display("DDRAM-THROUGHPUT-OK b_latency=%0d writes=%0d drained_cycles=%0d cycles_per_write=%0f",
                 B_LATENCY,N,write_done_cyc-start_cyc,real'(write_done_cyc-start_cyc)/N);
        $finish;
    end
endmodule
