module tb_fe_parent_perm;
  logic clk=0, rst_n=0, flush_en=0, fill_en=0, fill_big=0, fill_dirty=0;
  logic active=1;
  logic [31:0] query=0, fill_lin=0;
  logic [19:0] fill_pfn=0;
  logic [2:0] fill_perm=0;
  logic hit, dirty, valid, child_hit, child_dirty;
  logic [31:0] phys;
  logic [19:0] child_phys;
  logic [2:0] perm, child_perm;
  int checks=0, fault_checks=0, negative_hits=0, positive_hits=0;
  logic [31:0] random_state=32'h619325dc;
  tlb_assoc #(.IS_D(1),.TLB_SETS(16),.TLB_WAYS(4),.P54_LARGE(1)) parent (
    .clk(clk),.rst_n(rst_n),.lk_lin(query),.lk_hit(hit),.lk_phys(phys),
    .lk_perm(perm),.lk_dirty(dirty),.fill_en(fill_en),.fill_lin(fill_lin),
    .fill_pfn(fill_pfn),.fill_perm(fill_perm),.fill_big(fill_big),
    .fill_dirty(fill_dirty),.flush_en(flush_en)
  );
  ven_fe_dtlb child (
    .clk(clk),.rst_n(rst_n),
`ifdef NEGATIVE_KEEP_CHILD_ON_FILL
    .invalidate(flush_en),
`else
    .invalidate(flush_en || fill_en),
`endif
    .query_page(query[31:12]),.query_valid(valid),.query_hit(child_hit),
    .query_dirty(child_dirty),.query_phys(child_phys),.query_perm(child_perm),
    .capture(active && !valid),.capture_page(query[31:12]),
    .capture_phys(phys[31:12]),.capture_hit(hit),.capture_dirty(dirty),.capture_perm(perm)
  );
  function automatic logic [31:0] rnd();
    random_state ^= random_state << 13;
    random_state ^= random_state >> 17;
    random_state ^= random_state << 5;
    return random_state;
  endfunction
  task automatic check();
    checks++;
    if (rst_n && valid) begin
      assert (child_hit == hit) else $fatal(1,"hit owner stale query=%h",query);
      if (hit) begin
        positive_hits++;
        assert ({child_phys,child_perm,child_dirty} == {phys[31:12],perm,dirty})
          else $fatal(1,"permission/payload owner stale query=%h parent=%h/%b child=%h/%b",
                      query,phys,perm,child_phys,child_perm);
        // Neither page entries nor cached result may retain access policy.
        // Sweep current U/S, W/R and WP independently while translation stays hot.
        for (int u=0;u<2;u++) for (int w=0;w<2;w++) for (int wp=0;wp<2;wp++) begin
          bit expected, got;
          expected = (u!=0 && !perm[2]) || (w!=0 && !perm[1] && (u!=0 || wp!=0));
          got = (u!=0 && !child_perm[2]) || (w!=0 && !child_perm[1] && (u!=0 || wp!=0));
          fault_checks++;
          assert (got == expected) else $fatal(1,"cached access class or WP");
        end
      end else negative_hits++;
    end
  endtask
  task automatic tick();
    clk=0; #1; check(); clk=1; #1; check(); clk=0; #1;
  endtask
  task automatic fill(input logic [31:0] lin, input logic [19:0] pfn,
                      input logic [2:0] p, input bit big, input bit d);
    fill_en=1; fill_lin=lin; fill_pfn=pfn; fill_perm=p; fill_big=big; fill_dirty=d;
    tick(); fill_en=0; tick(); tick();
  endtask
  initial begin
    tick(); rst_n=1;
    query=32'h00401000;
    // Negative result -> present RO -> RW/dirty -> supervisor-only. Same VPN,
    // different raw permissions: stale positive and negative owners both fail.
    tick(); tick();
    fill(query,20'h00801,3'b101,0,0);
    fill(query,20'h00801,3'b111,0,1);
    fill(query,20'h00901,3'b011,0,1);
    // Unrelated fills, including same-set eviction, must invalidate the child.
    for (int i=0;i<10;i++) fill(32'h01001000+32'(i)*32'h10000,20'h08000+20'(i),3'b111,0,1);
    // Large-page permission/physical overlays and later small-page allocations.
    query=32'h01423004;
    fill(32'h01400000,20'h10000,3'b101,1,0);
    for (int i=0;i<16;i++) begin query=32'h01400004+32'(i)*32'h1000; tick(); tick(); end
    fill(32'h01400000,20'h20000,3'b011,1,1);
    flush_en=1; tick(); flush_en=0; tick(); tick();
    for (int n=0;n<10000;n++) begin
      query=32'h00400000 | ((rnd()%24)<<12) | (rnd()&32'hffc);
      fill_en=(rnd()%3==0); fill_lin=32'h00400000 | ((rnd()%24)<<12);
      fill_pfn=20'(rnd()); fill_perm=3'(rnd()) | 3'b001;
      fill_big=(rnd()%13==0); fill_dirty=1'(rnd());
      flush_en=(rnd()%97==0); rst_n=(rnd()%997!=0); active=(rnd()%7!=0);
      tick(); fill_en=0; flush_en=0; rst_n=1; active=1;
      tick(); tick();
    end
    assert (checks>60000 && positive_hits>1000 && negative_hits>1000 && fault_checks>8000)
      else $fatal(1,"coverage shortfall %0d/%0d/%0d/%0d",checks,positive_hits,negative_hits,fault_checks);
    $display("FE-PARENT-PERM-OK checks=%0d positive=%0d negative=%0d access-policies=%0d",
             checks,positive_hits,negative_hits,fault_checks);
    $finish;
  end
endmodule
