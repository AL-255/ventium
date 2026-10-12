// Diagnostic only: observe the unmodified request equation in the RAW profile.
// No internal forcing, arbitration changes, new synthesis flag or performance claim.
`ifndef SYNTHESIS
`ifdef VEN_RAW_V_READ_PRIME
`ifdef VEN_P54_LOAD_STORE_PAIR
  longint unsigned np_clocks, np_agi, np_ref, np_retained, np_prime;
  longint unsigned np_intent, np_request, np_accept, np_shape_only;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      np_clocks <= 0; np_agi <= 0; np_ref <= 0; np_retained <= 0;
      np_prime <= 0; np_intent <= 0; np_request <= 0;
      np_accept <= 0; np_shape_only <= 0;
    end else begin
      np_clocks <= np_clocks + 1;
      if (agi_prime_offer) np_agi <= np_agi + 1;
      if (ref_prime_offer) np_ref <= np_ref + 1;
      if (mc_offer) np_retained <= np_retained + 1;
      if (mc_prime_offer) np_prime <= np_prime + 1;
      if (pipe_load_req && pipe_store_pair_shape) np_intent <= np_intent + 1;
      if (pipe_load_req && mem_store_pair_req) np_request <= np_request + 1;
      if (pipe_load_req && pipe_store_pair_accept) np_accept <= np_accept + 1;
      if (pipe_store_pair_shape && mem_next_req) begin
        np_shape_only <= np_shape_only + 1;
        if (np_shape_only == 0)
          $display("NEXT-PAIR-SHAPE pc=%h load=%b agi=%b ref=%b retained=%b prime=%b",
                   eip, pipe_load_req, agi_prime_offer, ref_prime_offer, mc_offer, mc_prime_offer);
        if ($test$plusargs("next_pair_reject_shape"))
          $fatal(1,"NEXT-PAIR-BROAD: shape-only exclusion loses a real hint");
      end
      assert (!mc_valid_q)
        else $fatal(1,"NEXT-PAIR-RETAINED: RAW profile retained a next-read owner");
      assert (!(pipe_load_req && pipe_store_pair_shape && mem_next_req))
        else $fatal(1,"NEXT-PAIR-OVERLAP pc=%h agi=%b ref=%b retained=%b prime=%b held=%b",
                    eip, agi_prime_offer, ref_prime_offer, mc_offer, mc_prime_offer, mc_held_read_prime);
    end
  end
  final $display("NEXT-PAIR-PROBE clocks=%0d agi=%0d ref=%0d retained=%0d prime=%0d intent=%0d request=%0d accept=%0d shape_only=%0d",
                 np_clocks,np_agi,np_ref,np_retained,np_prime,np_intent,np_request,np_accept,np_shape_only);
`endif
`endif
`endif
