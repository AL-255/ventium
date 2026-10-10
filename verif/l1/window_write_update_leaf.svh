// Ordinary transactions only: independent byte memory is the data oracle.
// The shared setup helpers never write internal cache state.
int wu_checks=0, wu_stores=0, wu_immediate=0;
`ifdef VEN_L1D_WINDOW_WRITE_UPDATE
localparam bit WU_ENABLED=1;
`else
localparam bit WU_ENABLED=0;
`endif
`ifdef WU_REQUIRE_NEW_BEHAVIOR
localparam bit WU_EXPECT=1;
`else
localparam bit WU_EXPECT=WU_ENABLED;
`endif

task automatic wu_read(input logic[31:0] address,input bit immediate);
  @(negedge clk);c_req=1;c_we=0;c_addr=address;c_wstrb=4'hf;
  #1;
  if(c_ack!==immediate)
    $fatal(1,"WRITE-UPDATE-REUSE-MISSING addr=%08x got=%b expected=%b",address,c_ack,immediate);
  if(immediate) begin
    if(!(dut.window_reuse || dut.shadow_reuse) || m_req || dut.do_rd_cap ||
       c_rdata!==word_at(address)) $fatal(1,"write update stale saved bytes");
    wu_immediate++;
  end
  do @(posedge clk);while(!c_ack);
  @(negedge clk);c_req=0;wu_checks++;
  while(dut.st!=dut.L1_IDLE) @(negedge clk);
endtask

task automatic wu_store(input logic[31:0] address,input logic[3:0] mask,
                        input int delay,input bit paired,input logic[31:0] vaddr,
                        input logic[3:0] policy,vpolicy);
  int old_backing,guard;
  logic[511:0] old_primary;
  logic[255:0] old_shadow;
  old_primary=dut.rd_window_q;old_shadow=dut.shadow_line_q;old_backing=backing;
  @(negedge clk);c_req=1;c_we=1;c_addr=address;c_wstrb=mask;
  c_wdata=32'h79a5ec13^address^32'(wu_stores);hold_ack=1;
  c_pair_req=paired;c_pair_addr=vaddr;c_pair_wdata=32'h96ca5217^vaddr;
  c_pair_wstrb=paired ? 4'hf : 4'h0;
  c_store_update_mask=policy;c_pair_store_update_mask=vpolicy;
  repeat(delay) begin
    @(posedge clk);
    if(c_ack || m_ack || c_pair_ack) $fatal(1,"write update posted early");
    @(negedge clk);
    if(dut.rd_window_q!==old_primary || dut.shadow_line_q!==old_shadow)
      $fatal(1,"write update modified bytes before ACK");
  end
  hold_ack=0;guard=0;
  do begin
    @(posedge clk);if(++guard>80)$fatal(1,"write update store timeout");
    if(c_ack && paired && !c_pair_ack)$fatal(1,"write update lost V store");
  end while(!c_ack);
  @(negedge clk);c_req=0;c_we=0;c_pair_req=0;c_pair_wstrb=0;c_wstrb=4'hf;
  c_store_update_mask=4'hf;c_pair_store_update_mask=4'hf;
  if(backing!=old_backing+1)$fatal(1,"write update lost/duplicated backing U");
  wu_stores++;
endtask

task automatic wu_check_lines;
  for(int offset=0;offset<=28;offset++) begin
    read_at(32'h1000+32'(offset));read_at(32'h1020+32'(offset));
    wu_checks+=2;
  end
endtask

