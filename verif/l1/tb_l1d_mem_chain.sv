`timescale 1ns/1ps
module tb_l1d_mem_chain;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  logic flush_all=0, golden=0, cacheable=1, snoop_inv_valid=0;
  logic [31:0] snoop_inv_addr=0;
  logic c_req=0, c_we=0, c_ack;
  logic [31:0] c_addr=0, c_wdata=0, c_rdata;
  logic [3:0] c_wstrb=4'hf;
  logic c_next_req=0, c_next_commit=0, c_next_cacheable=1, c_next_ready;
  logic [31:0] c_next_addr=0;
  logic [3:0] c_next_wstrb=4'hf;
  logic [7:0] dbg_serve;
  logic m_req, m_we, m_ack, m_rd_narrow;
  logic [31:0] m_addr, m_wdata, m_rdata;
  logic [3:0] m_wstrb;
  logic [1:0] m_rd_size;
`ifdef VEN_L1D_CODE_BUFFER
  logic c_code=0;
`endif
`ifdef VEN_L1D_STORE_POLICY
  logic [3:0] c_store_update_mask=4'hf;
`endif
`ifdef VEN_P54_DUAL_STORE_PAIR
  logic c_pair_req=0, c_pair_ready, c_pair_ack;
  logic [31:0] c_pair_addr=0, c_pair_wdata=0;
  logic [3:0] c_pair_wstrb=0;
`ifdef VEN_L1D_STORE_POLICY
  logic [3:0] c_pair_store_update_mask=4'hf;
`endif
  logic m_pair_req, m_pair_ready=0, m_pair_ack=0;
  logic [31:0] m_pair_addr, m_pair_wdata;
  logic [3:0] m_pair_wstrb;
`endif
`ifdef VEN_P54_DUAL_HIT
  logic [1:0] pair_req_valid=0, pair_cacheable=2'b11, pair_rsp_ready=2'b11;
  logic [1:0][31:0] pair_paddr='0;
  logic [1:0][1:0] pair_size_log2='0;
  logic [1:0][15:0] pair_owner='0;
  logic [1:0] pair_req_ready, pair_req_split, pair_rsp_valid, pair_rsp_cancel;
  logic pair_bank_conflict;
  logic [1:0][15:0] pair_rsp_owner;
  logic [1:0][31:0] pair_rsp_paddr, pair_rsp_data;
`ifdef VEN_P54_DUAL_BYTE_LOAD_PAIR
  logic pair_now_req=0, pair_now_cacheable=1, pair_now_valid;
  logic [31:0] pair_now_paddr=0, pair_now_data;
  logic [1:0] pair_now_size_log2=0;
`endif
`endif
`ifdef VEN_FP_LOAD64
  logic [31:0] c_rdata_hi;
  logic c_rdata_hi_valid;
`endif
  ven_l1d dut(.*);
  byte unsigned mem[65536];
  int ticks=0, accepted=0, backing=0;
`ifdef VEN_L1D_PERF
  longint unsigned misses_before_next;
`endif
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
      if ((c_wstrb==4'hf && c_rdata!==word_at(c_addr)) ||
          (c_wstrb==4'h1 && c_rdata[7:0]!==mem[c_addr]))
        $fatal(1,"old-response owner/data changed: %08x got=%08x",c_addr,c_rdata);
    end
    if(c_next_req && c_next_commit && c_next_ready) begin
      if((c_req && !c_ack) || m_req)
        $fatal(1,"next accepted without old response / with backing request");
      accepted++;
    end
  end
  task automatic read_at(input logic [31:0] addr);
    int guard;
    @(negedge clk); c_req=1; c_we=0; c_addr=addr; c_wstrb=4'hf;
    guard=0;
    do begin @(posedge clk); if(++guard>200) $fatal(1,"read timeout"); end while(!c_ack);
    @(negedge clk); c_req=0;
    while(dut.st!=0) @(negedge clk);
  endtask
  task automatic arm_old(input logic [31:0] addr);
`ifdef VEN_L1D_TWO_WINDOW_REUSE
    // Exercise a genuine registered owner, not either saved-window hit.
    // Use ordinary reads to move both windows; no hierarchical state forcing.
    read_at('h3040); read_at('h3860);
