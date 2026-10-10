// Actual full-profile cache, independently checked backing memory. Never write
// DUT cache state hierarchically. A/B changes only expected reuse, not traffic.
int iw_checks=0,iw_reuses=0,iw_store_count=0;
`ifdef VEN_L1D_INDEPENDENT_WINDOW_INVALIDATE
localparam bit IW_ENABLED=1;
`else
localparam bit IW_ENABLED=0;
`endif
`ifdef IW_REQUIRE_NEW_BEHAVIOR
localparam bit IW_EXPECT=1;
`else
localparam bit IW_EXPECT=IW_ENABLED;
`endif

task automatic iw_reset;
  @(negedge clk);c_req=0;c_we=0;c_next_req=0;c_next_commit=0;c_pair_req=0;
  c_pair_wstrb=0;c_wstrb=4'hf;cacheable=1;golden=0;flush_all=0;snoop_inv_valid=0;
  c_store_update_mask=4'hf;c_pair_store_update_mask=4'hf;
  c_code=0;hold_ack=0;rst_n=0;
  repeat(3) @(negedge clk);rst_n=1;
  if(dut.window_valid_q || dut.shadow_valid_q || dut.rd_armed)
    $fatal(1,"independent windows reset retained owner");
endtask

task automatic iw_setup(input logic[31:0] shadow_addr,primary_addr);
  iw_reset();
  read_at(shadow_addr);read_at(primary_addr);
  read_at(shadow_addr);read_at(primary_addr);
  if(!dut.window_valid_q || !dut.shadow_valid_q ||
      dut.rd_addr_q[31:5]!=primary_addr[31:5] ||
      dut.shadow_line_addr_q!=shadow_addr[31:5])
    $fatal(1,"independent windows setup ownership");
endtask

task automatic iw_read(input logic[31:0] address,input bit immediate);
  @(negedge clk);c_req=1;c_we=0;c_addr=address;c_wstrb=4'hf;
  #1;
  if(c_ack!==immediate) $fatal(1,"independent shadow immediate got=%b expected=%b addr=%08x",
                             c_ack,immediate,address);
  if(immediate) begin
    if(!dut.shadow_reuse || m_req || dut.do_rd_cap || c_rdata!==word_at(address))
      $fatal(1,"independent shadow did not reuse exact old line");
    iw_reuses++;
  end
  do @(posedge clk);while(!c_ack);
  @(negedge clk);c_req=0;iw_checks++;
  while(dut.st!=dut.L1_IDLE) @(negedge clk);
endtask

task automatic iw_store(input logic[31:0] address,input logic[3:0] mask,
                        input int delay,input bit pair_store);
  int guard,old_backing;
  old_backing=backing;
  @(negedge clk);c_req=1;c_we=1;c_addr=address;c_wstrb=mask;
  c_wdata=32'h795aec13^address;hold_ack=(delay!=0);
  c_pair_req=pair_store;c_pair_addr=address+4;c_pair_wdata=32'h965ca217;c_pair_wstrb=4'hf;
  repeat(delay) begin
    @(posedge clk);if(c_ack || m_ack || c_pair_ack) $fatal(1,"blocked store acknowledged");
    @(negedge clk);
  end
  hold_ack=0;guard=0;
  do begin
    @(posedge clk);if(++guard>50)$fatal(1,"store timeout");
    if(c_ack && pair_store && !c_pair_ack)$fatal(1,"paired store lost V");
  end while(!c_ack);
  @(negedge clk);c_req=0;c_we=0;c_pair_req=0;c_pair_wstrb=0;c_wstrb=4'hf;
  if(backing!=old_backing+1)$fatal(1,"duplicate/lost U store");
  iw_store_count++;
endtask

task automatic iw_load_store(input logic[31:0] load_addr,store_addr,
                             input int delay,input logic[3:0] policy);
  int old_backing,guard;
  logic[31:0] old_value;
  old_value=word_at(load_addr);old_backing=backing;
  @(negedge clk);c_req=1;c_we=0;c_addr=load_addr;c_wstrb=4'hf;
  c_pair_req=1;c_pair_addr=store_addr;c_pair_wdata=32'h573cbda1^store_addr;
  c_pair_wstrb=4'hf;c_pair_store_update_mask=policy;hold_ack=1;
  repeat(delay) begin
    @(posedge clk);
    if(c_pair_ack || m_ack || !c_ack || c_rdata!==old_value)
      $fatal(1,"load/store wait lost old U or posted early");
    @(negedge clk);
  end
  hold_ack=0;guard=0;
  do begin
    @(posedge clk);
    if(++guard>50)$fatal(1,"load/store timeout");
    if(!c_ack || c_rdata!==old_value || dut.do_rd_cap)
      $fatal(1,"load/store changed U or recaptured on store edge");
    if(c_pair_ack && (!m_we || m_addr!=store_addr || m_pair_req))
      $fatal(1,"load/store backing owner");
  end while(!c_pair_ack);
  @(negedge clk);c_req=0;c_pair_req=0;c_pair_wstrb=0;c_pair_store_update_mask=4'hf;
  if(backing!=old_backing+1)$fatal(1,"duplicate/lost load/store V");
  iw_store_count++;
