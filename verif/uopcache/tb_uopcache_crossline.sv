`timescale 1ns/1ps
module tb_uopcache_crossline;
  import ventium_pkg::*;
  import ventium_alu_pkg::*;
  import ventium_decode_pkg::*;
  logic clk=0;
  always #5 clk=~clk;
`ifdef VEN_UOP_CROSS_INDEX
  localparam int SETS=64;
`else
  localparam int SETS=2;
`endif
  localparam int IDXW=$clog2(SETS);
  logic rst_n=0, start=0, repair=0, inv=0, inv2=0;
  logic [IDXW-1:0] invset=0, source_set=0, following_set=1;
  logic [IDXW-1:0] query_set=0, query_following_set=1;
  logic flush=0, mode16=0, ready, busy, hit, next_valid=1;
  logic query_next_way=0;
  logic source_way=0, next_way=0, query_way=0, invalidate_way=0;
  logic [255:0] bytes0;
  logic [47:0] bytes1;
  logic [4:0] offset=26;
  fpd_t base_a[8],base_b[8],tail_a[4],tail_b[4], packet;
  logic va[32],vb[32],pa,pb;
  logic [3:0] sa[32],sb[32];
  int checks=0;
  uopcache #(.IC_SETS(SETS),.TAIL_LOCAL(1),.EXEC_REPAIR(1)) dut (
    .clk,.rst_n,.rd_setA(IDXW'(0)),.rd_setB(IDXW'(1)),.rd_wayA(1'b0),.rd_wayB(1'b0),
    .rd_baseA(base_a),.rd_baseB(base_b),.rd_tailA(tail_a),.rd_tailB(tail_b),
    .rd_bvalidA(va),.rd_bvalidB(vb),.rd_bslotA(sa),.rd_bslotB(sb),
    .rd_pdvalidA(pa),.rd_pdvalidB(pb),
    .pd_start(start),.pd_set(source_set),.pd_way(source_way),.pd_line(bytes0),
    .pd_flags(32'h202),.pd_cycle_mode(1'b1),.pd_def16(1'b0),.cur_def16(mode16),
    .flush_all(flush),.inv_en(inv),.inv_set(invset),.inv_way(invalidate_way),
    .inv2_en(inv2),.inv2_set(IDXW'(1)),.inv2_way(invalidate_way),
    .repair_start(repair),.repair_set(source_set),.repair_way(source_way),
    .repair_line(bytes0),.repair_off(offset),.repair_flags(32'h202),
    .repair_ready(ready),.pd_busy(busy),
    .repair_next_valid(next_valid),.repair_next_bytes(bytes1),
    .repair_next_set(following_set),.repair_next_way(next_way),
    .cross_query_set(query_set),.cross_query_way(query_way),.cross_query_off(offset),
    .cross_query_next_set(query_following_set),.cross_query_next_way(query_next_way),
    .cross_hit(hit),.cross_uop(packet)
  );
  task automatic check(input bit ok,input string msg);
    if (!ok) $fatal(1,"%s",msg);
    checks++;
  endtask
  task automatic settle;
    int n=0;
    while(busy) begin
      @(negedge clk);
      if (++n>60) $fatal(1,"walker timeout");
    end
    repeat(2) @(negedge clk);
  endtask
  task automatic seed(input int off=26);
    logic [303:0] whole;
    rst_n=0; start=0; repair=0; inv=0; inv2=0; flush=0; mode16=0;
    next_valid=1; query_next_way=0;
    source_way=0; next_way=0; query_way=0; invalidate_way=0;
    source_set=0; following_set=1; query_set=0; query_following_set=1; invset=0;
    offset=5'(off);
    whole={38{8'h90}};
    whole[off*8 +: 56]=56'h12345678b50413;
    bytes0=whole[255:0]; bytes1=whole[303:256];
    repeat(2) @(negedge clk);
    rst_n=1; @(negedge clk);
    start=1; @(negedge clk); start=0; settle();
    check(!va[offset] && !hit,"cross-line instruction must not enter normal map");
    check(ready,"repair not ready");
  endtask
  task automatic launch;
    repair=1; @(negedge clk); repair=0;
  endtask
`ifdef VEN_UOP_CROSS2
  task automatic second_entry;
    source_way=1; next_way=1; query_way=1; query_next_way=1;
    // Distinct physical cache ways, with a different immediate to detect a
    // descriptor mux returning the right identity but the wrong payload.
    bytes1[7:0]=8'h56;
    start=1; @(negedge clk); start=0; settle();
    launch(); settle();
    check(hit && packet.mem_disp==32'h56345678,"second entry payload missing");
    query_way=0; query_next_way=0; #1;
    check(hit && packet.mem_disp==32'h12345678,"victim payload not retained");
  endtask
`endif
  initial begin
    seed(); launch(); settle();
    check(hit && packet.simple && packet.is_mem && packet.len==7 &&
          packet.alu_op==ALU_ADC && !packet.mem_base_en && !packet.mem_ss &&
          packet.mem_index_en && packet.mem_index==6 && packet.mem_scale==2 &&
          packet.mem_disp==32'h12345678,"wrong reconstructed ADC");
    query_next_way=1; #1; check(!hit,"wrong successor identity hit");
    query_next_way=0; #1; check(hit,"original identity lost");
    for(int off=26;off<32;off++) begin
      seed(off); launch(); settle();
      check(hit && packet.len==7 && packet.alu_op==ALU_ADC &&
            packet.mem_disp==32'h12345678,"wrong multi-byte suffix reconstruction");
    end
    // The admitted repair owns its byte snapshot, not later read-port traffic.
    seed(); launch(); bytes1=48'd0; settle();
    check(hit && packet.mem_disp==32'h12345678,"repair used uncaptured suffix");
    // Change bytes in each source independently, invalidate, then rebuild.
    seed(); launch(); settle();
    bytes1[7:0]=8'h56; inv2=1;
    @(negedge clk); inv2=0; check(!hit,"suffix write left stale descriptor");
    launch(); settle();
    check(hit && packet.mem_disp==32'h56345678,"suffix re-repair used stale bytes");
    bytes0[26*8 +: 8]=8'h03; inv=1; invset=0;
    @(negedge clk); inv=0; check(!hit,"opcode write left stale descriptor");
    start=1; @(negedge clk); start=0; settle();
    launch(); settle();
    check(hit && packet.alu_op==ALU_ADD && packet.mem_disp==32'h56345678,
          "first-source refill resurrected old opcode");
    // Sweep cancellation from acceptance through seek and publication, plus
    // the already-published case. inv2 independently covers the second source.
    for(int cause=0;cause<4;cause++) begin
      for(int phase=0;phase<30;phase++) begin
        seed();
        repair=1;
        repeat(phase) begin @(negedge clk); repair=0; end
        case(cause)
          0: begin inv=1; invset=0; end
          1: inv2=1;
          2: flush=1;
          3: mode16=1;
        endcase
        // Local invalidation uses the ordinary descriptor port edge contract.
        // The core independently fences same-cycle global flush consumption.
        @(negedge clk); repair=0; inv=0; inv2=0; flush=0;
        check(!hit,"invalidation edge did not clear hit");
        settle(); check(!hit,"cancelled descriptor resurrected");
      end
    end
    seed(); next_valid=0; launch(); settle();
    check(!hit,"missing successor must remain slow");
    seed(); launch(); repeat(10) @(negedge clk);
    start=1; @(negedge clk); start=0; settle();
    check(!hit && pa,"refill did not preempt disposable cross-line repair");
    seed(); offset=2; launch(); settle();
    check(va[2] && dut.repair_floor[0]==2,"normal repair did not establish floor");
    offset=26; launch(); repeat(6) @(negedge clk);
    check(busy && dut.wanchor==26,"optional seek did not start");
    offset=1; repair=1; #1;
    check(ready,"optional cross seek blocked earlier-anchor repair");
    @(negedge clk); repair=0;
    check(dut.wanchor==1 && dut.woff==0,"normal repair did not preempt immediately");
    settle(); check(va[1] && !hit,"yielded seek published stale cross descriptor");
`ifdef VEN_UOP_REPAIR_FAIR
    // Repeated earlier-anchor traffic must not starve the same optional
    // cross-line boundary forever. One yield is allowed; the next late seek
    // gets a bounded non-preemptible interval while real fills still win.
    offset=26; launch(); repeat(6) @(negedge clk);
    check(busy && dut.wanchor==26,"protected cross seek did not start");
    offset=0; repair=1; #1;
    check(!ready,"second late seek yielded again before publication");
    @(negedge clk); repair=0; offset=26; settle(); #1;
    check(hit && packet.mem_disp==32'h12345678,
          "protected cross seek did not publish correct descriptor");
    check(!dut.cross_yield_recent_q,"fairness credit did not clear at completion");
    offset=0; repair=1; #1;
    check(ready,"earlier map repair remained blocked after publication");
    @(negedge clk); repair=0; settle();
    // A foreground fill remains higher priority even while the late seek is
    // protected. Retain the fairness credit so its next attempt can finish.
    seed(); offset=2; launch(); settle();
    offset=26; launch(); repeat(6) @(negedge clk);
    offset=1; repair=1; #1; check(ready,"first yield unavailable after reset");
    @(negedge clk); repair=0; settle();
    offset=26; launch(); repeat(6) @(negedge clk);
    start=1; @(negedge clk); start=0;
    check(!dut.wrepair,"foreground fill did not preempt protected seek");
    settle();
    offset=26; launch(); repeat(6) @(negedge clk);
    offset=0; repair=1; #1;
    check(!ready,"fill preemption lost late-seek fairness credit");
    @(negedge clk); repair=0; offset=26; settle(); #1;
    check(hit && packet.mem_disp==32'h12345678,
          "late seek did not publish after foreground fill");
`endif
`ifdef VEN_UOP_CROSS2
    seed(); launch(); settle(); second_entry();
    // Repeating publication of the current primary must preserve the victim.
    query_way=1; query_next_way=1; launch(); settle();
    check(hit && packet.mem_disp==32'h56345678,"primary republication changed payload");
    query_way=0; query_next_way=0; #1;
    check(hit && packet.mem_disp==32'h12345678,"primary republication evicted victim");
    // A third identity uses the same first-source bytes in way 1 but the
    // original successor in way 0. No source bytes change without invalidation.
    next_way=0; query_way=1; query_next_way=0; bytes1[7:0]=8'h12;
    launch(); settle();
    check(hit && packet.mem_disp==32'h12345678,"third identity payload missing");
    query_way=1; query_next_way=1; #1;
    check(hit && packet.mem_disp==32'h56345678,"third publish lost displaced primary");
    query_way=0; query_next_way=0; #1;
    check(!hit,"third publish failed to evict oldest identity");
    for(int victim=0;victim<2;victim++) begin
      for(int source=0;source<2;source++) begin
        seed(); launch(); settle(); second_entry();
        invalidate_way=1'(victim);
        if(source==0) begin inv=1; invset=0; end else inv2=1;
        @(negedge clk); inv=0; inv2=0;
        query_way=1'(victim); query_next_way=1'(victim); #1;
        check(!hit,"invalidated primary/victim survived");
        query_way=1'(!victim); query_next_way=1'(!victim); #1;
        check(hit,"unrelated primary/victim lost on local invalidation");
      end
    end
    for(int cause=0;cause<2;cause++) begin
      seed(); launch(); settle(); second_entry();
      if(cause==0) flush=1; else mode16=1;
      @(negedge clk); flush=0;
      check(!hit,"global clear left victim valid");
      query_way=1; query_next_way=1; #1;
      check(!hit,"global clear left primary valid");
    end
    // Kill the displaced primary on the exact publication edge of the new
    // descriptor. Copying its old valid bit must not resurrect it as victim.
    seed(); launch(); settle();
    source_way=1; next_way=1; query_way=1; query_next_way=1;
    start=1; @(negedge clk); start=0; settle(); launch();
    while(dut.woff != {1'b0,offset}) @(negedge clk);
    inv=1; invset=0; invalidate_way=0;
    @(negedge clk); inv=0; settle();
    check(hit,"unrelated publication was cancelled");
    query_way=0; query_next_way=0; #1;
    check(!hit,"publication resurrected an invalidated victim");
`endif
`ifdef VEN_UOP_CROSS_INDEX
    // More than two distinct seams, including different payloads. All entries
    // must survive until a real index collision or a source invalidation.
    seed();
    for (int s=0; s<33; s++) begin
      source_set=IDXW'(s); following_set=IDXW'(s+1);
      query_set=source_set; query_following_set=following_set;
      // This line's prefix is the preceding seam's supplied suffix. Keep
      // overlapping source bytes consistent, not merely their cache identities.
      bytes0[7:0]=8'(s);
      bytes1[7:0]=8'(s+1);
      start=1; @(negedge clk); start=0; settle(); launch(); settle();
      check(hit,"indexed publication missing");
    end
    for (int s=0; s<33; s++) begin
      query_set=IDXW'(s); query_following_set=IDXW'(s+1); #1;
      check(hit && packet.mem_disp==((32'(s+1)<<24)|32'h00345678),"indexed capacity/payload loss");
    end
    inv=1; invset=IDXW'(4); @(negedge clk); inv=0;
    for (int s=0; s<33; s++) begin
      query_set=IDXW'(s); query_following_set=IDXW'(s+1); #1;
      check(hit==(s!=3 && s!=4),"indexed invalidation lost wrong source identity");
    end
    // Displace set 32 into bucket zero, then ensure the full set tag rejects
    // set zero rather than returning set 32's descriptor under an index alias.
    for (int s=32; s<34; s++) begin
      source_set=IDXW'(s); following_set=IDXW'(s+1);
      bytes0[7:0]=8'(s); bytes1[7:0]=8'(s+1);
      start=1; @(negedge clk); start=0; settle(); launch(); settle();
    end
    query_set=0; query_following_set=1; #1;
    check(!hit,"indexed conflict returned aliased payload");
    query_set=IDXW'(32); query_following_set=IDXW'(33); #1;
    check(hit,"indexed conflict lost replacement");
    flush=1; @(negedge clk); flush=0;
    for (int s=0; s<34; s++) begin
      query_set=IDXW'(s); query_following_set=IDXW'(s+1); #1;
      check(!hit,"global flush left an indexed bucket resident");
    end
    // Bucket zero contains A(set 0); B(set 32) is primary. Publishing C(set 8)
    // would replace A with B. An invalidation of A must not kill valid B,
    // whereas invalidating B must suppress its insertion and retain A.
    for (int killed=0; killed<2; killed++) begin
      for (int source=0; source<2; source++) begin
        seed(); launch(); settle();
        source_set=IDXW'(32); following_set=IDXW'(33); bytes1[7:0]=8'h56;
        start=1; @(negedge clk); start=0; settle(); launch(); settle();
        query_set=0; query_following_set=1; #1;
        check(hit && packet.mem_disp==32'h12345678,"race setup lost A");
        source_set=IDXW'(8); following_set=IDXW'(9); bytes1[7:0]=8'h78;
        start=1; @(negedge clk); start=0; settle(); launch();
        while(dut.woff != {1'b0,offset}) @(negedge clk);
        inv=1; invset=IDXW'((killed ? 32 : 0)+source);
        @(negedge clk); inv=0; settle();
        query_set=IDXW'(8); query_following_set=IDXW'(9); #1;
        check(hit && packet.mem_disp==32'h78345678,"race killed unrelated C");
        query_set=0; query_following_set=1; #1;
        check(hit==1'(killed),"race retained wrong old bucket occupant");
        if(hit) check(packet.mem_disp==32'h12345678,"race changed A payload");
        query_set=IDXW'(32); query_following_set=IDXW'(33); #1;
        check(hit==1'(!killed),"race resurrected or lost displaced B");
        if(hit) check(packet.mem_disp==32'h56345678,"race changed B payload");
      end
    end
`endif
    $display("UOP-CROSSLINE-GATE-OK checks=%0d",checks);
    $finish;
  end
endmodule
