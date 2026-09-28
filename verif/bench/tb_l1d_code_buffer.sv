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
`ifdef VEN_P54_DUAL_STORE_PAIR
  logic c_pair_req=0, c_pair_ready, c_pair_ack;
  logic [31:0] c_pair_addr=0, c_pair_wdata=0;
  logic [3:0] c_pair_wstrb=4'hf;
  logic m_pair_req, m_pair_ready, m_pair_ack;
  logic [31:0] m_pair_addr, m_pair_wdata;
  logic [3:0] m_pair_wstrb;
  assign m_pair_ready=1'b1;
  assign m_pair_ack=m_pair_req;
`endif
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
`ifdef VEN_P54_DUAL_STORE_PAIR
  always @(posedge clk) if (rst_n && m_pair_req && m_pair_ack) begin
    backing++;
    for (int b=0;b<4;b++)
      if (m_pair_wstrb[b]) mem[m_pair_addr+b]=m_pair_wdata[8*b +: 8];
  end
`endif

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

`ifdef VEN_P54_DUAL_STORE_PAIR
  task automatic paired_write(input logic [31:0] uaddr, vaddr);
    @(negedge clk); c_addr=uaddr; c_wdata=32'h10203040;
    c_we=1; c_req=1; c_wstrb=4'hf;
    c_pair_addr=vaddr; c_pair_wdata=32'h50607080;
    c_pair_wstrb=4'hf; c_pair_req=1;
    #1;
    if (!c_pair_ready || !c_ack || !c_pair_ack)
      $fatal(1,"paired store not accepted U=%08x V=%08x",uaddr,vaddr);
    @(posedge clk);
    @(negedge clk); c_req=0; c_we=0; c_pair_req=0;
    repeat(2) @(negedge clk);
  endtask
`endif

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

    // The next D miss occupies the SAME set as the staged code line. Its
    // critical word retires first; the following code read must be captured
    // from the private I staging buffer before the D fill has drained when
    // hit-under-fill is enabled. The control waits for the fill to finish.
    // A same-set D-array read would need separate replacement arbitration.
    before_code=backing;
    @(negedge clk); c_addr=32'h4000; c_code=0; c_we=0; c_req=1; c_wstrb=4'hf;
    begin
      int guard;
      guard=0;
      do begin
        @(posedge clk);
        if (++guard>100) $fatal(1,"data critical word timeout");
      end while (!c_ack);
      if (c_rdata!==word_at(32'h4000)) $fatal(1,"data critical word mismatch");
      @(negedge clk); c_addr=32'h3004; c_code=1; c_wstrb=4'h0;
      guard=0;
      do begin
        @(posedge clk);
        if (++guard>100) $fatal(1,"code hit-under-fill timeout");
      end while (!c_ack);
      if (c_rdata!==word_at(32'h3004)) $fatal(1,"code hit-under-fill mismatch");
      $display("P54-L1D-CODE-D-FILL code_wait_clocks=%0d fill_active_at_ack=%0b",
               guard,dut.st==dut.L1_FILL);
`ifdef VEN_L1D_HIT_UNDER_FILL
      if (dut.st!=dut.L1_FILL)
        $fatal(1,"same-set code hit waited for the data fill to drain");
`endif
    end
    @(negedge clk); c_req=0; c_code=0; c_wstrb=4'hf;
    while (dut.st!=dut.L1_IDLE) @(negedge clk);
    if (backing-before_code!=8)
      $fatal(1,"code hit under D fill issued backing traffic");
    if (!dut.code_valid_q)
      $fatal(1,"D fill discarded independent I staging line");

`ifdef VEN_L1D_HIT_UNDER_FILL
    // Cancel an already captured I response on its serve edge when DMA writes
    // that physical code line. The D fill is still active and must not make the
    // stale registered window visible one clock later.
    @(negedge clk); c_addr=32'h5000; c_code=0; c_we=0; c_req=1; c_wstrb=4'hf;
    begin
      int guard;
      guard=0;
      do begin
        @(posedge clk);
        if (++guard>100) $fatal(1,"second data critical word timeout");
      end while (!c_ack);
      @(negedge clk); c_addr=32'h3004; c_code=1; c_wstrb=4'h0;
      @(posedge clk); // capture the old code word
      @(negedge clk);
      mem[32'h3004]=8'h12; mem[32'h3005]=8'h34;
      mem[32'h3006]=8'h56; mem[32'h3007]=8'h78;
      snoop_inv_addr=32'h3004; snoop_inv_valid=1;
      #1;
      if (c_ack) $fatal(1,"snoop did not cancel captured I response");
      @(posedge clk);
      @(negedge clk); snoop_inv_valid=0;
      guard=0;
      do begin
        @(posedge clk);
        if (++guard>100) $fatal(1,"post-snoop I refill timeout");
      end while (!c_ack);
      if (c_rdata!==word_at(32'h3004))
        $fatal(1,"post-snoop I refill returned stale data");
    end
    @(negedge clk); c_req=0; c_code=0; c_wstrb=4'hf;
    while (dut.st!=dut.L1_IDLE) @(negedge clk);
`endif

`ifdef VEN_L1D_CODE_TAG_INVALIDATE
    write_word(32'h4000,32'hdeadbeef);
    if (!dut.code_valid_q)
      $fatal(1,"unrelated U store discarded I staging line");
    before_code=backing;
    read_word(32'h3004,1);
    if (backing!=before_code)
      $fatal(1,"unrelated U store caused a code refill");
    @(negedge clk); snoop_inv_valid=1; snoop_inv_addr=32'h5000;
    @(negedge clk); snoop_inv_valid=0;
    if (!dut.code_valid_q)
      $fatal(1,"unrelated physical snoop discarded I staging line");
    before_code=backing;
    read_word(32'h3004,1);
    if (backing!=before_code)
      $fatal(1,"unrelated physical snoop caused a code refill");

    // The first byte of this U store is in 0x2fe0; the last reaches 0x3000.
    write_word(32'h2ffd,32'h12345678);
    if (dut.code_valid_q)
      $fatal(1,"crossing U store left changed I line valid");
    read_word(32'h3000,1);
`ifdef VEN_P54_DUAL_STORE_PAIR
    paired_write(32'h4000,32'h5004);
    if (!dut.code_valid_q)
      $fatal(1,"unrelated paired stores discarded I staging line");
    before_code=backing;
    read_word(32'h3004,1);
    if (backing!=before_code)
      $fatal(1,"unrelated paired stores caused a code refill");
    paired_write(32'h4000,32'h3004);
    if (dut.code_valid_q)
      $fatal(1,"paired V store left changed I line valid");
    read_word(32'h3004,1);
`ifdef VEN_P54_LOAD_STORE_PAIR
    // U consumes an already registered data hit while V writes the staged
    // instruction line. Its write is one backing request, not a second pair
    // request, and the copied code bytes must be invalidated on acceptance.
    read_word(32'h1000,0);
    read_word(32'h3004,1);
    @(negedge clk); c_addr=32'h1000; c_code=0; c_we=0;
    c_req=1; c_wstrb=4'hf; c_pair_req=0;
    @(posedge clk);
    @(negedge clk); c_pair_addr=32'h3004;
    c_pair_wdata=32'ha1b2c3d4; c_pair_wstrb=4'hf; c_pair_req=1;
    #1;
    if (!c_pair_ready || !c_ack || !c_pair_ack || !m_req || !m_we || m_pair_req)
      $fatal(1,"load/store code mutation was not accepted as one V write");
    @(posedge clk);
    @(negedge clk); c_req=0; c_pair_req=0;
    if (dut.code_valid_q)
      $fatal(1,"load/store V write left stale code staging valid");
    read_word(32'h3004,1);
    if (word_at(32'h3004) != 32'ha1b2c3d4)
      $fatal(1,"load/store V write did not reach backing code bytes");
`endif
`endif
`endif

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
`ifdef VEN_L1D_CODE_STREAM
    // A later word of a code line can be returned while the backing burst is
    // still in progress. Without streaming it waits until the whole line
    // validates; the ACK must still be owned by the current word address.
    @(negedge clk); c_addr=32'h6000; c_code=1; c_we=0; c_req=1; c_wstrb=4'h0;
    begin
      int guard;
      guard=0;
      do begin
        @(posedge clk);
        if (++guard>100) $fatal(1,"stream first word timeout");
      end while (!c_ack);
      if (c_rdata!==word_at(32'h6000)) $fatal(1,"stream first word mismatch");
      @(negedge clk);
      #1;
      if (c_ack) $fatal(1,"held critical word was acknowledged twice");
      @(posedge clk);
      if (c_ack) $fatal(1,"held critical word was acknowledged twice");
      @(negedge clk); c_addr=32'h6004;
      guard=0;
      do begin
        @(posedge clk);
        if (++guard>100) $fatal(1,"stream second word timeout");
      end while (!c_ack);
      if (c_rdata!==word_at(32'h6004)) $fatal(1,"stream second word mismatch");
      if (dut.st!=dut.L1_FILL)
        $fatal(1,"stream second word did not overlap the remaining fill");
    end
    @(negedge clk); c_req=0; c_code=0; c_wstrb=4'hf;
    while (dut.st!=dut.L1_IDLE) @(negedge clk);
    before_code=backing;
    read_word(32'h6008,1);
    if (backing!=before_code) $fatal(1,"streaming line failed to validate");
`endif

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
