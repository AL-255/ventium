// Actual cache state from public fill/read/prime traffic only.
int pair_now_cases=0,pair_now_immediate=0,pair_now_denied=0;
int pair_now_standalone=0,pair_now_fresh=0;

task automatic pair_now_inputs(input logic[31:0] base,vaddr,
    input logic[1:0] size,valid_mask);
  c_req=1;c_we=0;c_addr=base;c_wstrb=4'hf;c_next_req=0;c_next_commit=0;
  pair_req_valid=valid_mask;pair_paddr[0]='h1000;pair_paddr[1]=vaddr;
  pair_size_log2[0]=2;pair_size_log2[1]=size;pair_cacheable=3;
  pair_owner[0]=16'ha101;pair_owner[1]=16'ha102;pair_rsp_ready=0;
  pair_now_req=1;pair_now_paddr=vaddr;pair_now_size_log2=size;pair_now_cacheable=1;
endtask

task automatic pair_now_clear;
  @(negedge clk);c_req=0;c_next_req=0;pair_req_valid=0;pair_now_req=0;pair_rsp_ready=3;
  @(negedge clk);
endtask

task automatic run_pair_now_capture;
  // Every byte offset for both byte/dword V reads, in both saved windows.
  // A same-bank or over-extent immediate rejection must not become a capture.
  for(int win=0;win<2;win++) for(int width=0;width<2;width++)
    for(int off=0;off<32;off++) begin
      logic[31:0] base,vaddr,expected_data;
      bit expected_now;
      fresh_pair_setup();base=win ? 32'h2040 : 32'h3080;vaddr=base+32'(off);
      expected_now=(off>=4) && (!width || off<=28);
      expected_data=width ? word_at(vaddr) : {24'd0,mem[vaddr]};
      @(negedge clk);pair_now_inputs(base,vaddr,width ? 2'd2 : 2'd0,2'b10);
      #2;
      if (!c_ack || pair_now_valid!==expected_now || pair_req_ready[1] ||
          dut.pair_lookup_active || dut.pair_hit[1] ||
          (expected_now && pair_now_data!==expected_data))
        $fatal(1,"PAIR-NOW-FULL saved win=%0d width=%0d off=%0d now=%b expected=%b capture=%b",
          win,width,off,pair_now_valid,expected_now,pair_req_ready[1]);
      @(posedge clk);#2;
      if (pair_rsp_valid[1]) $fatal(1,"PAIR-NOW-FULL duplicate V response");
      pair_now_cases++;
      if(expected_now) pair_now_immediate++; else pair_now_denied++;
      pair_now_clear();
    end
  // A real registered U owner permits standalone lane 0 alongside an
  // immediate lane 1. Preserve that priority for BOTH independent requests.
  for(int win=0;win<2;win++) begin
    logic[31:0] base;
    fresh_pair_setup();base=win ? 32'h2040 : 32'h3080;
    prime_only(base);
    pair_now_inputs(base,base+4,2'd2,2'b11);
    #2;
    if (!dut.rd_armed || !dut.rd_match || !c_ack || !pair_now_valid ||
        !dut.pair_lookup_active || !pair_req_ready[0] || pair_req_ready[1] ||
        dut.pair_hit[1] || pair_now_data!==word_at(base+4))
      $fatal(1,"PAIR-NOW-FULL standalone priority");
    @(posedge clk);#2;
    if (pair_rsp_valid!==2'b01 || pair_rsp_paddr[0]!==32'h1000 ||
        pair_rsp_owner[0]!==16'ha101 || pair_rsp_data[0]!==word_at('h1000))
      $fatal(1,"PAIR-NOW-FULL standalone owner/data");
    pair_now_standalone++;pair_now_clear();
  end
  // Immediate request asserted but no saved window: actual bank capture
  // still accepts V and creates the normal registered response.
  for(int width=0;width<2;width++) begin
    fresh_pair_setup();
    @(negedge clk);pair_now_inputs('h1000,'h1004,width ? 2'd2 : 2'd0,2'b10);
    #2;
    if (!dut.pair_legacy_capture || pair_now_valid || !pair_req_ready[1])
      $fatal(1,"PAIR-NOW-FULL fresh capture");
    @(posedge clk);#2;
    if (!c_ack || pair_rsp_valid!==2'b10 || pair_rsp_paddr[1]!==32'h1004 ||
        pair_rsp_owner[1]!==16'ha102 || pair_rsp_data[1]!==
        (width ? word_at('h1004) : {24'd0,mem['h1004]}))
      $fatal(1,"PAIR-NOW-FULL fresh owner/data");
    pair_now_fresh++;pair_now_clear();
  end
  iw_reset();
  if(pair_now_cases!=128 || pair_now_immediate!=106 || pair_now_denied!=22 ||
      pair_now_standalone!=2 || pair_now_fresh!=2)
    $fatal(1,"PAIR-NOW-FULL coverage");
  $display("PAIR-NOW-FULL-OK cases=128 immediate=106 denied=22 standalone=2 fresh=2");
endtask
