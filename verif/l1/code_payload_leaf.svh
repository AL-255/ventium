// Public transactions only: no DUT deposit, forced hit, or bypassed ownership.
int cp_reads=0, cp_code=0, cp_forward=0, cp_primary=0, cp_dual=0, cp_early=0;
always @(posedge clk) if (rst_n && c_req && !c_we && c_ack && c_code) begin
  if (c_rdata !== word_at(c_addr))
    $fatal(1,"CODE-PAYLOAD-BACKING: addr=%08x got=%08x",c_addr,c_rdata);
  if (dut.code_word_reuse) cp_code++;
  if (dut.fill_forward_code_hit && dut.code_word_reuse) cp_forward++;
  if (dut.rd_match) cp_primary++;
  if (dut.rd_match && dut.code_word_reuse) cp_dual++;
  if (dut.early_match) cp_early++;
end

task automatic cp_read(input logic[31:0] address, input bit code,
                       input logic[3:0] strobes, input bit drain);
  int guard;
  @(negedge clk); c_req=1; c_we=0; c_code=code; c_addr=address; c_wstrb=strobes;
  guard=0;
  do begin
    @(posedge clk);
    if (++guard>200) $fatal(1,"CODE-PAYLOAD timeout");
  end while (!c_ack);
  @(negedge clk); c_req=0; cp_reads++;
  if (drain) while (dut.st!=dut.L1_IDLE) @(negedge clk);
endtask

task automatic run_code_payload;
  logic[31:0] base;
  // All critical-word starts, both ordinary instruction-fetch strobe forms,
  // partial fill-word ownership, completed staging-line reuse, and D traffic.
  for (int start=0; start<8; start++)
    for (int zero_strobe=0; zero_strobe<2; zero_strobe++) begin
      iw_reset(); base=32'h4000+32'(start*64);
      cp_read(base+32'(start*4),1,zero_strobe ? 4'h0 : 4'hf,0);
      for (int n=1;n<8;n++)
        cp_read(base+32'(((start+n)%8)*4),1,zero_strobe ? 4'h0 : 4'hf,n==7);
      for (int n=0;n<8;n++) cp_read(base+32'(n*4),1,4'hf,1);
      cp_read(base,0,4'hf,1);
      cp_read(base+4,1,4'h0,1);
      // Uncacheable instruction-labelled transactions must use bypass data,
      // not stale staging bytes. Restore cacheability through the public port.
      cacheable=0; cp_read(base+8,1,4'hf,1); cacheable=1;
      cp_read(base+8,1,4'hf,1);
      // Coherent store invalidates the code owner; refill must see new bytes.
      c_code=0; wu_store(base+12,4'hf,2,0,0,4'hf,4'hf);
      cp_read(base+12,1,4'hf,1);
      // DMA update plus snoop and then flush suppress ACK on the exact edge.
      @(negedge clk); c_req=1; c_addr=base+16; c_wstrb=4'hf;
      snoop_inv_valid=1; snoop_inv_addr=base; mem[base+16] ^= 8'h6d;
      @(posedge clk); if(c_ack) $fatal(1,"CODE-PAYLOAD snoop ACK");
      @(negedge clk); c_req=0; snoop_inv_valid=0;
      cp_read(base+16,1,4'hf,1);
      @(negedge clk); c_req=1; c_addr=base+20; flush_all=1;
      @(posedge clk); if(c_ack) $fatal(1,"CODE-PAYLOAD flush ACK");
      @(negedge clk); c_req=0; flush_all=0;
      cp_read(base+20,1,4'hf,1);
    end
  if (cp_reads!=368 || cp_code<128 || cp_forward==0 || cp_early==0)
    $fatal(1,"CODE-PAYLOAD missing coverage reads=%0d code=%0d forward=%0d early=%0d",
           cp_reads,cp_code,cp_forward,cp_early);
  iw_reset();
  $display("CODE-PAYLOAD-OK reads=%0d code=%0d forward=%0d primary=%0d duplicate=%0d early=%0d",
           cp_reads,cp_code,cp_forward,cp_primary,cp_dual,cp_early);
endtask
