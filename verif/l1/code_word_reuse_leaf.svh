// Included in the full-profile memory-chain leaf. No hierarchical DUT writes.
int code_word_checks=0, code_word_latency=0;

task automatic code_read(input logic [31:0] addr, input logic [3:0] strobes,
                         input bit drain_fill, input bit known_staged);
  int waits;
  @(negedge clk); c_req=1; c_we=0; c_code=1; c_addr=addr; c_wstrb=strobes;
  waits=0;
  do begin
    @(posedge clk);
    if (++waits>200) $fatal(1,"instruction word timeout %08x",addr);
  end while (!c_ack);
  if (c_rdata!==word_at(addr))
    $fatal(1,"instruction word ownership %08x got=%08x expected=%08x",addr,c_rdata,word_at(addr));
  if (known_staged) begin
`ifdef VEN_L1D_CODE_WORD_REUSE
    if (waits!=1) $fatal(1,"registered staging word took %0d clocks",waits);
`else
    if (waits!=2) $fatal(1,"control capture latency changed %0d",waits);
`endif
    code_word_latency+=waits;
  end
  code_word_checks++;
  @(negedge clk); c_req=0; c_code=0; c_wstrb=4'hf;
  if (drain_fill) while(dut.st!=dut.L1_IDLE) @(negedge clk);
endtask

task automatic code_word_guard(input int reason);
  #1;
`ifdef VEN_L1D_CODE_WORD_REUSE
  if (dut.code_word_reuse) $fatal(1,"unsafe code staging reuse reason=%0d",reason);
`endif
  code_word_checks++;
endtask

task automatic run_code_word_reuse;
  int old_backing, guard;
  logic [31:0] base;
  // Reset normally; retain the independent backing oracle, not a saved DUT.
  @(negedge clk); rst_n=0; c_req=0; c_code=0; c_next_req=0; c_next_commit=0;
  repeat(3) @(negedge clk); rst_n=1;
  code_read('h8000,4'h0,1,0);
  old_backing=backing;
  for(int wordno=0;wordno<8;wordno++)
    code_read(32'h8000+32'(wordno*4),wordno[0] ? 4'hf : 4'h0,1,1);
  if(backing!=old_backing) $fatal(1,"resident code reuse requested backing");

  // Physically retarget on every edge, with no idle gap or saved rd_addr owner.
  @(negedge clk); c_req=1; c_code=1; c_we=0; c_wstrb=0;
  for(int wordno=7;wordno>=0;wordno--) begin
    c_addr=32'h8000+32'(wordno*4);
    guard=0;
    do begin @(posedge clk); if(++guard>8) $fatal(1,"back-to-back code timeout"); end while(!c_ack);
    if(c_rdata!==word_at(c_addr)) $fatal(1,"retargeted code word is stale");
`ifdef VEN_L1D_CODE_WORD_REUSE
    if(guard!=1) $fatal(1,"back-to-back code bubble");
