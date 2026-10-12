`timescale 1ns/1ps
module tb_dma_declaration_order;
  reg clk=0;
  always #5 clk=~clk;
  reg rst_n=0, write=0, read=0;
  reg [3:0] address=0;
  reg [7:0] writedata=0;
  wire [7:0] readdata;
  wire [15:0] dma_address, dma_writedata;
  wire dma_read, dma_write;
  reg dma_waitrequest=1;
  reg [3:0] grant=0;
  wire [3:0] ack, tc, requests, busy, mask;
  wire disabled;
  wire [15:0] data0,data1,data2,data3;
  integer checks=0;

  i8237 dut(.clk(clk),.rst_n(rst_n),.address(address),.write(write),
    .writedata(writedata),.read(read),.readdata(readdata),
    .dma_address(dma_address),.dma_write(dma_write),.dma_writedata(dma_writedata),
    .dma_read(dma_read),.dma_readdata(16'h0),.dma_readdatavalid(1'b0),
    .dma_waitrequest(dma_waitrequest),
    .ch0_req(1'b0),.ch0_ack(ack[0]),.ch0_writedata(16'h0),.ch0_readdata(data0),.ch0_tc(tc[0]),
    .ch1_req(1'b0),.ch1_ack(ack[1]),.ch1_writedata(16'h0),.ch1_readdata(data1),.ch1_tc(tc[1]),
    .ch2_req(1'b0),.ch2_ack(ack[2]),.ch2_writedata(16'h0),.ch2_readdata(data2),.ch2_tc(tc[2]),
    .ch3_req(1'b0),.ch3_ack(ack[3]),.ch3_writedata(16'h0),.ch3_readdata(data3),.ch3_tc(tc[3]),
    .req(requests),.ch_req(grant),.busy(busy),.disabled(disabled),.mask(mask));

  task tick;
    @(posedge clk); #1;
  endtask
  task host_write(input [3:0] port, input [7:0] value);
    @(negedge clk); address=port; writedata=value; write=1;
    tick();
    @(negedge clk); write=0;
    tick();
  endtask
  task host_read(input [3:0] port, output [7:0] value);
    @(negedge clk); address=port; read=1;
    tick(); value=readdata;
    @(negedge clk); read=0;
    tick();
  endtask
  task program_word(input [3:0] port, input [15:0] value);
    host_write(12,0); host_write(port,value[7:0]); host_write(port,value[15:8]);
  endtask
  task check_word(input [3:0] port, input [15:0] expected);
    reg [7:0] lo,hi;
    host_write(12,0); host_read(port,lo); host_read(port,hi);
    if ({hi,lo} !== expected)
      $fatal(1,"DMA-BYTE-SELECT: port=%0d got=%04x expected=%04x",port,{hi,lo},expected);
    checks=checks+1;
  endtask

  integer pass,port,ch,mode;
  reg [15:0] value;
  initial begin
    repeat(3) tick();
    @(negedge clk); rst_n=1;
    tick();
    // All eight 16-bit register pairs, with distinct high/low values and
    // reads clearing/advancing the global byte pointer through the I/O port.
    for(pass=0;pass<8;pass=pass+1) begin
      for(port=0;port<8;port=port+1) begin
        value=16'h8123^(pass*16'h1711)^(port*16'h1327);
        program_word(port,value);
        check_word(port,value);
      end
    end
    // The byte pointer belongs to the controller, not an individual channel.
    program_word(7,16'h5afe);
    host_write(12,0); host_write(0,8'h12); host_write(7,8'hab);
    check_word(7,16'habfe);
    // Clearing the pointer in the middle of a pair must select the low byte.
    program_word(0,16'h7654);
    host_write(12,0); host_write(0,8'h32); host_write(12,0); host_write(0,8'h10);
    check_word(0,16'h7610);
    // Exercise actual channel grants and the stalled memory output. Abort
    // both transfer directions with the public software-reset I/O command.
    for(ch=0;ch<4;ch=ch+1) begin
      for(mode=1;mode<=2;mode=mode+1) begin
        value=16'ha123+ch*16'h123;
        program_word(ch*2,value); program_word(ch*2+1,16'h1357);
        host_write(11,(mode<<2)|ch);
        @(negedge clk); grant=1<<ch;
        tick();
        @(negedge clk); grant=0;
        repeat(3) tick();
        if (dma_address !== value || busy !== (4'b1<<ch) ||
            dma_read !== (mode==2) || dma_write !== (mode==1))
          $fatal(1,"DMA-TRANSFER: ch=%0d mode=%0d address=%04x busy=%x read=%b write=%b",
                 ch,mode,dma_address,busy,dma_read,dma_write);
        host_write(13,0);
        repeat(2) tick();
        if (busy !== 0 || dma_read !== 0 || dma_write !== 0 || mask !== 4'hf || disabled !== 0)
          $fatal(1,"DMA-SOFT-RESET: ch=%0d mode=%0d busy=%x read=%b write=%b mask=%x",
                 ch,mode,busy,dma_read,dma_write,mask);
        checks=checks+1;
      end
    end
    $display("DMA-DECLARATION-ORDER-OK: checks=%0d four_channels both_directions public_io_only",checks);
    $finish;
  end
  initial begin #100000; $fatal(1,"DMA test watchdog"); end
endmodule
