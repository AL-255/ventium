// Port-driven whole-wrapper checks. No force, STEP or internal state mutation.
byte unsigned expected_mem[65536];
integer u_stores=0, v_stores=0, quad_stores=0, blocked=0, full_queue=0;
integer axi_writes=0, reset_checks=0, denied_checks=0;
bit record_writes=1;
function automatic logic [31:0] expected_word(input logic[31:0] addr);
  return {expected_mem[addr+3],expected_mem[addr+2],expected_mem[addr+1],expected_mem[addr]};
endfunction
always @(posedge clk) if(rst_n && !axi_only_reset) begin
  if(awvalid && awready) axi_writes++;
  if(dut.u_axi.wq_count==2) full_queue++;
  if(core_req && core_we && !core_ack) blocked++;
  if(dut.u_axi.wr_quad_enq) quad_stores++;
  if(record_writes && core_req && core_we && core_ack) begin
    for(int b=0;b<4;b++) if(core_wstrb[b]) expected_mem[core_addr+b]=core_wdata[8*b+:8];
    u_stores++;
  end
  if(record_writes && store_pair_ack) begin
    for(int b=0;b<4;b++) if(store_pair_wstrb[b]) expected_mem[store_pair_addr+b]=store_pair_wdata[8*b+:8];
    v_stores++;
  end
end
task automatic drop_request;
  core_req=0; core_we=0; store_pair_req=0; core_wstrb=4'hf;
endtask
task automatic drain;
  integer guard_n;
  guard_n=0;
  while(!m_idle || dut.u_l1d.st!=0) begin
    @(negedge clk);
    guard_n++;
    if(guard_n>500 || bus_err) $fatal(1,"PAIR-WRAPPER drain fault/timeout");
  end
endtask
task automatic store_at(input logic[31:0] addr,vaddr,input bit paired,input logic[3:0] mask);
  integer guard_n;
  @(negedge clk);
  core_req=1;core_we=1;core_addr=addr;core_wdata=32'h61437bac^addr;core_wstrb=mask;
  store_pair_req=paired;store_pair_addr=vaddr;store_pair_wdata=32'h8b927c01^vaddr;store_pair_wstrb=4'hf;
  guard_n=0;
  do begin
    @(posedge clk);
    guard_n++;
    if(guard_n>500 || bus_err) $fatal(1,"PAIR-WRAPPER store fault/timeout");
    if(core_ack && paired && !store_pair_ack) $fatal(1,"PAIR-WRAPPER split atomic pair");
  end while(!core_ack);
  @(negedge clk);drop_request();
endtask
task automatic read_at(input logic[31:0] addr);
  integer guard_n;
  @(negedge clk);core_req=1;core_we=0;core_addr=addr;core_wstrb=4'hf;
  guard_n=0;
  do begin
    @(posedge clk);
    guard_n++;
    if(guard_n>500 || bus_err) $fatal(1,"PAIR-WRAPPER read fault/timeout");
  end while(!core_ack);
  if(core_rdata!==expected_word(addr))
    $fatal(1,"PAIR-WRAPPER data addr=%08x got=%08x expected=%08x",addr,core_rdata,expected_word(addr));
  @(negedge clk);drop_request();drain();
