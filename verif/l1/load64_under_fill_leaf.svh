// Real bus fills and resident requests only: no DUT memory/state writes.
task automatic run_load64_under_fill;
  int checks, wide, prior_backing;
  logic [31:0] target, prior_addr;
  checks=0; wide=0;
  // I fills may overlap either D set; D fills may overlap only another set.
  // All 25 within-line eight-byte offsets include every unaligned shape.
  for(int instruction_fill=0;instruction_fill<2;instruction_fill++)
    for(int other=0;other<2;other++)
      if(instruction_fill || other)
        for(int beat=0;beat<8;beat++)
          for(int off=0;off<=24;off++) begin
            ifill_setup(beat,1'(instruction_fill));
            target='h1000+32'(other*32+off);
            prior_backing=backing; prior_addr=m_addr;
            c_req=1; c_we=0; c_code=0; c_addr=target; c_wstrb=4'hf;
            #1;
            if(c_ack || c_rdata_hi_valid) $fatal(1,"wide read bypassed registered owner");
            @(posedge clk); @(negedge clk); #1;
            if(!c_ack || !dut.rd_match || c_rdata!==word_at(target))
              $fatal(1,"resident low half lost during fill");
`ifdef VEN_FP_LOAD64_UNDER_FILL
            if(!c_rdata_hi_valid || c_rdata_hi!==word_at(target+4))
              $fatal(1,"complete resident high half suppressed/corrupted");
            wide++;
`else
            if(c_rdata_hi_valid) $fatal(1,"control unexpectedly widens under fill");
`endif
            if(backing!=prior_backing || m_addr!=prior_addr || !m_req || m_we)
              $fatal(1,"wide D read stole the backing fill");
            @(posedge clk); @(negedge clk); c_req=0; hold_ack=0;
            while(dut.st!=dut.L1_IDLE) @(negedge clk);
            read_at('h1000); read_at('h1020); checks++;
          end
  // One-byte/word requests and less than eight bytes left never widen.
  for(int kind=0;kind<9;kind++) begin
    ifill_setup(3);
    target='h1020+32'(kind<2 ? 0 : kind+23);
    c_req=1; c_addr=target; c_wstrb=kind==0 ? 4'h1 : kind==1 ? 4'h3 : 4'hf;
    @(posedge clk); @(negedge clk); #1;
    if(c_rdata_hi_valid) $fatal(1,"narrow/cross-line response widened");
    c_req=0; c_wstrb=4'hf; hold_ack=0;
    while(dut.st!=dut.L1_IDLE) @(negedge clk);
    checks++;
  end
  // Reset/flush/snoop win on both capture and serve edges for both fill kinds.
  for(int instruction_fill=0;instruction_fill<2;instruction_fill++)
    for(int event_kind=0;event_kind<3;event_kind++)
      for(int response_edge=0;response_edge<2;response_edge++) begin
        ifill_setup(3,1'(instruction_fill));
        c_req=1; c_addr='h1020; c_wstrb=4'hf;
        if(response_edge) begin @(posedge clk); @(negedge clk); end
        case(event_kind)
          0:begin snoop_inv_valid=1; snoop_inv_addr='h1020; end
          1:flush_all=1;
          2:rst_n=0;
        endcase
        #1;
        if(c_rdata_hi_valid) $fatal(1,"cancelled high-half owner escaped");
        @(posedge clk); @(negedge clk);
        c_req=0; snoop_inv_valid=0; flush_all=0; rst_n=1; hold_ack=0;
        while(dut.st!=dut.L1_IDLE) @(negedge clk);
        checks++;
      end
  $display("LOAD64-UNDER-FILL-OK checks=%0d wide=%0d",checks,wide);
endtask
