`timescale 1ns/1ps
// Scratch-module A/B: architectural traffic is fixed; only capture slots vary.
module tb_l1d_window_keep_store;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  logic flush_all=0, golden=0, cacheable=1, snoop_inv_valid=0;
  logic [31:0] snoop_inv_addr=0;
  logic c_req=0, c_we=0, c_ack;
  logic [31:0] c_addr=0, c_wdata=0, c_rdata, c_rdata_hi;
  logic [3:0] c_wstrb=4'hf;
  logic c_rdata_hi_valid;
  logic c_hit_stream=0, c_req_ready, c_rsp_valid, c_rsp_ready=1, c_rsp_cancel;
  logic [31:0] c_rsp_addr;
  logic [7:0] dbg_serve;
  logic m_req, m_we, m_ack, m_rd_narrow, ack_block=0;
  logic [31:0] m_addr, m_wdata, m_rdata;
  logic [3:0] m_wstrb;
  logic [1:0] m_rd_size;
  ven_l1d dut(
      .c_next_req(1'b0), .c_next_commit(1'b0), .c_next_cacheable(1'b0),
      .c_next_addr(32'd0), .c_next_wstrb(4'd0), .c_next_ready(), .*);
`ifdef VEN_L1D_WINDOW_KEEP_STORE
  localparam bit KEEP=1;
`else
  localparam bit KEEP=0;
`endif
`ifdef VEN_L1D_TAG_INVALIDATE
  localparam bit TAG=1;
`else
  localparam bit TAG=0;
