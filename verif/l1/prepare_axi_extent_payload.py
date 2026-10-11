"""Prepare word extent before late direction/strobe selection; private experiment.

No request, alias-rejection, response, queue, or state equation changes. The
result preserves 32-bit wraparound, including unusual ADDR_MASK geometries.
"""
import hashlib

PARENT = 'ed11478bcf7898e410b5d9bd4f1952d8d3291037f38987c3c01eb935b9b13e38'
OLD = '''  assign alias_last = (m_rd_narrow && !m_we)
                    ? (m_addr + ((32'd1 << m_rd_size) - 32'd1))
                    : {m_addr[31:2], 2'b00} + (alias_two ? 32'd7 : 32'd3);
'''
NEW = '''  // Precompute the word extent without putting the late kind/spill
  // predicate on an adder's carry input. Both payloads retain 32-bit wrap.
  logic [29:0] alias_next_word;
  assign alias_next_word = m_addr[31:2] + 30'd1;
  assign alias_last = (m_rd_narrow && !m_we)
                    ? (m_addr + ((32'd1 << m_rd_size) - 32'd1))
                    : (alias_two ? {alias_next_word, 2'b11}
                                 : {m_addr[31:2], 2'b11});
'''
PAIR_OLD = '''  assign pair_alias_last = {m_pair_addr[31:2], 2'b00} +
                           ((pair_alias_ssh[7:4] != 4'd0) ? 32'd7 : 32'd3);
'''
PAIR_NEW = '''  logic [29:0] pair_alias_next_word;
  assign pair_alias_next_word = m_pair_addr[31:2] + 30'd1;
  assign pair_alias_last = (pair_alias_ssh[7:4] != 4'd0)
                          ? {pair_alias_next_word, 2'b11}
                          : {m_pair_addr[31:2], 2'b11};
'''


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('AXI extent parent source drift')
    if source.count(OLD) != 1 or source.count(PAIR_OLD) != 1:
        raise ValueError('AXI extent equation drift')
    changed = source.replace(OLD, NEW).replace(PAIR_OLD, PAIR_NEW)
    if changed.replace(NEW, OLD).replace(PAIR_NEW, PAIR_OLD) != source:
        raise ValueError('non-reversible extent edit')
    return changed


def block(source):
    start = source.index('  logic [7:0]  alias_ssh;')
    end = source.index('  always_ff @(posedge core_clk or negedge core_rst_n) begin', start)
    return source[start:end]