endtask
initial begin : wrapper_test
  integer old_aw,guard_n;
  for(int a=0;a<65536;a++) begin
    expected_mem[a]=8'(a^(a>>8));slv.mem[a]=expected_mem[a];
  end
  slv.poke('h30000,32'hdeadbeef);slv.poke('h30004,32'hcafef00d);
  repeat(4)@(negedge clk);rst_n=1;repeat(4)@(negedge clk);
  store_at('h1000,0,0,4'hf);
  store_at('h1020,'h1024,1,4'hf); // one remaining slot admits aligned quad
  store_at('h1040,0,0,4'hf);     // full queue must stall
  drain();
  store_at('h1060,0,0,4'hf);
  store_at('h1084,'h1088,1,4'hf); // non-quad pair waits for two slots
  drain();read_at('h1020);read_at('h1024);read_at('h1084);read_at('h1088);
  for(int offset_n=0;offset_n<4;offset_n++)
    for(int mask_n=1;mask_n<16;mask_n++) begin
      store_at('h2000+32'(offset_n),0,0,4'(mask_n));
      drain();read_at('h2000);read_at('h2004);
    end
  // Independent V route/SMRAM qualification is a readiness query. The core
  // must not authorize V when it is rejected. Observe between clock edges.
  @(negedge clk);core_req=1;core_we=1;core_addr='h1000;core_wstrb=4'hf;
  store_pair_req=0;store_pair_addr='h30004;#1;
  if(store_pair_ready || !dut.store_pair_smram_deny) $fatal(1,"PAIR-WRAPPER SMRAM V ready");
  store_pair_addr='h40000000;#1;
  if(store_pair_ready) $fatal(1,"PAIR-WRAPPER unrouted V ready");
  store_pair_addr='ha0000;#1;
  if(store_pair_ready) $fatal(1,"PAIR-WRAPPER MMIO V ready");
  drop_request();denied_checks+=3;
  // Denied U must suppress the backing pair too, with no partial DDR write.
  @(negedge clk);record_writes=0;old_aw=axi_writes;
  core_req=1;core_we=1;core_addr='h30000;store_pair_req=1;store_pair_addr='h30004;
  repeat(3) begin
    @(posedge clk);
    if(dut.axm_req || dut.axm_pair_req || store_pair_ack || !core_ack)
      $fatal(1,"PAIR-WRAPPER denied U reached backing");
    @(negedge clk);
  end
  drop_request();
  if(axi_writes!=old_aw || slv.peek('h30000)!=32'hdeadbeef || slv.peek('h30004)!=32'hcafef00d)
    $fatal(1,"PAIR-WRAPPER SMRAM partial write");
  denied_checks++;record_writes=1;
  // Interrupt an unaccepted AR through the real AXI-only reset input, then
  // retry the still-present producer request. No internal signal is forced.
  @(negedge clk);allow_ar=0;core_req=1;core_we=0;core_addr='h6000;core_wstrb=4'hf;
  guard_n=0;
  while(!arvalid) begin
    @(negedge clk);guard_n++;
    if(guard_n>200)$fatal(1,"PAIR-WRAPPER AR never offered");
  end
  axi_only_reset=1;#1;
  if(core_ack || store_pair_ack || arvalid || awvalid || wvalid)
    $fatal(1,"PAIR-WRAPPER stale reset response");
  repeat(3)@(negedge clk);axi_only_reset=0;allow_ar=1;
  guard_n=0;
  do begin
    @(posedge clk);guard_n++;
    if(guard_n>500 || bus_err)$fatal(1,"PAIR-WRAPPER reset retry");
  end while(!core_ack);
  if(core_rdata!==expected_word('h6000))$fatal(1,"PAIR-WRAPPER reset data");
  @(negedge clk);drop_request();drain();reset_checks++;
  for(int a=0;a<65536;a++) if(slv.mem[a]!==expected_mem[a])
    $fatal(1,"PAIR-WRAPPER final RAM at %08x",a);
  if(u_stores!=65 || v_stores!=2 || quad_stores!=1 || blocked==0 || full_queue==0 || reset_checks!=1 || denied_checks!=4)
    $fatal(1,"PAIR-WRAPPER coverage U=%0d V=%0d quad=%0d blocked=%0d full=%0d reset=%0d deny=%0d",
      u_stores,v_stores,quad_stores,blocked,full_queue,reset_checks,denied_checks);
  $display("PAIR-CREDIT-WRAPPER-OK U=%0d V=%0d quad=%0d blocked=%0d full=%0d reset=%0d deny=%0d AW=%0d",
    u_stores,v_stores,quad_stores,blocked,full_queue,reset_checks,denied_checks,axi_writes);
  $finish;
  disable wrapper_test;
end
initial begin #1000000;$fatal(1,"PAIR-WRAPPER watchdog");end
