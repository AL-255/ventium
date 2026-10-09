// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Exact first-command/response ownership, including byte-exact device reads.
module tb_axi_read_through;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  initial begin #3000000; $fatal(1,"watchdog"); end
  logic [3:0] awid=0, bid, arid=0, rid;
  logic [39:0] awaddr=0, araddr=0;
  logic [7:0] awlen=0, arlen=0;
  logic [2:0] awsize=2, arsize=2;
  logic [1:0] awburst=1, arburst=1, bresp, rresp;
  logic awvalid=0, awready, wvalid=0, wready, wlast=1;
  logic [31:0] wdata=0, rdata;
  logic [3:0] wstrb=0;
  logic bvalid, bready=0, arvalid=0, arready, rvalid, rready=1, rlast;
  logic [29:0] avm_address;
  logic [31:0] avm_writedata, avm_readdata;
  logic [3:0] avm_byteenable, avm_burstcount;
  logic avm_write, avm_read, avm_waitrequest=0, avm_readdatavalid=0;
  ven_axi2avalon dut (
    .clk,.rst_n,.s_axi_awid(awid),.s_axi_awaddr(awaddr),.s_axi_awlen(awlen),
    .s_axi_awsize(awsize),.s_axi_awburst(awburst),.s_axi_awvalid(awvalid),.s_axi_awready(awready),
    .s_axi_wdata(wdata),.s_axi_wstrb(wstrb),.s_axi_wlast(wlast),.s_axi_wvalid(wvalid),.s_axi_wready(wready),
    .s_axi_bid(bid),.s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(bready),
    .s_axi_arid(arid),.s_axi_araddr(araddr),.s_axi_arlen(arlen),.s_axi_arsize(arsize),
    .s_axi_arburst(arburst),.s_axi_arvalid(arvalid),.s_axi_arready(arready),
    .s_axi_rid(rid),.s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rlast(rlast),
    .s_axi_rvalid(rvalid),.s_axi_rready(rready),.avm_address,.avm_writedata,
    .avm_byteenable,.avm_burstcount,.avm_write,.avm_read,.avm_waitrequest,
    .avm_readdatavalid,.avm_readdata);
  int tick=0, left=0, gap=0, cadence=0;
  int ar_count=0, av_count=0, responses=0, writes=0, cases=0;
  int first_ar=0, first_av=0, total_latency=0;
  logic [29:0] cursor=0;
  logic [39:0] expected_addr=0;
  logic [3:0] expected_id=0, expected_be=0;
  int expected_words=0, expected_offset=0, received=0, commands=0;
  bit expected_wrap=0, checking=0;
  function automatic logic [31:0] word_at(input logic [29:0] address_word);
    return 32'h97531bdf ^ (32'(address_word)*32'h13579);
  endfunction
  function automatic logic [29:0] expected_word(input int n);
    if(expected_wrap) return {expected_addr[31:5],3'd0}+30'((expected_offset+n)%8);
    return expected_addr[31:2]+30'(n);
  endfunction
  always @(posedge clk) begin
    tick<=tick+1;
    avm_readdatavalid<=0;
    if(!rst_n) begin left<=0;gap<=0;end
    else begin
      if(arvalid && arready) begin ar_count++;first_ar=tick;end
      if(avm_write && !avm_waitrequest) begin
        if(left!=0 || avm_read) $fatal(1,"write/read ownership overlap");
        writes++;
      end
      if(avm_read && !avm_waitrequest) begin
        if(left!=0 || !checking) $fatal(1,"unsolicited/overlapping Avalon command");
        if(commands==0) begin
          first_av=tick;
          if(avm_address!==expected_addr[31:2] || avm_byteenable!==expected_be ||
             avm_burstcount!=4'(expected_wrap ? 8-expected_offset : expected_words))
            $fatal(1,"first command changed address/width/extent");
        end else if(commands!=1 || !expected_wrap || expected_offset==0 ||
                    avm_address!=={expected_addr[31:5],3'd0} ||
                    avm_byteenable!==4'hf || avm_burstcount!=4'(expected_offset))
          $fatal(1,"WRAP continuation changed identity");
        commands++;av_count++;cursor<=avm_address;left<=int'(avm_burstcount);gap<=cadence;
      end else if(left!=0) begin
        if(gap!=0) gap<=gap-1;
        else begin
          avm_readdata<=word_at(cursor);avm_readdatavalid<=1;
          cursor<=cursor+1;left<=left-1;gap<=cadence;
        end
      end
      if(rvalid && rready) begin
        if(!checking || received>=expected_words || rdata!==word_at(expected_word(received)) ||
           rid!==expected_id || rresp!==0 || rlast!==(received==expected_words-1))
          $fatal(1,"wrong response owner/data/count/lane %0d",received);
        received++;responses++;
      end
    end
  end
  task automatic read_case(input int bytes_log2, lane, words, offset, stall, spacing,
                           input bit wrap);
    int prior_ar, prior_av, expected_delay;
    @(negedge clk);
    expected_addr=40'h2800+40'(cases*64)+40'(offset*4+lane);
    expected_id=4'(cases);expected_words=words;expected_offset=offset;
    expected_wrap=wrap;expected_be=4'(((1<<(1<<bytes_log2))-1)<<lane);
    received=0;commands=0;checking=1;cadence=spacing;
    araddr=expected_addr;arid=expected_id;arlen=8'(words-1);arsize=3'(bytes_log2);
    arburst=wrap ? 2'b10 : 2'b01;arvalid=1;avm_waitrequest=(stall!=0);
    prior_ar=ar_count;prior_av=av_count;
    // AR is captured even if the endpoint cannot accept yet. No new AXI
    // ready/valid timing obligation is imposed on the existing producer.
    @(posedge clk);if(!arready) $fatal(1,"idle AR acceptance changed");
    @(negedge clk);arvalid=0;araddr='1;arid=~expected_id;arsize=0;arlen=0;arburst=0;
    // Poison unrelated live WSTRB too: narrow reads own their original lanes.
    wstrb=~expected_be;
    repeat(stall) @(negedge clk);
    avm_waitrequest=0;
    for(int guard=0;guard<300 && received!=words;guard++) @(negedge clk);
    if(received!=words || ar_count!=prior_ar+1 ||
       av_count-prior_av!=(wrap && offset!=0 ? 2 : 1)) $fatal(1,"read did not close exactly");
    expected_delay=stall==0 ? 1 : stall+1;
`ifdef VEN_AXI2AVL_READ_THROUGH
    if(stall==0) expected_delay=0;
`endif
    if(first_av-first_ar!=expected_delay) $fatal(1,"command delay %0d expected %0d",first_av-first_ar,expected_delay);
    total_latency+=first_av-first_ar;cases++;checking=0;
    repeat(2) @(negedge clk);
  endtask
  task automatic held_b;
    int before_writes;
    @(negedge clk);before_writes=writes;
    awaddr=40'h5000;awid=4'h9;awvalid=1;wvalid=1;wdata=32'hcafe0123;wstrb=4'hf;bready=0;
    begin bit aw=0,wd=0;
      for(int guard=0;guard<20 && (!aw || !wd);guard++) begin
        @(posedge clk);if(awready && awvalid) aw=1;if(wready && wvalid) wd=1;
        @(negedge clk);if(aw) awvalid=0;if(wd) wvalid=0;
      end
      if(!aw || !wd) $fatal(1,"write timeout");
    end
    repeat(2) @(negedge clk);
    arvalid=1;araddr=40'h6400;
    repeat(5) begin
      #1;if(!bvalid || bid!=9 || bresp!=0 || arready || avm_read)
        $fatal(1,"read escaped prior held B");
      @(negedge clk);
    end
    arvalid=0;bready=1;repeat(2) @(negedge clk);
    if(bvalid || writes!=before_writes+1) $fatal(1,"write/B count mismatch");
  endtask
  initial begin
    repeat(3) @(negedge clk);rst_n=1;
    for(int wait_n=0;wait_n<6;wait_n++)
      for(int spacing=0;spacing<3;spacing++) begin
        for(int size=0;size<3;size++)
          for(int lane=0;lane<4;lane+=(1<<size)) read_case(size,lane,1,0,wait_n,spacing,0);
        read_case(2,0,8,0,wait_n,spacing,0);
        for(int off=0;off<8;off++) read_case(2,0,8,off,wait_n,spacing,1);
      end
    held_b();
    // Shared reset with a captured, unaccepted command: no phantom device read.
    @(negedge clk);avm_waitrequest=1;arvalid=1;araddr=40'h2000;arlen=0;arsize=2;arburst=1;
    checking=1;commands=0;expected_addr=araddr;expected_words=1;expected_wrap=0;expected_be=4'hf;
    @(posedge clk);if(!arready) $fatal(1,"reset probe AR not accepted");
    @(negedge clk);arvalid=0;rst_n=0;
    repeat(2) @(negedge clk);
    avm_waitrequest=0;
    #1;if(avm_read || rvalid || bvalid) $fatal(1,"reset retained old owner");
    checking=0;rst_n=1;read_case(2,0,8,5,0,0,1);
    $display("AXI-READ-THROUGH-OK cases=%0d command_delay=%0d responses=%0d",cases,total_latency,responses);
    $finish;
  end
endmodule
