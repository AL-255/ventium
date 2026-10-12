    // These conflicts deliberately exceed today's RAW producer contract.
    // They test the arbiter itself; architectural core A/B must separately
    // show that ordinary instruction traffic retains its old clocks/state.
    compare_parent = 1'b0;
    $display("[intent] reserve before request; hint returns when intent drops");
    read_word(32'h40, mem[16]);
    read_word(32'h60, mem[24]);
    wait_idle();
    @(negedge clk);
    c_req = 0; c_pair_req = 0; c_we = 0;
    explicit_intent = 0; next_hint = 1; next_commit = 1; next_address = 32'h40;
    #1;
    if (!dut.mc_lookup_prime || !dut.c_next_ready) fail("intent prime setup");
    @(posedge clk); #1;
    if (!dut.rd_armed || dut.rd_addr_q != 32'h40) fail("intent U owner missing");
    @(negedge clk);
    c_req = 1; c_addr = 32'h40; c_wstrb = 4'hf;
    c_pair_addr = 32'h44; c_pair_wstrb = 4'hf; c_pair_wdata = 32'h31415926;
    next_address = 32'h60; next_commit = 0;
    explicit_intent = 1;
    #1;
    if (!dut.rd_match || dut.mc_lookup_next || dut.c_next_ready ||
        !c_pair_ready || !c_ack || c_pair_ack || m_req)
      fail("intent without request did not reserve read bank without writing");
    explicit_intent = 0;
    #1;
    if (!dut.mc_lookup_old || !dut.c_next_ready || c_pair_ready || m_req)
      fail("dropping intent did not restore the existing hint arbitration");
    explicit_intent = 1;
    c_pair_req = 1;
    #1;
    if (!c_pair_ready || !c_pair_ack || !m_req || !c_ack ||
        dut.mc_lookup_next || dut.mc_capture_next || dut.c_next_ready)
      fail("paired store did not win shared port over unused next-read hint");
    load_store_write_base = writes;
    @(posedge clk);
    @(negedge clk);
    c_req = 0; c_pair_req = 0; explicit_intent = 0; next_hint = 0;
    if (writes != load_store_write_base + 1 || mem[17] != 32'h31415926)
      fail("intent V store missing or duplicated");
    read_word(32'h44, 32'h31415926);

    $display("[intent] bank conflict/snoop/backpressure never grant a store");
    read_word(32'h40, mem[16]); wait_idle();
    @(negedge clk);
    c_req = 0; next_hint = 1; next_commit = 1; next_address = 32'h40;
    #1;
    if (!dut.c_next_ready) fail("second intent prime setup");
    @(posedge clk); #1;
    @(negedge clk);
    c_req = 1; c_we = 0; c_addr = 32'h40; c_wstrb = 4'hf;
    c_pair_req = 1; explicit_intent = 1;
    c_pair_addr = 32'h60; c_pair_wstrb = 4'hf; c_pair_wdata = 32'hf00dbaad;
    next_address = 32'h64; next_commit = 1;
    #1;
    if (c_pair_ready || c_pair_ack || m_req || !c_ack || dut.mc_lookup_next)
      fail("intent overrode bank exclusion or lost U");
    c_pair_addr = 32'h44;
    snoop_inv_valid = 1; snoop_inv_addr = 32'h40;
    #1;
    if (c_pair_ready || c_pair_ack || m_req || c_ack || dut.mc_capture_next)
      fail("intent overrode snoop exclusion");
    snoop_inv_valid = 0;
    block_pair = 1;
    #1;
    if (!c_pair_ready || c_pair_ack || !m_req || m_ack || !c_ack ||
        dut.mc_lookup_next || dut.mc_capture_next)
      fail("intent overrode backing backpressure or blocked U");
    load_store_write_base = writes;
    @(posedge clk);
    @(negedge clk);
    c_req = 0; c_pair_req = 0; explicit_intent = 0; next_hint = 0; block_pair = 0;
    if (writes != load_store_write_base || mem[17] != 32'h31415926)
      fail("unaccepted intent mutated backing data");
    read_word(32'h44, 32'h31415926);
    if (errors == 0) $display("PAIR-INTENT-ARBITRATION-OK");
