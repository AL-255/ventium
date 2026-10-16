`timescale 1ns/1ps
module tb;
  localparam IDXW=7,OFFW=5,L1_IDLE=0,L1_FILL=1;
  logic c_next_req,c_req,c_we,rd_match,c_pair_intent,early_armed,stream_path;
  logic rd_armed,bypass_q,fill_poison,code_fill_q,cacheable,c_next_cacheable;
  logic golden,flush_all,snoop_inv_valid,c_next_commit;
  logic [3:0] st,c_next_wstrb,c_wstrb;
  logic [31:0] c_addr,c_next_addr;
  logic [6:0] fset;
  logic [1:0] tag_prime_hit,tag_current_hit;
  integer samples=0,ready_samples=0,prime_samples=0,old_samples=0;
  integer seed=32'h5afe2026;
  // EXTRACTED_EQUATIONS
  task check;
    begin
      #1;
      if ({old_mc_lookup_old,old_mc_lookup_prime,old_mc_lookup_next,old_lookup_addr,
           old_lookup_wstrb,old_c_next_ready,old_mc_capture_next} !==
          {new_mc_lookup_old,new_mc_lookup_prime,new_mc_lookup_next,new_lookup_addr,
           new_lookup_wstrb,new_c_next_ready,new_mc_capture_next})
        $fatal(1,"NEXT-READY-MISMATCH sample=%0d",samples);
      samples++;
      if(old_c_next_ready) ready_samples++;
      if(old_c_next_ready && old_mc_lookup_prime) prime_samples++;
      if(old_c_next_ready && old_mc_lookup_old) old_samples++;
    end
  endtask
  initial begin
    for(integer k=0;k<131072;k=k+1) begin
      {c_next_req,c_req,c_we,rd_match,c_pair_intent,early_armed,stream_path,
       rd_armed,bypass_q,fill_poison,code_fill_q,cacheable,c_next_cacheable,
       golden,flush_all,snoop_inv_valid,c_next_commit}=$random(seed);
      st=k%3;c_next_wstrb=$random(seed);c_wstrb=$random(seed);
      c_addr=$random(seed);c_next_addr=$random(seed);fset=$random(seed);
      tag_prime_hit=$random(seed);tag_current_hit=$random(seed);
      // Directed resident admission samples alongside unrestricted rejects.
      // Independent current/next hits still vary; never assume equality.
      if(k%8==0) begin
        c_next_req=1;c_req=(k/8)%2;c_we=0;rd_match=1;c_pair_intent=0;
        early_armed=0;stream_path=0;rd_armed=0;cacheable=1;c_next_cacheable=1;
        golden=0;flush_all=0;snoop_inv_valid=0;st=L1_IDLE;
        c_next_wstrb=1;
      end
      check;
    end
    // Exhaust the ready-cone decision variables with all other guards open.
    // Random rejection-heavy samples alone missed the old-read cacheability
    // mutant in R1; this includes the exact solver counterexample family.
    for(integer k=0;k<65536;k=k+1) begin
      c_next_req=k[0];c_req=k[1];cacheable=k[2];
      tag_current_hit=k[4:3];tag_prime_hit=k[6:5];
      c_next_wstrb=k[10:7];c_next_addr=32'h2020+32'(k[15:11]);
      c_we=0;rd_match=1;c_pair_intent=0;early_armed=0;stream_path=0;
      rd_armed=0;bypass_q=0;fill_poison=0;code_fill_q=0;c_next_cacheable=1;
      golden=0;flush_all=0;snoop_inv_valid=0;c_next_commit=1;
      st=L1_IDLE;c_wstrb=4'hf;c_addr=32'h1000;fset=0;
      check;
    end
    if(ready_samples<100 || old_samples<100) $fatal(1,"vacuous ready/old coverage");
`ifdef VEN_PIPE_REG_LOAD_PRIME
    if(prime_samples<100) $fatal(1,"vacuous prime coverage");
`else
    if(prime_samples!=0) $fatal(1,"disabled prime admitted");
`endif
    $display("NEXT-READY-LEAF-OK samples=%0d ready=%0d old=%0d prime=%0d",samples,ready_samples,old_samples,prime_samples);
    $finish;
  end
endmodule
