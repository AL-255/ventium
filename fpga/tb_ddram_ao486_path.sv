// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Exact frozen AXI master -> Avalon bridge -> ao486 cache -> real board bridge.
// Memory becomes visible only on actual delayed B completion. No guest patches.
// Run identical traffic on serial and posted bridges, with the FPGA define set.
module tb_ddram_ao486_path #(parameter bit POSTED = 0,
                           parameter int WRITE_SLOTS = 8);
  localparam bit REPLAY = 0;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  initial begin #10000000; $fatal(1, "path watchdog"); end
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
`ifdef VEN_P54_DUAL_STORE_PAIR
    .m_pair_req(1'b0), .m_pair_addr(32'd0), .m_pair_wdata(32'd0),
    .m_pair_wstrb(4'd0), .m_pair_ready(), .m_pair_ack(),
`endif
`ifdef VEN_DBG_CORE
    .dbg_rd_valid(), .dbg_rd_addr(), .dbg_rd_data(),
`endif
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
  wire [63:0] ddr_dout;
  wire ddr_valid, ddr_busy;
  logic inv=0;
  logic [24:0] inv_addr=0;
  l2_cache #(.ADDRBITS(24)) cache (
    .CLK(clk), .RESET(!rst_n), .DISABLE(1'b0),
    .l2_inv_pulse(inv), .l2_inv_addr(inv_addr),
    .CPU_ADDR(av_addr), .CPU_DIN(av_din), .CPU_DOUT(av_dout),
    .CPU_DOUT_READY(av_valid), .CPU_BE(av_be), .CPU_BURSTCNT(av_count),
    .CPU_BUSY(av_busy), .CPU_RD(av_read), .CPU_WE(av_write),
    .DDRAM_ADDR(ddr_addr), .DDRAM_DIN(ddr_din), .DDRAM_BE(ddr_be),
    .DDRAM_BURSTCNT(ddr_count), .DDRAM_RD(ddr_rd), .DDRAM_WE(ddr_we),
    .DDRAM_DOUT(ddr_dout), .DDRAM_DOUT_READY(ddr_valid), .DDRAM_BUSY(ddr_busy),
    .VGA_ADDR(), .VGA_DIN(8'd0), .VGA_DOUT(), .VGA_MODE(3'd0),
    .VGA_RD(), .VGA_WE(), .VGA_WR_SEG(6'd0), .VGA_RD_SEG(6'd0),
    .VGA_FB_EN(1'b0), .uma_ram(1'b0)
`ifdef VEN_VGA_WIDE_STORE
    , .VGA_WIDE_READY(1'b0), .VGA_WIDE_WE(), .VGA_WIDE_DOUT()
`endif
  );
    wire [3:0] m_axi_awid, m_axi_arid;
    wire [31:0] m_axi_awaddr, m_axi_araddr;
    wire [7:0] m_axi_awlen, m_axi_arlen;
    wire [2:0] m_axi_awsize, m_axi_arsize, dbg_st;
    wire [1:0] m_axi_awburst, m_axi_arburst;
    wire m_axi_awvalid, m_axi_wvalid, m_axi_wlast, m_axi_bready;
    wire m_axi_arvalid, m_axi_rready;
    wire [63:0] m_axi_wdata;
    wire [7:0] m_axi_wstrb;
    reg m_axi_awready = 0, m_axi_wready = 0, m_axi_arready = 0;
    reg m_axi_bvalid = 0, m_axi_rvalid = 0, m_axi_rlast = 0;
    reg [1:0] m_axi_bresp = 0, m_axi_rresp = 0;
    reg [63:0] m_axi_rdata = 0;
    wire fault, drained;

    generate if (POSTED) begin : g_posted
      ven_ddram_axi_posted #(.WRITE_SLOTS(WRITE_SLOTS)) transport (
      .clk(clk), .rst_n(rst_n), .DDRAM_BUSY(ddr_busy),
      .DDRAM_BURSTCNT(ddr_count), .DDRAM_ADDR(ddr_addr), .DDRAM_DOUT(ddr_dout),
      .DDRAM_DOUT_READY(ddr_valid), .DDRAM_RD(ddr_rd), .DDRAM_DIN(ddr_din),
      .DDRAM_BE(ddr_be), .DDRAM_WE(ddr_we), .*);
    end else begin : g_serial
      ven_ddram_axi transport (
      .clk(clk), .rst_n(rst_n), .DDRAM_BUSY(ddr_busy),
      .DDRAM_BURSTCNT(ddr_count), .DDRAM_ADDR(ddr_addr), .DDRAM_DOUT(ddr_dout),
      .DDRAM_DOUT_READY(ddr_valid), .DDRAM_RD(ddr_rd), .DDRAM_DIN(ddr_din),
      .DDRAM_BE(ddr_be), .DDRAM_WE(ddr_we), .*);
      assign fault = 0;
      assign drained = rst_n && !ddr_busy && !ddr_rd && !ddr_we && !ddr_valid;
    end endgenerate

  logic [31:0] ram[2048], expected_ram[2048];
  int clocks=0, ars=0, reads=0, measured_clocks=0, writes=0;
  int aw=0, w=0, b=0, ds=0, outer_ar=0;
  int aw_at[4096], w_at[4096], aw_addr[4096];
  logic [63:0] wd[4096], producer_data[4096];
  logic [7:0] ws[4096], producer_mask[4096];
  logic [31:0] producer_addr[4096];
  int next_word=0, left=0, read_due=-1, latency=20, seed=1;
  wire [127:0] dbg_cmp={19'd0,1'b1,drained,107'd0};
  wire v_m_idle=idle;
`include "posted_ordering.svh"
  bit ordered_effect_waiting=0;
  logic [31:0] rng=1;
  bit aw_stalled=0,w_stalled=0;
  logic [31:0] saved_aw=0;
  logic [63:0] saved_w=0;
  logic [7:0] saved_strb=0;
  always @(posedge clk) begin
    clocks=clocks+1;
    if(rst_n) begin
      if(bus_err || fault) $fatal(1,"transport fault");
      if(drained && (b!=ds || left!=0 || ddr_rd || ddr_we || ddr_valid))
        $fatal(1,"false external-drain indication");
      if(ordered_effect_waiting && platform_memory_drained && b!=writes)
        $fatal(1,"I/O/debug barrier overtook a core write");
      if(arvalid && arready) ars++;
      if(ddr_we && !ddr_busy) begin
        if(ds>=4096 || ddr_addr>=1024 || ddr_count!=1)
          $fatal(1,"DDR write shape");
        producer_addr[ds]={4'b0,ddr_addr,3'b0};
        producer_data[ds]=ddr_din;
        producer_mask[ds]=ddr_be;
        ds++;
      end
      if(aw_stalled && (!m_axi_awvalid || m_axi_awaddr!==saved_aw))
        $fatal(1,"AW changed under stall");
      if(w_stalled && (!m_axi_wvalid || m_axi_wdata!==saved_w || m_axi_wstrb!==saved_strb))
        $fatal(1,"W changed under stall");
      aw_stalled=m_axi_awvalid && !m_axi_awready; saved_aw=m_axi_awaddr;
      w_stalled=m_axi_wvalid && !m_axi_wready; saved_w=m_axi_wdata; saved_strb=m_axi_wstrb;
      if(m_axi_awvalid && m_axi_awready) begin
        if(aw>=ds || m_axi_awaddr!==producer_addr[aw] ||
           m_axi_awlen!=0 || m_axi_awsize!=3 || m_axi_awburst!=1 || m_axi_awid!=0)
          $fatal(1,"AW mismatch %0d/%0d",aw,ds);
        aw_at[aw]=clocks; aw_addr[aw]=int'(m_axi_awaddr)/4; aw++;
      end
      if(m_axi_wvalid && m_axi_wready) begin
        if(w>=ds || m_axi_wdata!==producer_data[w] ||
           m_axi_wstrb!==producer_mask[w] || !m_axi_wlast)
          $fatal(1,"W mismatch %0d/%0d",w,ds);
        w_at[w]=clocks; wd[w]=m_axi_wdata; ws[w]=m_axi_wstrb; w++;
      end
      if(m_axi_bvalid && m_axi_bready) begin
        if(b>=aw || b>=w) $fatal(1,"unowned B");
        for(int lane=0;lane<8;lane++)
          if(ws[b][lane]) ram[aw_addr[b]+lane/4][8*(lane%4)+:8]=wd[b][8*lane+:8];
        b++;
      end
      if(m_axi_arvalid && m_axi_arready) begin
        if(b!=ds) $fatal(1,"read overtook uncommitted writes");
        if(left!=0 || m_axi_araddr>=8192 || m_axi_arlen!=7 ||
           m_axi_arsize!=3 || m_axi_arburst!=1 || m_axi_arid!=0)
          $fatal(1,"bad outer read shape");
        next_word=int'(m_axi_araddr)/4; left=8; read_due=clocks+7; outer_ar++;
      end
      if(m_axi_rvalid && m_axi_rready) begin
        left--; next_word+=2; read_due=clocks+1+int'(rng%4);
      end
    end
  end
  always @(negedge clk) begin
    rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
    m_axi_awready=rst_n && rng[0+:3]!=0;
    m_axi_wready=rst_n && rng[4+:3]!=0;
    m_axi_arready=rst_n && rng[8+:3]!=0;
    m_axi_bvalid=0;
    if(b<aw && b<w)
      m_axi_bvalid=clocks >= ((aw_at[b]>w_at[b]?aw_at[b]:w_at[b])+latency);
    m_axi_rvalid=left>0 && clocks>=read_due;
    m_axi_rlast=left==1;
    m_axi_rdata=left>0 ? {ram[next_word+1],ram[next_word]} : 0;
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

  task automatic drain;
    ordered_effect_waiting=1;
    for(int guard=0;guard<8192;guard++) begin
      @(negedge clk);
      if(platform_memory_drained) begin
        if(b!=writes || av_write || ddr_we) $fatal(1,"early I/O/debug release");
        ordered_effect_waiting=0;
        return;
      end
    end
    $fatal(1,"full-path drain timeout b=%0d writes=%0d",b,writes);
  endtask
  initial begin
    if($value$plusargs("seed=%d",seed)) rng=32'(seed);
    if($value$plusargs("latency=%d",latency)) begin end
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
    drain();
    begin
      int began,accepted,guard;
      bit accepted_now;
      began=clocks; accepted=0; guard=0;
      @(negedge clk); req=1; we=1; mask=4'hf; addr=32'(600*4); data=32'h45a50000|32'(600);
      while(accepted<64) begin
        @(posedge clk); accepted_now=ack; @(negedge clk);
        if(accepted_now) begin
          expected_ram[600+accepted]=32'h45a50000|32'(600+accepted);
          accepted++; writes++;
          if(accepted<64) begin
            addr=32'((600+accepted)*4); data=32'h45a50000|32'(600+accepted);
          end
        end
        if(++guard>8192) $fatal(1,"store stream timeout");
      end
      req=0; we=0; drain();
      $display("DDRAM-AO486-THROUGHPUT posted=%0d slots=%0d delay=%0d clocks=%0d stores=64",
               POSTED,WRITE_SLOTS,latency,clocks-began);
      for(int base=600;base<664;base+=8) read_line(base,0);
    end
    // Masked aliases + forced misses exercise actual cache-hit updates and
    // read-after-posted-write ordering, not only a synthetic DDR producer.
    for(int j=0;j<512;j++) begin
      int word_addr;
      logic [31:0] value;
      word_addr=512+int'(rng%256); value=rng^32'hBABC1234;
      write_word(word_addr,4'(rng>>16),value);
      if(j%8==7) begin
        if(j%32==31) begin
          @(negedge clk); inv_addr=25'(word_addr/2); inv=1;
          @(negedge clk); inv=0;
          repeat(4) @(negedge clk);
        end
        read_line(word_addr&~7,word_addr%8);
      end
    end
    drain();
    for(int i=0;i<2048;i++)
      if(ram[i]!==expected_ram[i])
        $fatal(1,"final RAM mismatch word=%0d got=%08x expected=%08x",i,ram[i],expected_ram[i]);
    if(aw!=writes || w!=writes || b!=writes || ds!=writes)
      $fatal(1,"unbalanced writes aw=%0d w=%0d b=%0d ddr=%0d cpu=%0d",aw,w,b,ds,writes);
    $display("DDRAM-AO486-PATH-OK seed=%0d delay=%0d posted=%0d slots=%0d writes=%0d reads=%0d AR=%0d",
             seed,latency,POSTED,WRITE_SLOTS,writes,reads,outer_ar);
    $finish;
  end
endmodule
