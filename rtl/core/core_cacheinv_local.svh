// Generated from the same ven_cacheinv_local leaf body; no new state.
  logic cache_inv_local;
  logic [14:0] cinv_allowed_prefix, cinv_header_match;
  for (genvar i=0; i<15; i++) begin : g_cacheinv_local_header
    // LOCK is illegal for both no-memory forms. Repeated REP/size/segment
    // prefixes keep the original decoder's acceptance; do not impose a new
    // prefix-group or length policy here. In particular, a header ending at
    // byte16 retains the old predicate; the existing fetch engine owns #GP.
    assign cinv_allowed_prefix[i] = is_prefix(ibuf[i]) && ibuf[i]!=8'hf0;
    if (i==0) begin : g_first
      always_comb begin
        cinv_header_match[i]=1'b0;
        if ((cosim_en || soc_en) && ibuf[i]==8'h0f &&
            ((ibuf[i+1]==8'h08) || (ibuf[i+1]==8'h09))) cinv_header_match[i]=1'b1;
      end
    end else begin : g_prefixed
      always_comb begin
        cinv_header_match[i]=1'b0;
        if ((&cinv_allowed_prefix[i-1:0]) && (cosim_en || soc_en) &&
            ibuf[i]==8'h0f && ((ibuf[i+1]==8'h08) || (ibuf[i+1]==8'h09)))
          cinv_header_match[i]=1'b1;
      end
    end
  end
  assign cache_inv_local = |cinv_header_match;
