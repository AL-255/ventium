`timescale 1ns/1ps
// Actual management slave -> actual transmitter -> actual retained 8042.
// AXI-Lite and guest I/O are the only stimulus interfaces. This is not the
// complete PL wrapper: CPU, DDR, video and forensic freeze are not instantiated.
module tb_kbd_mmio;
    parameter integer HZ=40000000;
    localparam integer HALF=(64'd128*HZ+3124999)/3125000;
    localparam integer IDLE=(64'd80*HZ+3124999)/3125000;
    reg clk=0,resetn=0;
    always #5 clk=~clk;
    reg [15:0] awaddr=0,araddr=0;
    reg [31:0] wdata=0;
    reg awvalid=0,wvalid=0,bready=0,arvalid=0,rready=0;
    wire awready,wready,bvalid,arready,rvalid;
    wire [1:0] bresp,rresp;
    wire [31:0] rdata;
    wire [7:0] inject_data;
    wire inject_valid,ready,busy,core_reset_n;
    wire guest_reset_n=resetn & core_reset_n;
    ven_mgmt_axil management (
        .clk(clk),.rst_n(resetn),
        .s_awaddr(awaddr),.s_awvalid(awvalid),.s_awready(awready),
        .s_wdata(wdata),.s_wstrb(4'hf),.s_wvalid(wvalid),.s_wready(wready),
        .s_bresp(bresp),.s_bvalid(bvalid),.s_bready(bready),
        .s_araddr(araddr),.s_arvalid(arvalid),.s_arready(arready),
        .s_rdata(rdata),.s_rresp(rresp),.s_rvalid(rvalid),.s_rready(rready),
        .kbd_inject_data(inject_data),.kbd_inject_valid(inject_valid),
        .kbd_inject_ready(ready),.kbd_inject_busy(busy),.core_reset_n(core_reset_n));
    wire dc,dd,kc,kd,mc,md,irqk,irqm;
    ven_ps2_kbd_inject #(.CLK_HZ(HZ)) device (
        .clk(clk),.rst_n(guest_reset_n),.inject_valid(inject_valid),.inject_data(inject_data),
        .inject_ready(ready),.inject_busy(busy),.host_clk_release(kc),.host_dat_release(kd),
        .dev_clk_release(dc),.dev_dat_release(dd));
    reg [3:0] io_addr=0;
    reg [7:0] io_data=0;
    reg io_rd=0,io_wr=0;
    wire [7:0] io_result;
    ps2 controller (
        .clk(clk),.rst_n(guest_reset_n),.irq_keyb(irqk),.irq_mouse(irqm),
        .io_address(io_addr),.io_read(io_rd),.io_readdata(io_result),
        .io_write(io_wr),.io_writedata(io_data),.io_cs(1'b1),.ctl_cs(1'b0),
        .output_a20_enable(),.output_reset_n(),.a20_enable(),
        .ps2_kbclk(kc & dc),.ps2_kbdat(kd & dd),.ps2_mouseclk(mc),.ps2_mousedat(md),
        .ps2_kbclk_out(kc),.ps2_kbdat_out(kd),.ps2_mouseclk_out(mc),.ps2_mousedat_out(md));
    integer order,inhibit,i,n,submits=0;
    reg [31:0] value;
    reg [7:0] status,got;
    reg [10:0] expected;
    always @(posedge clk) if(resetn && inject_valid) submits=submits+1;

    task write_csr(input [15:0] addr,input [31:0] data);
        integer waits;
        begin
            @(negedge clk);awaddr=addr;wdata=data;bready=0;
            awvalid=(order!=2);wvalid=(order!=1);
            if(order!=0) begin
                repeat(4) begin
                    @(posedge clk);#1;
                    if(awready || wready || bvalid) $fatal(1,"write accepted without both channels");
                end
                @(negedge clk);awvalid=1;wvalid=1;
            end
            waits=0;
            do begin
                @(posedge clk);#1;waits=waits+1;
                if(waits>40) $fatal(1,"AW/W timeout");
            end while(!(awready && wready));
            // Hold both payloads through the actual registered-ready handshake.
            @(posedge clk);
            @(negedge clk);awvalid=0;wvalid=0;
            waits=0;
            while(!bvalid) begin
                @(posedge clk);#1;waits=waits+1;
                if(waits>40) $fatal(1,"B timeout");
            end
            repeat(5) begin
                @(posedge clk);#1;
                if(bvalid!==1 || bresp!==0) $fatal(1,"B backpressure response changed");
            end
            @(negedge clk);bready=1;
            @(posedge clk);#1;
            @(negedge clk);bready=0;
        end
    endtask
    task read_csr(input [15:0] addr,output [31:0] data);
        integer waits;
        begin
            @(negedge clk);araddr=addr;arvalid=1;rready=0;waits=0;
            do begin
                @(posedge clk);#1;waits=waits+1;
                if(waits>40) $fatal(1,"AR timeout");
            end while(!arready);
            @(posedge clk);
            @(negedge clk);arvalid=0;waits=0;
            while(!rvalid) begin
                @(posedge clk);#1;waits=waits+1;
                if(waits>40) $fatal(1,"R timeout");
            end
            data=rdata;
            repeat(5) begin
                @(posedge clk);#1;
                if(rvalid!==1 || rdata!==data || rresp!==0) $fatal(1,"R backpressure response changed");
            end
            @(negedge clk);rready=1;
            @(posedge clk);#1;
            @(negedge clk);rready=0;
        end
    endtask
    task write_io(input [3:0] addr,input [7:0] data);
        begin
            @(negedge clk);io_addr=addr;io_data=data;io_wr=1;
            @(negedge clk);io_wr=0;repeat(3) @(negedge clk);
        end
    endtask
    task read_io(input [3:0] addr,output [7:0] data);
        begin
            @(negedge clk);io_addr=addr;io_rd=1;
            @(posedge clk);#1;data=io_result;
            @(negedge clk);io_rd=0;repeat(3) @(negedge clk);
        end
    endtask
    task queue(input [7:0] data);
        begin
            read_csr(16'h390,value);
            if(value!==1) $fatal(1,"MMIO queue lacks credit %08x",value);
            write_csr(16'h380,{23'd0,1'b1,data});
            read_csr(16'h390,value);
            if(value!==2) $fatal(1,"MMIO byte not owned %08x",value);
        end
    endtask
    task check_byte(input [7:0] data);
        begin
            n=0;status=0;
            while(!status[0] && n<20000) begin read_io(4,status);n=n+5;end
            if(!status[0] || status[5] || |status[7:6] || !irqk || irqm)
                $fatal(1,"controller status/IRQ mismatch %02x",status);
            read_io(0,got);
            if(got!==data) $fatal(1,"received %02x expected %02x",got,data);
        end
    endtask
    task no_output;
        begin
            read_io(4,status);
            if(status[0] || |status[7:6] || irqk || irqm) $fatal(1,"duplicate/error output %02x",status);
        end
    endtask
    task wire_byte(input [7:0] data);
        begin
            expected={1'b1,~^data,data,1'b0};
            for(i=0;i<11;i=i+1) begin
                @(negedge dc);
                if(!kc || (kd & dd)!==expected[i]) $fatal(1,"wire bit/parity mismatch %0d",i);
                @(posedge dc);
            end
            repeat(64) @(negedge clk);
            read_csr(16'h390,value);
            if(value!==1) $fatal(1,"completed frame still owned %08x",value);
        end
    endtask
    initial begin
        if(!$value$plusargs("order=%d",order) || order<0 || order>2 ||
           !$value$plusargs("inhibit=%d",inhibit) || inhibit<0 || inhibit>1)
            $fatal(1,"invalid test selectors");
        repeat(8) @(negedge clk);resetn=1;
        read_csr(16'h3a0,value);
        if(value!==32'h564b0001) $fatal(1,"wrong keyboard capability %08x",value);
        write_csr(16'h020,32'd2); // Release guest reset through the actual management register.
        repeat(9000) @(negedge clk);
        if(!guest_reset_n) $fatal(1,"guest not released");
        write_io(4,8'h60);write_io(0,8'h43);no_output;
        queue(8'h5a);
        if(inhibit) begin
            @(negedge dd);
            repeat(10) begin @(negedge dc);@(posedge dc);end
            repeat(HALF/2) @(negedge clk);
            write_io(4,8'haa); // Actual controller self-test inhibits before stop falls.
            repeat(16) @(negedge clk);
            if(kc!==0) $fatal(1,"controller failed to inhibit");
            check_byte(8'h55);
            repeat(4000) @(negedge clk);
            read_csr(16'h390,value);
            if(value!==2) $fatal(1,"KBD-MMIO-EARLY-READY hz=%0d order=%0d",HZ,order);
        end
        wire_byte(8'h5a);check_byte(8'h1c);no_output;
        queue(8'h1c);wire_byte(8'h1c);check_byte(8'h1e);
        repeat(IDLE+24*HALF) @(negedge clk);no_output;
        if(submits!=2) $fatal(1,"duplicate/lost MMIO submit %0d",submits);
        $display("KBD-MMIO-OK hz=%0d order=%0d inhibit=%0d submits=2 irq1=1",HZ,order,inhibit);
        $finish;
    end
    initial begin repeat(400000) @(posedge clk);$fatal(1,"bounded MMIO test timeout");end
endmodule
