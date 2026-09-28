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
  logic pair_bank_conflict;
  logic [7:0] dbg_serve;
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
      $fatal(1,"pair ready got=%b expected=%b",pair_req_ready,expected_ready);
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
