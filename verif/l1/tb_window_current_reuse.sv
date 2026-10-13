`timescale 1ns/1ps
// Combinational leaf inputs only: no core state injection or sequential proof.
module tb;
  localparam OFFW=5, IDXW=7, L1_IDLE=0, L1_FILL=1;
  logic c_req,c_we,rd_armed,rd_match,c_next_req,c_pair_intent;
  logic stream_path,early_armed,cacheable,golden,flush_all,snoop_inv_valid;
  logic window_valid_q,shadow_valid_q,code_access,bypass_q,fill_poison,code_fill_q;
  logic [1:0] st,tag_current_hit,tag_prime_hit;
  logic [31:0] c_addr,c_next_addr,rd_addr_q;
  logic [31:5] shadow_line_addr_q;
  logic [6:0] fset;
  wire mc_lookup_old,mc_lookup_prime,mc_lookup_next,hit0,hit1,hit;
  wire window_current_hit,old_window,new_window,old_shadow,new_shadow;
  integer checks=0,primary=0,shadow=0,arbitrated=0,prime=0;
  logic [63:0] rng=64'hf72ab48d1369958b;
  // EXTRACTED_EQUATIONS
  task automatic defaults;
    c_req=1;c_we=0;rd_armed=1;rd_match=1;c_next_req=0;c_pair_intent=0;
    stream_path=0;early_armed=0;cacheable=1;golden=0;flush_all=0;snoop_inv_valid=0;
    window_valid_q=1;shadow_valid_q=1;code_access=0;
    bypass_q=0;fill_poison=0;code_fill_q=0;st=L1_IDLE;
    tag_current_hit=1;tag_prime_hit=0;c_addr=32'h1000;c_next_addr=32'h1040;
    rd_addr_q=32'h1000;shadow_line_addr_q=27'h80;fset=0;
  endtask
  task automatic check;
    #1;checks++;
    if (old_window !== new_window || old_shadow !== new_shadow)
      $fatal(1,"WINDOW-REUSE-MISMATCH check=%0d current=%b next=%b req=%b rd_match=%b intent=%b windows=%b%b/%b%b off=%0d",
        checks,tag_current_hit,tag_prime_hit,c_req,rd_match,c_pair_intent,
        old_window,old_shadow,new_window,new_shadow,c_addr[4:0]);
    if (new_window) primary++;
    if (new_shadow) shadow++;
    if (c_req && mc_lookup_next && !new_window && !new_shadow) arbitrated++;
    if (!c_req && mc_lookup_prime && !new_window && !new_shadow) prime++;
  endtask
  initial begin
    // Explicit counterexamples for forbidden owner, tag, extent and fence cuts.
    defaults();check();c_next_req=1;check();
    defaults();tag_current_hit=0;tag_prime_hit=3;check();
    defaults();flush_all=1;check();
    defaults();snoop_inv_valid=1;check();
    defaults();c_addr=32'h101d;check();
    defaults();code_access=1;check();
    // Exhaust every Boolean guard, both current ways, both next ways, and
    // primary/shadow line equality in independent overlapping groups.
    for (integer i=0;i<65536;i++) begin
      defaults();
      {c_req,c_we,rd_armed,rd_match,c_next_req,c_pair_intent,stream_path,
       early_armed,cacheable,golden,flush_all,snoop_inv_valid,window_valid_q,
       shadow_valid_q,code_access,tag_current_hit[0]}=16'(i);
      check();
    end
    for (integer i=0;i<4096;i++) begin
      defaults();
      {c_req,rd_armed,rd_match,c_next_req,c_pair_intent,tag_current_hit,
       tag_prime_hit,window_valid_q,shadow_valid_q,code_access}=12'(i);
      for (integer off=0;off<32;off++) begin
        c_addr=32'h1000+32'(off);check();
        rd_addr_q=32'h1040;shadow_line_addr_q=27'h82;check();
        rd_addr_q=32'h1000;shadow_line_addr_q=27'h80;
      end
    end
    for (integer i=0;i<16384;i++) begin
      defaults();rng=rng^(rng<<13);rng=rng^(rng>>7);rng=rng^(rng<<17);
      {c_req,c_we,rd_armed,rd_match,c_next_req,c_pair_intent,stream_path,
       early_armed,cacheable,golden,flush_all,snoop_inv_valid,window_valid_q,
       shadow_valid_q,code_access,tag_current_hit,tag_prime_hit,st,bypass_q,
       fill_poison,code_fill_q}=24'(rng);
      c_addr=rng[31:0];c_next_addr=rng[63:32];
      rd_addr_q=rng[0]?c_addr:c_addr^32'h20;
      shadow_line_addr_q=rng[1]?c_addr[31:5]:c_addr[31:5]^27'd1;
      fset=rng[10:4];check();
    end
`ifdef VEN_L1D_WINDOW_REUSE
    if (!primary) $fatal(1,"WINDOW-REUSE-COVERAGE primary");
`endif
`ifdef VEN_L1D_TWO_WINDOW_REUSE
    if (!shadow) $fatal(1,"WINDOW-REUSE-COVERAGE shadow");
`endif
`ifdef VEN_PIPE_MEM_CHAIN
    if (!arbitrated || !prime) $fatal(1,"WINDOW-REUSE-COVERAGE arbitration");
`endif
    $display("WINDOW-REUSE-OK checks=%0d primary=%0d shadow=%0d arbitrated=%0d prime=%0d",
             checks,primary,shadow,arbitrated,prime);
    $finish;
  end
endmodule
