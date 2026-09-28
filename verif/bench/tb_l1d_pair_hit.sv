`timescale 1ns/1ps
module tb_l1d_pair_hit;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  logic flush_all=0, golden=0, cacheable=1, snoop_inv_valid=0;
  logic [31:0] snoop_inv_addr=0;
  logic c_req=0, c_we=0, c_ack;
  logic [31:0] c_addr=0, c_wdata=0, c_rdata;
  logic [3:0] c_wstrb=4'hf;
  logic [1:0] pair_req_valid=0, pair_cacheable=2'b11;
  logic [1:0][31:0] pair_paddr=0, pair_rsp_paddr, pair_rsp_data;
  logic [1:0][1:0] pair_size_log2=0;
  logic [1:0][15:0] pair_owner=0, pair_rsp_owner;
  logic [1:0] pair_req_ready, pair_req_split, pair_rsp_valid;
  logic [1:0] pair_rsp_cancel, pair_rsp_ready=2'b11;
`ifdef VEN_P54_DUAL_BYTE_LOAD_PAIR
  logic pair_now_req=0, pair_now_cacheable=1;
  logic [31:0] pair_now_paddr=0;
  logic [1:0] pair_now_size_log2=0;
  logic pair_now_valid;
  logic [31:0] pair_now_data;
`endif
  logic pair_bank_conflict;
  logic [7:0] dbg_serve;
`ifdef VEN_PIPE_MEM_CHAIN
  logic c_next_req=0, c_next_commit=0, c_next_cacheable=1, c_next_ready;
  logic [31:0] c_next_addr=0;
  logic [3:0] c_next_wstrb=4'hf;
