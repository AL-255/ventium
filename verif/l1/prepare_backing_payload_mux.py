"""Factor backing payload selection out of request-qualified branches.

Private derivative of the retained prefix-payload parent. Unlike the earlier
early-hint change, every output must remain identical even without a request.
No request, credit, cache-policy, latency or state equation changes.
"""
import hashlib
import re

from prepare_backing_pair_payload import ANCHOR, EARLY, FIELDS, rename

PARENT = '62d3332d4d044efe022acce33eaa99b16e9a36da7a43e4afeda0b0265baeb3f3'
END = '\n`ifndef SYNTHESIS\n  logic [0:0] backing_before_m_req;'
FILL_ELSE = '''      end else
      // H-19: during the extra beat, address the NEXT line's word 0.
      m_addr = byp_hi_beat ? ({fbase[31:5], 5'd0} + 32'd32)
                           : ({fbase[31:5], 5'd0} + {27'd0, fill_word, 2'b00});'''
PAYLOAD = '''  // Credit is queried before request admission. Keep its payload mux
  // independent of c_req, stream_path and pair-ready; those still authorize
  // transactions in the unchanged control producer below.
  always_comb begin
    m_addr = c_addr;
    m_wstrb = c_wstrb;
`ifdef VEN_P54_LOAD_STORE_PAIR
    if (!c_we) begin
      m_addr = c_pair_addr;
      m_wstrb = c_pair_wstrb;
    end
`endif
    if (st == L1_FILL) begin
      m_wstrb = 4'd0;
      if (bypass_q)
        m_addr = {fbase[31:2], 2'd0} + {29'd0, byp_off_q[fw[1:0]]};
      else
        m_addr = byp_hi_beat ? ({fbase[31:5], 5'd0} + 32'd32)
                 : ({fbase[31:5], 5'd0} + {27'd0, fill_word, 2'b00});
    end
  end
'''


def block(source):
    begin = source.index('  always_comb begin\n' + ANCHOR)
    return source[begin:source.index(END, begin)]


def changed_block(source):
    old = block(source)
    if old.count(EARLY) != 1 or old.count(FILL_ELSE) != 1:
        raise ValueError('backing producer structure drift')
    control = old.replace(EARLY, '').replace(FILL_ELSE, '      end')
    control, count = re.subn(r'\bm_(?:addr|wstrb)\s*=\s*[^;]+;', '', control)
    if count != 8:
        raise ValueError(f'backing payload assignment count drift: {count}')
    return ('`ifdef VEN_P54_DUAL_STORE_PAIR\n' + PAYLOAD + control +
            '`else\n' + old + '`endif\n')


def witness(source):
    prefix = 'payload_mux_before_'
    out = '`ifndef SYNTHESIS\n'
    for name, width in FIELDS.items():
        if name.startswith('m_pair_'):
            out += '`ifdef VEN_P54_DUAL_STORE_PAIR\n'
        out += f'  logic [{width-1}:0] {prefix}{name};\n'
        if name.startswith('m_pair_'):
            out += '`endif\n'
    out += rename(block(source), prefix)
    out += '  always_ff @(posedge clk) if (rst_n) begin\n'
    for name in FIELDS:
        if name.startswith('m_pair_'):
            out += '`ifdef VEN_P54_DUAL_STORE_PAIR\n'
        out += f'    assert ({name} === {prefix}{name})\n'
        out += f'      else $fatal(1,"BACKING-PAYLOAD-MUX: {name} changed");\n'
        if name.startswith('m_pair_'):
            out += '`endif\n'
    return out + '  end\n`endif\n'


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('backing payload mux parent drift/reapplication')
    old = block(source)
    return source.replace(old, changed_block(source) + witness(source), 1)
