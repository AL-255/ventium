`timescale 1ns/1ps
// Real FPGA keyboard serializer + real 8042/FIFO. Ordinary guest I/O creates
// pressure; hierarchical signals are read-only witnesses, never stimulus.
module tb_kbd_backpressure;
    parameter integer HZ=40000000;
    localparam integer HALF=(64'd128*HZ+3124999)/3125000;
    localparam integer CELL=2*HALF;
    reg clk=0,rst_n=0,valid=0,rd=0,wr=0;
    reg [7:0] data=0,wdata=0;
    reg [3:0] address=0;
    wire ready,busy,dc,dd,kc,kd,mc,md,irqk,irqm;
    wire [7:0] rdata;
    integer during,translated,flip,i,n,edges=0,frames=0,old_edges,pending_seen=0;
    reg [7:0] status,got,first,second;
    reg [10:0] wire_frame;
    always #5 clk=~clk;
    ven_ps2_kbd_inject #(.CLK_HZ(HZ)) device (
        .clk(clk),.rst_n(rst_n),.inject_valid(valid),.inject_data(data),
        .inject_ready(ready),.inject_busy(busy),
        .host_clk_release(kc),.host_dat_release(kd),
        .dev_clk_release(dc),.dev_dat_release(dd));
    ps2 controller (
        .clk(clk),.rst_n(rst_n),.irq_keyb(irqk),.irq_mouse(irqm),
        .io_address(address),.io_read(rd),.io_readdata(rdata),
        .io_write(wr),.io_writedata(wdata),.io_cs(1'b1),.ctl_cs(1'b0),
        .output_a20_enable(),.output_reset_n(),.a20_enable(),
        .ps2_kbclk(kc & dc),.ps2_kbdat(kd & dd),
        .ps2_mouseclk(mc),.ps2_mousedat(md),
        .ps2_kbclk_out(kc),.ps2_kbdat_out(kd),
        .ps2_mouseclk_out(mc),.ps2_mousedat_out(md));
    always @(negedge dc) if(rst_n) begin
        if(!kc) $fatal(1,"KBD-BACKPRESSURE-INVISIBLE-EDGE");
        wire_frame[edges%11]=kd & dd;
        edges=edges+1;
        if(edges%11==0) begin
            if(wire_frame[0]!==0 || wire_frame[10]!==1 || (^wire_frame[9:1])!==1'b1 ||
               wire_frame[8:1] !== (frames==0 ? 8'h5a : 8'h1d) || frames>=2)
                $fatal(1,"KBD-BACKPRESSURE-FRAME got=%03x frames=%0d",wire_frame,frames);
            frames=frames+1;
        end
    end
    task write_io(input [3:0] addr,input [7:0] value);
        begin
            @(negedge clk);address=addr;wdata=value;wr=1;
            @(negedge clk);wr=0;repeat(3) @(negedge clk);
        end
    endtask
    task read_io(input [3:0] addr,output [7:0] value);
        begin
            @(negedge clk);address=addr;rd=1;
            @(posedge clk);#1;value=rdata;
            @(negedge clk);rd=0;repeat(3) @(negedge clk);
        end
    endtask
    task queue(input [7:0] value);
        begin
            if(!ready || busy) $fatal(1,"KBD-BACKPRESSURE-NO-CREDIT");
            @(negedge clk);data=value;valid=1;
            @(negedge clk);valid=0;
            if(ready || !busy) $fatal(1,"KBD-BACKPRESSURE-NO-OWNER");
        end
    endtask
    task completed;
        begin
            n=0;
            while(!ready && n<2*8192+12*CELL+256) begin @(negedge clk);n=n+1;end
            if(!ready || busy) $fatal(1,"KBD-BACKPRESSURE-COMPLETE-TIMEOUT");
            repeat(64) @(negedge clk);
        end
    endtask
    task check_byte(input [7:0] value);
        begin
            n=0;status=0;
            while(!status[0] && n<2*8192+12*CELL+256) begin read_io(4,status);n=n+5;end
            if(!status[0] || status[5] || |status[7:6] || !irqk || irqm)
                $fatal(1,"KBD-BACKPRESSURE-STATUS got=%02x",status);
            read_io(0,got);
            if(got!==value) $fatal(1,"KBD-BACKPRESSURE-DATA got=%02x expected=%02x",got,value);
        end
    endtask
    task held;
        begin
            old_edges=edges;
            repeat(2*8192+64) begin
                @(negedge clk);
                if(ready || !busy || edges!=old_edges || kc)
                    $fatal(1,"KBD-BACKPRESSURE-HELD-OWNER");
            end
        end
    endtask
    task filler(input integer index);
        begin
            // Both revisions limit ordinary D2 replies to <60 entries. Real
            // headless keyboard ACKs can consume the remaining FIFO slots.
            if(index<59) begin write_io(4,8'hd2);write_io(0,8'h80+8'(index));end
            else begin write_io(0,8'hf4);repeat(8) @(negedge clk);end
        end
    endtask
    task configure(input integer mode);
        begin write_io(4,8'h60);write_io(0,mode ? 8'h43 : 8'h03);end
    endtask
    initial begin
        if(!$value$plusargs("during=%d",during) || during<0 || during>1 ||
           !$value$plusargs("translate=%d",translated) || translated<0 || translated>1 ||
           !$value$plusargs("flip=%d",flip) || flip<0 || flip>1)
            $fatal(1,"KBD-BACKPRESSURE-SELECTOR");
        first=translated ? 8'h1c : 8'h5a;
        second=(translated^flip) ? 8'h11 : 8'h1d;
        repeat(8) @(negedge clk);rst_n=1;repeat(9000) @(negedge clk);
        configure(translated);
        // Keep the legacy controller out of its physical SEND path while
        // filling before reception. Re-enable through the command byte below.
        if(!during) begin write_io(4,8'h60);write_io(0,translated ? 8'h53 : 8'h13);end
        for(i=0;i<(during ? 59 : 64);i=i+1) filler(i);
        if(during) begin
            if(!kc || controller.keyb_fifo_counter!=59) $fatal(1,"KBD-BACKPRESSURE-START");
            queue(8'h5a);@(negedge dc);repeat(16) @(negedge clk);
            for(i=59;i<64;i=i+1) filler(i);
            if(!controller.keyb_fifo_full || frames!=0) $fatal(1,"KBD-BACKPRESSURE-FILL-RACE");
            completed;
`ifdef CHECK_RETAINED
            if(!controller.kb_rx_pending || controller.kb_rx_pending_data!==first)
                $fatal(1,"KBD-BACKPRESSURE-PENDING");
            pending_seen=1;
