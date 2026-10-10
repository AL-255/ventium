`timescale 1ps/1ps
// Exercise the real 8042 port/IRQ interface, plus a pin-level malformed host.
// No hierarchical register writes or forced FIFO/interrupt state are used.
module ps2_device_case #(
    parameter integer HZ = 3125000,
    parameter integer HALF_PS = 160000
) (output reg done = 0);
    localparam integer CELL = 2 * ((HZ + 24999) / 25000);
    localparam integer IDLE_WAIT = (HZ + 9999) / 10000;
    reg clk=0, rst_n=0;
    always #HALF_PS if (!done) clk = ~clk;
    reg tx_valid=0, rx_ready=0;
    reg [7:0] tx_data=0;
    wire tx_ready, tx_done, tx_aborted, rx_valid, rx_aborted;
    wire [7:0] rx_data;
    wire [1:0] rx_error;
    wire hc, hd, dc, dd;
    reg manual=0, manual_clk=1, manual_dat=1;
    wire host_clk = manual ? manual_clk : hc;
    wire host_dat = manual ? manual_dat : hd;
    wire line_clk = host_clk & dc;
    wire line_dat = host_dat & dd;
    reg [3:0] io_address=0;
    reg io_read=0, io_write=0;
    reg [7:0] io_writedata=0;
    wire [7:0] io_readdata;
    wire irq_keyb, irq_mouse, a20, output_a20, output_reset;
    wire kc, kd;
    integer sent=0, aborted=0, receive_aborted=0, checks=0;
    always @(posedge clk) begin
        if (tx_done) sent <= sent + 1;
        if (tx_aborted) aborted <= aborted + 1;
        if (rx_aborted) receive_aborted <= receive_aborted + 1;
    end
    ven_ps2_device #(.CLK_HZ(HZ)) device (
        .clk(clk),.rst_n(rst_n),.tx_valid(tx_valid),.tx_data(tx_data),
        .tx_ready(tx_ready),.tx_done(tx_done),.tx_aborted(tx_aborted),
        .rx_valid(rx_valid),.rx_data(rx_data),.rx_error(rx_error),
        .rx_ready(rx_ready),.rx_aborted(rx_aborted),
        .host_clk_release(host_clk),.host_dat_release(host_dat),
        .dev_clk_release(dc),.dev_dat_release(dd)
    );
    ps2 controller (
        .clk(clk),.rst_n(rst_n),.irq_keyb(irq_keyb),.irq_mouse(irq_mouse),
        .io_address(io_address),.io_read(io_read),.io_readdata(io_readdata),
        .io_write(io_write),.io_writedata(io_writedata),.io_cs(1'b1),.ctl_cs(1'b0),
        .output_a20_enable(output_a20),.output_reset_n(output_reset),.a20_enable(a20),
        .ps2_kbclk(1'b1),.ps2_kbdat(1'b1),.ps2_kbclk_out(kc),.ps2_kbdat_out(kd),
        .ps2_mouseclk(manual ? 1'b1 : line_clk),
        .ps2_mousedat(manual ? 1'b1 : line_dat),
        .ps2_mouseclk_out(hc),.ps2_mousedat_out(hd)
    );
    task io_wr(input [3:0] address, input [7:0] value);
        begin
            @(negedge clk); io_address=address; io_writedata=value; io_write=1;
            @(negedge clk); io_write=0;
            repeat (3) @(negedge clk);
        end
    endtask
    task io_rd(input [3:0] address, output [7:0] value);
        begin
            @(negedge clk); io_address=address; io_read=1;
            @(posedge clk); #1; value=io_readdata;
            @(negedge clk); io_read=0;
            repeat (3) @(negedge clk);
        end
    endtask
    task mouse_command(input [7:0] value);
        reg [7:0] status;
        begin
            io_rd(4,status);
            if (status[1]) $fatal(1,"HZ%0d controller input unexpectedly full",HZ);
            io_wr(4,8'hd4);
            io_wr(0,value);
        end
    endtask
    task received(input [7:0] expected, input [1:0] errors);
        integer n;
        begin
            n=0;
            while (!rx_valid && n < 15000+CELL*12) begin
                @(negedge clk); n=n+1;
            end
            if (!rx_valid || rx_data !== expected || rx_error !== errors)
                $fatal(1,"HZ%0d host RX got valid=%b data=%02x errors=%b expected=%02x/%b",HZ,rx_valid,rx_data,rx_error,expected,errors);
            repeat (32) begin
                @(negedge clk);
                if (!rx_valid || rx_data !== expected || rx_error !== errors || tx_ready)
                    $fatal(1,"HZ%0d RX mailbox changed before consume",HZ);
            end
            checks=checks+1;
        end
    endtask
    task consume;
        begin
            @(negedge clk); rx_ready=1;
            @(negedge clk); rx_ready=0;
            if (rx_valid) $fatal(1,"HZ%0d RX valid did not clear",HZ);
        end
    endtask
    task queue_tx(input [7:0] value);
        integer n;
        begin
            n=0;
            while (!tx_ready && n < CELL*12) begin @(negedge clk); n=n+1; end
            if (!tx_ready) $fatal(1,"HZ%0d TX never ready",HZ);
            @(negedge clk); tx_data=value; tx_valid=1;
            @(negedge clk); tx_valid=0;
            if (tx_ready) $fatal(1,"HZ%0d TX ownership not acquired",HZ);
        end
    endtask
    task device_byte(input [7:0] value);
        integer n, before_sent;
        integer bit_number;
        reg [7:0] status, result;
        reg [10:0] expected;
        time started_at, previous_fall, fell_at;
        begin
            before_sent=sent;
            queue_tx(value);
            // Independent physical-pin oracle: both selected frequencies
            // divide exactly into 40 us. Do not derive expected timing from
            // DUT counters/parameters or merely rely on the 8042 accepting it.
            expected={1'b1,~^value,value,1'b0};
            @(negedge dd); started_at=$time;
            for (bit_number=0;bit_number<11;bit_number=bit_number+1) begin
                @(negedge dc); fell_at=$time;
                if (line_dat !== expected[bit_number])
                    $fatal(1,"HZ%0d TX bit/parity mismatch at %0d",HZ,bit_number);
                if (bit_number==0 && fell_at-started_at != 40000000)
                    $fatal(1,"HZ%0d initial clock high not 40us",HZ);
                if (bit_number>0 && fell_at-previous_fall != 80000000)
                    $fatal(1,"HZ%0d PS/2 clock not 12.5kHz",HZ);
                previous_fall=fell_at;
                @(posedge dc);
                if ($time-fell_at != 40000000)
                    $fatal(1,"HZ%0d clock low not 40us",HZ);
            end
            n=0;
            while ((!irq_mouse || sent == before_sent) && n < IDLE_WAIT+CELL*12+100) begin
                @(negedge clk); n=n+1;
            end
            if (!irq_mouse || irq_keyb || sent != before_sent+1)
                $fatal(1,"HZ%0d device TX missing IRQ12/completion or spurious IRQ1",HZ);
            io_rd(4,status);
            if ((status & 8'ha1) !== 8'h21)
                $fatal(1,"HZ%0d AUX/OBF/parity status wrong %02x",HZ,status);
            io_rd(0,result);
            if (result !== value) $fatal(1,"HZ%0d port60 got %02x expected %02x",HZ,result,value);
            repeat (10) @(negedge clk);
            if (irq_mouse) $fatal(1,"HZ%0d IRQ12 not consumed",HZ);
            checks=checks+1;
        end
    endtask
    task pin_command(input [7:0] value, input bad_parity, input bad_stop);
        integer i;
        reg parity;
        begin
            parity=~^value;
            @(negedge clk); manual_clk=0; manual_dat=1;
            repeat (IDLE_WAIT+2) @(negedge clk);
            manual_dat=0;
            repeat (8) @(negedge clk);
            manual_clk=1;
            for (i=0;i<11;i=i+1) begin
                @(negedge dc);
                repeat (2) @(negedge clk);
                if (i<8) manual_dat=value[i];
                else if (i==8) manual_dat=parity ^ bad_parity;
                else if (i==9) manual_dat=!bad_stop;
                else begin
                    manual_dat=1;
                    if (dd !== 0) $fatal(1,"HZ%0d missing device ACK bit",HZ);
                end
                @(posedge dc);
            end
            @(negedge clk); manual_dat=1;
        end
    endtask
    reg [7:0] values[0:9];
    integer i, old_sent, old_aborted, old_rx_aborted;
    reg [7:0] status;
    initial begin
        values[0]=8'hff; values[1]=8'hf2; values[2]=8'hf4; values[3]=8'hf5;
        values[4]=8'hf3; values[5]=8'he8; values[6]=8'he9; values[7]=8'heb;
        values[8]=8'h00; values[9]=8'ha5;
        repeat (8) @(negedge clk); rst_n=1;
        repeat (8) @(negedge clk);
        for (i=0;i<10;i=i+1) begin
            mouse_command(values[i]);
            received(values[i],0);
            consume;
            device_byte(8'hfa);
            // This controller retains IBF until the response enters OBF,
            // not merely until the serial ACK bit. An actual received reply
            // plus cleared IBF checks both halves of the wire handshake.
            io_rd(4,status);
            if (status[1]) $fatal(1,"HZ%0d command/reply did not clear IBF",HZ);
            device_byte(values[i]); // Byte-transparent AUX path; no keyboard translation.
        end
        device_byte(8'h08); device_byte(8'h7f); device_byte(8'h80);
        // Full RX mailbox must not overwrite an unconsumed command or ACK a
        // second command before storage is available.
        @(negedge clk); manual=1;
        pin_command(8'hf2,0,0); received(8'hf2,0);
        fork
            pin_command(8'hf4,0,0);
            begin
                @(posedge manual_clk);
                repeat (CELL*2) begin
                    @(negedge clk);
                    if (!rx_valid || rx_data !== 8'hf2 || dc !== 1)
                        $fatal(1,"HZ%0d full RX slot lost data or clocked next command",HZ);
                end
                consume;
            end
        join
        received(8'hf4,0); consume;
        checks=checks+1;
        // Independent pin host checks error metadata without touching 8042
        // internals. The client must choose RESEND rather than accept bad data.
        pin_command(8'h96,1,0); received(8'h96,1); consume;
        pin_command(8'h69,0,1); received(8'h69,2); consume;
        pin_command(8'h81,1,1); received(8'h81,3); consume;
        // Host command preempts an owned but not-yet-started TX byte.
        old_sent=sent; old_aborted=aborted;
        queue_tx(8'h55);
        pin_command(8'hf4,0,0); received(8'hf4,0); consume;
        if (sent != old_sent || aborted != old_aborted+1)
            $fatal(1,"HZ%0d request-to-send did not cancel pending output",HZ);
        checks=checks+1;
        // Truncated outgoing byte: explicit abort, no false completion/suffix.
        old_sent=sent; old_aborted=aborted;
        queue_tx(8'ha5);
        repeat (3) @(negedge dc);
        @(negedge clk); manual_clk=0;
        repeat (8) @(negedge clk);
        if (sent != old_sent || aborted != old_aborted+1 || dc !== 1 || dd !== 1)
            $fatal(1,"HZ%0d TX inhibition lost abort or claimed completion",HZ);
        manual_clk=1;
        repeat (CELL*12) @(negedge clk);
        if (sent != old_sent) $fatal(1,"HZ%0d aborted TX emitted a suffix",HZ);
        checks=checks+1;
        // Truncated host command is also explicit and cannot leave an old
        // prefix in the following command or publish an incomplete mailbox.
        old_rx_aborted=receive_aborted;
        manual_clk=0; manual_dat=1;
        repeat (IDLE_WAIT+2) @(negedge clk);
        manual_dat=0;
        repeat (8) @(negedge clk);
        manual_clk=1;
        repeat (3) @(negedge dc);
        @(negedge clk); manual_clk=0; manual_dat=1;
        repeat (8) @(negedge clk);
        if (rx_valid || receive_aborted != old_rx_aborted+1 || dc !== 1 || dd !== 1)
            $fatal(1,"HZ%0d truncated RX was not discarded",HZ);
        manual_clk=1;
        pin_command(8'hc3,0,0); received(8'hc3,0); consume;
        checks=checks+1;
        // Reset during a queued byte discards old guest transport state.
        queue_tx(8'hf0);
        @(negedge clk); rst_n=0;
        repeat (8) @(negedge clk);
        if (rx_valid || tx_done || tx_aborted || dc !== 1 || dd !== 1)
            $fatal(1,"HZ%0d reset did not release lines/mailboxes",HZ);
        manual=0; rst_n=1;
        repeat (CELL*12) @(negedge clk);
        if (irq_mouse || irq_keyb || rx_valid) $fatal(1,"HZ%0d pre-reset byte leaked",HZ);
        queue_tx(8'h33);
        repeat (3) @(negedge dc);
        @(negedge clk); rst_n=0;
        repeat (8) @(negedge clk); rst_n=1;
        repeat (CELL*12) @(negedge clk);
        if (irq_mouse || irq_keyb || rx_valid || sent != old_sent)
            $fatal(1,"HZ%0d active-frame reset leaked completion/data",HZ);
        mouse_command(8'hff); received(8'hff,0); consume;
        device_byte(8'hfa); device_byte(8'haa); device_byte(8'h00);
        checks=checks+1;
        $display("PS2-DEVICE-OK hz=%0d checks=%0d completed=%0d aborted=%0d",HZ,checks,sent,aborted);
        done=1;
    end
endmodule

module tb_ps2_device;
    wire legacy_done, fpga_done;
    ps2_device_case legacy(.done(legacy_done));
    ps2_device_case #(.HZ(40000000),.HALF_PS(12500)) fpga(.done(fpga_done));
    initial begin
        wait(legacy_done && fpga_done);
        $display("PS2-DEVICE-ALL-OK profiles=2");
        $finish;
    end
    initial begin
        #200000000000;
        $fatal(1,"PS2 device test timeout");
    end
endmodule
