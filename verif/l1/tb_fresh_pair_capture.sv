`timescale 1ns/1ps
module tb;
  localparam OFFW=5, IDXW=7, TAGW=20;
  localparam L1_IDLE=2'd0, L1_FILL=2'd1;
  localparam BYPASS_RD_EN=1'b1;
  reg rst_n,c_req,c_we,cacheable,golden,rd_armed,early_armed;
  reg flush_all,snoop_inv_valid,c_next_req,c_pair_intent,c_code;
  reg code_valid_q,code_fill_q,rd_code_q,window_valid_q,shadow_valid_q;
  reg bypass_q,fill_poison,c_hit_stream,rd_stream_q;
  reg [1:0] st,pair_req_valid,tag_current_hit,tag_prime_hit;
  reg hit_n;
  reg [31:0] c_addr,c_next_addr,rd_addr_q,early_addr_q,fbase;
  reg [26:0] shadow_line_addr_q,code_line_tag_q;
  reg [6:0] fset;
  reg [19:0] ftag;
  reg [7:0] fill_word_valid;
  reg [3:0] c_wstrb,c_next_wstrb;
  wire stream_path,rd_match,mc_lookup_old,mc_lookup_prime,mc_lookup_next;
  wire [31:0] lookup_addr;
  wire [3:0] lookup_wstrb;
  wire [6:0] set_c;
  wire [19:0] tag_c;
  reg [2:0] c_x_hi;
  wire xline,hit0,hit1,hit,rd_hit,code_access,code_hit;
  wire window_reuse,shadow_reuse,code_word_reuse,do_rd_cap_legacy;
  wire fill_independent_hit,fill_forward_data_hit,fill_forward_code_hit,fill_forward_hit;
  wire old_capture,new_capture;
  // EXTRACTED_EQUATIONS
  reg [31:0] random_q=32'h902dad1b;
  integer checks=0,captures=0,byte31=0,saved=0,flushed_capture=0,next_lookups=0;
  integer i,off,mask,policy;
  function automatic [31:0] rnd(input [31:0] x);
    reg [31:0] y;
    begin y=x^(x<<13);y=y^(y>>17);rnd=y^(y<<5);end
  endfunction
  task automatic randomize_inputs;
    begin
      random_q=rnd(random_q);
      {rst_n,c_req,c_we,cacheable,golden,rd_armed,early_armed,flush_all,
       snoop_inv_valid,c_next_req,c_pair_intent,c_code,code_valid_q,code_fill_q,
       rd_code_q,window_valid_q,shadow_valid_q,bypass_q,fill_poison,
       c_hit_stream,rd_stream_q,hit_n}=random_q[21:0];
      random_q=rnd(random_q);
      {st,pair_req_valid,tag_current_hit,tag_prime_hit,c_wstrb,c_next_wstrb,
       fill_word_valid}=random_q[23:0];
      random_q=rnd(random_q);c_addr=random_q;
      random_q=rnd(random_q);c_next_addr=random_q;
      random_q=rnd(random_q);rd_addr_q=random_q[0] ? c_addr : random_q;
      random_q=rnd(random_q);early_addr_q=random_q;
      random_q=rnd(random_q);fbase=random_q;fset=random_q[6:0];ftag=random_q[19:0];
      random_q=rnd(random_q);
      shadow_line_addr_q=random_q[0] ? c_addr[31:5] : random_q[26:0];
      code_line_tag_q=random_q[1] ? c_addr[31:5] : random_q[26:0];
    end
  endtask
  task automatic fresh;
    begin
      randomize_inputs();
      rst_n=1;c_req=1;c_we=0;cacheable=1;golden=0;rd_armed=0;
      early_armed=0;flush_all=0;snoop_inv_valid=0;c_next_req=1;c_pair_intent=0;
      c_code=0;code_valid_q=0;code_fill_q=0;rd_code_q=0;
      window_valid_q=0;shadow_valid_q=0;c_hit_stream=0;rd_stream_q=0;
      st=L1_IDLE;pair_req_valid=2'b10;tag_current_hit=2'b01;tag_prime_hit=0;
      c_addr=32'h12340000;rd_addr_q=c_addr;shadow_line_addr_q=c_addr[31:5];
      c_next_addr=32'hfedcba3f;c_next_wstrb=4'hf;c_wstrb=4'hf;
    end
  endtask
  task automatic check;
    begin
      #1;checks++;
      if(old_capture !== new_capture)
        $fatal(1,"FRESH-PAIR-MISMATCH check=%0d old=%b new=%b addr=%h strb=%h next=%b rd=%b window=%b shadow=%b flush=%b snoop=%b state=%d",
          checks,old_capture,new_capture,c_addr,c_wstrb,mc_lookup_next,rd_armed,
          window_reuse,shadow_reuse,flush_all,snoop_inv_valid,st);
      if(old_capture) begin
        captures++;
        if(c_addr[4:0]==31 && c_wstrb==1) byte31++;
        if(flush_all) flushed_capture++;
      end
      if(window_reuse || shadow_reuse) saved++;
      if(mc_lookup_next) next_lookups++;
      if(c_req && !rd_armed && mc_lookup_next)
        $fatal(1,"FRESH-PAIR-LEMMA-MISMATCH");
    end
  endtask
  initial begin
    for(i=0;i<40000;i++) begin randomize_inputs();check();end
    // Every current byte position and strobe shape, including byte 31,
    // zero-strobe legacy reads, unaligned dwords and actual line crossings.
    for(off=0;off<32;off++) for(mask=0;mask<16;mask++)
      for(policy=0;policy<256;policy++) begin
        fresh();c_addr[4:0]=5'(off);c_wstrb=4'(mask);
        {window_valid_q,shadow_valid_q,flush_all,snoop_inv_valid,
         c_next_req,c_pair_intent,c_code,code_valid_q}=8'(policy);
        check();
      end
    // Exercise all major suppressors independently and in combination.
    for(i=0;i<8192;i++) begin
      fresh();
      {c_req,c_we,cacheable,golden,rd_armed,early_armed,flush_all,
       snoop_inv_valid,c_next_req,c_pair_intent,c_hit_stream,rd_stream_q,
       c_code}=13'(i);
      check();
    end
    if(captures==0 || flushed_capture==0) $fatal(1,"FRESH-PAIR-MISSING-COVERAGE");
`ifdef VEN_P54_DUAL_BYTE_LOAD_PAIR
    if(byte31==0) $fatal(1,"FRESH-PAIR-MISSING-BYTE31");
`endif
`ifdef VEN_L1D_WINDOW_REUSE
    if(saved==0) $fatal(1,"FRESH-PAIR-MISSING-SAVED");
`endif
`ifdef VEN_PIPE_MEM_CHAIN
    if(next_lookups==0) $fatal(1,"FRESH-PAIR-MISSING-NEXT");
`endif
    $display("FRESH-PAIR-CAPTURE-OK checks=%0d captures=%0d byte31=%0d saved=%0d flush=%0d next=%0d",
      checks,captures,byte31,saved,flushed_capture,next_lookups);
    $finish;
  end
endmodule