`endif
  // Sparse test backing: wrap addresses index their low 16 bits. No test holds
  // two physical synonyms simultaneously; flush precedes the wrap submatrix.
  byte unsigned mem[65536];
  int reads=0, writes=0, read_clocks=0, captures=0, witnesses=0, backing_reads=0;
  logic [31:0] checksum=0;
  function automatic logic [31:0] word_at(input logic [31:0] addr);
    return {mem[16'(addr+3)],mem[16'(addr+2)],mem[16'(addr+1)],mem[16'(addr)]};
  endfunction
  assign m_rdata=word_at(m_addr);
  assign m_ack=m_req && !ack_block;
  always @(posedge clk) begin
    if(rst_n && dut.do_rd_cap) captures++;
    if(rst_n && m_req && m_ack) begin
      if(m_we) begin
        writes++;
        for(int b=0;b<4;b++) if(m_wstrb[b]) mem[16'(m_addr+32'(b))]=m_wdata[b*8 +: 8];
      end else backing_reads++;
    end
  end
  task automatic read_at(input logic [31:0] addr, input int immediate=-1);
    int guard;
    @(negedge clk); c_req=1; c_we=0; c_addr=addr; c_wstrb=4'hf;
    guard=0;
    do begin
      @(posedge clk); read_clocks++; guard++;
      if(guard==1 && immediate>=0) begin
        if(c_ack !== (immediate==1)) $fatal(1,"first ACK addr=%08x want=%0d",addr,immediate);
        if(immediate==1) begin
          if(!dut.window_reuse || m_req || dut.do_rd_cap)
            $fatal(1,"reuse witness missing");
          witnesses++;
        end
      end
      if(guard>200) $fatal(1,"read timeout %08x",addr);
    end while(!c_ack);
    if(c_rdata!==word_at(addr))
      $fatal(1,"stale read %08x got=%08x expected=%08x",addr,c_rdata,word_at(addr));
    checksum={checksum[26:0],checksum[31:27]} ^ c_rdata ^ addr;
    reads++;
    @(negedge clk); c_req=0;
    while(dut.st!=0) @(negedge clk);
  endtask
  task automatic warm(input logic [31:0] addr=32'h1000);
    read_at(addr); read_at(addr);
    if(!dut.window_valid_q) $fatal(1,"warm provenance missing");
  endtask
  task automatic flush();
    @(negedge clk); flush_all=1;
    @(negedge clk); flush_all=0;
    if(dut.window_valid_q) $fatal(1,"flush retained window");
  endtask
  task automatic store_at(input logic [31:0] addr, input logic [3:0] mask,
                          input int delay_cycles, input bit survives);
    int before_writes;
    before_writes=writes;
    @(negedge clk); c_req=1; c_we=1; c_addr=addr; c_wstrb=mask;
    c_wdata=32'hbe39a571 ^ addr; ack_block=(delay_cycles!=0);
    for(int i=0;i<delay_cycles;i++) begin
      @(posedge clk);
      if(c_ack || m_ack || !m_req || !m_we) $fatal(1,"held store ACK/owner changed");
      @(negedge clk);
    end
    ack_block=0;
    @(posedge clk);
    if(!c_ack || !m_ack || !m_we || m_addr!=addr || m_wstrb!=mask || m_wdata!=c_wdata)
      $fatal(1,"store acceptance metadata changed");
    @(negedge clk); c_req=0; c_we=0; c_wstrb=4'hf;
    if(writes!=before_writes+1) $fatal(1,"duplicate/lost store");
    if(dut.window_valid_q !== (KEEP && survives))
      $fatal(1,"window store policy addr=%08x mask=%x keep=%0d survives=%0d",addr,mask,KEEP,survives);
    if(dut.rd_full_line_q || c_rdata_hi_valid) $fatal(1,"store retained FP high-half provenance");
  endtask
  initial begin
    int hi;
    bit overlap;
    for(int i=0;i<65536;i++) mem[i]=8'(i^(i>>8));
    repeat(3) @(negedge clk); rst_n=1;
    // Unrelated cacheable hit/miss stores with every representative ACK delay.
    for(int delay_cycles=0;delay_cycles<8;delay_cycles++) begin
      warm('h2040); warm(); store_at('h2044,4'hf,delay_cycles,1);
      read_at('h1008,int'(KEEP)); read_at('h2044);
      flush(); warm(); store_at('h3044,4'hf,delay_cycles,1);
      read_at('h100c,int'(KEEP)); read_at('h3044);
      // A different physical tag in the same set is not an overlap. Without
      // TAG_INVALIDATE the old cache way may disappear: current hit must veto.
      flush(); warm('h2000); warm(); store_at('h2004,4'hf,delay_cycles,1);
      read_at('h1004,int'(KEEP && TAG)); read_at('h2004);
    end
    // All offsets and all 16 strobes, source line on either side of a store.
    // Includes sparse masks, zero-strobe no-op and partial cross-line writes.
    for(int side=0;side<2;side++) begin
      for(int off=0;off<32;off++) for(int mask=0;mask<16;mask++) begin
        flush(); warm(side==0 ? 32'h1000 : 32'h1020);
        hi=0; for(int b=0;b<4;b++) if((mask & (1<<b))!=0) hi=b;
        overlap=(side==0) || (off+hi>31);
        store_at(32'h1000+32'(off),4'(mask),off%3,!overlap);
        read_at(side==0 ? 32'h1000 : 32'h1020,int'(KEEP && !overlap));
        read_at(32'h1000+32'(off));
      end
    end
    // 32-bit physical wrap: a store in ffffffe0 can touch the saved zero line.
    for(int off=29;off<32;off++) for(int mask=0;mask<16;mask++) begin
      flush(); warm(0);
      hi=0; for(int b=0;b<4;b++) if((mask & (1<<b))!=0) hi=b;
      overlap=(off+hi>31);
      store_at(32'hffffffe0+32'(off),4'(mask),2,!overlap);
      read_at(0,int'(KEEP && !overlap));
      read_at(32'hffffffe0+32'(off));
    end
    flush(); warm(); cacheable=0;
    store_at('h3044,4'hf,3,0); cacheable=1; read_at('h1004,0);
    warm(); @(negedge clk); cacheable=0;
    read_at('h1000,0);
    if(dut.window_valid_q) $fatal(1,"NC read retained window");
    cacheable=1;
    warm(); @(negedge clk); snoop_inv_valid=1; snoop_inv_addr='h1000;
    mem['h1000]=8'hfa;
    @(negedge clk); snoop_inv_valid=0;
    if(dut.window_valid_q) $fatal(1,"snoop retained window");
    read_at('h1000,0);
    warm(); flush(); read_at('h1000,0);
    warm(); @(negedge clk); golden=1;
    @(negedge clk); golden=0;
    if(dut.window_valid_q) $fatal(1,"golden retained window");
    read_at('h1000,0);
    warm(); @(negedge clk); c_hit_stream=1;
    @(negedge clk); c_hit_stream=0;
    if(dut.window_valid_q) $fatal(1,"stream retained window");
    read_at('h1000,0);
    warm(); read_at('h4000,0); // refill must replace, never expand window capacity
    read_at('h1000,0);
    if(KEEP && witnesses==0) $fatal(1,"no recovered slot witnesses");
    $display("WINDOW-KEEP-STORE-RESULT keep=%0d tag=%0d reads=%0d writes=%0d checksum=%08x clocks=%0d captures=%0d reuse=%0d backing_reads=%0d",
             KEEP,TAG,reads,writes,checksum,read_clocks,captures,witnesses,backing_reads);
    $display("L1D-WINDOW-KEEP-STORE-OK"); $finish;
  end
  initial begin #100000000; $fatal(1,"watchdog"); end
endmodule
