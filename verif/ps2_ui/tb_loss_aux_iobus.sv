// Actual current iobus + PS/2 + FIFO, ordinary I/O and device pins only.
// Read-only hierarchical witnesses prove a requested collision really occurred.
`timescale 1ns/1ps
module tb_loss_aux_iobus;
  logic clk=0; always #5 clk=~clk;
  logic rst_n=0, cpu_read_do=0, cpu_write_do=0, bus_wait=0;
  logic [15:0] cpu_read_address=0, cpu_write_address=0;
  logic [31:0] cpu_write_data=0;
  wire [31:0] cpu_read_data, bus_writedata;
  wire cpu_read_done,cpu_write_done,bus_read,bus_write;
  wire [15:0] bus_address;
  wire [2:0] bus_datasize;
  logic io_cs=0,ctl_cs=0,dev_clk=1,dev_data=1;
  wire kclk,kdata,mclk,mdata,kirq,mirq;
  wire [7:0] read_data;
  int scenario=0,half_period=64,wait_cycles=0,translated=1;
  int cycles=0,reads=0,writes=0,collisions=0,received=0;
  logic [7:0] value,status;
  always @(posedge clk) begin
    io_cs <= bus_address[15:3] == 13'h00c;
    ctl_cs <= bus_address[15:4] == 12'h009;
    cycles <= cycles+1;
    if(cycles>300000) $fatal(1,"LOSS-AUX-TIMEOUT");
    if(rst_n) begin
      if(io_cs && bus_read) reads <= reads+1;
      if(io_cs && bus_write) writes <= writes+1;
      if(dut.keyb_recv_final) received <= received+1;
      if(dut.keyb_recv_final && dut.wtk_q) begin
        collisions <= collisions+1;
        $display("LOSS-AUX-COLLISION cycle=%0d raw=%h",cycles,dut.keyb_recv_buffer);
      end
    end
  end
  iobus bus_dut (
    .clk(clk),.reset(!rst_n),.cpu_read_do(cpu_read_do),.cpu_read_address(cpu_read_address),
    .cpu_read_length(3'd1),.cpu_read_data(cpu_read_data),.cpu_read_done(cpu_read_done),
    .cpu_write_do(cpu_write_do),.cpu_write_address(cpu_write_address),.cpu_write_length(3'd1),
    .cpu_write_data(cpu_write_data),.cpu_write_done(cpu_write_done),.bus_address(bus_address),
    .bus_write(bus_write),.bus_read(bus_read),.bus_io32(1'b0),.bus_datasize(bus_datasize),
    .bus_writedata(bus_writedata),.bus_readdata({24'd0,read_data}),.bus_wait(bus_wait));
  ps2 dut (
    .clk(clk),.rst_n(rst_n),.irq_keyb(kirq),.irq_mouse(mirq),
    .io_address(bus_address[3:0]),.io_read(bus_read),.io_readdata(read_data),
    .io_write(bus_write),.io_writedata(bus_writedata[7:0]),.io_cs(io_cs),.ctl_cs(ctl_cs),
    .output_a20_enable(),.output_reset_n(),.a20_enable(),
    .ps2_kbclk(dev_clk & kclk),.ps2_kbdat(dev_data & kdata),
    .ps2_kbclk_out(kclk),.ps2_kbdat_out(kdata),
    .ps2_mouseclk(mclk),.ps2_mousedat(mdata),
    .ps2_mouseclk_out(mclk),.ps2_mousedat_out(mdata));

  task automatic idle(input int count); repeat(count) @(negedge clk); endtask
  task automatic write_port(input logic [15:0] address,input logic [7:0] data);
    int before_count,watchdog;
    before_count=writes; cpu_write_address=address; cpu_write_data={24'd0,data};
    cpu_write_do=1; bus_wait=wait_cycles!=0; idle(1); cpu_write_do=0;
    watchdog=0;
    while(!bus_write && watchdog<20) begin idle(1); watchdog++; end
    if(!bus_write) $fatal(1,"LOSS-AUX-NO-WRITE");
    if(wait_cycles!=0) begin idle(wait_cycles+1); bus_wait=0; end
    watchdog=0;
    while(!cpu_write_done && watchdog<100) begin idle(1); watchdog++; end
    if(!cpu_write_done || writes!=before_count+1) $fatal(1,"LOSS-AUX-WRITE-COUNT");
    idle(2);
  endtask
  task automatic read_port(input logic [15:0] address,output logic [7:0] data);
    int before_count,watchdog;
    before_count=reads; cpu_read_address=address; cpu_read_do=1;
    bus_wait=wait_cycles!=0; idle(1); cpu_read_do=0; watchdog=0;
    while(!bus_read && watchdog<20) begin idle(1); watchdog++; end
    if(!bus_read) $fatal(1,"LOSS-AUX-NO-READ");
    if(wait_cycles!=0) begin idle(wait_cycles+2); bus_wait=0; end
    watchdog=0;
    while(!cpu_read_done && watchdog<100) begin idle(1); watchdog++; end
    if(!cpu_read_done || reads!=before_count+1) $fatal(1,"LOSS-AUX-READ-COUNT");
    data=cpu_read_data[7:0]; idle(2);
  endtask
  task automatic expect_byte(input bit mouse,input logic [7:0] expected);
    logic [7:0] s,b;
    idle(16); read_port(16'h64,s);
    if((s & 8'ha1)!=(mouse?8'h21:8'h01))
      $fatal(1,"LOSS-AUX-OWNER status=%h expected_mouse=%0d",s,mouse);
    if(mouse ? (!mirq || kirq) : (!kirq || mirq)) $fatal(1,"LOSS-AUX-IRQ");
    read_port(16'h60,b);
    if(b!==expected) $fatal(1,"LOSS-AUX-BYTE got=%h expected=%h",b,expected);
  endtask
  task automatic wire_cell(input bit bit_value);
    dev_data=bit_value; dev_clk=1; idle(half_period);
    dev_clk=0; idle(half_period);
  endtask
  task automatic wire_byte(input logic [7:0] byte_value);
    bit parity;
    if(!kclk || !kdata) $fatal(1,"LOSS-AUX-INHIBITED");
    parity=1; wire_cell(0);
    for(int b=0;b<8;b++) begin parity^=byte_value[b]; wire_cell(byte_value[b]); end
    wire_cell(parity); wire_cell(1); dev_data=1; dev_clk=1; idle(128);
  endtask
  initial begin
    if($value$plusargs("scenario=%d",scenario)) begin end
    if($value$plusargs("half=%d",half_period)) begin end
    if($value$plusargs("wait=%d",wait_cycles)) begin end
    if($value$plusargs("translate=%d",translated)) begin end
    idle(32); rst_n=1; idle(10000);
    write_port(16'h64,8'h60); write_port(16'h60,translated?8'h43:8'h03); idle(32);
    if(dut.translate!==1'(translated)) $fatal(1,"LOSS-AUX-CONFIG");
    case(scenario)
      0: begin
        // Race the normal iobus write against the frame's final receive edge.
        fork
          wire_byte(8'h5a);
          begin idle(22*half_period-2); write_port(16'h60,8'hf4); end
        join
        if(collisions!=1 || received!=1) $fatal(1,"LOSS-AUX-COLLISION-NOT-EXERCISED %0d %0d",collisions,received);
        expect_byte(0,translated?8'h1c:8'h5a);
        expect_byte(0,8'hfa);
      end
      1,2: begin
        for(int n=0;n<64;n++) begin write_port(16'h60,8'hf4); idle(8); end
        if(!dut.keyb_fifo_full) $fatal(1,"LOSS-AUX-FULL-PRECONDITION");
        if(scenario==2) begin
          write_port(16'h64,8'hd3); write_port(16'h60,8'h29); idle(32);
          // Selected keyboard head must not be reclassified by mouse occupancy.
          expect_byte(0,8'hfa);
          write_port(16'h60,8'hf4); idle(16); // Refill keyboard while AUX is selected.
          if(!dut.keyb_fifo_full || !dut.status_mousebufferfull) $fatal(1,"LOSS-AUX-MOUSE-PRECONDITION");
        end
        write_port(16'h60,8'hf4); idle(32);
        read_port(16'h64,status);
        if(!(status & 8'h02)) $fatal(1,"LOSS-AUX-FULL-ACK-LOST");
        if(scenario==2) begin
          expect_byte(1,8'h29); read_port(16'h64,status);
          if(!(status & 8'h02) || !dut.keyb_fifo_full) $fatal(1,"LOSS-AUX-MOUSE-GAVE-KBD-CREDIT");
        end
        // One real keyboard pop permits the retained ACK to commit exactly once.
        expect_byte(0,8'hfa); read_port(16'h64,status);
        if(status & 8'h02 || !dut.keyb_fifo_full) $fatal(1,"LOSS-AUX-KBD-CREDIT");
        for(int n=0;n<64;n++) expect_byte(0,8'hfa);
      end
      default: $fatal(1,"LOSS-AUX-BAD-SCENARIO");
    endcase
    idle(32); read_port(16'h64,status);
    if(status & 8'ha3 || !dut.keyb_fifo_empty || !dut.mouse_fifo_empty)
      $fatal(1,"LOSS-AUX-EXTRA-OR-ERROR status=%h",status);
    $display("LOSS-AUX-IOBUS-OK scenario=%0d half=%0d wait=%0d translate=%0d cycles=%0d collisions=%0d reads=%0d writes=%0d",
             scenario,half_period,wait_cycles,translated,cycles,collisions,reads,writes);
    $finish;
  end
endmodule
