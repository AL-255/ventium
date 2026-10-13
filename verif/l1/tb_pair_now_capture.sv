`timescale 1ns/1ps
module tb;
  localparam OFFW=5, IDXW=7, L1_IDLE=0, L1_FILL=1;
  logic c_req,c_we,rd_armed,rd_match,c_next_req,c_pair_intent,c_pair_req,c_ack;
  logic stream_path,early_armed,cacheable,golden,flush_all,snoop_inv_valid;
  logic window_valid_q,shadow_valid_q,code_access,bypass_q,fill_poison,code_fill_q;
  logic mc_capture_next,pair_now_req,pair_now_cacheable;
  logic [1:0] st,tag_current_hit,tag_prime_hit,pair_req_valid,pair_rsp_valid;
  logic [1:0] pair_cacheable,pair_hit0,pair_hit1;
  logic [1:0][1:0] pair_size_log2;
  logic [1:0][31:0] pair_paddr;
  logic [1:0] pair_now_size_log2;
  logic [31:0] c_addr,c_next_addr,rd_addr_q,pair_now_paddr;
  logic [3:0] c_wstrb,c_next_wstrb;
  logic [31:5] shadow_line_addr_q;
  logic [6:0] fset;
  wire mc_lookup_old,mc_lookup_prime,mc_lookup_next,hit0,hit1,hit;
  wire window_reuse,shadow_reuse,pair_fresh_current_hit,pair_fresh_saved_window;
  wire pair_legacy_capture,pair_store_read_capture,pair_prime_capture;
  wire pair_legacy_bank_owned,pair_lookup_active,pair_now_valid;
  wire [1:0] old_hit,new_hit;
  integer checks=0,v_capture=0,v_now=0,two_lane_now=0;
  logic [63:0] rng=64'hafd137882379bac5;
  // EXTRACTED_EQUATIONS
  task automatic defaults;
    c_req=1;c_we=0;rd_armed=0;rd_match=0;c_next_req=0;c_pair_intent=0;
    c_pair_req=0;c_ack=1;stream_path=0;early_armed=0;cacheable=1;golden=0;
    flush_all=0;snoop_inv_valid=0;window_valid_q=0;shadow_valid_q=0;code_access=0;
    bypass_q=0;fill_poison=0;code_fill_q=0;mc_capture_next=0;
    pair_now_req=1;pair_now_cacheable=1;st=L1_IDLE;tag_current_hit=1;tag_prime_hit=1;
    pair_req_valid=2'b10;pair_rsp_valid=0;pair_cacheable=3;pair_hit0=3;pair_hit1=0;
    pair_size_log2={2'd2,2'd2};pair_now_size_log2=2;
    c_addr=32'h1000;c_next_addr=32'h1040;rd_addr_q=c_addr;pair_now_paddr=32'h1004;
    pair_paddr={32'h1004,32'h1000};c_wstrb=15;c_next_wstrb=15;
    shadow_line_addr_q=c_addr[31:5];fset=0;
  endtask
  task automatic check;
    #1;checks++;
    if (old_hit !== new_hit)
      $fatal(1,"PAIR-NOW-CAPTURE-MISMATCH check=%0d req=%b now=%b lookup=%b old=%b new=%b",
             checks,pair_req_valid,pair_now_valid,pair_lookup_active,old_hit,new_hit);
    if (pair_req_valid==2'b10 && new_hit[1]) v_capture++;
    if (pair_req_valid==2'b10 && pair_now_valid) v_now++;
    if (pair_req_valid==2'b11 && pair_now_valid && pair_lookup_active) two_lane_now++;
`ifdef VEN_P54_DUAL_LOAD_PAIR
    if (pair_req_valid==2'b10 && pair_now_valid && pair_lookup_active)
      $fatal(1,"PAIR-NOW-CAPTURE-EXCLUSION");
`endif
  endtask
  initial begin
    defaults();check();
    defaults();window_valid_q=1;rd_armed=1;rd_match=1;check();
    pair_req_valid=3;check();
    defaults();shadow_valid_q=1;rd_armed=1;rd_match=1;check();
    pair_req_valid=3;check();
    // Exhaust ownership/control booleans with both registered-window states.
    for (integer i=0;i<65536;i++) begin
      defaults();
      {c_req,c_we,rd_armed,rd_match,c_next_req,c_pair_intent,c_pair_req,
       stream_path,early_armed,cacheable,golden,flush_all,snoop_inv_valid,
       window_valid_q,shadow_valid_q,code_access}=16'(i);
      check();pair_req_valid=3;check();
    end
    // All byte positions, request shapes, immediate widths and primary/
    // shadow occupancy. Address comparisons are preserved from real source.
    for(integer i=0;i<2048;i++) begin
      defaults();
      {pair_req_valid,pair_now_size_log2,window_valid_q,shadow_valid_q,
       c_addr[4:0]}=11'(i);
      rd_armed=1;rd_match=1;
      pair_size_log2[1]=pair_now_size_log2;check();
    end
    for(integer i=0;i<16384;i++) begin
      defaults();rng=rng^(rng<<13);rng=rng^(rng>>7);rng=rng^(rng<<17);
      {c_req,c_we,rd_armed,rd_match,c_next_req,c_pair_intent,c_pair_req,c_ack,
       stream_path,early_armed,cacheable,golden,flush_all,snoop_inv_valid,
       window_valid_q,shadow_valid_q,code_access,bypass_q,fill_poison,code_fill_q,
       mc_capture_next,pair_now_req,pair_now_cacheable,st,tag_current_hit,
       tag_prime_hit,pair_req_valid,pair_rsp_valid,pair_cacheable,pair_hit0,
       pair_hit1,pair_size_log2,pair_now_size_log2,c_wstrb,c_next_wstrb}=51'(rng);
      c_addr=rng[31:0];c_next_addr=rng[63:32];pair_now_paddr=c_addr^32'd4;
      pair_paddr[1]=rng[0]?pair_now_paddr:~pair_now_paddr;
      rd_addr_q=rng[1]?c_addr:~c_addr;
      shadow_line_addr_q=rng[2]?c_addr[31:5]:~c_addr[31:5];check();
    end
`ifdef VEN_P54_DUAL_HIT_LEGACY_CAPTURE
    if (!v_capture) $fatal(1,"PAIR-NOW-CAPTURE-COVERAGE capture");
`endif
`ifdef VEN_L1D_WINDOW_REUSE
    if (!v_now || !two_lane_now) $fatal(1,"PAIR-NOW-CAPTURE-COVERAGE immediate");
`endif
    $display("PAIR-NOW-CAPTURE-OK checks=%0d capture=%0d immediate=%0d two_lane=%0d",
             checks,v_capture,v_now,two_lane_now);
    $finish;
  end
endmodule
