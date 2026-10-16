`timescale 1ns/1ps
// Exact hosted-endpoint contract, not a universal physical keyboard model.
// The real RTL device sees only wired-AND pins; reset/AA affects the 8042
// alone. A software-like producer retries only an explicit tx_aborted event.
// All DUT accesses are ports. No internal writes, force or saved state.
module tb_hosted_resync;
    parameter integer HZ = 40000000;
    localparam integer HALF = (HZ+24999)/25000;
    localparam integer CELL = 2*HALF;
    localparam integer IDLE = (HZ+9999)/10000;
    reg clk=0, ctrl_rst_n=0, dev_rst_n=0;
    always #5 clk=~clk; // Logical cycle count; HZ sets serial phase lengths.
    reg mouse, reset_case;
    integer point, phase_bit;
    reg phase_low;
    reg [3:0] address=0;
    reg rd=0, wr=0;
    reg [7:0] wdata=0;
    wire [7:0] rdata;
    wire kc,kd,mc,md,dc,dd;
    wire hc=mouse ? mc : kc;
    wire hd=mouse ? md : kd;
    wire irqk,irqm,a20,oa20,oreset;
    reg tx_valid=0;
    reg [7:0] tx_data=0;
    wire tx_ready,tx_done,tx_abort,rx_valid,rx_abort;
    wire [7:0] rx_data;
    wire [1:0] rx_error;
    integer completed=0,aborted=0,edges=0;
    integer before_completed,before_aborted,i,n;
    reg [7:0] value,status,got;
    reg [10:0] frame;
    always @(posedge clk) begin
        if (tx_done) completed <= completed+1;
        if (tx_abort) aborted <= aborted+1;
        if (rx_valid || rx_abort) $fatal(1,"unexpected host command/event");
    end
    // Counts the actual endpoint clock, independently of endpoint internals.
    always @(negedge dc) if (dev_rst_n && hc) edges=edges+1;
    ven_ps2_device #(.CLK_HZ(HZ)) device (
        .clk(clk),.rst_n(dev_rst_n),.tx_valid(tx_valid),.tx_data(tx_data),
        .tx_ready(tx_ready),.tx_done(tx_done),.tx_aborted(tx_abort),
        .rx_valid(rx_valid),.rx_data(rx_data),.rx_error(rx_error),
        .rx_ready(1'b0),.rx_aborted(rx_abort),
        .host_clk_release(hc),.host_dat_release(hd),
        .dev_clk_release(dc),.dev_dat_release(dd));
    ps2 controller (
        .clk(clk),.rst_n(ctrl_rst_n),.irq_keyb(irqk),.irq_mouse(irqm),
        .io_address(address),.io_read(rd),.io_readdata(rdata),
        .io_write(wr),.io_writedata(wdata),.io_cs(1'b1),.ctl_cs(1'b0),
        .output_a20_enable(oa20),.output_reset_n(oreset),.a20_enable(a20),
        .ps2_kbclk(kc & (mouse ? 1'b1 : dc)),
        .ps2_kbdat(kd & (mouse ? 1'b1 : dd)),
        .ps2_mouseclk(mc & (mouse ? dc : 1'b1)),
        .ps2_mousedat(md & (mouse ? dd : 1'b1)),
        .ps2_kbclk_out(kc),.ps2_kbdat_out(kd),
        .ps2_mouseclk_out(mc),.ps2_mousedat_out(md));
    task write_io(input [3:0] addr,input [7:0] data);
        begin
            @(negedge clk); address=addr; wdata=data; wr=1;
            @(negedge clk); wr=0;
            repeat (3) @(negedge clk);
        end
    endtask
    task read_io(input [3:0] addr,output [7:0] data);
        begin
            @(negedge clk); address=addr; rd=1;
            @(posedge clk); #1; data=rdata;
            @(negedge clk); rd=0;
            repeat (3) @(negedge clk);
        end
    endtask
    task queue(input [7:0] data);
        begin
            n=0;
            while (!tx_ready && n<20000) begin @(negedge clk); n=n+1; end
            if (!tx_ready) $fatal(1,"endpoint ownership stuck");
            @(negedge clk); tx_data=data; tx_valid=1;
            @(negedge clk); tx_valid=0;
        end
    endtask
    task check_byte(input [7:0] expected,input auxiliary);
        begin
            n=0; status=0;
            while (!status[0] && n<20000) begin read_io(4,status); n=n+5; end
            if (!status[0] || status[5] !== auxiliary || |status[7:6])
                $fatal(1,"bad receive status %02x expected AUX=%b",status,auxiliary);
            read_io(0,got);
            if (got !== expected) $fatal(1,"wrong/missing byte got=%02x expected=%02x",got,expected);
        end
    endtask
    task no_output;
        begin
            read_io(4,status);
            if (status[0] || |status[7:6] || irqk || irqm)
                $fatal(1,"stale/extra receive or error status=%02x",status);
        end
    endtask
    initial begin
        if (!$value$plusargs("mouse=%d",mouse) ||
            !$value$plusargs("reset=%d",reset_case) ||
            !$value$plusargs("point=%d",point)) $fatal(1,"missing matrix selectors");
        // start-low, data0-high, data3-low, data7-high, parity high/low,
        // stop high/low and completed idle. All are physical-pin positions.
        case (point)
            0: begin phase_bit=0; phase_low=1; end
            1: begin phase_bit=1; phase_low=0; end
            2: begin phase_bit=4; phase_low=1; end
            3: begin phase_bit=8; phase_low=0; end
            4: begin phase_bit=9; phase_low=0; end
            5: begin phase_bit=9; phase_low=1; end
            6: begin phase_bit=10; phase_low=0; end
            7: begin phase_bit=10; phase_low=1; end
            8: begin phase_bit=11; phase_low=0; end
            default: $fatal(1,"bad point");
        endcase
        value=mouse ? 8'ha5 : 8'h5a;
        repeat (8) @(negedge clk);
        ctrl_rst_n=1; dev_rst_n=1;
        repeat (9000) @(negedge clk);
        write_io(4,8'h60); write_io(0,8'h43); // translated, both IRQs
        no_output;
        queue(value);
        @(negedge dd); // start bit, then advance through actual full cells
        for (i=0;i<phase_bit;i=i+1) begin @(negedge dc); @(posedge dc); end
        if (phase_bit<11) begin
            if (phase_low) @(negedge dc);
            repeat (HALF/2) @(negedge clk);
        end else repeat (IDLE/2+32) @(negedge clk);
        if (edges !== (phase_bit+(phase_low ? 1 : 0)))
            $fatal(1,"phase was not actually exercised edges=%0d",edges);
        before_completed=completed; before_aborted=aborted;
        if (reset_case) begin
            @(negedge clk); ctrl_rst_n=0;
            repeat (4) @(negedge clk); ctrl_rst_n=1;
        end else write_io(4,8'haa);
        // Do not reset/requeue the endpoint on AA/reset. Only its real abort
        // event permits retry. A completed byte is intentionally flushed.
        repeat (16) @(negedge clk);
        if (hc !== 0) $fatal(1,"RESYNC-INHIBIT-MISSING");
        if (point<8) begin
            if (aborted != before_aborted+1 || completed != before_completed)
                $fatal(1,"abort/completion ownership mismatch");
        end else if (aborted != before_aborted || completed != 1)
            $fatal(1,"completed byte was spuriously aborted");
        repeat (8300) @(negedge clk);
        if (!reset_case) check_byte(8'h55,0);
        no_output;
        // Fresh transmission must have all eleven correct wire bits, never
        // a suffix from the interrupted frame. The producer retries once.
        queue(value); frame={1'b1,~^value,value,1'b0};
        for (i=0;i<11;i=i+1) begin
            @(negedge dc);
            if ((hd & dd) !== frame[i]) $fatal(1,"retry wire bit/parity mismatch bit=%0d",i);
            @(posedge dc);
        end
        repeat (64) @(negedge clk);
        check_byte(mouse ? value : 8'h1c,mouse);
        if (completed != before_completed+1 || aborted != before_aborted+(point<8))
            $fatal(1,"retry completion count mismatch");
        repeat (IDLE+CELL) @(negedge clk); no_output;
        $display("HOSTED-RESYNC-OK hz=%0d mouse=%0d reset=%0d point=%0d aborts=%0d completed=%0d edges=%0d",
                 HZ,mouse,reset_case,point,aborted,completed,edges);
        $finish;
    end
    initial begin
        repeat (300000) @(posedge clk);
        $fatal(1,"bounded hosted-resync timeout");
    end
endmodule
