int sw_checks=0,sw_stores=0,sw_immediate=0;
`ifdef VEN_L1D_STORE_WINDOW_WARM
localparam bit SW_ENABLED=1;
`else
localparam bit SW_ENABLED=0;
`endif
`ifdef SW_REQUIRE_NEW_BEHAVIOR
localparam bit SW_EXPECT=1;
`else
localparam bit SW_EXPECT=SW_ENABLED;
`endif
task automatic sw_setup;
  iw_setup('h1020,'h1000);
  // Ordinary fills/captures leave the target resident but neither saved.
  read_at('h1040);read_at('h1020);read_at('h1000);
  if(!dut.window_valid_q || !dut.shadow_valid_q ||
     dut.rd_addr_q[31:5]!=27'('h1000>>5) ||
     dut.shadow_line_addr_q!=27'('h1020>>5))$fatal(1,"store warm setup");
endtask
task automatic sw_read(input logic[31:0] address,input bit immediate);
  @(negedge clk);c_req=1;c_we=0;c_addr=address;c_wstrb=4'hf;
  #1;
  if(c_ack!==immediate)$fatal(1,"STORE-WARM-REUSE-MISSING address=%x got=%b expected=%b",address,c_ack,immediate);
  if(immediate) begin
    if(!(dut.window_reuse || dut.shadow_reuse) || m_req || dut.do_rd_cap ||
       c_rdata!==word_at(address))$fatal(1,"store warm stale line");
    sw_immediate++;
  end
  do @(posedge clk);while(!c_ack);
  @(negedge clk);c_req=0;sw_checks++;
  while(dut.st!=dut.L1_IDLE)@(negedge clk);
endtask
task automatic run_store_window_warm;
  bit crossing;
  logic[511:0] saved;
  sw_setup();wu_store('h1044,4'hf,3,0,0,4'hf,4'hf);sw_stores++;
  sw_read('h1044,SW_EXPECT);
  for(int offset=0;offset<32;offset++)for(int mask=0;mask<16;mask++)begin
    sw_setup();crossing=0;
    for(int b=0;b<4;b++)if((mask&(1<<b)) && offset+b>=32)crossing=1;
    wu_store(32'h1040+32'(offset),4'(mask),offset%4,0,0,4'hf,4'hf);sw_stores++;
    if(dut.rd_armed)$fatal(1,"store warming invented a read response");
    sw_read('h1040,SW_ENABLED && !crossing && mask!=0);
    // Check every sliding word, not only changed bytes, plus both old lines.
    for(int o=0;o<=28;o++)begin read_at(32'h1040+32'(o));sw_checks++;end
    wu_check_lines();read_at(32'h1040+32'(offset));sw_checks++;
  end
  // Every policy mask: any skipped written byte retains tag invalidation.
  for(int policy=0;policy<16;policy++)begin
    sw_setup();wu_store('h1041,4'hf,2,0,0,4'(policy),4'hf);sw_stores++;
    sw_read('h1040,SW_ENABLED && policy==15);read_at('h1041);sw_checks++;
  end
  // Nonallocating store miss and uncommitted/withdrawn write cannot create
  // a window. Neither changes existing bytes before actual ACK.
  iw_setup('h1020,'h1000);wu_store('h1044,4'hf,0,0,0,4'hf,4'hf);sw_stores++;
  if(dut.rd_addr_q[31:5]==27'('h1040>>5))$fatal(1,"store miss allocated read storage");
  sw_read('h1044,0);
  sw_setup();saved=dut.rd_window_q;
  @(negedge clk);c_req=1;c_we=1;c_addr='h1044;c_wstrb=4'hf;c_wdata=32'h172395ab;hold_ack=1;
  repeat(5)begin @(posedge clk);if(c_ack || m_ack)$fatal(1,"withdrawn warm ACK");end
  @(negedge clk);c_req=0;c_we=0;hold_ack=0;
  if(dut.rd_window_q!==saved || dut.rd_addr_q[31:5]!=27'('h1000>>5))$fatal(1,"uncommitted warm changed owner");
  sw_read('h1044,0);
  // Paired stores use independent physical bank rows; no new warm owner is
  // admitted. Existing coherent updates are still covered by the prior suite.
  sw_setup();wu_store('h1040,4'hf,2,1,'h1024,4'hf,4'hf);sw_stores++;
  sw_read('h1040,0);read_at('h1024);sw_checks++;
  for(int reason=0;reason<4;reason++)begin
    sw_setup();@(negedge clk);
    case(reason)
      0:flush_all=1;
      1:begin snoop_inv_valid=1;snoop_inv_addr='h1020;mem['h1020]^=8'h55;end
      2:golden=1;
      3:cacheable=0;
    endcase
    wu_store('h1044,4'hf,1,0,0,4'hf,4'hf);sw_stores++;
    if(dut.window_valid_q || dut.shadow_valid_q)$fatal(1,"store warming bypassed global poison");
    @(negedge clk);flush_all=0;snoop_inv_valid=0;golden=0;cacheable=1;
    sw_read('h1044,0);wu_check_lines();
  end
  iw_reset();
  $display("STORE-WARM-OK checks=%0d stores=%0d immediate=%0d",sw_checks,sw_stores,sw_immediate);
endtask
