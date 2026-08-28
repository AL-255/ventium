`timescale 1ns/1ps

// Focused regression for the PS-published PIO completion contract.  The
// platform's dpram is intentionally modeled as a synchronous black-box RAM:
// these checks exercise status/request ownership, not buffer contents.
module dpram #(parameter AW=12, parameter DW=16) (
    input clock,
    input [AW-1:0] address_a, input [DW-1:0] data_a, input wren_a, output reg [DW-1:0] q_a,
    input [AW-1:0] address_b, input [DW-1:0] data_b, input wren_b, output reg [DW-1:0] q_b
);
    reg [DW-1:0] mem [0:(1<<AW)-1];
    always @(posedge clock) begin
        if (wren_a) mem[address_a] <= data_a;
        if (wren_b) mem[address_b] <= data_b;
        q_a <= mem[address_a];
        q_b <= mem[address_b];
    end
endmodule

module ide_completion_tb;
    reg clk = 0, rst_n = 0, use_fast = 0;
    reg [3:0] io_address = 0, mgmt_address = 0;
    reg io_read = 0, io_write = 0, io_32 = 0, mgmt_write = 0, mgmt_read = 0;
    reg [31:0] io_writedata = 0;
    reg [15:0] mgmt_writedata = 0;
    wire irq, drq, no_data, dbg_disable_irq, dbg_sw_reset, io_wait;
    wire [1:0] drive_en;
    wire [2:0] request;
    wire [31:0] io_readdata;
    wire [15:0] mgmt_readdata;

    always #5 clk = ~clk;

    ide dut (.*);

    task automatic mgmt_put(input [3:0] addr, input [15:0] data);
        begin
            @(negedge clk); mgmt_address = addr; mgmt_writedata = data; mgmt_write = 1;
            @(negedge clk); mgmt_write = 0;
        end
    endtask

    task automatic drain_sector;
        integer i;
        begin
            for (i = 0; i < 256; i = i + 1) begin
                @(negedge clk); io_address = 0; io_read = 1;
                @(negedge clk); io_read = 0;
            end
            repeat (3) @(negedge clk);
        end
    endtask

    task automatic check(input [7:0] got, input [7:0] expected, input [255:0] label);
        if (got !== expected) begin
            $display("FAIL %0s got=%02x expected=%02x", label, got, expected);
            $fatal(1);
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        // Make drive 0 present, provide a one-sector PIO buffer, then publish a
        // terminal read descriptor: status=58h (DRDY|DSC|DRQ), IRQ and END set.
        mgmt_put(6, 16'h0009);
        mgmt_put(0, 16'h0001);
        mgmt_put(5, 16'h5e00);
        check({7'd0, irq}, 8'h01, "terminal descriptor initially raises IRQ");
        // BIOS polling clears the descriptor IRQ before the PIO drain.  The
        // terminal transition must raise it again to wake STI; HLT.
        @(negedge clk); io_address = 7; io_read = 1;
        @(negedge clk); io_read = 0;
        check({7'd0, irq}, 8'h00, "status poll clears early IRQ");
        drain_sector();
        check(dut.status, 8'h50, "terminal retains DRDY|DSC and clears DRQ");
        check({5'd0, request}, 8'h00, "terminal does not request another block");
        check({7'd0, drq}, 8'h00, "terminal drops DRQ");
        check({7'd0, irq}, 8'h01, "terminal completion reasserts IRQ after drain");

        // A held old io_done record must not overwrite the next command's BSY
        // status before the daemon publishes a successor descriptor.
        @(negedge clk); io_address = 7; io_writedata = 32'h20; io_write = 1;
        @(negedge clk); io_write = 0;
        repeat (3) @(negedge clk);
        check(dut.status, 8'h80, "new command is not overwritten by old completion");

        // A non-terminal descriptor must still enter BSY and retain the held
        // request until a fresh word-5 publication consumes it.
        mgmt_put(5, 16'h5c00);
        drain_sector();
        check(dut.status, 8'h80, "nonterminal becomes busy");
        check({5'd0, request}, 8'h05, "nonterminal requests next block");
        mgmt_put(5, 16'h5e00);
        check({5'd0, request}, 8'h00, "new descriptor clears held request");
        $display("IDE-COMPLETION-TB-OK");
        $finish;
    end
endmodule
