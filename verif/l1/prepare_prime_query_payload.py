"""Select resident-query payload by owner, not late request qualification.

Private exact-parent experiment. Only idle/unoffered payloads may differ;
request, commit, translation, cache admission and architectural state do not.
"""
import hashlib
import re

PAYLOAD = 'rtl/core/core_mem_chain.svh'
PARENT = 'fd0325d25511950f6761e73f3b2b9ce6ea8ec81c38692203b048954de65ecd5c'


def assignment(source, name):
    rows = re.findall(r'  assign '+name+r' = .*?;\n', source, re.S)
    if len(rows) != 1:
        raise ValueError('ambiguous assignment: '+name)
    return rows[0]


def witness(source):
    old_addr = assignment(source, 'mem_next_addr').replace(
        'mem_next_addr =', 'prime_payload_old_addr =')
    old_strb = assignment(source, 'mem_next_wstrb').replace(
        'mem_next_wstrb =', 'prime_payload_old_strb =')
    return '''`ifndef SYNTHESIS
  logic [31:0] prime_payload_old_addr;
  logic [3:0] prime_payload_old_strb;
'''+old_addr+old_strb+'''  always_ff @(posedge clk) if (rst_n) begin
    assert (!mem_next_commit || mem_next_req)
      else $fatal(1, "PRIME-PAYLOAD: commit without request");
    if (mem_next_req) begin
      assert ({mem_next_addr,mem_next_wstrb} ===
              {prime_payload_old_addr,prime_payload_old_strb})
        else $fatal(1, "PRIME-PAYLOAD: offered address/width changed");
      assert (!mc_prime_offer || !mc_valid_q)
        else $fatal(1, "PRIME-PAYLOAD: live prime collided with retained owner");
    end
  end
`endif
'''


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('prime payload predecessor drift/reapplication')
    changed = source
    for name in ('mem_next_addr', 'mem_next_wstrb'):
        old = assignment(source, name)
        if old.count('mc_prime_offer') != 1:
            raise ValueError('prime selection changed: '+name)
        changed = changed.replace(old, old.replace('mc_prime_offer', '!mc_valid_q'))
    anchor = assignment(changed, 'mem_next_addr')
    explanation = '''  // OFFER still owns admission. Retained versus live payload selection
  // depends only on the registered owner: every live prime excludes it,
  // and every retained offer requires it. AGI/reference selectors keep
  // their original priority. Do not put late permission/branch/decode
  // qualification before the downstream address-region comparison.
'''
    return changed.replace(anchor, explanation+anchor+witness(source))
