// Public-port traffic only. The shared memory checker observes every ACK.
int rp_duplicates=0, rp_lookaheads=0, rp_partial=0;
always @(posedge clk) if (rst_n && c_req && !c_we && c_ack) begin
  if (dut.rd_match && dut.shadow_reuse) rp_duplicates++;
  if (dut.rd_match && dut.mc_lookup_next) rp_lookaheads++;
end

task automatic run_response_payload;
  int prior_duplicates;
  // Make duplicate primary/shadow physical owners through actual chained
  // captures, then remove lookahead and serve the exact registered owner.
  // Arbitrary next misses while that owner is held must not choose its data.
  for (int offset=0; offset<29; offset++) begin
    iw_setup('h1000,'h1040);
    arm_old('h1000);
    c_next_req=1; c_next_commit=1; c_next_addr=32'h1000+32'(offset);
    @(posedge clk);
    if (!c_ack || !c_next_ready) $fatal(1,"RESPONSE-PAYLOAD duplicate capture");
    @(negedge clk); c_addr=c_next_addr; c_next_req=0; c_next_commit=0;
    prior_duplicates=rp_duplicates;
    @(posedge clk);
    if (!c_ack || !dut.rd_match || !dut.shadow_reuse)
      $fatal(1,"RESPONSE-PAYLOAD duplicate was not exercised");
    @(negedge clk); c_req=0;
    if (rp_duplicates<=prior_duplicates) $fatal(1,"RESPONSE-PAYLOAD duplicate count");
    read_at(32'h1000+32'(28-offset));
    // A rejected next miss conservatively invalidates reusable windows, so
    // exercise it separately rather than assuming those windows survive it.
    arm_old(32'h1000+32'(offset));
    c_next_req=1; c_next_addr='h8000; c_next_commit=0;
    repeat (3) begin
      @(posedge clk);
      if (!c_ack || !dut.rd_match || c_next_ready || m_req)
        $fatal(1,"RESPONSE-PAYLOAD rejected next changed old owner");
      @(negedge clk);
    end
    c_next_req=0; c_req=0;
  end

  // A V bank capture can make U's saved line partial. U's owned dword must
  // still match the old complete shadow, even though other bank data differ.
  for (int bank=0; bank<8; bank++) begin
    iw_setup('h1000,'h1040);
    arm_old('h1000);
    c_req=0; c_next_req=0; c_next_commit=0;
    @(posedge clk); @(negedge clk); // release the old registered owner
    // Present a resident line outside both saved windows, with one V bank
    // reserved in another line. Use the profile's actual legacy-capture path.
    c_req=1; c_addr=32'h1040+32'(bank*4);
    pair_req_valid=2'b10; pair_paddr[1]=32'h1000+32'(((bank+1)%8)*4);
    pair_size_log2[1]=2'd2; pair_owner[1]=16'(bank+100);
    #1;
    if (!dut.pair_legacy_capture || !pair_req_ready[1] || !dut.do_rd_cap)
      $fatal(1,"RESPONSE-PAYLOAD partial capture not admitted");
    @(posedge clk); @(negedge clk);
    c_req=1; pair_req_valid=0;
    #1;
    if (!c_ack || !dut.rd_match || dut.rd_full_line_q ||
        !pair_rsp_valid[1] || pair_rsp_data[1]!==word_at(pair_paddr[1]))
      $fatal(1,"RESPONSE-PAYLOAD partial U/V owner data");
    rp_partial++;
    @(posedge clk); @(negedge clk); c_req=0;
    read_at('h1004); read_at('h1044);
  end
  if (rp_duplicates<29 || rp_lookaheads<87 || rp_partial!=8)
    $fatal(1,"RESPONSE-PAYLOAD missing ownership coverage");
  iw_reset();
  $display("RESPONSE-PAYLOAD-OK duplicates=%0d lookaheads=%0d partial=%0d",
           rp_duplicates,rp_lookaheads,rp_partial);
endtask
