"""Draft a separate intent-only paired-store readiness result in private RTL.

Preserve the ordinary readiness port and every original assertion. Only
consumers with a checked intent may use the cofactor. This is not integrated
or timing-qualified; direct cache testbenches need the new output connected.
"""
import hashlib
import re

from prove_pair_intent_ready import extract

PARENTS = {
    'rtl/mem/ven_l1d.sv': '182856870bdf5627a2c0c48180fbb2a2a604b679728b40d53e9811bb1df31d37',
    'rtl/mem/ventium_l1_axi.sv': 'c29c4503b1980f92d96847a3f22959b47dc5c6ae83fd4bc9ade099749d093be0',
}
CORE = '7b6dcfe3c35b07bca3016c178cf81ebfb7cf104ea30d17e10b6f40b4c8a4506f'


def caller_contract(core, seam):
    """Reject a caller that observes the cofactor without its intent premise."""
    assert hashlib.sha256(core.encode()).hexdigest() == CORE
    assert hashlib.sha256(seam.encode()).hexdigest() == PARENTS['rtl/mem/ventium_l1_axi.sv']
    assert len(re.findall(r'\bmem_store_pair_ready\b', core)) == 2
    assert core.count('assign mem_store_pair_intent = pipe_store_pair_offer;') == 1
    assert core.count('assign mem_store_pair_req = pipe_store_pair_offer && mem_store_pair_ready;') == 1
    assert seam.count('.c_pair_intent(core_store_pair_intent && l1d_c_req)') == 1
    assert seam.count('.c_pair_req(core_store_pair_req && l1d_c_req)') == 1


def edits(source, name):
    if name == 'rtl/mem/ven_l1d.sv':
        old, fast = extract(source)
        fast = fast.replace('assign pair_intent_ready =', 'assign c_pair_intent_ready =')
        added = '''  // This additional result is valid only under c_pair_intent.
  // Intent already wins lookup arbitration; ordinary c_pair_ready retains
  // its complete no-intent semantics. Never use this result unqualified.
'''+fast+'''`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n && c_pair_intent)
    assert (c_pair_intent_ready === c_pair_ready)
      else $fatal(1,"INTENT-READY: changed intent-qualified readiness");
`endif
'''
        result = [
            ('    output logic        c_pair_ready,',
             '    output logic        c_pair_ready,\n    output logic        c_pair_intent_ready,', 1),
            (old,old+added,1),
            ('  assign c_pair_ack = c_pair_req && c_pair_ready && c_ack &&',
             '  assign c_pair_ack = c_pair_req && c_pair_intent_ready && c_ack &&',1),
            ('        m_req = c_pair_ready;', '        m_req = c_pair_intent_ready;',1),
            ('        m_pair_req = c_pair_ready;', '        m_pair_req = c_pair_intent_ready;',1),
            ('      m_req=c_pair_req && c_pair_ready;',
             '      m_req=c_pair_req && c_pair_intent_ready;',1),
            ('        if (c_pair_req) c_ack = c_pair_ready && m_ack && m_pair_ack;',
             '        if (c_pair_req) c_ack = c_pair_intent_ready && m_ack && m_pair_ack;',2),
        ]
    elif name == 'rtl/mem/ventium_l1_axi.sv':
        old = '''  assign core_store_pair_ready = l1d_c_req && !core_smram_deny &&
      !core_route_deny && !dma_drain_stall && !store_pair_smram_deny &&
      store_pair_l1c && store_pair_dram && !cr0_cd && l1d_store_pair_ready;
'''
        new = old.replace('&& l1d_store_pair_ready;', '&& l1d_store_pair_intent_ready;')
        witness = '''`ifndef SYNTHESIS
  logic core_store_pair_ready_before_intent_cut;
'''+old.replace('assign core_store_pair_ready =', 'assign core_store_pair_ready_before_intent_cut =')+'''  always_ff @(posedge core_clk) if (seam_core_rst_n) begin
    if (core_store_pair_intent)
      assert (core_store_pair_ready === core_store_pair_ready_before_intent_cut)
        else $fatal(1,"INTENT-READY: seam qualification changed");
    assert (!core_store_pair_req || core_store_pair_intent)
      else $fatal(1,"INTENT-READY: paired request lacks checked intent");
  end
`endif
'''
        result = [
            ('  logic l1d_store_pair_ready, l1d_store_pair_ack;',
             '  logic l1d_store_pair_ready, l1d_store_pair_ack;\n  logic l1d_store_pair_intent_ready;',1),
            (old,new+witness,1),
            ('      .c_pair_ready(l1d_store_pair_ready),',
             '      .c_pair_ready(l1d_store_pair_ready),\n      .c_pair_intent_ready(l1d_store_pair_intent_ready),',1),
        ]
    else:
        raise ValueError(name)
    return result


def transform(source, name):
    if name not in PARENTS or hashlib.sha256(source.encode()).hexdigest() != PARENTS[name]:
        raise ValueError('intent-ready source drift/reapplication: '+name)
    result = source
    for old,new,count in edits(source,name):
        if result.count(old) != count:
            raise ValueError('intent-ready anchor drift: '+old)
        result = result.replace(old,new)
    return result
