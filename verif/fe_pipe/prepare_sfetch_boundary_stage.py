"""Register true boundary beats only; preserve interior-16 fetch throughput.

The all-demand predecessor regressed a measured 16-bit prefix loop by 44%.
Keep that failed experiment intact. This narrower experiment does not stage
the page/CS/IP-interior policy, whose width is already independent of decode.
"""
import prepare_sfetch_beat_stage as base

PARENTS = base.PARENTS
replace_once = base.replace_once

STAGE = """  // Only true page/CS/IP boundaries need a registered exact byte count.
  // Interior-16 fetch already has a fixed four-byte payload and keeps its
  // original request timing; neither it nor S_PIPE acquires this stage.
  logic sfetch_beat_valid_q;
  logic [2:0] sfetch_beat_size_q;
  wire sfetch_stage_select = (state == S_FETCH) && sfetch_boundary
`ifdef VEN_SFETCH16_DEMAND
                             && !sfetch_interior16
`endif
                             ;
  wire sfetch_staged_req = sfetch_stage_select &&
                             sfetch_beat_valid_q;
  assign sfetch_demand_req = sfetch_staged_req
`ifdef VEN_SFETCH16_DEMAND
                             || (sfetch_interior16 && sfetch_want_req)
`endif
                             ;
  assign sfetch_demand_size =
`ifdef VEN_SFETCH16_DEMAND
                             sfetch_interior16 ? sfetch_want_size :
`endif
                             sfetch_beat_size_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      sfetch_beat_valid_q <= 1'b0;
      sfetch_beat_size_q <= 3'd0;
    end else if (!sfetch_stage_select &&
                 !((state == S_WALK) && (walk_ret_state == S_FETCH))) begin
      sfetch_beat_valid_q <= 1'b0;
    end else if (sfetch_stage_select) begin
      if (sfetch_beat_valid_q) begin
        if (fsm_case_enabled && mem_req && mem_ack)
          sfetch_beat_valid_q <= 1'b0;
      end else if (sfetch_want_req) begin
        sfetch_beat_valid_q <= 1'b1;
        sfetch_beat_size_q <= sfetch_want_size;
      end
    end
  end
"""


def transform(source, name):
    result = base.transform(source, name)
    if name.endswith('.sv'):
        result = replace_once(result, base.STAGE, STAGE)
    return result
