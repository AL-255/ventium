"""Remove impossible next-lookup dependencies from L1 paired readiness.

Apply only to a new private derivative. The exact predecessor hash protects
the implications used below; no request, array update or response is added.
"""
import hashlib
import re

PARENT = '61161ec0f9231f3c6c714f66552828381192cb29191f6984368447bca744143e'
READY_PATTERN = r'  assign c_pair_ready = .*?;\n(?=  assign c_pair_ack)'
CAPTURE_PATTERN = r'  assign pair_store_read_capture = .*?;\n(?=`else)'

NEW_READY = """`ifdef VEN_P54_LOAD_STORE_PAIR
  logic pair_current_hit, pair_read_owned;
`ifdef VEN_PIPE_MEM_CHAIN
  assign pair_current_hit = |tag_current_hit;
`else
  assign pair_current_hit = hit;
`endif
  // Identity only: the common readiness predicate below supplies the same
  // hit, invalidation, mode and extent checks as window/shadow reuse.
  assign pair_read_owned = rd_match
`ifdef VEN_L1D_WINDOW_REUSE
      || (window_valid_q && (c_addr[31:5] == rd_addr_q[31:5]))
`ifdef VEN_L1D_TWO_WINDOW_REUSE
      || (shadow_valid_q && (c_addr[31:5] == shadow_line_addr_q))
`endif
`endif
      ;
`endif
  // c_req excludes prime lookup; c_we excludes old-response lookahead.
  // For a read, only c_next_req && rd_match can redirect the lookup here.
  // Aligned full dwords cannot cross a 32-byte line, so neither xline nor
  // the selected next-address/tag mux belongs in this readiness cone.
  assign c_pair_ready = rst_n && c_req && cacheable && !golden &&
      !flush_all && !snoop_inv_valid && (st == L1_IDLE) &&
`ifdef VEN_P54_LOAD_STORE_PAIR
      (c_we ? m_pair_ready :
       (pair_read_owned && pair_current_hit && !early_armed
`ifdef VEN_L1D_CODE_BUFFER
        && !code_access
`endif
`ifdef VEN_PIPE_MEM_CHAIN
        && !(c_next_req && rd_match)
`endif
       )) &&
`else
      c_we && m_pair_ready &&
`endif
      !stream_path &&
      (c_addr[1:0] == 2'd0) && (c_pair_addr[1:0] == 2'd0) &&
      (c_addr[4:2] != c_pair_addr[4:2]) &&
      (c_wstrb == 4'hf) && (c_pair_wstrb == 4'hf);
"""

NEW_CAPTURE = """  // This is an aligned current store: c_req && c_we makes both
  // next-lookup selectors false, and the dword cannot cross a line.
  assign pair_store_read_capture = (pair_req_valid == 2'b10) &&
      c_req && c_we && c_ack && cacheable && !golden &&
      (st == L1_IDLE) && !stream_path &&
      !early_armed && !flush_all && !snoop_inv_valid &&
`ifdef VEN_P54_DUAL_STORE_PAIR
      !c_pair_req &&
`endif
      (c_addr[1:0] == 2'd0) && (c_wstrb == 4'hf);
"""


def extract(source, pattern):
    matches = re.findall(pattern, source, re.S)
    if len(matches) != 1:
        raise ValueError('paired readiness anchor drift')
    return matches[0]


def witness(old, output):
    name = output + '_before_cut'
    return ("`ifndef SYNTHESIS\n  logic " + name + ';\n' +
            old.replace('assign '+output+' =', 'assign '+name+' =') +
            '  always_ff @(posedge clk) if (rst_n)\n' +
            '    assert ('+output+' === '+name+')\n' +
            '      else $fatal(1,"PAIR-READY-COFACTOR: '+output+'");\n' +
            '`endif\n')


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('paired readiness predecessor drift')
    result = source
    for pattern, replacement, output in (
            (READY_PATTERN, NEW_READY, 'c_pair_ready'),
            (CAPTURE_PATTERN, NEW_CAPTURE, 'pair_store_read_capture')):
        old = extract(source, pattern)
        result = result.replace(old, replacement + witness(old, output))
    return result
