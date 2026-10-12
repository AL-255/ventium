`timescale 1ps/1ps
`default_nettype none
// Interactive system-boundary test. Python owns only AXI transactions, guest
// port I/O and elapsed time. No controller/FIFO/IRQ/serial state is forced.
module tb_ps2_adapter_path;
    parameter integer HZ = 40000000;
    localparam integer HALF_PS = 500000000000 / HZ;
    reg clk=0; always #HALF_PS clk=~clk;
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
    wire tx_valid, tx_ready, tx_done, tx_aborted, rx_valid, rx_ready, rx_aborted;
    wire [7:0] tx_data, rx_data;
    wire [1:0] rx_error;
    wire guest_reset=!rst_n || !core_reset_n || frozen;
    wire hc, hd, dc, dd, irq_mouse, irq_keyb;
    reg [3:0] io_address=0;
    reg io_read=0, io_write=0;
    reg [7:0] io_writedata=0;
    wire [7:0] io_readdata;
    wire unused_a20, unused_output_a20, unused_reset, unused_kc, unused_kd;
    integer transactions=0, write_pulses=0, frames=0, received=0, aborts=0;
    integer wire_bits=0;
    reg wire_owned=0;
    reg [10:0] expected_frame;
    reg [63:0] cycles=0;
    always @(posedge clk) begin
        cycles<=cycles+1;
        if (rst_n && mouse_wr) write_pulses=write_pulses+1;
        if (rst_n && (dbg_clear || dbg_step || cap_arm || kbd_valid))
            $fatal(1,"ADAPTER-PATH unrelated command alias");
        if (guest_reset) begin wire_owned=0; wire_bits=0; end
        else begin
            if (tx_valid && tx_ready) begin
                if (wire_owned) $fatal(1,"ADAPTER-PATH overlapping serial ownership");
                wire_owned=1; wire_bits=0;
                expected_frame={1'b1,~^tx_data,tx_data,1'b0};
            end
            if (tx_done) begin
                if (!wire_owned || wire_bits!=11)
                    $fatal(1,"ADAPTER-PATH delivery without full frame");
                frames=frames+1; wire_owned=0;
            end
            if (tx_aborted) begin aborts=aborts+1; wire_owned=0; end
            if (rx_valid && rx_ready) begin
                if (rx_error!=0) $fatal(1,"ADAPTER-PATH bad host frame");
                received=received+1;
            end
            if (rx_aborted) $fatal(1,"ADAPTER-PATH unexpected host truncation");
        end
    end
    always @(negedge dc) if (!guest_reset && wire_owned) begin
        if (wire_bits>=11 || (hd & dd)!==expected_frame[wire_bits])
            $fatal(1,"ADAPTER-PATH wire data/parity mismatch bit=%0d",wire_bits);
        wire_bits=wire_bits+1;
    end

    // The runner inserts the exact, complete ven_mgmt_axil instance from the
    // existing management test here, pinning both source files. This avoids
    // maintaining a second divergent list of the debug/capture tie-offs.
    // @ACTUAL_MANAGEMENT_INSTANCE@

    ven_ps2_mailbox mailbox (
        .clk(clk), .rst_n(rst_n), .guest_reset(guest_reset),
        .csr_write(mouse_wr), .csr_waddr(mouse_wa), .csr_wdata(mouse_wd),
        .csr_wstrb(mouse_ws), .csr_raddr(mouse_ra), .csr_rdata(mouse_rd),
        .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready),
        .tx_done(tx_done), .tx_aborted(tx_aborted), .rx_valid(rx_valid),
        .rx_data(rx_data), .rx_error(rx_error), .rx_ready(rx_ready), .rx_aborted(rx_aborted));
    ven_ps2_device #(.CLK_HZ(HZ)) device (
        .clk(clk), .rst_n(!guest_reset), .tx_valid(tx_valid), .tx_data(tx_data),
        .tx_ready(tx_ready), .tx_done(tx_done), .tx_aborted(tx_aborted),
        .rx_valid(rx_valid), .rx_data(rx_data), .rx_error(rx_error),
        .rx_ready(rx_ready), .rx_aborted(rx_aborted),
        .host_clk_release(hc), .host_dat_release(hd),
        .dev_clk_release(dc), .dev_dat_release(dd));
    ps2 controller (
        .clk(clk), .rst_n(!guest_reset), .irq_keyb(irq_keyb), .irq_mouse(irq_mouse),
        .io_address(io_address), .io_read(io_read), .io_readdata(io_readdata),
        .io_write(io_write), .io_writedata(io_writedata), .io_cs(1'b1), .ctl_cs(1'b0),
        .output_a20_enable(unused_output_a20), .output_reset_n(unused_reset),
        .a20_enable(unused_a20), .ps2_kbclk(1'b1), .ps2_kbdat(1'b1),
        .ps2_kbclk_out(unused_kc), .ps2_kbdat_out(unused_kd),
        .ps2_mouseclk(hc & dc), .ps2_mousedat(hd & dd),
        .ps2_mouseclk_out(hc), .ps2_mousedat_out(hd));

    task axi_write(input [15:0] address, input [31:0] value);
        integer before_pulses;
        begin
            before_pulses=write_pulses;
            fork
                begin
                    repeat(transactions%3) @(negedge clk);
                    @(negedge clk); awaddr=address; awvalid=1;
                    do @(posedge clk); while(!awready);
                    @(negedge clk); awvalid=0;
                end
                begin
                    repeat(2-transactions%3) @(negedge clk);
                    @(negedge clk); wdata=value; wvalid=1;
                    do @(posedge clk); while(!wready);
                    @(negedge clk); wvalid=0;
                end
            join
            wait(bvalid);
            repeat(3) begin
                @(negedge clk);
                if (!bvalid || bresp!=0) $fatal(1,"ADAPTER-PATH unstable B");
            end
            bready=1; @(negedge clk); bready=0;
            if (write_pulses-before_pulses!=((address[11:8]==4 && address[3:0]==0)?1:0))
                $fatal(1,"ADAPTER-PATH command duplication/loss");
        end
    endtask
    task axi_read(input [15:0] address, output [31:0] value);
        begin
            @(negedge clk); araddr=address; arvalid=1;
            do @(posedge clk); while(!arready);
            @(negedge clk); arvalid=0; araddr=16'h0050;
            wait(rvalid); value=rdata;
            repeat(3) begin
                @(negedge clk);
                if (!rvalid || rresp!=0 || rdata!==value)
                    $fatal(1,"ADAPTER-PATH unstable R");
            end
            rready=1; @(negedge clk); rready=0;
        end
    endtask
    task io_wr(input [3:0] address, input [7:0] value);
        @(negedge clk); io_address=address; io_writedata=value; io_write=1;
        @(negedge clk); io_write=0;
        repeat(3) @(negedge clk);
    endtask
    task io_rd(input [3:0] address, output [7:0] value);
        @(negedge clk); io_address=address; io_read=1;
        @(posedge clk); #1; value=io_readdata;
        @(negedge clk); io_read=0;
        repeat(3) @(negedge clk);
    endtask
    integer op, address, value, scanned;
    reg [31:0] answer;
    reg [7:0] port_byte;
    initial begin
        repeat(8) @(negedge clk); rst_n=1;
        repeat(8) @(negedge clk);
        $display("READY ADAPTER-PATH %0d",HZ); $fflush();
        forever begin
            scanned=$fscanf(32'h80000000,"%d %h %h",op,address,value);
            if (scanned!=3) $fatal(1,"ADAPTER-PATH truncated request");
            transactions=transactions+1; answer=0;
            case(op)
                0: begin
                    $display("DONE %0d %0d %0d %0d %0d",transactions,frames,received,aborts,cycles);
                    $fflush(); $finish;
                end
                1: axi_read(16'(address),answer);
                2: axi_write(16'(address),32'(value));
                3: begin io_rd(4'(address),port_byte); answer={24'd0,port_byte}; end
                4: io_wr(4'(address),8'(value));
                5: begin
                    if(value<0 || value>HZ/100) $fatal(1,"ADAPTER-PATH invalid wait");
                    repeat(value) @(negedge clk);
                end
                6: answer={30'd0,irq_keyb,irq_mouse};
                default: $fatal(1,"ADAPTER-PATH unknown request");
            endcase
            $display("RESULT %0d %08x %0d",transactions,answer,cycles); $fflush();
        end
    end
    initial begin #2000000000000; $fatal(1,"ADAPTER-PATH virtual timeout"); end
endmodule
`default_nettype wire