`endif
            queue(8'h1d);
            if(flip) configure(!translated);
            held;
            for(i=0;i<64;i=i+1) check_byte(i<59 ? 8'h80+8'(i) : 8'hfa);
            check_byte(first);completed;check_byte(second);
        end else begin
            configure(translated);
            repeat(32) @(negedge clk);
            if(!controller.keyb_fifo_full || kc) $fatal(1,"KBD-BACKPRESSURE-FULL");
            queue(8'h5a);held;
            for(i=0;i<64;i=i+1) check_byte(i<59 ? 8'h80+8'(i) : 8'hfa);
            completed;
            if(flip) configure(!translated);
            check_byte(first);queue(8'h1d);completed;check_byte(second);
        end
        repeat(8192+12*CELL) @(negedge clk);read_io(4,status);
        if(status[0] || status[5] || |status[7:6] || irqk || irqm ||
           !controller.keyb_fifo_empty || !ready || busy || frames!=2 || edges!=22)
            $fatal(1,"KBD-BACKPRESSURE-EXTRA-OR-ERROR");
        $display("KBD-BACKPRESSURE-OK hz=%0d during=%0d translate=%0d flip=%0d frames=2 reads=66 pending=%0d",HZ,during,translated,flip,pending_seen);
        $finish;
    end
    initial begin repeat(300000) @(posedge clk);$fatal(1,"KBD-BACKPRESSURE-TIMEOUT");end
endmodule
