`timescale 1ns/1ps
module tb_l1d_code_buffer;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  logic flush_all=0, golden=0, cacheable=1, snoop_inv_valid=0;
  logic [31:0] snoop_inv_addr=0;
  logic c_req=0, c_we=0, c_code=0, c_ack;
  logic [31:0] c_addr=0, c_wdata=0, c_rdata;
  logic [3:0] c_wstrb=4'hf;
  logic [7:0] dbg_serve;
  logic m_req, m_we, m_ack, m_rd_narrow;
  logic [31:0] m_addr, m_wdata, m_rdata;
  logic [3:0] m_wstrb;
  logic [1:0] m_rd_size;
  byte unsigned mem[65536];
  int backing=0;
  ven_l1d dut(.*);

  function automatic logic [31:0] word_at(input logic [31:0] addr);
    return {mem[addr+3],mem[addr+2],mem[addr+1],mem[addr]};
  endfunction
  assign m_rdata=word_at(m_addr);
  assign m_ack=m_req;
  always @(posedge clk) if (rst_n && m_req && m_ack) begin
    backing++;
    if (m_we)
      for (int b=0;b<4;b++)
        if (m_wstrb[b]) mem[m_addr+b]=m_wdata[8*b +: 8];
  end

  task automatic read_word(input logic [31:0] addr, input bit is_code);
    int guard;
    @(negedge clk); c_addr=addr; c_code=is_code; c_we=0; c_req=1;
    c_wstrb=is_code ? 4'h0 : 4'hf;
    guard=0;
    do begin
      @(posedge clk);
      if (++guard>100) $fatal(1,"read timeout addr=%08x code=%0b",addr,is_code);
    end while (!c_ack);
    if (c_rdata!==word_at(addr))
      $fatal(1,"read mismatch addr=%08x code=%0b got=%08x expected=%08x",
             addr,is_code,c_rdata,word_at(addr));
    @(negedge clk); c_req=0; c_code=0; c_wstrb=4'hf;
    while (dut.st!=0) @(negedge clk);
    repeat(2) @(negedge clk);
  endtask

  task automatic write_word(input logic [31:0] addr,
                            input logic [31:0] data);
    int guard;
    @(negedge clk); c_addr=addr; c_wdata=data; c_we=1; c_req=1;
    guard=0;
    do begin
      @(posedge clk);
      if (++guard>100) $fatal(1,"write timeout addr=%08x",addr);
    end while (!c_ack);
    @(negedge clk); c_req=0; c_we=0;
    repeat(2) @(negedge clk);
  endtask

  task automatic poison_code_fill(input logic [31:0] addr,
                                  input logic [2:0] beat);
    int before_fill;
    @(negedge clk); c_addr=addr; c_code=1; c_we=0; c_req=1; c_wstrb=4'h0;
    do @(negedge clk); while (dut.st!=dut.L1_FILL || dut.fw!=beat);
    snoop_inv_addr=addr; snoop_inv_valid=1;
    @(negedge clk); snoop_inv_valid=0; c_req=0; c_code=0; c_wstrb=4'hf;
    while (dut.st!=dut.L1_IDLE) @(negedge clk);
    if (dut.code_valid_q) $fatal(1,"snoop at beat %0d validated poisoned I fill",beat);
    before_fill=backing;
    read_word(addr,1);
    if (backing-before_fill!=8)
      $fatal(1,"snoop at beat %0d did not cause a fresh I fill",beat);
  endtask

  initial begin
    int before_code, after_code;
    for (int i=0;i<65536;i++) mem[i]=8'(i ^ (i>>8) ^ 8'h5a);
    repeat(3) @(negedge clk); rst_n=1;
    // These three lines have the same set index; the first two consume both
    // data ways, and the third belongs only in the I-fill staging buffer.
    read_word(32'h1000,0);
    read_word(32'h2000,0);
    before_code=backing;
    read_word(32'h3000,1);
    after_code=backing;
    if (after_code-before_code!=8 || !dut.code_valid_q)
      $fatal(1,"code fill did not stage exactly one line");
    read_word(32'h3004,1);
    read_word(32'h1000,0);
    read_word(32'h2000,0);
    if (backing!=after_code)
      $fatal(1,"code fill evicted a resident data line or missed its staging hit");

    // A CPU store must kill the staged copy even when the code line was never
    // allocated in D-cache. A subsequent I read must see the new backing data.
    write_word(32'h3000,32'h12345678);
    if (dut.code_valid_q) $fatal(1,"store left stale code staging valid");
    read_word(32'h3000,1);
    if (backing<after_code+9) $fatal(1,"post-store code did not refill");

    mem[32'h3000]=8'haa;
    @(negedge clk); snoop_inv_valid=1; snoop_inv_addr=32'h3000;
    @(negedge clk); snoop_inv_valid=0;
    if (dut.code_valid_q) $fatal(1,"snoop left stale code staging valid");
    read_word(32'h3000,1);
    @(negedge clk); flush_all=1;
    @(negedge clk); flush_all=0;
    if (dut.code_valid_q) $fatal(1,"flush left stale code staging valid");
    read_word(32'h3000,1);
    golden=1;
    read_word(32'h3000,1);
    if (dut.code_valid_q) $fatal(1,"golden mode retained I staging line");
    golden=0; cacheable=0;
    read_word(32'h3000,1);
    if (dut.code_valid_q) $fatal(1,"uncacheable I read retained staging line");
    cacheable=1;

    // Both mid-fill and terminal-beat snoops must poison the staged line.
    // The terminal case exercises same-edge allocation/invalidation ordering.
    poison_code_fill(32'h4000,3'd3);
    poison_code_fill(32'h5000,3'd7);

    // An armed D response at the identical physical address cannot satisfy a
    // retargeted I request. Address-only ownership would acknowledge stale
    // rd_window_q or early_rdata_q and skip the separate I fill entirely.
    read_word(32'h1000,0);
    read_word(32'h2000,0); // make the captured D window belong to another line
    before_code=backing;
    @(negedge clk); c_addr=32'h1000; c_req=1; c_we=0; c_code=0;
    @(posedge clk); @(negedge clk); c_code=1; c_wstrb=4'h0;
    #1;
    if (c_ack) $fatal(1,"D response mislabeled as I response");
    begin
      int guard;
      guard=0;
      do begin
        @(posedge clk);
        if (++guard>100) $fatal(1,"retargeted I read timed out");
      end while (!c_ack);
      if (c_rdata!==word_at(32'h1000))
        $fatal(1,"retargeted I read wrong got=%08x expected=%08x st=%0d early=%0b rd_match=%0b code_hit=%0b fbase=%08x m_addr=%08x early_addr=%08x",
               c_rdata,word_at(32'h1000),dut.st,dut.early_match,
               dut.rd_match,dut.code_hit,dut.fbase,m_addr,dut.early_addr_q);
    end
    @(negedge clk); c_req=0; c_code=0; c_wstrb=4'hf;
    while (dut.st!=0) @(negedge clk);
    if (backing-before_code!=8)
      $fatal(1,"retargeted I read did not refill separately");
    $display("P54-L1D-CODE-BUFFER-OK backing=%0d",backing);
    $finish;
  end
  initial begin #300000; $fatal(1,"global timeout"); end
endmodule
