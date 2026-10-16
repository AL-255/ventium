"""Private timing experiment: register an exact, demanded slow-fetch beat.

No production edit and no extra stage on the U/V fast path. The experiment
costs one preparation clock per boundary/interior-16 demand beat. It must earn
promotion by measured throughput and physical timing, not by source inspection.
"""
import hashlib

PARENTS = {
    'rtl/core/core.sv': '2739f38f16c8f929d2890f516917cce66aa23f793e8af326bb0a374785b5f4cb',
    'rtl/core/core_fetch_decode.svh': 'd109aa12a2fa0a37ca75bd1fa1e2b5e72d8b0aaa7774ada032f283234ebc0517',
}

STAGE = """  // Only an exact demanded S_FETCH beat is staged. Neither a speculative
  // successor instruction nor an S_PIPE data access acquires this owner.
  // The existing MMU/segment/fragment/response machinery still authorizes and
  // completes the beat. A page walk is a detour of this owner, not a new beat.
  logic sfetch_beat_valid_q;
  logic [2:0] sfetch_beat_size_q;
  assign sfetch_demand_req = (state == S_FETCH) && sfetch_boundary &&
                             sfetch_beat_valid_q;
  assign sfetch_demand_size = sfetch_beat_size_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      sfetch_beat_valid_q <= 1'b0;
      sfetch_beat_size_q <= 3'd0;
    end else if (!((state == S_FETCH) && sfetch_boundary) &&
                 !((state == S_WALK) && (walk_ret_state == S_FETCH))) begin
      sfetch_beat_valid_q <= 1'b0;
    end else if ((state == S_FETCH) && sfetch_boundary) begin
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

WITNESS = """
`ifndef SYNTHESIS
  // The original length/header policy remains an independent reference. The
  // buffered instruction and valid count may change only on the accepted beat;
  // no permission, trap, or byte-count result is guessed by this stage.
  always_ff @(posedge clk) if (rst_n && sfetch_demand_req) begin
    assert (sfetch_want_req && sfetch_demand_size === sfetch_want_size)
      else $fatal(1, "SFETCH-BEAT-STAGE: stale demand owner");
  end
`endif
"""


def replace_once(text, before, after):
    if text.count(before) != 1:
        raise ValueError('fetch-beat source shape drift: ' + before[:80])
    return text.replace(before, after, 1)


def transform(source, name):
    if hashlib.sha256(source.encode()).hexdigest() != PARENTS[name]:
        raise ValueError('fetch-beat parent drift/reapplication: ' + name)
    if name.endswith('.svh'):
        # A temporarily unissued beat is not a completed instruction. Keep the
        # original semantic completion condition, independent of staged valid.
        return replace_once(source, '(!sfetch_demand_req && d_fetch_meta_ready)',
                            '(!sfetch_want_req && d_fetch_meta_ready)')
    start = source.index('  assign sfetch_demand_req = ')
    end = source.index('\n`ifndef SYNTHESIS', start)
    original = source[start:end]
    raw = original.replace('sfetch_demand_req', 'sfetch_want_req').replace(
        'sfetch_demand_size', 'sfetch_want_size')
    raw = '  logic sfetch_want_req;\n  logic [2:0] sfetch_want_size;\n' + raw
    return source[:start] + raw + STAGE + WITNESS + source[end:]
