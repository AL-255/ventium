// Natural bus traffic only: no hierarchical writes, forced tags or saved state.
int tag_checks=0;

function automatic logic [19:0] tag_value(input int setno, input int way);
`ifdef VEN_L1D_TAG_LUTRAM
  return dut.dc_tag[{7'(setno),1'(way)}];
`else
  return dut.dc_tag[setno][way];
`endif
endfunction

task automatic tag_all_invalid;
  for(int setno=0;setno<128;setno++)
    for(int way=0;way<2;way++) begin
      if(dut.dc_val[setno][way]!==1'b0) $fatal(1,"tag validity survives reset/flush");
      tag_checks++;
    end
endtask

task automatic tag_cold_read(input logic [31:0] addr);
  int before_backing;
  before_backing=backing;
  read_at(addr);
  if(backing-before_backing!=8) $fatal(1,"invalid tag supplied a hit %08x",addr);
  tag_checks++;
endtask

task automatic run_tag_lutram;
  logic [19:0] retained[128][2];
  logic [31:0] base;
  int guard, saved_ticks, saved_backing, taglo, before_hits;
  saved_ticks=ticks; saved_backing=backing;
  @(negedge clk); rst_n=0; c_req=0; c_code=0; c_we=0; c_next_req=0; c_next_commit=0;
  repeat(3) @(negedge clk); rst_n=1;
  tag_all_invalid();
  // Every set, both ways. Non-zero different tags ensure warm reset cannot
  // accidentally pass because the retained RAM payload happened to be zero.
  for(int setno=0;setno<128;setno++) begin
    // Different tags per set detect dropped set-address bits: no power of
    // two is divisible by six. Every address remains inside the 64KiB oracle.
    taglo=1+2*(setno%6);
    tag_cold_read(32'((taglo<<12)+setno*32));
    tag_cold_read(32'(((taglo+1)<<12)+setno*32));
    for(int way=0;way<2;way++) begin
      if(!dut.dc_val[setno][way]) $fatal(1,"both ways not populated");
      retained[setno][way]=tag_value(setno,way);
      if(retained[setno][way]!=20'(taglo) && retained[setno][way]!=20'(taglo+1))
        $fatal(1,"wrong installed tag");
    end
    if(retained[setno][0]===retained[setno][1]) $fatal(1,"ways aliased");
  end
  // All 256 live entries must hit, not just look nonzero after installation.
  before_hits=backing;
  for(int setno=127;setno>=0;setno--) begin
    taglo=1+2*(setno%6);
    read_at(32'((taglo<<12)+setno*32));
    read_at(32'(((taglo+1)<<12)+setno*32));
    tag_checks+=2;
  end
  if(backing!=before_hits) $fatal(1,"resident tag lookup missed or aliased");
  @(negedge clk); rst_n=0;
  repeat(3) @(negedge clk); rst_n=1;
  tag_all_invalid();
  for(int setno=0;setno<128;setno++)
    for(int way=0;way<2;way++) begin
`ifdef VEN_L1D_TAG_LUTRAM
      if(tag_value(setno,way)!==retained[setno][way]) $fatal(1,"RAM tags were reset");
`else
      if(tag_value(setno,way)!==20'd0) $fatal(1,"default-off reset changed");
`endif
      tag_checks++;
    end
  // Mutate backing after reset; stale retained tags/data must never acknowledge.
  for(int addr='h1000;addr<'hd000;addr++) mem[addr]^=8'h57;
  for(int setno=127;setno>=0;setno--) begin
    taglo=1+2*(setno%6);
    tag_cold_read(32'(((taglo+1)<<12)+setno*32));
    tag_cold_read(32'((taglo<<12)+setno*32));
  end
  @(negedge clk); flush_all=1;
  @(negedge clk); flush_all=0;
  tag_all_invalid();
  for(int setno=0;setno<128;setno++)
    tag_cold_read(32'h3000+32'(setno*32));

  // Matching snoop/flush on every D-fill beat, including tag-write edge.
  // Request removal after poison forces the subsequent demand to prove refill.
  for(int kind=0;kind<2;kind++)
    for(int beat=0;beat<8;beat++) begin
      base=32'h8000+32'((kind*8+beat)*32);
      @(negedge clk); c_req=1; c_we=0; c_code=0; c_addr=base; c_wstrb=4'hf;
      guard=0;
      while(!(dut.st==dut.L1_FILL && dut.fw==3'(beat))) begin
        @(negedge clk); if(++guard>200) $fatal(1,"D-fill poison phase timeout");
      end
      // Select a real accepted beat edge, not merely a phase with no m_ack.
      while(!m_ack) @(negedge clk);
      if(kind==0) begin snoop_inv_valid=1; snoop_inv_addr=base; end
      else flush_all=1;
      #1; if(c_ack) $fatal(1,"poison-edge stale response");
      @(posedge clk);
      @(negedge clk); c_req=0; snoop_inv_valid=0; flush_all=0;
      while(dut.st!=dut.L1_IDLE) @(negedge clk);
      for(int b=0;b<32;b++) mem[base+32'(b)]^=8'h9b;
      tag_cold_read(base);
    end
  $display("TAG-LUTRAM-LEAF-OK checks=%0d ticks=%0d backing=%0d",tag_checks,
           ticks-saved_ticks,backing-saved_backing);
endtask
