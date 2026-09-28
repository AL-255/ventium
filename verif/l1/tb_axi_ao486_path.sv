// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Production AXI master -> bridge -> actual ao486 cache -> bounded DDR model.
// No guest, checkpoint, or replay injection. Compare REPLAY=0/1 on exact words.
module tb_axi_ao486_path #(parameter bit REPLAY = 0);
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  initial begin #1000000; $fatal(1, "path watchdog"); end
  logic req=0, we=0;
  logic [31:0] addr=0, data=0;
  logic [3:0] mask=0;
  wire [31:0] result;
  wire ack, bus_err, idle;
  wire [3:0] awid;
  wire [39:0] awaddr;
  wire [7:0] awlen;
  wire [2:0] awsize;
  wire [1:0] awburst;
  wire awvalid;
  wire awready;
  wire [31:0] wdata;
  wire [3:0] wstrb;
  wire wlast;
  wire wvalid;
  wire wready;
  wire [3:0] bid;
  wire [1:0] bresp;
  wire bvalid;
  wire bready;
  wire [3:0] arid;
  wire [39:0] araddr;
  wire [7:0] arlen;
  wire [2:0] arsize;
  wire [1:0] arburst;
  wire arvalid;
  wire arready;
  wire [3:0] rid;
  wire [31:0] rdata;
  wire [1:0] rresp;
  wire rlast;
  wire rvalid;
  wire rready;
  ven_axi_master #(.LINE_REPLAY(REPLAY)) master (
    .core_clk(clk), .core_rst_n(rst_n), .axi_clk(clk), .axi_rst_n(rst_n),
    .m_req(req), .m_we(we), .m_addr(addr), .m_rd_narrow(1'b0),
    .m_rd_size(2'd2), .m_wdata(data), .m_wstrb(mask),
    .m_rdata(result), .m_ack(ack), .bus_err(bus_err),
    .shutdown(1'b0), .m_idle(idle),
    .m_axi_awlock(), .m_axi_awcache(), .m_axi_awprot(), .m_axi_awqos(),
    .m_axi_arlock(), .m_axi_arcache(), .m_axi_arprot(), .m_axi_arqos(),
    .m_axi_awid(awid),
    .m_axi_awaddr(awaddr),
    .m_axi_awlen(awlen),
    .m_axi_awsize(awsize),
    .m_axi_awburst(awburst),
    .m_axi_awvalid(awvalid),
    .m_axi_awready(awready),
    .m_axi_wdata(wdata),
    .m_axi_wstrb(wstrb),
    .m_axi_wlast(wlast),
    .m_axi_wvalid(wvalid),
    .m_axi_wready(wready),
    .m_axi_bid(bid),
    .m_axi_bresp(bresp),
    .m_axi_bvalid(bvalid),
    .m_axi_bready(bready),
    .m_axi_arid(arid),
    .m_axi_araddr(araddr),
    .m_axi_arlen(arlen),
    .m_axi_arsize(arsize),
    .m_axi_arburst(arburst),
    .m_axi_arvalid(arvalid),
    .m_axi_arready(arready),
    .m_axi_rid(rid),
    .m_axi_rdata(rdata),
    .m_axi_rresp(rresp),
    .m_axi_rlast(rlast),
    .m_axi_rvalid(rvalid),
    .m_axi_rready(rready)
  );
  wire [29:0] av_addr;
  wire [31:0] av_din, av_dout;
  wire [3:0] av_be, av_count;
  wire av_write, av_read, av_busy, av_valid;
  ven_axi2avalon bridge (
    .clk(clk), .rst_n(rst_n),
    .s_axi_awid(awid),
    .s_axi_awaddr(awaddr),
    .s_axi_awlen(awlen),
    .s_axi_awsize(awsize),
    .s_axi_awburst(awburst),
    .s_axi_awvalid(awvalid),
    .s_axi_awready(awready),
    .s_axi_wdata(wdata),
    .s_axi_wstrb(wstrb),
    .s_axi_wlast(wlast),
    .s_axi_wvalid(wvalid),
    .s_axi_wready(wready),
    .s_axi_bid(bid),
    .s_axi_bresp(bresp),
    .s_axi_bvalid(bvalid),
    .s_axi_bready(bready),
    .s_axi_arid(arid),
    .s_axi_araddr(araddr),
    .s_axi_arlen(arlen),
    .s_axi_arsize(arsize),
    .s_axi_arburst(arburst),
    .s_axi_arvalid(arvalid),
    .s_axi_arready(arready),
    .s_axi_rid(rid),
    .s_axi_rdata(rdata),
    .s_axi_rresp(rresp),
    .s_axi_rlast(rlast),
    .s_axi_rvalid(rvalid),
    .s_axi_rready(rready),
    .avm_address(av_addr), .avm_writedata(av_din), .avm_byteenable(av_be),
    .avm_burstcount(av_count), .avm_write(av_write), .avm_read(av_read),
    .avm_waitrequest(av_busy), .avm_readdatavalid(av_valid), .avm_readdata(av_dout)
  );
  wire [24:0] ddr_addr;
  wire [63:0] ddr_din;
  wire [7:0] ddr_be, ddr_count;
  wire ddr_rd, ddr_we;
  logic [63:0] ddr_dout=0;
  logic ddr_valid=0, ddr_busy=0;
  l2_cache #(.ADDRBITS(24)) cache (
    .CLK(clk), .RESET(!rst_n), .DISABLE(1'b0),
    .l2_inv_pulse(1'b0), .l2_inv_addr(25'd0),
    .CPU_ADDR(av_addr), .CPU_DIN(av_din), .CPU_DOUT(av_dout),
    .CPU_DOUT_READY(av_valid), .CPU_BE(av_be), .CPU_BURSTCNT(av_count),
    .CPU_BUSY(av_busy), .CPU_RD(av_read), .CPU_WE(av_write),
    .DDRAM_ADDR(ddr_addr), .DDRAM_DIN(ddr_din), .DDRAM_BE(ddr_be),
    .DDRAM_BURSTCNT(ddr_count), .DDRAM_RD(ddr_rd), .DDRAM_WE(ddr_we),
    .DDRAM_DOUT(ddr_dout), .DDRAM_DOUT_READY(ddr_valid), .DDRAM_BUSY(ddr_busy),
    .VGA_ADDR(), .VGA_DIN(8'd0), .VGA_DOUT(), .VGA_MODE(3'd0),
    .VGA_RD(), .VGA_WE(), .VGA_WR_SEG(6'd0), .VGA_RD_SEG(6'd0),
    .VGA_FB_EN(1'b0), .uma_ram(1'b0));
  logic [31:0] ram[2048], expected_ram[2048];
  int left=0, delay_n=0, next_word=0;
  int clocks=0, ars=0, reads=0, measured_clocks=0, writes=0;
  always @(posedge clk) begin
    clocks <= clocks+1;
    if (bus_err) $fatal(1, "master bus error");
    if (arvalid && arready) ars <= ars+1;
    ddr_valid <= 0;
    // DDR transaction ownership deliberately survives CPU reset.
    if (ddr_rd && !ddr_busy) begin
      if (ddr_count != 8 || ddr_addr >= 1024) $fatal(1, "DDR read shape");
      ddr_busy <= 1; left <= 8; delay_n <= 4; next_word <= int'(ddr_addr)*2;
    end
    if (ddr_we && !ddr_busy) begin
      if (ddr_count != 1 || ddr_addr >= 1024) $fatal(1, "DDR write shape");
      for (int lane=0;lane<8;lane++)
        if (ddr_be[lane]) ram[int'(ddr_addr)*2+lane/4][8*(lane%4)+:8] <= ddr_din[8*lane+:8];
    end
    if (ddr_busy) begin
      if (delay_n != 0) delay_n <= delay_n-1;
      else begin
        ddr_dout <= {ram[next_word+1],ram[next_word]}; ddr_valid <= 1;
        next_word <= next_word+2; left <= left-1;
        delay_n <= (next_word % 3)+1;
        if (left==1) ddr_busy <= 0;
      end
    end
  end
  task automatic read_line(input int base, input int offset);
    int got, before_ar, began;
    @(negedge clk);
    before_ar=ars; began=clocks; got=0;
    we=0; addr=32'((base+offset)*4); req=1;
    for (int guard=0;guard<1024 && got<8;guard++) begin
      @(posedge clk);
      if (ack) begin
        if (result !== expected_ram[base+((offset+got)%8)])
          $fatal(1,"read mismatch base=%0d offset=%0d beat=%0d got=%08x expected=%08x",
                 base,offset,got,result,expected_ram[base+((offset+got)%8)]);
        got++;
      end
      @(negedge clk);
      addr=32'((base+((offset+got)%8))*4);
    end
    req=0;
    if (got!=8 || ars-before_ar != (REPLAY?2:1))
      $fatal(1,"read completion/AR count %0d/%0d",got,ars-before_ar);
    measured_clocks += clocks-began; reads++;
  endtask
  task automatic write_word(input int word_addr,input logic[3:0] be,input logic[31:0] value);
    bit accepted;
    @(negedge clk); we=1; addr=32'(word_addr*4); mask=be; data=value; req=1;
    accepted=0;
    for(int guard=0;guard<1024 && !accepted;guard++) begin
      @(posedge clk); accepted=ack; @(negedge clk);
    end
    req=0; we=0;
    if(!accepted) $fatal(1,"posted write timeout");
    for(int lane=0;lane<4;lane++)
      if(be[lane]) expected_ram[word_addr][8*lane+:8]=value[8*lane+:8];
    writes++;
    // Do not wait for B here: the following read must honor posted ownership.
  endtask
  initial begin
    for(int i=0;i<2048;i++) begin ram[i]=32'hCAFE0000|32'(i); expected_ram[i]=ram[i]; end
    repeat(4) @(negedge clk); rst_n=1;
    repeat(160) @(negedge clk);
    for(int half_line=0;half_line<2;half_line++) begin
      for(int off=0;off<8;off++) begin
        read_line(64+(half_line*8+off)*16+half_line*8,off);
        read_line(64+(half_line*8+off)*16+half_line*8,off);
      end
    end
    for(int strobe=0;strobe<16;strobe++) begin
      write_word(512+strobe%8,4'(strobe),32'h12345678^(32'(strobe)*32'h01010101));
      read_line(512,strobe%8);
    end
`ifdef VEN_P54_WRITE_PIPE_TEST
    // Saturate the actual P54 two-slot write buffer through the production
    // master, bridge, and ao486 L2. The control and candidate must perform
    // identical visible writes; this clock count is a seam microbenchmark,
    // not CPU instruction throughput or gameplay IPC.
    begin
      int began;
      began=clocks;
      for(int word_addr=600;word_addr<632;word_addr++)
        write_word(word_addr,4'hf,32'h45a5_0000|32'(word_addr));
      for(int guard=0;guard<1024 && !idle;guard++) @(negedge clk);
      if(!idle) $fatal(1,"streamed stores did not drain");
      $display("AXI-AO486-WRITE-PIPE clocks=%0d stores=32",clocks-began);
      for(int base=600;base<632;base+=8)
        read_line(base,0);
    end
`endif
    for(int guard=0;guard<1024 && !idle;guard++) @(negedge clk);
    if(!idle) $fatal(1,"master not idle");
    $display("AXI-AO486-PATH-OK replay=%0d reads=%0d writes=%0d AR=%0d read_clocks=%0d",
             REPLAY,reads,writes,ars,measured_clocks);
    $finish;
  end
endmodule
