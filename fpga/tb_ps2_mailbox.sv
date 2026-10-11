`timescale 1ns/1ps
`default_nettype none
module ps2_mailbox_case #(parameter integer BITS=32)(output reg finished=0);
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, guest_reset=1, wr=0;
    reg [3:0] wa=0, ra=0, strb=15;
    reg [31:0] wd=0;
    wire [31:0] rd;
    wire tx_valid, rx_ready;
    wire [7:0] tx_data;
    reg tx_ready=0, tx_done=0, tx_aborted=0, rx_valid=0, rx_aborted=0;
    reg [7:0] rx_data=0;
    reg [1:0] rx_error=0;
    integer checks=0, transfers=0;
    reg [31:0] value, sequence_q, generation;
    ven_ps2_mailbox #(.COUNTER_BITS(BITS)) dut(
        .clk(clk), .rst_n(rst_n), .guest_reset(guest_reset),
        .csr_write(wr), .csr_waddr(wa), .csr_wdata(wd), .csr_wstrb(strb),
        .csr_raddr(ra), .csr_rdata(rd), .tx_valid(tx_valid), .tx_data(tx_data),
        .tx_ready(tx_ready), .tx_done(tx_done), .tx_aborted(tx_aborted),
        .rx_valid(rx_valid), .rx_data(rx_data), .rx_error(rx_error),
        .rx_ready(rx_ready), .rx_aborted(rx_aborted));
    always @(posedge clk) if (rst_n && tx_valid && tx_ready) transfers=transfers+1;
    task tick;
        begin @(posedge clk); #1; end
    endtask
    task check(input bit ok, input string message);
        begin
            checks=checks+1;
            if (!ok) $fatal(1,"PS2-MAILBOX-FAIL bits=%0d check=%0d %s",BITS,checks,message);
        end
    endtask
    task read_reg(input [3:0] address, output [31:0] data);
        begin ra=address; #1; data=rd; end
    endtask
    task write_reg(input [3:0] address, input [31:0] data, input [3:0] lanes=15);
        begin
            @(negedge clk); wr=1; wa=address; wd=data; strb=lanes;
            tick(); @(negedge clk); wr=0; strb=15;
        end
    endtask
    task status(input [31:0] mask, input [31:0] expected, input string message);
        begin read_reg(1,value); check((value & mask) === expected,message); end
    endtask
    task clear_error;
        begin write_reg(10,2); status(32'h200,0,"protocol error clear"); end
    endtask
    task arm;
        begin
            read_reg(2,generation); write_reg(3,generation);
            status(2,2,"generation arm");
        end
    endtask
    task serial_admit;
        begin
            @(negedge clk); tx_ready=1; tick();
            @(negedge clk); tx_ready=0;
            status(32'h38,32'h10,"exactly one serial admission");
        end
    endtask
    task serial_finish(input bit aborted);
        begin
            @(negedge clk); tx_done=!aborted; tx_aborted=aborted; tick();
            @(negedge clk); tx_done=0; tx_aborted=0;
            status(32'h78,aborted ? 32'h20 : 32'h60,"retained completion kind");
        end
    endtask
    task tx_ack;
        begin read_reg(5,sequence_q); write_reg(6,sequence_q); status(32'h38,0,"TX ACK"); end
    endtask
    task rx_send(input [7:0] data, input [1:0] errors=0);
        begin
            check(rx_ready,"RX ready before transfer");
            @(negedge clk); rx_valid=1; rx_data=data; rx_error=errors; tick();
            @(negedge clk); rx_valid=0;
            status(32'h80,32'h80,"RX retained");
            read_reg(7,value); check(value === {22'd0,errors,data},"RX byte and framing metadata");
        end
    endtask
    task guest_restart;
        reg [31:0] old_epoch;
        begin
            read_reg(2,old_epoch);
            @(negedge clk); guest_reset=1; #1;
            check(!tx_valid && !rx_ready,"guest reset blocks handshakes immediately");
            repeat(3) tick();
            status(32'h3ff,1,"guest reset clears ownership and sticky state");
            read_reg(2,value);
            check(value == ((old_epoch == ((64'd1 << BITS)-1)) ? old_epoch : old_epoch+1),"one epoch per reset assertion");
            read_reg(5,value); check(value == 0,"reset TX sequence");
            read_reg(8,value); check(value == 0,"reset RX sequence");
            @(negedge clk); guest_reset=0; tick();
        end
    endtask
    initial begin
        repeat(3) tick();
        @(negedge clk); rst_n=1; tick();
        read_reg(0,value); check(value==32'h5053_3201,"capability");
        write_reg(4,32'h42); status(32'h3ff,1,"writes during guest reset cannot admit");
        @(negedge clk); guest_reset=0; tick();
        write_reg(4,32'h42); status(32'h23c,32'h200,"unarmed submit is visible rejection");
        clear_error(); arm();
        if (BITS==32) begin
            for (integer b=0; b<256; b=b+1) begin
                write_reg(4,32'(b));
                read_reg(5,value); check(value==32'(b+1),"TX sequence confirms CSR admission");
                check(tx_valid && tx_data==8'(b),"byte held until transport admission");
                repeat(3) tick(); check(tx_valid && tx_data==8'(b),"backpressure preserves byte");
                serial_admit(); serial_finish(0);
                repeat(3) tick(); status(32'h78,32'h60,"reads/delay cannot consume TX event");
                tx_ack();
            end
            check(transfers==256,"no duplicated native handshakes");
            write_reg(4,32'hAA); read_reg(5,sequence_q);
            write_reg(4,32'hBB); status(32'h208,32'h208,"second submit rejected");
            check(tx_data==8'hAA,"busy write cannot overwrite byte");
            read_reg(5,value); check(value==sequence_q,"rejected write cannot claim sequence");
            clear_error(); serial_admit(); serial_finish(1);
            write_reg(6,sequence_q-1); status(32'h220,32'h220,"stale event ACK retained");
            clear_error(); tx_ack();
            for(integer lanes=0;lanes<15;lanes=lanes+1) begin
                read_reg(5,sequence_q); write_reg(4,32'h5A,4'(lanes));
                read_reg(5,value); check(value==sequence_q,"partial strobe cannot admit");
                status(32'h23c,32'h200,"partial strobe rejected"); clear_error();
            end
            write_reg(4,32'h100); status(32'h23c,32'h200,"reserved TX bits rejected"); clear_error();
            // RX arriving after CSR admission but before wire ownership must
            // resolve the pending TX, otherwise the policy cannot receive it.
            write_reg(4,32'hFA); rx_send(8'hF2,2'b10);
            status(32'hF8,32'hA0,"host command aborts queued byte and retains RX");
            check(!tx_valid,"cancelled TX never reaches serial port"); tx_ack();
            read_reg(8,sequence_q); write_reg(9,sequence_q+1);
            status(32'h280,32'h280,"wrong RX ACK rejected"); clear_error();
            // A second received byte may not overwrite unread metadata.
            @(negedge clk); rx_valid=1; rx_data=8'hE9; rx_error=1;
            repeat(3) tick(); check(!rx_ready,"full RX backpressure");
            read_reg(7,value); check(value==32'h2F2,"unread RX remains stable");
            write_reg(9,sequence_q); tick(); @(negedge clk); rx_valid=0;
            read_reg(7,value); check(value==32'h1E9,"next RX after explicit ACK");
            read_reg(8,value); check(value==sequence_q+1,"RX sequence advancement");
            write_reg(9,value);
            write_reg(4,32'hF8); serial_admit();
            read_reg(5,sequence_q);
            @(negedge clk); tx_done=1; wr=1; wa=6; wd=sequence_q;
            tick(); @(negedge clk); tx_done=0; wr=0;
            status(32'h278,32'h260,"premature ACK cannot erase simultaneous completion");
            clear_error(); tx_ack();
            // Hardware event wins a same-edge sticky-bit clear.
            @(negedge clk); rx_aborted=1; wr=1; wa=10; wd=1;
            tick(); @(negedge clk); rx_aborted=0; wr=0;
            status(32'h100,32'h100,"RX abort not lost to W1C"); write_reg(10,1);
            for(integer phase=0;phase<4;phase=phase+1) begin
                if(phase>0) write_reg(4,32'hA5);
                if(phase>1) serial_admit();
                if(phase>2) serial_finish(0);
                if(phase != 1) rx_send(8'hFF);
                read_reg(2,generation); guest_restart();
                write_reg(3,generation); status(32'h202,32'h200,"stale generation cannot arm");
                clear_error(); arm();
            end
            write_reg(4,32'hA5); serial_admit();
            @(negedge clk); tx_done=1; tx_aborted=1; tick();
            @(negedge clk); tx_done=0; tx_aborted=0;
            status(32'h278,32'h220,"contradictory completion fails visibly, never delivered");
            clear_error(); tx_ack();
        end else begin
            // Reduced-width instances reach saturation naturally, never by
            // forcing private DUT state or changing deployed ABI semantics.
            for(integer n=1;n<=3;n=n+1) begin
                write_reg(4,32'(n)); serial_admit(); serial_finish(0); tx_ack();
            end
            status(32'h404,32'h400,"TX sequence saturates, no wrap");
            write_reg(4,4); read_reg(5,value); check(value==3,"exhausted TX not admitted");
            guest_restart(); arm();
            for(integer n=1;n<=3;n=n+1) begin rx_send(8'(n)); write_reg(9,32'(n)); end
            check(!rx_ready,"RX sequence saturation backpressures");
            read_reg(8,value); check(value==3,"RX sequence never wraps");
            guest_restart(); guest_restart(); guest_restart();
            write_reg(3,3); status(32'h606,32'h600,"epoch exhaustion rejects stale generation forever");
            read_reg(2,value); check(value==3,"epoch saturation");
        end
        $display("PS2-MAILBOX-OK bits=%0d checks=%0d transfers=%0d",BITS,checks,transfers);
        finished=1;
    end
endmodule
module tb_ps2_mailbox;
    wire normal_done, overflow_done;
    ps2_mailbox_case normal(normal_done);
    ps2_mailbox_case #(.BITS(2)) overflow(overflow_done);
    initial begin
        wait(normal_done && overflow_done);
        $display("PS2-MAILBOX-ALL-OK profiles=2"); $finish;
    end
    initial begin #1000000; $fatal(1,"PS2 mailbox test timeout"); end
endmodule
`default_nettype wire
