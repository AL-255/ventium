"""Give checked paired-store intent explicit priority over nonbinding hints.

Private derivative of BACKING-PAYLOAD, not of the slower NEXT-PAIR candidate.
The request remains ready-qualified; the new intent has no architectural effect
by itself. It only reserves the shared cache lookup from speculative next reads.
"""
import hashlib

PARENTS = {
    'rtl/core/core.sv': '9c3dd3ba97fbc262ba99a1aa9a186d59049f9e597cee42322daa503e97ca0959',
    'rtl/ventium_top.sv': 'e28b4151744bd07a3e68822977b01c8e79992f42f369959d89437dbd87b1f7ab',
    'rtl/mem/ventium_l1_axi.sv': 'b2df30865b1edcaeb06f71c6415f4d4eb42570a2d41d3670089721cca14669e0',
    'rtl/mem/ven_l1d.sv': '15c3b939ac56928ad0484677058e3fad913cee9686de91940304e80bb202187f',
}


def replace(text, old, new):
    assert text.count(old) == 1, old
    return text.replace(old, new)


def transform(text, name):
    assert hashlib.sha256(text.encode()).hexdigest() == PARENTS[name], name
    if name == 'rtl/core/core.sv':
        text = replace(text, '    output logic        mem_store_pair_req,',
            '    output logic        mem_store_pair_intent,\n    output logic        mem_store_pair_req,')
        old = '  assign mem_store_pair_req = pipe_store_pair_offer && mem_store_pair_ready;'
        text = replace(text, old, '''  // Intent is checked before ready, and cannot post a write or retire V.
  // It gives an actual U/V store packet priority over a nonbinding next-read
  // lookup. Keep request/ACK admission unchanged: lack of credit still lets
  // U fall back to serial issue without waiting for a second backing slot.
  assign mem_store_pair_intent = pipe_store_pair_offer;
'''+old+'''
`ifndef SYNTHESIS
`ifdef VEN_RAW_V_READ_PRIME
`ifdef VEN_PIPE_MEM_CHAIN
  // The current RAW producer never offers both. Check this on instructions,
  // not by assuming away the shared-port conflict in timing constraints.
  always_ff @(posedge clk) if (rst_n)
    assert (!(mem_store_pair_intent && mem_next_req))
      else $fatal(1,"PAIR-INTENT: RAW producer offered a conflicting hint");
`endif
`endif
`endif''')
    elif name == 'rtl/ventium_top.sv':
        text = replace(text, '  logic        core_store_pair_req, core_store_pair_ready, core_store_pair_ack;',
            '  logic        core_store_pair_intent;\n  logic        core_store_pair_req, core_store_pair_ready, core_store_pair_ack;')
        text = replace(text, '      .mem_store_pair_req(core_store_pair_req),',
            '      .mem_store_pair_intent(core_store_pair_intent),\n      .mem_store_pair_req(core_store_pair_req),')
        text = replace(text, '      .core_store_pair_req(l1axi_en && core_store_pair_req),',
            '      .core_store_pair_intent(l1axi_en && core_store_pair_intent),\n      .core_store_pair_req(l1axi_en && core_store_pair_req),')
    elif name == 'rtl/mem/ventium_l1_axi.sv':
        text = replace(text, '    input  logic        core_store_pair_req,',
            '    input  logic        core_store_pair_intent,\n    input  logic        core_store_pair_req,')
        text = replace(text, '      .c_pair_req(core_store_pair_req && l1d_c_req),',
            '      .c_pair_intent(core_store_pair_intent && l1d_c_req),\n      .c_pair_req(core_store_pair_req && l1d_c_req),')
    elif name == 'rtl/mem/ven_l1d.sv':
        text = replace(text, '    input  logic        c_pair_req,',
            '''    // Checked packet intent, independent of ready. Reserves lookup only;
    // c_pair_req plus the existing acknowledgements still authorizes writes.
    input  logic        c_pair_intent,
    input  logic        c_pair_req,''')
        text = replace(text, '        && !(c_next_req && rd_match)',
            '        && (c_pair_intent || !(c_next_req && rd_match))')
        # The wide-read cofactor duplicated the old lookup exclusion too.
        # Follow the actual new arbiter, retaining its independent old-form
        # validity assertion rather than weakening it for simultaneous hints.
        text = replace(text, '      && !(c_next_req && rd_match)',
            '''`ifdef VEN_P54_DUAL_STORE_PAIR
      && (c_pair_intent || !(c_next_req && rd_match))
`else
      && !(c_next_req && rd_match)
`endif''')
        text = replace(text, '  assign mc_lookup_old = c_next_req && c_req && !c_we && rd_match &&',
            '''  assign mc_lookup_old = c_next_req && c_req && !c_we && rd_match &&
`ifdef VEN_P54_DUAL_STORE_PAIR
      !c_pair_intent &&
`endif''')
        # Prime lookup requires !c_req, whereas a checked intent belongs to
        # a current U packet. Explicitly reject a malformed stand-alone hint
        # conflict too; never capture next data on an intent-reserved port.
        text = replace(text, '  assign mc_lookup_prime = c_next_req && !c_req && !rd_armed &&',
            '''  assign mc_lookup_prime = c_next_req && !c_req && !rd_armed &&
`ifdef VEN_P54_DUAL_STORE_PAIR
      !c_pair_intent &&
`endif''')
        anchor = '  assign c_pair_ack = c_pair_req && c_pair_ready && c_ack &&'
        text = replace(text, anchor, '''`ifndef SYNTHESIS
  always_ff @(posedge clk) if (rst_n) begin
    assert (!c_pair_req || c_pair_intent)
      else $fatal(1,"PAIR-INTENT: request without prior intent");
    if (c_pair_intent)
      assert (!mc_lookup_next && !mc_capture_next)
        else $fatal(1,"PAIR-INTENT: conflicting hint acquired the cache port");
  end
`endif
'''+anchor)
    else:
        raise AssertionError(name)
    return text