`endif
    @(negedge clk); c_req=1; c_we=0; c_addr=addr; c_wstrb=4'hf;
    // A normal request captures the registered response on the next edge.
    @(posedge clk); @(negedge clk);
    if(!c_ack || !dut.rd_match) $fatal(1,"old registered response not armed");
  endtask
`ifdef VEN_RAW_V_READ_PRIME
  task automatic prime_only(input logic [31:0] addr);
    @(negedge clk); c_next_req=1; c_next_commit=1; c_next_addr=addr;
    @(posedge clk);
    if (!c_next_ready || c_ack || m_req)
      $fatal(1,"cache-only prime failed / issued backing traffic");
    @(negedge clk); c_next_req=0; c_next_commit=0;
  endtask
`endif
  initial begin
    for(int i=0;i<65536;i++) mem[i]=8'(i^(i>>8));
    repeat(3) @(negedge clk); rst_n=1;
    read_at('h1000); read_at('h2020);
`ifdef VEN_L1D_PERF
    if(dut.perf_miss_start!=2) $fatal(1,"real demand misses not counted");
`endif
    arm_old('h1000);
    // No gaps: old response belongs to c_addr while lookup already addresses
    // an unrelated set. Every edge consumes one old read and accepts one new.
    for(int i=0;i<128;i++) begin
      c_next_req=1; c_next_commit=1;
      c_next_addr=(i%2 ? 32'h1000 : 32'h2020)+32'(i%7)*4;
      @(posedge clk);
      if(!c_next_ready || !c_ack) $fatal(1,"resident chain bubble %0d",i);
      @(negedge clk); c_addr=c_next_addr;
    end
    // Consecutive same-address transactions are distinct explicit acceptances.
    repeat(16) begin
      c_next_addr=c_addr;
      @(posedge clk); if(!c_next_ready) $fatal(1,"same-address chain bubble");
      @(negedge clk);
    end
    // Backpressure holds the old response while arbitrary next addresses move.
    c_next_commit=0;
    repeat(11) begin
      c_next_addr=c_next_addr==32'h1000 ? 32'h2020 : 32'h1000;
      @(posedge clk);
      if(!c_ack || !dut.rd_match || m_req) $fatal(1,"old owner lost under backpressure");
      @(negedge clk);
    end
    // Miss, uncacheable, crossing and unsupported strobe are silent rejection.
    c_next_addr='h4000;
`ifdef VEN_L1D_PERF
    misses_before_next=dut.perf_miss_start;
`endif
    @(posedge clk); if(c_next_ready || m_req) $fatal(1,"next miss allocated");
    @(negedge clk);
`ifdef VEN_L1D_PERF
    if(dut.perf_miss_start!=misses_before_next)
      $fatal(1,"rejected next lookup counted as backing miss");
