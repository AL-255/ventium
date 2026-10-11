`timescale 1ns/1ps
// Real L1 sequential reset/owner tests. A reset aborts the upstream and backing
// session together; it must not roll back an already acknowledged RAM write.
module tb_fp_read_ack_reset;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  logic c_req=0, c_we=0, c_ack, c_read_ack;
  logic [31:0] c_addr=0, c_wdata=0, c_rdata;
  logic [3:0] c_wstrb=4'hf;
  logic m_req, m_we, m_ack, m_rd_narrow, ack_block=0;
  logic [31:0] m_addr, m_wdata, m_rdata;
  logic [3:0] m_wstrb;
  logic [1:0] m_rd_size;
  logic stream=0, stream_ready=0, request_ready, response_valid, response_cancel;
  logic [31:0] response_addr;
  int delay_setting=0, delay_count=0;
  int reads=0, writes=0, backing_reads=0, resets=0, comparisons=0;
  int abandoned_fills=0, aborted_hits=0, aborted_stores=0, consumed_streams=0;
  byte unsigned mem[65536];

  ven_l1d dut(
    .clk(clk), .rst_n(rst_n), .flush_all(1'b0), .golden(1'b0),
    .cacheable(1'b1), .snoop_inv_valid(1'b0), .snoop_inv_addr(32'd0),
    .c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_wdata(c_wdata),
    .c_wstrb(c_wstrb), .c_rdata(c_rdata), .c_ack(c_ack),
`ifdef READ_ACK_PORT
    .c_read_ack(c_read_ack),
