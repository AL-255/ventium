"""Prepare backing pair address/strobes before late request qualification.

Private exact-source derivative. Actual requests, read fills, write data and
ordering are unchanged. Idle hints may change only when nobody can consume
pair credit. Assertions retain the complete original backing producer.
"""
import hashlib
import re

PARENT = 'a9a1c8c640f2f5781765ca2f27979a664c1914fb14e4b93c348877b39ad29fae'
FIELDS = dict(m_req=1, m_we=1, m_addr=32, m_wdata=32, m_wstrb=4,
              m_rd_narrow=1, m_rd_size=2, m_pair_req=1, m_pair_addr=32,
              m_pair_wdata=32, m_pair_wstrb=4)
ANCHOR = "    m_req=1'b0; m_we=1'b0; m_addr=32'd0; m_wdata=32'd0; m_wstrb=4'd0;\n"
EARLY = '''`ifdef VEN_P54_DUAL_STORE_PAIR
    // Pair credit consumes address/strobes before m_req. Select its payload
    // from U/V direction, not late route-qualified c_req. Request, stream,
    // cache/permission and paired-admission guards below remain authoritative.
    m_addr=c_addr; m_wstrb=c_wstrb;
`ifdef VEN_P54_LOAD_STORE_PAIR
    if (!c_we) begin m_addr=c_pair_addr; m_wstrb=c_pair_wstrb; end
`endif
`endif
'''


def block(source):
    start = source.index('  always_comb begin\n' + ANCHOR)
    end = source.index('\n  // REVIEW_Jul29 H-13:', start)
    return source[start:end]


def changed_block(source):
    old = block(source)
    assert old.count(ANCHOR) == 1
    fill = "    if (st==L1_FILL) begin\n      m_req  = 1'b1; m_we = 1'b0;\n"
    assert old.count(fill) == 1
    return old.replace(ANCHOR, ANCHOR + EARLY).replace(
        fill, fill + "      m_wstrb = 4'd0; // retain the complete original fill packet\n")


def rename(text, prefix):
    return re.sub(r'\b(' + '|'.join(FIELDS) + r')\b',
                  lambda match: prefix + match[0], text)


def witness(source):
    prefix = 'backing_before_'
    text = '`ifndef SYNTHESIS\n'
    for name, width in FIELDS.items():
        if name.startswith('m_pair_'):
            text += '`ifdef VEN_P54_DUAL_STORE_PAIR\n'
        text += f'  logic [{width-1}:0] {prefix}{name};\n'
        if name.startswith('m_pair_'):
            text += '`endif\n'
    text += rename(block(source), prefix)
    text += '  always_ff @(posedge clk) if (rst_n) begin\n'
    for name in FIELDS:
        if name in ('m_addr', 'm_wstrb'):
            continue
        if name.startswith('m_pair_'):
            text += '`ifdef VEN_P54_DUAL_STORE_PAIR\n'
        text += f'    assert ({name} === {prefix}{name})\n'
        text += f'      else $fatal(1,"BACKING-PAIR-PAYLOAD: {name} changed");\n'
        if name.startswith('m_pair_'):
            text += '`endif\n'
    text += '''    // Compare active transactions AND request-qualified readiness hints,
    // even when a blocked pair has m_req=0. Do not mask backpressured credit.
    if (m_req || ((st == L1_IDLE) && c_req && !stream_path &&
`ifdef VEN_P54_LOAD_STORE_PAIR
                  1'b1
`else
                  c_we
`endif
                 )) begin
      assert ({m_addr,m_wstrb} === {backing_before_m_addr,backing_before_m_wstrb})
        else $fatal(1,"BACKING-PAIR-PAYLOAD: consumed payload/credit changed");
    end
  end
`endif
'''
    return text


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('backing pair payload predecessor drift/reapplication')
    return source.replace(block(source), changed_block(source) + witness(source))
