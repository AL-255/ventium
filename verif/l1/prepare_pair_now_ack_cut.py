"""Cut the redundant general ACK from the registered same-line pair result.

Prepare a private copy only. Reusable windows already imply a registered
read acknowledgement; preserve the different combinational-ACK profile.
"""
import hashlib
import re

PARENT = '1d8a499aff0093a0861b20ec9faefee0820672cefe42d47504cd53f9ef71277b'
PATTERN = r'  assign pair_now_valid = .*?;\n'
OLD = '      !pair_rsp_valid[1] && c_req && !c_we && cacheable && c_ack &&\n'
NEW = '''      !pair_rsp_valid[1] && c_req && !c_we && cacheable &&
`ifdef VEN_L1D_COMB_ACK
      c_ack &&
`endif
'''
COMMENT = '''  // Both reusable windows below imply a current cacheable read ACK
  // in the registered response profile and exclude stream-mode override.
  // Do not route backing-write/paired-store ACK selection through this
  // read-only result and back into the fresh V-bank admission decision.
  // Keep c_ack for the distinct combinational-response profile.
'''


def extract(source):
    matches = re.findall(PATTERN, source, re.S)
    if len(matches) != 1:
        raise ValueError('ambiguous same-line pair return')
    return matches[0]


def witness(original):
    return ("`ifndef SYNTHESIS\n  logic pair_now_before_ack_cut;\n" +
            original.replace('assign pair_now_valid =', 'assign pair_now_before_ack_cut =') +
            '  always_ff @(posedge clk) if (rst_n)\n' +
            '    assert (pair_now_valid === pair_now_before_ack_cut)\n' +
            '      else $fatal(1,"PAIR-NOW-ACK: changed same-line response");\n' +
            '`endif\n')


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('same-line ACK predecessor drift')
    original = extract(source)
    if original.count(OLD) != 1 or '(window_reuse || shadow_reuse)' not in original:
        raise ValueError('same-line ownership guard drift')
    return source.replace(original, COMMENT+original.replace(OLD, NEW)+witness(original))
