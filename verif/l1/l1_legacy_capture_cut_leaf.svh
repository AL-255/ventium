// Actual L1 interface stimulus, included after the existing memory-chain gate.
// Never force DUT state. Both the parent and candidate see these same pins.
  int cut_checks=0, cut_fresh=0, cut_same_bank=0, cut_held=0;
  task automatic cut_idle;
    @(negedge clk);
    c_req=0; c_we=0; c_next_req=0; c_next_commit=0;
    pair_req_valid=0; pair_rsp_ready=2'b11;
    flush_all=0; snoop_inv_valid=0; golden=0; cacheable=1;
    hold_ack=0;
`ifdef VEN_L1D_CODE_BUFFER
    c_code=0;
`endif
`ifdef VEN_P54_DUAL_STORE_PAIR
    c_pair_req=0;
`endif
    repeat(2) @(negedge clk);
    if (|pair_rsp_valid) $fatal(1,"CUT held response failed to drain");
  endtask

  task automatic cut_windows_away;
    read_at('h3040); read_at('h3860);
    repeat(2) @(negedge clk);
  endtask

  task automatic run_legacy_capture_cut;
    logic [31:0] expected;
    int expected_ready;
    cut_idle();
    read_at('h1000); read_at('h2020);
    // Every bank combination, byte/dword size, and irrelevant next COMMIT.
    // A fresh U has no old response, so next lookup MUST NOT select the mux.
    for(int ub=0;ub<8;ub++) for(int vb=0;vb<8;vb++)
      for(int narrow=0;narrow<2;narrow++) for(int hint=0;hint<4;hint++) begin
        cut_windows_away();
        c_req=1; c_we=0; c_addr='h1000+32'(4*ub)+(narrow?3:0);
        c_wstrb=narrow?4'h1:4'hf;
        c_next_req=1'(hint); c_next_commit=1'(hint>>1);
        c_next_cacheable=1; c_next_addr=(hint&2)?'h2020:'h7000;
        c_next_wstrb=4'hf;
        pair_req_valid=2'b10; pair_rsp_ready=0;
        pair_paddr[1]='h2020+32'(4*vb)+(narrow?3:0);
        pair_owner[1]=16'(cut_checks+100);
        pair_size_log2[1]=narrow?2'd0:2'd2;
        expected=narrow?{24'd0,mem[pair_paddr[1]]}:word_at(pair_paddr[1]);
        expected_ready=(ub==vb)?0:2;
        #1;
        if (c_ack || dut.mc_lookup_next || !dut.pair_legacy_capture ||
            pair_req_ready!=2'(expected_ready) ||
            pair_bank_conflict!=(ub==vb))
          $fatal(1,"CUT fresh capture bank=%0d/%0d byte=%0d hint=%0d ready=%b ack=%b",
                    ub,vb,narrow,hint,pair_req_ready,c_ack);
        @(posedge clk); #1;
        if(!c_ack || pair_rsp_valid!=2'(expected_ready))
          $fatal(1,"CUT fresh response missing");
        if(ub!=vb && (pair_rsp_owner[1]!=pair_owner[1] ||
           pair_rsp_paddr[1]!=pair_paddr[1] || pair_rsp_data[1]!=expected))
          $fatal(1,"CUT fresh V identity/value wrong");
        if(ub==vb) cut_same_bank++; else cut_fresh++;
        @(negedge clk); c_req=0; c_next_req=0; c_next_commit=0; pair_req_valid=0;
        // A full response slot must refuse another owner even on idle banks.
        if(ub!=vb) begin
          pair_req_valid=2'b10; pair_paddr[1]='h2020; pair_owner[1]=16'hdead;
        end
        repeat(3) begin
          @(posedge clk); #1;
          if(pair_rsp_valid!=2'(expected_ready) ||
             (ub!=vb && (pair_rsp_data[1]!=expected || pair_req_ready!=0)))
            $fatal(1,"CUT held response changed");
          cut_held++;
        end
        cut_idle(); cut_checks++;
      end

    // Standalone two-lane arbitration stays intact: no older legacy owner.
    for(int b=0;b<8;b++) begin
      pair_req_valid=2'b11; pair_rsp_ready=0;
      pair_paddr[0]='h1000+32'(4*b);
      pair_paddr[1]='h2020+32'(4*((b+1)%8));
      pair_size_log2={2'd2,2'd2}; pair_owner={16'h12ab,16'h34cd};
      #1;
      if(pair_req_ready!=2'b11) $fatal(1,"CUT standalone pair rejected");
      @(posedge clk); #1;
      if(pair_rsp_valid!=2'b11 || pair_rsp_owner!=pair_owner ||
         pair_rsp_data[0]!=word_at(pair_paddr[0]) ||
         pair_rsp_data[1]!=word_at(pair_paddr[1]))
        $fatal(1,"CUT standalone pair response wrong");
      @(negedge clk); pair_req_valid=0;
      // Cancellation wins on the same edge even for a held response.
      if(b%2) begin snoop_inv_valid=1; snoop_inv_addr='h1000; end
      else flush_all=1;
      #1;
      if(pair_rsp_valid!=0 || pair_rsp_cancel!=2'b11)
        $fatal(1,"CUT invalidate failed to cancel both owners");
      @(posedge clk); #1;
      if(pair_rsp_valid!=0) $fatal(1,"CUT cancelled response escaped");
      cut_idle(); read_at('h1000); read_at('h2020); cut_checks++;
    end

    // A next-read OFFER is not acceptance. Toggle predecessor commitment
    // while an independent V asks for a different bank; only the optional
    // primed-pair profile is allowed to create an owner at the commit edge.
    for(int committed=0;committed<2;committed++) begin
      cut_windows_away();
      c_next_req=1; c_next_commit=1'(committed); c_next_addr='h1000;
      c_next_wstrb=4'hf; pair_req_valid=2'b10; pair_rsp_ready=0;
      pair_paddr[1]='h2024; pair_size_log2[1]=2'd2;
      #1;
      expected_ready=0;
`ifdef VEN_P54_DUAL_LOAD_PRIME
      expected_ready=committed?2:0;
`endif
      if(!c_next_ready || pair_req_ready!=2'(expected_ready))
        $fatal(1,"CUT next-offer commitment policy changed");
      @(posedge clk); #1;
      if(pair_rsp_valid!=2'(expected_ready))
        $fatal(1,"CUT speculative/orphan V created");
      cut_idle(); cut_checks++;
    end

    // A store grants no younger read owner until the backing accepts U.
    // Check both different-bank overlap and equal-bank rejection, including
    // the hardware profile where this optional store/read feature is OFF.
    for(int b=0;b<8;b++) for(int same=0;same<2;same++) begin
      cut_windows_away();
      c_req=1; c_we=1; c_addr='h1000+32'(4*b); c_wstrb=4'hf;
      c_wdata=32'haabb0000+32'(b); hold_ack=1;
      pair_req_valid=2'b10; pair_rsp_ready=0; pair_size_log2[1]=2'd2;
      pair_paddr[1]='h2020+32'(4*(same?b:((b+1)%8)));
      expected=word_at(pair_paddr[1]);
      repeat(3) begin
        #1;
        if(c_ack || pair_req_ready!=0 || pair_rsp_valid!=0)
          $fatal(1,"CUT V captured before backing accepted U store");
        @(negedge clk);
      end
      hold_ack=0;
      #1;
      while(!c_ack) begin @(negedge clk); #1; end
      expected_ready=0;
`ifdef VEN_P54_STORE_LOAD_PAIR
      expected_ready=same?0:2;
`endif
      if(pair_req_ready!=2'(expected_ready)) $fatal(1,"CUT store/read admission changed");
      @(posedge clk); #1;
      if(pair_rsp_valid!=2'(expected_ready) ||
         (expected_ready!=0 && pair_rsp_data[1]!=expected))
        $fatal(1,"CUT store/read returned wrong V");
      cut_idle(); cut_checks++;
    end
    $display("L1-LEGACY-CAPTURE-CUT-OK checks=%0d fresh=%0d same_bank=%0d held=%0d",
             cut_checks,cut_fresh,cut_same_bank,cut_held);
  endtask