`endif
    code_word_checks++;
    @(negedge clk);
  end
  c_req=0; c_code=0; c_wstrb=4'hf;
  // Test between falling/rising edges, then withdraw the offer before it can
  // commit. Each unsafe shape must reject reuse, not disable the legacy path.
  @(negedge clk); c_req=1; c_code=1; c_addr='h8004; c_wstrb=0;
  c_we=1; code_word_guard(1); c_we=0; c_req=0;
  @(negedge clk); c_req=1; c_code=0; code_word_guard(2); c_code=1; c_req=0;
  @(negedge clk); c_req=1; cacheable=0; code_word_guard(3); cacheable=1; c_req=0;
  @(negedge clk); c_req=1; golden=1; code_word_guard(4); golden=0; c_req=0;
  @(negedge clk); c_req=1; flush_all=1; code_word_guard(5); flush_all=0; c_req=0;
  @(negedge clk); c_req=1; snoop_inv_valid=1; code_word_guard(6); snoop_inv_valid=0; c_req=0;
  @(negedge clk); c_req=1; c_addr='h8024; code_word_guard(7); c_addr='h8004; c_req=0;
  @(negedge clk); c_req=1; c_addr='h8005; code_word_guard(8); c_addr='h8004; c_req=0;
  @(negedge clk); c_req=1; c_wstrb=1; code_word_guard(9); c_wstrb=0; c_req=0;
  @(negedge clk); c_req=1; c_wstrb=3; code_word_guard(10); c_wstrb=0;
  c_req=0; code_word_guard(11); c_code=0; c_wstrb=4'hf;

  // Only arrived words from the current fill may be observed. Backing stays
  // held while a later arrived word is read, then an unarrived word is offered.
  code_read('h8100,0,0,0);
  guard=0;
  while(!dut.fill_word_valid[2]) begin
    @(negedge clk); if(++guard>100) $fatal(1,"code fill did not reach word 2");
  end
  hold_ack=1;
  old_backing=backing;
  code_read('h8104,0,0,1);
  if(backing!=old_backing) $fatal(1,"held fill advanced during reuse");
  @(negedge clk); c_req=1; c_code=1; c_addr='h811c; c_wstrb=0;
  repeat(3) begin
    @(posedge clk); if(c_ack) $fatal(1,"unarrived word acknowledged");
  end
  @(negedge clk); c_req=0; c_code=0; c_wstrb=4'hf; hold_ack=0;
  while(dut.st!=dut.L1_IDLE) @(negedge clk);
  code_word_checks++;

  // A completed I staging line is independent of a same-set D-array fill.
  read_at('h9100);
  // read_at drains; use another miss to retain the active fill below.
  @(negedge clk); c_req=1; c_we=0; c_code=0; c_addr='ha100; c_wstrb=4'hf;
  guard=0;
  do begin @(posedge clk); if(++guard>200) $fatal(1,"D critical timeout"); end while(!c_ack);
  @(negedge clk); c_req=0; hold_ack=1;
  code_read('h8108,0,0,1);
  if(dut.st!=dut.L1_FILL) $fatal(1,"I staging did not overlap D fill");
  hold_ack=0;
  while(dut.st!=dut.L1_IDLE) @(negedge clk);

  // On every fill-beat boundary, a matching physical mutation invalidates
  // the staging copy and poisons partial forwarding. No stale word may escape.
  for(int beat=0;beat<8;beat++) begin
    base=32'h8400+32'(beat*32);
    @(negedge clk); c_req=1; c_code=1; c_we=0; c_addr=base; c_wstrb=0;
    guard=0;
    while(!(dut.st==dut.L1_FILL && dut.fw==3'(beat))) begin
      @(negedge clk); if(++guard>200) $fatal(1,"poison boundary timeout");
    end
    snoop_inv_valid=1; snoop_inv_addr=base;
    for(int b=0;b<32;b++) mem[base+32'(b)]=mem[base+32'(b)]^8'hb3;
    #1; if(c_ack) $fatal(1,"snoop-edge code response leaked");
    @(posedge clk);
    @(negedge clk); snoop_inv_valid=0; c_req=0; c_code=0; c_wstrb=4'hf;
    while(dut.st!=dut.L1_IDLE) @(negedge clk);
    if(dut.code_valid_q) $fatal(1,"poisoned staging line installed");
    old_backing=backing;
    code_read(base,0,1,0);
    if(backing-old_backing!=8) $fatal(1,"poisoned line not refilled");
    code_read(base+4,4'hf,1,1);
  end
  // Same-edge flush wins over a fully registered staging response too.
  @(negedge clk); c_req=1; c_code=1; c_addr=base+4; c_wstrb=0; flush_all=1;
  #1; if(c_ack) $fatal(1,"flush-edge code response leaked");
  @(posedge clk);
  @(negedge clk); c_req=0; c_code=0; flush_all=0; c_wstrb=4'hf;
  if(dut.code_valid_q) $fatal(1,"flush retained code staging validity");
  code_read(base+4,0,1,0);
  // Normal reset must also remove the staging owner.
  @(negedge clk); rst_n=0;
  repeat(3) @(negedge clk); rst_n=1;
  if(dut.code_valid_q) $fatal(1,"reset retained code staging validity");
  code_word_checks+=2;
  $display("CODE-WORD-REUSE-LEAF-OK checks=%0d staged_latency=%0d",code_word_checks,code_word_latency);
endtask
