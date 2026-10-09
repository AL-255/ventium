// Native leaf stimulus only: no forced DUT state, no replacement memory owner.
task automatic run_prime_under_fill();
  int checks, guard, backing_before;
  logic [31:0] backing_addr;
  checks=0;
  @(negedge clk); rst_n=0;
  c_req=0; c_next_req=0; c_next_commit=0;
  repeat(2) @(negedge clk); rst_n=1;
  read_at('h1000); read_at('h1040);
  // Miss in set 2. Its critical response releases the CPU, while the paused
  // real backing slave leaves the original tail owner active.
  @(negedge clk); c_req=1; c_addr='h3040; c_we=0; c_wstrb=4'hf;
  guard=0;
  do begin @(posedge clk); if(++guard>200) $fatal(1,"critical fill timeout"); end while(!c_ack);
  @(negedge clk); c_req=0; hold_ack=1;
  @(negedge clk);
  if(dut.st!=dut.L1_FILL || dut.early_armed || dut.rd_armed || !m_req || m_we)
    $fatal(1,"no distinct held fill owner");
  backing_addr=m_addr; backing_before=backing;

  // Test every byte and every contained aligned dword on the existing port.
  for(int mode=0;mode<2;mode++) begin
    for(int off=0;off<32;off+=(mode ? 4 : 1)) begin
      @(negedge clk);
      c_next_req=1; c_next_commit=0; c_next_cacheable=1;
      c_next_addr='h1000+32'(off); c_next_wstrb=mode ? 4'hf : 4'h1;
      #1;
`ifdef VEN_L1D_PRIME_UNDER_FILL
      if(!c_next_ready) $fatal(1,"independent resident prime blocked");
`else
      if(c_next_ready) $fatal(1,"control unexpectedly primes under fill");
`endif
      if(dut.rd_armed || c_ack || m_addr!=backing_addr || backing!=backing_before)
        $fatal(1,"uncommitted hint changed an owner");
      @(posedge clk); @(negedge clk); c_next_commit=1;
      @(posedge clk); @(negedge clk);
      c_next_req=0; c_next_commit=0;
      c_req=1; c_addr=c_next_addr; c_wstrb=c_next_wstrb;
      #1;
`ifdef VEN_L1D_PRIME_UNDER_FILL
      if(!c_ack || !dut.rd_match) $fatal(1,"primed response not owned next clock");
