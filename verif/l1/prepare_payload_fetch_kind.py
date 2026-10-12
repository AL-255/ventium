"""Refine the private payload-only hint; never change mem_code or cur_is_d.

The source-extracted S_PIPE request test checks the conditional equivalence.
Whole-core qualification is still required. No new execution mode or flag.
"""
import hashlib

PARENT = '385b7c2e4c80ca0f82c0742c8cd60ba39be0c8f21198f2835847cad5430b8cf7'
OLD = '  assign mem_payload_code = !cur_is_d;'
NEW = '''  // For an issued S_PIPE beat, pf_miss identifies exactly the I-fill
  // alternative. New data issues require pipe_frontend_ready (pipe_bytes_ok);
  // pf_miss requires !pipe_bytes_ok and !pipe_mem_active_q. A held data owner
  // therefore cannot become a fetch after executable-line invalidation.
  // This cofactor is ONLY a payload hint, never translation or bus authority.
  assign mem_payload_code = (state == S_PIPE) ? pf_miss : !cur_is_d;
`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n && mem_req) begin
    assert (mem_payload_code === !cur_is_d)
      else $fatal(1, "PAYLOAD-FETCH-KIND: changed issued access classification");
  end
`endif'''


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT or source.count(OLD) != 1:
        raise ValueError('payload-hint predecessor drift/reapplication')
    return source.replace(OLD, NEW)
