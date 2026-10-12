// Called after a public flush. Saved windows are not live one-cycle response
// owners: stage an ordinary resident read and consume it on the next edge.
// Never deposit DUT state, force a hit, or keep an owner beyond its lifetime.
integer overlap_checks=0, overlap_returns=0, overlap_held=0;
task automatic run_overlap_checks;
  warm_full_window(32'h80,mem[32]);
  warm_full_window(32'h64,mem[25]);
  warm_full_window(32'h40,mem[16]);
  // 0x80 is resident, but neither saved window holds it after the two misses.
  // This request must capture a registered response rather than bypass it.
  @(negedge clk);
  c_req=1; c_we=0; c_pair_req=0; c_addr=32'h80; c_wstrb=4'hf;
  pair_req_valid=0; pair_rsp_ready=0;
  #1;
  if (c_ack || !dut.do_rd_cap_legacy || !dut.rd_hit)
    $fatal(1,"OVERLAP-FIXTURE: ordinary resident read did not stage a response");
  @(posedge clk); #1;
  if (!dut.rd_armed || dut.rd_addr_q != 32'h80 || !c_ack)
    $fatal(1,"OVERLAP-FIXTURE: missing one-cycle registered U response");
  @(negedge clk);
  c_addr=32'h64;
  pair_req_valid=2'b11; pair_paddr[0]=32'h50; pair_paddr[1]=32'h54;
  pair_size_log2[0]=2; pair_size_log2[1]=2;
  pair_owner[0]=16'h1111; pair_owner[1]=16'h2222; pair_rsp_ready=0;
  #1;
  if (!dut.rd_armed || dut.rd_match) fail("overlap fixture lost unmatched held U");
  if (pair_req_ready != 0) fail("unmatched current U admitted unrelated pair");
  overlap_checks++;
  // Retarget before the SAME sampling edge. Waiting another cycle would
  // discard rd_armed, testing the wrong ownership state. The #2 gap also
  // lets the independent old/new cache miter observe the denied probe.
  #2; c_addr=32'h80;
  #1;
  if (!dut.rd_match || !c_ack || pair_req_ready != 2'b11)
    fail("owned read consumption did not lend independent banks");
  if (m_req) fail("resident overlapping pair issued backing traffic");
  overlap_checks++;
  @(posedge clk); #1;
  if (pair_rsp_valid != 2'b11 || pair_rsp_data[0] !== mem[20] ||
      pair_rsp_data[1] !== mem[21] || pair_rsp_paddr[0] != 32'h50 ||
      pair_rsp_paddr[1] != 32'h54 || pair_rsp_owner != 32'h2222_1111)
    fail("overlap returned wrong data/address/owners");
  overlap_returns+=2;
  @(negedge clk); c_req=0; pair_req_valid=0;
  repeat(3) begin
    @(posedge clk); #1;
    if (pair_rsp_valid != 2'b11 || pair_rsp_data[0] !== mem[20] ||
        pair_rsp_data[1] !== mem[21] || pair_rsp_owner != 32'h2222_1111)
      fail("overlap backpressure changed a retained response");
    overlap_held++;
  end
  @(negedge clk); pair_rsp_ready=2'b11;
  @(posedge clk); #1;
  if (pair_rsp_valid) fail("overlap responses did not drain exactly once");
  @(negedge clk); pair_rsp_ready=0;
  overlap_checks++;
  $display("PAIR-OVERLAP-CACHE-OK checks=%0d returns=%0d held=%0d",
           overlap_checks,overlap_returns,overlap_held);
  // Let the pre-existing same-line corpus establish its own cold windows.
  extra_flush=1;
  @(posedge clk);
  @(negedge clk); extra_flush=0;
endtask
