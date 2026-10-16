`timescale 1ns/1ps
// The real FPGA transmitter and 8042, connected only through public pins.
// AA resets the controller receive epoch; guest reset resets both devices.
// No producer retry: an interrupted byte remains owned by the transmitter.
module tb_kbd_controller_inhibit;
    parameter integer HZ=40000000;
    localparam integer HALF=(64'd128*HZ+3124999)/3125000;
    localparam integer CELL=2*HALF;
    localparam integer IDLE=(64'd80*HZ+3124999)/3125000;
    reg clk=0,rst_n=0,valid=0;
    reg [7:0] data=0,wdata=0;
    reg [3:0] address=0;
    reg rd=0,wr=0;
    wire ready,busy,dc,dd,kc,kd,mc,md,irqk,irqm,a20,oa20,oreset;
    wire [7:0] rdata;
    integer phase,reset_case,bit_number,i,n,edges=0,initial_edges;
    integer cycle=0,stop_cycle=-1,inhibit_cycle=-1;
    reg retry_expected;
    reg [7:0] status,got;
    reg [10:0] expected;
    always #5 clk=~clk;
    always @(posedge clk) cycle=cycle+1;
    always @(negedge dc) if(kc && rst_n) begin
        edges=edges+1;
        if(edges==11) stop_cycle=cycle;
    end
    always @(negedge kc) if(rst_n) inhibit_cycle=cycle;
    ven_ps2_kbd_inject #(.CLK_HZ(HZ)) device (
        .clk(clk),.rst_n(rst_n),.inject_valid(valid),.inject_data(data),
        .inject_ready(ready),.inject_busy(busy),
        .host_clk_release(kc),.host_dat_release(kd),
        .dev_clk_release(dc),.dev_dat_release(dd));
    ps2 controller (
        .clk(clk),.rst_n(rst_n),.irq_keyb(irqk),.irq_mouse(irqm),
        .io_address(address),.io_read(rd),.io_readdata(rdata),
        .io_write(wr),.io_writedata(wdata),.io_cs(1'b1),.ctl_cs(1'b0),
        .output_a20_enable(oa20),.output_reset_n(oreset),.a20_enable(a20),
        .ps2_kbclk(kc & dc),.ps2_kbdat(kd & dd),
        .ps2_mouseclk(mc),.ps2_mousedat(md),
        .ps2_kbclk_out(kc),.ps2_kbdat_out(kd),
        .ps2_mouseclk_out(mc),.ps2_mousedat_out(md));
    task write_io(input [3:0] addr,input [7:0] value);
        begin
            @(negedge clk);address=addr;wdata=value;wr=1;
            @(negedge clk);wr=0;
            repeat(3) @(negedge clk);
        end
    endtask
    task read_io(input [3:0] addr,output [7:0] value);
        begin
            @(negedge clk);address=addr;rd=1;
            @(posedge clk);#1;value=rdata;
            @(negedge clk);rd=0;
            repeat(3) @(negedge clk);
        end
    endtask
    task queue(input [7:0] value);
        begin
            if(!ready || busy) $fatal(1,"queue without credit");
            @(negedge clk);data=value;valid=1;
            @(negedge clk);valid=0;
            if(ready || !busy) $fatal(1,"byte not owned");
        end
    endtask
    task check_byte(input [7:0] value);
        begin
            n=0;status=0;
            while(!status[0] && n<20000) begin read_io(4,status);n=n+5;end
            if(!status[0] || status[5] || |status[7:6] || !irqk || irqm)
                $fatal(1,"receive status/IRQ mismatch %02x",status);
            read_io(0,got);
            if(got !== value) $fatal(1,"wrong received byte %02x expected %02x",got,value);
        end
    endtask
    task no_output;
        begin
            read_io(4,status);
            if(status[0] || |status[7:6] || irqk || irqm)
                $fatal(1,"unexpected receive/error/IRQ %02x",status);
        end
    endtask
    task wire_byte(input [7:0] value);
        begin
            expected={1'b1,~^value,value,1'b0};
            for(i=0;i<11;i=i+1) begin
                @(negedge dc);
                if(!kc || (kd & dd) !== expected[i])
                    $fatal(1,"wire bit/parity mismatch bit=%0d",i);
                @(posedge dc);
            end
            repeat(64) @(negedge clk);
            if(!ready || busy) $fatal(1,"completed frame still owned");
        end
    endtask
    initial begin
        if(!$value$plusargs("phase=%d",phase) || phase<0 || phase>25 ||
           !$value$plusargs("reset=%d",reset_case) || reset_case<0 || reset_case>1)
            $fatal(1,"invalid selectors");
        retry_expected=!reset_case && (phase<21 || phase==23 || phase==24);
        repeat(8) @(negedge clk);rst_n=1;
        repeat(9000) @(negedge clk);
        write_io(4,8'h60);write_io(0,8'h43); // translation, both IRQs
        no_output;queue(8'h5a);@(negedge dd);
        bit_number=phase<=22 ? phase/2 : 10;
        for(i=0;i<bit_number;i=i+1) begin @(negedge dc);@(posedge dc);end
        if(phase<22) begin
            if(phase%2) @(negedge dc);
            repeat(HALF/2) @(negedge clk);
        end else if(phase==22) repeat(IDLE+32) @(negedge clk);
        else repeat(HALF-2+(phase-23)) @(negedge clk);
        initial_edges=edges;
        if(phase<=22 && initial_edges !== bit_number+(phase%2))
            $fatal(1,"wrong physical phase");
        if(reset_case) begin
            @(negedge clk);rst_n=0;
            repeat(4) @(negedge clk);rst_n=1;
        end else write_io(4,8'haa);
        repeat(16) @(negedge clk);
        if(kc !== 0) $fatal(1,"actual controller did not inhibit");
        // At/just before the falling stop edge, no full shared synchronous
        // clock observed that stop. At one clock after it, the byte completed.
        if(!reset_case && phase==23 && stop_cycle!=-1)
            $fatal(1,"pre-stop inhibit too late");
        if(!reset_case && phase==24 && edges!=10)
            $fatal(1,"coincident stop/inhibit leaked a physical stop");
        if(!reset_case && phase==25 && (stop_cycle<0 || inhibit_cycle-stop_cycle!=1))
            $fatal(1,"one-clock post-stop phase not exercised");
        if(!reset_case) check_byte(8'h55);
        // Stay inside the actual 8192-clock controller inhibit. The original
        // injector falsely returns ready here for the late-frame witnesses.
        repeat(4000) @(negedge clk);
        if(retry_expected && (ready || !busy))
            $fatal(1,"KBD-CONTROLLER-EARLY-READY hz=%0d phase=%0d",HZ,phase);
        if(!retry_expected && (!ready || busy))
            $fatal(1,"reset/completed frame incorrectly retained");
        if(retry_expected) begin
            // The pending byte retries automatically; no second valid pulse.
            wire_byte(8'h5a);
            check_byte(8'h1c);
        end else repeat(9000+IDLE+12*CELL) @(negedge clk);
        no_output;
        // Reset and AA restore the normal translated configuration. Check a
        // distinct subsequent byte and actual IRQ1/port60, never a FIFO poke.
        queue(8'h1c);wire_byte(8'h1c);check_byte(8'h1e);
        repeat(IDLE+12*CELL) @(negedge clk);no_output;
        $display("KBD-CONTROLLER-OK hz=%0d phase=%0d reset=%0d retry=%0d irq1=1",HZ,phase,reset_case,retry_expected);
        $finish;
    end
    initial begin repeat(400000) @(posedge clk);$fatal(1,"bounded controller test timeout");end
endmodule
