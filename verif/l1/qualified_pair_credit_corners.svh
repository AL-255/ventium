// Included after the existing port tasks and byte-addressed RAM scoreboard.
integer quad_release=0, split_release=0, deny_release=0, error_release=0;
integer shutdown_checks=0;
bit checking_denied=0, checking_error=0;
always @(posedge clk) if(rst_n && !axi_only_reset) begin
  if(dut.u_axi.wq_head_release && dut.u_axi.wr_quad_enq && dut.u_axi.wq_count==2)
    quad_release++;
  if(dut.u_axi.wq_head_release && dut.u_axi.wr_pair_enq && dut.u_axi.wq_count==1)
    split_release++;
  if(checking_denied && dut.u_axi.wq_head_release) begin
    if(dut.axm_req || dut.axm_pair_req || store_pair_ack || !core_ack)
      $fatal(1,"PAIR-CORNERS denied pair reached released slot");
    deny_release++;
  end
  if(checking_error && bvalid && bready) begin
    if(!dut.u_axi.wq_head_release || !bus_err || core_ack || store_pair_ack ||
       dut.u_axi.wr_enq || dut.axm_pair_req)
      $fatal(1,"PAIR-CORNERS same-edge B error admitted pair");
    error_release++;
  end
  if(shutdown && (dut.u_axi.wr_enq || dut.u_axi.wr_pair_enq || dut.u_axi.wr_quad_enq))
    $fatal(1,"PAIR-CORNERS shutdown admitted backing write");
end

task automatic reset_ports;
  @(negedge clk);rst_n=0;drop_request();shutdown=0;inject_b_error=0;
  checking_denied=0;checking_error=0;record_writes=1;
  repeat(4)@(negedge clk);rst_n=1;repeat(4)@(negedge clk);
endtask
task automatic present_pair(input logic[31:0] addr,vaddr);
  core_req=1;core_we=1;core_addr=addr;core_wdata=32'h61437bac^addr;core_wstrb=4'hf;
  store_pair_req=1;store_pair_addr=vaddr;store_pair_wdata=32'h8b927c01^vaddr;store_pair_wstrb=4'hf;
endtask
task automatic wait_b;
  integer guard_n;
  guard_n=0;
  while(!bvalid) begin
    @(negedge clk);guard_n++;
    if(guard_n>200)$fatal(1,"PAIR-CORNERS B never offered");
  end
endtask

initial begin : corner_test
  integer old_aw,old_u,old_v,guard_n;
  for(int a=0;a<65536;a++) begin
    expected_mem[a]=8'(a^(a>>8));slv.mem[a]=expected_mem[a];
  end
  slv.poke('h30000,32'hdeadbeef);slv.poke('h30004,32'hcafef00d);
  reset_ports();

  // Full queue: an aligned pair consumes exactly the slot released by B.
  store_at('h1000,0,0,4'hf);store_at('h1020,0,0,4'hf);
  if(dut.u_axi.wq_count!=2)$fatal(1,"PAIR-CORNERS quad precondition not full");
  store_at('h1040,'h1044,1,4'hf);drain();
  if(quad_release!=1)$fatal(1,"PAIR-CORNERS no same-edge quad reuse");

  // One occupied slot: a non-combinable pair must wait for its B, then
  // allocate both slots atomically on that same edge.
  store_at('h1080,0,0,4'hf);
  if(dut.u_axi.wq_count!=1)$fatal(1,"PAIR-CORNERS split precondition");
  store_at('h10a4,'h10a8,1,4'hf);drain();
  if(split_release!=1)$fatal(1,"PAIR-CORNERS no same-edge split reuse");

  // A U/V SMRAM-denied transaction coincides with a real previous B release.
  store_at('h10c0,0,0,4'hf);wait_b();
  old_aw=axi_writes;record_writes=0;checking_denied=1;
  present_pair('h30000,'h30004);
  @(posedge clk);@(negedge clk);drop_request();checking_denied=0;record_writes=1;
  drain();
  if(deny_release!=1 || axi_writes!=old_aw || slv.peek('h30000)!=32'hdeadbeef ||
     slv.peek('h30004)!=32'hcafef00d)$fatal(1,"PAIR-CORNERS denied release RAM");

  // Externally supplied error on that releasing B must override available
  // credit before the pending non-combinable pair can be acknowledged.
  store_at('h10e0,0,0,4'hf);
  @(negedge clk);present_pair('h1104,'h1108);
  wait_b();inject_b_error=1;checking_error=1;#1;
  if(!bus_err || core_ack || store_pair_ack || dut.u_axi.wr_enq)
    $fatal(1,"PAIR-CORNERS B error not immediate");
  old_aw=axi_writes;old_u=u_stores;old_v=v_stores;
  @(posedge clk);@(negedge clk);checking_error=0;inject_b_error=0;
  repeat(8) begin
    @(posedge clk);
    if(!bus_err || core_ack || store_pair_ack || dut.u_axi.wr_enq)
      $fatal(1,"PAIR-CORNERS B error not sticky");
    @(negedge clk);
  end
  drop_request();
  if(error_release!=1 || axi_writes!=old_aw || u_stores!=old_u || v_stores!=old_v)
    $fatal(1,"PAIR-CORNERS errored pair changed ownership");
  // A coupled reset clears the error; a real pair works afterwards.
  reset_ports();store_at('h1120,'h1124,1,4'hf);drain();

  // Shutdown drains an already-owned write but never enqueues a new pair.
  // Its documented idle local ACK does not constitute a DDR write. Reset
  // before resuming normal operation: shutdown is a terminal quiesce path.
  store_at('h1140,0,0,4'hf);
  @(negedge clk);shutdown=1;record_writes=0;present_pair('h1160,'h1164);
  if(m_idle)$fatal(1,"PAIR-CORNERS shutdown had nothing to drain");
  old_aw=axi_writes;guard_n=0;
  while(!m_idle) begin
    #1;
    if(core_ack || store_pair_ack || dut.u_axi.wr_enq)
      $fatal(1,"PAIR-CORNERS shutdown ACK before drain");
    @(negedge clk);guard_n++;
    if(guard_n>200)$fatal(1,"PAIR-CORNERS shutdown did not drain");
  end
  #1;
  if(!core_ack || !store_pair_ack || dut.u_axi.wr_enq || awvalid || wvalid || arvalid)
    $fatal(1,"PAIR-CORNERS shutdown idle response");
  @(posedge clk);@(negedge clk);drop_request();
  if(axi_writes!=old_aw)$fatal(1,"PAIR-CORNERS shutdown started new AW");
  shutdown_checks++;
  reset_ports();store_at('h1180,'h1184,1,4'hf);drain();

  for(int a=0;a<65536;a++) if(slv.mem[a]!==expected_mem[a])
    $fatal(1,"PAIR-CORNERS final RAM at %08x got=%02x expected=%02x",a,slv.mem[a],expected_mem[a]);
  if(quad_release!=1 || split_release!=1 || deny_release!=1 || error_release!=1 || shutdown_checks!=1)
    $fatal(1,"PAIR-CORNERS missing boundary coverage");
  $display("PAIR-CREDIT-CORNERS-OK quad_release=%0d split_release=%0d deny_release=%0d error_release=%0d shutdown=%0d U=%0d V=%0d AW=%0d",
    quad_release,split_release,deny_release,error_release,shutdown_checks,u_stores,v_stores,axi_writes);
  $finish;
end
initial begin #1000000;$fatal(1,"PAIR-CORNERS watchdog");end
