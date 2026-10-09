// Exercise complete-line provenance through read-ahead and coincident fills.
// All state is established by public bus transactions, never DUT writes.
task automatic run_load64_fill_edges;
  int checks, wide, critical_suppressed, before_backing;
  logic [31:0] target;
  checks=0; wide=0; critical_suppressed=0;
  // Held read-ahead and accepted-beat collisions, both ordinary and primed.
  for(int coincident=0;coincident<2;coincident++)
    for(int prime=0;prime<2;prime++)
      if(coincident || prime)
        for(int instruction_fill=0;instruction_fill<2;instruction_fill++)
          for(int other=0;other<2;other++)
            if(instruction_fill || other)
              for(int beat=0;beat<8;beat++)
                for(int off=0;off<=24;off+=4) begin
                  ifill_setup(beat,1'(instruction_fill));
                  target='h1000+32'(other*32+off);
                  if(coincident)
                    while((ticks%3)!=0) @(negedge clk);
                  before_backing=backing;
                  if(prime) begin
                    c_next_req=1; c_next_commit=1; c_next_cacheable=1;
                    c_next_addr=target; c_next_wstrb=4'hf;
                  end else begin
                    c_req=1; c_addr=target; c_wstrb=4'hf;
                  end
                  if(coincident) hold_ack=0;
                  #1;
                  if(prime && !c_next_ready) $fatal(1,"wide prime not accepted");
                  if(coincident && (!m_ack || dut.fw!=3'(beat)))
                    $fatal(1,"wide capture did not coincide with selected fill beat");
                  @(posedge clk); @(negedge clk); hold_ack=1;
                  c_next_req=0; c_next_commit=0; c_req=1; c_addr=target; c_wstrb=4'hf;
                  #1;
                  if(!c_ack || !dut.rd_match || c_rdata!==word_at(target))
                    $fatal(1,"wide edge test lost registered low-half owner");
`ifdef VEN_FP_LOAD64_UNDER_FILL
                  // The first backing beat arms its own critical response.
                  // Low-half selection is owner-qualified, but the optional
                  // wide path deliberately retains its !early_armed guard.
                  // A request retargeted before that beat must still get the
                  // correct low half; it is not entitled to a wide response.
                  if(coincident && beat==0) begin
                    if(!dut.early_armed || dut.early_match || c_rdata_hi_valid)
                      $fatal(1,"critical response exclusion/identity changed");
                    critical_suppressed++;
                  end else begin
                    if(!c_rdata_hi_valid || c_rdata_hi!==word_at(target+4))
                      $fatal(1,"wide provenance coincident=%0d prime=%0d I=%0d other=%0d beat=%0d off=%0d",coincident,prime,instruction_fill,other,beat,off);
                    wide++;
                  end
`else
                  if(c_rdata_hi_valid) $fatal(1,"disabled wide fill-edge response");
`endif
                  if(backing!=before_backing+coincident)
                    $fatal(1,"wide overlap changed backing transaction count");
                  @(posedge clk); @(negedge clk); c_req=0; hold_ack=0;
                  while(dut.st!=dut.L1_IDLE) @(negedge clk);
                  read_at('h1000); read_at('h1020); checks++;
                end
  $display("LOAD64-FILL-EDGES-OK checks=%0d wide=%0d critical_suppressed=%0d",checks,wide,critical_suppressed);
endtask
