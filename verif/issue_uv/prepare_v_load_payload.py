"""Private V-load data selector cut; no change to admission or write enables.

Only the RAW/non-dual-prime profile has the existing invariant that a held V
response owns an active U read. Immediate acceptance requires !active, so the
two data owners are exclusive. Keep the original selector in other profiles.
This recipe prepares sources; it does not qualify or deploy them.
"""
import hashlib

PARENTS = {
    'rtl/core/core.sv': '6c020b3c171fb422756a7874fb48cd32a683953ff5b95d44b708be3a7fa08b1c',
    'rtl/core/core_gpr_wb.svh': '4ae36b71b057a728ce077214173a99fbe653c2215e6b9256cf14dd2dc62c422b',
}
OLD = '''`ifdef VEN_P54_DUAL_BYTE_LOAD_PAIR
                    pipe_v_pair_now_accept ? mem_pair_now_data :
`endif
                    mem_pair_rsp_data[1], fp_operand_width(pipe_v_eff),
'''
# This is a DATA mux only. The enclosing (held || immediate) test and all
# architectural write/retire gates stay byte-identical.
NEW = '''`ifdef VEN_P54_DUAL_BYTE_LOAD_PAIR
`ifdef VEN_RAW_V_READ_PRIME
`ifndef VEN_P54_DUAL_LOAD_PRIME
                    // Held and immediate owners are exclusive in this profile.
                    // Select data with the registered owner, not late acceptance.
                    pipe_mem_v_hit_q ? mem_pair_rsp_data[1] : mem_pair_now_data,
`else
                    pipe_v_pair_now_accept ? mem_pair_now_data : mem_pair_rsp_data[1],
`endif
`else
                    pipe_v_pair_now_accept ? mem_pair_now_data : mem_pair_rsp_data[1],
`endif
`else
                    mem_pair_rsp_data[1],
`endif
                    fp_operand_width(pipe_v_eff),
'''
OWNER = '''    assert (!pipe_mem_v_hit_q || (pipe_mem_active_q && !pipe_mem_we_q))
      else $fatal(1,"PAIR-RESPONSE-COMMIT: V lost its read-only U owner");
'''
WITNESS = '''`ifdef VEN_P54_DUAL_BYTE_LOAD_PAIR
    assert (!(pipe_mem_v_hit_q && pipe_v_pair_now_accept))
      else $fatal(1,"V-LOAD-PAYLOAD: overlapping response owners");
    if (pipe_mem_v_hit_q || pipe_v_pair_now_accept)
      assert ((pipe_v_pair_now_accept ? mem_pair_now_data : mem_pair_rsp_data[1]) ===
              (pipe_mem_v_hit_q ? mem_pair_rsp_data[1] : mem_pair_now_data))
        else $fatal(1,"V-LOAD-PAYLOAD: consumed data changed");
`endif
'''
ACCEPT = '''  assign pipe_v_pair_now_accept = pipe_v_pair_request && mem_pair_now_valid &&
      mem_read_ack && !pipe_mem_active_q;
'''


def transform(sources):
    if set(sources) != set(PARENTS):
        raise ValueError('need both exact writeback/owner sources')
    for path, expected in PARENTS.items():
        if hashlib.sha256(sources[path].encode()).hexdigest() != expected:
            raise ValueError('V-load payload parent drift/reapplication: ' + path)
    core, wb = sources['rtl/core/core.sv'], sources['rtl/core/core_gpr_wb.svh']
    if core.count(OWNER) != 1 or core.count(ACCEPT) != 1 or wb.count(OLD) != 1:
        raise ValueError('V-load owner/acceptance/selector anchor drift')
    result = dict(sources)
    result['rtl/core/core.sv'] = core.replace(OWNER, OWNER + WITNESS)
    result['rtl/core/core_gpr_wb.svh'] = wb.replace(OLD, NEW)
    return result


def payload_assignment(fragment, name):
    """Extract the actual first data argument; retain all SV profile branches."""
    suffix = ', fp_operand_width(pipe_v_eff),\n' if fragment == OLD else '                    fp_operand_width(pipe_v_eff),\n'
    if not fragment.endswith(suffix):
        raise ValueError('unexpected writeback argument boundary')
    expression = fragment[:-len(suffix)]
    # Each branch of NEW already ends in the argument-separator comma.
    if fragment == NEW:
        expression = expression.replace(',\n', '\n')
    return '  assign ' + name + ' =\n' + expression + ';\n'
