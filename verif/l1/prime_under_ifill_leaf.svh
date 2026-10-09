// Uses ordinary CPU requests and a held backing slave. No DUT state writes.
task automatic run_prime_under_ifill;
  int checks, completions, guard, prior_backing;
  logic [31:0] prior_addr, target;
  checks=0; completions=0;
  for(int beat=0;beat<8;beat++)
    for(int other=0;other<2;other++)
      for(int narrow=0;narrow<2;narrow++)
        for(int off=0;off<32;off+=(narrow ? 1 : 4)) begin
          ifill_setup(beat);
          target=32'h1000+32'(other*32+off);
          prior_backing=backing; prior_addr=m_addr;
          c_next_req=1; c_next_commit=0; c_next_cacheable=1;
          c_next_addr=target; c_next_wstrb=narrow ? 4'h1 : 4'hf;
          repeat(3) begin
            #1;
`ifdef VEN_L1D_PRIME_UNDER_IFILL
            if(!c_next_ready) $fatal(1,"I fill blocked resident D prime");
`else
            if(c_next_ready) $fatal(1,"control admitted new I-fill prime");
`endif
            if(c_ack || dut.rd_armed || backing!=prior_backing || m_addr!=prior_addr)
              $fatal(1,"uncommitted prime changed an owner");
            @(posedge clk); @(negedge clk);
          end
          c_next_commit=1;
          @(posedge clk); @(negedge clk);
          c_next_req=0; c_next_commit=0;
          c_req=1; c_addr=target; c_wstrb=c_next_wstrb;
          #1;
`ifdef VEN_L1D_PRIME_UNDER_IFILL
          if(!c_ack || !dut.rd_match) $fatal(1,"prime not owned on first demand clock");
          completions++;
`else
          if(c_ack) $fatal(1,"control prime unexpectedly early");
          @(posedge clk); @(negedge clk); #1;
          if(!c_ack || !dut.rd_match) $fatal(1,"ordinary under-I-fill fallback failed");
`endif
          if((narrow && c_rdata[7:0]!==mem[target]) || (!narrow && c_rdata!==word_at(target)))
            $fatal(1,"primed I-fill payload mismatch");
          if(backing!=prior_backing || m_addr!=prior_addr || !m_req || m_we)
            $fatal(1,"prime replaced I backing owner");
          @(posedge clk); @(negedge clk); c_req=0; hold_ack=0;
          while(dut.st!=dut.L1_IDLE) @(negedge clk);
          c_wstrb=4'hf;
          code_read('h9000,0,1,1); read_at('h1000); read_at('h1020);
          checks++;
        end

  // Same-set D fill, miss, MMIO, crossing, partial strobe, live demand and
  // instruction-shaped live payload selector stay excluded.
  for(int kind=0;kind<7;kind++) begin
    ifill_setup(3,kind!=0);
    prior_backing=backing; prior_addr=m_addr;
    c_next_req=1; c_next_commit=1; c_next_addr='h1000;
    c_next_wstrb=4'hf; c_next_cacheable=1;
    case(kind)
      1:c_next_addr='h5080;
      2:c_next_cacheable=0;
      3:c_next_addr='h101f;
      4:c_next_wstrb=4'h3;
      5:begin c_req=1; c_addr='h5080; end
      6:begin c_code=1; c_addr='h9000; end
      default:;
    endcase
    repeat(3) begin
      #1;
      if(c_next_ready || c_ack || dut.rd_armed || backing!=prior_backing || m_addr!=prior_addr)
        $fatal(1,"unsafe prime kind=%0d",kind);
      @(posedge clk); @(negedge clk);
    end
    c_req=0; c_code=0; c_next_req=0; c_next_commit=0; c_next_cacheable=1; hold_ack=0;
    while(dut.st!=dut.L1_IDLE) @(negedge clk);
    checks++;
  end

  for(int event_kind=0;event_kind<3;event_kind++)
    for(int response_edge=0;response_edge<2;response_edge++) begin
      ifill_setup(4);
      c_next_req=1; c_next_commit=1; c_next_addr='h1000; c_next_wstrb=4'hf;
      if(response_edge) begin
        @(posedge clk); @(negedge clk);
        c_next_req=0; c_next_commit=0; c_req=1; c_addr='h1000;
      end
      case(event_kind)
        0:begin snoop_inv_valid=1; snoop_inv_addr='h1000; end
        1:flush_all=1;
        2:rst_n=0;
      endcase
      #1;
      if(event_kind!=2 && (c_next_ready || c_ack)) $fatal(1,"event lost to prime");
      @(posedge clk); @(negedge clk);
      c_req=0; c_next_req=0; c_next_commit=0; snoop_inv_valid=0; flush_all=0; rst_n=1;
      if(dut.rd_armed) $fatal(1,"event retained prime owner");
      mem['h1000]^=8'h39; hold_ack=0;
      while(dut.st!=dut.L1_IDLE) @(negedge clk);
      prior_backing=backing; read_at('h1000);
      if(backing-prior_backing!=8) $fatal(1,"event did not invalidate D line");
      checks++;
    end

  // Real I-beat capture on each beat, including final same-set publication.
  for(int beat=0;beat<8;beat++) begin
    ifill_setup(beat);
    while((ticks%3)!=0) @(negedge clk);
    c_next_req=1; c_next_commit=1; c_next_addr='h1000; c_next_wstrb=4'hf;
    hold_ack=0; #1;
    if(!m_ack || dut.fw!=3'(beat)) $fatal(1,"no coincident I beat");
    @(posedge clk); @(negedge clk); hold_ack=1;
    c_next_req=0; c_next_commit=0; c_req=1; c_addr='h1000;
    #1;
`ifdef VEN_L1D_PRIME_UNDER_IFILL
    if(!c_ack || c_rdata!==word_at('h1000) || !dut.rd_match)
      $fatal(1,"I publication lost prime payload");
    if(dut.dc_lru[0]!==dut.hit_way) $fatal(1,"I publication overwrote D LRU");
`else
    if(c_ack) $fatal(1,"control primed with I beat");
    @(posedge clk); @(negedge clk); #1;
    if(!c_ack) $fatal(1,"I-beat ordinary fallback missing");
`endif
    @(posedge clk); @(negedge clk); c_req=0; hold_ack=0;
    while(dut.st!=dut.L1_IDLE) @(negedge clk);
    read_at('h1000); code_read('h9000,0,1,1); checks++;
  end
  $display("PRIME-UNDER-IFILL-OK checks=%0d completions=%0d",checks,completions);
endtask
