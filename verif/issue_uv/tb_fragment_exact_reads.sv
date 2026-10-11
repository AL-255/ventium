`timescale 1ns/1ps
module tb_fragment_exact_reads;
  logic clk=0, rst_n=0;
  logic [3:0] state=0, cur_size=4, raw_strb=0;
  logic [31:0] cur_lin_nat=32'h8ffd, raw_data=32'h87654321, bus_rdata=0;
  logic request=1, write=0, paging_on=1, fe_translatable=1, fx_abort_q=0;
  logic xlate_miss=0, perm_fault=0, sync_access_fault=0, fe_xlate_pend=0, bus_ack=0;
  wire mem_req, mem_we, mem_ack_o;
  wire [31:0] mem_addr, mem_wdata, mem_rdata_o;
  wire [3:0] mem_wstrb;
  integer reads=0, replacements=0, walks=0, writes=0, pieces=0;
  fragment_exact dut(.*);

  task automatic tick;
    #2; clk=1; #2; clk=0; #2;
  endtask

  task automatic reset_engine;
    rst_n=0; state=0; fx_abort_q=0; bus_ack=0; request=1; write=0;
    paging_on=1; fe_translatable=1; raw_strb=0;
    xlate_miss=0; perm_fault=0; sync_access_fault=0; fe_xlate_pend=0;
    tick(); rst_n=1; #2;
    if (dut.fx_act !== 0) $fatal(1,"FRAGMENT-EXACT-FAIL reset");
  endtask

  // Independent byte set oracle for the actual extracted L1 ARSIZE planner.
  // Every byte is touched once, no byte outside the fragment may be touched.
  task automatic exact_bytes(input logic [31:0] address, input integer count);
    integer seen[4]; logic [31:0] physical; integer lane;
    #1;
    for (integer b=0;b<4;b++) seen[b]=0;
    if (!mem_req || mem_we || mem_addr !== address || mem_wstrb !== 4'((1<<count)-1))
      $fatal(1,"FRAGMENT-EXACT-FAIL request addr=%h want=%h mask=%h count=%0d active=%0d abort=%0d first=%0d",
        mem_addr,address,mem_wstrb,count,dut.fx_act,fx_abort_q,dut.fx_first);
    for (integer p=0;p<dut.byp_cnt_c;p++) begin
      pieces++;
      physical=(mem_addr & 32'hfffffffc)+32'(dut.byp_off_c[p]);
      if ((physical & ((1<<dut.byp_siz_c[p])-1)) != 0)
        $fatal(1,"FRAGMENT-EXACT-FAIL unaligned AXI piece");
      for (integer b=0;b<(1<<dut.byp_siz_c[p]);b++) begin
        lane=integer'(physical+b-address);
        if (lane<0 || lane>=count)
          $fatal(1,"FRAGMENT-EXACT-FAIL excess byte %h fragment %h+%0d",physical+b,address,count);
        seen[lane]++;
      end
    end
    for (integer b=0;b<count;b++)
      if (seen[b]!=1) $fatal(1,"FRAGMENT-EXACT-FAIL missing/duplicate byte");
  endtask

  // Begin an old live sequence through its real sequential input. No force.
  task automatic old_owner(input integer first, input integer kind);
    cur_size=4; cur_lin_nat=32'h6000-32'(first); raw_strb=15;
    write=(kind!=0); bus_ack=(kind==0); #1; tick(); bus_ack=0;
    if (kind>=2) tick();
    if (kind>=3) begin bus_ack=1; tick(); bus_ack=0; end
    if (!dut.fx_act || dut.fx_first!=first)
      $fatal(1,"FRAGMENT-EXACT-FAIL old owner not exercised");
  endtask

  task automatic read_case(input integer size, first, legacy, delay_cycles,
      walk_detour, old_first, old_kind);
    logic [31:0] expected, first_data, second_data;
    reset_engine();
    if (old_first!=0) begin old_owner(old_first,old_kind); fx_abort_q=1; replacements++; end
    write=0; cur_size=4'(size); cur_lin_nat=32'h9000-32'(first);
    raw_strb=legacy ? 4'd0 : 4'((1<<size)-1);
    first_data=32'h44332211; second_data=32'h88776655;
    expected=(first_data & ~(32'hffffffff << (first*8))) | (second_data << (first*8));
    bus_rdata=first_data; bus_ack=(delay_cycles==0); #2;
    if (!dut.fx_start || mem_ack_o) $fatal(1,"FRAGMENT-EXACT-FAIL start/early ack");
    exact_bytes(32'h22000-32'(first),first);
    tick(); fx_abort_q=0;
    if (delay_cycles!=0) begin
      for (integer d=0;d<delay_cycles;d++) begin
        exact_bytes(32'h22000-32'(first),first);
        if (mem_ack_o) $fatal(1,"FRAGMENT-EXACT-FAIL premature ack");
        tick();
      end
      bus_ack=1; #1;
      if (mem_ack_o) $fatal(1,"FRAGMENT-EXACT-FAIL first ack exposed");
      tick();
    end
    bus_ack=0; #1;
    if (dut.fx_ph!=1 || dut.fx_first!=first)
      $fatal(1,"FRAGMENT-EXACT-FAIL replacement latch/phase");
    if (walk_detour!=0) begin
      state=1; raw_strb=0; bus_ack=1; bus_rdata=32'hdeadcafe;
      repeat(3) begin
        #1;
        if (mem_wstrb!==0 || dut.fx_merge_e || dut.fx_hold_e)
          $fatal(1,"FRAGMENT-EXACT-FAIL walk shaping not blanked");
        tick();
        if (dut.fx_ph!=1 || dut.fx_lo!==first_data)
          $fatal(1,"FRAGMENT-EXACT-FAIL walk mutated engine");
      end
      walks++; state=0; raw_strb=legacy ? 0 : 4'((1<<size)-1); bus_ack=0;
    end
    // A stalled permission/translation response must not issue a second read.
    fe_xlate_pend=1; #1;
    if (mem_req) $fatal(1,"FRAGMENT-EXACT-FAIL pending read issued");
    tick(); fe_xlate_pend=0; #1;
    exact_bytes(32'h73000,size-first);
    bus_ack=1; bus_rdata=second_data; #1;
    if (!mem_ack_o || mem_rdata_o!==expected)
      $fatal(1,"FRAGMENT-EXACT-FAIL final merge/ack");
    tick(); bus_ack=0; request=0; #1;
    if (dut.fx_act) $fatal(1,"FRAGMENT-EXACT-FAIL completion");
    reads++;
  endtask

  task automatic write_case(input integer mask, first);
    reset_engine(); write=1; raw_strb=4'(mask); cur_size=4;
    cur_lin_nat=32'h9000-32'(first); #1;
    if (dut.fx_cross) begin
      if (mem_req || !dut.fx_start) $fatal(1,"FRAGMENT-EXACT-FAIL write probe escaped");
      tick(); #1;
      if (mem_req) $fatal(1,"FRAGMENT-EXACT-FAIL registered probe escaped");
      tick(); #1;
      if (mem_wstrb!==4'(mask & ((1<<first)-1))) $fatal(1,"FRAGMENT-EXACT-FAIL write first mask");
      bus_ack=1; tick(); #1;
      if (mem_wstrb!==4'(mask>>first) || mem_wdata!==(raw_data>>(first*8)))
        $fatal(1,"FRAGMENT-EXACT-FAIL write second payload");
      tick();
    end else if (mem_wstrb!==4'(mask)) $fatal(1,"FRAGMENT-EXACT-FAIL noncrossing write mask");
    writes++;
  endtask

  initial begin
    for (integer size=2;size<=4;size++)
      for (integer first=1;first<size;first++)
        for (integer legacy=0;legacy<2;legacy++)
          for (integer delay_index=0;delay_index<3;delay_index++)
            for (integer walk=0;walk<2;walk++)
              read_case(size,first,legacy,delay_index==2 ? 7 : delay_index,walk,0,0);
    for (integer old_first=1;old_first<=3;old_first++)
      for (integer old_kind=0;old_kind<4;old_kind++)
        for (integer first=1;first<=3;first++)
          for (integer legacy=0;legacy<2;legacy++)
            for (integer delayed=0;delayed<2;delayed++)
              read_case(4,first,legacy,delayed,1,old_first,old_kind);
    for (integer mask=0;mask<16;mask++)
      for (integer first=1;first<=4;first++) write_case(mask,first);
    $display("FRAGMENT-EXACT-OK reads=%0d replacements=%0d walks=%0d writes=%0d pieces=%0d",
        reads,replacements,walks,writes,pieces);
    $finish;
  end
endmodule