endtask

task automatic run_independent_windows;
  bit overlaps;
  logic[31:0] address;
  // The exact missing regression: primary write, unrelated shadow read.
  iw_setup('h1000,'h1040);
  iw_store('h1044,4'hf,3,0);
  if(dut.window_valid_q || dut.shadow_valid_q!==IW_EXPECT)
    $fatal(1,"PRIMARY-ONLY-STORE-LOST-SHADOW");
  iw_read('h1004,IW_EXPECT);
  read_at('h1044); // written primary must return the updated backing value

  // Every write strobe/offset, including crossing from primary into shadow.
  // Empty strobes retain existing conservative base-line invalidation.
  for(int offset=0;offset<32;offset++)
    for(int mask=0;mask<16;mask++) begin
      iw_setup('h1020,'h1000);address=32'h1000+32'(offset);overlaps=0;
      for(int lane=0;lane<4;lane++)
        if((mask & (1<<lane))!=0 && offset+lane>=32) overlaps=1;
      iw_store(address,4'(mask),offset%4,0);
      if(dut.shadow_valid_q!==(IW_EXPECT && !overlaps))
        $fatal(1,"shadow write overlap offset=%0d mask=%x",offset,mask);
      iw_read('h1024,IW_EXPECT && !overlaps);
      read_at(address); // full unaligned dword compared to independent memory
    end

  // Store to the shadow must invalidate it, independently of the primary.
  iw_setup('h1000,'h1040);iw_store('h1004,4'hf,2,0);
  if(dut.shadow_valid_q || !dut.window_valid_q)$fatal(1,"shadow-only write owner");
  iw_read('h1004,0);
  // Both U/V stores hit primary banks. Unrelated shadow survives only on.
  iw_setup('h1000,'h1040);iw_store('h1040,4'hf,4,1);
  if(dut.window_valid_q || dut.shadow_valid_q!==IW_EXPECT)
    $fatal(1,"paired primary stores lost independent shadow");
  iw_read('h1008,IW_EXPECT);read_at('h1040);read_at('h1044);

  // U reads either saved owner while V writes primary/shadow/neither. A
  // skipped cache update must invalidate the tag and cannot serve old bytes.
  for(int u_owner=0;u_owner<2;u_owner++)
    for(int v_owner=0;v_owner<3;v_owner++)
      for(int policy=0;policy<2;policy++)
        for(int delay=0;delay<4;delay++) begin
          iw_setup('h1000,'h1040);
          address=v_owner==0 ? 32'h1044 : v_owner==1 ? 32'h1004 : 32'h1084;
          iw_load_store(u_owner==0 ? 32'h1040 : 32'h1000,address,delay,
                        policy==0 ? 4'h0 : 4'hf);
          if(dut.shadow_valid_q!==((v_owner==0 && IW_EXPECT) || v_owner==2))
            $fatal(1,"load/store shadow invalidation U=%0d V=%0d policy=%0d",
                   u_owner,v_owner,policy);
          iw_read('h1008,(v_owner==0 && IW_EXPECT) || v_owner==2);
          read_at(address);
        end

  // Global cancellation retains its priority over both owners, even when the
  // same edge also names only the primary line.
  for(int reason=0;reason<4;reason++) begin
    iw_setup('h1000,'h1040);
    @(negedge clk);
    case(reason)
      0:flush_all=1;
      1:begin snoop_inv_valid=1;snoop_inv_addr='h1000;mem['h1000]^=8'ha5;end
      2:golden=1;
      3:cacheable=0;
    endcase
    iw_store('h1044,4'hf,1,0);
    if(dut.window_valid_q || dut.shadow_valid_q)$fatal(1,"global cancel retained window");
    @(negedge clk);flush_all=0;snoop_inv_valid=0;golden=0;cacheable=1;
    iw_read('h1000,0);
  end
  // A demand miss may still discard both windows. No cache-capacity increase.
  iw_setup('h1000,'h1040);read_at('h9000);
  iw_read('h1004,0);
  iw_reset();
  $display("INDEPENDENT-WINDOWS-OK checks=%0d stores=%0d immediate=%0d",
           iw_checks,iw_store_count,iw_reuses);
endtask