`endif
    c_next_addr='h1000; c_next_cacheable=0;
    @(posedge clk); if(c_next_ready || m_req) $fatal(1,"speculative MMIO");
    @(negedge clk); c_next_cacheable=1; c_next_addr='h101f;
    @(posedge clk); if(c_next_ready || m_req) $fatal(1,"crossing admitted");
    @(negedge clk); c_next_addr='h1000; c_next_wstrb=4'h3;
    @(posedge clk); if(c_next_ready || m_req) $fatal(1,"unsupported extent admitted");
    @(negedge clk); c_next_addr='h101f; c_next_wstrb=4'h1; c_next_commit=1;
    @(posedge clk); if(!c_next_ready) $fatal(1,"contained byte rejected");
    @(negedge clk); c_addr=c_next_addr; c_wstrb=4'h1;
    c_next_req=0; c_next_commit=0;
    @(posedge clk); if(!c_ack) $fatal(1,"byte response missing");
    @(negedge clk); c_req=0;
    // Store acceptance must never be mistaken for consumption of an old read.
    c_we=1; c_req=1; c_addr='h1000; c_wstrb=4'hf; c_wdata='hbadc0ffe;
    c_next_req=1; c_next_commit=1; c_next_addr='h2020;
    do begin @(posedge clk); if(c_next_ready) $fatal(1,"store accepted next read"); end while(!c_ack);
    @(negedge clk); c_req=0; c_we=0; c_next_req=0; c_next_commit=0;
    read_at('h1000);
`ifdef VEN_L1D_WINDOW_REUSE
    // A second read of the same line can complete directly from the saved
    // window, without creating the rd_match owner this chain fixture needs.
    // Touch an unrelated resident line first so arm_old checks the registered
    // response path in both policy configurations.
    read_at('h2020);
`endif
    arm_old('h1000);
    c_next_req=1; c_next_commit=1; c_next_addr='h2020;
    snoop_inv_valid=1; snoop_inv_addr='h1000; mem['h1000]=8'h76;
    @(posedge clk); if(c_ack || c_next_ready) $fatal(1,"snoop-edge stale handoff");
    @(negedge clk); c_req=0; c_next_req=0; c_next_commit=0; snoop_inv_valid=0;
    read_at('h1000);
`ifdef VEN_L1D_WINDOW_REUSE
    read_at('h2020);
`endif
    arm_old('h1000);
    c_next_req=1; c_next_commit=1; c_next_addr='h2020; flush_all=1;
    @(posedge clk); if(c_ack || c_next_ready) $fatal(1,"flush-edge handoff");
    @(negedge clk); c_req=0; c_next_req=0; c_next_commit=0; flush_all=0;
    read_at('h1000);
`ifdef VEN_L1D_WINDOW_REUSE
    read_at('h2020);
`endif
    arm_old('h1000);
    @(negedge clk); rst_n=0;
    @(negedge clk); rst_n=1; c_req=0;
    if(dut.rd_armed) $fatal(1,"reset retained response");
`ifdef VEN_PIPE_REG_LOAD_PRIME
    // No old read owner: a preceding register instruction can prime only an
    // already-resident, cacheable line.  The next clock must own the ordinary
    // registered ACK, without having allocated a backing transaction.
    read_at('h2020);
    @(negedge clk); c_next_req=1; c_next_commit=0; c_next_addr='h2020;
    @(posedge clk); if(!c_next_ready || c_ack || m_req || dut.rd_armed)
      $fatal(1,"uncommitted prime changed L1 ownership");
    @(negedge clk); c_next_commit=1;
    @(posedge clk); if(!c_next_ready || c_ack || m_req)
      $fatal(1,"resident standalone prime rejected");
    @(negedge clk); c_next_req=0; c_next_commit=0;
    c_req=1; c_we=0; c_addr='h2020; c_wstrb=4'hf;
    @(posedge clk); if(!c_ack || c_rdata!==word_at('h2020))
      $fatal(1,"primed response missing/wrong owner");
    @(negedge clk); c_req=0;
    @(negedge clk); c_next_req=1; c_next_commit=1; c_next_addr='h4000;
    @(posedge clk); if(c_next_ready || m_req)
      $fatal(1,"standalone prime miss allocated");
    @(negedge clk); c_next_addr='h2020; c_next_cacheable=0;
    @(posedge clk); if(c_next_ready || m_req)
      $fatal(1,"standalone prime MMIO admitted");
    @(negedge clk); c_next_req=0; c_next_commit=0; c_next_cacheable=1;
`endif
`ifdef VEN_PIPE_REG_LOAD_PRIME
`ifdef VEN_RAW_V_READ_PRIME
    // Cache-window warming grants no architectural ownership. A frontend gap,
    // snoop, flush, or intervening committed store must be safe before demand.
    read_at('h1000);
    prime_only('h1000);
    repeat (3) @(negedge clk);
    read_at('h1000);
    prime_only('h1000);
    snoop_inv_valid=1; snoop_inv_addr='h1000;
    mem['h1000]=8'h83;
    @(posedge clk); if(c_ack || c_next_ready) $fatal(1,"cache-only prime survived snoop edge");
    @(negedge clk); snoop_inv_valid=0;
    read_at('h1000);
    prime_only('h1000);
    flush_all=1;
    @(posedge clk); if(c_ack || c_next_ready) $fatal(1,"cache-only prime survived flush edge");
    @(negedge clk); flush_all=0;
    read_at('h1000);
    prime_only('h1000);
    c_req=1; c_we=1; c_addr='h1000; c_wstrb=4'hf; c_wdata='h17293b4d;
    do @(posedge clk); while(!c_ack);
    @(negedge clk); c_req=0; c_we=0;
    read_at('h1000);
    if(accepted!=150) $fatal(1,"wrong raw-prime accepted count %0d",accepted);
`else
    if(accepted!=146) $fatal(1,"wrong accepted count %0d",accepted);
`endif
`else
    if(accepted!=145) $fatal(1,"wrong accepted count %0d",accepted);
`endif
    $display("L1D-MEM-CHAIN-OK accepted=%0d backing=%0d",accepted,backing);
    $finish;
  end
  initial begin #1000000; $fatal(1,"watchdog"); end
endmodule
