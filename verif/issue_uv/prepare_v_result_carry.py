"""Private V arithmetic carry cut; preserve its architectural flag carry.

ADC/SBB are U-only. Accepted V arithmetic never consumes CF for its result,
but INC/DEC must preserve U's post-operation CF in their flags. No issue or
commit gate changes, no new cycle or register, no source changes outside these
two exact predecessors. The runtime witness checks actual accepted V packets.
"""
import hashlib

HASHES = {
    'rtl/core/v_pipe.sv': 'c6686a33a661d13e52f8b0bc715d22ac14bbd870b5788497253ebb3411c29cf1',
    'rtl/core/core.sv': '1430e18b5c039ab2ebb69e7cdf14d114ae6d0ee1dd4b63c72c2f4f2207b34076',
}
OLD = '    v_alu   = alu_result(v_d.alu_op, v_a_w, v_b_w, eflags[0]);\n'
NEW = '''    // ADC/SBB cannot execute in V (decode/issue require pairs_second).
    // No accepted V result consumes carry. Keep the real forwarded EFLAGS
    // below: INC/DEC must still preserve the preceding U instruction's CF.
    v_alu   = alu_result(v_d.alu_op, v_a_w, v_b_w, 1'b0);
'''
ANCHOR = '  // ===========================================================================\n  // BTB resolve port (R2 extract, bpred_btb).'
WITNESS = '''`ifndef SYNTHESIS
  // Check the committed descriptor, including held and memory-paired packets;
  // an ineligible transient decode is deliberately not a retirement witness.
  always_ff @(posedge clk) if (rst_n && pipe_int_commit && pipe_pair_eff) begin
    assert (pipe_v_eff.pairs_second &&
            pipe_v_eff.alu_op != ALU_ADC && pipe_v_eff.alu_op != ALU_SBB)
      else $fatal(1,"V-RESULT-CARRY: ineligible carry consumer committed in V");
    if ($test$plusargs("ven_v_result_carry_witness"))
      $display("[V-RESULT-CARRY] pc=%08x op=%0d held=%0b cf=%0b",
               pipe_commit_eip, pipe_v_eff.alu_op, pipe_mem_active_q, v_input_flags[0]);
  end
`endif

'''


def transform(source, name):
    if name not in HASHES or hashlib.sha256(source.encode()).hexdigest() != HASHES[name]:
        raise ValueError('V-result predecessor drift/reapplication: '+name)
    if name.endswith('/v_pipe.sv'):
        if source.count(OLD) != 1: raise ValueError('V-result equation is not unique')
        return source.replace(OLD,NEW)
    if source.count(ANCHOR) != 1: raise ValueError('V-commit witness anchor is not unique')
    return source.replace(ANCHOR,WITNESS+ANCHOR)
