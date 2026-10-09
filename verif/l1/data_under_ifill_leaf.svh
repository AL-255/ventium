// Bus stimulus only; no forced cache contents or internal-state writes.
int ifill_checks=0, ifill_held_completions=0;

task automatic ifill_setup(input int beat, input bit instruction_fill=1);
  int guard;
  @(negedge clk);
  rst_n=0; c_req=0; c_we=0; c_code=0; hold_ack=0;
  c_next_req=0; c_next_commit=0; cacheable=1; golden=0;
  flush_all=0; snoop_inv_valid=0;
  repeat(3) @(negedge clk); rst_n=1;
  // Both a same-set and different-set D line, with deliberately different
  // backing contents. I fills must not evict or overwrite either one.
  read_at('h1000); read_at('h1020);
  @(negedge clk); c_req=1; c_code=instruction_fill;
  c_addr='h9000; c_wstrb=instruction_fill ? 4'h0 : 4'hf;
  guard=0;
  while(!(dut.st==dut.L1_FILL && dut.fw==3'(beat))) begin
    @(negedge clk); if(++guard>200) $fatal(1,"I-fill phase timeout");
  end
  hold_ack=1; c_req=0; c_code=0; c_wstrb=4'hf;
  // Release the critical-response owner before testing independent reads.
  @(negedge clk);
  if(dut.st!=dut.L1_FILL || dut.early_armed || dut.rd_armed || !m_req || m_we)
    $fatal(1,"held fill does not own the backing port");
endtask

task automatic ifill_resident_read(input logic [31:0] addr, input bit narrow);
  int prior_backing, guard;
  logic [31:0] prior_addr;
  prior_backing=backing; prior_addr=m_addr;
  c_req=1; c_code=0; c_we=0; c_addr=addr; c_wstrb=narrow ? 4'h1 : 4'hf;
  @(posedge clk);
  if(c_ack) $fatal(1,"D response bypassed its register");
  @(negedge clk);
  @(posedge clk);
`ifdef VEN_L1D_DATA_UNDER_IFILL
  if(!c_ack || !dut.rd_match) $fatal(1,"resident D read blocked by I fill");
  if((narrow && c_rdata[7:0]!==mem[addr]) || (!narrow && c_rdata!==word_at(addr)))
    $fatal(1,"I-fill overlap returned another owner's bytes");
  ifill_held_completions++;
`else
  if(c_ack) $fatal(1,"control unexpectedly overlaps I-fill/D-hit");
`endif
  if(backing!=prior_backing || m_addr!=prior_addr || !m_req || m_we)
    $fatal(1,"D hit replaced or advanced the frozen I fill");
  @(negedge clk);
`ifdef VEN_L1D_DATA_UNDER_IFILL
  c_req=0;
`endif
  hold_ack=0;
`ifndef VEN_L1D_DATA_UNDER_IFILL
  guard=0;
  do begin @(posedge clk); if(++guard>200) $fatal(1,"control drain timeout"); end while(!c_ack);
  if((narrow && c_rdata[7:0]!==mem[addr]) || (!narrow && c_rdata!==word_at(addr)))
    $fatal(1,"control read data mismatch");
  @(negedge clk); c_req=0;
`endif
  while(dut.st!=dut.L1_IDLE) @(negedge clk);
  c_wstrb=4'hf;
  // Complete code staging must still contain the I stream, not D hit bytes.
  code_read('h9000,0,1,1);
  read_at('h1000); read_at('h1020);
  ifill_checks++;
endtask

task automatic run_data_under_ifill;
  int guard, before_backing;
  logic [31:0] before_addr;
  // Every backing beat, both same/different sets, all aligned words and all
  // byte offsets (including byte 31). One held fill per independent case.
  for(int beat=0;beat<8;beat++)
    for(int other=0;other<2;other++)
      for(int mode=0;mode<2;mode++)
        for(int off=0;off<32;off+=(mode ? 4 : 1)) begin
          ifill_setup(beat);
          ifill_resident_read(32'h1000+32'(other*32+off),!mode);
        end

  // A D fill still cannot use its own set's other resident way. There is no
  // new hit/miss/store/MMIO policy, nor a backing request allocation.
  for(int kind=0;kind<5;kind++) begin
    ifill_setup(3,kind!=0);
    before_backing=backing; before_addr=m_addr;
    c_req=1; c_addr='h1000; c_wstrb=4'hf;
    case(kind)
      1: c_addr='h5080; // genuine miss
      2: cacheable=0;
      3: c_we=1;
      4: c_addr='h101f; // cross-line dword, although both lines are resident
      default: ;
    endcase
    repeat(4) begin
      @(posedge clk);
      if(c_ack || backing!=before_backing || m_addr!=before_addr || m_we)
        $fatal(1,"unsafe I-fill overlap kind=%0d",kind);
    end
    @(negedge clk); c_req=0; c_we=0; cacheable=1; hold_ack=0;
    while(dut.st!=dut.L1_IDLE) @(negedge clk);
    ifill_checks++;
  end

  // Invalidate on both the capture and response edges. Invalidation of the
  // D line need not poison an unrelated I fill, but no old D byte may escape.
  for(int event_kind=0;event_kind<3;event_kind++)
    for(int response_edge=0;response_edge<2;response_edge++) begin
      ifill_setup(4);
      c_req=1; c_addr='h1000; c_wstrb=4'hf;
      if(response_edge) begin @(posedge clk); @(negedge clk); end
      case(event_kind)
        0: begin snoop_inv_valid=1; snoop_inv_addr='h1000; end
        1: flush_all=1;
        2: rst_n=0;
      endcase
      #1;
      if(event_kind!=2 && c_ack) $fatal(1,"invalidation-edge stale D response");
      @(posedge clk); @(negedge clk);
      c_req=0; snoop_inv_valid=0; flush_all=0; rst_n=1;
      mem['h1000]^=8'h6d;
      if(dut.rd_armed) $fatal(1,"event retained D response owner");
      hold_ack=0;
      while(dut.st!=dut.L1_IDLE) @(negedge clk);
      before_backing=backing;
      read_at('h1000);
      if(backing-before_backing!=8) $fatal(1,"invalidated D line did not refill");
      ifill_checks++;
    end

  // An ordinary D capture may coincide with EVERY accepted I beat, including
  // final tag publication. Check the D-LRU update survives that same-set edge.
  for(int beat=0;beat<8;beat++) begin
    ifill_setup(beat);
    while((ticks%3)!=0) @(negedge clk);
    c_req=1; c_addr='h1000; c_wstrb=4'hf; hold_ack=0;
    #1; if(!m_ack || dut.fw!=3'(beat)) $fatal(1,"no coincident I beat");
    @(posedge clk); @(negedge clk); hold_ack=1;
`ifdef VEN_L1D_DATA_UNDER_IFILL
    if(!c_ack || c_rdata!==word_at('h1000) || !dut.rd_match)
      $fatal(1,"I-beat collision lost D response");
    if(dut.dc_lru[0]!==dut.hit_way) $fatal(1,"I publication clobbered D LRU");
`else
    if(c_ack) $fatal(1,"control I-beat response early");
`endif
    @(posedge clk); @(negedge clk); c_req=0; hold_ack=0;
    while(dut.st!=dut.L1_IDLE) @(negedge clk);
    read_at('h1000); code_read('h9000,0,1,1);
    ifill_checks++;
  end
  $display("DATA-UNDER-IFILL-OK checks=%0d held_completions=%0d",ifill_checks,ifill_held_completions);
endtask
