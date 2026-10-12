// Public traffic only: fill real tags/data and create/evict response windows.
// The independent whole-cache miter also checks both edges and every bank.
int fresh_pair_cases=0,fresh_pair_accepts=0,fresh_pair_holds=0;
int fresh_pair_saved=0,fresh_pair_conflicts=0,fresh_pair_guards=0;

task automatic fresh_pair_setup;
  pair_req_valid=0;pair_now_req=0;pair_rsp_ready=2'b11;
  iw_reset();
  read_at('h1000);read_at('h2040);read_at('h3080);
  // Cold critical-word responses need not retain a complete reusable line.
  // Re-read the two now-resident lines to establish actual saved windows.
  read_at('h2040);read_at('h3080);
  @(negedge clk);
  if(dut.rd_armed || dut.window_reuse || dut.shadow_reuse ||
     !dut.window_valid_q || !dut.shadow_valid_q ||
     dut.rd_addr_q[31:5]!=(32'h3080>>5) || dut.shadow_line_addr_q!=(32'h2040>>5))
    $fatal(1,"FRESH-PAIR-SETUP: live read owner");
endtask

task automatic fresh_pair_probe(input logic[31:0] address,vaddress,
    input logic[3:0] mask,input bit capture,accept_v);
  @(negedge clk);
  c_req=1;c_we=0;c_addr=address;c_wstrb=mask;
  c_next_req=1;c_next_commit=0;c_next_addr=32'hfc00301f;c_next_wstrb=4'hf;
  pair_req_valid=2'b10;pair_paddr[1]=vaddress;pair_size_log2[1]=2'd2;
  pair_owner[1]=16'h8f01;pair_rsp_ready=0;pair_now_req=0;
  #2;
  if(dut.rd_armed || dut.mc_lookup_next || dut.pair_legacy_capture!==capture ||
     pair_req_ready[1]!==accept_v)
    $fatal(1,"FRESH-PAIR-PROBE: addr=%h strb=%h capture=%b/%b ready=%b/%b next=%b rd=%b",
      address,mask,dut.pair_legacy_capture,capture,pair_req_ready[1],accept_v,
      dut.mc_lookup_next,dut.rd_armed);
  // Withdraw or retarget a rejected next request within this same clock.
  // Neither the admission nor the old/current data result may depend on it.
  c_next_req=0;c_next_addr=32'h1000;c_next_wstrb=1;
  #1;
  if(dut.pair_legacy_capture!==capture || pair_req_ready[1]!==accept_v)
    $fatal(1,"FRESH-PAIR-NEXT-DEPENDENCE");
  c_next_req=1;
  #1;
  if(dut.pair_legacy_capture!==capture || pair_req_ready[1]!==accept_v)
    $fatal(1,"FRESH-PAIR-NEXT-DEPENDENCE restored");
  if(!capture) begin
    if(!(dut.window_reuse || dut.shadow_reuse) || !c_ack)
      $fatal(1,"FRESH-PAIR-SAVED: missing actual immediate U response");
    fresh_pair_saved++;
  end
  if(capture && address[4:2]==vaddress[4:2]) begin
    if(!pair_bank_conflict) $fatal(1,"FRESH-PAIR-BANK-CONFLICT missing");
    fresh_pair_conflicts++;
  end
  @(posedge clk);#2;
  if(!c_ack || (mask==4'hf ? c_rdata!==word_at(address) : c_rdata[7:0]!==mem[address]))
    $fatal(1,"FRESH-PAIR-U-DATA");
  if(pair_rsp_valid[1]!==accept_v)
    $fatal(1,"FRESH-PAIR-V-VALID");
  if(accept_v && (pair_rsp_paddr[1]!==vaddress || pair_rsp_data[1]!==word_at(vaddress) ||
                 pair_rsp_owner[1]!==16'h8f01))
    $fatal(1,"FRESH-PAIR-V-OWNER-DATA");
  @(negedge clk);c_req=0;c_next_req=0;pair_req_valid=0;
  // Backpressure V after accepting both reads; its exact owner/data survive.
  repeat(3) begin
    @(posedge clk);#2;
    if(pair_rsp_valid[1]!==accept_v || (accept_v &&
        (pair_rsp_paddr[1]!==vaddress || pair_rsp_data[1]!==word_at(vaddress) ||
         pair_rsp_owner[1]!==16'h8f01)))
      $fatal(1,"FRESH-PAIR-HELD-V changed");
    if(accept_v) fresh_pair_holds++;
  end
  @(negedge clk);pair_rsp_ready=2'b11;
  @(negedge clk);
  fresh_pair_cases++;
  if(accept_v) fresh_pair_accepts++;
endtask

task automatic run_fresh_pair_capture;
  // Every byte (including 29..31), every aligned word, and same-bank refusal.
  for(int offset=0;offset<32;offset++) begin
    fresh_pair_setup();
    fresh_pair_probe(32'h1000+32'(offset),
      32'h1000+32'(((offset/4+1)%8)*4),4'h1,1,1);
  end
  for(int offset=0;offset<32;offset+=4) begin
    fresh_pair_setup();
    fresh_pair_probe(32'h1000+32'(offset),
      32'h1000+32'(((offset/4+1)%8)*4),4'hf,1,1);
    fresh_pair_setup();
    fresh_pair_probe(32'h1000+32'(offset),32'h1000+32'(offset),4'hf,1,0);
  end
  // Both saved windows suppress a redundant fresh-bank capture without
  // delaying U. The byte-31 case cannot use a four-byte saved-window read.
  fresh_pair_setup();fresh_pair_probe('h3080,'h3084,4'hf,0,0);
  fresh_pair_setup();fresh_pair_probe('h2040,'h2044,4'hf,0,0);
  fresh_pair_setup();fresh_pair_probe('h309f,'h3080,4'h1,1,1);
  fresh_pair_setup();
  @(negedge clk);
  c_req=1;c_we=0;c_addr='h1000;c_wstrb=4'hf;
  pair_req_valid=2'b10;pair_paddr[1]='h1004;pair_size_log2[1]=2;
  pair_rsp_ready=0;c_next_req=1;c_next_commit=0;c_next_addr='hffff101f;
  #1;
  if(!dut.pair_legacy_capture || !pair_req_ready[1]) $fatal(1,"FRESH-PAIR-GUARD setup");
  // Restore each transient input before an active clock edge. Each check is
  // independent of registered assertions and sees the real combinational DUT.
  snoop_inv_valid=1;#0.5;
  if(dut.pair_legacy_capture || pair_req_ready[1]) $fatal(1,"FRESH-PAIR-SNOOP");
  snoop_inv_valid=0;cacheable=0;#0.5;
  if(dut.pair_legacy_capture || pair_req_ready[1]) $fatal(1,"FRESH-PAIR-NONCACHE");
  cacheable=1;golden=1;#0.5;
  if(dut.pair_legacy_capture || pair_req_ready[1]) $fatal(1,"FRESH-PAIR-GOLDEN");
  golden=0;flush_all=1;#0.5;
  if(!dut.pair_legacy_capture || pair_req_ready[1]) $fatal(1,"FRESH-PAIR-FLUSH ownership");
  flush_all=0;c_req=0;pair_req_valid=0;c_next_req=0;pair_rsp_ready=2'b11;
  fresh_pair_guards+=4;
  iw_reset();
  if(fresh_pair_cases!=51 || fresh_pair_accepts!=41 || fresh_pair_holds!=123 ||
     fresh_pair_saved!=2 || fresh_pair_conflicts!=8 || fresh_pair_guards!=4)
    $fatal(1,"FRESH-PAIR-CACHE-COVERAGE");
  $display("FRESH-PAIR-CACHE-OK cases=%0d pairs=%0d held=%0d saved=%0d conflicts=%0d guards=%0d",
    fresh_pair_cases,fresh_pair_accepts,fresh_pair_holds,fresh_pair_saved,
    fresh_pair_conflicts,fresh_pair_guards);
endtask
