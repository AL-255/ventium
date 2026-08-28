`timescale 1ns/1ps

// Focused AXI-Lite regression for the versioned snapshot and quiescent-exec
// banks in the FPGA wrapper's ven_mgmt_axil.  Compile it against the external
// integration source, for example:
//   iverilog -g2012 -s ven_mgmt_debug_tb -o /tmp/ven_mgmt_debug_tb.vvp \
//     /home/yukidama/github/ao486_MiSTer/fpga/rk-ao486-system/src/ven_mgmt_axil.v \
//     fpga/ven_mgmt_debug_tb.sv && vvp /tmp/ven_mgmt_debug_tb.vvp
// In particular this proves a 0x280 STEP write cannot alias legacy 0x080
// DBG_CTL bit8=CLEAR.
module ven_mgmt_debug_tb;
    reg clk = 0; always #5 clk = ~clk;
    reg rst_n = 0;
    reg [15:0] s_awaddr = 0; reg s_awvalid = 0;
    reg [31:0] s_wdata = 0; reg [3:0] s_wstrb = 0; reg s_wvalid = 0;
    wire s_awready, s_wready; wire [1:0] s_bresp; wire s_bvalid; reg s_bready = 0;
    reg [15:0] s_araddr = 0; reg s_arvalid = 0; wire s_arready;
    wire [31:0] s_rdata; wire [1:0] s_rresp; wire s_rvalid; reg s_rready = 0;
    wire [15:0] mgmt_address; wire mgmt_read; reg [15:0] mgmt_readdata = 0;
    wire mgmt_write; wire [15:0] mgmt_writedata;
    wire [6:0] dbg_trace_idx; wire dbg_clear, dbg_ext_freeze;
    wire [31:0] dbg_freeze_thresh, dbg_cmp_cfg, dbg_cmp_range;
    wire dbg_halt_req, dbg_step, dbg_bp_en, dbg_bp_clr;
    wire [31:0] dbg_bp_addr; wire [6:0] dbg_arch_sel;
    wire core_reset_n, irq_out;

    ven_mgmt_axil dut (
        .clk(clk), .rst_n(rst_n),
        .s_awaddr(s_awaddr), .s_awvalid(s_awvalid), .s_awready(s_awready),
        .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wvalid(s_wvalid), .s_wready(s_wready),
        .s_bresp(s_bresp), .s_bvalid(s_bvalid), .s_bready(s_bready),
        .s_araddr(s_araddr), .s_arvalid(s_arvalid), .s_arready(s_arready),
        .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rvalid(s_rvalid), .s_rready(s_rready),
        .mgmt_address(mgmt_address), .mgmt_read(mgmt_read), .mgmt_readdata(mgmt_readdata),
        .mgmt_write(mgmt_write), .mgmt_writedata(mgmt_writedata),
        .ide0_request(3'd0), .ide1_request(3'd0), .fdd_request(2'd0), .cpu_hung(1'b0),
        .dbg_word(32'd0), .dbg_word2(32'd0), .dbg_trace_idx(dbg_trace_idx),
        .dbg_clear(dbg_clear), .dbg_ext_freeze(dbg_ext_freeze),
        .dbg_freeze_thresh(dbg_freeze_thresh), .dbg_cmp_cfg(dbg_cmp_cfg), .dbg_cmp_range(dbg_cmp_range),
        .dbg_halt_req(dbg_halt_req), .dbg_step(dbg_step), .dbg_bp_en(dbg_bp_en),
        .dbg_bp_addr(dbg_bp_addr), .dbg_bp_clr(dbg_bp_clr), .dbg_arch_sel(dbg_arch_sel),
        .dbg_halted(1'b1), .dbg_arch_data(32'hc001d00d),
        .dbg_last_eip(32'd0), .dbg_frozen(1'b1), .dbg_frozen_eip(32'd0),
        .dbg_frozen_ctx_eip(32'h12345678), .dbg_frozen_cs(16'h0018),
        .dbg_frozen_esp(32'h89abcdef), .dbg_frozen_eflags(32'h00000246),
        .dbg_frozen_fault_pc(32'hdeadbeef), .dbg_frozen_cr0(32'h60000011),
        .dbg_frozen_state(6'h2d), .dbg_frozen_vec(8'h0e),
        .dbg_trace_pc(32'd0), .dbg_trace_aux(32'd0), .dbg_trace_count(6'd0),
        .dbg_rd_ring_addr(32'd0), .dbg_rd_ring_data(32'd0), .dbg_rd_ring_data_hi(32'd0),
        .dbg_perf_stall(32'd0), .dbg_perf_cyc(64'd0), .dbg_perf_retired(64'd0),
        .dbg_perf_io(32'd0), .dbg_perf_irq(32'd0), .dbg_cr0_live(32'd0),
        .dbg_rd_beats(32'd0), .dbg_ar_hs(32'd0), .dbg_b_hs(32'd0),
        .dbg_st_pipe(32'd0), .dbg_st_walk(32'd0), .dbg_st_fetch(32'd0), .dbg_st_other(32'd0),
        .core_reset_n(core_reset_n), .irq_out(irq_out)
    );

    task automatic read_expect(input [15:0] addr, input [31:0] expected);
        reg [31:0] got;
        begin
            @(negedge clk); s_araddr = addr; s_arvalid = 1; s_rready = 0;
            @(negedge clk); s_arvalid = 0;
            @(negedge clk); got = s_rdata;
            if (!s_rvalid || got !== expected) begin
                $display("READ FAIL addr=%h got=%h valid=%b expected=%h", addr, got, s_rvalid, expected);
                $fatal;
            end
            s_rready = 1;
            @(negedge clk); s_rready = 0;
        end
    endtask

    task automatic write_word(input [15:0] addr, input [31:0] value);
        begin
            @(negedge clk); s_awaddr = addr; s_wdata = value; s_awvalid = 1; s_wvalid = 1;
            @(negedge clk); s_awvalid = 0; s_wvalid = 0;
            if (addr == 16'h0280 && (dbg_clear || dbg_ext_freeze || mgmt_write)) begin
                $display("HIGH-BANK ALIAS FAIL clear=%b freeze=%b mgmt_write=%b", dbg_clear, dbg_ext_freeze, mgmt_write);
                $fatal;
            end
            @(negedge clk); if (!s_bvalid) begin $display("WRITE FAIL addr=%h no response", addr); $fatal; end
            s_bready = 1;
            @(negedge clk); s_bready = 0;
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        read_expect(16'h0200, 32'h56440001);
        read_expect(16'h0210, 32'h00000018);
        read_expect(16'h0220, 32'h12345678);
        read_expect(16'h0230, 32'h89abcdef);
        read_expect(16'h0240, 32'h00000246);
        read_expect(16'h0250, 32'hdeadbeef);
        read_expect(16'h0260, 32'h60000011);
        read_expect(16'h0270, 32'h0000b40e);
        read_expect(16'h0280, 32'h00000004);
        read_expect(16'h02a0, 32'h00000000);
        read_expect(16'h02b0, 32'hc001d00d);
        read_expect(16'h02c0, 32'h56450005);
        write_word(16'h0280, 32'h00000303);
        if (dbg_halt_req !== 1'b1 || dbg_bp_en !== 1'b1 || dbg_step !== 1'b0 || dbg_bp_clr !== 1'b0) $fatal;
        read_expect(16'h0280, 32'h00000007);
        write_word(16'h0290, 32'h11223344);
        read_expect(16'h0290, 32'h11223344);
        // Exercise selector bit 6: the descriptor/debug-state bank begins at
        // 64 and must not truncate to the original six-bit x87 map.
        write_word(16'h02a0, 32'h0000004a);
        read_expect(16'h02a0, 32'h0000004a);
        $display("VEN-MGMT-DEBUG-TB-OK");
        $finish;
    end
endmodule