`endif
  logic m_req, m_we, m_ack, m_rd_narrow;
  logic [31:0] m_addr, m_wdata, m_rdata;
  logic [3:0] m_wstrb;
  logic [1:0] m_rd_size;
  byte unsigned mem[65536];
  int checks=0, accepts=0, responses=0, cancels=0, backing=0;
  ven_l1d dut(.*);

  function automatic logic [31:0] word_at(input logic [31:0] addr);
    return {mem[addr+3], mem[addr+2], mem[addr+1], mem[addr]};
  endfunction
  assign m_rdata = word_at(m_addr);
  assign m_ack = m_req;
  always @(posedge clk) if (rst_n) begin
    if (m_req && m_ack) begin
      backing++;
      if (m_we)
        for (int b=0;b<4;b++)
          if (m_wstrb[b]) mem[m_addr+b]=m_wdata[8*b +: 8];
    end
    accepts += $countones(pair_req_valid & pair_req_ready);
    responses += $countones(pair_rsp_valid & pair_rsp_ready);
    cancels += $countones(pair_rsp_cancel);
    checks++;
  end

  task automatic legacy_read(input logic [31:0] addr);
    int guard;
    @(negedge clk); c_req=1; c_we=0; c_addr=addr; c_wstrb=4'hf;
    guard=0;
    do begin
      @(posedge clk);
      if (++guard>100) $fatal(1,"legacy read timed out %08x",addr);
    end while (!c_ack);
    if (c_rdata !== word_at(addr)) $fatal(1,"legacy data mismatch %08x",addr);
    @(negedge clk); c_req=0;
    while (dut.st!=0) @(negedge clk);
    repeat(2) @(negedge clk);
  endtask

  task automatic legacy_write(input logic [31:0] addr,
                              input logic [31:0] data);
    int guard;
    @(negedge clk); c_req=1; c_we=1; c_addr=addr;
    c_wdata=data; c_wstrb=4'hf;
    guard=0;
    do begin
      @(posedge clk);
      if (++guard>100) $fatal(1,"legacy write timed out %08x",addr);
    end while (!c_ack);
    @(negedge clk); c_req=0; c_we=0;
    repeat(2) @(negedge clk);
  endtask

  task automatic expect_pair(input logic [1:0] expected_ready);
    #1;
    if (pair_req_ready !== expected_ready)
      $fatal(1,"pair ready got=%b expected=%b c_addr=%08x window=%b shadow=%b",
             pair_req_ready,expected_ready,c_addr,
             dut.window_reuse,dut.shadow_reuse);
  endtask

  initial begin
    int backing_before;
    for (int i=0;i<65536;i++) mem[i]=8'(i ^ (i>>8) ^ 8'ha5);
    repeat(3) @(negedge clk); rst_n=1;
    legacy_read(32'h1000); legacy_read(32'h1024); legacy_read(32'h1020);
    backing_before=backing;
    @(negedge clk);
    pair_req_valid=2'b11; pair_paddr[0]=32'h1000;
    pair_paddr[1]=32'h1024; pair_size_log2='{2'd2,2'd2};
    pair_owner='{16'd2,16'd1};
    expect_pair(2'b11);
    @(posedge clk); @(negedge clk); pair_req_valid=0;
    if (pair_rsp_valid!==2'b11 || pair_rsp_owner[0]!==16'd1 ||
        pair_rsp_owner[1]!==16'd2 ||
        pair_rsp_data[0]!==word_at(32'h1000) ||
        pair_rsp_data[1]!==word_at(32'h1024))
      $fatal(1,"distinct-bank pair response mismatch");
    @(posedge clk); @(negedge clk);

    // Both response slots consume and replace on every edge. This is the
    // throughput contract for two bank-distinct resident reads per clock,
    // independent of whether the current core can issue V memory yet.
    pair_req_valid=2'b11;
    pair_paddr[0]=32'h1000; pair_paddr[1]=32'h1004;
    for (int i=0; i<32; i++) begin
      pair_owner[0]=16'(2*i+16); pair_owner[1]=16'(2*i+17);
      expect_pair(2'b11);
      @(posedge clk); @(negedge clk);
      if (pair_rsp_valid!==2'b11 ||
          pair_rsp_owner[0]!==16'(2*i+16) ||
          pair_rsp_owner[1]!==16'(2*i+17) ||
          pair_rsp_data[0]!==word_at(32'h1000) ||
          pair_rsp_data[1]!==word_at(32'h1004))
        $fatal(1,"back-to-back two-bank response mismatch iteration=%0d",i);
    end
    pair_req_valid=0;
    @(posedge clk); @(negedge clk);
    if (pair_rsp_valid!=0 || backing!=backing_before)
      $fatal(1,"back-to-back pairs stalled or reached backing memory");

    pair_req_valid=2'b11; pair_paddr[0]=32'h1000;
    pair_paddr[1]=32'h1020; pair_owner='{16'd4,16'd3};
    expect_pair(2'b01);
    if (!pair_bank_conflict) $fatal(1,"same-bank conflict missing");
    @(posedge clk); @(negedge clk);
    pair_req_valid=2'b10; // U accepted, V remains the same unaccepted owner
    expect_pair(2'b10);
    if (!pair_rsp_valid[0] || pair_rsp_owner[0]!==16'd3)
      $fatal(1,"same-bank U completion lost");
    @(posedge clk); @(negedge clk); pair_req_valid=0;
    if (!pair_rsp_valid[1] || pair_rsp_owner[1]!==16'd4 ||
        pair_rsp_data[1]!==word_at(32'h1020))
      $fatal(1,"same-bank V completion lost");
    @(posedge clk); @(negedge clk);

    // Unaligned dword uses adjacent banks. A non-overlapping V bank can still
    // complete alongside it; byte/word returns are zero-extended.
    pair_req_valid=2'b11; pair_paddr[0]=32'h1001;
    pair_paddr[1]=32'h1028; pair_owner='{16'd6,16'd5};
    expect_pair(2'b11);
    @(posedge clk); @(negedge clk); pair_req_valid=0;
    if (pair_rsp_data[0]!==word_at(32'h1001) ||
        pair_rsp_data[1]!==word_at(32'h1028))
      $fatal(1,"unaligned dword assembly mismatch");
    @(posedge clk); @(negedge clk);

    pair_req_valid=2'b11; pair_paddr[0]=32'h101f;
    pair_paddr[1]=32'h1024; pair_size_log2[0]=2'd0;
    pair_size_log2[1]=2'd1;
    expect_pair(2'b11);
    @(posedge clk); @(negedge clk); pair_req_valid=0;
    if (pair_rsp_data[0]!=={24'd0,mem[32'h101f]} ||
        pair_rsp_data[1]!=={16'd0,mem[32'h1025],mem[32'h1024]})
      $fatal(1,"byte/word extraction mismatch");
    @(posedge clk); @(negedge clk);

    pair_req_valid=2'b11; pair_paddr[0]=32'h101f;
    pair_paddr[1]=32'h1024; pair_size_log2[0]=2'd2;
    pair_size_log2[1]=2'd2;
    expect_pair(2'b00);
    if (!pair_req_split[0]) $fatal(1,"split U not identified");
    pair_req_valid=2'b10; // external fallback takes U; V is still unaccepted
    expect_pair(2'b10);
    @(posedge clk); @(negedge clk); pair_req_valid=0;
    @(posedge clk); @(negedge clk);
    if (backing!=backing_before)
      $fatal(1,"pair hits or rejected split caused backing traffic");

    // A held response cannot be overwritten, and a same-cycle consume can
    // accept its replacement with a new owner/data word.
    pair_rsp_ready[0]=0; pair_req_valid=2'b01;
    pair_paddr[0]=32'h1004; pair_owner[0]=16'h1111;
    expect_pair(2'b01);
    @(posedge clk); @(negedge clk);
    pair_paddr[0]=32'h1008; pair_owner[0]=16'h2222;
    repeat(4) begin
      expect_pair(2'b00);
      if (!pair_rsp_valid[0] || pair_rsp_owner[0]!==16'h1111 ||
          pair_rsp_data[0]!==word_at(32'h1004))
        $fatal(1,"held response changed");
      @(posedge clk); @(negedge clk);
    end
    pair_rsp_ready[0]=1;
    expect_pair(2'b01);
    @(posedge clk); @(negedge clk); pair_req_valid=0;
    if (!pair_rsp_valid[0] || pair_rsp_owner[0]!==16'h2222 ||
        pair_rsp_data[0]!==word_at(32'h1008))
      $fatal(1,"consume-and-replace response mismatch");
    @(posedge clk); @(negedge clk);

    pair_rsp_ready[0]=0; pair_req_valid=2'b01;
    pair_paddr[0]=32'h1000; pair_owner[0]=16'h3333;
    expect_pair(2'b01);
    @(posedge clk); @(negedge clk); pair_req_valid=0; flush_all=1;
    #1;
    if (pair_rsp_valid[0] || !pair_rsp_cancel[0])
      $fatal(1,"flush failed to cancel held owner");
    @(posedge clk); @(negedge clk); flush_all=0;
    if (pair_rsp_valid!=0) $fatal(1,"canceled owner resurrected");
    pair_rsp_ready=2'b11;

    // A new legacy read's first capture edge owns the banks exclusively.
    // Once its registered response is ready, the old data comes from the
    // captured window and a distinct-bank pair can read the arrays on the
    // SAME consumption edge without changing the old owner or data.
    legacy_read(32'h1000);
    @(negedge clk); c_req=1; c_addr=32'h1004;
    pair_req_valid=2'b11; pair_paddr[0]=32'h1000;
    pair_paddr[1]=32'h1008;
    expect_pair(2'b00);
    @(posedge clk); if (c_ack && c_rdata!==word_at(32'h1004))
      $fatal(1,"legacy response corrupted by pair probe");
    @(negedge clk);
    if (!c_ack || c_rdata!==word_at(32'h1004))
      $fatal(1,"registered legacy response not ready before overlap");
`ifdef VEN_L1D_COMB_ACK
    // Its response still uses the LIVE banks, so V must wait until U leaves.
    expect_pair(2'b00);
    @(posedge clk);
    if (!c_ack || c_rdata!==word_at(32'h1004))
      $fatal(1,"combinational legacy response corrupted by pair probe");
    @(negedge clk); c_req=0;
    expect_pair(2'b11);
    @(posedge clk);
    @(negedge clk); pair_req_valid=0;
`else
    expect_pair(2'b11);
    @(posedge clk);
    if (!c_ack || c_rdata!==word_at(32'h1004))
      $fatal(1,"legacy response corrupted on pair acceptance edge");
    @(negedge clk); c_req=0; pair_req_valid=0;
`endif
    if (pair_rsp_valid!==2'b11 ||
        pair_rsp_data[0]!==word_at(32'h1000) ||
        pair_rsp_data[1]!==word_at(32'h1008))
      $fatal(1,"overlapped pair response mismatch");
    repeat(2) @(negedge clk);

`ifdef VEN_P54_DUAL_HIT_LEGACY_CAPTURE
    // A fresh aligned U hit captures its normal registered response while
    // the otherwise idle bank reads a younger V from a DIFFERENT line.
    // The mixed full-line window must not be reused at U's next offset.
    legacy_read(32'h1000); legacy_read(32'h1024);
    @(negedge clk); c_req=1; c_we=0; c_addr=32'h1000;
    pair_req_valid=2'b10; pair_paddr[1]=32'h1024;
    pair_size_log2[1]=2'd2; pair_owner[1]=16'h6601;
    expect_pair(2'b10);
    if (c_ack) $fatal(1,"fresh U read unexpectedly acknowledged before capture");
    @(posedge clk); @(negedge clk);
    pair_req_valid=0;
    if (!c_ack || c_rdata!==word_at(32'h1000) ||
        pair_rsp_valid!==2'b10 || pair_rsp_owner[1]!==16'h6601 ||
        pair_rsp_data[1]!==word_at(32'h1024))
      $fatal(1,"fresh U/V registered response ownership or data mismatch");
    if (dut.window_valid_q)
      $fatal(1,"mixed-bank capture left a reusable full-line window");
    @(posedge clk); @(negedge clk); c_req=0;
    if (pair_rsp_valid!=0) $fatal(1,"fresh V response duplicated");
    legacy_read(32'h1004);

    // A same-bank V cannot steal U's word, but rejection cannot slow or
    // corrupt U's ordinary hit response.
    legacy_read(32'h1024); // move reusable window off U's line
    @(negedge clk); c_req=1; c_addr=32'h1000;
    pair_req_valid=2'b10; pair_paddr[1]=32'h1020;
    expect_pair(2'b00);
`ifdef VEN_L1D_TWO_WINDOW_REUSE
    // The previous complete U line may be served by the shadow on this edge;
    // that is not a bank capture and must not fabricate a V owner.
    if (!pair_bank_conflict && !dut.shadow_reuse)
      $fatal(1,"same-bank V rejection has no U owner");
`else
    if (!pair_bank_conflict) $fatal(1,"legacy U/V bank conflict not reported");
`endif
    @(posedge clk); @(negedge clk); pair_req_valid=0;
    if (!c_ack || c_rdata!==word_at(32'h1000) || pair_rsp_valid!=0)
      $fatal(1,"same-bank V rejection disturbed U");
    @(posedge clk); @(negedge clk); c_req=0;
`ifdef VEN_P54_DUAL_BYTE_LOAD_PAIR
    // A byte U owns only its physical bank, including the last byte of a
    // line. A younger byte V in another bank must receive its own response;
    // a same-bank V must remain unaccepted without delaying U.
`ifdef VEN_L1D_TWO_WINDOW_REUSE
    // The preceding dword test can leave U's line in the shadow. Refresh its
    // identical word to invalidate that shadow without changing memory data;
    // this block is specifically testing a fresh bank capture, not reuse.
    legacy_write(32'h1000, word_at(32'h1000));
    backing_before=backing;
`endif
    legacy_read(32'h1024);
    @(negedge clk); c_req=1; c_we=0; c_addr=32'h1001; c_wstrb=4'h1;
    pair_req_valid=2'b10; pair_paddr[1]=32'h1024;
    pair_size_log2[1]=2'd0; pair_owner[1]=16'h6801;
    expect_pair(2'b10);
    if (c_ack) $fatal(1,"fresh byte U acknowledged before capture");
    @(posedge clk); @(negedge clk); pair_req_valid=0;
    if (!c_ack || c_rdata[7:0]!==mem[32'h1001] ||
        pair_rsp_valid!==2'b10 || pair_rsp_owner[1]!==16'h6801 ||
        pair_rsp_data[1]!=={24'd0,mem[32'h1024]})
      $fatal(1,"fresh byte U/V response ownership or data mismatch");
    @(posedge clk); @(negedge clk); c_req=0; c_wstrb=4'hf;
    legacy_read(32'h1024);

    @(negedge clk); c_req=1; c_addr=32'h101f; c_wstrb=4'h1;
    pair_req_valid=2'b10; pair_paddr[1]=32'h1020;
    pair_size_log2[1]=2'd0; pair_owner[1]=16'h6802;
    expect_pair(2'b10);
    @(posedge clk); @(negedge clk); pair_req_valid=0;
    if (!c_ack || c_rdata[7:0]!==mem[32'h101f] ||
        pair_rsp_valid!==2'b10 || pair_rsp_owner[1]!==16'h6802 ||
        pair_rsp_data[1]!=={24'd0,mem[32'h1020]})
      $fatal(1,"line-end byte U/V response mismatch");
    @(posedge clk); @(negedge clk); c_req=0; c_wstrb=4'hf;
    legacy_read(32'h1024);

    @(negedge clk); c_req=1; c_addr=32'h1001; c_wstrb=4'h1;
    pair_req_valid=2'b10; pair_paddr[1]=32'h1020;
    pair_size_log2[1]=2'd0;
    expect_pair(2'b00);
    if (!pair_bank_conflict)
      $fatal(1,"same-bank byte V conflict not reported");
    @(posedge clk); @(negedge clk); pair_req_valid=0;
    if (!c_ack || c_rdata[7:0]!==mem[32'h1001] || pair_rsp_valid!=0)
      $fatal(1,"same-bank byte V rejection disturbed U");
    @(posedge clk); @(negedge clk); c_req=0; c_wstrb=4'hf;
    pair_size_log2[1]=2'd2;

    // A complete registered line window can serve both bytes immediately.
    // It must not also enqueue the V on the older registered sideband.
    legacy_read(32'h1000);
    @(negedge clk); c_req=1; c_addr=32'h1004; c_wstrb=4'h1;
    pair_req_valid=2'b10; pair_paddr[1]=32'h1008;
    pair_size_log2[1]=2'd0; pair_owner[1]=16'h6803;
    pair_now_req=1; pair_now_paddr=32'h1008;
    #1;
    if (!c_ack || !pair_now_valid ||
        pair_now_data!=={24'd0,mem[32'h1008]} || pair_req_ready[1])
      $fatal(1,"same-window byte return not immediate or double accepted");
    pair_now_cacheable=0; #1;
    if (pair_now_valid) $fatal(1,"uncacheable V used immediate window");
    pair_now_cacheable=1; pair_now_paddr=32'h1048; pair_paddr[1]=32'h1048; #1;
    if (pair_now_valid) $fatal(1,"uncaptured line used immediate window");
    pair_now_paddr=32'h1008; pair_paddr[1]=32'h1008;
    snoop_inv_valid=1; #1;
    if (pair_now_valid) $fatal(1,"snooped window served immediate V");
    snoop_inv_valid=0; flush_all=1; #1;
    if (pair_now_valid) $fatal(1,"flushed window served immediate V");
    flush_all=0; #1;
    if (!pair_now_valid) $fatal(1,"unpoisoned same-window V lost");
    @(posedge clk); @(negedge clk); c_req=0; pair_req_valid=0;
    pair_now_req=0;
    c_wstrb=4'hf; pair_size_log2[1]=2'd2;
    if (pair_rsp_valid[1])
      $fatal(1,"immediate byte return enqueued a duplicate V response");

    legacy_read(32'h1000);
    @(negedge clk); c_req=1; c_addr=32'h1004; c_wstrb=4'h1;
    pair_req_valid=2'b10; pair_paddr[1]=32'h1005;
    pair_size_log2[1]=2'd0; pair_now_req=1;
    pair_now_paddr=32'h1005; pair_now_size_log2=2'd0;
    #1;
    if (!c_ack || pair_now_valid || pair_req_ready[1])
      $fatal(1,"same-bank byte V bypassed P54 bank conflict");
    @(posedge clk); @(negedge clk); c_req=0; pair_req_valid=0;
    pair_now_req=0; c_wstrb=4'hf; pair_size_log2[1]=2'd2;

    legacy_read(32'h1000);
    @(negedge clk); c_req=1; c_addr=32'h1004;
    pair_req_valid=2'b10; pair_paddr[1]=32'h1008;
    pair_size_log2[1]=2'd2; pair_owner[1]=16'h6804;
    pair_now_req=1; pair_now_paddr=32'h1008; pair_now_size_log2=2'd2;
    #1;
    if (!c_ack || !pair_now_valid ||
        pair_now_data!==word_at(32'h1008) || pair_req_ready[1])
      $fatal(1,"same-window dword return not immediate or double accepted");
    pair_now_paddr=32'h101d; #1;
    if (pair_now_valid) $fatal(1,"cross-line dword used immediate window");
    pair_now_paddr=32'h1008;
    @(posedge clk); @(negedge clk); c_req=0; pair_req_valid=0;
    pair_now_req=0; pair_now_size_log2=0;
    if (pair_rsp_valid[1])
      $fatal(1,"immediate dword return enqueued a duplicate V response");
`endif
`ifdef VEN_P54_DUAL_LOAD_PRIME
    // A checked lookahead captures U without a live c_req. It may reserve
    // U's bank and capture V on another bank only if commit is authorized.
`ifdef VEN_L1D_TWO_WINDOW_REUSE
`ifdef VEN_P54_DUAL_BYTE_LOAD_PAIR
    legacy_write(32'h1000, word_at(32'h1000));
    backing_before=backing;
`endif
`endif
    legacy_read(32'h1024);
    @(negedge clk); c_next_req=1; c_next_commit=0;
    c_next_addr=32'h1000; pair_req_valid=2'b10;
    pair_paddr[1]=32'h1024; pair_owner[1]=16'h7701;
    #1;
    if (!c_next_ready || pair_req_ready[1])
      $fatal(1,"uncommitted lookahead admitted V");
    c_next_commit=1;
    expect_pair(2'b10);
    @(posedge clk); @(negedge clk);
    c_next_req=0; c_next_commit=0; pair_req_valid=0;
    c_req=1; c_addr=32'h1000;
    #1;
    if (!c_ack || c_rdata!==word_at(32'h1000) ||
        pair_rsp_valid!==2'b10 || pair_rsp_owner[1]!==16'h7701 ||
        pair_rsp_data[1]!==word_at(32'h1024) || dut.window_valid_q)
      $fatal(1,"primed U/V owner, data or mixed-window failure ack=%b data=%08x vrsp=%b owner=%x vdata=%08x window=%b",
             c_ack,c_rdata,pair_rsp_valid,pair_rsp_owner[1],
             pair_rsp_data[1],dut.window_valid_q);
    @(posedge clk); @(negedge clk); c_req=0;

`ifdef VEN_P54_DUAL_BYTE_LOAD_PAIR
    legacy_read(32'h1024);
    @(negedge clk); c_next_req=1; c_next_commit=0;
    c_next_addr=32'h1001; c_next_wstrb=4'h1;
    pair_req_valid=2'b10; pair_paddr[1]=32'h1024;
    pair_size_log2[1]=2'd0; pair_owner[1]=16'h7801;
    #1;
    if (!c_next_ready || pair_req_ready[1])
      $fatal(1,"uncommitted byte prime admitted V");
    c_next_commit=1;
    expect_pair(2'b10);
    @(posedge clk); @(negedge clk);
    c_next_req=0; c_next_commit=0; pair_req_valid=0;
    c_req=1; c_addr=32'h1001; c_wstrb=4'h1;
    #1;
    if (!c_ack || c_rdata[7:0]!==mem[32'h1001] ||
        pair_rsp_valid!==2'b10 || pair_rsp_owner[1]!==16'h7801 ||
        pair_rsp_data[1]!=={24'd0,mem[32'h1024]} || dut.window_valid_q)
      $fatal(1,"primed byte U/V ownership or data failure");
    @(posedge clk); @(negedge clk); c_req=0; c_wstrb=4'hf;
    c_next_wstrb=4'hf; pair_size_log2[1]=2'd2;

`endif

    legacy_read(32'h1024);
    @(negedge clk); c_next_req=1; c_next_commit=1;
    c_next_addr=32'h1000; pair_req_valid=2'b10;
    pair_paddr[1]=32'h1020;
    expect_pair(2'b00);
    if (!c_next_ready || !pair_bank_conflict)
      $fatal(1,"same-bank prime must leave U lookahead intact");
    @(posedge clk); @(negedge clk);
    c_next_req=0; c_next_commit=0; pair_req_valid=0;
    c_req=1; c_addr=32'h1000;
    #1;
    if (!c_ack || c_rdata!==word_at(32'h1000) || pair_rsp_valid!=0)
      $fatal(1,"same-bank prime disturbed U result");
    @(posedge clk); @(negedge clk); c_req=0;
`ifdef VEN_L1D_TWO_WINDOW_REUSE
    // A same-line prime must register its new owner without recapturing A
    // and evicting the independent hot B line from the shadow.
    legacy_write(32'h5000, 32'h5a5aa5a5);
    legacy_read(32'h1020);
    legacy_read(32'h1000);
    @(negedge clk); c_next_req=1; c_next_commit=1;
    c_next_addr=32'h1004;
    #1;
    if (!c_next_ready || !dut.mc_prime_window_reuse || dut.do_rd_cap)
      $fatal(1,"same-line prime reread the SRAM and lost the shadow");
    @(posedge clk); @(negedge clk);
    c_next_req=0; c_next_commit=0; c_req=1; c_addr=32'h1004;
    #1;
    if (!c_ack || c_rdata!==word_at(32'h1004) || !dut.shadow_valid_q)
      $fatal(1,"same-line prime lost its registered owner or shadow");
    @(posedge clk); @(negedge clk); c_addr=32'h1020;
    #1;
    if (!c_ack || !dut.shadow_reuse || c_rdata!==word_at(32'h1020))
      $fatal(1,"second resident line missed the preserved shadow");
    @(posedge clk); @(negedge clk); c_req=0;
`ifdef VEN_P54_DUAL_BYTE_LOAD_PAIR
    @(negedge clk); c_req=1; c_addr=32'h1024; c_wstrb=4'h1;
    pair_req_valid=2'b10; pair_paddr[1]=32'h1028;
    pair_size_log2[1]=2'd0; pair_owner[1]=16'h7803;
    pair_now_req=1; pair_now_paddr=32'h1028;
    #1;
    if (!dut.shadow_reuse || !c_ack || !pair_now_valid ||
        pair_now_data!=={24'd0,mem[32'h1028]} || pair_req_ready[1])
      $fatal(1,"shadow-window byte return failed");
    @(posedge clk); @(negedge clk); c_req=0; pair_req_valid=0;
    pair_now_req=0; c_wstrb=4'hf; pair_size_log2[1]=2'd2;
    if (pair_rsp_valid[1]) $fatal(1,"shadow byte return duplicated V");
`endif
`endif

    // A missing U tag or a simultaneous snoop cannot manufacture a V
    // response from an otherwise resident younger address.
    c_next_req=1; c_next_commit=1; c_next_addr=32'h3000;
    pair_req_valid=2'b10; pair_paddr[1]=32'h1024;
    #1;
    if (c_next_ready || pair_req_ready[1])
      $fatal(1,"missed prime admitted V");
    @(posedge clk); @(negedge clk);
    c_next_addr=32'h1000; snoop_inv_valid=1;
    #1;
    if (c_next_ready || pair_req_ready[1])
      $fatal(1,"snooped prime admitted V");
    @(posedge clk); @(negedge clk);
    c_next_req=0; c_next_commit=0; pair_req_valid=0; snoop_inv_valid=0;
    if (pair_rsp_valid!=0) $fatal(1,"rejected prime left a V owner");
`endif
`endif

    // A rejected request must neither touch the cache nor enqueue a response.
    // In particular 8-byte reads, uncached addresses and absent tags use the
    // existing checked slow path, not a truncated dword fast-path result.
    pair_req_valid=2'b01; pair_paddr[0]=32'h1000;
    pair_size_log2[0]=2'd3;
    expect_pair(2'b00);
    pair_size_log2[0]=2'd2; pair_cacheable[0]=0;
    expect_pair(2'b00);
    pair_cacheable[0]=1; pair_paddr[0]=32'h2000;
    expect_pair(2'b00);
    pair_req_valid=0;

    // Legacy write-through hit must update the same physical bank storage
    // subsequently read by the pair path, including an unaligned dword.
    legacy_write(32'h1001,32'h87654321);
    pair_req_valid=2'b01; pair_paddr[0]=32'h1001;
    pair_owner[0]=16'h4444;
    expect_pair(2'b01);
    @(posedge clk); @(negedge clk); pair_req_valid=0;
    if (!pair_rsp_valid[0] || pair_rsp_data[0]!==32'h87654321)
      $fatal(1,"pair read missed legacy store-hit update");
    @(posedge clk); @(negedge clk);

    // Two physical tags can occupy opposite ways of one indexed set. The
    // per-bank row mux must preserve each accepted lane's own way selection.
    legacy_read(32'h2004);
    pair_req_valid=2'b11; pair_paddr[0]=32'h1000;
    pair_paddr[1]=32'h2004;
    pair_owner='{16'h5556,16'h5555};
    expect_pair(2'b11);
    @(posedge clk); @(negedge clk); pair_req_valid=0;
    if (pair_rsp_data[0]!==word_at(32'h1000) ||
        pair_rsp_data[1]!==word_at(32'h2004))
      $fatal(1,"opposite-way pair response mismatch");
    @(posedge clk); @(negedge clk);

    // An external snoop in the same clock as a probe must suppress admission.
    pair_req_valid=2'b01; pair_paddr[0]=32'h1001;
    snoop_inv_valid=1; snoop_inv_addr=32'h1000;
    expect_pair(2'b00);
    @(posedge clk); @(negedge clk);
    pair_req_valid=0; snoop_inv_valid=0;
    if (pair_rsp_valid[0]) $fatal(1,"snoop admitted a stale pair owner");

    if (accepts<14 || responses<13 || cancels!=1)
      $fatal(1,"pair ownership coverage too low");
    $display("P54-L1D-PAIR-HIT-OK checks=%0d accepts=%0d responses=%0d cancels=%0d backing=%0d",
             checks,accepts,responses,cancels,backing);
    $finish;
  end
  initial begin #200000; $fatal(1,"global timeout"); end
endmodule
