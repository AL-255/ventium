`timescale 1ns/1ps
module tb_fe_banked #(
  parameter int SETTLE = 1,
  parameter int START_DELAY = 0,
  parameter bit INITIAL_PORT_TRANSITIONS = 0
);
  logic clk=0, rst_n=0, invalidate=0, capture=0;
  logic [19:0] query_page=0, capture_page=0, capture_phys=0;
  logic capture_hit=0, capture_dirty=0;
  logic [2:0] capture_perm=0, query_perm;
  logic query_valid, query_hit, query_dirty;
  logic [19:0] query_phys;
  ven_fe_dtlb dut (.*);
  bit ref_valid[16][4], ref_hit[16][4], ref_dirty[16][4];
  logic [19:0] ref_page[16][4], ref_phys[16][4];
  logic [2:0] ref_perm[16][4];
  int victim[16];
  int checks=0, updates=0, evictions=0, captures=0;
  int reset_collisions=0, invalidate_collisions=0, cross_set=0;
  logic [31:0] random_state=32'h21e944ce;
  function automatic logic [31:0] rnd();
    random_state ^= random_state << 13;
    random_state ^= random_state >> 17;
    random_state ^= random_state << 5;
    return random_state;
  endfunction
  function automatic logic [19:0] page_for(input int n);
    // Independent low set and high tag bits, including both VPN top bits.
    return 20'h80400 + 20'(n);
  endfunction
  task automatic check_query();
    bit v, h, d;
    logic [19:0] p;
    logic [2:0] perm;
    int s;
    s=int'(query_page[3:0]); v=0; h=0; d=0; p=0; perm=0;
    for (int w=0; w<4; w++)
      if (ref_valid[s][w] && ref_page[s][w] == query_page) begin
        v=1; h=ref_hit[s][w]; d=ref_dirty[s][w]; p=ref_phys[s][w]; perm=ref_perm[s][w];
      end
    checks++;
    assert ({query_valid,query_hit,query_dirty,query_phys,query_perm} === {v,h,d,p,perm})
      else $fatal(1,"banked scoreboard mismatch page=%05x check=%0d",query_page,checks);
  endtask
  task automatic tick();
    int s, slot;
    bit present;
    clk=0; #(SETTLE); check_query(); clk=1; #(SETTLE);
    if (!rst_n || invalidate) begin
      for (int k=0; k<16; k++) begin
        victim[k]=0;
        for (int w=0; w<4; w++) ref_valid[k][w]=0;
      end
      if (capture && !rst_n) reset_collisions++;
      if (capture && invalidate) invalidate_collisions++;
    end else if (capture) begin
      s=int'(capture_page[3:0]); slot=-1; present=0;
      for (int w=0; w<4; w++)
        if (ref_valid[s][w] && ref_page[s][w] == capture_page) begin slot=w; present=1; end
      if (slot<0) for (int w=0; w<4; w++)
        if (slot<0 && !ref_valid[s][w]) slot=w;
      if (slot<0) begin slot=victim[s]; evictions++; end
      if (present) updates++;
      else victim[s]=(slot+1)%4;
      ref_valid[s][slot]=1; ref_page[s][slot]=capture_page;
      ref_phys[s][slot]=capture_phys; ref_perm[s][slot]=capture_perm;
      ref_hit[s][slot]=capture_hit; ref_dirty[s][slot]=capture_dirty;
      captures++;
      if (query_page[3:0] != capture_page[3:0]) cross_set++;
    end
    check_query(); clk=0; #(SETTLE);
  endtask
  initial begin
    // Some event-based vendor LUT models never evaluate an all-zero input
    // declared at time zero until an input changes. Exercise the address
    // ports while reset is held, before the first clock or reference update.
    // No DUT state is forced, and no checked transaction changes.
    if (INITIAL_PORT_TRANSITIONS) begin
      #1; query_page='1; capture_page='1;
      #1; query_page='0; capture_page='0;
    end
    // The mapped Xilinx functional model starts with a global set/reset pulse.
    // A netlist wrapper waits for it before applying the same explicit reset
    // and scoreboard sequence; the ordinary RTL test has no startup delay.
    #(START_DELAY);
    tick(); rst_n=1;
    // The ordinary parent's complete 64-page working set must remain resident.
    for (int n=0; n<64; n++) begin
      capture=1; capture_page=page_for(n); query_page=capture_page;
      capture_phys=20'h20000+20'(n); capture_perm=3'(n);
      capture_hit=(n%3 != 0); capture_dirty=1'(n);
      tick();
    end
    capture=0;
    for (int round=0; round<10; round++)
      for (int n=0; n<64; n++) begin
        query_page=page_for(n); #(SETTLE);
        assert (query_valid) else $fatal(1,"64-page capacity retention failed page=%05x",query_page);
        check_query();
      end
    // Same-owner updates must neither duplicate tags nor rotate replacement.
    for (int n=0; n<64; n++) begin
      capture=1; capture_page=page_for(n); query_page=capture_page;
      capture_phys=20'h30000+20'(n); capture_perm=3'(7-n); capture_hit=1; capture_dirty=1;
      tick();
    end
    // A fifth same-set tag evicts only that set; other sets keep their owners.
    capture_page=page_for(64); query_page=capture_page; tick(); capture=0;
    for (int n=1; n<16; n++) begin query_page=page_for(n); #(SETTLE); check_query(); end
    // Full-tag alias: same low page bits, distinct most significant tag.
    capture=1; capture_page=page_for(1)^20'h80000; query_page=capture_page; tick();
    invalidate=1; tick(); invalidate=0; tick(); rst_n=0; tick(); rst_n=1; tick();
    for (int n=0; n<10000; n++) begin
      query_page=page_for(int'(rnd()%128)); capture_page=page_for(int'(rnd()%128));
      capture_phys=20'(rnd()); capture_perm=3'(rnd());
      capture_hit=1'(rnd()); capture_dirty=1'(rnd());
      capture=(rnd()%4!=0); invalidate=(rnd()%997==0); rst_n=(rnd()%1999!=0);
      tick();
      for (int k=0; k<128; k++) begin query_page=page_for(k); #(SETTLE); check_query(); end
    end
    assert (checks>1200000 && updates>1000 && evictions>1000 && captures>7000 &&
            reset_collisions>0 && invalidate_collisions>0 && cross_set>5000)
      else $fatal(1,"banked coverage shortfall");
    $display("FE-BANKED-LEAF-OK checks=%0d updates=%0d evictions=%0d captures=%0d cross-set=%0d reset-collision=%0d invalidate-collision=%0d",
             checks,updates,evictions,captures,cross_set,reset_collisions,invalidate_collisions);
    $finish;
  end
endmodule
