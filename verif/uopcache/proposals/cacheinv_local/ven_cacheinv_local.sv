// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Experimental combinational projection of decode_stages' cache-invalidate
// predicate for the REGISTERED, complete ibuf in S_DECODE. No new state or
// earlier invalidation. The caller must retain state == S_DECODE qualification.
// Not connected to production RTL; qualify against the actual decoder first.
module ven_cacheinv_local
  import ventium_decode_pkg::*;
(
    input logic [7:0] ibuf [16],
    input logic cosim_en, soc_en,
    output logic recognized
);
  logic [14:0] allowed_prefix, header_match;
  for (genvar i=0; i<15; i++) begin : g_header
    // LOCK is illegal for both no-memory forms. Repeated REP/size/segment
    // prefixes keep the original decoder's acceptance; do not impose a new
    // prefix-group or length policy here. In particular, a header ending at
    // byte16 retains the old predicate; the existing fetch engine owns #GP.
    assign allowed_prefix[i] = is_prefix(ibuf[i]) && ibuf[i]!=8'hf0;
    if (i==0) begin : g_first
      always_comb begin
        header_match[i]=1'b0;
        if ((cosim_en || soc_en) && ibuf[i]==8'h0f &&
            ((ibuf[i+1]==8'h08) || (ibuf[i+1]==8'h09))) header_match[i]=1'b1;
      end
    end else begin : g_prefixed
      always_comb begin
        header_match[i]=1'b0;
        if ((&allowed_prefix[i-1:0]) && (cosim_en || soc_en) &&
            ibuf[i]==8'h0f && ((ibuf[i+1]==8'h08) || (ibuf[i+1]==8'h09)))
          header_match[i]=1'b1;
      end
    end
  end
  assign recognized = |header_match;
endmodule
