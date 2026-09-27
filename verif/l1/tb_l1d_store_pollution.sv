// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Default: characterize the existing policy without changing its expectations.
// TAG_POLICY=1: require zero unrelated eviction plus directed coherence checks.
`timescale 1ns/1ps
module tb_l1d_store_pollution #(parameter bit TAG_POLICY=0);
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
  logic stall_store=0;
  ven_l1d dut(
`ifdef VEN_PIPE_MEM_CHAIN
      .c_next_req(1'b0), .c_next_commit(1'b0), .c_next_cacheable(1'b0),
      .c_next_addr(32'd0), .c_next_wstrb(4'd0), .c_next_ready(),
`endif
.*);
  byte unsigned mem[65536];
  int read_beats=0, write_beats=0;
  function automatic logic [31:0] word_at(input logic [31:0] a);
    return {mem[a+3],mem[a+2],mem[a+1],mem[a]};
  endfunction
  assign m_rdata=word_at(m_addr);
  assign m_ack=m_req && !(m_we && stall_store);
  always @(posedge clk) begin
    if(m_req && m_ack) begin
      if(m_we) begin
        write_beats++;
        for(int b=0;b<4;b++) if(m_wstrb[b]) mem[m_addr+b]=m_wdata[b*8 +: 8];
      end else read_beats++;
    end
    if(rst_n && c_req && !c_we && c_ack && c_rdata!==word_at(c_addr))
      $fatal(1,"stale data at %08x",c_addr);
  end
  task automatic read_at(input logic [31:0] addr);
    int guard;
    @(negedge clk); c_req=1; c_we=0; c_addr=addr;
    guard=0;
    do begin
      @(posedge clk);
      if(++guard>100) $fatal(1,"read timeout");
    end while(!c_ack);
    @(negedge clk); c_req=0;
    while(dut.st!=0) @(negedge clk);
  endtask
  task automatic measure(input string label, input logic [31:0] store_addr,
                         input bit nc, input int expected_refills);
    int before_reads, before_writes;
    @(negedge clk); rst_n=0; c_req=0; cacheable=1;
    repeat(3) @(negedge clk);
    rst_n=1;
    // Full P5 geometry: two different tags, same set, both ways occupied.
    read_at('h1000); read_at('h2000);
    before_reads=read_beats;
    read_at('h1000); read_at('h2000);
    if(read_beats!=before_reads) $fatal(1,"warm control not resident");
    before_writes=write_beats;
    @(negedge clk);
    cacheable=!nc; c_req=1; c_we=1; c_addr=store_addr;
    c_wdata='h89abcdef; stall_store=1;
    repeat(4) begin
      @(posedge clk);
      if(c_ack) $fatal(1,"store ack escaped backpressure");
    end
    @(negedge clk); stall_store=0;
    @(posedge clk); if(!c_ack) $fatal(1,"store not accepted");
    @(negedge clk); c_req=0; c_we=0; cacheable=1;
    if(write_beats!=before_writes+1 || word_at(store_addr)!=='h89abcdef)
      $fatal(1,"write-through ownership/data mismatch");
    read_at('h1000); read_at('h2000);
    $display("STORE-POLLUTION %s refill_read_beats=%0d",label,read_beats-before_reads);
    // The baseline runner retains its original counts; the separate tag-policy
    // runner passes TAG_POLICY=1 and additionally runs the coherence cases.
    if(read_beats-before_reads!=expected_refills)
      $fatal(1,"baseline policy changed: inspect and remeasure");
  endtask
  task automatic accepted_store(input logic [31:0] addr, input logic [3:0] mask);
    @(negedge clk); c_req=1; c_we=1; c_addr=addr; c_wstrb=mask;
    c_wdata=32'hd42ba651;
    @(posedge clk); if(!c_ack) $fatal(1,"direct store unexpectedly blocked");
    @(negedge clk); c_req=0; c_we=0; c_wstrb=4'hf;
  endtask
  task automatic tag_cases;
    int before_reads, before_writes;
    logic [255:0] old_line;
    logic way;
    // Every byte position and nonempty byte mask, including line crossing.
    // Readback is checked against byte-accurate backing, not against DUT tags.
    for(int offset=0;offset<32;offset++) begin
      for(int mask=1;mask<16;mask++) begin
        read_at(32'h4000); read_at(32'h4020);
        read_at(32'h5000); read_at(32'h5020);
        accepted_store(32'h4000+32'(offset),4'(mask));
        before_reads=read_beats;
        read_at(32'h5000); read_at(32'h5020);
        if(read_beats!=before_reads) $fatal(1,"unrelated crossing-store victim");
        read_at(32'h4000+32'(offset));
      end
    end
    // A cancelled, unaccepted store must change neither backing nor cached data.
    read_at('h6000);
    @(negedge clk); c_addr='h6000;
    #1; way=dut.hit_way; old_line=dut.dc_line[{7'd0,way}];
    before_writes=write_beats;
    c_req=1; c_we=1; c_wdata=32'hffffffff; stall_store=1;
    repeat(4) begin
      @(posedge clk);
      if(c_ack) $fatal(1,"cancel test accepted blocked store");
      @(negedge clk);
      if(dut.dc_line[{7'd0,way}]!==old_line) $fatal(1,"unaccepted store mutated cache");
    end
    c_req=0; c_we=0; stall_store=0;
    if(write_beats!=before_writes) $fatal(1,"cancelled store reached backing");
    read_at('h6000);
    // Same-cycle snoop wins over accepted local store update; the refilled
    // value must come from backing, not from the invalidated registered window.
    @(negedge clk);
    snoop_inv_valid=1; snoop_inv_addr='h6000;
    c_req=1; c_we=1; c_addr='h6000; c_wstrb=4'hf; c_wdata=32'hd42ba651;
    @(posedge clk);
    if(!c_ack || !dut.hit) $fatal(1,"snoop/store test missed simultaneous resident hit");
    @(negedge clk); c_req=0; c_we=0; snoop_inv_valid=0;
    before_reads=read_beats; read_at('h6000);
    if(read_beats!=before_reads+8) $fatal(1,"snoop did not invalidate stored line");
  endtask
  initial begin
    for(int i=0;i<65536;i++) mem[i]=8'(i^(i>>8));
    measure("store-hit-other-way",'h1004,0,TAG_POLICY ? 0 : 8);
    measure("store-miss-same-set",'h3000,0,TAG_POLICY ? 0 : 16);
    measure("uncached-store-same-set",'h3000,1,TAG_POLICY ? 0 : 16);
    if(TAG_POLICY) begin
      tag_cases();
      $display("L1D-TAG-POLICY-OK (zero pollution, masked stores, crossing, cancellation, snoop)");
    end else $display("STORE-POLLUTION-BASELINE-OK (characterization, not optimized hardware acceptance)");
    $finish;
  end
  initial begin #1000000; $fatal(1,"watchdog"); end
endmodule
