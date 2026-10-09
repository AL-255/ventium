// Appended after the existing chain/cache ownership checks. No forced state.
    read_at('h1000); read_at('h1024);
    prime_only('h1000);
    c_req=1; c_addr='h1000; c_we=0; c_wstrb=4'hf;
    pair_req_valid=2'b10; pair_paddr[1]='h1024; pair_size_log2[1]=2;
    pair_owner[1]=16'h1234; pair_rsp_ready=0;
    pair_now_req=1; pair_now_paddr='h1024; pair_now_size_log2=2;
    #1;
    if (!c_ack || !dut.rd_match || pair_req_ready[1] || pair_now_valid)
      $fatal(1,"primed U retirement would orphan a registered V");
    @(posedge clk); @(negedge clk);
    c_req=0; pair_req_valid=0; pair_now_req=0;
    #1;
    if (pair_rsp_valid!=0) $fatal(1,"orphaned delayed V survived U retirement");
    repeat(2) @(negedge clk);

    // Immediate same-line pairing is retained; no bank response is enqueued.
    prime_only('h1000);
    c_req=1; c_addr='h1000;
    pair_req_valid=2'b10; pair_paddr[1]='h1004;
    pair_now_req=1; pair_now_paddr='h1004;
    #1;
    if (!c_ack || !pair_now_valid || pair_now_data!==word_at('h1004) || pair_req_ready[1])
      $fatal(1,"same-line primed U/V pair was suppressed/double-enqueued");
    @(posedge clk); @(negedge clk);
    c_req=0; pair_req_valid=0; pair_now_req=0;
    #1;
    if (pair_rsp_valid!=0) $fatal(1,"immediate pair left a delayed V");
    repeat(2) @(negedge clk);

    // A true fresh registered U still lends a different bank to V.
    read_at('h3040); read_at('h3860);
    @(negedge clk);
    c_req=1; c_addr='h1000; pair_req_valid=2'b10; pair_paddr[1]='h1024;
    #1;
    if (c_ack || !dut.pair_legacy_capture || !pair_req_ready[1])
      $fatal(1,"fresh registered U/V capture was suppressed");
    @(posedge clk); @(negedge clk); pair_req_valid=0;
    #1;
    if (!c_ack || c_rdata!==word_at('h1000) || pair_rsp_valid!=2'b10 ||
        pair_rsp_data[1]!==word_at('h1024) || pair_rsp_owner[1]!=16'h1234)
      $fatal(1,"fresh registered pair lost owner/data");
    @(posedge clk); @(negedge clk); c_req=0; pair_rsp_ready=2'b11;
    repeat(3) @(negedge clk);
    if (pair_rsp_valid!=0) $fatal(1,"pair drain leaked a response");
    $display("PRIME-PAIR-OWNER-LEAF-OK checks=3");
