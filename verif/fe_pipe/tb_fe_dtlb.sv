module tb_fe_dtlb;
  logic clk=0, rst_n=0, invalidate=0, capture=0;
  logic [19:0] query_page=0, capture_page=0, capture_phys=0;
  logic capture_hit=0, capture_dirty=0;
  logic query_valid, query_hit, query_dirty;
  logic [19:0] query_phys;
  ven_fe_dtlb dut (.*);
  bit ref_valid[8], ref_hit[8], ref_dirty[8];
  logic [19:0] ref_page[8], ref_phys[8];
  int replacement=0, checks=0, captures=0, updates=0, evictions=0;
  int invalidations=0, reset_collisions=0, invalidate_collisions=0;
  logic [31:0] random_state=32'hce172945;

  function automatic logic [31:0] rnd();
    random_state ^= random_state << 13;
    random_state ^= random_state >> 17;
    random_state ^= random_state << 5;
    return random_state;
  endfunction
  function automatic logic [19:0] page_for(input int k);
    // Same low bits, different high bits catch truncated tags / aliases.
    return (20'(k) << 12) | 20'h003dc;
  endfunction
  task automatic check_query();
    bit v, h, d;
    logic [19:0] p;
    v=0; h=0; d=0; p=0;
    for (int i=0;i<8;i++) begin
      if (ref_valid[i] && ref_page[i] == query_page) begin
        v=1; h=ref_hit[i]; d=ref_dirty[i]; p=ref_phys[i];
      end
    end
    checks++;
    assert ({query_valid,query_hit,query_dirty,query_phys} === {v,h,d,p})
      else $fatal(1,"query mismatch page=%05x check=%0d got=%b/%b/%b/%05x expected=%b/%b/%b/%05x",
                  query_page,checks,query_valid,query_hit,query_dirty,query_phys,v,h,d,p);
  endtask
  task automatic tick();
    int slot;
    bit present;
    clk=0; #1; check_query();
    clk=1; #1;
    if (!rst_n || invalidate) begin
      foreach (ref_valid[i]) ref_valid[i]=0;
      replacement=0;
      invalidations++;
      if (capture && !rst_n) reset_collisions++;
      if (capture && invalidate) invalidate_collisions++;
    end else if (capture) begin
      slot=-1; present=0;
      for (int i=0;i<8;i++)
        if (ref_valid[i] && ref_page[i]==capture_page) begin slot=i; present=1; end
      if (slot<0) for (int i=0;i<8;i++)
        if (slot<0 && !ref_valid[i]) slot=i;
      if (slot<0) begin slot=replacement; evictions++; end
      if (present) updates++;
      else replacement=(slot+1)%8;
      ref_valid[slot]=1; ref_page[slot]=capture_page; ref_phys[slot]=capture_phys;
      ref_hit[slot]=capture_hit; ref_dirty[slot]=capture_dirty;
      captures++;
    end
    check_query();
    clk=0; #1;
  endtask
  initial begin
    tick(); rst_n=1;
    // Fill all slots; negative translations are real cached query results.
    for (int k=0;k<8;k++) begin
      capture=1; capture_page=page_for(k); capture_phys=20'h80000+20'(k);
      capture_hit=(k%3 != 0); capture_dirty=(k%2 != 0);
      query_page=capture_page; tick();
    end
    // A repeated clean->dirty / negative->hit update must not evict a sibling.
    for (int k=0;k<8;k++) begin
      capture_page=page_for(k); capture_phys=20'h30000+20'(k);
      capture_hit=1; capture_dirty=1; query_page=capture_page; tick();
    end
    capture=0;
    for (int round=0;round<100;round++)
      for (int k=0;k<8;k++) begin query_page=page_for(k); #1; check_query(); end
    // Full-cache eviction, reset and fill/flush collision priority.
    capture=1; capture_page=page_for(15); query_page=capture_page; tick();
    invalidate=1; tick(); invalidate=0; tick();
    rst_n=0; tick(); rst_n=1; tick();
    for (int n=0;n<20000;n++) begin
      query_page=page_for(int'(rnd()%24));
      capture_page=page_for(int'(rnd()%24));
      capture_phys=20'(rnd()); capture_hit=1'(rnd()); capture_dirty=1'(rnd());
      capture=(rnd()%4 != 0); invalidate=(rnd()%97 == 0); rst_n=(rnd()%997 != 0);
      tick();
      for (int k=0;k<24;k++) begin query_page=page_for(k); #1; check_query(); end
    end
    assert (checks>500000 && captures>10000 && updates>1000 && evictions>1000 &&
            reset_collisions>0 && invalidate_collisions>0)
      else $fatal(1,"coverage shortfall");
    $display("FE-DTLB-LEAF-OK checks=%0d captures=%0d updates=%0d evictions=%0d invalidations=%0d reset-collision=%0d invalidate-collision=%0d",
             checks,captures,updates,evictions,invalidations,reset_collisions,invalidate_collisions);
    $finish;
  end
endmodule