`endif
`ifdef VEN_L1D_CODE_BUFFER
    .c_code(1'b0),
`endif
`ifdef VEN_L1D_STORE_POLICY
    .c_store_update_mask(4'hf),
`endif
`ifdef VEN_PIPE_MEM_CHAIN
    .c_next_req(1'b0), .c_next_commit(1'b0), .c_next_cacheable(1'b0),
    .c_next_addr(32'd0), .c_next_wstrb(4'd0), .c_next_ready(),
`endif
`ifdef VEN_FP_LOAD64
    .c_rdata_hi(), .c_rdata_hi_valid(),
`endif
`ifdef VEN_L1D_HIT_STREAM
    .c_hit_stream(stream), .c_req_ready(request_ready),
    .c_rsp_valid(response_valid), .c_rsp_ready(stream_ready),
    .c_rsp_addr(response_addr), .c_rsp_cancel(response_cancel),
`endif
`ifdef VEN_P54_DUAL_STORE_PAIR
    .c_pair_req(1'b0), .c_pair_addr(32'd0), .c_pair_wdata(32'd0),
    .c_pair_wstrb(4'd0), .c_pair_ready(), .c_pair_ack(),
`ifdef VEN_L1D_STORE_POLICY
    .c_pair_store_update_mask(4'hf),
`endif
    .m_pair_req(), .m_pair_addr(), .m_pair_wdata(), .m_pair_wstrb(),
    .m_pair_ready(1'b1), .m_pair_ack(1'b0),
`endif
`ifdef VEN_P54_DUAL_HIT
    .pair_req_valid(2'b0), .pair_cacheable(2'b0), .pair_paddr(64'b0),
    .pair_size_log2(4'b0), .pair_owner(32'b0), .pair_req_ready(),
    .pair_req_split(), .pair_bank_conflict(), .pair_rsp_valid(),
    .pair_rsp_cancel(), .pair_rsp_ready(2'b0), .pair_rsp_owner(),
    .pair_rsp_paddr(), .pair_rsp_data(),
`ifdef VEN_P54_DUAL_BYTE_LOAD_PAIR
    .pair_now_req(1'b0), .pair_now_cacheable(1'b0), .pair_now_paddr(32'd0),
    .pair_now_size_log2(2'b0), .pair_now_valid(), .pair_now_data(),
`endif
`endif
    .dbg_serve(), .m_req(m_req), .m_we(m_we), .m_addr(m_addr),
    .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_rdata(m_rdata),
    .m_rd_narrow(m_rd_narrow), .m_rd_size(m_rd_size), .m_ack(m_ack)
  );
`ifndef READ_ACK_PORT
  assign c_read_ack=c_ack; // Parent has no new port: unchanged legacy response.
`endif

  function automatic logic [31:0] word_at(input logic [31:0] addr);
    return {mem[16'(addr+3)],mem[16'(addr+2)],mem[16'(addr+1)],mem[16'(addr)]};
  endfunction
  assign m_rdata=word_at(m_addr);
  assign m_ack=rst_n && m_req && !ack_block && delay_count>=delay_setting;
  always @(posedge clk) begin
    if(!rst_n || !m_req || m_ack) delay_count<=0;
    else if(delay_count<32) delay_count<=delay_count+1;
    if(rst_n && m_req && m_ack) begin
      if(m_we) begin
        writes++;
        for(int b=0;b<4;b++) if(m_wstrb[b]) mem[16'(m_addr+32'(b))]=m_wdata[b*8 +: 8];
      end else backing_reads++;
    end
    if(rst_n && !c_we) begin
      if(c_read_ack!==c_ack) $fatal(1,"READ_ACK_OWNER_MISMATCH");
      comparisons++;
    end
  end

  // Called between rising edges, including while an unconsumed ACK is high.
  task automatic reset_now();
    rst_n=0; c_req=0; c_we=0; stream=0; stream_ready=0; ack_block=0;
    repeat(2) @(negedge clk);
    if(c_ack || c_read_ack || m_req || dut.st!=0)
      $fatal(1,"RESET_RETAINED_TRANSACTION");
`ifdef VEN_L1D_HIT_STREAM
    if(response_valid) $fatal(1,"RESET_RETAINED_STREAM_OWNER");
`endif
    rst_n=1; resets++;
    repeat(2) @(negedge clk);
    if(c_ack || c_read_ack || m_req) $fatal(1,"RESET_RESURRECTED_TRANSACTION");
  endtask
  task automatic read_at(input logic [31:0] addr);
    int guard;
    @(negedge clk); c_req=1; c_we=0; c_addr=addr;
    guard=0;
    do begin
      @(posedge clk);
      if(++guard>1000) $fatal(1,"READ_TIMEOUT");
    end while(!c_ack);
    if(c_read_ack!==1'b1 || c_rdata!==word_at(addr))
      $fatal(1,"READ_STALE_OR_WRONG_ACK address=%08x",addr);
    reads++;
    @(negedge clk); c_req=0;
    while(dut.st!=0) @(negedge clk);
  endtask

  initial begin
    int before_reads, before_writes, guard;
    logic [31:0] saved;
    for(int i=0;i<65536;i++) mem[i]=8'(i^(i>>8));
    for(int latency=0;latency<3;latency++) begin
      delay_setting=(latency==0)?0:((latency==1)?3:7);
      @(negedge clk); reset_now();
      // Cancel each of the eight possible incomplete fill positions. No DUT
      // state is injected: ordinary requests/backing handshakes reach them.
      for(int phase=0;phase<8;phase++) begin
        before_reads=backing_reads;
        @(negedge clk); c_req=1; c_addr='h3000; ack_block=(phase==0);
        guard=0;
        do begin
          @(posedge clk); #1;
          if(++guard>1000) $fatal(1,"FILL_PHASE_TIMEOUT");
        end while(dut.st==0 || backing_reads-before_reads<phase);
        @(negedge clk); ack_block=1;
        if(backing_reads-before_reads!=phase || dut.st==0)
          $fatal(1,"FILL_PHASE_NOT_REACHED phase=%0d",phase);
        reset_now(); abandoned_fills++;
        read_at('h3000);
        @(negedge clk); reset_now();
      end

      // Resident response may be combinational reuse or a registered hit.
      // Reset before its consumption edge, then demand a fresh correct read.
      read_at('h1000);
      before_reads=backing_reads;
      @(negedge clk); c_req=1; c_addr='h1000; #1;
      guard=0;
      // A critical-word-first fill need not have armed a full saved window.
      // Wait for this resident hit's registered response, but inspect AFTER
      // the edge that raises it and reset BEFORE its consumption edge.
      while(!c_ack) begin
        @(posedge clk); #1;
        if(++guard>2) $fatal(1,"RESIDENT_RESPONSE_TIMEOUT");
      end
      if(!c_read_ack || backing_reads!=before_reads || dut.st!=0)
        $fatal(1,"RESIDENT_RESPONSE_WAS_NOT_A_HIT");
      reset_now(); aborted_hits++;
      read_at('h1000);

      // A store without backing admission must not escape reset.
      saved=word_at('h1004); before_writes=writes;
      @(negedge clk); c_req=1; c_we=1; c_addr='h1004;
      c_wdata='hbad0cafe; ack_block=1;
      repeat(4) begin @(posedge clk); if(c_ack || m_ack) $fatal(1,"BLOCKED_STORE_ACK"); end
      @(negedge clk); reset_now(); aborted_stores++;
      if(writes!=before_writes || word_at('h1004)!==saved)
        $fatal(1,"RESET_INVENTED_STORE");
      read_at('h1004);

      // Conversely an acknowledged write is not undone by reset.
      @(negedge clk); c_req=1; c_we=1; c_addr='h1004; c_wdata='h739ac125;
      guard=0;
      do begin @(posedge clk); if(++guard>1000) $fatal(1,"STORE_TIMEOUT"); end while(!c_ack);
      @(negedge clk); reset_now();
      if(writes!=before_writes+1 || word_at('h1004)!=='h739ac125)
        $fatal(1,"RESET_ROLLED_BACK_STORE");
      read_at('h1004);

`ifdef VEN_L1D_HIT_STREAM
      // A held response belongs to its accepted address even with c_req=0
      // and another live address. Test both later consumption and reset.
      for(int consume=0;consume<2;consume++) begin
        read_at('h1000);
        @(negedge clk); stream=1; c_req=1; c_addr='h1000; stream_ready=0;
        @(posedge clk); if(!request_ready) $fatal(1,"STREAM_OWNER_NOT_ACCEPTED");
        @(negedge clk); c_req=0; c_addr='h2000;
        repeat(3) begin
          @(negedge clk);
          if(!response_valid || response_addr!='h1000 || c_ack || c_read_ack)
            $fatal(1,"HELD_STREAM_OWNER_CHANGED");
        end
        if(consume!=0) begin
          stream_ready=1; #1;
          if(!c_ack || !c_read_ack || c_rdata!==word_at('h1000))
            $fatal(1,"STREAM_CONSUME_WITHOUT_REQUEST");
          @(posedge clk); consumed_streams++;
          @(negedge clk);
        end
        reset_now(); read_at('h1000);
      end
`endif
    end
    if(abandoned_fills!=24 || aborted_hits!=3 || aborted_stores!=3 || writes!=3)
      $fatal(1,"RESET_COVERAGE_INCOMPLETE");
    $display("FP-READ-ACK-RESET-OK fills=%0d hits=%0d stores=%0d writes=%0d reads=%0d resets=%0d streams=%0d comparisons=%0d",
      abandoned_fills,aborted_hits,aborted_stores,writes,reads,resets,consumed_streams,comparisons);
    $finish;
  end
  initial begin #1000000; $fatal(1,"RESET_WATCHDOG"); end
endmodule
