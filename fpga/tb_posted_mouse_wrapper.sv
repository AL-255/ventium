`timescale 1ns/1ps
// Actual wrapper + management + mailbox + device. Unrelated CPU/DDR/video
// modules are deliberately absent (-i); this is NOT full-wrapper/CPU acceptance.
module tb_posted_mouse_wrapper;
    parameter CLK_HZ = 40_000_000;
    reg clk = 0;
    localparam real HALF_NS = 500_000_000.0 / CLK_HZ;
    always #(HALF_NS) clk = ~clk;
    reg resetn = 0;
    reg [15:0] araddr = 0;
    reg arvalid = 0, rready = 0;
    wire arready, rvalid;
    wire [31:0] rdata;
    wire [1:0] rresp;
    rk_ao486_system_pl #(.CLK_HZ(CLK_HZ)) dut (
        .clk(clk), .resetn(resetn),
        .s_axil_awaddr(16'd0), .s_axil_awvalid(1'b0),
        .s_axil_wdata(32'd0), .s_axil_wstrb(4'd0), .s_axil_wvalid(1'b0),
        .s_axil_bready(1'b0), .s_axil_araddr(araddr), .s_axil_arvalid(arvalid),
        .s_axil_arready(arready), .s_axil_rdata(rdata), .s_axil_rvalid(rvalid),
        .s_axil_rresp(rresp), .s_axil_rready(rready),
        .m_axi_awready(1'b0), .m_axi_wready(1'b0), .m_axi_bresp(2'd0),
        .m_axi_bvalid(1'b0), .m_axi_arready(1'b0), .m_axi_rdata(64'd0),
        .m_axi_rresp(2'd0), .m_axi_rlast(1'b0), .m_axi_rvalid(1'b0)
    );
    task automatic read_csr(input [15:0] address, output [31:0] value);
        integer wait_count;
        begin
            @(negedge clk); araddr = address; arvalid = 1; rready = 0;
            wait_count = 0;
            do begin
                @(posedge clk); #1; wait_count = wait_count + 1;
                if (wait_count > 40) $fatal(1, "AR timeout");
            end while (!arready);
            @(negedge clk); arvalid = 0;
            wait_count = 0;
            while (!rvalid) begin
                @(posedge clk); #1; wait_count = wait_count + 1;
                if (wait_count > 40) $fatal(1, "R timeout");
            end
            value = rdata;
            repeat (4) begin
                @(posedge clk); #1;
                if (rvalid !== 1 || rdata !== value || rresp !== 0)
                    $fatal(1, "response not held under backpressure");
            end
            @(negedge clk); rready = 1;
            @(posedge clk); #1;
            @(negedge clk); rready = 0;
        end
    endtask
    reg [31:0] value;
    initial begin
        repeat (8) @(negedge clk);
        resetn = 1;
        repeat (8) @(negedge clk);
        read_csr(16'h400, value);
        if (value !== 32'h50533201)
            $fatal(1, "POSTED-MOUSE-CAPABILITY-MISSING got=%08x", value);
        read_csr(16'h410, value);
        if (value !== 32'd1) $fatal(1, "guest reset status got=%08x", value);
        read_csr(16'h420, value);
        // Fabric reset initializes epoch=0 and guest_reset_q=1. Keeping the
        // guest held in reset is not another reset assertion/generation.
        if (value !== 32'd0) $fatal(1, "guest reset generation got=%08x", value);
        if (dut.ps2_mouseclk_dev !== 1 || dut.ps2_mousedat_dev !== 1)
            $fatal(1, "device wires not driven/released during guest reset");
        $display("POSTED-MOUSE-WRAPPER-MICRO-OK CLK_HZ=%0d reads=3 full_cpu=0", CLK_HZ);
        $finish;
    end
    initial begin #100000; $fatal(1, "test timeout"); end
endmodule
