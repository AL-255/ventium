`timescale 1ns/1ps
`default_nettype none
// Actual ven_mgmt_axil + mailbox. The serial byte port is an explicit BFM;
// pin framing/8042 behavior belongs to the separate real-wire test.
module tb_ps2_mailbox_mgmt;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0, frozen=0;
    reg [15:0] awaddr=0, araddr=0;
    reg [31:0] wdata=0;
    reg [3:0] wstrb=15;
    reg awvalid=0, wvalid=0, bready=0, arvalid=0, rready=0;
    wire awready, wready, bvalid, arready, rvalid;
    wire [1:0] bresp, rresp;
    wire [31:0] rdata;
    wire mouse_wr, core_reset_n, dbg_clear, dbg_step, cap_arm, kbd_valid;
    wire [3:0] mouse_wa, mouse_ra, mouse_ws;
    wire [31:0] mouse_wd, mouse_rd;
    wire tx_valid, rx_ready;
    wire [7:0] tx_data;
    reg tx_ready=0, tx_done=0, tx_aborted=0, rx_valid=0, rx_aborted=0;
    reg [7:0] rx_data=0;
    reg [1:0] rx_error=0;
    wire guest_reset=!rst_n || !core_reset_n || frozen;
    integer checks=0, tx_count=0, write_pulses=0;
    reg [31:0] q;
    always @(posedge clk) if (rst_n) begin
        if (tx_valid && tx_ready) tx_count=tx_count+1;
        if (mouse_wr) write_pulses=write_pulses+1;
        if (dbg_clear || dbg_step || cap_arm || kbd_valid)
            $fatal(1,"mouse CSR aliased unrelated command");
    end
    ven_mgmt_axil mgmt (
        .clk(clk), .rst_n(rst_n), .s_awaddr(awaddr), .s_awvalid(awvalid), .s_awready(awready),
        .s_wdata(wdata), .s_wstrb(wstrb), .s_wvalid(wvalid), .s_wready(wready),
        .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready), .s_araddr(araddr),
        .s_arvalid(arvalid), .s_arready(arready), .s_rdata(rdata), .s_rresp(rresp),
        .s_rvalid(rvalid), .s_rready(rready),
        .mgmt_address(), .mgmt_read(), .mgmt_readdata(16'd0), .mgmt_write(), .mgmt_writedata(),
        .ide0_request(3'd0), .ide1_request(3'd0), .fdd_request(2'd0), .cpu_hung(1'b0),
        .dbg_word(32'd0), .dbg_word2(32'd0), .dbg_trace_idx(), .dbg_clear(dbg_clear),
        .dbg_ext_freeze(), .dbg_freeze_thresh(), .dbg_cmp_cfg(), .dbg_cmp_range(),
        .dbg_halt_req(), .dbg_step(dbg_step), .dbg_bp_en(), .dbg_bp_addr(), .dbg_bp_clr(),
        .dbg_arch_sel(), .dbg_halted(1'b0), .dbg_arch_data(32'd0), .dbg_last_eip(32'd0),
        .dbg_frozen(frozen), .dbg_frozen_eip(32'd0), .dbg_frozen_ctx_eip(32'd0),
        .dbg_frozen_cs(16'd0), .dbg_frozen_esp(32'd0), .dbg_frozen_eflags(32'd0),
        .dbg_frozen_fault_pc(32'd0), .dbg_frozen_cr0(32'd0), .dbg_frozen_state(6'd0),
        .dbg_frozen_vec(8'd0), .dbg_trace_pc(32'd0), .dbg_trace_aux(32'd0), .dbg_trace_count(6'd0),
        .dbg_rd_ring_addr(32'd0), .dbg_rd_ring_data(32'd0), .dbg_rd_ring_data_hi(32'd0),
        .dbg_perf_stall(32'd0), .dbg_perf_cyc(64'd0), .dbg_perf_retired(64'd0),
        .dbg_perf_io(32'd0), .dbg_perf_irq(32'd0), .dbg_cr0_live(32'd0), .dbg_rd_beats(32'd0),
        .dbg_ar_hs(32'd0), .dbg_b_hs(32'd0), .dbg_st_pipe(32'd0), .dbg_st_walk(32'd0),
        .dbg_st_fetch(32'd0), .dbg_st_other(32'd0),
        .cap_arm(cap_arm), .cap_rd_addr(), .cap_rd_en(), .cap_rd_data(32'd0),
        .cap_frame_ready(1'b0), .cap_capture_active(1'b0), .cap_frame_overrun(1'b0),
        .cap_frame_sequence(32'd0), .cap_frame_cycle(64'd0), .cap_frame_width(12'd0),
        .cap_frame_height(12'd0), .cap_frame_pixels(20'd0), .kbd_inject_data(),
        .kbd_inject_valid(kbd_valid), .kbd_inject_ready(1'b1), .kbd_inject_busy(1'b0),
        .mouse_csr_write(mouse_wr), .mouse_csr_waddr(mouse_wa), .mouse_csr_wdata(mouse_wd),
        .mouse_csr_wstrb(mouse_ws), .mouse_csr_raddr(mouse_ra), .mouse_csr_rdata(mouse_rd),
        .core_reset_n(core_reset_n), .irq_out());
    ven_ps2_mailbox mailbox (
        .clk(clk), .rst_n(rst_n), .guest_reset(guest_reset), .csr_write(mouse_wr),
        .csr_waddr(mouse_wa), .csr_wdata(mouse_wd), .csr_wstrb(mouse_ws),
        .csr_raddr(mouse_ra), .csr_rdata(mouse_rd), .tx_valid(tx_valid), .tx_data(tx_data),
        .tx_ready(tx_ready), .tx_done(tx_done), .tx_aborted(tx_aborted), .rx_valid(rx_valid),
        .rx_data(rx_data), .rx_error(rx_error), .rx_ready(rx_ready), .rx_aborted(rx_aborted));
    task check(input bit condition, input string message);
        begin checks=checks+1; if(!condition) $fatal(1,"PS2-MGMT-FAIL check=%0d %s",checks,message); end
    endtask
    task write_word(input [15:0] addr, input [31:0] data,
                    input integer aw_delay=0, input integer w_delay=0, input [3:0] lanes=15);
        integer old_pulses;
        begin
            old_pulses=write_pulses;
            fork
                begin
                    repeat(aw_delay) @(negedge clk);
                    @(negedge clk); awaddr=addr; awvalid=1;
                    do @(posedge clk); while(!awready);
                    @(negedge clk); awvalid=0;
                end
                begin
                    repeat(w_delay) @(negedge clk);
                    @(negedge clk); wdata=data; wstrb=lanes; wvalid=1;
                    do @(posedge clk); while(!wready);
                    @(negedge clk); wvalid=0;
                end
            join
            wait(bvalid);
            repeat(4) begin @(negedge clk); check(bvalid && bresp==0,"B backpressure"); end
            bready=1; @(negedge clk); bready=0;
            check(write_pulses-old_pulses == ((addr[11:8]==4 && addr[3:0]==0) ? 1 : 0),
                  "exactly one mouse command per mapped AXI write");
        end
    endtask
    task read_word(input [15:0] addr, output [31:0] data);
        begin
            @(negedge clk); araddr=addr; arvalid=1;
            do @(posedge clk); while(!arready);
            @(negedge clk); arvalid=0; araddr=16'h0050;
            wait(rvalid); data=rdata;
            repeat(4) begin @(negedge clk); check(rvalid && rresp==0 && rdata===data,"stable R response after AR changes"); end
            rready=1; @(negedge clk); rready=0;
        end
    endtask
    task read_expect(input [15:0] addr, input [31:0] expected);
        begin read_word(addr,q); check(q===expected,"CSR readback"); end
    endtask
    initial begin
        repeat(4) @(negedge clk); rst_n=1;
        read_expect(16'h0000,32'hA0486501);
        read_expect(16'h0400,32'h50533201);
        read_expect(16'h0404,0); read_expect(16'h0500,0);
        read_expect(16'h0410,1); // guest initially held in reset
        write_word(16'h0020,2,0,3);
        read_expect(16'h0420,0); write_word(16'h0430,0,4,0);
        read_expect(16'h0410,6);
        write_word(16'h0440,32'hA5,0,5);
        read_expect(16'h0450,1); read_expect(16'h0410,10);
        check(tx_valid && tx_data==8'hA5,"queued actual AXI byte");
        @(negedge clk); tx_ready=1; @(negedge clk); tx_ready=0;
        read_expect(16'h0410,18); check(tx_count==1,"one native byte after skewed AW/W");
        @(negedge clk); tx_done=1; @(negedge clk); tx_done=0;
        read_expect(16'h0410,98); read_expect(16'h0410,98);
        write_word(16'h0460,0); read_expect(16'h0410,610); // stale ACK retains completion
        write_word(16'h04A0,2); write_word(16'h0460,1);
        read_expect(16'h0410,6);
        write_word(16'h0440,32'h5A,2,0,1); // new path must preserve WSTRB
        read_expect(16'h0450,1); read_expect(16'h0410,514);
        write_word(16'h04A0,2);
        write_word(16'h0444,32'h5A); read_expect(16'h0450,1);
        read_expect(16'h0410,6); // lane alias must not submit
        @(negedge clk); rx_valid=1; rx_data=8'hFD; rx_error=3;
        @(negedge clk); rx_valid=0;
        read_expect(16'h0470,32'h3FD); read_expect(16'h0480,1);
        write_word(16'h0490,2); read_expect(16'h0410,642);
        write_word(16'h04A0,2); write_word(16'h0490,1); read_expect(16'h0410,6);
        write_word(16'h0440,32'hFA);
        @(negedge clk); frozen=1; #1; check(!tx_valid,"forensic guest reset gates queued TX");
        repeat(4) @(negedge clk); frozen=0;
        read_expect(16'h0420,1); read_expect(16'h0450,0); read_expect(16'h0410,0);
        write_word(16'h0430,0); read_expect(16'h0410,512);
        write_word(16'h04A0,2); write_word(16'h0430,1); read_expect(16'h0410,6);
        write_word(16'h0020,1,3,0); read_expect(16'h0420,2); read_expect(16'h0410,1);
        $display("PS2-MGMT-OK checks=%0d native_transfers=%0d command_pulses=%0d",checks,tx_count,write_pulses);
        $finish;
    end
    initial begin #1000000; $fatal(1,"PS2 management test timeout"); end
endmodule
`default_nettype wire
