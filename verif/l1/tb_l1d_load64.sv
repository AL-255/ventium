`timescale 1ns/1ps
// Response-width contract: extra bytes come only from an owned COMPLETE
// registered resident line, never from a second array or a widened MMIO beat.
module tb_l1d_load64;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  logic flush_all=0, golden=0, cacheable=1, snoop_inv_valid=0;
  logic [31:0] snoop_inv_addr=0;
  logic c_req=0, c_we=0, c_ack, c_rdata_hi_valid;
  logic [31:0] c_addr=0, c_wdata=0, c_rdata, c_rdata_hi;
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
  int ticks=0, reads=0, wide_reads=0, narrow_bytes=0;
  function automatic logic [31:0] word_at(input logic [31:0] addr);
    return {mem[addr+3],mem[addr+2],mem[addr+1],mem[addr]};
  endfunction
  // Narrow backing results are on their physical byte lanes, like AXI.
  assign m_rdata=word_at(m_rd_narrow ? (m_addr & 32'hfffffffc) : m_addr);
  assign m_ack=m_req && ((ticks%3)==0);
  always @(posedge clk) begin
    ticks<=ticks+1;
    if(m_req && m_ack) begin
      if(m_we) begin
        for(int b=0;b<4;b++) if(m_wstrb[b]) mem[m_addr+b]=m_wdata[b*8 +: 8];
      end else if(m_rd_narrow) narrow_bytes+=1<<m_rd_size;
    end
    if(rst_n && c_req && !c_we && c_ack) begin
      for(int b=0;b<4;b++)
        if(c_wstrb[b] && c_rdata[b*8 +: 8]!==mem[c_addr+b])
          $fatal(1,"wrong low word addr=%08x data=%08x",c_addr,c_rdata);
      reads++;
      if(c_rdata_hi_valid) begin
        if(!cacheable || golden || c_addr[4:0]>24 || m_rd_narrow ||
           c_rdata_hi!==word_at(c_addr+4))
          $fatal(1,"wrong/unowned high word addr=%08x data=%08x",c_addr,c_rdata_hi);
        wide_reads++;
      end
    end
    if(c_rdata_hi_valid && (!c_ack || !rst_n || flush_all || snoop_inv_valid))
      $fatal(1,"wide response survived cancellation");
  end
  task automatic read_at(input logic [31:0] addr, input int expected_wide);
    int guard;
    @(negedge clk); c_req=1; c_we=0; c_addr=addr;
    guard=0;
    do begin
      @(posedge clk);
      if(++guard>300) $fatal(1,"read timeout at %08x",addr);
    end while(!c_ack);
    if(expected_wide>=0 && c_rdata_hi_valid!==1'(expected_wide))
      $fatal(1,"wrong width at %08x expected=%0d got=%0b st=%0d",addr,expected_wide,c_rdata_hi_valid,dut.st);
    @(negedge clk); c_req=0;
  endtask
  task automatic drain();
    while(dut.st!=0) @(negedge clk);
  endtask
  task automatic warm();
    read_at('h1000,-1); drain(); read_at('h1000,1);
  endtask
  initial begin
    int before_bytes;
    for(int i=0;i<65536;i++) mem[i]=8'(i^(i>>8));
    repeat(3) @(negedge clk);
    rst_n=1;
    read_at('h1000,0); // critical-word response is NOT a complete line
    drain(); read_at('h1000,1);
    read_at('h1020,0); drain(); read_at('h1020,1);
`ifdef VEN_L1D_TWO_WINDOW_REUSE
    @(negedge clk); c_req=1; c_we=1; c_addr='h5000; c_wdata='h12345678;
    do @(posedge clk); while(!c_ack);
    @(negedge clk); c_req=0; c_we=0;
    read_at('h1000,1);
    read_at('h1020,1);
    @(negedge clk); c_req=1; c_addr='h1004;
    #1;
    if(!dut.shadow_reuse || !c_ack || !c_rdata_hi_valid ||
       c_rdata_hi!==word_at('h1008))
      $fatal(1,"shadow lost complete eight-byte response");
    @(posedge clk); @(negedge clk); c_req=0;
`endif
    // All within-line offsets, including exactly-eight-bytes-left and each
    // crossing shape. Retargeting may reuse only a complete captured line.
    for(int offset=0;offset<32;offset++) read_at(32'h1000+32'(offset),offset<=24 ? 1 : 0);
    read_at('h2000,0); drain(); read_at('h2000,1);
    warm();
    // New address must never inherit the old response's high bytes.
    @(negedge clk); c_req=1; c_addr='h1000;
    @(posedge clk); if(!c_rdata_hi_valid) $fatal(1,"warm source not wide");
    @(negedge clk); c_addr='h4000;
    #1; if(c_rdata_hi_valid) $fatal(1,"retarget stole old window");
    @(negedge clk); c_req=0;
    // Invalidation on a response edge cancels both halves, then backing wins.
    warm();
    @(negedge clk); c_req=1; c_addr='h1000; snoop_inv_valid=1;
    snoop_inv_addr='h1000; mem['h1004]=8'ha5;
    @(posedge clk); if(c_ack || c_rdata_hi_valid) $fatal(1,"snoop-edge response");
    @(negedge clk); c_req=0; snoop_inv_valid=0;
    warm();
    @(negedge clk); c_req=1; c_addr='h1000; flush_all=1;
    @(posedge clk); if(c_ack || c_rdata_hi_valid) $fatal(1,"flush-edge response");
    @(negedge clk); c_req=0; flush_all=0;
    warm();
    // Changing cacheability must neither return resident high bytes nor widen
    // any bus read. Check exact byte count for all dword alignments and m16.
    @(negedge clk); cacheable=0;
    for(int offset=0;offset<4;offset++) begin
      before_bytes=narrow_bytes;
      read_at(32'h1000+32'(offset),0); drain();
      if(narrow_bytes-before_bytes!=4) $fatal(1,"MMIO dword amplification");
    end
    @(negedge clk); c_wstrb=4'h3;
    before_bytes=narrow_bytes; read_at('h1003,0); drain();
    if(narrow_bytes-before_bytes!=2) $fatal(1,"MMIO word amplification");
    @(negedge clk); c_wstrb=4'hf; cacheable=1;
    warm();
    // A hit store invalidates provenance even though the cached line updates.
    @(negedge clk); c_req=1; c_we=1; c_addr='h1004; c_wdata='h89abcdef;
    do @(posedge clk); while(!c_ack);
    @(negedge clk); c_req=0; c_we=0;
    read_at('h1000,1);
    // Cold fill and already-landed-word forwarding cannot claim unknown high
    // bytes from an incomplete saved window (even if the tag becomes valid).
    read_at('h3000,0);
    read_at('h3004,0); drain(); read_at('h3004,1);
    @(negedge clk); golden=1;
    read_at('h1000,0); drain();
    @(negedge clk); golden=0; rst_n=0; c_req=1; c_addr='h1000;
    #1; if(c_rdata_hi_valid) $fatal(1,"reset leaked response");
    @(negedge clk); c_req=0; rst_n=1;
    read_at('h1000,0); drain(); read_at('h1000,1);
    if(wide_reads<25) $fatal(1,"missing positive wide-response witnesses");
    $display("L1D-LOAD64-OK reads=%0d wide=%0d narrow-bytes=%0d",reads,wide_reads,narrow_bytes);
    $finish;
  end
  initial begin #1000000; $fatal(1,"watchdog"); end
endmodule
