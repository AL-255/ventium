"""Private exact-source read-ACK cofactor; does not alter an existing export."""
import hashlib
import re

PARENT = 'a9a1c8c640f2f5781765ca2f27979a664c1914fb14e4b93c348877b39ad29fae'


def assignment(source, name):
    rows = re.findall(r'  assign ' + name + r'\s*=.*?;\n', source, re.S)
    rows = [row for row in rows if "= 1'b0;" not in row]
    if len(rows) != 1:
        raise ValueError('read ACK assignment drift: ' + name)
    return rows[0]


def ack_block(source):
    rows = re.findall(r'  always_comb begin\n    c_read_ack = .*?\n  end\n', source, re.S)
    if len(rows) != 1:
        raise ValueError('read ACK block drift')
    return rows[0]


def helpers(source):
    text = '''  // Under an active read, lookahead requires rd_match. That exact
  // registered owner already acknowledges the read (with cacheability and
  // invalidation guards). Absorb the lookup exclusion in this ACK ONLY;
  // preserve the original reuse/data/capture qualifiers everywhere else.
  logic read_ack_current_hit;
`ifdef VEN_PIPE_MEM_CHAIN
  assign read_ack_current_hit = |tag_current_hit;
`else
  assign read_ack_current_hit = hit;
`endif
  logic read_ack_window_reuse, read_ack_shadow_reuse, read_ack_code_reuse;
'''
    for name, switch in (('window_reuse', 'VEN_L1D_WINDOW_REUSE'),
                         ('shadow_reuse', 'VEN_L1D_TWO_WINDOW_REUSE'),
                         ('code_word_reuse', 'VEN_L1D_CODE_WORD_REUSE')):
        new_name = 'read_ack_' + ('code_reuse' if name == 'code_word_reuse' else name)
        old = assignment(source, name)
        if old.count('!mc_lookup_next && ') != 1:
            raise ValueError('read ACK exclusion drift: ' + name)
        new = old.replace('!mc_lookup_next && ', '')
        new = re.sub(r'\bhit\b', 'read_ack_current_hit', new)
        new = new.replace('assign ' + name, 'assign ' + new_name)
        text += '`ifdef ' + switch + '\n' + new
        text += '`else\n  assign ' + new_name + " = 1'b0;\n`endif\n"
    return text


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('read ACK predecessor drift/reapplication')
    old = ack_block(source)
    new = old.replace('window_reuse || shadow_reuse',
                      'read_ack_window_reuse || read_ack_shadow_reuse')
    new = new.replace('code_word_reuse ||', 'read_ack_code_reuse ||')
    if new == old:
        raise ValueError('read ACK consumer drift')
    return source.replace(old, helpers(source) + new)
