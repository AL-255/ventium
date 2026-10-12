// Two complete L1/AXI instances, each with its own byte-addressable slave.
// All stimulus is through public request/reset/coherence ports; only backing
// RAM is seeded. No cache state, AXI credit or queue state is forced.
byte unsigned expected_mem[65536];
integer checks=0,stores=0,pairs=0,load_stores=0,blocked=0,quad=0;
integer idle_credit_changes=0,full_queue=0;
function automatic logic [31:0] expected_word(input logic[31:0] a);
  return {expected_mem[a+3],expected_mem[a+2],expected_mem[a+1],expected_mem[a]};
endfunction
always @(posedge clk) if(rst_n) begin
  if(bus_err || shadow_bus_err) $fatal(1,"BACKING-AXI bus error");
  if(master.wq_count==2) full_queue++;
  if(c_req && c_we && !c_ack) blocked++;
  if(master.wr_quad_enq) quad++;
  if(!c_req && m_pair_ready!=shadow_m_pair_ready) idle_credit_changes++;
  if(c_req && !c_we && c_ack && c_rdata!==expected_word(c_addr))
    $fatal(1,"BACKING-AXI read addr=%08x got=%08x expected=%08x",c_addr,c_rdata,expected_word(c_addr));
  if(c_req && c_we && c_ack) begin
    for(int b=0;b<4;b++) if(c_wstrb[b]) expected_mem[c_addr+b]=c_wdata[8*b+:8];
    stores++;
  end
  if(c_pair_ack) begin
    for(int b=0;b<4;b++) if(c_pair_wstrb[b]) expected_mem[c_pair_addr+b]=c_pair_wdata[8*b+:8];
    pairs++; if(!c_we)load_stores++;
  end
  checks++;
end
task automatic drain;
  integer timeout_n;
  timeout_n=0;
  while(!m_idle || !shadow_m_idle || dut.st!=dut.L1_IDLE) begin
    @(negedge clk);
    if(++timeout_n>400)$fatal(1,"BACKING-AXI drain timeout");
  end
endtask
task automatic drop_request;
  c_req=0;c_pair_req=0;c_we=0;c_pair_wstrb=0;c_wstrb=4'hf;
endtask
task automatic store_at(input logic[31:0] a,v,input bit pair_store,input logic[3:0] mask);
  integer timeout_n;
  @(negedge clk);c_req=1;c_we=1;c_addr=a;c_wdata=32'h61437bac^a;c_wstrb=mask;
  c_pair_req=pair_store;c_pair_addr=v;c_pair_wstrb=4'hf;c_pair_wdata=32'h8b927c01^v;
  timeout_n=0;
  do begin
    @(posedge clk);
    if(++timeout_n>300)$fatal(1,"BACKING-AXI store timeout");
    if(c_ack && pair_store && !c_pair_ack)$fatal(1,"BACKING-AXI lost V");
  end while(!c_ack);
  @(negedge clk);drop_request();
endtask
task automatic read_at(input logic[31:0] a,input bit cached);
  integer timeout_n;
  @(negedge clk);c_req=1;c_we=0;c_addr=a;c_wstrb=4'hf;cacheable=cached;
  timeout_n=0;
  do begin
    @(posedge clk);
    if(++timeout_n>300)$fatal(1,"BACKING-AXI read timeout");
  end while(!c_ack);
  @(negedge clk);drop_request();drain();cacheable=1;
endtask
task automatic load_store(input logic[31:0] a,v);
  integer timeout_n;
  @(negedge clk);c_req=1;c_we=0;c_addr=a;c_wstrb=4'hf;
  c_pair_req=1;c_pair_addr=v;c_pair_wstrb=4'hf;c_pair_wdata=32'h45617acf^v;
  timeout_n=0;
  do begin
    @(posedge clk);
    if(++timeout_n>300)$fatal(1,"BACKING-AXI load/store timeout");
    if(c_pair_ack && (!c_ack || m_pair_req || m_addr!=v))
      $fatal(1,"BACKING-AXI load/store ownership");
  end while(!c_pair_ack);
  @(negedge clk);drop_request();
