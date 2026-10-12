`timescale 1ns/1ps
module tb_dma_system_declarations;
  reg clk=0;
  always #5 clk=~clk;
  reg rst_n=0;
  reg [4:0] io_address=0;
  reg io_read=0,io_write=0,io_master_cs=0,io_slave_cs=0,io_page_cs=0;
  reg [7:0] io_writedata=0;
  wire [7:0] io_readdata;
  wire [23:0] mem_address;
  wire mem_16bit,mem_read,mem_write;
  wire [15:0] mem_writedata;
  reg [7:0] requests=0;
  wire [7:0] ack,tc;
  wire [7:0] data0,data1,data2,data3;
  wire [15:0] data5,data6,data7;
  integer checks=0;
  dma dut(.clk(clk),.rst_n(rst_n),.io_address(io_address),.io_read(io_read),
    .io_readdata(io_readdata),.io_write(io_write),.io_writedata(io_writedata),
    .io_master_cs(io_master_cs),.io_slave_cs(io_slave_cs),.io_page_cs(io_page_cs),
    .mem_address(mem_address),.mem_16bit(mem_16bit),.mem_waitrequest(1'b1),
    .mem_read(mem_read),.mem_readdatavalid(1'b0),.mem_readdata(16'h0),
    .mem_write(mem_write),.mem_writedata(mem_writedata),
    .dma_0_req(requests[0]),.dma_0_ack(ack[0]),.dma_0_tc(tc[0]),.dma_0_readdata(data0),.dma_0_writedata(8'h51),
    .dma_1_req(requests[1]),.dma_1_ack(ack[1]),.dma_1_tc(tc[1]),.dma_1_readdata(data1),.dma_1_writedata(8'h62),
    .dma_2_req(requests[2]),.dma_2_ack(ack[2]),.dma_2_tc(tc[2]),.dma_2_readdata(data2),.dma_2_writedata(8'h73),
    .dma_3_req(requests[3]),.dma_3_ack(ack[3]),.dma_3_tc(tc[3]),.dma_3_readdata(data3),.dma_3_writedata(8'h84),
    .dma_5_req(requests[5]),.dma_5_ack(ack[5]),.dma_5_tc(tc[5]),.dma_5_readdata(data5),.dma_5_writedata(16'h9515),
    .dma_6_req(requests[6]),.dma_6_ack(ack[6]),.dma_6_tc(tc[6]),.dma_6_readdata(data6),.dma_6_writedata(16'ha626),
    .dma_7_req(requests[7]),.dma_7_ack(ack[7]),.dma_7_tc(tc[7]),.dma_7_readdata(data7),.dma_7_writedata(16'hb737));
  task tick;
    @(posedge clk); #1;
  endtask
  task host_write(input bit master,input [3:0] port,input [7:0] value);
    @(negedge clk);
    io_address=master ? {port,1'b0} : {1'b0,port};
    io_master_cs=master; io_slave_cs=!master; io_writedata=value; io_write=1;
    tick();
    @(negedge clk); io_write=0; io_master_cs=0; io_slave_cs=0;
    tick();
  endtask
  task host_read(input bit master,input [3:0] port,output [7:0] value);
    @(negedge clk);
    io_address=master ? {port,1'b0} : {1'b0,port};
    io_master_cs=master; io_slave_cs=!master; io_read=1;
    tick(); value=io_readdata;
    @(negedge clk); io_read=0; io_master_cs=0; io_slave_cs=0;
    tick();
  endtask
  task page_write(input [3:0] port,input [7:0] value);
    @(negedge clk); io_address={1'b0,port};io_page_cs=1;io_writedata=value;io_write=1;
    tick();
    @(negedge clk);io_page_cs=0;io_write=0;
    tick();
  endtask
  task program_word(input bit master,input [3:0] port,input [15:0] value);
    host_write(master,12,0);host_write(master,port,value[7:0]);host_write(master,port,value[15:8]);
  endtask
  task check_word(input bit master,input [3:0] port,input [15:0] value);
    reg [7:0] lo,hi;
    host_write(master,12,0);host_read(master,port,lo);host_read(master,port,hi);
    if ({hi,lo} !== value)
      $fatal(1,"DMA-BYTE-SELECT: master=%0d port=%0d got=%04x expected=%04x",master,port,{hi,lo},value);
    checks=checks+1;
  endtask
  integer controller,pass,port,ch,local_ch,mode;
  reg [15:0] value;
  reg [23:0] expected_address;
  reg [7:0] page_value;
  reg [3:0] page_port;
  reg master;
  initial begin
    repeat(3) tick();
    @(negedge clk);rst_n=1;
    tick();
    for(controller=0;controller<2;controller=controller+1) begin
      for(pass=0;pass<4;pass=pass+1) begin
        for(port=0;port<8;port=port+1) begin
          value=16'h8123^(pass*16'h1711)^(port*16'h1327)^(controller*16'h6996);
          program_word(controller,port,value);check_word(controller,port,value);
        end
      end
      program_word(controller,7,16'h5afe);
      host_write(controller,12,0);host_write(controller,0,8'h12);host_write(controller,7,8'hab);
      check_word(controller,7,16'habfe);
      program_word(controller,0,16'h7654);
      host_write(controller,12,0);host_write(controller,0,8'h32);
      host_write(controller,12,0);host_write(controller,0,8'h10);
      check_word(controller,0,16'h7610);
    end
    // Unmask the cascade. Drive real device request pins; the wrapper selects
    // channels, qualifies masks and expands the page/word memory address.
    host_write(1,10,0);
    for(ch=0;ch<8;ch=ch+1) if(ch!=4) begin
      master=(ch>=4); local_ch=ch & 3;
      case(ch)
        0:page_port=7;1:page_port=3;2:page_port=1;3:page_port=2;
        5:page_port=11;6:page_port=9;7:page_port=10;
      endcase
      for(mode=1;mode<=2;mode=mode+1) begin
        value=16'ha123+ch*16'h123;page_value=8'h32+ch*2;
        expected_address=master ? {page_value[7:1],value,1'b0} : {page_value,value};
        program_word(master,local_ch*2,value);program_word(master,local_ch*2+1,16'h1357);
        page_write(page_port,page_value);
        host_write(master,11,(mode<<2)|local_ch);host_write(master,10,local_ch);
        @(negedge clk);requests=1<<ch;
        tick();tick();
        @(negedge clk);requests=0;
        repeat(5) tick();
        if (mem_address !== expected_address || mem_16bit !== master ||
            mem_read !== (mode==2) || mem_write !== (mode==1))
          $fatal(1,"DMA-TRANSFER: ch=%0d mode=%0d addr=%06x expected=%06x width=%b read=%b write=%b",
                 ch,mode,mem_address,expected_address,mem_16bit,mem_read,mem_write);
        host_write(master,13,0);
        repeat(4) tick();
        if (mem_read !== 0 || mem_write !== 0 || (ack & 8'hef) !== 0)
          $fatal(1,"DMA-SOFT-RESET: ch=%0d mode=%0d read=%b write=%b ack=%x",ch,mode,mem_read,mem_write,ack);
        checks=checks+1;
      end
    end
    $display("DMA-SYSTEM-DECLARATIONS-OK: checks=%0d two_controllers seven_channels public_io_and_dma_only",checks);
    $finish;
  end
  initial begin #200000;$fatal(1,"DMA system test watchdog");end
endmodule
