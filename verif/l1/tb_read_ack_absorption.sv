`timescale 1ns/1ps
module tb;
  localparam L1_IDLE=0,L1_FILL=1,L1_DONE=2,L1_BYP=3;
  localparam IDXW=7,OFFW=5,BYPASS_RD_EN=1;
  reg rst_n,c_req,c_we,cacheable,golden,flush_all,snoop_inv_valid;
  reg stream_path,early_armed,rd_armed,rd_code_q,c_code;
  reg window_valid_q,shadow_valid_q,c_next_req,bypass_q,fill_poison,code_fill_q;
  reg code_valid_q,fill_independent_hit,fill_forward_code_hit;
  reg early_match,byp_match,c_hit_stream,c_rsp_valid,c_rsp_ready;
  reg [1:0] st,tag_current_hit,tag_prime_hit;
  reg [31:0] c_addr,rd_addr_q,c_next_addr;
  reg [26:0] shadow_line_addr_q,code_line_tag_q;
  reg [6:0] fset;
  reg [3:0] c_wstrb;
  wire rd_match,mc_lookup_old,mc_lookup_prime,mc_lookup_next,hit,rd_hit;
  wire code_access,code_hit,window_reuse,shadow_reuse,code_word_reuse;
  reg old_ack,new_ack;
  assign hit = mc_lookup_next ? |tag_prime_hit : |tag_current_hit;
  assign rd_hit = hit;
  // EXTRACTED_EQUATIONS
  reg [31:0] random_q=32'h816fbc39;
  function automatic [31:0] next_random(input [31:0] value);
    reg [31:0] x;
    begin x=value^(value<<13);x=x^(x>>17);next_random=x^(x<<5);end
  endfunction
  task randomize_inputs;
    begin
      random_q=next_random(random_q);
      {rst_n,c_req,c_we,cacheable,golden,flush_all,snoop_inv_valid,
       stream_path,early_armed,rd_armed,rd_code_q,c_code,
       window_valid_q,shadow_valid_q,c_next_req,bypass_q,fill_poison,code_fill_q,
       code_valid_q,fill_independent_hit,fill_forward_code_hit,
       early_match,byp_match,c_hit_stream,c_rsp_valid,c_rsp_ready}=random_q;
      random_q=next_random(random_q);
      {st,tag_current_hit,tag_prime_hit,fset,c_wstrb}=random_q;
      random_q=next_random(random_q);c_addr=random_q;
      random_q=next_random(random_q);rd_addr_q=random_q;
      random_q=next_random(random_q);c_next_addr=random_q;
      random_q=next_random(random_q);shadow_line_addr_q=random_q[26:0];
      random_q=next_random(random_q);code_line_tag_q=random_q[26:0];
    end
  endtask
  integer checks=0,lookahead_checks=0,window_checks=0,shadow_checks=0,code_checks=0;
  task check;
    begin
      #1;
      if(old_ack !== new_ack)
        $fatal(1,"READ-ACK-ABSORPTION-MISMATCH check=%0d old=%b new=%b req=%b rd=%b lookup=%b",checks,old_ack,new_ack,c_req,rd_match,mc_lookup_next);
      checks=checks+1;
      if(c_req && !c_we && mc_lookup_next) lookahead_checks=lookahead_checks+1;
      if(window_reuse) window_checks=window_checks+1;
      if(shadow_reuse) shadow_checks=shadow_checks+1;
      if(code_word_reuse) code_checks=code_checks+1;
    end
  endtask
  integer i,shape;
  initial begin
    // Randomize all independent abstract leaf inputs, then correlate real
    // ownership for additional coverage. No internal state of a cache is forced:
    // this is an extracted combinational miter, not a sequential cache test.
    for(i=0;i<200000;i=i+1) begin
      randomize_inputs();
      case(i%8)
        0: begin end
        1: begin rd_addr_q=c_addr;end
        2: begin shadow_line_addr_q=c_addr[31:5];end
        3: begin rd_addr_q={c_addr[31:5],5'd0};end
        4: begin code_line_tag_q=c_addr[31:5];end
        default: begin
          rst_n=1;c_req=1;c_we=0;cacheable=1;golden=0;flush_all=0;snoop_inv_valid=0;
          stream_path=0;early_armed=0;st=L1_IDLE;
          rd_addr_q=c_addr;shadow_line_addr_q=c_addr[31:5];code_line_tag_q=c_addr[31:5];
        end
      endcase
      check();
    end
    // Exhaustively vary lookup, current/next tags, owner and all ACK blockers
    // around a naturally specified complete registered response identity.
    for(shape=0;shape<16384;shape=shape+1) begin
      randomize_inputs();
      rst_n=1;c_req=1;c_we=0;cacheable=1;golden=0;stream_path=0;early_armed=0;
      st=L1_IDLE;c_addr=32'h12340000;rd_addr_q=c_addr;
      shadow_line_addr_q=c_addr[31:5];code_line_tag_q=c_addr[31:5];
      c_wstrb=4'hf;early_match=0;byp_match=0;
      {c_next_req,rd_armed,rd_code_q,c_code,window_valid_q,shadow_valid_q,
       tag_current_hit,tag_prime_hit,cacheable,flush_all,snoop_inv_valid,code_valid_q}=shape[13:0];
      check();
    end
    if(lookahead_checks==0 || window_checks==0 || shadow_checks==0 || code_checks==0)
      $fatal(1,"READ-ACK-ABSORPTION-COVERAGE");
    $display("READ-ACK-ABSORPTION-OK checks=%0d lookahead=%0d window=%0d shadow=%0d code=%0d",checks,lookahead_checks,window_checks,shadow_checks,code_checks);
    $finish;
  end
endmodule
