// Use real resident data and a real held data fill; never force DUT state.
task automatic run_next_ready_underfill;
  int checks,before_backing;
  logic [31:0] target,before_addr;
  checks=0;
  for(int beat=0;beat<8;beat++)
    for(int narrow=0;narrow<2;narrow++)
      for(int off=0;off<32;off+=(narrow ? 1 : 4)) begin
        ifill_setup(beat,0);
        target=32'h1020+32'(off);before_addr=m_addr;before_backing=backing;
        c_next_req=1;c_next_commit=0;c_next_cacheable=1;
        c_next_addr=target;c_next_wstrb=narrow ? 4'h1 : 4'hf;
        repeat(3) begin
          #1;
          if(!c_next_ready || !dut.mc_lookup_prime || c_ack || dut.rd_armed ||
             !m_req || m_we || m_addr!=before_addr || backing!=before_backing)
            $fatal(1,"NEXT-READY-DFILL uncommitted ownership changed");
          @(posedge clk);@(negedge clk);
        end
        c_next_commit=1;
        @(posedge clk);@(negedge clk);
        c_next_req=0;c_next_commit=0;c_req=1;c_addr=target;c_wstrb=c_next_wstrb;
        #1;
        if(!c_ack || !dut.rd_match || !m_req || m_we || m_addr!=before_addr ||
           backing!=before_backing ||
           (narrow ? c_rdata[7:0]!==mem[target] : c_rdata!==word_at(target)))
          $fatal(1,"NEXT-READY-DFILL response missing/wrong owner");
        @(posedge clk);@(negedge clk);c_req=0;hold_ack=0;
        while(dut.st!=dut.L1_IDLE) @(negedge clk);
        c_wstrb=4'hf;checks++;
      end
  if(checks!=320) $fatal(1,"NEXT-READY-DFILL coverage");
  $display("NEXT-READY-DFILL-OK checks=%0d",checks);
endtask
