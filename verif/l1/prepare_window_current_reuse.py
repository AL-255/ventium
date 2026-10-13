"""Exact saved-window cofactor; private derivative, never edit a pinned export.

Current reads exclude mc_lookup_prime. Under the unchanged reuse guards,
mc_lookup_old reduces to next_req && rd_match && !paired-store-intent.
The tag mux must select current tags when that arbitration permits reuse.
No new state, port, flag, cache capacity or architectural cycle is introduced.
"""
import hashlib
import re

PARENT = 'd565f12a984a4e83c8816a0214705999033a2c0906ad66f44f27d5b117b4d4f8'
ANCHOR = '''  // Reuse the first complete resident line of the existing registered window.
'''
HELPER = '''  // Reuse serves only a current, idle, cacheable read. Prime lookup has
  // !c_req, so it cannot apply here; old-owner lookup still arbitrates below.
  // Compare current tags directly, not the selected-next hit mux. This is
  // equivalent for every leaf input, not a promise from one core consumer.
  logic window_current_hit;
`ifdef VEN_PIPE_MEM_CHAIN
  assign window_current_hit = |tag_current_hit;
`else
  assign window_current_hit = hit;
`endif
'''
ARBITRATION = '''
`ifdef VEN_PIPE_MEM_CHAIN
`ifdef VEN_P54_DUAL_STORE_PAIR
      && (c_pair_intent || !(c_next_req && rd_match))
`else
      && !(c_next_req && rd_match)
`endif
`endif
'''


def equation(source, name):
    rows = re.findall(r'^  assign '+name+r'\s*=.*?;\n', source, re.M | re.S)
    rows = [s for s in rows if "= 1'b0;" not in s]
    if len(rows) != 1:
        raise ValueError('window reuse equation drift: '+name)
    return rows[0]


def replacement(old):
    assert old.count('!mc_lookup_next && ') == 1
    assert old.count('&& hit &&') == 1 and old.count(';\n') == 1
    return old.replace('!mc_lookup_next && ', '').replace('&& hit &&',
        '&& window_current_hit &&').replace(';\n', ARBITRATION+'      ;\n')


def witness(old, name):
    reference = name+'_before_current_cut'
    return ('`ifndef SYNTHESIS\n  logic '+reference+';\n'+
        old.replace('assign '+name+' =', 'assign '+reference+' =')+
        '  always_ff @(posedge clk) if (rst_n)\n'
        '    assert ('+name+' === '+reference+')\n'
        '      else $fatal(1,"WINDOW-CURRENT-REUSE: '+name+'");\n'
        '`endif\n')


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('window-current parent drift/reapplication')
    assert source.count(ANCHOR) == 1
    result = source.replace(ANCHOR, HELPER+ANCHOR)
    for name in ('window_reuse', 'shadow_reuse'):
        old = equation(source, name)
        assert result.count(old) == 1
        result = result.replace(old, replacement(old)+witness(old, name))
    return result
