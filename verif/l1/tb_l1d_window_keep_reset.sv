`timescale 1ns/1ps
// Reset is a system boundary: upstream withdraws its request and the backing
// response session resets too. It is NOT rollback of a completed RAM write.
module tb_l1d_window_keep_reset;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  logic flush_all=0, golden=0, cacheable=1, snoop_inv_valid=0;
  logic [31:0] snoop_inv_addr=0;
  logic c_req=0, c_we=0, c_ack;
  logic [31:0] c_addr=0, c_wdata=0, c_rdata, c_rdata_hi;
  logic [3:0] c_wstrb=4'hf;
  logic c_rdata_hi_valid;
  logic c_hit_stream=0, c_req_ready, c_rsp_valid, c_rsp_ready=0, c_rsp_cancel;
  logic [31:0] c_rsp_addr;
  logic [7:0] dbg_serve;
  logic m_req, m_we, m_ack, m_rd_narrow, ack_block=0;
  logic [31:0] m_addr, m_wdata, m_rdata;
  logic [3:0] m_wstrb;
  logic [1:0] m_rd_size;
  ven_l1d dut(
      .c_next_req(1'b0), .c_next_commit(1'b0), .c_next_cacheable(1'b0),
      .c_next_addr(32'd0), .c_next_wstrb(4'd0), .c_next_ready(), .*);
  byte unsigned mem[65536];
  int reads=0, writes=0, resets=0, cancellations=0, backing_reads=0;
  function automatic logic [31:0] word_at(input logic [31:0] addr);
    return {mem[16'(addr+3)],mem[16'(addr+2)],mem[16'(addr+1)],mem[16'(addr)]};
  endfunction
  assign m_rdata=word_at(m_addr);
  assign m_ack=rst_n && m_req && !ack_block;
  always @(posedge clk) if(rst_n && m_req && m_ack) begin
    if(m_we) begin
      writes++;
      for(int b=0;b<4;b++) if(m_wstrb[b]) mem[16'(m_addr+32'(b))]=m_wdata[b*8 +: 8];
    end else backing_reads++;
  end
  task automatic read_at(input logic [31:0] addr);
    int guard;
    @(negedge clk); c_req=1; c_we=0; c_addr=addr; c_wstrb=4'hf;
    guard=0;
    do begin
      @(posedge clk);
      if(++guard>100) $fatal(1,"read timeout");
    end while(!c_ack);
    if(c_rdata!==word_at(addr)) $fatal(1,"post-reset/cancel stale read %08x",addr);
    reads++;
    @(negedge clk); c_req=0;
    while(dut.st!=0) @(negedge clk);
  endtask
  task automatic reset_session();
    @(negedge clk);
    rst_n=0; c_req=0; c_we=0; c_hit_stream=0; c_rsp_ready=0;
    flush_all=0; snoop_inv_valid=0; golden=0; cacheable=1; ack_block=0;
    repeat(2) @(negedge clk);
    if(dut.window_valid_q || dut.rd_full_line_q || dut.rd_armed ||
       c_rsp_valid || c_ack || m_req || dut.st!=0) $fatal(1,"reset retained transaction");
    rst_n=1; resets++;
    repeat(2) @(negedge clk);
    if(c_ack || c_rsp_valid || m_req) $fatal(1,"old transaction resurrected");
  endtask
  task automatic cancel_stream(input int kind);
    read_at('h1000); read_at('h1020);
    @(negedge clk); c_hit_stream=1; c_req=1; c_addr='h1004; c_rsp_ready=0;
    @(posedge clk); if(!c_req_ready) $fatal(1,"stream did not accept owner");
    @(negedge clk); c_req=0;
    repeat(3) @(negedge clk);
    if(!c_rsp_valid || c_rsp_addr!='h1004) $fatal(1,"lost held stream owner");
    // A pending LEGACY STORE cannot steal a held streaming read's ACK.
    c_hit_stream=0; c_req=1; c_we=1; c_addr='h1024; c_wdata='h12345678;
    repeat(2) begin
      @(posedge clk);
      if(c_ack || m_req || !c_rsp_valid) $fatal(1,"store stole held read response");
    end
    @(negedge clk);
    // Withdraw that unaccepted store before canceling the read. No fictional
    // legacy cancel input is used; c_rsp_cancel is the existing stream output.
    c_req=0; c_we=0;
    case(kind)
      0: flush_all=1;
      1: begin snoop_inv_valid=1; snoop_inv_addr='h1000; end
      2: golden=1;
    endcase
    @(posedge clk);
    if(!c_rsp_cancel || c_rsp_valid || c_ack || m_req) $fatal(1,"stream cancellation failed");
    cancellations++;
    @(negedge clk); flush_all=0; snoop_inv_valid=0; golden=0;
    if(dut.window_valid_q || c_rsp_valid) $fatal(1,"cancel retained window/owner");
    read_at('h1024); read_at('h1000);
  endtask
  initial begin
    int before_reads, before_writes;
    logic [31:0] saved;
    for(int i=0;i<65536;i++) mem[i]=8'(i^(i>>8));
    reset_session();
    // Reset a registered, unconsumed legacy hit (not a stream response).
    read_at('h1000); read_at('h2000);
    @(negedge clk); c_req=1; c_addr='h1004;
    @(posedge clk);
    @(negedge clk); if(!dut.rd_armed) $fatal(1,"legacy pending fixture absent");
    // Assert reset now, before the armed response's next sampling edge.
    rst_n=0; c_req=0;
    reset_session(); read_at('h1004);
    // Reset during a miss, including partial fills and the final pending beat.
    for(int phase=0;phase<8;phase++) begin
      reset_session(); before_reads=backing_reads;
      @(negedge clk); c_req=1; c_addr='h3000; ack_block=(phase==0);
      @(negedge clk);
      while(backing_reads-before_reads<phase) @(negedge clk);
      ack_block=1;
      if(dut.st==0) $fatal(1,"missing outstanding fill");
      reset_session(); read_at('h3000);
    end
    // A withdrawn legacy miss still drains its backing fill; no cancel port.
    reset_session(); before_reads=backing_reads;
    @(negedge clk); c_req=1; c_addr='h4000;
    repeat(3) @(negedge clk); c_req=0;
    while(dut.st!=0) begin
      @(negedge clk); if(c_ack) $fatal(1,"withdrawn miss acknowledged");
    end
    if(backing_reads-before_reads!=8) $fatal(1,"withdrawn fill did not drain exactly eight beats");
    read_at('h4000);
    // Both cacheable and NC outstanding stores are canceled only by the
    // coordinated reset before backing ACK; no external write may occur.
    for(int nc=0;nc<2;nc++) begin
      read_at('h1000); read_at('h2000); saved=word_at('h2004); before_writes=writes;
      @(negedge clk); c_req=1; c_we=1; c_addr='h2004; c_wdata='hbad0cafe;
      cacheable=(nc==0); ack_block=1;
      repeat(4) begin @(posedge clk); if(c_ack || m_ack) $fatal(1,"blocked store acknowledged"); end
      reset_session();
      if(writes!=before_writes || word_at('h2004)!==saved) $fatal(1,"reset undid/invented backing write");
      read_at('h2004);
    end
    // A RAM write already acknowledged BEFORE reset is not rolled back.
    before_writes=writes;
    @(negedge clk); c_req=1; c_we=1; c_addr='h2004; c_wdata='h739ac125;
    @(posedge clk); if(!c_ack) $fatal(1,"committed store fixture blocked");
    @(negedge clk); c_req=0; c_we=0;
    reset_session();
    if(writes!=before_writes+1 || word_at('h2004)!=='h739ac125) $fatal(1,"reset rolled back completed store");
    read_at('h2004);
    before_writes=writes;
    for(int kind=0;kind<3;kind++) cancel_stream(kind);
    if(writes!=before_writes) $fatal(1,"unaccepted mode-switch store escaped");
    read_at('h1000);
    @(negedge clk); c_hit_stream=1; c_req=1; c_addr='h1000; c_rsp_ready=0;
    @(posedge clk); if(!c_req_ready) $fatal(1,"reset stream fixture absent");
    @(negedge clk); c_req=0;
    reset_session(); read_at('h1000);
    $display("L1D-WINDOW-KEEP-RESET-OK reads=%0d writes=%0d resets=%0d cancellations=%0d",reads,writes,resets,cancellations);
    $finish;
  end
  initial begin #1000000; $fatal(1,"watchdog"); end
endmodule