`else
      if(c_ack) $fatal(1,"control response unexpectedly early");
      @(posedge clk); @(negedge clk); #1;
      if(!c_ack) $fatal(1,"control independent resident read failed");
`endif
      if((mode && c_rdata!==word_at(c_addr)) || (!mode && c_rdata[7:0]!==mem[c_addr]))
        $fatal(1,"wrong primed payload");
      if(m_addr!=backing_addr || backing!=backing_before || !m_req || m_we)
        $fatal(1,"prime replaced backing fill");
      @(posedge clk); @(negedge clk); c_req=0;
      @(negedge clk); checks++;
    end
  end

  // Same-set resident, miss, MMIO, split dword, partial strobe and a live
  // demand owner must not be accepted as an independent cache-only hint.
  for(int kind=0;kind<6;kind++) begin
    @(negedge clk);
    c_next_req=1; c_next_commit=1; c_next_addr='h1000;
    c_next_cacheable=1; c_next_wstrb=4'hf;
    case(kind)
      0: c_next_addr='h1040;
      1: c_next_addr='h8080;
      2: c_next_cacheable=0;
      3: c_next_addr='h101f;
      4: c_next_wstrb=4'h3;
      5: begin c_req=1; c_addr='h3080; c_wstrb=4'hf; end
    endcase
    #1;
    if(c_next_ready || m_addr!=backing_addr || backing!=backing_before)
      $fatal(1,"unsafe prime accepted kind=%0d",kind);
    @(posedge clk); @(negedge clk);
    c_req=0; c_next_req=0; c_next_commit=0; checks++;
  end
  c_next_cacheable=1; c_next_wstrb=4'hf;

  // A snoop on the proposed capture edge wins over the hint.
  @(negedge clk); c_next_req=1; c_next_commit=1; c_next_addr='h1000;
  snoop_inv_valid=1; snoop_inv_addr='h1000;
  #1; if(c_next_ready || c_ack) $fatal(1,"snoop allowed under-fill prime");
  @(posedge clk); @(negedge clk);
  c_next_req=0; c_next_commit=0; snoop_inv_valid=0;
  mem['h1000]=8'h59; checks++;
  // Drain the original fill naturally, then refill the invalidated operand.
  hold_ack=0;
  while(dut.st!=dut.L1_IDLE) @(negedge clk);
  read_at('h1000);

  // Kill a captured hint on its response edge while the other fill is still
  // active. Snoop and flush suppress ACK; reset clears the registered owner.
  for(int event_kind=0;event_kind<3;event_kind++) begin
    @(negedge clk); rst_n=0; c_req=0;
    repeat(2) @(negedge clk); rst_n=1;
    read_at('h1000);
    @(negedge clk); c_req=1; c_addr='h3040; c_wstrb=4'hf;
    do @(posedge clk); while(!c_ack);
    @(negedge clk); c_req=0; hold_ack=1;
    @(negedge clk); c_next_req=1; c_next_commit=1; c_next_addr='h1000;
    @(posedge clk); @(negedge clk);
    c_next_req=0; c_next_commit=0; c_req=1; c_addr='h1000;
    case(event_kind)
      0: begin snoop_inv_valid=1; snoop_inv_addr='h1000; mem['h1000]++; end
      1: begin flush_all=1; mem['h1000]++; end
      2: rst_n=0;
    endcase
    #1;
    if(event_kind!=2 && c_ack) $fatal(1,"invalidated hint acknowledged");
    @(posedge clk); @(negedge clk);
    c_req=0; snoop_inv_valid=0; flush_all=0; rst_n=1; hold_ack=0;
    #1; if(dut.rd_armed) $fatal(1,"event retained the primed owner");
    while(dut.st!=dut.L1_IDLE) @(negedge clk);
    read_at('h1000); checks++;
  end

  // Capture a hint on the final fill beat. The two writes touch different
  // physical sets; no extra backing transaction or response may appear.
  @(negedge clk); rst_n=0; c_req=0;
  repeat(2) @(negedge clk); rst_n=1;
  read_at('h1000);
  @(negedge clk); c_req=1; c_addr='h3040; c_wstrb=4'hf;
  do @(posedge clk); while(!c_ack);
  @(negedge clk); c_req=0;
  while(dut.st==dut.L1_FILL && dut.fw!=7) @(negedge clk);
  if(dut.st!=dut.L1_FILL) $fatal(1,"missed terminal fill beat");
  hold_ack=1;
  while((ticks%3)!=0) @(negedge clk);
  c_next_req=1; c_next_commit=1; c_next_addr='h1000; hold_ack=0;
  #1;
  if(!m_ack || dut.fw!=7) $fatal(1,"terminal beat not coincident");
`ifdef VEN_L1D_PRIME_UNDER_FILL
  if(!c_next_ready) $fatal(1,"terminal fill beat blocked unrelated prime");
`else
  if(c_next_ready) $fatal(1,"control primed on terminal fill beat");
`endif
  @(posedge clk); @(negedge clk);
  c_next_req=0; c_next_commit=0; c_req=1; c_addr='h1000;
  #1;
`ifdef VEN_L1D_PRIME_UNDER_FILL
  if(!c_ack || c_rdata!==word_at('h1000)) $fatal(1,"terminal overlap corrupted prime");
`else
  if(c_ack) $fatal(1,"control terminal response early");
  @(posedge clk); @(negedge clk); #1;
  if(!c_ack) $fatal(1,"control terminal response lost");
`endif
  @(posedge clk); @(negedge clk); c_req=0;
  while(dut.st!=dut.L1_IDLE) @(negedge clk);
  read_at('h3040); checks++;
  $display("PRIME-UNDER-FILL-LEAF-OK checks=%0d",checks);
endtask
