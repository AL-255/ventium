  logic mc_valid_q, agi_prime_select, ref_prime_select, mc_prime_offer;
  logic agi_guard, ref_guard, chain_guard;
  logic agi_prime_offer, ref_prime_offer, mc_offer, mem_next_req;
  logic [31:0] mc_query_phys, mc_phys_q, reference_addr, candidate_addr, tested_addr;
  // The driver checks these three implications in the actual pinned source.
  // The remaining permission/extent conditions are unconstrained Booleans:
  // this admits a superset of reachable offers, not just successful accesses.
  assign agi_prime_offer = agi_prime_select && agi_guard;
  assign ref_prime_offer = ref_prime_select && ref_guard;
  assign mc_offer = mc_valid_q && chain_guard;
  // SOURCE_EXTRACTED_ASSIGNMENTS
  integer samples = 0, offered = 0, unused_differences = 0;
  initial begin
    for (integer controls=0; controls<128; controls++) begin
      {mc_valid_q,agi_prime_select,ref_prime_select,mc_prime_offer,
       agi_guard,ref_guard,chain_guard} = 7'(controls);
      for (integer bitnum=0; bitnum<32; bitnum++) begin
        mc_query_phys = 32'hffffffff ^ (32'b1 << bitnum);
        mc_phys_q = 32'b1 << bitnum;
        #1;
        tested_addr = candidate_addr;
        if ($test$plusargs("mutant_owner")) tested_addr = mc_query_phys;
        if ($test$plusargs("mutant_live")) tested_addr = mc_phys_q;
        samples++;
        if (mem_next_req) begin
          offered++;
          if (tested_addr !== reference_addr)
            $fatal(1, "NEXT_QUERY_PAYLOAD_EQ controls=%0d bit=%0d", controls, bitnum);
        end else if (tested_addr !== reference_addr) unused_differences++;
      end
    end
    if (samples != 4096 || offered == 0 || unused_differences == 0)
      $fatal(1, "NEXT_QUERY_VACUOUS");
    $display("NEXT-QUERY-PAYLOAD-OK samples=%0d offered=%0d unused=%0d", samples, offered, unused_differences);
    $finish;
  end
