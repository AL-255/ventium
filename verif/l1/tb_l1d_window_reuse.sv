`timescale 1ns/1ps
module tb_l1d_window_reuse;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  logic flush_all=0, golden=0, cacheable=1, snoop_inv_valid=0;
  logic [31:0] snoop_inv_addr=0;
  logic c_req=0, c_we=0, c_ack;
  logic [31:0] c_addr=0, c_wdata=0, c_rdata;
  logic [3:0] c_wstrb=4'hf;
  logic [7:0] dbg_serve;
  logic m_req, m_we, m_ack, m_rd_narrow;
  logic [31:0] m_addr, m_wdata, m_rdata;
  logic [3:0] m_wstrb;
  logic [1:0] m_rd_size;
  ven_l1d dut(
`ifdef VEN_PIPE_MEM_CHAIN
      .c_next_req(1'b0), .c_next_commit(1'b0), .c_next_cacheable(1'b0),
      .c_next_addr(32'd0), .c_next_wstrb(4'd0), .c_next_ready(),
`endif
.*);
  byte unsigned mem[65536];
  int ticks=0, reads=0, backing=0;
  function automatic logic [31:0] word_at(input logic [31:0] addr);
    return {mem[addr+3],mem[addr+2],mem[addr+1],mem[addr]};
  endfunction
  assign m_rdata=word_at(m_addr);
  assign m_ack=m_req && ((ticks%3)==0);
  always @(posedge clk) begin
    ticks<=ticks+1;
    if(m_req && m_ack) begin
      backing++;
      if(m_we)
        for(int b=0;b<4;b++) if(m_wstrb[b]) mem[m_addr+b]=m_wdata[b*8 +: 8];
    end
    if(rst_n && c_req && !c_we && c_ack) begin
      if(c_rdata!==word_at(c_addr))
        $fatal(1,"stale/wrong read %08x got=%08x expected=%08x",c_addr,c_rdata,word_at(c_addr));
      reads++;
    end
  end
  task automatic read_at(input logic [31:0] addr);
    int guard;
    @(negedge clk); c_req=1; c_we=0; c_addr=addr;
    guard=0;
    do begin
      @(posedge clk);
      if(++guard>200) $fatal(1,"read timeout");
    end while(!c_ack);
    @(negedge clk); c_req=0;
    while(dut.st!=0) @(negedge clk);
  endtask
  task automatic warm();
    read_at('h1000); read_at('h1000);
  endtask
  initial begin
    for(int i=0;i<65536;i++) mem[i]=8'(i^(i>>8));
    repeat(3) @(negedge clk);
    rst_n=1;
    warm();
`ifdef VEN_L1D_TWO_WINDOW_REUSE
    // Both lines must be resident before the one-cycle capture experiment.
    read_at('h1020);
    read_at('h1000);
`endif
    // Repeated same-address and unaligned reads, no gaps between requests.
    for(int i=0;i<128;i++) begin
      @(negedge clk); c_req=1; c_addr=32'h1000+32'(i%29);
      @(posedge clk);
      if(!c_ack || !dut.window_reuse || m_req) $fatal(1,"resident reuse bubble");
    end
    @(negedge clk); c_req=0;
`ifdef VEN_L1D_TWO_WINDOW_REUSE
    // B displaces A from the primary read window, not from the cache. Both
    // resident lines must then serve on their own request edges without a
    // second array capture. A third line may replace only the older shadow.
    read_at('h1020);
    @(negedge clk); c_req=1; c_addr='h1004;
    #1;
    if(!c_ack || !dut.shadow_reuse || dut.do_rd_cap || m_req)
      $fatal(1,"prior resident line was not reused");
    @(posedge clk);
    @(negedge clk); c_addr='h1024;
    #1;
    if(!c_ack || !dut.window_reuse || dut.do_rd_cap || m_req)
      $fatal(1,"newer resident line lost its window");
    @(negedge clk); c_req=0;
    read_at('h1040);
    @(negedge clk); c_req=1; c_addr='h1004;
    #1;
    if(c_ack || dut.shadow_reuse)
      $fatal(1,"shadow became a third cache entry");
    @(negedge clk); c_req=0;
    read_at('h1000);
    read_at('h1020);
    @(negedge clk); flush_all=1; c_req=1; c_addr='h1000;
    #1;
    if(c_ack) $fatal(1,"flush served stale shadow");
    @(negedge clk); flush_all=0; c_req=0;
    if(dut.shadow_valid_q) $fatal(1,"flush retained shadow");
    warm();
`ifdef VEN_L1D_WINDOW_KEEP_STORE
    // KEEP_STORE checks only the primary address. A write to the older
    // shadow line must clear that shadow even though the primary survives.
    read_at('h1020);
    read_at('h1000);
    @(negedge clk); c_req=1; c_we=1; c_addr='h5000; c_wdata='h65748392;
    do @(posedge clk); while(!c_ack);
    @(negedge clk); c_req=0; c_we=0;
    read_at('h1020);
    read_at('h1000);
    if(!dut.shadow_valid_q) $fatal(1,"shadow not established before store");
    if(dut.rd_addr_q[31:5] != 32'h1020 >> 5 ||
       dut.shadow_line_addr_q != 32'h1000 >> 5)
      $fatal(1,"store witness lost primary/shadow ownership");
    @(negedge clk); c_req=1; c_we=1; c_addr='h1004; c_wdata='h76543210;
    do @(posedge clk); while(!c_ack);
    @(negedge clk); c_req=0; c_we=0;
    if(dut.shadow_valid_q || !dut.window_valid_q)
      $fatal(1,"store to shadow line retained stale shadow or lost primary shadow=%b primary=%b primary_addr=%08x shadow_addr=%08x",
             dut.shadow_valid_q,dut.window_valid_q,dut.rd_addr_q,
             {dut.shadow_line_addr_q,5'd0});
    read_at('h1004);
`endif
`endif
    read_at('h101f); // crossing must use the original two-line machinery
    read_at('h2000); // unrelated line must never use the previous window
    warm();
    @(negedge clk); c_req=1; c_we=1; c_addr='h1004; c_wdata='h12345678;
    do @(posedge clk); while(!c_ack);
    @(negedge clk); c_req=0; c_we=0;
    read_at('h1004);
    warm();
    @(negedge clk); snoop_inv_valid=1; snoop_inv_addr='h1000;
    c_req=1; c_addr='h1000; mem['h1000]=8'hfa;
    @(posedge clk); if(c_ack) $fatal(1,"snoop-edge stale ack");
    @(negedge clk); c_req=0; snoop_inv_valid=0;
    read_at('h1000);
    warm();
    @(negedge clk); flush_all=1; c_req=1; c_addr='h1000;
    @(posedge clk); if(c_ack) $fatal(1,"flush-edge stale ack");
    @(negedge clk); flush_all=0; c_req=0;
    read_at('h1000);
    warm();
    @(negedge clk); cacheable=0; mem['h1000]=8'hbe;
    read_at('h1000); // bypass must see backing data, not resident/window data
    @(negedge clk); cacheable=1; flush_all=1;
    @(negedge clk); flush_all=0;
    warm();
    @(negedge clk); golden=1;
    read_at('h1000);
    if(dut.window_valid_q) $fatal(1,"golden retained window");
    @(negedge clk); golden=0; rst_n=0;
    @(negedge clk); rst_n=1;
    if(dut.window_valid_q) $fatal(1,"reset retained window");
    read_at('h1000);
    // Repeated tag replacements in one set (8 KiB, 2-way), interleaved
    // with line/byte retargeting. A retained window must add no cache capacity.
    for(int i=0;i<96;i++) begin
      read_at(32'h1000+32'((i%3)*4096));
      read_at(32'h1000+32'((i%3)*4096)+32'(i%29));
    end
    // Every possible within-line byte offset, including all crossings.
    for(int i=0;i<128;i++) read_at(32'h1000+32'(i));
    $display("L1D-WINDOW-REUSE-OK reads=%0d backing=%0d",reads,backing);
    $finish;
  end
  initial begin #1000000; $fatal(1,"watchdog"); end
endmodule