endtask
initial begin
  for(int a=0;a<65536;a++) begin
    expected_mem[a]=8'(a^(a>>8));
    memory.mem[a]=expected_mem[a];shadow_memory.mem[a]=expected_mem[a];
  end
  repeat(4)@(negedge clk);rst_n=1;
  // One occupied slot: idle hints differ, but must not admit anything.
  store_at('h1000,0,0,4'hf);
  c_we=1;c_addr='h1020;c_pair_addr='h1024;c_wstrb=4'hf;c_pair_wstrb=4'hf;
  repeat(3)begin
    @(posedge clk);
    if(c_pair_ready || m_req || c_pair_ack || master.wq_count!=1)
      $fatal(1,"BACKING-AXI idle hint caused transaction");
    @(negedge clk);
  end
  store_at('h1020,'h1024,1,4'hf); // one-slot quad admission
  store_at('h1040,0,0,4'hf); // block while both slots occupied
  drain();
  store_at('h1060,0,0,4'hf);
  store_at('h1084,'h1088,1,4'hf); // two-slot, non-quad admission
  drain();
  // All byte enables and offsets, including split unaligned stores.
  for(int offset_n=0;offset_n<4;offset_n++)
    for(int mask_n=1;mask_n<16;mask_n++) begin
      store_at(32'h2000+32'(offset_n),0,0,4'(mask_n));
      drain();read_at('h2000,1);read_at('h2004,1);
    end
  // Registered U read and V store with no credit, then same-edge release.
  read_at('h3000,1);read_at('h3040,1);read_at('h3000,1);
  store_at('h4000,0,0,4'hf);store_at('h4020,0,0,4'hf);
  load_store('h3000,'h3044);drain();read_at('h3044,1);
  // Invalid atomic pair cannot post U; dropping the pair retries U alone.
  @(negedge clk);c_req=1;c_we=1;c_addr='h5000;c_wdata=32'h98765432;c_wstrb=4'h3;
  c_pair_req=1;c_pair_addr='h5004;c_pair_wstrb=4'hf;
  repeat(3)begin
    @(posedge clk);if(c_ack || m_req || c_pair_ack)$fatal(1,"BACKING-AXI invalid pair admitted");
    @(negedge clk);
  end
  c_pair_req=0;
  do @(posedge clk);while(!c_ack);
  @(negedge clk);drop_request();drain();
  // Unrequested out-of-window hints cannot set the master's alias fault.
  c_we=1;c_addr=32'h12345678;c_pair_addr=32'h1234567c;c_wstrb=4'hf;c_pair_wstrb=4'hf;
  repeat(3)@(negedge clk);drop_request();
  // Cache flush/snoop and uncacheable byte-exact cross-word/page-edge reads.
  flush_all=1;@(negedge clk);flush_all=0;read_at('h2000,1);
  snoop_inv_addr='h2000;snoop_inv_valid=1;@(negedge clk);snoop_inv_valid=0;
  read_at('h2000,1);read_at('h201d,0);read_at('h2fff,0);
  drain();
  for(int a=0;a<65536;a++)
    if(memory.mem[a]!==expected_mem[a] || shadow_memory.mem[a]!==expected_mem[a])
      $fatal(1,"BACKING-AXI final RAM mismatch at %08x",a);
  if(quad==0 || pairs<3 || load_stores==0 || blocked==0 || idle_credit_changes==0 || full_queue==0)
    $fatal(1,"BACKING-AXI coverage quad=%0d pair=%0d ls=%0d blocked=%0d idle=%0d full=%0d",
           quad,pairs,load_stores,blocked,idle_credit_changes,full_queue);
  $display("BACKING-AXI-OK checks=%0d stores=%0d pairs=%0d load_stores=%0d quad=%0d blocked=%0d idle_credit_changes=%0d full_queue=%0d",
           checks,stores,pairs,load_stores,quad,blocked,idle_credit_changes,full_queue);
  $finish;
end
initial begin #1000000;$fatal(1,"BACKING-AXI watchdog");end
