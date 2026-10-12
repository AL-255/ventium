"""Private, default-off payload-only code-kind sideband timing proposal.

Never rewrite request-qualified mem_code/code_access: the AXI wrapper can deny
or stall a request after core_req. Only data muxes may use the earlier hint.
The four-file parent is the frozen MC+PAIR+SRT candidate, not the dirty checkout.
This recipe does not publish a qualified core or modify the running synthesis.
"""
import hashlib

FLAG = 'VEN_L1D_PAYLOAD_CODE_HINT'
HASHES = {
    'rtl/core/core.sv': '8d0c3c35eca0c3ea97981d3f33178ef0c656a2eb90f27faea97fe998ab5e24a0',
    'rtl/ventium_top.sv': 'a325538d58543afa5e4b8585e0f4a8b0baa05c5562fa666a1c41547b6c4c1379',
    'rtl/mem/ventium_l1_axi.sv': '2cb00ba4d8365c9d95423fa24c17e32d26eea765be9733fbeb8363ece22b85c5',
    'rtl/mem/ven_l1d.sv': '1d8a499aff0093a0861b20ec9faefee0820672cefe42d47504cd53f9ef71277b',
}


def replace(source, old, new):
    if source.count(old) != 1:
        raise ValueError('missing/ambiguous anchor: '+old[:100])
    return source.replace(old, new)


def guard(body):
    return '`ifdef '+FLAG+'\n'+body+'\n`endif'


def choice(old, new):
    return '`ifdef '+FLAG+'\n'+new+'\n`else\n'+old+'\n`endif'


def select_hint_branch(source, enabled):
    """Resolve ONLY this proposal flag, keeping all other preprocessor guards."""
    result, stack = [], []
    for line in source.splitlines(keepends=True):
        item = line.strip()
        if item == '`ifdef '+FLAG:
            stack.append([enabled, 0])
        elif stack:
            if item.startswith(('`ifdef ', '`ifndef ')):
                stack[-1][1] += 1
            elif item == '`endif':
                if stack[-1][1] == 0:
                    stack.pop()
                    continue
                stack[-1][1] -= 1
            elif item == '`else' and stack[-1][1] == 0:
                stack[-1][0] = not stack[-1][0]
                continue
            if stack and all(level[0] for level in stack):
                result.append(line)
        else:
            result.append(line)
    if stack:
        raise ValueError('unclosed hint profile guard')
    return ''.join(result)


def transform(inputs):
    if set(inputs) != set(HASHES):
        raise ValueError('need all four exact interface sources')
    for path, digest in HASHES.items():
        if hashlib.sha256(inputs[path].encode()).hexdigest() != digest:
            raise ValueError('parent drift or reapplication: '+path)
    result = dict(inputs)
    for path, rows in {
        'rtl/core/core.sv': (
            ('    output logic        mem_code,', '    output logic        mem_payload_code,'),
            ('  assign mem_code = mem_req && !cur_is_d;',
             '  // Data-selection hint only: no request, permission, ACK or cache state authority.\n'
             '  assign mem_payload_code = !cur_is_d;')),
        'rtl/ventium_top.sv': (
            ('  logic        core_mem_code;', '  logic        core_mem_payload_code;'),
            ('      .mem_code     (core_mem_code),', '      .mem_payload_code(core_mem_payload_code),'),
            ('      .core_code (l1axi_en && core_mem_code),',
             '      .core_payload_code(l1axi_en && core_mem_payload_code),')),
        'rtl/mem/ventium_l1_axi.sv': (
            ('    input  logic        core_code,', '    input  logic        core_payload_code,'),
            ('      .c_code  (core_code),', '      .c_payload_code(core_payload_code),')),
        'rtl/mem/ven_l1d.sv': (
            ('    input  logic        c_code, // physical instruction-fill beat, never a data operand',
             '    input  logic        c_payload_code, // early kind; valid only on an acknowledged read'),),
    }.items():
        for old, added in rows:
            result[path] = replace(result[path], old, old+'\n'+guard(added))
    path = 'rtl/mem/ven_l1d.sv'
    text = result[path]
    old = '''  assign code_access = c_code && !c_we && cacheable && !golden &&
      (c_addr[1:0] == 2'd0) && ((c_wstrb == 4'h0) || (c_wstrb == 4'hf));'''
    payload = '''  // Do not use this predicate for tags, ready, ACK, capture or LRU.
  // c_payload_code equals c_code on every admitted read. While no request is
  // consumed it may differ, deliberately bypassing late core permission logic.
  wire code_payload_access = c_payload_code && cacheable && !golden &&
      (c_addr[1:0] == 2'd0) && ((c_wstrb == 4'h0) || (c_wstrb == 4'hf));'''
    text = replace(text, old, old+'\n'+guard(payload))
    old = '''  assign rd_match  = rd_armed && !stream_path && (rd_addr_q == c_addr)
`ifdef VEN_L1D_CODE_BUFFER
      && (rd_code_q == code_access)
`endif
      ;'''
    payload = '''  wire rd_payload_match = rd_armed && !stream_path && (rd_addr_q == c_addr)
      && (rd_code_q == code_payload_access);'''
    text = replace(text, old, old+'\n'+guard(payload))
    old = '''  assign early_match = early_armed && c_req && !c_we &&
                       (c_addr == early_addr_q) && (c_wstrb == early_wstrb_q)
`ifdef VEN_L1D_CODE_BUFFER
                       && (early_code_q == code_access)
`endif
                       ;'''
    payload = '''  wire early_payload_match = early_armed && (c_addr == early_addr_q) &&
      (c_wstrb == early_wstrb_q) && (early_code_q == code_payload_access);
`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n && c_req && !c_we && c_ack) begin
    assert (c_payload_code === c_code && code_payload_access === code_access &&
            rd_payload_match === rd_match && early_payload_match === early_match)
      else $fatal(1, "PAYLOAD-CODE-HINT: changed consumed response owner");
  end
`endif'''
    text = replace(text, old, old+'\n'+guard(payload))
    for old, new in (
        ('  wire code_payload_select = code_access && !rd_match;',
         '  wire code_payload_select = code_payload_access && !rd_payload_match;'),
        ('                           : early_match ? early_rdata_q',
         '                           : early_payload_match ? early_rdata_q'),
        ('  wire shadow_payload_select = !rd_match && shadow_valid_q &&',
         '  wire shadow_payload_select = !rd_payload_match && shadow_valid_q &&'),
    ):
        text = replace(text, old, choice(old, new))
    old = '''  wire shadow_high_payload_select = shadow_valid_q &&
      (c_addr[31:5] == shadow_line_addr_q)
`ifdef VEN_L1D_CODE_BUFFER
      && !code_access
`endif
      ;'''
    new = old.replace('      && !code_access', '      && !code_payload_access')
    text = replace(text, old, choice(old, new))
    anchor = '  // ---- arrays ----------------------------------------------------------------'
    requirements = '\n'.join('`ifndef '+name+'\n  initial $fatal(1, "payload code hint requires '+name+'");\n`endif'
        for name in ('VEN_L1D_CODE_BUFFER', 'VEN_L1D_CODE_PAYLOAD_SELECT'))
    requirements += '\n`ifdef VEN_L1D_COMB_ACK\n  initial $fatal(1, "payload code hint requires registered responses");\n`endif'
    text = replace(text, anchor, guard(requirements)+'\n\n'+anchor)
    result[path] = text
    return result