task automatic run_window_write_update;
  logic[31:0] address,uaddr,vaddr;
  logic[511:0] old_primary;
  logic[255:0] old_shadow;
  bit crossing,u_drop,v_drop;
  // Required-failure control: an acknowledged same-line store used to discard
  // this complete owner. The on variant must return fresh bytes immediately.
  iw_setup('h1020,'h1000);
  wu_store('h1004,4'hf,3,0,0,4'hf,4'hf);
  wu_read('h1004,WU_EXPECT);
  wu_check_lines();

  // Every offset/strobe, both saved owners, with variable backing stalls.
  // First-line and crossing invalidations use actual written byte extents.
  for(int owner=0;owner<2;owner++)
    for(int offset=0;offset<32;offset++)
      for(int mask=0;mask<16;mask++) begin
        iw_setup('h1020,'h1000);crossing=0;
        for(int b=0;b<4;b++) if((mask & (1<<b)) && offset+b>=32)crossing=1;
        address=(owner==0 ? 32'h1000 : 32'h1020)+32'(offset);
        wu_store(address,4'(mask),offset%4,0,0,4'hf,4'hf);
        wu_read(owner==0 ? 32'h1000 : 32'h1020,WU_ENABLED && !crossing);
        wu_check_lines();read_at(address);wu_checks++;
      end

  // All U/V owner combinations and partial update policies. V's distinct
  // bank uses its own physical tag; neither owner may borrow the other's row.
  for(int u_owner=0;u_owner<3;u_owner++)
    for(int v_owner=0;v_owner<3;v_owner++)
      for(int policy=0;policy<4;policy++) begin
        iw_setup('h1020,'h1000);
        uaddr=u_owner==0 ? 32'h1000 : u_owner==1 ? 32'h1020 : 32'h1040;
        vaddr=v_owner==0 ? 32'h1004 : v_owner==1 ? 32'h1024 : 32'h1044;
        u_drop=(policy & 1)!=0;v_drop=(policy & 2)!=0;
        wu_store(uaddr,4'hf,policy,1,vaddr,u_drop ? 4'h5 : 4'hf,v_drop ? 4'ha : 4'hf);
        if(dut.window_valid_q !==
            ((u_owner!=0 || (WU_ENABLED && !u_drop)) &&
             (v_owner!=0 || (WU_ENABLED && !v_drop))))
          $fatal(1,"paired primary preservation U=%0d V=%0d policy=%0d",u_owner,v_owner,policy);
        if(dut.shadow_valid_q !==
            ((u_owner!=1 || (WU_ENABLED && !u_drop)) &&
             (v_owner!=1 || (WU_ENABLED && !v_drop))))
          $fatal(1,"paired shadow preservation U=%0d V=%0d policy=%0d",u_owner,v_owner,policy);
        wu_check_lines();read_at(uaddr);read_at(vaddr);wu_checks+=2;
      end

  // A held older load must retain its value while the younger V store waits.
  // V may update either window or a nonresident line. No new read capture.
  for(int u_owner=0;u_owner<2;u_owner++)
    for(int v_owner=0;v_owner<3;v_owner++)
      for(int policy=0;policy<3;policy++)
        for(int delay=0;delay<4;delay++) begin
          iw_setup('h1020,'h1000);
          address=v_owner==0 ? 32'h1004 : v_owner==1 ? 32'h1024 : 32'h1044;
          iw_load_store(u_owner==0 ? 32'h1000 : 32'h1020,address,delay,
                        policy==0 ? 4'h0 : policy==1 ? 4'h5 : 4'hf);
          wu_stores++;
          if(dut.window_valid_q!==(v_owner!=0 || (WU_ENABLED && policy==2)) ||
             dut.shadow_valid_q!==(v_owner!=1 || (WU_ENABLED && policy==2)))
            $fatal(1,"load/store owner preservation");
          wu_check_lines();read_at(address);wu_checks++;
        end

  // Aborted stores change neither backing memory nor saved bytes. Never
  // convert merely presenting a request into a committed store.
  for(int owner=0;owner<2;owner++) begin
    iw_setup('h1020,'h1000);old_primary=dut.rd_window_q;old_shadow=dut.shadow_line_q;
    address=owner==0 ? 32'h1004 : 32'h1024;
    @(negedge clk);c_req=1;c_we=1;c_addr=address;c_wstrb=4'hf;
    c_wdata=~word_at(address);hold_ack=1;
    repeat(4) begin @(posedge clk);if(c_ack || m_ack)$fatal(1,"withdrawn store ACK");end
    @(negedge clk);c_req=0;c_we=0;hold_ack=0;
    if(dut.rd_window_q!==old_primary || dut.shadow_line_q!==old_shadow)
      $fatal(1,"withdrawn store corrupted bytes");
    wu_read(address,WU_ENABLED);wu_check_lines();
  end

  // Global invalidation remains authoritative even on a same-line write.
  for(int reason=0;reason<4;reason++) begin
    iw_setup('h1020,'h1000);
    @(negedge clk);
    case(reason)
      0:flush_all=1;
      1:begin snoop_inv_valid=1;snoop_inv_addr='h1020;mem['h1020]^=8'ha5;end
      2:golden=1;
      3:cacheable=0;
    endcase
    wu_store('h1004,4'hf,1,0,0,4'hf,4'hf);
    if(dut.window_valid_q || dut.shadow_valid_q)$fatal(1,"write update bypassed global poison");
    @(negedge clk);flush_all=0;snoop_inv_valid=0;golden=0;cacheable=1;
    wu_read('h1004,0);wu_check_lines();
  end
  iw_setup('h1020,'h1000);read_at('h9000);wu_read('h1004,0);
  iw_reset();
  $display("WINDOW-WRITE-UPDATE-OK checks=%0d stores=%0d immediate=%0d",
           wu_checks,wu_stores,wu_immediate);
endtask
