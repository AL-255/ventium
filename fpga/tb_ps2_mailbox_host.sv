`timescale 1ns/1ps
// Interactive CSR test of the actual mailbox. The serial transport is an
// explicit input BFM; this is not a PS/2 wire, AXI-Lite, or OS-driver test.
module tb_ps2_mailbox_host;
    reg clk=0, rst_n=0, guest_reset=1;
    always #12.5 clk=~clk;
    reg csr_write=0;
    reg [3:0] csr_waddr=0, csr_raddr=0;
    reg [31:0] csr_wdata=0;
    wire [31:0] csr_rdata;
    wire tx_valid, rx_ready;
    wire [7:0] tx_data;
    reg tx_ready=0, tx_done=0, tx_aborted=0;
    reg rx_valid=0, rx_aborted=0;
    reg [7:0] rx_data=0;
    reg [1:0] rx_error=0;
    ven_ps2_mailbox dut (
        .clk(clk), .rst_n(rst_n), .guest_reset(guest_reset),
        .csr_write(csr_write), .csr_waddr(csr_waddr), .csr_wdata(csr_wdata),
        .csr_wstrb(4'hf), .csr_raddr(csr_raddr), .csr_rdata(csr_rdata),
        .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready),
        .tx_done(tx_done), .tx_aborted(tx_aborted),
        .rx_valid(rx_valid), .rx_data(rx_data), .rx_error(rx_error),
        .rx_ready(rx_ready), .rx_aborted(rx_aborted)
    );
    integer operation, scanned, commands=0;
    reg [31:0] address, value;
    initial begin
        repeat(8) @(negedge clk); rst_n=1;
        repeat(4) @(negedge clk);
        $display("READY MAILBOX-CSR"); $fflush();
        forever begin
            scanned=$fscanf(32'h80000000,"%d %h %h",operation,address,value);
            if (scanned != 3) $fatal(1,"invalid host test command");
            commands=commands+1;
            case(operation)
                0: begin
                    $display("DONE %0d",commands); $fflush(); $finish;
                end
                1: begin
                    if (address > 15) $fatal(1,"CSR address range");
                    @(negedge clk); csr_raddr=address[3:0]; #1;
                    $display("READ %08x",csr_rdata); $fflush();
                end
                2: begin
                    if (address > 15) $fatal(1,"CSR address range");
                    @(negedge clk); csr_write=1; csr_waddr=address[3:0]; csr_wdata=value;
                    @(negedge clk); csr_write=0;
                    $display("OK"); $fflush();
                end
                3: begin
                    // Complete exactly one queued byte through public pins.
                    @(negedge clk);
                    if (!tx_valid) $fatal(1,"no queued transport byte");
                    tx_ready=1;
                    @(negedge clk); tx_ready=0;
                    tx_done=(value==1); tx_aborted=(value==0);
                    if (value > 1) $fatal(1,"bad completion");
                    @(negedge clk); tx_done=0; tx_aborted=0;
                    $display("TX %02x",tx_data); $fflush();
                end
                4: begin
                    @(negedge clk);
                    if (!rx_ready || value > 1023) $fatal(1,"RX cannot be admitted");
                    rx_data=value[7:0]; rx_error=value[9:8]; rx_valid=1;
                    @(negedge clk); rx_valid=0;
                    $display("OK"); $fflush();
                end
                5: begin
                    if (value > 1) $fatal(1,"bad reset level");
                    @(negedge clk); guest_reset=value[0];
                    repeat(3) @(negedge clk);
                    $display("OK"); $fflush();
                end
                6: begin
                    @(negedge clk); rx_aborted=1;
                    @(negedge clk); rx_aborted=0;
                    $display("OK"); $fflush();
                end
                default: $fatal(1,"unknown host test command");
            endcase
        end
    end
endmodule
