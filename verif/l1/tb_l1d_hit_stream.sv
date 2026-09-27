`timescale 1ns/1ps
module tb_l1d_hit_stream;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  logic flush_all=0, golden=0, cacheable=1, snoop_inv_valid=0;
  logic [31:0] snoop_inv_addr=0;
  logic c_req=0, c_we=0, c_ack;
  logic [31:0] c_addr=0, c_wdata=0, c_rdata;
  logic [3:0] c_wstrb=4'hf;
  logic c_hit_stream=0, c_req_ready, c_rsp_valid, c_rsp_ready=0, c_rsp_cancel;
  logic [31:0] c_rsp_addr;
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
  int ticks=0, accepts=0, responses=0, cancels=0, backing=0;
  logic [31:0] expected_addr[$], expected_data[$];
  logic [31:0] rng=32'h013579bd;
  function automatic logic [31:0] word_at(input logic [31:0] addr);
    return {mem[addr+3],mem[addr+2],mem[addr+1],mem[addr]};
  endfunction
  assign m_rdata=word_at(m_addr);
  assign m_ack=m_req && ((ticks % 3)==0);
  always @(posedge clk) begin
    ticks <= ticks+1;
    if (m_req && m_ack) begin
      backing++;
      if(m_we)
        for(int b=0;b<4;b++) if(m_wstrb[b]) mem[m_addr+b]=m_wdata[b*8 +: 8];
    end
    if(!rst_n) begin
      expected_addr.delete(); expected_data.delete();
    end else begin
      if(dut.stream_path && m_req) $fatal(1,"stream generated backing traffic");
      if(c_rsp_cancel) begin
        if(expected_addr.size()!=1 || c_rsp_valid || c_ack)
          $fatal(1,"cancel did not name exactly one unconsumed response");
        void'(expected_addr.pop_front()); void'(expected_data.pop_front());
        cancels++;
      end else if(c_rsp_valid) begin
        if(expected_addr.size()!=1 || c_rsp_addr!==expected_addr[0] || c_rdata!==expected_data[0])
          $fatal(1,"response identity/data changed, address=%08x data=%08x",c_rsp_addr,c_rdata);
        if(c_rsp_ready) begin
          void'(expected_addr.pop_front()); void'(expected_data.pop_front());
          responses++;
        end
      end
      if(c_hit_stream && c_req && c_req_ready) begin
        expected_addr.push_back(c_addr); expected_data.push_back(word_at(c_addr)); accepts++;
      end
      if(expected_addr.size()>1) $fatal(1,"one-slot capacity exceeded");
    end
  end

  task automatic legacy_read(input logic [31:0] addr);
    int guard;
    @(negedge clk); c_hit_stream=0; c_req=1; c_we=0; c_addr=addr; c_wstrb=4'hf;
    guard=0;
    do begin
      @(posedge clk);
      if(++guard>200) $fatal(1,"legacy read timeout %08x",addr);
    end while(!c_ack);
    if(c_rdata!==word_at(addr)) $fatal(1,"legacy read value %08x",addr);
    @(negedge clk); c_req=0;
    while(dut.st!=0) @(negedge clk); // drain a critical-word-first fill
    repeat(2) @(negedge clk);
  endtask
  task automatic warm();
    cacheable=1;
    legacy_read(32'h1000); legacy_read(32'h1020);
  endtask
  task automatic drain();
    @(negedge clk); c_req=0; c_rsp_ready=1;
    repeat(2) @(negedge clk);
    if(c_rsp_valid || expected_addr.size()!=0) $fatal(1,"response did not drain");
  endtask
  task automatic throughput(input bit same_address);
    int before_a, before_r;
    before_a=accepts; before_r=responses;
    for(int i=0;i<64;i++) begin
      @(negedge clk); c_hit_stream=1; c_req=1; c_rsp_ready=1;
      c_addr=same_address ? 32'h1003 : 32'h1000+32'(i%61);
      // Do not cross either 32-byte line; include unaligned dwords.
      if(c_addr[4:0]>28) c_addr=c_addr-3;
      @(posedge clk);
      if(!c_req_ready) $fatal(1,"stream throughput bubble at %0d",i);
      if(i>0 && !c_rsp_valid) $fatal(1,"missing pipelined response at %0d",i);
    end
    drain();
    if(accepts-before_a!=64 || responses-before_r!=64) $fatal(1,"throughput count mismatch");
  endtask
  task automatic rejected(input logic [31:0] addr, input bit nc, input bit wr,
                          input logic [3:0] strobes);
    int before_b, before_a;
    logic before_lru;
    before_b=backing; before_a=accepts;
    @(negedge clk); c_hit_stream=1; c_req=1; c_addr=addr;
    cacheable=!nc; c_we=wr; c_wstrb=strobes; c_rsp_ready=1;
    before_lru=dut.dc_lru[addr[11:5]];
    repeat(5) begin
      @(posedge clk);
      if(c_req_ready || c_ack || m_req) $fatal(1,"rejected request had side effect");
    end
    @(negedge clk); c_req=0; cacheable=1; c_we=0; c_wstrb=4'hf;
    if(backing!=before_b || accepts!=before_a) $fatal(1,"rejection counted as access");
    if(dut.dc_lru[addr[11:5]]!==before_lru) $fatal(1,"rejected request changed LRU");
  endtask
  task automatic cancel_held(input int kind, input bit replace_attempt);
    warm();
    @(negedge clk); c_hit_stream=1; c_req=1; c_addr=32'h1004; c_rsp_ready=0;
    @(posedge clk); if(!c_req_ready) $fatal(1,"cancel fixture not accepted");
    @(negedge clk); c_req=0;
    repeat(3) @(negedge clk);
    if(!c_rsp_valid) $fatal(1,"held response disappeared");
    // Cancel must win even when the old response would be consumed and a
    // different resident read would otherwise replace it on this same edge.
    c_rsp_ready=replace_attempt; c_req=replace_attempt; c_addr=32'h1020;
    case(kind)
      0: flush_all=1;
      1: begin snoop_inv_valid=1; snoop_inv_addr=32'h1000; end
      2: golden=1;
    endcase
    @(posedge clk);
    if(!c_rsp_cancel || c_rsp_valid || c_req_ready) $fatal(1,"missing cancellation or stale replacement");
    @(negedge clk); c_req=0; flush_all=0; snoop_inv_valid=0; golden=0;
    if(c_rsp_valid) $fatal(1,"canceled response resurrected");
  endtask

  initial begin
    for(int i=0;i<65536;i++) mem[i]=8'(i ^ (i>>8) ^ 8'ha5);
    repeat(3) @(negedge clk); rst_n=1;
    warm(); throughput(0); throughput(1);
    // Independent producer/consumer pacing. New request address changes only
    // after acceptance; a stalled response must keep its old identity/data.
    for(int i=0;i<1000;i++) begin
      @(negedge clk);
      rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
      c_req=1; c_addr=32'h1000+32'(accepts%29); c_rsp_ready=rng[2:0]!=0;
    end
    drain();
    // Even an early mode switch cannot acknowledge a legacy write with the
    // previous stream read's completion or overwrite its held data register.
    @(negedge clk); c_req=1; c_addr=32'h1000; c_rsp_ready=0;
    @(posedge clk); if(!c_req_ready) $fatal(1,"mode-switch fixture not accepted");
    @(negedge clk); c_hit_stream=0; c_we=1; c_addr=32'h1024; c_wdata=32'h12345678;
    repeat(3) begin
      @(posedge clk);
      if(c_ack || m_req || !c_rsp_valid) $fatal(1,"early legacy request stole stream response");
    end
    @(negedge clk); c_rsp_ready=1;
    @(posedge clk); if(c_ack || m_req) $fatal(1,"stream consume acknowledged legacy write");
    do @(posedge clk); while(!c_ack);
    @(negedge clk); c_req=0; c_we=0;
    if(word_at(32'h1024)!==32'h12345678) $fatal(1,"legacy write not forwarded");
    legacy_read(32'h1024);
    // Response attributes belong to the ACCEPTED request, not the currently
    // presented noncacheable address. Retire the old response, reject the new
    // stream request, then service that new request through narrow legacy I/O.
    @(negedge clk); c_hit_stream=1; c_req=1; c_addr=32'h1004; c_rsp_ready=0;
    @(posedge clk); if(!c_req_ready) $fatal(1,"attribute fixture not accepted");
    @(negedge clk); c_addr=32'h1020; cacheable=0; c_rsp_ready=1;
    @(posedge clk);
    if(!c_rsp_valid || !c_ack || c_rsp_addr!=32'h1004 || c_req_ready || m_req)
      $fatal(1,"next request attributes corrupted old response");
    @(negedge clk); c_req=0;
    begin
      int before_b;
      before_b=backing;
      legacy_read(32'h1020);
      if(backing<=before_b) $fatal(1,"noncacheable fallback did not read backing");
    end
    cacheable=1;
    rejected(32'h8000,0,0,4'hf); // miss
    rejected(32'h1000,1,0,4'hf); // resident but noncacheable
    rejected(32'h1000,0,1,4'hf); // write
    rejected(32'h101d,0,0,4'hf); // line-crossing dword
    rejected(32'h1000,0,0,4'h1); // byte access belongs to legacy path
    for(int k=0;k<3;k++) begin cancel_held(k,0); cancel_held(k,1); end
    // Invalidation on capture edge must accept nothing.
    warm();
    @(negedge clk); c_hit_stream=1; c_req=1; c_addr=32'h1000;
    snoop_inv_valid=1; snoop_inv_addr=32'h1000;
    @(posedge clk); if(c_req_ready) $fatal(1,"snoop/capture race accepted");
    @(negedge clk); c_req=0; snoop_inv_valid=0;
    if(c_rsp_valid) $fatal(1,"snoop/capture race published stale data");
    // Return to the original miss/fill protocol and check fresh data.
    mem[32'h1000]=8'h12; legacy_read(32'h1000);
    // A reset may cancel an unconsumed stream response, never replay it later.
    @(negedge clk); c_hit_stream=1; c_req=1; c_addr=32'h1000; c_rsp_ready=0;
    @(posedge clk); if(!c_req_ready) $fatal(1,"reset fixture not accepted");
    @(negedge clk); rst_n=0; c_req=0;
    repeat(2) @(negedge clk); rst_n=1; c_hit_stream=0;
    if(c_rsp_valid || c_ack) $fatal(1,"reset retained a response");
    legacy_read(32'h1000);
    if(accepts<800 || responses<800 || cancels!=6) $fatal(1,"insufficient coverage");
    $display("L1D-HIT-STREAM-OK accepted=%0d responses=%0d cancels=%0d",accepts,responses,cancels);
    $finish;
  end
  initial begin #2000000; $fatal(1,"global timeout"); end
endmodule
