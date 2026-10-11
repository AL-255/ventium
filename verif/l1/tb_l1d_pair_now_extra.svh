// Module-scope extension of the unchanged dual-store/coherence fixture.
// All cache state is created by ordinary backing fills and transactions.
logic extra_flush=0, extra_cacheable=1;
logic [1:0] pair_req_valid=0, pair_req_ready, pair_req_split;
logic [1:0][31:0] pair_paddr='0, pair_rsp_paddr, pair_rsp_data;
logic [1:0][1:0] pair_size_log2='0;
logic [1:0][15:0] pair_owner='0, pair_rsp_owner;
logic pair_bank_conflict;
logic [1:0] pair_rsp_valid, pair_rsp_cancel, pair_rsp_ready=0;
logic pair_now_req=0, pair_now_cacheable=1, pair_now_valid;
logic [31:0] pair_now_paddr=0, pair_now_data;
logic [1:0] pair_now_size_log2=2;
integer now_checks=0, now_returns=0, now_backpressure=0;

task automatic pair_now_probe(input integer kind);
  logic want;
  logic [31:0] value;
  @(negedge clk);
  c_req=1; c_we=0; c_pair_req=0; c_addr=32'h40; c_wstrb=4'hf;
  pair_req_valid=2'b10; pair_paddr[1]=32'h44; pair_size_log2[1]=2;
  pair_owner[1]=16'h7654; pair_now_req=1; pair_now_cacheable=1;
  pair_now_paddr=32'h44; pair_now_size_log2=2;
  want=1; value=mem[17];
  case (kind)
    1: begin // Same physical word bank, even though the line is buffered.
      pair_paddr[1]=32'h40; pair_now_paddr=32'h40; want=0;
    end
    2: begin // The last byte needs only bank seven, not another cache line.
      pair_paddr[1]=32'h5f; pair_now_paddr=32'h5f;
      pair_size_log2[1]=0; pair_now_size_log2=0;
      value={24'd0,mem[23][31:24]};
    end
    3: begin
      pair_paddr[1]=32'h5d; pair_now_paddr=32'h5d; want=0;
    end
    4: begin pair_paddr[1]=32'h48; want=0; end
    5: begin pair_size_log2[1]=0; want=0; end
    6: begin pair_now_cacheable=0; want=0; end
    7: begin pair_now_req=0; want=0; end
    default: ;
  endcase
  #1;
  if (!c_ack || pair_now_valid != want || pair_req_ready != 0)
    fail($sformatf("same-line kind=%0d ack=%b valid=%b expected=%b ready=%b",
                   kind,c_ack,pair_now_valid,want,pair_req_ready));
  if (want && pair_now_data !== value)
    fail($sformatf("same-line value kind=%0d got=%h expected=%h",kind,pair_now_data,value));
  if (m_req) fail("buffered same-line read started backing traffic");
  now_checks++; if (want) now_returns++;
  @(posedge clk); #1;
  if (|pair_rsp_valid) fail("same-line response was also enqueued");
  @(negedge clk);
  c_req=0; pair_req_valid=0; pair_now_req=0; pair_now_cacheable=1;
endtask

task automatic run_pair_now_checks;
  $display("[pair-now] primary window, exact lane/size and word-bank ownership");
  @(negedge clk);
  c_req=0; c_pair_req=0; c_we=0; c_wstrb=4'hf;
  extra_flush=1;
  @(posedge clk);
  @(negedge clk); extra_flush=0;
  // Make B resident first. The miss for A deliberately discards B's read
  // window, so the later resident B read must capture and retain A as shadow.
  read_word(32'h64,mem[25]); wait_idle();
  read_word(32'h40,mem[16]); wait_idle();
  for (integer k=0;k<8;k++) pair_now_probe(k);

`ifdef VEN_L1D_TWO_WINDOW_REUSE
  $display("[pair-now] retained shadow window supplies its own line");
  // Move the physical registered primary to a different line. The old line
  // is only a read buffer: live tags and ordinary cancellation still apply.
  read_word(32'h64,mem[25]); wait_idle();
  @(negedge clk); c_req=0;
  if (!dut.shadow_valid_q || dut.shadow_line_addr_q != (32'h40 >> 5))
    fail("ordinary reads did not create the intended shadow owner");
  pair_now_probe(0); pair_now_probe(2);
`endif

  $display("[pair-now] a held real V response excludes immediate duplicate return");
  @(negedge clk); c_req=0; pair_now_req=0; pair_req_valid=0;
  repeat (2) @(posedge clk);
  @(negedge clk);
  pair_req_valid=2'b10; pair_paddr[1]=32'h44;
  pair_size_log2[1]=2; pair_owner[1]=16'habcd; pair_rsp_ready=0;
  #1;
  if (pair_req_ready != 2'b10) fail("standalone V hit did not create held-response fixture");
  @(posedge clk); #1;
  if (pair_rsp_valid != 2'b10 || pair_rsp_data[1] !== mem[17] ||
      pair_rsp_owner[1] != 16'habcd)
    fail("held-response fixture has wrong data or owner");
  @(negedge clk); pair_req_valid=0;
  repeat (3) begin
    @(posedge clk); #1;
    if (pair_rsp_valid != 2'b10 || pair_rsp_data[1] !== mem[17] ||
        pair_rsp_owner[1] != 16'habcd) fail("backpressure lost V identity");
    now_backpressure++;
  end
  @(negedge clk);
  c_req=1; c_we=0; c_addr=32'h40; c_wstrb=4'hf;
  pair_req_valid=2'b10; pair_owner[1]=16'h7654;
  pair_now_req=1; pair_now_paddr=32'h44; pair_now_size_log2=2;
  #1;
  if (!c_ack || pair_now_valid || pair_req_ready != 0 || pair_rsp_owner[1] != 16'habcd)
    fail("live V response was overwritten or also returned immediately");
  now_checks++;
  @(posedge clk); #1;
  if (pair_rsp_owner[1] != 16'habcd) fail("blocked new owner replaced held V");
  @(negedge clk);
  c_req=0; pair_req_valid=0; pair_now_req=0; pair_rsp_ready=2'b10;
  @(posedge clk); #1;
  if (|pair_rsp_valid) fail("held response did not drain once");
  @(negedge clk); pair_rsp_ready=0;
  pair_now_probe(0);

  $display("[pair-now] snoop cancellation, fresh DMA data, flush and cacheability");
  @(negedge clk);
  c_req=1; c_addr=32'h40; pair_req_valid=2'b10;
  pair_now_req=1; pair_now_paddr=32'h44;
  pair_paddr[1]=32'h44; pair_owner[1]=16'h7654;
  snoop_inv_valid=1; snoop_inv_addr=32'h44;
  mem[17]=32'hdada_2026; // external writer, paired with its real invalidation
  #1;
  if (c_ack || pair_now_valid || pair_req_ready != 0)
    fail("snoop allowed stale same-line data or a fresh V owner");
  now_checks++;
  @(posedge clk);
  @(negedge clk);
  c_req=0; pair_req_valid=0; pair_now_req=0; snoop_inv_valid=0;
  read_word(32'h40,mem[16]); wait_idle();
  read_word(32'h44,32'hdada_2026);
  pair_now_probe(0);

  @(negedge clk);
  c_req=1; c_addr=32'h40; pair_req_valid=2'b10; pair_now_req=1;
  extra_flush=1;
  #1;
  if (c_ack || pair_now_valid || pair_req_ready != 0) fail("flush admitted a paired read");
  now_checks++;
  @(posedge clk);
  @(negedge clk);
  c_req=0; pair_req_valid=0; pair_now_req=0; extra_flush=0;
  read_word(32'h40,mem[16]); wait_idle();
  pair_now_probe(0);

  @(negedge clk);
  c_req=1; c_addr=32'h40; pair_req_valid=2'b10; pair_now_req=1;
  extra_cacheable=0;
  #1;
  if (pair_now_valid || pair_req_ready != 0) fail("uncacheable U borrowed buffered data");
  now_checks++;
  // Withdraw before a clock: this is a combinational permission probe, not
  // a fake uncached transaction that the small backing model must complete.
  c_req=0; pair_req_valid=0; pair_now_req=0; extra_cacheable=1;
  if (now_returns < 4 || now_backpressure != 3)
    fail("missing actual same-line/backpressure transaction coverage");
  $display("PAIR-NOW-CACHE-CHECKS checks=%0d returns=%0d held=%0d",
           now_checks,now_returns,now_backpressure);
endtask
