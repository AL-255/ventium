"""Private FP-only wide-valid cofactor of the audited PAYLOAD-REGION snapshot.

Retain the general high-valid output unchanged. A separate *contextual*
candidate omits only next-request arbitration and is consumed solely in
S_FLOAD; every lookahead offer requires the distinct S_PIPE state. No request,
ACK, data mux, register, clock, mode or architectural cycle is changed.
"""
import hashlib
import re

PARENTS = {
    'rtl/core/core.sv': '7b6dcfe3c35b07bca3016c178cf81ebfb7cf104ea30d17e10b6f40b4c8a4506f',
    'rtl/ventium_top.sv': 'd0b07744fb6c52a09324fc31fe338c847eac396f5137e628f3d35d6484102202',
    'rtl/mem/ventium_l1_axi.sv': '1ba072672d09c4228017e64c11d3dd0506c4bddb5dc5a1a72924ea6defc2015d',
    'rtl/mem/ven_l1d.sv': '3a11ad8b8ce9e7569b0b1b144fe3666414186046e8e05fc1aff82e8aa5f1b874',
}
OFFER_PINS = {
    'rtl/core/core_mem_chain.svh': '3630952571613ece5b9845f641f0adfba0fa43cd14f99a72bc5802723e5fbaac',
    'rtl/core/core_ref_operand_prime.svh': 'e4a31829ed91c44ccfdb5e96350c95f3953c8c6d746a97b3b25c094b5be35399',
    'rtl/core/core_agi_resident_prime.svh': '818dbc33998087af6849f5ca3177733f7ab05de38e670b9a6e470e2fe275d092',
}
ARBITRATION = '''`ifdef VEN_PIPE_MEM_CHAIN
`ifdef VEN_P54_DUAL_STORE_PAIR
      && (c_pair_intent || !(c_next_req && rd_match))
`else
      && !(c_next_req && rd_match)
`endif
`endif
'''


def assignment(source, name):
    rows = re.findall(r'^  assign '+name+r'\s*=.*?;\n', source, re.M | re.S)
    rows = [row for row in rows if "= 1'b0;" not in row]
    if len(rows) != 1:
        raise ValueError('wide-context assignment drift: '+name)
    return rows[0]


def validate_sources(inputs):
    for path, digest in {**PARENTS, **OFFER_PINS}.items():
        if path not in inputs or hashlib.sha256(inputs[path].encode()).hexdigest() != digest:
            raise ValueError('wide-context complete source drift: '+path)


def edits(source, path):
    if path == 'rtl/core/core.sv':
        port = '    input  logic        bus_rdata_hi_valid,'
        old = assignment(source, 'fp_load64_take')
        assert old.count('bus_rdata_hi_valid') == 1 and '(state == S_FLOAD)' in old
        witness = '''`ifndef SYNTHESIS
  // The contextual candidate is not a general bus grant. Only this state
  // consumes it; all four lookahead offers require S_PIPE instead.
  always_ff @(posedge clk) if (rst_n && state == S_FLOAD) begin
`ifdef VEN_PIPE_MEM_CHAIN
    assert (!mem_next_req)
      else $fatal(1,"FP-WIDE-CONTEXT: lookahead overlaps FLOAD");
`endif
    assert (bus_rdata_hi_uncontended === bus_rdata_hi_valid)
      else $fatal(1,"FP-WIDE-CONTEXT: FLOAD high-valid changed");
  end
`endif
'''
        return [(port, port+'''
    // Same high response validity ONLY in S_FLOAD; not a general ACK.
    input  logic        bus_rdata_hi_uncontended,'''),
                (old, old.replace('bus_rdata_hi_valid', 'bus_rdata_hi_uncontended')+witness)]
    if path == 'rtl/ventium_top.sv':
        return [(old, old+'\n'+new) for old, new in (
            ('  logic        core_mem_rdata_hi_valid;', '  logic        core_mem_rdata_hi_uncontended;'),
            ('  logic        l1_c_rdata_hi_valid;', '  logic        l1_c_rdata_hi_uncontended;'),
            ('      .bus_rdata_hi_valid(core_mem_rdata_hi_valid),',
             '      .bus_rdata_hi_uncontended(core_mem_rdata_hi_uncontended),'),
            ('      .core_rdata_hi_valid(l1_c_rdata_hi_valid),',
             '      .core_rdata_hi_uncontended(l1_c_rdata_hi_uncontended),'),
            ('  assign core_mem_rdata_hi_valid = l1axi_en && l1_c_rdata_hi_valid;',
             '  assign core_mem_rdata_hi_uncontended = l1axi_en && l1_c_rdata_hi_uncontended;'),
            ("  assign core_mem_rdata_hi_valid = 1'b0;",
             "  assign core_mem_rdata_hi_uncontended = 1'b0;"))]
    if path == 'rtl/mem/ventium_l1_axi.sv':
        old = assignment(source, 'core_rdata_hi_valid')
        new = old.replace('core_rdata_hi_valid', 'core_rdata_hi_uncontended').replace(
            'l1d_c_rdata_hi_valid', 'l1d_c_rdata_hi_uncontended')
        return [(before, before+'\n'+after) for before, after in (
            ('    output logic        core_rdata_hi_valid,',
             '    output logic        core_rdata_hi_uncontended, // contextual FP-only candidate'),
            ('  logic        l1d_c_rdata_hi_valid;', '  logic        l1d_c_rdata_hi_uncontended;'),
            ('      .c_rdata_hi_valid(l1d_c_rdata_hi_valid),',
             '      .c_rdata_hi_uncontended(l1d_c_rdata_hi_uncontended),'))] + [(old, old+new)]
    if path == 'rtl/mem/ven_l1d.sv':
        port = '    output logic        c_rdata_hi_valid,'
        old = assignment(source, 'c_rdata_hi_valid')
        if old.count(ARBITRATION) != 1:
            raise ValueError('wide-context arbitration scope drift')
        new = old.replace('c_rdata_hi_valid', 'c_rdata_hi_uncontended').replace(ARBITRATION, '')
        comment = '''  // Contextual candidate, NOT a replacement ACK/high-valid grant.
  // The sole core consumer is S_FLOAD, which excludes every lookahead offer.
  // Keep all owner, residency, extent, cacheability, reset and invalidation
  // checks. The ordinary output above retains next-port arbitration exactly.
'''
        monitor = '''`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n
`ifdef VEN_PIPE_MEM_CHAIN
                              && !c_next_req
`endif
                             )
    assert (c_rdata_hi_uncontended === c_rdata_hi_valid)
      else $fatal(1,"FP-WIDE-CONTEXT: uncontended leaf validity changed");
`endif
'''
        return [(port, port+'\n    output logic        c_rdata_hi_uncontended, // valid only with no next request'),
                (old, old+comment+new+monitor)]
    raise ValueError(path)


def transform(source, path):
    if path not in PARENTS or hashlib.sha256(source.encode()).hexdigest() != PARENTS[path]:
        raise ValueError('wide-context parent drift/reapplication: '+path)
    result = source
    for old, new in edits(source, path):
        if result.count(old) != 1:
            raise ValueError('wide-context ambiguous anchor: '+old[:100])
        result = result.replace(old, new)
    return result
